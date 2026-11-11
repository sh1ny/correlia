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
import 'support/plugin_delivery_observer.dart';
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
    final observation = await observeDeliveryWithheld(suite);
    expect(observation.facts['credit_limit'], 2);
    expect(
      observation.facts['accepted_unacknowledged_batches'],
      inInclusiveRange(1, 2),
    );
    expect(observation.facts['retained_events_after_timeout'], 6);
    expect(observation.facts['available_credits'], 0);
    expect(observation.facts['acknowledged_count'], 0);
  });

  test(
    'invalid acknowledgements cannot complete work or create credits',
    () async {
      final facts = (await observeDeliveryInvalidAck(suite)).facts;
      for (final mode in ['invalid-epoch', 'invalid-sequence']) {
        expect(facts['${mode}_acknowledged'], 0);
        expect(facts['${mode}_pending'], 2);
        expect(facts['${mode}_credits'], 0);
      }
      expect(facts['duplicate_acknowledged'], 1);
      expect(facts['duplicate_credits'], 0);
    },
  );

  test('stalled receiver times out retaining outstanding work', () async {
    final facts = (await observeDeliveryStalled(suite)).facts;
    final event = pluginDeliveryEvent(42);
    expect(facts['pending_count'], 1);
    expect(facts['pending_id'], event.event.eventId);
    expect(
      facts['pending_sha256'],
      sha256.convert(event.toJsonBytes()).toString(),
    );
    expect(facts['available_credits'], 0);
    expect(facts['acknowledged_count'], 0);
  });

  test('10000 events reconcile after pre-ack plugin crash', () async {
    final facts = (await observeDeliveryReconciliation(suite)).facts;
    expect(facts['reconciled_unique_ids'], 10000);
    expect(facts['acknowledged_before_second_crash'], 10000);
    expect(facts['duplicate_ids'], facts['uncertain_ids']);
    expect(facts['first_barrier_events'], greaterThan(0));
    expect(facts['pending_after_first_crash'], greaterThan(0));
    expect(facts['new_records_after_second_restart'], 1);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('failed restart retains immutable pending events', () async {
    final facts = (await observeDeliveryFailedRestart(suite)).facts;
    final event = pluginDeliveryEvent(7);
    expect(facts['failed'], isTrue);
    expect(facts['pending_count'], 1);
    expect(facts['pending_id'], event.event.eventId);
    expect(
      facts['pending_sha256'],
      sha256.convert(event.toJsonBytes()).toString(),
    );
    expect(facts['acknowledged_count'], 0);
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
        final drainingCheck = expectLater(delivery.drain(), throwsStateError);
        await Future.wait([delivery.stop(), blockedCheck, drainingCheck]);
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
