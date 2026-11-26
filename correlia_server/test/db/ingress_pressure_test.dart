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
import '../support/postgres_lock_witness.dart' show ContentionGate;
import '../support/secret_fixture.dart';
import 'ingest_config_test.dart' show sourceId, token;

const _connection = 'aaaaaaaa-0000-4000-8000-000000000001';
const _holder = 'aaaaaaaa-0000-4000-8000-000000000002';

Future<int> _count(Session session, String table) async =>
    (await session.db.unsafeQuery('SELECT count(*) FROM $table')).single[0]!
        as int;

void main() {
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

      test('sync_admission_orders_progress_before_count', () async {
        await publish(2, 2);
        await session.db.unsafeExecute('''
          INSERT INTO icinga2_sync_progress(sync_id,source_id,phase,started_at)
          VALUES ('$streamDbSyncId','$icinga2DbSourceId','reading',now())
        ''');
        final competing = ConsumerAdmission(
          connection,
          beforeWriteForTest: (_, _) async {
            await expectLater(
              builder.build().db.unsafeQuery(
                "SELECT sync_id FROM icinga2_sync_progress WHERE sync_id='$streamDbSyncId' FOR UPDATE NOWAIT",
              ),
              throwsA(
                isA<DatabaseQueryException>().having(
                  (e) => e.code,
                  'code',
                  '55P03',
                ),
              ),
            );
          },
        );
        expect(
          await admit(batch(sync: true), repo: competing),
          StreamAdmissionResult.committed,
        );
        expect(
          await admit(batch(sync: true, invalid: true), repo: competing),
          StreamAdmissionResult.committed,
        );
        expect(await admit(batch()), StreamAdmissionResult.atCapacity);
        final worker = PipelineRepository(
          builder.build(),
          clock: () => receipt,
        );
        for (var i = 0; i < 2; i++) {
          expect(await worker.pinOne(), isTrue);
          expect(await worker.processOne(), isTrue);
        }
        final progress = await session.db.unsafeQuery(
          'SELECT rows_admitted,rows_done,rows_failed FROM icinga2_sync_progress',
        );
        expect(progress.single.toList(), [2, 1, 1]);
        expect(
          await webhook(first, 'after-sync-a', 'body'),
          AdmissionOutcome.accepted,
        );
        expect(
          await webhook(second, 'after-sync-b', 'body'),
          AdmissionOutcome.accepted,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
