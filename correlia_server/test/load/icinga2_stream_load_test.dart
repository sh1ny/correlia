@Tags(['load'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/batcher.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/read_timing.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/redaction.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/status.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/stream_reader.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_child.dart';
import '../support/icinga2_stream_decode_fixture.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/secret_fixture.dart';

const _subscription = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';

void main() {
  withServerpod(
    'full Event Streams row under the routing ceiling',
    (builder, _) {
      test('worst_case_fanout', () async {
        final session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute(
          'TRUNCATE icinga2_stream_lease, icinga2_stream_status, icinga2_admitted_batch',
        );
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final outputs = List.generate(
          8,
          (i) => '66666666-6666-4666-8666-66666666666$i',
        );
        Future<String> publish(int revision, int routes) async {
          final source = streamSource(icinga2DbSourceId)
            ..['output_ids'] = outputs.take(routes).toList();
          final config = streamBootstrap(revision, [source])
            ..['outputs'] = [
              for (final (i, output) in outputs.take(routes).indexed)
                {
                  'id': output,
                  'kind': 'webhook',
                  'url': 'http://127.0.0.1:9191/$i',
                  'signing_key_ref': 'load-signing-key',
                },
            ];
          return (await repository.publishConfig(config, {
            ...streamMaterial(),
            'load-signing-key': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE',
          }, runMode: 'test')).snapshotId;
        }

        final admissionSnapshot = await publish(1, 1);
        final connection = await openStreamDatabase(session.serverpod);
        addTearDown(connection.close);
        final lease = (await StreamLeaseStore(
          connection,
        ).acquire(icinga2DbSourceId, 'load-fanout'))!;
        expect(
          await StreamStatusStore(
            connection,
          ).startConnection(lease, _subscription),
          1,
        );
        final store = ConsumerAdmission(connection);
        final now = DateTime.now().toUtc();
        final request = streamDecodeRequest('');
        final output =
            '🛰' *
            4096; // Four-byte scalars at the maximum canonical description length.
        final base = streamDbCheck(now);
        final input = StringBuffer();
        for (var i = 0; i < streamItemsPerRow; i++) {
          input.writeln(
            jsonEncode({
              ...base,
              'service': 'worst-$i',
              'check_result': {
                ...base['check_result']! as Map<String, Object?>,
                'output': output,
              },
            }),
          );
        }
        final reader = StreamReader(
          request: request,
          policy: StreamStateTypePolicy.softAndHard,
          redactor: PasswordRedactor(utf8.encode('not-the-test-payload')),
          connectionId: _subscription,
          admit: (batch) => store.admit(
            lease: lease,
            snapshotId: admissionSnapshot,
            batch: batch,
          ),
          onOversize: () async =>
              fail('Maximum canonical description must fit one valid line'),
        );
        expect(
          await reader.run(Stream.value(utf8.encode(input.toString()))),
          StreamReadEnd.eof,
        );
        final rows = await countRows(session, 'raw_inbox');
        expect(rows, greaterThan(1));
        expect(await countRows(session, 'events'), 0);
        final routesSnapshot = await publish(2, 8);

        final pipeline = PipelineRepository(session);
        var maxMicros = 0;
        for (var i = 0; i < rows; i++) {
          expect(await pipeline.pinOne(), isTrue);
          final time = Stopwatch()..start();
          expect(await pipeline.processOne(), isTrue);
          time.stop();
          expect(
            time.elapsed,
            lessThan(pipelineRowDeadline),
            reason: 'Claimed row $i',
          );
          if (time.elapsedMicroseconds > maxMicros) {
            maxMicros = time.elapsedMicroseconds;
          }
        }
        expect(await countRows(session, 'pipeline_failures'), 0);
        expect(await countRows(session, 'events'), streamItemsPerRow);
        expect(await countRows(session, 'outbox'), streamItemsPerRow * 8);
        final largest =
            (await session.db.unsafeQuery(
                  '''
          SELECT max(fanout)::bigint FROM (
            SELECT sum(octet_length(e.payload)) * 9 AS fanout
            FROM events e WHERE e.config_snapshot_id=@snapshot GROUP BY e.raw_id
          ) AS batches
        ''',
                  parameters: QueryParameters.named({
                    'snapshot': routesSnapshot,
                  }),
                )).single.single!
                as int;
        expect(largest, lessThanOrEqualTo(streamFanoutBudget));
        stdout.writeln(
          jsonEncode({
            'icinga2_fanout': {
              'rows': rows,
              'events': streamItemsPerRow,
              'deliveries': streamItemsPerRow * 8,
              'largest_fanout_bytes': largest,
              'longest_row_us': maxMicros,
            },
          }),
        );
      }, timeout: const Timeout(Duration(minutes: 3)));
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['load'],
  );

  test('sustained_full_input_drain_rate', () async {
    final fixture = await Icinga2StreamChild.create();
    await fixture.start(role: 'worker', revision: 1);
    await fixture.waitState('connected');
    final socket = fixture.upstream.subscriptions.single;
    final template = streamDbCheck(DateTime.now().toUtc());
    final check = template['check_result']! as Map<String, Object?>;
    final window = Stopwatch()..start();
    var sent = 0;
    var done = false;
    final producer = () async {
      while (!done) {
        final lines = StringBuffer();
        final time = DateTime.now().microsecondsSinceEpoch / 1000000;
        for (var i = 0; i < 100; i++) {
          lines.writeln(
            jsonEncode({
              ...template,
              'timestamp': time,
              'service': 'load-${sent++ % 4096}',
              'check_result': {
                ...check,
                'execution_start': time,
                'execution_end': time,
              },
            }),
          );
        }
        socket.write(lines.toString());
        await socket.flush();
      }
    }();
    // Measure two wall-clock boundaries while the producer continues without pacing.
    final midpoint = Completer<void>();
    final end = Completer<void>();
    final first = Timer(const Duration(minutes: 5), midpoint.complete);
    final last = Timer(const Duration(minutes: 10), end.complete);
    try {
      await Future.any([midpoint.future, producer]);
      final before = await fixture.count('events');
      final measuredFrom = window.elapsedMicroseconds;
      await Future.any([end.future, producer]);
      final after = await fixture.count('events');
      final measuredUs = window.elapsedMicroseconds - measuredFrom;
      expect(after, greaterThan(before));
      expect(sent, greaterThanOrEqualTo(after));
      final state = (await fixture.db.execute(
        'SELECT state, "gapCount", "connectionSeq" FROM icinga2_stream_status',
      )).single;
      // A full-input sample can land in a normal high-watermark pause.
      expect(state[0], anyOf('connected', 'paused'));
      expect(state[1], 0);
      expect(state[2], 1);
      expect(await fixture.count('pipeline_failures'), 0);
      stdout.writeln(
        jsonEncode({
          'icinga2_sustained': {
            'sent': sent,
            'events_at_midpoint': before,
            'events_at_end': after,
            'window_seconds': measuredUs / 1000000,
            'drain_events_per_second': (after - before) * 1000000 / measuredUs,
            'gap_count': state[1],
            'final_consumer_state': state[0],
          },
        }),
      );
    } finally {
      done = true;
      first.cancel();
      last.cancel();
      await producer;
    }
  }, timeout: const Timeout(Duration(minutes: 13)));
}
