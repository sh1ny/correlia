import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

const _futureDay = '2030-02-01';
const _otherDay = '2030-02-02';
const _outside = '2030-02-06';

Future<int?> _reserve(Session session, String day, DateTime now) async =>
    (await session.db.unsafeQuery(
          "SELECT correlia_reserve_partition('raw_inbox',@day::date,@now)",
          parameters: QueryParameters.named({'day': day, 'now': now}),
        )).single[0]
        as int?;

Future<bool> _attach(
  Session session,
  String day,
  int attempt, {
  Transaction? tx,
}) async =>
    (await session.db.unsafeQuery(
          "SELECT correlia_attach_partition('raw_inbox',@day::date,@attempt)",
          parameters: QueryParameters.named({'day': day, 'attempt': attempt}),
          transaction: tx,
        )).single[0]!
        as bool;

Future<bool> _fail(
  Session session,
  String day,
  int attempt,
  DateTime now,
) async =>
    (await session.db.unsafeQuery(
          "SELECT correlia_partition_failed('raw_inbox',@day::date,@attempt,'lock_timeout',@now)",
          parameters: QueryParameters.named({
            'day': day,
            'attempt': attempt,
            'now': now,
          }),
        )).single[0]!
        as bool;

Future<String> _write(Session session, String when) async =>
    (await session.db.unsafeQuery('''
      INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
      VALUES (@when::timestamptz,gen_random_uuid(),gen_random_uuid(),decode('01','hex'),
        'digest','application/json','done') RETURNING tableoid::regclass::text
    ''', parameters: QueryParameters.named({'when': '$when UTC'}))).single[0]!
        as String;

Future<int> _retries(Session session) async =>
    (await session.db.unsafeQuery(
          'SELECT count(*) FROM pipeline_partition_retry',
        )).single[0]!
        as int;

void main() {
  withServerpod(
    'daily partition preparation',
    (builder, _) {
      test(
        'default_validation_timeout_records_retry_without_blocking_writes',
        () async {
          final session = builder.build();
          await initializeIngestSchema(session);
          final now = DateTime.utc(2030, 1, 30);
          expect(await _write(session, _otherDay), 'raw_inbox_default');
          expect(await _write(session, _outside), 'raw_inbox_default');
          final attempt = (await _reserve(session, _futureDay, now))!;
          await expectLater(
            session.db.transaction((tx) async {
              expect(
                await _attach(session, _futureDay, attempt, tx: tx),
                isTrue,
              );
              // Force an error after the real attachment, before its commit.
              await session.db.unsafeQuery('SELECT 1/0', transaction: tx);
            }),
            throwsA(isA<DatabaseQueryException>()),
          );
          expect(await _fail(session, _futureDay, attempt, now), isTrue);
          expect(await _retries(session), 1);
          expect(await _reserve(session, _futureDay, now), isNull);
          final occupied = (await _reserve(session, _otherDay, now))!;
          expect(await _attach(session, _otherDay, occupied), isFalse);
          expect(await _write(session, _outside), 'raw_inbox_default');
          final restarted = builder.build();
          final next = (await _reserve(
            restarted,
            _futureDay,
            now.add(const Duration(minutes: 10)),
          ))!;
          expect(next, greaterThan(attempt));
          expect(await _attach(restarted, _futureDay, next), isTrue);
          expect(await _write(session, _futureDay), 'raw_inbox_20300201');
          expect(await _write(session, _otherDay), 'raw_inbox_default');
        },
      );

      test('late_attach_failure_cannot_replace_success', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        const day = '2030-03-01';
        final now = DateTime.utc(2030, 2, 27);
        final first = (await _reserve(session, day, now))!;
        await expectLater(
          session.db.transaction((tx) async {
            expect(await _attach(session, day, first, tx: tx), isTrue);
            await session.db.unsafeQuery('SELECT 1/0', transaction: tx);
          }),
          throwsA(isA<DatabaseQueryException>()),
        );
        final successor = builder.build();
        final next = (await _reserve(
          successor,
          day,
          now.add(const Duration(minutes: 10)),
        ))!;
        expect(await _attach(successor, day, next), isTrue);
        expect(await _fail(session, day, first, now), isFalse);
        expect(await _reserve(session, day, now), isNull);
        expect(await _write(session, day), 'raw_inbox_20300301');
        expect(
          (await session.db.unsafeQuery(
            "SELECT count(*) FROM pipeline_partition_retry WHERE day='$day'",
          )).single[0],
          0,
        );
      });

      test('eligible_closed_partition_drops', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        const day = '2020-04-01';
        final now = DateTime.utc(2020, 3, 31);
        expect(
          await _attach(session, day, (await _reserve(session, day, now))!),
          isTrue,
        );
        expect(await _write(session, day), 'raw_inbox_20200401');
        expect(
          (await session.db.unsafeQuery(
            "SELECT correlia_drop_old_partition('raw_inbox','2020-10-01')",
          )).single[0],
          isTrue,
        );
        expect(
          (await session.db.unsafeQuery(
            "SELECT to_regclass('raw_inbox_20200401')::text",
          )).single[0],
          isNull,
        );
        expect(
          (await session.db.unsafeQuery(
            "SELECT to_regclass('raw_inbox_default')::text",
          )).single[0],
          'raw_inbox_default',
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
