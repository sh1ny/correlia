import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/redaction.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/status.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_progress.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_reader.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_result.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_decode_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';

const _connection = 'a0d930d1-1111-4222-8333-444444444444';

void main() {
  withServerpod(
    'Icinga2 sync retention through the durable pipeline',
    (builder, _) {
      late Session session;
      late ConsumerAdmission admission;
      late SyncProgressStore progress;
      late StreamLease lease;
      late String snapshot;
      final now = streamDbNow;
      final start = now.subtract(const Duration(seconds: 30));
      final recovery = now.subtract(const Duration(seconds: 1));
      final check = streamDbCheck(start);
      final projected = streamDbCheck(recovery, state: 0, sync: true);

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute(
          'TRUNCATE icinga2_stream_lease,icinga2_stream_status,icinga2_admitted_batch,icinga2_stream_resync',
        );
        snapshot = await publishStreamDb(session);
        final connection = await openStreamDatabase(session.serverpod);
        addTearDown(connection.close);
        lease = (await StreamLeaseStore(
          connection,
        ).acquire(icinga2DbSourceId, 'storage-test'))!;
        expect(
          await StreamStatusStore(
            connection,
          ).startConnection(lease, _connection),
          1,
        );
        admission = ConsumerAdmission(connection);
        progress = SyncProgressStore(connection);
      });

      Future<void> drain(int expected) async {
        final repository = PipelineRepository(session, clock: () => now);
        for (var i = 0; i < expected; i++) {
          expect(
            await repository.pinOne(),
            isTrue,
            reason: 'Row $i was not claimable',
          );
          expect(
            await repository.processOne(),
            isTrue,
            reason: 'Row $i was not processed',
          );
        }
        expect(await repository.pinOne(), isFalse);
        expect(await repository.processOne(), isFalse);
      }

      Future<void> runSync({
        required int confirmations,
        required int repairs,
        required int tombstones,
      }) async {
        const rowSize = 100;
        const rowCount = 100;
        final running = await progress.start(lease, connectionId: _connection);
        expect(running.disposition, SyncStartDisposition.started);
        final id = running.syncId!;
        final attrs = projected['attrs']! as Map<String, Object?>;
        final rows = [
          for (var row = 0; row < rowCount; row++)
            [
              for (var item = 0; item < rowSize; item++)
                StreamAdmissionItem.text(
                  now,
                  jsonEncode({
                    ...projected,
                    'name': 'stream-host!service-${row * rowSize + item}',
                    'attrs': {
                      ...attrs,
                      'name': 'service-${row * rowSize + item}',
                    },
                  }),
                ),
            ],
        ];
        expect(
          await admission.admit(
            lease: lease,
            snapshotId: snapshot,
            batch: StreamRawBatch(
              id: const Uuid().v4(),
              connectionId: _connection,
              origin: IcingaStreamOrigin.sync,
              syncId: id,
              rows: rows,
            ),
          ),
          StreamAdmissionResult.committed,
        );
        expect(
          await progress.finish(
            lease,
            id,
            const SyncReadReport(counts: {'objects': rowCount * rowSize}),
          ),
          isTrue,
        );
        expect((await progress.read(id))!.phase, SyncPhase.applying);
        await drain(rowCount);
        final applied = (await progress.read(id))!;
        expect(applied.phase, SyncPhase.complete);
        expect(applied.rowsDone, rowCount);
        expect(
          applied.counts,
          allOf(
            containsPair('objects', rowCount * rowSize),
            containsPair('confirmed', confirmations),
            containsPair('repaired', repairs),
            containsPair('tombstoned', tombstones),
          ),
        );
      }

      test('steady_installation', () async {
        await runSync(confirmations: 0, repairs: 0, tombstones: 10000);
        for (final table in [
          'raw_inbox',
          'icinga2_raw_origin',
          'events',
          'outbox',
          'observation_keys',
        ]) {
          expect(await countRows(session, table), 0, reason: table);
        }
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('kept_rows_follow_stored_events', () async {
        final rows = [
          for (var row = 0; row < 50; row++)
            [
              StreamAdmissionItem.text(
                now,
                jsonEncode({
                  ...check,
                  'service': row < 3
                      ? 'service-${row * 100 + 7}'
                      : 'stream-$row',
                }),
              ),
            ],
        ];
        expect(
          await admission.admit(
            lease: lease,
            snapshotId: snapshot,
            batch: StreamRawBatch(
              id: const Uuid().v4(),
              connectionId: _connection,
              origin: IcingaStreamOrigin.stream,
              rows: rows,
            ),
          ),
          StreamAdmissionResult.committed,
        );
        await drain(50);
        await runSync(confirmations: 0, repairs: 3, tombstones: 9997);
        expect(await countRows(session, 'raw_inbox'), 53);
        expect(await countRows(session, 'events'), 53);
        expect(await countRows(session, 'outbox'), 53);
        expect(
          await queryRows(
            session,
            'SELECT origin,count(*) AS count FROM icinga2_raw_origin GROUP BY origin ORDER BY origin',
          ),
          [
            {'origin': 'stream', 'count': 50},
            {'origin': 'sync', 'count': 3},
          ],
        );
      }, timeout: const Timeout(Duration(minutes: 4)));

      Future<String> readServices(List<Object?> objects) async {
        final running = await progress.start(lease, connectionId: _connection);
        expect(running.disposition, SyncStartDisposition.started);
        final id = running.syncId!;
        final report = await SyncReader(
          request: streamDecodeRequest(''),
          policy: StreamStateTypePolicy.softAndHard,
          redactor: PasswordRedactor(utf8.encode('not-in-fixture')),
          connectionId: _connection,
          syncId: id,
          open: (projection) async => SyncResponse(
            200,
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'results': projection == SyncProjection.hosts
                      ? const <Object?>[]
                      : objects,
                }),
              ),
            ),
          ),
          admit: (batch) =>
              admission.admit(lease: lease, snapshotId: snapshot, batch: batch),
          receiptClock: () => now,
        ).run();
        expect(await progress.finish(lease, id, report), isTrue);
        return id;
      }

      test('passive_service_not_reported_for_nine_days', () async {
        final original = now.subtract(const Duration(days: 10));
        await seedStreamDb(session, snapshot, [
          streamDbCheck(original),
        ], observed: original);
        await drain(1);
        final id = await readServices([
          streamDbCheck(
            now.subtract(const Duration(days: 9)),
            state: 0,
            sync: true,
          ),
        ]);
        await drain(1);
        final result = (await progress.read(id))!;
        expect(result.phase, SyncPhase.complete);
        expect(result.counts, containsPair('late', 1));
        expect(result.counts, containsPair('diverged', 1));
        expect((await theAlert(session))['status'], 'firing');
        expect(await countRows(session, 'events'), 1);
      });

      test('per_object_error_in_a_2_16_response', () async {
        await seedStreamDb(session, snapshot, [check]);
        await drain(1);
        final id = await readServices([
          {'code': 500, 'status': 'Object query failed'},
          projected,
        ]);
        await drain(1);
        final result = (await progress.read(id))!;
        expect(result.phase, SyncPhase.failed);
        expect(result.counts, containsPair('object_error', 1));
        expect(result.rowsAdmitted, 1);
        expect((await theAlert(session))['status'], 'resolved');
      });

      test('bad_object_fixed_in_icinga_2', () async {
        final before = await countRows(session, 'raw_inbox');
        final malformed = await readServices([
          {
            ...projected,
            'attrs': {'last_check_result': 42},
          },
        ]);
        expect((await progress.read(malformed))!.phase, SyncPhase.failed);
        expect(await countRows(session, 'raw_inbox'), before);
        await session.db.unsafeExecute(
          "UPDATE icinga2_sync_progress SET started_at=started_at-interval '61 seconds'",
        );
        final fixed = await readServices([projected]);
        await drain(1);
        expect((await progress.read(fixed))!.phase, SyncPhase.complete);
      });

      test('persistent_bad_object_before_a_missed_recovery', () async {
        await seedStreamDb(session, snapshot, [check]);
        await drain(1);
        final bad = {
          ...projected,
          'attrs': {
            ...projected['attrs']! as Map<String, Object?>,
            'name': 'bad-service',
            'last_check_result': {'output': 'incomplete'},
          },
        };
        for (var sync = 0; sync < 3; sync++) {
          if (sync != 0) {
            await session.db.unsafeExecute(
              "UPDATE icinga2_sync_progress SET started_at=started_at-interval '61 seconds'",
            );
          }
          final id = await readServices([bad, projected]);
          await drain(1);
          final result = (await progress.read(id))!;
          expect(result.phase, SyncPhase.failed);
          expect(result.counts, containsPair('invalid_object', 1));
          expect(result.samples.single.identifier, 'stream-host!bad-service');
          expect((await theAlert(session))['status'], 'resolved');
          expect(await countRows(session, 'events'), 2);
          expect(await countRows(session, 'raw_inbox'), 2);
        }
        expect(await countRows(session, 'icinga2_stream_resync'), 0);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
