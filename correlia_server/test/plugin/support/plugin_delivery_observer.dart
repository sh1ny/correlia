import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:correlia_server/plugin.dart';
import 'package:correlia_server/src/plugin/plugin_host.dart'
    show PluginHostTestControls, createPluginHostForTesting;
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../delivery_event_source.dart';
import 'plugin_fixture_support.dart';

/// Immutable facts from one delivery proof.
final class PluginDeliveryCaseObservation {
  /// Creates a snapshot of actual fixture commands and case facts.
  PluginDeliveryCaseObservation(
    List<List<String>> commands,
    Map<String, Object?> facts,
    List<Map<String, Object?>> connections,
  ) : commands = List.unmodifiable(
        commands.map((c) => List<String>.unmodifiable(c)),
      ),
      facts = Map.unmodifiable(facts),
      connections = List.unmodifiable(
        connections.map((c) => Map<String, Object?>.unmodifiable(c)),
      );

  /// The actual process invocations.
  final List<List<String>> commands;

  /// The observed case facts.
  final Map<String, Object?> facts;

  /// The observed handshake and transport metadata.
  final List<Map<String, Object?>> connections;
}

/// Immutable aggregate of all five delivery proofs.
final class PluginDeliveryObservation {
  /// Creates the aggregate from completed case receipts.
  PluginDeliveryObservation(
    this.securityMode,
    Map<String, PluginDeliveryCaseObservation> cases,
  ) : cases = Map.unmodifiable(cases),
      commands = List.unmodifiable(cases.values.expand((c) => c.commands));

  /// The selected transport mode.
  final String securityMode;

  /// The actual process invocations.
  final List<List<String>> commands;

  /// The case receipts.
  final Map<String, PluginDeliveryCaseObservation> cases;

  /// Serializes the observed facts.
  Map<String, Object?> toJson() => {
    'securityMode': securityMode,
    'commands': commands,
    'cases': {
      for (final entry in cases.entries)
        entry.key: {
          'facts': entry.value.facts,
          'connections': entry.value.connections,
        },
    },
  };
}

/// Runs all delivery proofs using the selected transport.
Future<PluginDeliveryObservation> observePluginDelivery(
  PluginFixtureSuite suite, {
  bool diagnosticPlaintext = false,
}) async {
  final cases = <String, PluginDeliveryCaseObservation>{};
  cases['withheld'] = await observeDeliveryWithheld(
    suite,
    diagnosticPlaintext: diagnosticPlaintext,
  );
  cases['invalidAck'] = await observeDeliveryInvalidAck(
    suite,
    diagnosticPlaintext: diagnosticPlaintext,
  );
  cases['stalled'] = await observeDeliveryStalled(
    suite,
    diagnosticPlaintext: diagnosticPlaintext,
  );
  cases['reconciliation'] = await observeDeliveryReconciliation(
    suite,
    diagnosticPlaintext: diagnosticPlaintext,
  );
  cases['failedRestart'] = await observeDeliveryFailedRestart(
    suite,
    diagnosticPlaintext: diagnosticPlaintext,
  );
  return PluginDeliveryObservation(
    diagnosticPlaintext ? 'diagnostic-plaintext' : 'native-authenticated-tls',
    cases,
  );
}

final class _DeliveryContext {
  _DeliveryContext(
    this.executable,
    this.identity,
    this.scratch,
    this.diagnosticPlaintext,
  );
  final String executable;
  final PluginClientIdentity identity;
  final Directory scratch;
  final bool diagnosticPlaintext;
  final commands = <List<String>>[];
  final connections = <Map<String, Object?>>[];
  int serial = 0;

  static Future<_DeliveryContext> create(
    PluginFixtureSuite suite,
    bool diagnosticPlaintext,
  ) async {
    final build = await suite.build();
    final credentials = await suite.createCredentials();
    final identity = PluginClientIdentity(
      certificatePem: await credentials.certificate.readAsBytes(),
      privateKeyPem: await credentials.privateKey.readAsBytes(),
    );
    final scratch = await suite.scratchDirectory.createTemp('delivery-proof-');
    return _DeliveryContext(
      build.binaries[PluginFixtureBinary.plainStock]!.path,
      identity,
      scratch,
      diagnosticPlaintext,
    );
  }

  File journal() => File('${scratch.path}/delivery-${serial++}.jsonl');

  PluginHost host(
    File journal, {
    PluginFixtureAckMode ack = PluginFixtureAckMode.normal,
    PluginFixtureStartupMode startup = PluginFixtureStartupMode.serve,
    PluginControlSocket? barrier,
  }) {
    final arguments = PluginFixtureArguments(
      journalPath: journal.path,
      ackMode: ack,
      startupMode: startup,
      tlsMode: diagnosticPlaintext
          ? PluginFixtureTlsMode.plaintext
          : PluginFixtureTlsMode.required,
      controlSocketPath: barrier?.socketPath,
      armBarrier: barrier != null,
    ).toArguments();
    final config = PluginHostConfig(
      executable: executable,
      arguments: arguments,
      identity: identity,
      timeout: const Duration(seconds: 3),
    );
    if (!diagnosticPlaintext) return PluginHost(config);
    return createPluginHostForTesting(
      config,
      controls: PluginHostTestControls(
        diagnosticPlaintext: true,
        processStarter: (command, argv, environment) async {
          final process = await Process.start(
            command,
            argv,
            environment: environment,
            includeParentEnvironment: false,
          );
          commands.add(List.unmodifiable([command, ...argv]));
          return process;
        },
      ),
    );
  }

  Future<void> healthy(PluginHost host) async {
    expect(host.evidence!.version, 1);
    expect(host.evidence!.socketMode, 0x180);
    if (diagnosticPlaintext) {
      expect(host.tlsEvidence, isNull);
    } else {
      expect(host.tlsEvidence!.protocol, 'TLSv1.3');
      expect(
        host.tlsEvidence!.serverCertificateCurve,
        anyOf('P-521', 'secp521r1'),
      );
      expect(
        host.tlsEvidence!.clientCertificateCurve,
        anyOf('P-521', 'secp521r1'),
      );
    }
    await host.probe();
    final tls = host.tlsEvidence;
    final identity = PluginProcessIdentity.read(host.childPid!);
    expect(identity, isNotNull);
    if (!diagnosticPlaintext) {
      final bytes = await File('/proc/${identity!.pid}/cmdline').readAsBytes();
      final command = utf8.decode(bytes).split('\u0000');
      if (command.isNotEmpty && command.last.isEmpty) command.removeLast();
      commands.add(List.unmodifiable(command));
    }
    connections.add({
      'pid': identity!.pid,
      'startTime': identity.startTime,
      'version': host.evidence!.version,
      'socketMode': host.evidence!.socketMode,
      'socketUid': host.evidence!.socketUid,
      'protocol': tls?.protocol,
      'serverCurve': tls?.serverCertificateCurve,
      'clientCurve': tls?.clientCertificateCurve,
      'backendVersion': tls?.backendVersion,
      'configurationPolicy': tls?.configurationPolicy,
      'configurationSource': tls?.configurationSource,
    });
  }

  void observe(PluginDeliveryReceipt receipt, Set<String> acknowledged) {
    receipt.acknowledged.then<void>((_) {
      acknowledged.add(receipt.eventId);
    }, onError: (Object _, StackTrace _) {});
  }

  Future<Map<String, Object?>> withheld() async {
    final file = journal();
    final barrier = await PluginControlSocket.bind(scratch);
    late PluginHost first;
    final delivery = PluginDelivery(
      createHost: (_) => first = host(
        file,
        ack: PluginFixtureAckMode.withhold,
        barrier: barrier,
      ),
      policy: PluginDeliveryPolicy(
        maxBatchEvents: 1,
        maxOutstandingBatches: 2,
        ackProgressTimeout: const Duration(seconds: 2),
      ),
    );
    final acknowledged = <String>{};
    try {
      await delivery.start();
      await healthy(first);
      final failure = delivery.whenFailed;
      for (final event in pluginDeliveryEvents(6)) {
        observe(await delivery.admit(event), acknowledged);
      }
      await barrier.waitForBarrier(timeout: const Duration(seconds: 5));
      expect(delivery.outstandingBatchCount, lessThanOrEqualTo(2));
      expect(delivery.pendingEventCount, 6);
      await barrier.release();
      expect(
        await failure.timeout(const Duration(seconds: 6)),
        isA<TimeoutException>(),
      );
      final records = readPluginJournal(file);
      expect(records.length, lessThanOrEqualTo(2));
      expect(records, isNotEmpty);
      expect(acknowledged, isEmpty);
      expect(delivery.pendingEventCount, 6);
      expect(delivery.availableCredits, 0);
      return {
        'credit_limit': delivery.policy.maxOutstandingBatches,
        'accepted_unacknowledged_batches': records
            .map((record) => (record.epoch, record.sequence))
            .toSet()
            .length,
        'retained_events_after_timeout': delivery.pendingEventCount,
        'available_credits': delivery.availableCredits,
        'acknowledged_count': acknowledged.length,
      };
    } finally {
      await delivery.stop();
      await barrier.dispose();
    }
  }

  Future<Map<String, Object?>> invalidAck() async {
    final facts = <String, Object?>{};
    for (final mode in [
      PluginFixtureAckMode.invalidEpoch,
      PluginFixtureAckMode.invalidSequence,
      PluginFixtureAckMode.duplicate,
    ]) {
      final file = journal();
      late PluginHost first;
      final delivery = PluginDelivery(
        createHost: (_) => first = host(file, ack: mode),
        policy: PluginDeliveryPolicy(
          maxBatchEvents: 1,
          maxOutstandingBatches: 2,
          ackProgressTimeout: const Duration(seconds: 3),
        ),
      );
      final acknowledged = <String>{};
      try {
        await delivery.start();
        await healthy(first);
        final failure = delivery.whenFailed;
        final receipts = await Future.wait([
          delivery.admit(pluginDeliveryEvent(1)),
          delivery.admit(pluginDeliveryEvent(2)),
        ]);
        for (final receipt in receipts) {
          observe(receipt, acknowledged);
        }
        expect(
          await failure.timeout(const Duration(seconds: 6)),
          isA<FormatException>(),
        );
        expect(delivery.availableCredits, 0);
        if (mode != PluginFixtureAckMode.duplicate) {
          expect(acknowledged, isEmpty);
          expect(delivery.pendingEventCount, 2);
        } else {
          expect(acknowledged, contains(receipts.first.eventId));
          expect(acknowledged, isNot(contains(receipts.last.eventId)));
        }
        facts['${mode.argument}_acknowledged'] = acknowledged.length;
        facts['${mode.argument}_pending'] = delivery.pendingEventCount;
        facts['${mode.argument}_credits'] = delivery.availableCredits;
      } finally {
        await delivery.stop();
      }
    }
    return facts;
  }

  Future<Map<String, Object?>> stalled() async {
    final file = journal();
    late PluginHost first;
    final delivery = PluginDelivery(
      createHost: (_) => first = host(file, ack: PluginFixtureAckMode.withhold),
      policy: PluginDeliveryPolicy(
        ackProgressTimeout: const Duration(milliseconds: 400),
      ),
    );
    final acknowledged = <String>{};
    try {
      await delivery.start();
      await healthy(first);
      final failure = delivery.whenFailed;
      final event = pluginDeliveryEvent(42);
      observe(await delivery.admit(event), acknowledged);
      expect(
        await failure.timeout(const Duration(seconds: 5)),
        isA<TimeoutException>(),
      );
      expect(delivery.pendingEvents.single.event.eventId, event.event.eventId);
      expect(delivery.pendingEvents.single.toJsonBytes(), event.toJsonBytes());
      expect(delivery.availableCredits, 0);
      expect(acknowledged, isEmpty);
      await expectLater(delivery.drain(), throwsA(isA<TimeoutException>()));
      return {
        'pending_count': delivery.pendingEventCount,
        'pending_id': delivery.pendingEvents.single.event.eventId,
        'pending_sha256': sha256
            .convert(delivery.pendingEvents.single.toJsonBytes())
            .toString(),
        'available_credits': delivery.availableCredits,
        'acknowledged_count': acknowledged.length,
      };
    } finally {
      await delivery.stop();
    }
  }

  Future<Map<String, Object?>> reconciliation() async {
    final file = journal();
    final barrier = await PluginControlSocket.bind(scratch);
    final hosts = <PluginHost>[];
    final delivery = PluginDelivery(
      createHost: (attempt) {
        final next = host(file, barrier: attempt == 0 ? barrier : null);
        hosts.add(next);
        return next;
      },
      policy: PluginDeliveryPolicy(
        ackProgressTimeout: const Duration(seconds: 10),
      ),
    );
    final digests = <String, String>{};
    final acknowledged = <String>{};
    Future<void>? producer;
    try {
      await delivery.start();
      await healthy(hosts.first);
      final failed = delivery.whenFailed;
      producer = () async {
        for (final event in pluginDeliveryEvents(10000)) {
          final id = event.event.eventId;
          digests[id] = sha256.convert(event.toJsonBytes()).toString();
          observe(await delivery.admit(event), acknowledged);
        }
      }();
      unawaited(
        producer.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      final paused = await barrier.waitForBarrier(
        timeout: const Duration(seconds: 10),
      );
      final outstandingAtFirstBarrier = delivery.outstandingBatchCount;
      final before = readPluginJournal(file);
      expect(before, isNotEmpty);
      expect(
        before.every(
          (r) => r.epoch == paused.epoch && r.sequence == paused.sequence,
        ),
        isTrue,
      );
      final pid = delivery.childPid!;
      final process = PluginProcessIdentity.read(pid)!;
      final ackedBeforeCrash = Set<String>.of(acknowledged);
      expect(process.signalIfExact(ProcessSignal.sigkill), isTrue);
      await failed.timeout(const Duration(seconds: 6));
      expect(delivery.pendingEventCount, greaterThan(0));
      final pendingAtCrash = delivery.pendingEventCount;
      final pendingBytesAtCrash = delivery.pendingBytes;
      await delivery.restart();
      await healthy(hosts.last);
      await producer.timeout(const Duration(seconds: 90));
      await delivery.drain().timeout(const Duration(seconds: 90));
      final records = readPluginJournal(file);
      expect(digests, hasLength(10000));
      expect(records.map((r) => r.id).toSet(), digests.keys.toSet());
      final counts = <String, int>{};
      for (final record in records) {
        expect(record.sha256, digests[record.id]);
        counts.update(record.id, (n) => n + 1, ifAbsent: () => 1);
        if (record.epoch != paused.epoch) {
          expect(ackedBeforeCrash, isNot(contains(record.id)));
        }
      }
      final uncertain = before
          .map((r) => r.id)
          .toSet()
          .difference(ackedBeforeCrash);
      // A second crash, after all 10,000 valid ACKs, makes the no-replay
      // assertion non-vacuous without moving the required first barrier.
      final secondFailure = delivery.whenFailed;
      final secondProcess = PluginProcessIdentity.read(delivery.childPid!)!;
      expect(secondProcess.signalIfExact(ProcessSignal.sigkill), isTrue);
      await secondFailure.timeout(const Duration(seconds: 6));
      await delivery.restart();
      await healthy(hosts.last);
      final extra = pluginDeliveryEvent(10000);
      final extraReceipt = await delivery.admit(extra);
      await extraReceipt.acknowledged.timeout(const Duration(seconds: 10));
      await delivery.drain();
      final afterSecondCrash = readPluginJournal(
        file,
      ).skip(records.length).toList();
      expect(afterSecondCrash, hasLength(1));
      expect(afterSecondCrash.single.id, extra.event.eventId);
      expect(
        counts.entries
            .where((entry) => entry.value > 1)
            .map((entry) => entry.key)
            .toSet(),
        uncertain,
      );
      for (final id in uncertain) {
        expect(
          counts[id],
          2,
          reason:
              'recorded but unacknowledged work must actually be redelivered',
        );
      }
      expect(acknowledged, digests.keys.toSet());
      return {
        'reconciled_unique_ids': digests.length,
        'journal_records_before_second_crash': records.length,
        'duplicate_ids': counts.values.where((count) => count > 1).length,
        'uncertain_ids': uncertain.length,
        'first_barrier_sequence': paused.sequence,
        'first_barrier_events': before.length,
        'pending_after_first_crash': pendingAtCrash,
        'pending_bytes_after_first_crash': pendingBytesAtCrash,
        'default_credit_limit': delivery.policy.maxOutstandingBatches,
        'outstanding_at_first_barrier': outstandingAtFirstBarrier,
        'acknowledged_before_second_crash': acknowledged.length,
        'new_records_after_second_restart': afterSecondCrash.length,
        'first_crash_pid': process.pid,
        'first_crash_start_time': process.startTime,
        'second_crash_pid': secondProcess.pid,
        'second_crash_start_time': secondProcess.startTime,
      };
    } finally {
      await delivery.stop();
      if (producer != null) {
        try {
          await producer.timeout(const Duration(seconds: 10));
        } on Object catch (_) {}
      }
      await barrier.dispose();
    }
  }

  Future<Map<String, Object?>> failedRestart() async {
    final file = journal();
    final barrier = await PluginControlSocket.bind(scratch);
    late PluginHost first;
    final delivery = PluginDelivery(
      createHost: (attempt) => attempt == 0
          ? first = host(
              file,
              ack: PluginFixtureAckMode.withhold,
              barrier: barrier,
            )
          : host(file, startup: PluginFixtureStartupMode.exit),
      policy: PluginDeliveryPolicy(
        ackProgressTimeout: const Duration(seconds: 10),
      ),
    );
    final acknowledged = <String>{};
    try {
      await delivery.start();
      await healthy(first);
      final failed = delivery.whenFailed;
      final event = pluginDeliveryEvent(7);
      observe(await delivery.admit(event), acknowledged);
      await barrier.waitForBarrier(timeout: const Duration(seconds: 5));
      final process = PluginProcessIdentity.read(delivery.childPid!)!;
      expect(process.signalIfExact(ProcessSignal.sigkill), isTrue);
      await failed.timeout(const Duration(seconds: 5));
      final snapshot = delivery.pendingEvents;
      final bytes = List<int>.of(snapshot.single.toJsonBytes());
      await expectLater(
        delivery.restart(),
        throwsA(isA<PluginStartupException>()),
      );
      expect(delivery.isFailed, isTrue);
      expect(delivery.pendingEventCount, 1);
      expect(delivery.pendingEvents.single.event.eventId, event.event.eventId);
      expect(delivery.pendingEvents.single.toJsonBytes(), bytes);
      expect(() => snapshot.clear(), throwsUnsupportedError);
      expect(acknowledged, isEmpty);
      return {
        'pending_count': delivery.pendingEventCount,
        'pending_id': delivery.pendingEvents.single.event.eventId,
        'pending_sha256': sha256
            .convert(delivery.pendingEvents.single.toJsonBytes())
            .toString(),
        'acknowledged_count': acknowledged.length,
        'failed': delivery.isFailed,
      };
    } finally {
      await delivery.stop();
      await barrier.dispose();
    }
  }
}

Future<PluginDeliveryCaseObservation> _runDeliveryCase(
  PluginFixtureSuite suite,
  bool diagnosticPlaintext,
  Future<Map<String, Object?>> Function(_DeliveryContext) run,
) async {
  final context = await _DeliveryContext.create(suite, diagnosticPlaintext);
  try {
    final facts = await run(context);
    return PluginDeliveryCaseObservation(
      context.commands,
      facts,
      context.connections,
    );
  } finally {
    await context.scratch.delete(recursive: true);
  }
}

/// Observes a full credit window with withheld acknowledgements.
Future<PluginDeliveryCaseObservation> observeDeliveryWithheld(
  PluginFixtureSuite suite, {
  bool diagnosticPlaintext = false,
}) => _runDeliveryCase(
  suite,
  diagnosticPlaintext,
  (context) => context.withheld(),
);

/// Observes malformed and duplicate acknowledgements.
Future<PluginDeliveryCaseObservation> observeDeliveryInvalidAck(
  PluginFixtureSuite suite, {
  bool diagnosticPlaintext = false,
}) => _runDeliveryCase(
  suite,
  diagnosticPlaintext,
  (context) => context.invalidAck(),
);

/// Observes a stalled receiver retaining work.
Future<PluginDeliveryCaseObservation> observeDeliveryStalled(
  PluginFixtureSuite suite, {
  bool diagnosticPlaintext = false,
}) => _runDeliveryCase(
  suite,
  diagnosticPlaintext,
  (context) => context.stalled(),
);

/// Observes reconciliation across two real crashes.
Future<PluginDeliveryCaseObservation> observeDeliveryReconciliation(
  PluginFixtureSuite suite, {
  bool diagnosticPlaintext = false,
}) => _runDeliveryCase(
  suite,
  diagnosticPlaintext,
  (context) => context.reconciliation(),
);

/// Observes immutable pending work after a failed restart.
Future<PluginDeliveryCaseObservation> observeDeliveryFailedRestart(
  PluginFixtureSuite suite, {
  bool diagnosticPlaintext = false,
}) => _runDeliveryCase(
  suite,
  diagnosticPlaintext,
  (context) => context.failedRestart(),
);
