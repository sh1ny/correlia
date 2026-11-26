import 'dart:async';

import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;
import '../support/postgres_lock_witness.dart' show ContentionGate;
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' as fixture;

final _now = DateTime.utc(2026, 11, 25);
const _other = '11111111-aaaa-4aaa-8aaa-111111111111';

Future<void> _seed(
  Session session,
  String source,
  int count, {
  String code = 'invalid_json',
}) => session.db.unsafeSimpleExecute('''
      WITH inserted AS (
        INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
        SELECT '2026-11-10 UTC',gen_random_uuid(),'$source',decode('ff','hex'),'digest','application/json','failed'
        FROM generate_series(1,$count) RETURNING observed_at,raw_id,source_id
      ) SELECT correlia_record_raw_failure(observed_at,raw_id,source_id,NULL,'$code',NULL,'2026-11-24 UTC')
        FROM inserted
    ''');

void main() {
  withServerpod(
    'dead letter selection and replay',
    (builder, _) {
      late Session session;
      late QueueOperations operations;
      QueueOperations repo(
        Session connection, {
        Future<void> Function()? beforeWorkLock,
      }) => QueueOperations(
        connection,
        secretStore: testSecretStore,
        clock: () => _now,
        beforeWorkLockForTest: beforeWorkLock,
      );
      QueueFailureFilter filter({
        String? scope = fixture.sourceId,
        String? error,
      }) => QueueFailureFilter(
        kind: QueueFailureKind.raw,
        scopeId: scope,
        errorClass: error,
      );
      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(fixture.input(1));
        operations = repo(session);
      });

      test('equal_times_and_invalid_filter_cursor', () async {
        await _seed(session, fixture.sourceId, 3);
        final first = await operations.list(filter(), limit: 2);
        final second = await operations.list(
          filter(),
          limit: 2,
          cursor: first.continuation,
        );
        final ids = [
          ...first.failures,
          ...second.failures,
        ].map((row) => row.occurrence).toList();
        expect(ids, hasLength(3));
        expect(ids.toSet(), hasLength(3));
        expect(ids, orderedEquals([...ids]..sort()));
        expect(second.continuation, isNull);
        for (final call in [
          () => operations.list(filter(scope: 'unknown')),
          () => operations.list(
            filter(scope: _other),
            cursor: first.continuation,
          ),
          () => operations.list(filter(), limit: 101),
        ]) {
          await expectLater(call(), throwsA(isA<QueueOperatorException>()));
        }
      });

      test('sparse_filter_pages_use_matching_index', () async {
        await _seed(session, _other, 500);
        await _seed(session, fixture.sourceId, 500, code: 'body_bound');
        await _seed(session, fixture.sourceId, 3);
        await session.db.unsafeExecute('ANALYZE pipeline_dead_letter');
        final page = await operations.list(
          filter(error: 'invalid_json'),
          limit: 2,
        );
        final last = await operations.list(
          filter(error: 'invalid_json'),
          limit: 2,
          cursor: page.continuation,
        );
        expect(page.failures, hasLength(2));
        expect(last.failures, hasLength(1));
        expect(last.continuation, isNull);
        final plan = await session.db.unsafeQuery('''EXPLAIN
        SELECT occurrence_id FROM pipeline_dead_letter
        WHERE kind='raw' AND scope_id='${fixture.sourceId}' AND error_class='invalid_json'
        ORDER BY failed_at,occurrence_id LIMIT 3
      ''');
        expect(
          plan.map((row) => row[0]).join('\n'),
          contains('pipeline_dead_letter_scope_class_idx'),
        );
      });

      test('filtered_replay_batches_report_and_audit', () async {
        await _seed(session, fixture.sourceId, 3);
        await _seed(session, _other, 4);
        final page = await operations.replayBatch(filter(), 'demo', limit: 2);
        expect((page.queued, page.refused), (2, 0));
        final remaining = await operations.replayBatch(
          filter(),
          'demo',
          limit: 2,
          cursor: page.continuation,
        );
        expect(
          (remaining.queued, remaining.refused, remaining.continuation),
          (1, 0, null),
        );
        expect(
          page.items.map((i) => i.occurrence),
          isNot(contains(remaining.items.single.occurrence)),
        );
        final state = await session.db.unsafeQuery(
          'SELECT status,count(*) FROM raw_inbox GROUP BY status',
        );
        expect(
          {for (final row in state) row[0]: row[1]},
          {'pending': 3, 'failed': 4},
        );
        final audit = await session.db.unsafeQuery(
          "SELECT actor_ref,entity_version FROM activity WHERE change_kind='dead_letter_replayed' ORDER BY id",
        );
        expect(audit.map((r) => r.toList()), [
          ['demo', 2],
          ['demo', 1],
        ]);
      });

      test('replay_and_expiry_lock_one_occurrence', () async {
        await _seed(session, fixture.sourceId, 1);
        final occurrence = (await operations.list(
          filter(),
        )).failures.single.occurrence;
        final selected = Completer<void>();
        final gate = ContentionGate();
        final stale = gate.run(
          () => repo(
            builder.build(),
            beforeWorkLock: () async {
              selected.complete();
              await gate.future;
            },
          ).replayOne(QueueFailureKind.raw, occurrence, 'stale'),
        );
        await selected.future;
        expect(
          (await operations.replayOne(
            QueueFailureKind.raw,
            occurrence,
            'winner',
          )).queued,
          1,
        );
        await gate.join();
        expect((await stale).items.single.outcome, 'not_active');
        await _seed(session, fixture.sourceId, 1);
        final expiring = (await operations.list(
          filter(),
        )).failures.single.occurrence;
        var checkAt = _now;
        final atBoundary = QueueOperations(
          session,
          clock: () => checkAt,
          beforeWorkLockForTest: () async {
            checkAt = DateTime.utc(2026, 12, 8);
          },
        );
        expect(
          (await atBoundary.replayOne(
            QueueFailureKind.raw,
            expiring,
            'past-boundary',
          )).items.single.outcome,
          'expired',
        );
        await session.db.unsafeQuery(
          "SELECT correlia_maintain('expiry','2027-01-01 UTC',5)",
        );
        expect(
          (await operations.replayOne(
            QueueFailureKind.raw,
            expiring,
            'after-expiry',
          )).queued,
          0,
        );
        final actor = await session.db.unsafeQuery(
          "SELECT actor_ref FROM activity WHERE change_kind='dead_letter_replayed'",
        );
        expect(actor.single[0], 'winner');
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
