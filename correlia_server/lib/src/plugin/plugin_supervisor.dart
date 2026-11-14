import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:serverpod/serverpod.dart';

import '../ingest/bootstrap.dart';
import '../output/delivery_permit.dart';
import '../output/output_relay.dart';
import '../output/plugin_output_router.dart';
import 'output_plugin_connection.dart';
import 'plugin_admission_repository.dart';
import 'plugin_executable.dart';
import 'plugin_health_repository.dart';
import 'plugin_status_repository.dart';
import 'slot_scheduler.dart';
import 'supervision_policy.dart';

final class _Instance {
  _Instance(this.key, this.policy, this.restartCount);
  final PluginKey key;
  final SupervisionPolicy policy;
  int restartCount;
  final permit = DeliveryPermitSource();
  OutputPluginConnection? connection;
  OutputPluginException? failure;
  DateTime? lastHealth, lastHeartbeat;
  bool checking = false;
  bool recoveryBeforeFailure = false;
  bool recoveryPending = false;
  Future<void> statusTail = Future.value();
  bool removalPrepared = false;
  String? removalActivity;
  String? forcedError;
  bool reapRecorded = false;
  bool stopping = false;
}

/// Supervises bounded, pinned plugin processes and routes ready deliveries.
final class PluginSupervisor implements PluginOutputRouter {
  PluginSupervisor({
    required this.openSession,
    required this.bootstrap,
    required this.pluginDirectory,
    required this.hostInstanceId,
    required this.log,
    this.beforeLaunch,
    this.beforeRemove,
    this.onStatusWrite,
    this.afterForcedStop,
    DateTime Function()? clock,
    this.durations = const SupervisionDurations(),
    this.pollInterval = const Duration(milliseconds: 250),
  }) : clock = clock ?? DateTime.now {
    _scheduler = SlotScheduler(clock: this.clock);
  }

  final Future<Session> Function() openSession;
  final IngestBootstrap bootstrap;
  final String pluginDirectory;
  final String hostInstanceId;
  final void Function(String) log;
  final Future<void> Function(Future<void> stopping)? beforeLaunch;

  /// The test-only barrier entered before a connection is stopped and reaped.
  @visibleForTesting
  final Future<void> Function(PluginKey)? beforeRemove;

  /// The test-only observer of completed status writes; `null` marks the final write.
  @visibleForTesting
  final Future<void> Function(PluginKey?)? onStatusWrite;

  /// The test-only cleanup-failure injection, forwarded to the launch core.
  @visibleForTesting
  final Future<void> Function()? afterForcedStop;
  final DateTime Function() clock;
  final SupervisionDurations durations;
  final Duration pollInterval;
  late final SlotScheduler _scheduler;
  final Map<PluginKey, _Instance> _instances = {};
  final Set<Future<void>> _operations = {};
  final Set<PluginKey> _forcedKeys = {};
  final Set<Future<void>> _statusWrites = {};
  bool _statusWritesClosed = false;
  final Completer<void> _stopped = Completer<void>();
  Future<void>? _loop;
  Timer? _timer;
  Completer<void>? _wake;
  DateTime? _lastPrune;

  /// Starts polling without waiting for any plugin to become ready.
  Future<void> start() async {
    _loop ??= _run();
  }

  void _track(Future<void> task) {
    late Future<void> tracked;
    tracked = task
        .catchError((Object _) {
          log('plugin supervisor operation failed');
        })
        .whenComplete(() => _operations.remove(tracked));
    _operations.add(tracked);
  }

  Future<T> _session<T>(Future<T> Function(Session) action) async {
    final session = await openSession();
    try {
      return await action(session);
    } finally {
      await session.close();
    }
  }

  Future<void> _run() async {
    while (!_stopped.isCompleted) {
      try {
        await _sweep();
      } on Object {
        log('plugin supervisor sweep failed');
      }
      if (_stopped.isCompleted) break;
      _wake = Completer<void>();
      _timer = Timer(pollInterval, _wake!.complete);
      await _wake!.future;
      _timer = null;
      _wake = null;
    }
  }

  Future<void> _sweep() => _session((session) async {
    final now = clock().toUtc();
    final healthRepository = PluginHealthRepository(session, hostInstanceId);
    final admission = PluginAdmissionRepository(session, hostInstanceId);
    if (_lastPrune == null ||
        now.difference(_lastPrune!) >= const Duration(minutes: 1)) {
      await PluginStatusRepository(session, hostInstanceId).prune(now);
      await healthRepository.prune();
      _lastPrune = now;
    }
    for (final instance in _instances.values.toList(growable: false)) {
      if (instance.stopping) continue;
      if (instance.removalPrepared) {
        instance.stopping = true;
        _track(_remove(instance));
        continue;
      }
      if (instance.failure != null) {
        instance.stopping = true;
        _track(_remove(instance, failed: true));
        continue;
      }
      if (instance.connection == null ||
          instance.policy.state != PluginState.ready) {
        continue;
      }
      final previousFailures = instance.policy.failures.length;
      instance.policy.failures.removeWhere(
        (time) => now.difference(time) > durations.crashWindow,
      );
      if (instance.policy.failures.length != previousFailures) {
        instance.lastHeartbeat = null;
        await _persist(instance);
        instance.lastHeartbeat = now;
      }
      final previousProbe = instance.policy.nextProbeAt;
      final previousStep = instance.policy.backoffStep;
      if (instance.policy.tick()) {
        await _recover(instance, previousProbe);
      } else if (instance.policy.backoffStep != previousStep) {
        instance.lastHeartbeat = null;
        await _persist(instance);
        instance.lastHeartbeat = now;
      }
      if (instance.lastHeartbeat == null ||
          now.difference(instance.lastHeartbeat!) >=
              const Duration(seconds: 15)) {
        await _persist(instance);
        instance.lastHeartbeat = now;
      }
      if (!instance.checking &&
          (instance.lastHealth == null ||
              now.difference(instance.lastHealth!) >=
                  durations.healthInterval)) {
        instance.lastHealth = now;
        instance.checking = true;
        _track(_health(instance));
      }
      final due = await session.db.unsafeQuery(
        '''SELECT EXISTS(SELECT 1 FROM outbox
        WHERE output_id=CAST(@output AS uuid) AND output_kind='plugin' AND definition_digest=@digest
          AND status='queued' AND (next_attempt_at IS NULL OR next_attempt_at<=clock_timestamp()))''',
        parameters: QueryParameters.named({
          'output': instance.key.outputId,
          'digest': instance.key.digest,
        }),
        timeoutInSeconds: 5,
      );
      if (due.single[0] as bool) {
        _scheduler.due(instance.key);
      } else if (_scheduler.idleForRelease(instance.key)) {
        instance.stopping = true;
        _track(_remove(instance));
      }
    }
    while (!_stopped.isCompleted &&
        _instances.length < _scheduler.workerLimit) {
      final key = await admission.next(
        cursor: _scheduler.cursor,
        running: _scheduler.running,
      );
      if (key == null || _stopped.isCompleted) break;
      final policy = await healthRepository.load(
        key,
        clock,
        durations: durations,
      );
      final previousStatus = await session.db.unsafeQuery(
        '''SELECT "restartCount" FROM plugin_instance_status
        WHERE "hostInstanceId"=@host AND "outputId"=@output AND "definitionDigest"=@digest''',
        parameters: QueryParameters.named({
          'host': hostInstanceId,
          'output': key.outputId,
          'digest': key.digest,
        }),
        timeoutInSeconds: 5,
      );
      if (_stopped.isCompleted) break;
      final probing = policy.circuit == PluginCircuit.open;
      policy.start();
      _scheduler.admit(key, probing: probing);
      final instance = _Instance(
        key,
        policy,
        previousStatus.isEmpty ? 0 : previousStatus.single[0] as int,
      );
      _instances[key] = instance;
      _track(_launch(instance));
    }
    if (_stopped.isCompleted) return;
    final waiting = await admission.next(
      cursor: _scheduler.cursor,
      running: _scheduler.running,
      respectOutputLimit: false,
    );
    if (waiting != null) {
      if (!_scheduler.canAdmit(waiting)) {
        await PluginStatusRepository(
          session,
          hostInstanceId,
        ).writeWaiting(waiting, now);
      }
      final victim = _scheduler.rotationFor(waiting);
      if (victim != null) {
        final instance = _instances[victim]!;
        if (!instance.stopping) {
          instance.stopping = true;
          _track(_remove(instance));
        }
      }
    }
  });

  Future<void> _launch(_Instance instance) async {
    try {
      try {
        await _persist(instance);
      } on Object {
        instance.stopping = true;
        _track(_remove(instance));
        return;
      }
      if (beforeLaunch != null) await beforeLaunch!(_stopped.future);
      if (_stopped.isCompleted || instance.stopping) return;
      String? snapshotJson;
      try {
        snapshotJson = await _session((session) async {
          final rows = await session.db.unsafeQuery(
            '''SELECT s."publicJson" FROM outbox o
            JOIN ingest_config_snapshot s ON s."snapshotId"=o.config_snapshot_id
            WHERE o.output_id=CAST(@output AS uuid) AND o.definition_digest=@digest
            AND o.output_kind='plugin' AND o.status='queued'
            ORDER BY o.created_at,o.delivery_id LIMIT 1''',
            parameters: QueryParameters.named({
              'output': instance.key.outputId,
              'digest': instance.key.digest,
            }),
            timeoutInSeconds: 5,
          );
          return rows.isEmpty ? null : rows.single[0] as String;
        });
      } on Object {
        instance.stopping = true;
        _track(_remove(instance));
        return;
      }
      if (snapshotJson == null) {
        instance.stopping = true;
        _track(_remove(instance));
        return;
      }
      final snapshot = jsonDecode(snapshotJson) as Map<String, Object?>;
      final outputs = (snapshot['outputs'] as List<Object?>)
          .cast<Map<String, Object?>>();
      final definition = outputs.singleWhere(
        (item) =>
            item['id'] == instance.key.outputId &&
            item['kind'] == 'plugin' &&
            sha256Digest(item) == instance.key.digest,
      );
      final executable = await verifyPluginExecutable(
        pluginDirectory,
        definition['plugin'] as String,
        definition['sha256'] as String,
      );
      final references = (definition['secret_refs'] as Map<String, Object?>);
      final secrets = <String, List<int>>{};
      for (final entry in references.entries) {
        final reference = entry.value as Map<String, Object?>;
        final bytes = bootstrap.secret(reference['reference'] as String);
        if (bytes == null ||
            sha256.convert(bytes).toString() != reference['commitment']) {
          throw const OutputPluginException('plugin_secret_unavailable');
        }
        secrets[entry.key] = bytes;
      }
      if (_stopped.isCompleted || instance.stopping) return;
      final startWatch = Stopwatch()..start();
      final connection = await OutputPluginConnection.start(
        executable: executable,
        configJson: utf8.encode(jsonEncode(definition['config'])),
        secrets: secrets,
        timeout: durations.startTimeout,
        shutdownGrace: durations.shutdownGrace,
        afterForcedStop: afterForcedStop,
      );
      instance.connection = connection;
      unawaited(
        connection.failure.then((error) => _observeFailure(instance, error)),
      );
      if (_stopped.isCompleted || instance.stopping) return;
      final remaining = durations.startTimeout - startWatch.elapsed;
      if (remaining <= Duration.zero) {
        throw const OutputPluginException('plugin_start_timeout');
      }
      final healthDeadline = remaining < durations.healthDeadline
          ? remaining
          : durations.healthDeadline;
      final response = await connection.health(timeout: healthDeadline);
      if (!response.serving) {
        throw const OutputPluginException('plugin_health_failed');
      }
      if (instance.failure != null) return;
      instance.policy.ready();
      instance.lastHealth = clock().toUtc();
      instance.lastHeartbeat = clock().toUtc();
      _scheduler.ready(instance.key);
      try {
        await _persist(instance);
      } on Object {
        instance.lastHeartbeat = null;
        log('plugin supervisor status write failed');
      }
    } on Object catch (error) {
      instance.permit.invalidate();
      if (error is OutputPluginException) {
        if (error.reapedPid != null) {
          _recordReap(
            instance,
            pid: error.reapedPid!,
            forced: error.reapedForcibly == true,
            failed: true,
          );
        }
        instance.failure = error;
      } else if (error is PluginExecutableRejected) {
        instance.failure = const OutputPluginException(
          'plugin_executable_rejected',
        );
      } else {
        instance.failure = const OutputPluginException('plugin_start_failed');
      }
    }
  }

  void _observeFailure(_Instance instance, OutputPluginException error) {
    if (instance.failure != null) return;
    instance.permit.invalidate();
    if (instance.stopping || _stopped.isCompleted) return;
    if (instance.recoveryPending || instance.policy.tick()) {
      instance.recoveryBeforeFailure = true;
    }
    instance.failure = error;
  }

  Future<void> _recover(_Instance instance, DateTime? previousProbe) async {
    instance.recoveryPending = true;
    try {
      await _persist(instance, activity: 'plugin_recovered');
    } on Object {
      if (instance.failure == null) {
        instance.policy.circuit = PluginCircuit.probing;
        instance.policy.nextProbeAt = previousProbe;
      } else {
        instance.recoveryBeforeFailure = true;
      }
      rethrow;
    } finally {
      instance.recoveryPending = false;
    }
  }

  Future<void> _health(_Instance instance) async {
    try {
      bool serving;
      try {
        serving = (await instance.connection!.health(
          timeout: durations.healthDeadline,
        )).serving;
      } on Object {
        serving = false;
      }
      if (instance.stopping || instance.failure != null) return;
      final previousProbe = instance.policy.nextProbeAt;
      if (instance.policy.tick()) {
        await _recover(instance, previousProbe);
      }
      if (instance.stopping || instance.failure != null) return;
      if (instance.policy.health(serving)) {
        instance.permit.invalidate();
        instance.failure = const OutputPluginException('plugin_health_failed');
      }
    } finally {
      instance.checking = false;
    }
  }

  Future<void> _persist(
    _Instance instance, {
    String? activity,
    String? forcedError,
  }) {
    if (_statusWritesClosed) {
      throw StateError('Plugin status write after shutdown fence');
    }
    final connection = instance.connection;
    final policy = instance.policy;
    final snapshot = SupervisionPolicy(
      clock: clock,
      durations: durations,
      circuit: policy.circuit,
      backoffStep: policy.backoffStep,
      nextStartAt: policy.nextStartAt,
      nextProbeAt: policy.nextProbeAt,
      lastError: policy.lastError,
      failures: policy.failures,
    )..state = policy.state;
    final status = PluginStatusSnapshot(
      key: instance.key,
      state: snapshot.state.name,
      pluginName: connection?.metadata.name,
      pluginVersion: connection?.metadata.version,
      pid: connection?.pid,
      restartCount: instance.restartCount,
      crashesInWindow: snapshot.failures.length,
      lastErrorClass: forcedError ?? snapshot.lastError,
      lastPluginErrorClass: instance.failure?.pluginErrorClass,
      heartbeatAt: clock().toUtc(),
    );
    final result = instance.statusTail.then(
      (_) async {
        await _session(
          (session) => PluginStatusRepository(
            session,
            hostInstanceId,
          ).write(status, snapshot, activity: activity),
        );
        await onStatusWrite?.call(instance.key);
      },
    );
    late final Future<void> settled;
    settled = result
        .then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        )
        .whenComplete(() {
          _statusWrites.remove(settled);
        });
    _statusWrites.add(settled);
    instance.statusTail = settled;
    return result;
  }

  void _recordReap(
    _Instance instance, {
    required int pid,
    required bool forced,
    required bool failed,
  }) {
    if (instance.reapRecorded) return;
    instance.reapRecorded = true;
    if (forced && _stopped.isCompleted) _forcedKeys.add(instance.key);
    if (forced) instance.forcedError = 'plugin_forced_stop';
    log(
      'plugin-reaped output=${instance.key.outputId} '
      'digest=${instance.key.digest.substring(0, 12)} '
      'pid=$pid failed=$failed forced=$forced shutdown=${_stopped.isCompleted}',
    );
  }

  Future<void> _remove(_Instance instance, {bool failed = false}) async {
    try {
      if (!instance.removalPrepared) {
        // Voluntary retirement refuses new acquisitions but preserves held permits.
        await instance.permit.drain();
        instance.permit.invalidate();
        final connection = instance.connection;
        if (connection != null) {
          await beforeRemove?.call(instance.key);
          try {
            await connection.stop(grace: durations.shutdownGrace);
          } finally {
            if (connection.pid case final pid?) {
              _recordReap(
                instance,
                pid: pid,
                forced: connection.forcedStop,
                failed: failed,
              );
            }
          }
        }
        if (failed) {
          if (instance.recoveryBeforeFailure) {
            await _persist(instance, activity: 'plugin_recovered');
            instance.recoveryBeforeFailure = false;
          }
          instance.restartCount++;
          if (instance.policy.state != PluginState.backoff &&
              instance.policy.state != PluginState.degraded) {
            instance.policy.failed(
              instance.failure?.errorClass ?? 'plugin_connection_lost',
            );
          }
          if (instance.policy.circuit == PluginCircuit.open) {
            instance.removalActivity = 'plugin_degraded';
          }
        } else {
          instance.policy.stop();
        }
        instance.removalPrepared = true;
      }
      await _persist(
        instance,
        activity: instance.removalActivity,
        forcedError: instance.forcedError,
      );
      _instances.remove(instance.key);
      _scheduler.release(instance.key);
    } on Object {
      instance.stopping = false;
      rethrow;
    }
  }

  @override
  Map<String, Set<String>> get readyDefinitions {
    if (_stopped.isCompleted) return const {};
    final ready = <String, Set<String>>{};
    for (final instance in _instances.values) {
      if (!instance.stopping &&
          instance.failure == null &&
          instance.policy.state == PluginState.ready) {
        (ready[instance.key.outputId] ??= {}).add(instance.key.digest);
      }
    }
    return ready;
  }

  @override
  DeliveryPermit? tryAcquire(String outputId, String digest) {
    if (_stopped.isCompleted) return null;
    final instance = _instances[PluginKey(outputId, digest)];
    return instance == null ||
            instance.stopping ||
            instance.failure != null ||
            instance.policy.state != PluginState.ready
        ? null
        : instance.permit.acquire();
  }

  @override
  int eventLimit(String outputId, String digest) =>
      _instances[PluginKey(outputId, digest)]!.connection!.limits.maxEvents;

  @override
  int byteLimit(String outputId, String digest) =>
      _instances[PluginKey(outputId, digest)]!.connection!.limits.maxBytes;

  @override
  Future<List<DeliveryOutcome>> deliver(
    DeliveryPermit permit,
    DeliveryBatch batch,
  ) async {
    if (!permit.isValid) throw StateError('Plugin permit invalidated');
    final instance = _instances.values.singleWhere(
      (value) =>
          value.key.digest == batch.definitionDigest &&
          value.policy.state == PluginState.ready,
    );
    late final List<OutputPluginResult> results;
    try {
      results = await instance.connection!
          .deliver([
            for (final claim in batch.claims)
              OutputPluginEvent(claim.eventId, claim.payload),
          ])
          .timeout(batch.deadline.deliveryBudget);
    } on Object {
      _observeFailure(
        instance,
        const OutputPluginException('plugin_connection_lost'),
      );
      rethrow;
    }
    final byId = {for (final result in results) result.id: result};
    return [
      for (final claim in batch.claims)
        switch (byId[claim.eventId]!) {
          OutputPluginResult(outcome: OutputPluginOutcome.acknowledged) =>
            const DeliveryAcknowledged(),
          OutputPluginResult(
            outcome: OutputPluginOutcome.retryable,
            :final errorClass,
          ) =>
            DeliveryRetryable(errorClass),
          OutputPluginResult(
            outcome: OutputPluginOutcome.rejected,
            :final errorClass,
          ) =>
            DeliveryPermanent(errorClass),
        },
    ];
  }

  /// Drains all work, fences status writes and records forced reasons last.
  Future<void> stop() async {
    if (!_stopped.isCompleted) _stopped.complete();
    _timer?.cancel();
    if (_wake != null && !_wake!.isCompleted) _wake!.complete();
    await _loop;
    while (_operations.isNotEmpty) {
      await Future.wait(_operations.toList(growable: false));
    }
    Object? firstError;
    StackTrace? firstStack;
    for (final instance in _instances.values.toList(growable: false)) {
      instance.stopping = true;
      try {
        await _remove(instance, failed: instance.failure != null);
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    _statusWritesClosed = true;
    while (_statusWrites.isNotEmpty) {
      await Future.wait(_statusWrites.toList(growable: false));
    }
    try {
      await _session(
        (session) => PluginStatusRepository(
          session,
          hostInstanceId,
        ).markStopped(clock().toUtc(), forcedKeys: _forcedKeys),
      );
      await onStatusWrite?.call(null);
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}
