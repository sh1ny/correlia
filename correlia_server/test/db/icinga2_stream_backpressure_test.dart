import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/read_timing.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/redaction.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/stream_reader.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_decode_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/stream_reader_clock.dart';

void main() {
  withServerpod(
    'stream reader with actual fenced admission',
    (builder, _) {
      late Session session;
      late String snapshot;
      late StreamLease lease;
      late ConsumerAdmission repository;
      late StreamReaderClock clock;
      final now = streamDbNow;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute(
          'TRUNCATE icinga2_stream_lease,icinga2_admitted_batch,icinga2_stream_resync',
        );
        snapshot = await publishStreamDb(session);
        final db = await openStreamDatabase(session.serverpod);
        addTearDown(db.close);
        lease = (await StreamLeaseStore(
          db,
        ).acquire(icinga2DbSourceId, 'batch-test'))!;
        repository = ConsumerAdmission(db);
        clock = StreamReaderClock();
      });

      StreamReader reader({
        String password = 'not-in-fixtures',
        void Function(StreamAdmissionResult)? observed,
      }) {
        return StreamReader(
          request: streamDecodeRequest(''),
          policy: StreamStateTypePolicy.softAndHard,
          redactor: PasswordRedactor(utf8.encode(password)),
          connectionId: 'f2f2f2f2-1111-4222-8333-444444444444',
          receiptClock: () => now,
          monotonic: () => clock.elapsed,
          schedule: clock.schedule,
          onOversize: () async {},
          admit: (batch) async {
            final result = await repository.admit(
              lease: lease,
              snapshotId: snapshot,
              batch: batch,
            );
            observed?.call(result);
            return result;
          },
        );
      }

      Future<void> seed(int count, String status) => session.db.unsafeExecute(
        '''
      INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
      SELECT @observed,gen_random_uuid(),'$icinga2DbSourceId',decode('00','hex'),'seed','application/json',@status
      FROM generate_series(1,@count)
    ''',
        parameters: QueryParameters.named({
          'observed': now,
          'status': status,
          'count': count,
        }),
      );

      Stream<List<int>> input(String wire) => Stream.value(utf8.encode(wire));
      String check() =>
          jsonEncode(streamDbCheck(now.subtract(const Duration(seconds: 1))));

      test('failures_accumulate', () async {
        await seed(99, 'failed');
        expect(await reader().run(input('{malformed\n')), StreamReadEnd.eof);
        await processIcinga2(session, now);
        expect(await repository.retained(icinga2DbSourceId, limit: 101), 100);
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) FROM raw_inbox WHERE status='failed'",
          )).single[0],
          100,
        );
        final blocked = Completer<void>();
        final reading = reader(
          observed: (result) {
            expect(result, StreamAdmissionResult.atCapacity);
            if (!blocked.isCompleted) blocked.complete();
          },
        ).run(input('${check()}\n'));
        await blocked.future;
        clock.advance(const Duration(seconds: 30));
        expect(await reading, StreamReadEnd.backpressure);
        expect(await countRows(session, 'raw_inbox'), 100);
      });

      test('stream_source_pauses_at_retained_work_cap', () async {
        await seed(100, 'pending');
        final paused = Completer<void>();
        final retried = Completer<void>();
        final retries = <StreamAdmissionResult>[];
        final running = reader(
          observed: (result) {
            retries.add(result);
            if (retries.length == 1) paused.complete();
          },
        ).run(input('${check()}\n'));
        clock.onSchedule = (delay) {
          if (delay == const Duration(seconds: 1) && !retried.isCompleted) {
            retried.complete();
          }
        };
        await paused.future;
        await retried.future;
        await session.db.unsafeExecute('''UPDATE raw_inbox SET status='done'
        WHERE raw_id=(SELECT raw_id FROM raw_inbox LIMIT 1)''');
        clock.advance(const Duration(seconds: 1));
        expect(await running, StreamReadEnd.eof);
        expect(retries, [
          StreamAdmissionResult.atCapacity,
          StreamAdmissionResult.committed,
        ]);
        expect(await repository.retained(icinga2DbSourceId, limit: 101), 100);
        expect(await countRows(session, 'icinga2_admitted_batch'), 1);
      });

      test('unsubscribed_type_is_admitted_alone', () async {
        final valid = check();
        final unsupported = (jsonDecode(valid) as Map<String, Object?>)
          ..['type'] = 'CheckResult';
        final end = await reader().run(
          input('$valid\n${jsonEncode(unsupported)}\n'),
        );
        expect(end, StreamReadEnd.eof);
        expect(await countRows(session, 'raw_inbox'), 2);
        await processIcinga2(session, now);
        await processIcinga2(session, now);
        expect(await countRows(session, 'events'), 1);
        expect(
          await queryRows(
            session,
            'SELECT "errorClass","fieldPath" FROM pipeline_failures',
          ),
          [
            {'errorClass': 'unsupported_type', 'fieldPath': 'type'},
          ],
        );
      });

      test('redaction_keeps_original_invalid_json', () async {
        final ack = capturedStreamEvents(
          streamCaptures.last,
        ).firstWhere((event) => event['type'] == 'AcknowledgementSet');
        final line = jsonEncode({
          ...ack,
          'comment': 'wire-placeholder',
        }).replaceFirst('wire-placeholder', 'a\tb');
        expect(
          await reader(password: '\t').run(input('$line\n${check()}\n')),
          StreamReadEnd.eof,
        );
        final bodies = await queryRows(session, 'SELECT body FROM raw_inbox');
        expect(bodies, hasLength(2));
        final items = bodies.map((row) {
          final envelope =
              jsonDecode(utf8.decode(row['body']! as List<int>))
                  as Map<String, Object?>;
          return (envelope['items']! as List<Object?>).single!
              as Map<String, Object?>;
        });
        final malformed = items.singleWhere(
          (item) => item['invalid_json'] == true,
        );
        expect(malformed['redacted'], isTrue);
        final retained = malformed['line']! as String;
        expect(retained, isNot(contains('\t')));
        expect(jsonDecode(retained), isA<Map<String, Object?>>());
        await processIcinga2(session, now);
        await processIcinga2(session, now);
        expect(
          await queryRows(
            session,
            'SELECT "errorClass" FROM pipeline_failures',
          ),
          [
            {'errorClass': 'invalid_json'},
          ],
        );
        expect(await countRows(session, 'events'), 1);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
