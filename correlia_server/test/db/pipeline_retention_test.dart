import 'dart:async';

import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/maintenance.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/postgres_lock_witness.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as config;
import 'pipeline_test.dart' as fixture;

final _now = DateTime.utc(2026, 10, 1);
const _source = 'e1000000-0000-4000-8000-000000000001';
const _output = 'e2000000-0000-4000-8000-000000000001';
const _otherOutput = 'e2000000-0000-4000-8000-000000000002';
const _old = '2026-01-01 UTC';
const _oldOutbox = 'outbox_20260101';

String _id(int n) => 'e0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

Future<int> _maintain(
  Session session,
  String lane, {
  int cap = 3,
  DateTime? now,
  Transaction? tx,
}) async =>
    (await session.db.unsafeQuery(
          'SELECT correlia_maintain(@lane,@now,@cap)',
          parameters: QueryParameters.named({
            'lane': lane,
            'now': now ?? _now,
            'cap': cap,
          }),
          transaction: tx,
        )).single[0]!
        as int;

Future<void> _prepareOldPartition(Session session, String parent) async {
  final attempt = (await session.db.unsafeQuery(
    '''SELECT correlia_reserve_partition(@parent,'2026-01-01'::date,'$_old')''',
    parameters: QueryParameters.named({'parent': parent}),
  )).single[0];
  expect(
    (await session.db.unsafeQuery(
      "SELECT correlia_attach_partition(@parent,'2026-01-01'::date,@attempt)",
      parameters: QueryParameters.named({'parent': parent, 'attempt': attempt}),
    )).single[0],
    isTrue,
  );
}

Future<Object?> _dropOldPartition(
  Session session,
  String parent, [
  int pass = 0,
  Transaction? tx,
]) async {
  final now = _now.add(Duration(minutes: pass));
  final reservation = (await session.db.unsafeQuery(
    'SELECT child_name,attempt_id FROM correlia_reserve_drop(@parent,@now)',
    parameters: QueryParameters.named({'parent': parent, 'now': now}),
    transaction: tx,
  )).single;
  return (await session.db.unsafeQuery(
    'SELECT correlia_drop_old_partition(@parent,@child,@attempt,@now)',
    parameters: QueryParameters.named({
      'parent': parent,
      'now': now,
      'child': reservation[0],
      'attempt': reservation[1],
    }),
    transaction: tx,
  )).single[0];
}

Future<void> _raw(Session session, int id, String status) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
    VALUES ('$_old','${_id(id)}','$_source',decode('ff','hex'),'digest','application/json','$status');
  ''');
}

Future<void> _event(Session session, int id) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO events(observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,
      config_snapshot_id,source_time,payload)
    VALUES ('$_old','${_id(id)}','ready','$_old','${_id(99)}','$_source','fixture','$_old',
      convert_to('{"subject":"fixture"}','UTF8'))
  ''');
}

Future<void> _intent(
  Session session,
  int id,
  String status, {
  String? terminal = _old,
  String created = _old,
  String output = _output,
  Transaction? tx,
}) async {
  await session.db.unsafeSimpleExecute(
    '''
    INSERT INTO outbox(created_at,delivery_id,event_observed_at,event_id,event_disposition,
      output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,terminal_at)
    VALUES ('$created','${_id(100 + id)}','$_old','${_id(id)}','ready','$output','fixture',
      'https://example.com','key','commitment',decode('ffaa','hex'),'$status',
      ${terminal == null ? 'NULL' : "'$terminal'"})
  ''',
    transaction: tx,
  );
}

Future<void> _failure(Session session, int id, {String seen = _old}) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO pipeline_failures ("rawObservedAt","rawId","errorClass","createdAt")
    VALUES ('$_old','${_id(id)}','invalid_json','$seen');
    SELECT correlia_record_raw_failure('$_old','${_id(id)}','$_source',NULL,'invalid_json',NULL,'$seen');
    UPDATE raw_inbox SET status='failed' WHERE raw_id='${_id(id)}';
  ''');
}

Future<List<String>> _column(Session session, String sql) async => [
  for (final row in await session.db.unsafeQuery(sql)) row[0]! as String,
];

Future<int> _count(Session session, String table) async =>
    (await session.db.unsafeQuery('SELECT count(*) FROM $table')).single[0]!
        as int;

void main() {
  final cluster = LockWitnessCluster();
  tearDownAll(cluster.close);
  withServerpod(
    'pipeline retention',
    (builder, _) {
      late Session session;
      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute('''
        TRUNCATE raw_inbox,events,outbox,delivery_attempts,activity,pipeline_failures,
          observation_keys,transport_keys,icinga2_raw_origin,pipeline_retention_cursor,
          pipeline_retired_delivery;
        UPDATE raw_admission_cutoff SET cutoff='-infinity';
      ''');
      });

      test('dur_10_retention_keeps_unfinished_work', () async {
        await _prepareOldPartition(session, 'raw_inbox');
        await _raw(session, 1, 'done');
        final active = config.input(1);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(active);
        final received = DateTime.utc(2026, 1, 1);
        for (final name in [
          'pending-through-outage',
          'failed-before-recovery',
        ]) {
          await fixture.seed(session, [
            payload.alert(
              startsAt: received.toIso8601String(),
              labels: {'alertname': name},
            ),
          ], observed: received);
        }
        final worker = PipelineRepository(
          session,
          clock: () => _now,
          elapsedForTest: () => Duration.zero,
        );
        expect(await worker.pinOne(), isTrue);
        expect(await worker.pinOne(), isTrue);
        final failed = (await session.db.unsafeQuery('''
          WITH candidate AS (SELECT raw_id FROM raw_inbox WHERE status='pending' ORDER BY raw_id LIMIT 1),
          failed AS (
            UPDATE raw_inbox SET status='failed' WHERE raw_id=(SELECT raw_id FROM candidate)
            RETURNING observed_at,raw_id,source_id,config_snapshot_id
          )
          SELECT raw_id::text,correlia_record_raw_failure(observed_at,raw_id,source_id,
             config_snapshot_id,'processing_exhausted',NULL,'2026-09-30 UTC')
          FROM failed
        ''')).single[0];
        expect(await _dropOldPartition(session, 'raw_inbox'), isFalse);
        expect(await _maintain(session, 'raw'), 1);
        expect(await _maintain(session, 'expiry'), 0);
        expect(await worker.processOne(), isTrue);
        expect(await _count(session, 'events'), 1);
        expect(
          await _dropOldPartition(session, 'raw_inbox', 1),
          isFalse,
          reason: 'failed work alone protects the child',
        );
        final ops = QueueOperations(
          session,
          clock: () => _now,
          secretStore: testSecretStore,
        );
        final filter = QueueFailureFilter(kind: QueueFailureKind.raw);
        await _maintain(session, 'cutoff');
        final cutoff =
            (await session.db.unsafeQuery(
                  'SELECT cutoff FROM raw_admission_cutoff WHERE singleton=1',
                )).single[0]!
                as DateTime;
        expect(cutoff.isAfter(received), isTrue);
        final receipts = await _count(session, 'transport_keys');
        final failure = (await ops.list(filter)).failures.single;
        expect(failure.workId, failed);
        expect(
          (await ops.replayOne(
            QueueFailureKind.raw,
            failure.occurrence,
            'operator',
          )).queued,
          1,
        );
        final replayed = (await session.db.unsafeQuery('''
          SELECT raw_id::text,observed_at FROM raw_inbox WHERE status='pending'
        ''')).single;
        expect(replayed.toList(), [failed, received]);
        expect(await _count(session, 'raw_inbox'), 2);
        expect(await _count(session, 'transport_keys'), receipts);
        expect(await worker.processOne(), isTrue);
        expect(await _count(session, 'events'), 2);
        expect(
          await _column(
            session,
            'SELECT status FROM raw_inbox ORDER BY raw_id',
          ),
          ['done', 'done'],
        );
        expect((await ops.list(filter)).failures, isEmpty);
        expect(await _dropOldPartition(session, 'raw_inbox', 2), isTrue);
      });

      test('unfinished_outbox_keys_protect_old_events', () async {
        await _prepareOldPartition(session, 'events');
        for (var id = 1; id <= 4; id++) {
          await _event(session, id);
        }
        await _intent(session, 1, 'dead');
        await _intent(session, 2, 'delivering', terminal: null);
        await _intent(session, 3, 'delivered');
        expect(await _dropOldPartition(session, 'events'), isFalse);
        expect(await _maintain(session, 'events', cap: 5), 2);
        expect(
          await _column(
            session,
            'SELECT event_id::text FROM events ORDER BY event_id',
          ),
          [_id(1), _id(2)],
        );
        await session.db.unsafeExecute(
          "UPDATE outbox SET status='delivered' WHERE status='delivering'",
        );
        expect(
          await _dropOldPartition(session, 'events', 1),
          isFalse,
          reason: 'the dead delivery alone protects the child',
        );
        expect(await _maintain(session, 'events', cap: 4), 1);
        expect(await _column(session, 'SELECT event_id::text FROM events'), [
          _id(1),
        ]);
        await session.db.unsafeExecute(
          "UPDATE outbox SET status='delivered' WHERE status='dead'",
        );
        expect(await _dropOldPartition(session, 'events', 2), isTrue);
      });

      test('dur_12_expiry_discards_and_ledgers_atomically', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1);
        await _intent(session, 2, 'dead');
        expect(await _maintain(session, 'expiry'), 2);
        expect(
          await _column(
            session,
            'SELECT status FROM raw_inbox UNION ALL SELECT status FROM outbox',
          ),
          ['discarded', 'discarded'],
        );
        expect(await _count(session, 'pipeline_failures'), 0);
        expect(await _count(session, 'pipeline_dead_letter'), 0);
        final ledger = (await session.db.unsafeQuery(
          "SELECT sum(entity_version)::bigint FROM activity WHERE change_kind='dead_letter_expired'",
        )).single;
        expect(ledger[0], 2);
        expect(await _maintain(session, 'raw'), 1);
      });

      test('publication_extension_fences_expiry', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1);
        await _intent(session, 2, 'dead');
        final publisher = builder.build();
        addTearDown(
          () => session.db.unsafeExecute(
            'UPDATE pipeline_queue_policy SET dead_letter_retention_days=14',
          ),
        );
        final holding = ContentionGate();
        final changed = Completer<void>();
        final publication = holding.run(
          () => publisher.db.transaction((tx) async {
            await publisher.db.unsafeExecute(
              '''SELECT correlia_publish_queue_policy(
              '{"pipeline_operations":{"dead_letter_retention_days":365},"outputs":[]}'::jsonb)''',
              transaction: tx,
            );
            changed.complete();
            await holding.future;
          }),
        );
        await changed.future;
        await expectLater(
          _maintain(session, 'expiry'),
          throwsA(
            isA<DatabaseQueryException>().having(
              (error) => error.code,
              'SQLSTATE',
              '55P03',
            ),
          ),
        );
        await holding.join();
        await publication;
        expect(await _maintain(session, 'expiry'), 0);
        expect(
          await _column(
            session,
            'SELECT status FROM raw_inbox UNION ALL SELECT status FROM outbox',
          ),
          ['failed', 'dead'],
        );
        expect(await _count(session, 'pipeline_dead_letter'), 2);
        expect(await _count(session, 'activity'), 0);
        await session.db.transaction((tx) async {
          expect(
            await _maintain(
              session,
              'expiry',
              now: _now.add(const Duration(days: 365)),
              tx: tx,
            ),
            2,
          );
          await expectLater(
            publisher.db.unsafeQuery(
              'SELECT 1 FROM pipeline_queue_policy WHERE singleton=1 FOR NO KEY UPDATE NOWAIT',
            ),
            throwsA(
              isA<DatabaseQueryException>().having(
                (error) => error.code,
                'SQLSTATE',
                '55P03',
              ),
            ),
          );
        });
      });

      for (final (lane, table, key) in [
        ('expiry', 'raw_inbox', 'raw_id'),
        ('raw', 'raw_inbox', 'raw_id'),
        ('outbox', 'outbox', 'delivery_id'),
        ('transport', 'transport_keys', 'key'),
      ]) {
        test('${lane}_reclamation_skips_locked_page_and_wraps', () async {
          switch (lane) {
            case 'expiry':
              await _raw(session, 1, 'pending');
              await _failure(session, 1);
              await _intent(session, 2, 'dead');
            case 'raw':
              for (final id in [1, 2]) {
                await _raw(session, id, 'done');
              }
            case 'outbox':
              for (final id in [1, 2]) {
                await _intent(session, id, 'delivered');
              }
            case 'transport':
              await session.db.unsafeSimpleExecute('''
                UPDATE raw_admission_cutoff SET cutoff='2026-09-30 UTC';
                INSERT INTO transport_keys ("sourceId",key,"bodySha256","firstSeenAt","expiresAt","rawObservedAt","rawId")
                VALUES ('$_source','first','digest','$_old','2026-09-28','$_old','${_id(1)}'),
                       ('$_source','second','digest','$_old','2026-09-29','$_old','${_id(2)}')
              ''');
          }
          final oldest = switch (lane) {
            'outbox' => _id(101),
            'transport' => 'first',
            _ => _id(1),
          };
          final blocker = builder.build();
          final holding = ContentionGate();
          final locked = Completer<void>();
          final actor = holding.run(
            () => blocker.db.transaction((tx) async {
              expect(
                await blocker.db.unsafeQuery(
                  'SELECT $key FROM $table WHERE $key::text=@key FOR UPDATE',
                  transaction: tx,
                  parameters: QueryParameters.named({'key': oldest}),
                ),
                hasLength(1),
              );
              locked.complete();
              await holding.future;
            }),
          );
          await locked.future;
          expect(await _maintain(session, lane, cap: 1), 0);
          expect(await _maintain(session, lane, cap: 1), 1);
          await holding.join();
          await actor;
          expect(await _maintain(session, lane, cap: 1), 0);
          expect(await _maintain(session, lane, cap: 1), 1);
          if (lane == 'expiry') {
            expect(await _count(session, 'pipeline_dead_letter'), 0);
          } else {
            expect(await _count(session, table), 0);
          }
        });
      }

      test('full_sweep_revisits_retention_lanes_before_idling', () async {
        await session.db.unsafeSimpleExecute('''
          INSERT INTO outbox(created_at,delivery_id,event_observed_at,event_id,event_disposition,
            output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,
            payload,status,terminal_at)
          SELECT now()-interval '15 days',gen_random_uuid(),now(),gen_random_uuid(),'ready',
            '$_output','fixture','https://test.invalid','key','commitment',
            decode('ff','hex'),'delivered',now()-interval '15 days'
          FROM generate_series(1,501);
          INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
          SELECT created_at,delivery_id,1,gen_random_uuid(),created_at,'success' FROM outbox;
        ''');
        const interval = Duration(days: 1);
        final idle = Completer<void>();
        final order = <String>[];
        final worker = PipelineMaintenance(
          openSession: () async => builder.build(),
          log: (_) {},
          interval: interval,
          beforeCommitForTest: (lane) async => order.add(lane),
        );
        try {
          await runZoned(
            worker.start,
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, delay, callback) {
                if (delay >= interval && !idle.isCompleted) idle.complete();
                return parent.createTimer(zone, delay, callback);
              },
            ),
          );
          await idle.future;
          expect(await _count(session, 'outbox'), 0);
          expect(await _count(session, 'delivery_attempts'), 0);
          expect(await _count(session, 'pipeline_retired_delivery'), 0);
          expect(
            order.where({'outbox', 'attempts'}.contains),
            ['outbox', 'attempts', 'outbox', 'attempts'],
          );
        } finally {
          await worker.stop();
        }
      });

      test('maintenance_loop_keeps_failure_until_its_lane_succeeds', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1);
        const interval = Duration(days: 1);
        var idle = Completer<void Function()>();
        var failExpiry = true;
        final worker = PipelineMaintenance(
          openSession: () async => builder.build(),
          log: (_) {},
          interval: interval,
          beforeCommitForTest: (lane) async {
            if (failExpiry && lane == 'expiry') {
              throw StateError('test rollback');
            }
          },
        );
        try {
          await runZoned(
            worker.start,
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, delay, callback) {
                if (delay >= interval) {
                  idle.complete(zone.bindCallback(callback));
                  // The loop's idle timer is driven by the test.
                  return parent.createTimer(zone, delay, () {});
                }
                return parent.createTimer(zone, delay, callback);
              },
            ),
          );
          final nextPass = await idle.future;
          final ops = QueueOperations(session);
          final report = await ops.status();
          expect(report.maintenance!.lane, isNot('expiry'));
          expect(report.maintenance!.outcome, 'ok');
          expect(
            report.maintenanceFailures.map(
              (r) => (r.lane, r.outcome, r.affected),
            ),
            contains(('expiry', 'failed', 0)),
          );
          expect(await _count(session, 'pipeline_dead_letter'), 1);

          failExpiry = false;
          idle = Completer<void Function()>();
          nextPass();
          await idle.future;
          expect(
            (await ops.status()).maintenanceFailures.map((r) => r.lane),
            isNot(contains('expiry')),
          );
          expect(await _count(session, 'pipeline_dead_letter'), 0);
        } finally {
          await worker.stop();
        }
      });

      test('late_sweep_failure_does_not_replace_same_lane_success', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1);
        final gate = ContentionGate();
        final rolledBack = Completer<void>();
        final older = gate.run(
          () => MaintenanceRepository(
            builder.build(),
            beforeCommitForTest: (_) async => throw StateError('test rollback'),
            beforeSweepFailureForTest: () async {
              rolledBack.complete();
              await gate.future;
            },
          ).sweep('expiry'),
        );
        try {
          await Future.any([
            rolledBack.future,
            older.then<void>((_) => fail('Older failure was not parked')),
          ]);
          await MaintenanceRepository(session).sweep('expiry');
          final ops = QueueOperations(session);
          final before = (await ops.status()).maintenance!;
          expect(
            (before.lane, before.outcome, before.affected),
            ('expiry', 'ok', 1),
          );
          expect(await _count(session, 'pipeline_dead_letter'), 0);
          await gate.join();
          await older;
          final after = await ops.status();
          expect(after.maintenance!.toJson(), before.toJson());
          expect(
            after.maintenanceFailures.map((r) => r.lane),
            isNot(contains('expiry')),
          );
        } finally {
          await gate.join();
        }
      });

      test('failed_batch_reports_no_uncommitted_counts', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1);
        final ops = QueueOperations(session);
        await MaintenanceRepository(session).sweep('expiry');
        final committed = (await ops.status()).maintenance!;
        expect(
          (committed.lane, committed.outcome, committed.affected),
          ('expiry', 'ok', 1),
        );

        await _raw(session, 2, 'pending');
        await _failure(session, 2);
        await _intent(session, 3, 'dead');
        await MaintenanceRepository(
          session,
          beforeCommitForTest: (_) async {
            throw StateError('rollback fixture');
          },
        ).sweep('expiry');
        final rolledBack = (await ops.status()).maintenance!;
        expect(
          (rolledBack.lane, rolledBack.outcome, rolledBack.affected),
          ('expiry', 'failed', 0),
        );
        expect(
          await _column(
            session,
            'SELECT status FROM raw_inbox ORDER BY raw_id',
          ),
          ['discarded', 'failed'],
        );
        expect(await _column(session, 'SELECT status FROM outbox'), ['dead']);
        expect(await _count(session, 'pipeline_dead_letter'), 2);
        expect(await _count(session, 'activity'), 1);
      });

      test('reclamation_advances_past_protected_pages', () async {
        for (var id = 1; id <= 7; id++) {
          await _event(session, id);
          if (id < 7) await _intent(session, id, 'queued', terminal: null);
        }
        expect(await _maintain(session, 'events'), 0);
        expect(await _maintain(session, 'events'), 0);
        expect(await _maintain(session, 'events'), 1);
        expect(await _count(session, 'events'), 6);
      });

      Future<void> prepareOldOutbox() async {
        await _prepareOldPartition(session, 'outbox');
        addTearDown(
          () => session.db.unsafeSimpleExecute('''
          TRUNCATE outbox;
          DROP TABLE IF EXISTS $_oldOutbox;
          DELETE FROM pipeline_partition_range WHERE child_name='$_oldOutbox'
        '''),
        );
      }

      test('drained_outbox_drop_does_not_scan_heap', () async {
        await prepareOldOutbox();
        await session.db.unsafeSimpleExecute('''
          ALTER TABLE $_oldOutbox SET (autovacuum_enabled=false);
          INSERT INTO outbox(created_at,delivery_id,event_observed_at,event_id,event_disposition,
            output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,terminal_at)
          SELECT '$_old',gen_random_uuid(),'$_old',gen_random_uuid(),'ready','$_output','fixture',
            'https://example.com','key','commitment',convert_to(repeat(md5(n::text),16),'UTF8'),
            'delivered','$_old' FROM generate_series(1,512) n
        ''');
        expect(await _maintain(session, 'outbox', cap: 500), 500);
        expect(await _maintain(session, 'outbox', cap: 500), 12);
        expect(await _count(session, _oldOutbox), 0);
        expect(
          (await session.db.unsafeQuery(
            "SELECT pg_relation_size('$_oldOutbox')",
          )).single[0],
          greaterThan(128 * 1024),
        );
        await session.db.transaction((tx) async {
          // A reused backend can carry unflushed scans from earlier work.
          final before = (await session.db.unsafeQuery(
            '''
            SELECT (seq_scan+idx_scan)::text FROM pg_stat_xact_user_tables
            WHERE relid='$_oldOutbox'::regclass
            ''',
            transaction: tx,
          )).single[0];
          expect(before, isA<String>());
          await session.db.unsafeSimpleExecute(
            '''
            CREATE FUNCTION test_drop_scans() RETURNS event_trigger AS \$\$
            BEGIN
              PERFORM set_config('correlia.test_drop_scans',(seq_scan+idx_scan)::text,true)
              FROM pg_stat_xact_user_tables WHERE relid='$_oldOutbox'::regclass;
            END
            \$\$ LANGUAGE plpgsql;
            CREATE EVENT TRIGGER test_drop_scans ON ddl_command_start
              WHEN TAG IN ('DROP TABLE') EXECUTE FUNCTION test_drop_scans()
            ''',
            transaction: tx,
          );
          expect(await _dropOldPartition(session, 'outbox', 0, tx), isTrue);
          final scans = (await session.db.unsafeQuery(
            "SELECT current_setting('correlia.test_drop_scans',true)",
            transaction: tx,
          )).single[0];
          expect(scans, before);
          await session.db.unsafeSimpleExecute(
            'DROP EVENT TRIGGER test_drop_scans; DROP FUNCTION test_drop_scans()',
            transaction: tx,
          );
        });
      });

      test('outbox_drop_rechecks_after_concurrent_insert', () async {
        await prepareOldOutbox();
        final writer = builder.build();
        final dropper = builder.build();
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final gate = ContentionGate();
        final written = Completer<LockActor>();
        final aboutToDrop = Completer<LockActor>();
        final holding = gate.run(
          () => writer.db.transaction((tx) async {
            final actor = await pooledLockActor(writer, tx);
            await _intent(writer, 1, 'delivered', tx: tx);
            written.complete(actor);
            await gate.future;
          }),
        );
        try {
          final holder = await Future.any([
            written.future,
            holding.then<LockActor>((_) => fail('Insert was not held')),
          ]);
          final dropping = gate.run(
            () => dropper.db.transaction((tx) async {
              aboutToDrop.complete(
                await pooledLockActor(
                  dropper,
                  tx,
                  waiter: SqlTimeouts.poolDefault,
                ),
              );
              return _dropOldPartition(dropper, 'outbox', 0, tx);
            }),
          );
          final waiter = await Future.any([
            aboutToDrop.future,
            dropping.then<LockActor>((_) => fail('Drop did not wait')),
          ]);
          await witness.blockedBy(
            waiter,
            holder,
            dropping,
            statement: 'correlia_drop_old_partition',
          );
          await gate.join();
          await holding;
          expect(await dropping, isFalse);
          expect(await _count(session, _oldOutbox), 1);
          expect(await _maintain(session, 'outbox'), 1);
          expect(await _dropOldPartition(session, 'outbox', 1), isTrue);
        } finally {
          await gate.join();
        }
      });

      test('outbox_count_and_truncate_are_atomic', () async {
        await prepareOldOutbox();
        await _intent(session, 1, 'delivered');
        await _intent(
          session,
          2,
          'delivered',
          created: '2025-01-01 UTC',
          terminal: '2026-09-30 UTC',
        );
        await session.db.transaction((tx) async {
          final insert = await tx.createSavepoint();
          await _intent(session, 3, 'delivered', tx: tx);
          await insert.rollback();
          final delete = await tx.createSavepoint();
          await session.db.unsafeExecute(
            "DELETE FROM outbox WHERE delivery_id='${_id(101)}'",
            transaction: tx,
          );
          await delete.rollback();
          final truncateParent = await tx.createSavepoint();
          await session.db.unsafeExecute('TRUNCATE outbox', transaction: tx);
          await truncateParent.rollback();
        });
        expect(await _dropOldPartition(session, 'outbox'), isFalse);
        expect(
          await _column(
            session,
            'SELECT delivery_id::text FROM $_oldOutbox ORDER BY delivery_id',
          ),
          [_id(101)],
        );
        expect(
          (await session.db.unsafeQuery('''
            SELECT child_name,stored_rows FROM pipeline_outbox_partition_count ORDER BY child_name
          ''')).map((row) => row.toList()),
          [
            [_oldOutbox, 1],
            ['outbox_default', 1],
          ],
        );
        expect(await _maintain(session, 'outbox'), 1);
        await session.db.unsafeExecute('TRUNCATE $_oldOutbox');
        expect(await _dropOldPartition(session, 'outbox', 1), isTrue);
        expect(await _count(session, 'outbox_default'), 1);
        expect(
          (await session.db.unsafeQuery('''
            SELECT child_name,stored_rows FROM pipeline_outbox_partition_count
          ''')).single.toList(),
          ['outbox_default', 1],
        );
        await session.db.unsafeExecute('TRUNCATE outbox');
        expect(await _count(session, 'pipeline_outbox_partition_count'), 0);
      });

      test('nonempty_outbox_child_cannot_be_truncated', () async {
        await prepareOldOutbox();
        await _intent(session, 1, 'queued', terminal: null);
        await _intent(session, 2, 'dead');
        await _intent(
          session,
          3,
          'queued',
          created: '2025-01-01 UTC',
          terminal: null,
        );
        await expectLater(
          session.db.transaction((tx) async {
            await session.db.unsafeExecute(
              'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ',
              transaction: tx,
            );
            await session.db.unsafeExecute(
              'TRUNCATE $_oldOutbox',
              transaction: tx,
            );
          }),
          throwsA(
            isA<DatabaseQueryException>().having(
              (error) => error.code,
              'SQLSTATE',
              '25000',
            ),
          ),
        );
        for (final child in [_oldOutbox, 'outbox_default']) {
          await expectLater(
            session.db.unsafeExecute('TRUNCATE $child'),
            throwsA(
              isA<DatabaseQueryException>().having(
                (error) => error.code,
                'SQLSTATE',
                '0A000',
              ),
            ),
          );
        }
        expect(await _count(session, 'outbox'), 3);
        expect(await _count(session, 'pipeline_event_reference'), 3);
        expect(await _count(session, 'pipeline_dead_letter'), 1);
        final usage = (await session.db.unsafeQuery('''
          SELECT used_rows,live_rows FROM pipeline_output_capacity WHERE output_id='$_output'
        ''')).single;
        expect(usage.toList(), [3, 2]);
        expect(
          (await session.db.unsafeQuery('''
            SELECT sum(live_count)::bigint FROM pipeline_output_commitment
          ''')).single[0],
          2,
        );
        await session.db.unsafeExecute('TRUNCATE outbox');
        expect(await _count(session, 'outbox'), 0);
        expect(await _count(session, 'pipeline_outbox_partition_count'), 0);
        expect(await _count(session, 'pipeline_event_reference'), 0);
        expect(await _count(session, 'pipeline_dead_letter'), 0);
        expect(await _count(session, 'pipeline_output_commitment'), 0);
        expect(
          (await session.db.unsafeQuery('''
            SELECT used_rows,live_rows FROM pipeline_output_capacity WHERE output_id='$_output'
          ''')).single.toList(),
          [0, 0],
        );
        expect(await _dropOldPartition(session, 'outbox'), isTrue);
      });

      test('drop_requires_read_committed', () async {
        await prepareOldOutbox();
        await expectLater(
          session.db.transaction((tx) async {
            await session.db.unsafeExecute(
              'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ',
              transaction: tx,
            );
            return _dropOldPartition(session, 'outbox', 0, tx);
          }),
          throwsA(
            isA<DatabaseQueryException>().having(
              (error) => error.code,
              'SQLSTATE',
              '25000',
            ),
          ),
        );
        expect(await _dropOldPartition(session, 'outbox'), isTrue);
      });

      test('outbox_cleanup_skips_busy_output_count', () async {
        await prepareOldOutbox();
        await _intent(session, 1, 'delivered');
        final writer = builder.build();
        final gate = ContentionGate();
        final written = Completer<void>();
        final holding = gate.run(
          () => writer.db.transaction((tx) async {
            await _intent(writer, 2, 'delivered', tx: tx);
            written.complete();
            await gate.future;
          }),
        );
        try {
          await Future.any([
            written.future,
            holding.then<void>((_) => fail('Insert was not held')),
          ]);
          await _intent(session, 3, 'delivered', output: _otherOutput);
          expect(await _maintain(session, 'outbox'), 1);
          expect(
            await _column(session, 'SELECT delivery_id::text FROM outbox'),
            [_id(101)],
          );
          await gate.join();
          await holding;
          expect(await _maintain(session, 'outbox'), 2);
          expect(await _dropOldPartition(session, 'outbox'), isTrue);
        } finally {
          await gate.join();
        }
      });

      test('delivered_retention_reclaims_only_matching_attempts', () async {
        await _intent(session, 1, 'delivered');
        await _intent(session, 2, 'queued', terminal: null);
        await session.db.unsafeSimpleExecute('''
        INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
        SELECT created_at,delivery_id,1,gen_random_uuid(),created_at,'acknowledged' FROM outbox
      ''');
        expect(await _maintain(session, 'outbox'), 1);
        expect(await _maintain(session, 'attempts'), 1);
        expect(
          await _column(
            session,
            'SELECT "deliveryId"::text FROM delivery_attempts',
          ),
          [_id(102)],
        );
      });

      test('new_terminal_time_overrides_old_creation_age', () async {
        await _intent(session, 1, 'delivered', terminal: '2026-09-30 UTC');
        expect(await _maintain(session, 'outbox'), 0);
        expect(await _count(session, 'outbox'), 1);
      });

      test('discard_starts_its_own_terminal_retention', () async {
        await _intent(session, 1, 'dead');
        await session.db.unsafeSimpleExecute('''
          INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
          SELECT created_at,delivery_id,1,gen_random_uuid(),created_at,'permanent' FROM outbox
        ''');
        expect(await _maintain(session, 'expiry'), 1);
        expect(
          await _maintain(
            session,
            'outbox',
            now: _now.add(const Duration(days: 6)),
          ),
          0,
        );
        expect(await _maintain(session, 'attempts'), 0);
        expect(await _count(session, 'delivery_attempts'), 1);
        expect(
          await _maintain(
            session,
            'outbox',
            now: _now.add(const Duration(days: 8)),
          ),
          1,
        );
        expect(await _maintain(session, 'attempts'), 1);
      });

      test('retired_attempt_batch_advances_across_delivery_keys', () async {
        for (final id in [1, 2, 3]) {
          await _intent(session, id, 'delivered');
        }
        await session.db.unsafeSimpleExecute('''
          INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
          SELECT created_at,delivery_id,n,gen_random_uuid(),created_at,'retryable'
          FROM outbox CROSS JOIN generate_series(1,4) n
          WHERE delivery_id='${_id(103)}' OR (delivery_id='${_id(102)}' AND n=1)
        ''');
        expect(await _maintain(session, 'outbox'), 3);
        expect(await _maintain(session, 'attempts'), 3);
        expect(await _count(session, 'pipeline_retired_delivery'), 1);
        expect(await _count(session, 'delivery_attempts'), 2);
        expect(await _maintain(session, 'attempts'), 2);
        expect(await _count(session, 'pipeline_retired_delivery'), 0);
      });

      test('retired_intent_attempts_reclaim_across_batches', () async {
        await _event(session, 1);
        await _event(session, 2);
        await _intent(session, 1, 'discarded');
        await _intent(session, 2, 'queued', terminal: null);
        await session.db.unsafeSimpleExecute('''
        INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId","startedAt",outcome)
        SELECT created_at,delivery_id,n,gen_random_uuid(),created_at,'retryable'
        FROM outbox CROSS JOIN generate_series(1,8) n
      ''');
        expect(await _maintain(session, 'outbox'), 1);
        expect(await _maintain(session, 'events'), 1);
        expect(await _maintain(session, 'attempts'), 3);
        expect(await _maintain(session, 'attempts'), 3);
        expect(await _maintain(session, 'attempts'), 2);
        expect(await _count(session, 'pipeline_retired_delivery'), 0);
        expect(await _count(session, 'delivery_attempts'), 8);
      });

      test('replayable_work_protects_ordering_evidence', () async {
        await _raw(session, 1, 'pending');
        await _failure(session, 1, seen: '2026-09-30 UTC');
        await session.db.unsafeSimpleExecute('''
        UPDATE raw_admission_cutoff SET cutoff='2026-09-30 UTC';
        INSERT INTO observation_keys ("eventId",fingerprint,"sourceTime","firstSeenAt",disposition)
        VALUES ('${_id(5)}','fp','$_old','$_old','ready');
        INSERT INTO transport_keys ("sourceId",key,"bodySha256","firstSeenAt","expiresAt","rawObservedAt","rawId")
        VALUES ('$_source','expired','digest','$_old','2026-09-29','$_old','${_id(1)}'),
          ('$_source','still-live','digest','$_old','2026-10-02','$_old','${_id(1)}');
      ''');
        expect(await _maintain(session, 'observation'), 0);
        expect(await _maintain(session, 'transport'), 1);
        expect(await _column(session, 'SELECT key FROM transport_keys'), [
          'still-live',
        ]);
        await session.db.unsafeExecute("UPDATE raw_inbox SET status='done'");
        expect(await _maintain(session, 'observation'), 1);
      });

      test('queue_maintenance_advances_dedup_cutoff_without_icinga2', () async {
        await _raw(session, 1, 'done');
        await session.db.unsafeSimpleExecute('''
          INSERT INTO observation_keys ("eventId",fingerprint,"sourceTime","firstSeenAt",disposition)
          VALUES ('${_id(7)}','fp','$_old','$_old','ready');
          INSERT INTO transport_keys ("sourceId",key,"bodySha256","firstSeenAt","expiresAt","rawObservedAt","rawId")
          VALUES ('$_source','expired','digest','$_old','2026-01-02','$_old','${_id(1)}');
        ''');
        expect(await _maintain(session, 'transport'), 0);
        expect(await _maintain(session, 'observation'), 0);
        await _maintain(session, 'cutoff');
        expect(await _maintain(session, 'transport'), 1);
        expect(await _maintain(session, 'observation'), 1);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: cluster.override,
    testGroupTagsOverride: ['db'],
  );
}
