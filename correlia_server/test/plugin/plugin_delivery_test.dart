@Tags(['plugin'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/plugin.dart';
import 'package:correlia_server/src/plugin_generated/correlia/plugin/spike/v1/output.pb.dart'
    as wire;
import 'package:fixnum/fixnum.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'delivery_event_source.dart';
import 'support/plugin_fixture_support.dart';

void main() {
  late PluginFixtureSuite suite;
  late String executable;
  late PluginClientIdentity identity;
  var serial = 0;

  setUpAll(() async {
    suite = PluginFixtureSuite.create();
    final build = await suite.build();
    executable = build.binaries[PluginFixtureBinary.plainStock]!.path;
    final credentials = await suite.createCredentials();
    identity = PluginClientIdentity(
      certificatePem: await credentials.certificate.readAsBytes(),
      privateKeyPem: await credentials.privateKey.readAsBytes(),
    );
  });
  tearDownAll(() async => suite.dispose());

  File journal() =>
      File('${suite.scratchDirectory.path}/delivery-${serial++}.jsonl');

  PluginHost host(
    File journal, {
    PluginFixtureAckMode ack = PluginFixtureAckMode.normal,
    PluginFixtureStartupMode startup = PluginFixtureStartupMode.serve,
    PluginControlSocket? barrier,
  }) => PluginHost(
    PluginHostConfig(
      executable: executable,
      arguments: PluginFixtureArguments(
        journalPath: journal.path,
        ackMode: ack,
        startupMode: startup,
        tlsMode: PluginFixtureTlsMode.required,
        controlSocketPath: barrier?.socketPath,
        armBarrier: barrier != null,
      ).toArguments(),
      identity: identity,
      timeout: const Duration(seconds: 3),
    ),
  );

  Future<void> healthy(PluginHost host) async {
    expect(host.evidence!.version, 1);
    expect(host.tlsEvidence!.protocol, 'TLSv1.3');
    expect(
      host.tlsEvidence!.serverCertificateCurve,
      anyOf('P-521', 'secp521r1'),
    );
    expect(
      host.tlsEvidence!.clientCertificateCurve,
      anyOf('P-521', 'secp521r1'),
    );
    await host.probe();
  }

  void observe(PluginDeliveryReceipt receipt, Set<String> acknowledged) {
    receipt.acknowledged.then<void>((_) {
      acknowledged.add(receipt.eventId);
    }, onError: (Object _, StackTrace _) {});
  }

  test('withheld acknowledgements bound sends to credits', () async {
    final file = journal();
    final barrier = await PluginControlSocket.bind(suite.scratchDirectory);
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
      stdout.writeln(
        jsonEncode({
          'credit_limit': delivery.policy.maxOutstandingBatches,
          'accepted_unacknowledged_batches': records
              .map((record) => (record.epoch, record.sequence))
              .toSet()
              .length,
          'retained_events_after_timeout': delivery.pendingEventCount,
        }),
      );
    } finally {
      await delivery.stop();
      await barrier.dispose();
    }
  });

  test(
    'invalid acknowledgements cannot complete work or create credits',
    () async {
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
        } finally {
          await delivery.stop();
        }
      }
    },
  );

  test('stalled receiver times out retaining outstanding work', () async {
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
    } finally {
      await delivery.stop();
    }
  });

  test('10000 events reconcile after pre-ack plugin crash', () async {
    final file = journal();
    final barrier = await PluginControlSocket.bind(suite.scratchDirectory);
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
      stdout.writeln(
        jsonEncode({
          'reconciled_unique_ids': digests.length,
          'journal_records_before_second_crash': records.length,
          'duplicate_ids': counts.values.where((count) => count > 1).length,
          'first_barrier_sequence': paused.sequence,
          'first_barrier_events': before.length,
          'pending_after_first_crash': pendingAtCrash,
          'pending_bytes_after_first_crash': pendingBytesAtCrash,
          'default_credit_limit': delivery.policy.maxOutstandingBatches,
          'outstanding_at_first_barrier': outstandingAtFirstBarrier,
          'acknowledged_before_second_crash': acknowledged.length,
          'new_records_after_second_restart': afterSecondCrash.length,
        }),
      );
    } finally {
      await delivery.stop();
      if (producer != null) {
        try {
          await producer;
        } on Object catch (_) {}
      }
      await barrier.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('failed restart retains immutable pending events', () async {
    final file = journal();
    final barrier = await PluginControlSocket.bind(suite.scratchDirectory);
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
    } finally {
      await delivery.stop();
      await barrier.dispose();
    }
  });

  test('policy rejects invalid bounds', () {
    expect(
      () => PluginDeliveryPolicy(maxPendingEvents: 0),
      throwsArgumentError,
    );
    expect(() => PluginDeliveryPolicy(maxPendingBytes: 0), throwsArgumentError);
    expect(() => PluginDeliveryPolicy(maxBatchEvents: 0), throwsArgumentError);
    expect(() => PluginDeliveryPolicy(maxBatchBytes: 0), throwsArgumentError);
    expect(
      () => PluginDeliveryPolicy(maxOutstandingBatches: 0),
      throwsArgumentError,
    );
    expect(
      () => PluginDeliveryPolicy(ackProgressTimeout: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => PluginDeliveryPolicy(maxBatchBytes: 2 * 1024 * 1024 + 1),
      throwsArgumentError,
    );
  });

  test(
    'bounded admission supports cancellation and stop without transfer',
    () async {
      final file = journal();
      final barrier = await PluginControlSocket.bind(suite.scratchDirectory);
      late PluginHost first;
      final delivery = PluginDelivery(
        createHost: (_) => first = host(file, barrier: barrier),
        policy: PluginDeliveryPolicy(
          maxPendingEvents: 1,
          ackProgressTimeout: const Duration(seconds: 10),
        ),
      );
      final acknowledged = <String>{};
      try {
        await delivery.start();
        await healthy(first);
        observe(await delivery.admit(pluginDeliveryEvent(1)), acknowledged);
        await barrier.waitForBarrier(timeout: const Duration(seconds: 5));
        final cancellation = PluginDeliveryCancellation();
        await expectLater(
          delivery.admit(pluginDeliveryEvent(1)),
          throwsStateError,
        );
        final cancelled = delivery.admit(
          pluginDeliveryEvent(2),
          cancellation: cancellation,
        );
        final cancelledCheck = expectLater(cancelled, throwsStateError);
        cancellation.cancel();
        await cancelledCheck;
        expect(delivery.pendingEventCount, 1);
        final blocked = delivery.admit(pluginDeliveryEvent(3));
        final blockedCheck = expectLater(blocked, throwsStateError);
        await delivery.stop();
        await blockedCheck;
        expect(acknowledged, isEmpty);
      } finally {
        await delivery.stop();
        await barrier.dispose();
      }
    },
  );

  test(
    'pending byte capacity blocks admission independently of event count',
    () async {
      final file = journal();
      final barrier = await PluginControlSocket.bind(suite.scratchDirectory);
      final event = pluginDeliveryEvent(1);
      final limit = event.toJsonBytes().length;
      late PluginHost first;
      final delivery = PluginDelivery(
        createHost: (_) => first = host(file, barrier: barrier),
        policy: PluginDeliveryPolicy(
          maxPendingEvents: 4,
          maxPendingBytes: limit,
        ),
      );
      final acknowledged = <String>{};
      try {
        await delivery.start();
        await healthy(first);
        observe(await delivery.admit(event), acknowledged);
        await barrier.waitForBarrier(timeout: const Duration(seconds: 5));
        final cancellation = PluginDeliveryCancellation();
        final waiting = delivery.admit(
          pluginDeliveryEvent(2),
          cancellation: cancellation,
        );
        final rejected = expectLater(waiting, throwsStateError);
        cancellation.cancel();
        await rejected;
        expect(delivery.pendingEventCount, 1);
        expect(delivery.pendingBytes, limit);
        expect(acknowledged, isEmpty);
      } finally {
        await delivery.stop();
        await barrier.dispose();
      }
    },
  );

  test(
    'single event over the encoded batch limit is rejected before admission',
    () async {
      final file = journal();
      late PluginHost first;
      final delivery = PluginDelivery(
        createHost: (_) => first = host(file),
        policy: PluginDeliveryPolicy(maxBatchBytes: 16),
      );
      try {
        await delivery.start();
        await healthy(first);
        await expectLater(
          delivery.admit(pluginDeliveryEvent(1)),
          throwsArgumentError,
        );
        expect(delivery.pendingEventCount, 0);
        expect(delivery.pendingBytes, 0);
      } finally {
        await delivery.stop();
      }
    },
  );

  test(
    'progressing stream survives beyond its acknowledgement deadline',
    () async {
      final file = journal();
      late PluginHost first;
      final delivery = PluginDelivery(
        createHost: (_) => first = host(file),
        policy: PluginDeliveryPolicy(
          ackProgressTimeout: const Duration(seconds: 1),
        ),
      );
      try {
        await delivery.start();
        await healthy(first);
        final watch = Stopwatch()..start();
        var index = 0;
        do {
          final receipt = await delivery.admit(pluginDeliveryEvent(index++));
          await receipt.acknowledged.timeout(const Duration(seconds: 5));
        } while (watch.elapsed < const Duration(milliseconds: 1500));
        await delivery.drain();
        expect(delivery.isRunning, isTrue);
        expect(index, greaterThan(1));
      } finally {
        await delivery.stop();
      }
    },
  );

  test('batch count and encoded byte bounds hold on the real stream', () async {
    final events = pluginDeliveryEvents(8).toList();
    for (final (countLimit, byteLimit) in [
      (2, 1024 * 1024),
      (64, events.first.toJsonBytes().length * 2 + 128),
    ]) {
      final file = journal();
      late PluginHost first;
      final delivery = PluginDelivery(
        createHost: (_) => first = host(file),
        policy: PluginDeliveryPolicy(
          maxBatchEvents: countLimit,
          maxBatchBytes: byteLimit,
        ),
      );
      try {
        await delivery.start();
        await healthy(first);
        final receipts = await Future.wait(
          events.map((event) => delivery.admit(event)),
        );
        await Future.wait(receipts.map((receipt) => receipt.acknowledged));
        await delivery.drain();
        final byId = {for (final event in events) event.event.eventId: event};
        final batches = <String, List<PluginJournalRecord>>{};
        for (final record in readPluginJournal(file)) {
          batches
              .putIfAbsent('${record.epoch}:${record.sequence}', () => [])
              .add(record);
        }
        expect(
          batches.values.fold<int>(0, (total, batch) => total + batch.length),
          events.length,
        );
        for (final batch in batches.values) {
          expect(batch.length, lessThanOrEqualTo(countLimit));
          final request = wire.DeliverRequest(
            epoch: batch.first.epoch,
            sequence: Int64(batch.first.sequence),
            events: batch.map(
              (record) => wire.Event(
                eventId: record.id,
                canonicalJson: byId[record.id]!.toJsonBytes(),
              ),
            ),
          );
          expect(request.writeToBuffer().length, lessThanOrEqualTo(byteLimit));
        }
      } finally {
        await delivery.stop();
      }
    }
  });

  test(
    'diagnostic flood drains without blocking and retains a bounded tail',
    () async {
      final plugin = host(
        journal(),
        startup: PluginFixtureStartupMode.diagnosticFlood,
      );
      try {
        await plugin.start();
        fail('diagnostic fixture must reject its malformed handshake');
      } on PluginStartupException catch (error) {
        expect(
          error.diagnostics.length,
          lessThanOrEqualTo(pluginDiagnosticTailBytes + 128),
        );
        expect(
          error.cause,
          isA<FormatException>(),
          reason:
              'the handshake follows the complete stderr flood, not a blocked-pipe timeout',
        );
        expect(await File('/proc/${plugin.childPid}/stat').exists(), isFalse);
      } finally {
        await plugin.stop();
      }
    },
  );

  test(
    'post-handshake stdout and stderr flooding does not block delivery',
    () async {
      final file = journal();
      final delivery = PluginDelivery(
        createHost: (_) => host(
          file,
          startup: PluginFixtureStartupMode.diagnosticFloodAfterHandshake,
        ),
      );
      try {
        await delivery.start();
        final event = pluginDeliveryEvent(0);
        final receipt = await delivery.admit(event);
        await Future.any<void>([
          receipt.acknowledged,
          delivery.whenFailed.then<void>((cause) => throw cause),
        ]).timeout(const Duration(seconds: 15));
        final record = readPluginJournal(file).single;
        expect(record.id, event.event.eventId);
        expect(record.sha256, sha256.convert(event.toJsonBytes()).toString());
        expect(delivery.pendingEventCount, 0);
      } finally {
        await delivery.stop();
      }
    },
  );

  test('journal rejects torn, oversized and invalid records', () async {
    final file = journal();
    file.writeAsStringSync('{"id":"torn"}');
    expect(() => readPluginJournal(file), throwsFormatException);
    file.writeAsStringSync(
      '${jsonEncode({'id': 'x', 'sha256': 'z' * 64, 'epoch': 'e', 'sequence': 1})}\n',
    );
    expect(() => readPluginJournal(file), throwsFormatException);
    final handle = file.openSync(mode: FileMode.write);
    try {
      handle.truncateSync(pluginJournalMaxBytes + 1);
    } finally {
      handle.closeSync();
    }
    expect(() => readPluginJournal(file), throwsStateError);
  });
}
