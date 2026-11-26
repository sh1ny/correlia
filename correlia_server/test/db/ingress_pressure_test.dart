import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/admission.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:postgres/postgres.dart' show Connection;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/postgres_lock_witness.dart';
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' show sourceId, token;

const _connection = 'aaaaaaaa-0000-4000-8000-000000000001';
const _holder = 'aaaaaaaa-0000-4000-8000-000000000002';

Future<int> _count(Session session, String table) async =>
    (await session.db.unsafeQuery('SELECT count(*) FROM $table')).single[0]!
        as int;

void main() {
  final cluster = LockWitnessCluster();
  tearDownAll(cluster.close);
  withServerpod(
    'shared webhook and pull inbox pressure',
    (builder, _) {
      late Session session;
      late Connection connection;
      late StreamLease lease;
      late String snapshot;
      late DateTime receipt;
      late IngestAdmission first;
      late IngestAdmission second;
      late ConsumerAdmission pull;
      late Future<void> Function(int, int) publish;
      late Future<AdmissionOutcome> Function(
        IngestAdmission,
        String,
        String, {
        DateTime? observed,
      })
      webhook;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute(
          'TRUNCATE icinga2_admitted_batch,icinga2_stream_lease',
        );
        receipt =
            (await session.db.unsafeQuery(
                  'SELECT clock_timestamp()',
                )).single[0]!
                as DateTime;
        publish = (revision, cap) async {
          final input =
              await IngestConfigRepository(
                session,
                secretStore: testSecretStore,
              ).publishConfig(
                streamBootstrap(revision, [
                    streamSource(icinga2DbSourceId),
                    {
                      'id': sourceId,
                      'kind': 'alertmanager',
                      'enabled': true,
                      'credentials': [
                        {'ref': 'source-token', 'type': 'bearer'},
                      ],
                      'output_ids': <String>[],
                    },
                  ])
                  ..['pipeline_operations'] = {
                    'pending_max_rows': cap,
                    'pending_max_age_seconds': 3600,
                  },
                {...streamMaterial(), 'source-token': token(1)},
                runMode: 'test',
              );
          snapshot = input.snapshotId;
          final source = input.sources.singleWhere(
            (source) => source.id == sourceId,
          );
          webhook = (repo, key, body, {observed}) => repo.admit(
            sourceId: sourceId,
            kind: 'alertmanager',
            credential: source.credentials.single,
            pathToken: false,
            body: Uint8List.fromList(utf8.encode(body)),
            contentType: 'application/json',
            observedAt: observed ?? receipt,
            idempotencyKey: key,
          );
        };
        await publish(1, 1);
        connection = await openStreamDatabase(session.serverpod);
        addTearDown(connection.close);
        lease = (await StreamLeaseStore(
          connection,
        ).acquire(icinga2DbSourceId, _holder))!;
        first = IngestAdmission(builder.build());
        second = IngestAdmission(builder.build());
        pull = ConsumerAdmission(connection);
      });

      StreamRawBatch batch({bool sync = false, bool invalid = false}) =>
          StreamRawBatch(
            id: const Uuid().v4(),
            connectionId: _connection,
            origin: sync ? IcingaStreamOrigin.sync : IcingaStreamOrigin.stream,
            syncId: sync ? streamDbSyncId : null,
            rows: [
              [
                StreamAdmissionItem.text(
                  receipt,
                  invalid
                      ? '{'
                      : jsonEncode(streamDbCheck(receipt, sync: sync)),
                  invalidJson: invalid,
                ),
              ],
            ],
          );
      Future<StreamAdmissionResult> admit(
        StreamRawBatch value, {
        ConsumerAdmission? repo,
      }) => (repo ?? pull).admit(
        lease: lease,
        snapshotId: snapshot,
        batch: value,
      );

      test('two_apis_and_pull_contend_for_last_slot', () async {
        final attempts = await Future.wait([
          webhook(first, 'first-api', 'first').then((result) => result.name),
          webhook(second, 'second-api', 'second').then((result) => result.name),
          admit(batch()).then((result) => result.name),
        ]);
        final accepted = attempts.where(
          (result) => result == 'accepted' || result == 'committed',
        );
        expect(accepted, hasLength(1));
        expect(await _count(session, 'raw_inbox'), 1);
        expect(
          await _count(session, 'transport_keys'),
          accepted.single == 'accepted' ? 1 : 0,
        );
        expect(
          await _count(session, 'icinga2_admitted_batch'),
          accepted.single == 'committed' ? 1 : 0,
        );
      });

      test('admission_leaves_counter_free_while_ddl_waits_for_worker', () async {
        await publish(2, 2);
        expect(
          await webhook(first, 'first', 'body'),
          AdmissionOutcome.accepted,
        );
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final waiters = ContentionGate();
        final releaseWorker = ContentionGate();
        final worker = builder.build();
        final ddl = builder.build();
        final admission = builder.build();
        final workerReady = Completer<LockActor>();
        final ddlReady = Completer<LockActor>();
        final admissionReady = Completer<LockActor>();
        final completing = releaseWorker.run(
          () => worker.db.transaction((tx) async {
            final actor = await pooledLockActor(worker, tx);
            expect(
              await worker.db.unsafeQuery(
                "SELECT raw_id FROM raw_inbox WHERE status='pending' FOR UPDATE",
                transaction: tx,
              ),
              hasLength(1),
            );
            workerReady.complete(actor);
            await releaseWorker.future;
            // Don't rely on the database choosing a deadlock victim. The
            // worker must still be able to take the counter before completing.
            await worker.db.unsafeQuery(
              'SELECT pending_rows FROM pipeline_pending FOR UPDATE NOWAIT',
              transaction: tx,
            );
            await worker.db.unsafeExecute(
              "UPDATE raw_inbox SET status='done' WHERE status='pending'",
              transaction: tx,
            );
          }),
        );
        try {
          final holder = await Future.any([
            workerReady.future,
            completing.then<LockActor>((_) => fail('Worker did not hold raw')),
          ]);
          const ddlLock = 'LOCK TABLE ONLY raw_inbox IN ACCESS EXCLUSIVE MODE';
          final altering = waiters.run(
            () => ddl.db.transaction((tx) async {
              ddlReady.complete(
                await pooledLockActor(ddl, tx, waiter: SqlTimeouts.poolDefault),
              );
              await ddl.db.unsafeExecute(ddlLock, transaction: tx);
            }),
          );
          final ahead = await Future.any([
            ddlReady.future,
            altering.then<LockActor>((_) => fail('DDL did not wait')),
          ]);
          await witness.blockedBy(ahead, holder, altering, statement: ddlLock);

          const reserve = 'SELECT correlia_reserve_raw(1)';
          final reserving = waiters.run(
            () => admission.db.transaction((tx) async {
              admissionReady.complete(
                await pooledLockActor(
                  admission,
                  tx,
                  waiter: SqlTimeouts.poolDefault,
                ),
              );
              return (await admission.db.unsafeQuery(
                reserve,
                transaction: tx,
              )).single[0];
            }),
          );
          final behind = await Future.any([
            admissionReady.future,
            reserving.then<LockActor>((_) => fail('Admission did not wait')),
          ]);
          await witness.blockedBy(behind, ahead, reserving, statement: reserve);
          await releaseWorker.join();
          await completing;
          await altering;
          expect(await reserving, isNull);
        } finally {
          await releaseWorker.join();
          await waiters.join();
        }
      });

      test('pending_age_is_sampled_after_waiting_for_capacity', () async {
        await publish(2, 3);
        expect(await webhook(first, 'old', 'body'), AdmissionOutcome.accepted);
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final gate = ContentionGate();
        final blocker = builder.build();
        final waiting = builder.build();
        final held = Completer<LockActor>();
        final started = Completer<LockActor>();
        final holding = gate.run(
          () => blocker.db.transaction((tx) async {
            final actor = await pooledLockActor(blocker, tx);
            await blocker.db.unsafeQuery(
              'SELECT 1 FROM pipeline_pending FOR UPDATE',
              transaction: tx,
            );
            held.complete(actor);
            await gate.future;
          }),
        );
        final holder = await Future.any([
          held.future,
          holding.then<LockActor>((_) => fail('Counter lock was not held')),
        ]);
        final reservation = gate.run(
          () => waiting.db.transaction((tx) async {
            final actor = await pooledLockActor(
              waiting,
              tx,
              waiter: SqlTimeouts.poolDefault,
            );
            started.complete(actor);
            return (await waiting.db.unsafeQuery(
              'SELECT correlia_reserve_raw(1)',
              transaction: tx,
            )).single[0];
          }),
        );
        final waiter = await Future.any([
          started.future,
          reservation.then<LockActor>((_) => fail('Reservation did not start')),
        ]);
        await witness.blockedBy(
          waiter,
          holder,
          reservation,
          statement: 'correlia_reserve_raw(1)',
        );
        // Move the row's age boundary between the blocked statement's start
        // and this observation. No wall-clock sleep is needed to cross it.
        await session.db.unsafeExecute('''
          UPDATE raw_inbox SET queued_at=(
            SELECT query_start+(clock_timestamp()-query_start)/2-interval '1 hour'
            FROM pg_stat_activity WHERE pid=@pid
          ) WHERE status='pending'
        ''', parameters: QueryParameters.named({'pid': waiter.pid}));
        await gate.join();
        await holding;
        expect(await reservation, 'inbox');
        expect(await _count(session, 'raw_inbox'), 1);
      });

      test('committed_webhook_and_pull_retries_beat_pressure', () async {
        await publish(2, 2);
        final pullBatch = batch();
        expect(await admit(pullBatch), StreamAdmissionResult.committed);
        expect(
          await webhook(first, 'repeat', 'body'),
          AdmissionOutcome.accepted,
        );
        final receipts = await session.db.unsafeQuery(
          'SELECT "expiresAt" FROM transport_keys',
        );
        expect((await webhook(second, 'refused', 'new')).name, 'inboxPressure');
        expect(await admit(batch()), StreamAdmissionResult.atCapacity);
        expect(
          await webhook(second, 'repeat', 'body'),
          AdmissionOutcome.duplicate,
        );
        expect(await admit(pullBatch), StreamAdmissionResult.committed);
        expect(await _count(session, 'raw_inbox'), 2);
        expect(await _count(session, 'icinga2_admitted_batch'), 1);
        expect(
          (await session.db.unsafeQuery(
            'SELECT "expiresAt" FROM transport_keys',
          )).single[0],
          receipts.single[0],
        );
      });

      test('refused_admission_persists_one_disk_measurement', () async {
        await publish(2, 4);
        expect(
          await webhook(first, 'known', 'original'),
          AdmissionOutcome.accepted,
        );
        final priorBatch = batch();
        expect(await admit(priorBatch), StreamAdmissionResult.committed);
        await session.db.unsafeSimpleExecute(r'''
          UPDATE pipeline_queue_policy SET disk_budget_bytes=1;
          CREATE SEQUENCE test_sample_writes;
          CREATE FUNCTION test_count_sample_write() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            PERFORM nextval('test_sample_writes');
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER test_count_sample_write BEFORE UPDATE OF database_bytes ON pipeline_disk_sample
            FOR EACH ROW EXECUTE FUNCTION test_count_sample_write()
        ''');
        addTearDown(
          () => session.db.unsafeSimpleExecute('''
          DROP TRIGGER test_count_sample_write ON pipeline_disk_sample;
          DROP FUNCTION test_count_sample_write();
          DROP SEQUENCE test_sample_writes
        '''),
        );
        Future<void> stale() => session.db.unsafeExecute(
          "UPDATE pipeline_disk_sample SET sampled_at='-infinity'",
        );
        Future<List<Object?>> count() async => (await session.db.unsafeQuery(
          'SELECT last_value,is_called FROM test_sample_writes',
        )).single.toList();
        await stale();
        expect(
          await webhook(second, 'known', 'original'),
          AdmissionOutcome.duplicate,
        );
        expect(await admit(priorBatch), StreamAdmissionResult.committed);
        expect(await count(), [1, false]);
        expect(
          await webhook(second, 'new-webhook', 'new'),
          AdmissionOutcome.storagePressure,
        );
        expect(await count(), [1, true]);
        await stale();
        expect(await admit(batch()), StreamAdmissionResult.atCapacity);
        expect(await count(), [2, true]);
        expect(await _count(session, 'transport_keys'), 1);
        expect(await _count(session, 'icinga2_admitted_batch'), 1);
        expect(await _count(session, 'raw_inbox'), 2);
      });

      test('conflicting_live_key_beats_pressure', () async {
        expect(
          await webhook(first, 'one-intent', 'exact'),
          AdmissionOutcome.accepted,
        );
        expect(
          await webhook(second, 'one-intent', 'different'),
          AdmissionOutcome.conflict,
        );
        expect(
          (await webhook(second, 'another-intent', 'different')).name,
          'inboxPressure',
        );
        expect(await _count(session, 'transport_keys'), 1);
        final bodies = await session.db.unsafeQuery(
          "SELECT convert_from(body,'UTF8') FROM raw_inbox",
        );
        expect(bodies.single[0], 'exact');
      });

      test('expired_reservation_deleted_between_conflict_and_lock', () async {
        final expired = receipt.subtract(const Duration(minutes: 20));
        expect(
          await webhook(first, 'reused', 'previous', observed: expired),
          AdmissionOutcome.accepted,
        );
        await session.db.unsafeExecute("UPDATE raw_inbox SET status='done'");
        final conflicted = Completer<void>();
        final gate = ContentionGate();
        final reading = IngestAdmission(
          builder.build(),
          afterReservationConflictForTest: () async {
            conflicted.complete();
            await gate.future;
          },
        );
        final admission = gate.run(
          () => webhook(reading, 'reused', 'recovered'),
        );
        await conflicted.future;
        await session.db.unsafeExecute('DELETE FROM transport_keys');
        await gate.join();
        expect(await admission, AdmissionOutcome.accepted);
        expect(await _count(session, 'transport_keys'), 1);
        final raws = await session.db.unsafeQuery(
          "SELECT status,convert_from(body,'UTF8') FROM raw_inbox ORDER BY observed_at",
        );
        expect(raws.map((row) => row.toList()), [
          ['done', 'previous'],
          ['pending', 'recovered'],
        ]);
      });

      test('expired_transport_budget_never_accepts_a_retry', () async {
        expect(
          await webhook(first, 'reused', 'previous'),
          AdmissionOutcome.accepted,
        );
        await session.db.unsafeExecute("UPDATE raw_inbox SET status='done'");
        var elapsed = Duration.zero;
        final racing = IngestAdmission(
          builder.build(),
          reservationElapsedForTest: () => elapsed,
          afterReservationConflictForTest: () async {
            await session.db.unsafeExecute('DELETE FROM transport_keys');
            elapsed = const Duration(seconds: 5);
          },
        );
        await expectLater(
          webhook(racing, 'reused', 'replacement'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Transport reservation deadline exceeded',
            ),
          ),
        );
        expect(await _count(session, 'transport_keys'), 0);
        expect(
          (await session.db.unsafeQuery(
            "SELECT convert_from(body,'UTF8') FROM raw_inbox",
          )).single[0],
          'previous',
        );
      });

      for (final invalid in [false, true]) {
        test(
          'sync_admission_orders_progress_before_count ${invalid ? 'failure' : 'success'}',
          () async {
            await publish(2, 2);
            await session.db.unsafeSimpleExecute('''
            INSERT INTO icinga2_sync_progress(sync_id,source_id,phase,started_at)
            VALUES ('$streamDbSyncId','$icinga2DbSourceId','reading',now());
            UPDATE icinga2_stream_lease SET "expiresAt"='infinity';
          ''');
            expect(
              await admit(batch(sync: true, invalid: invalid)),
              StreamAdmissionResult.committed,
            );
            final workerSession = builder.build();
            final workerAtProgress = Completer<LockActor>();
            final worker = PipelineRepository(
              workerSession,
              clock: () => receipt,
              elapsedForTest: () => Duration.zero,
              beforeSyncProgressLockForTest: (tx) async {
                workerAtProgress.complete(
                  await pooledLockActor(
                    workerSession,
                    tx,
                    waiter: SqlTimeouts.pipelineWork,
                  ),
                );
              },
            );
            expect(await worker.pinOne(), isTrue);
            final endpoint = await StreamDatabaseEndpoint.resolve(
              session.serverpod,
            );
            final pullConnection = await endpoint.open(
              queryTimeout: const Duration(minutes: 5),
            );
            addTearDown(pullConnection.close);
            final pullAtProgress = Completer<LockActor>();
            final competing = ConsumerAdmission(
              pullConnection,
              beforeSyncProgressLockForTest: (tx) async {
                pullAtProgress.complete(
                  await lockActor(tx, waiter: SqlTimeouts.streamWrite),
                );
              },
            );
            final witness = await PostgresLockWitness.start(session);
            addTearDown(witness.close);
            final held = Completer<LockActor>();
            final gate = ContentionGate();
            final blockerSession = builder.build();
            final holding = gate.run(
              () => blockerSession.db.transaction((tx) async {
                final actor = await pooledLockActor(blockerSession, tx);
                await blockerSession.db.unsafeQuery(
                  "SELECT 1 FROM icinga2_sync_progress WHERE sync_id='$streamDbSyncId' FOR UPDATE",
                  transaction: tx,
                );
                held.complete(actor);
                await gate.future;
              }),
            );

            Future<void> expectCountUnlocked() async {
              expect(
                await session.db.unsafeQuery(
                  'SELECT pending_rows FROM pipeline_pending WHERE singleton=1 FOR UPDATE NOWAIT',
                ),
                hasLength(1),
              );
            }

            final holder = await Future.any([
              held.future,
              holding.then<LockActor>(
                (_) => fail('Fixture did not hold sync progress'),
              ),
            ]);
            final completing = gate.run(worker.processOne);
            final completer = await Future.any([
              workerAtProgress.future,
              completing.then<LockActor>(
                (_) => fail('Worker finished without waiting for progress'),
              ),
            ]);
            await witness.blockedBy(
              completer,
              holder,
              completing,
              statement: 'UPDATE icinga2_sync_progress',
            );
            await expectCountUnlocked();

            final admission = gate.run(
              () => admit(batch(sync: true), repo: competing),
            );
            final admitter = await Future.any([
              pullAtProgress.future,
              admission.then<LockActor>(
                (_) => fail('Admission finished without waiting for progress'),
              ),
            ]);
            await witness.blockedBy(
              admitter,
              completer,
              admission,
              statement: 'FROM icinga2_sync_progress',
            );
            await expectCountUnlocked();
            await gate.join();
            await holding;
            expect(await completing, isTrue);
            expect(await admission, StreamAdmissionResult.committed);
            final progress = await session.db.unsafeQuery(
              'SELECT rows_admitted,rows_done,rows_failed FROM icinga2_sync_progress',
            );
            expect(progress.single.toList(), [
              2,
              invalid ? 0 : 1,
              invalid ? 1 : 0,
            ]);
            expect(
              (await session.db.unsafeQuery(
                'SELECT pending_rows FROM pipeline_pending',
              )).single[0],
              1,
            );
          },
        );
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: cluster.override,
    testGroupTagsOverride: ['db'],
  );
}
