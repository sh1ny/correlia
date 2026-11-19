import 'dart:async';

import 'package:serverpod/serverpod.dart';

import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import 'output_relay.dart';
import 'plugin_output_router.dart';
import 'relay_deadline.dart';
import 'webhook_output.dart';

/// Runs bounded independent output lanes for a worker process.
final class RelaySubsystem extends Subsystem {
  /// Creates a relay using the process-local secret resolver.
  RelaySubsystem({
    required this.pod,
    required this.resolveKey,
    required String runMode,
    this.beforeAcquire,
    this.beforeClaimCommit,
    this.beforePluginComplete,
    this.onUnavailable,
    this.pluginRouter,
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _webhook = WebhookOutput(runMode: runMode);
  final Serverpod pod;
  final SigningKeyResolver resolveKey;
  final _diagnostics = <String, DateTime>{};

  /// Optional test barrier before acquisition; never used to configure delivery.
  final Future<void> Function()? beforeAcquire;

  /// Optional test barrier immediately before a claim's commit-boundary check.
  final Future<void> Function()? beforeClaimCommit;

  /// Optional test barrier after a plugin response and before its commit.
  final Future<void> Function(int acknowledgedCount)? beforePluginComplete;

  /// Receives fixed unavailable-key diagnostics without secret material.
  final void Function(String, String)? onUnavailable;

  /// Optional supervisor-backed router for plugin output definitions.
  final PluginOutputRouter? pluginRouter;
  final Duration pollInterval;
  final WebhookOutput _webhook;
  final Set<String> _busy = {};
  final Set<Future<void>> _lanes = {};
  final Completer<void> _stopped = Completer<void>();
  Future<void>? _loop;
  Timer? _timer;
  Completer<void>? _wake;

  @override
  String get name => 'output-relay';
  @override
  Set<ProcessRole> get roles => {ProcessRole.worker, ProcessRole.all};

  @override
  Future<void> start() async {
    _loop = _run();
  }

  Future<void> _run() async {
    final session = await pod.createSession(enableLogging: false);
    try {
      final repository = OutputRelayRepository(
        session,
        resolveKey,
        diagnostics: _diagnostics,
        onUnavailable: onUnavailable,
      );
      while (!_stopped.isCompleted) {
        if (beforeAcquire != null) {
          await Future.any([beforeAcquire!(), _stopped.future]);
          if (_stopped.isCompleted) break;
        }
        try {
          await repository.recoverExpired();
          final available = await repository.discover(
            _busy,
            readyDefinitions: pluginRouter?.readyDefinitions ?? {},
          );
          for (final output in available) {
            if (_stopped.isCompleted ||
                _lanes.length >= 64 ||
                !_busy.add(output)) {
              continue;
            }
            late Future<void> lane;
            lane = _deliver(output).whenComplete(() {
              _busy.remove(output);
              _lanes.remove(lane);
            });
            _lanes.add(lane);
          }
        } catch (_) {
          // The durable queue remains authoritative; retry on the next poll.
        }
        if (_stopped.isCompleted) break;
        _wake = Completer<void>();
        _timer = Timer(pollInterval, _wake!.complete);
        await _wake!.future;
        _timer = null;
        _wake = null;
      }
    } finally {
      await session.close();
    }
  }

  Future<void> _deliver(String output) async {
    final session = await pod.createSession(enableLogging: false);
    try {
      final repository = OutputRelayRepository(
        session,
        resolveKey,
        diagnostics: _diagnostics,
        onUnavailable: onUnavailable,
        beforeClaimCommit: beforeClaimCommit,
      );
      final router = pluginRouter;
      final digests = router?.readyDefinitions[output] ?? <String>{};
      final digest = await repository.oldestReadyDigest(output, digests);
      if (digest != null && router != null) {
        final permit = router.tryAcquire(output, digest);
        if (permit == null) return;
        try {
          final deadline = RelayDeadline();
          final batch = await repository.claim(
            output,
            limit: router.eventLimit(output, digest).clamp(1, 64),
            byteLimit: router.byteLimit(output, digest).clamp(1, 1024 * 1024),
            readyDigests: {digest},
            permit: permit,
            deadline: deadline,
          );
          if (batch == null || _stopped.isCompleted) return;
          final outcomes = await deliverPluginBatch(router, permit, batch);
          final barrier = beforePluginComplete;
          if (barrier != null) {
            await barrier(outcomes.whereType<DeliveryAcknowledged>().length);
          }
          await repository.completeBatch(batch, outcomes);
        } finally {
          permit.release();
        }
      } else {
        final deadline = RelayDeadline();
        final batch = await repository.claim(output, deadline: deadline);
        if (batch == null || _stopped.isCompleted) return;
        final claim = batch.claims.single;
        final outcome = await _webhook
            .send(claim.intent!, claim.key!)
            .timeout(deadline.deliveryBudget);
        if (!_stopped.isCompleted) {
          await repository.complete(claim, outcome, deadline: deadline);
        }
      }
    } catch (_) {
      // A started claim remains durable and will be recovered after its lease.
    } finally {
      await session.close();
    }
  }

  @override
  Future<void> stop() async {
    if (!_stopped.isCompleted) _stopped.complete();
    _timer?.cancel();
    if (_wake != null && !_wake!.isCompleted) _wake!.complete();
    _webhook.close();
    await _loop;
    await Future.wait(_lanes.toList());
  }
}
