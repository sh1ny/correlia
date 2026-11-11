import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import 'alert_state_test.dart' as support;
import 'pipeline_test.dart' as pipeline;

void main() {
  withServerpod(
    'activity ledger',
    (builder, _) {
      setUp(() async => support.reset(builder.build()));

      test('firing_then_resolved_writes_two_entries', () async {
        final s = builder.build();
        await support.deliver(s, [
          support.firing('2026-11-10T11:59:00Z'),
        ], support.base);
        await support.deliver(s, [
          support.recovery('2026-11-10T11:59:00Z', '2026-11-10T12:00:00Z'),
        ], support.base.add(const Duration(seconds: 1)));
        final ledger = await support.rows(
          s,
          'SELECT entity_id,entity_version,change_kind,actor_kind,cause_event_id::text AS event_id,cause_raw_id::text AS raw_id FROM activity ORDER BY id',
        );
        expect(ledger, hasLength(2));
        expect(ledger.map((e) => e['entity_version']), [1, 2]);
        expect(ledger.map((e) => e['change_kind']), ['created', 'resolved']);
        expect(ledger.map((e) => e['actor_kind']), everyElement('pipeline'));
        final events = await support.rows(
          s,
          'SELECT event_id::text AS event_id,raw_id::text AS raw_id FROM events ORDER BY observed_at',
        );
        expect(
          ledger.map((e) => e['event_id']),
          events.map((e) => e['event_id']),
        );
        expect(ledger.map((e) => e['raw_id']), events.map((e) => e['raw_id']));
        expect(ledger.first['entity_id'], ledger.last['entity_id']);
      });

      test('rolled_back_change_leaves_no_entry', () async {
        final s = builder.build();
        await pipeline.seed(s, [
          support.firing('2026-11-10T11:59:00Z'),
        ], observed: support.base);
        final repo = PipelineRepository(s, clock: () => support.base);
        await repo.pinOne();
        await s.db.unsafeSimpleExecute(
          "CREATE FUNCTION activity_test_reject() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN RAISE EXCEPTION 'test failure' USING ERRCODE='40001'; END \$\$",
        );
        await s.db.unsafeSimpleExecute(
          'CREATE TRIGGER activity_test_reject BEFORE INSERT ON outbox FOR EACH ROW EXECUTE FUNCTION activity_test_reject()',
        );
        try {
          await repo.processOne();
          expect(await pipeline.count(s, 'activity'), 0);
          expect(await pipeline.count(s, 'alerts'), 0);
        } finally {
          await s.db.unsafeSimpleExecute(
            'DROP TRIGGER activity_test_reject ON outbox',
          );
          await s.db.unsafeSimpleExecute(
            'DROP FUNCTION activity_test_reject()',
          );
        }
        await s.db.unsafeSimpleExecute(
          'UPDATE raw_inbox SET next_attempt_at=NULL',
        );
        await repo.processOne();
        expect(await pipeline.count(s, 'activity'), 1);
        expect(await pipeline.count(s, 'alerts'), 1);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
