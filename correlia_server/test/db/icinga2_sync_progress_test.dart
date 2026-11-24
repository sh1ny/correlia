@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/redaction.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/status.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_progress.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_reader.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_result.dart';
import 'package:postgres/postgres.dart' show Connection;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_decode_fixture.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/postgres_lock_witness.dart';
import '../support/secret_fixture.dart';
import '../support/stream_reader_clock.dart';

const _connection = 'aaaaaaaa-0000-4000-8000-000000000001';
const _nextConnection = 'aaaaaaaa-0000-4000-8000-000000000002';

void main() {
  final cluster = LockWitnessCluster();
  tearDownAll(cluster.close);
  withServerpod(
    'Icinga2 sync progress',
    (builder, _) {
      late Session session;
      late Connection db;
      late StreamLeaseStore leases;
      late StreamStatusStore statuses;
      late SyncProgressStore progress;
      late StreamLease lease;
      late String snapshot;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute('''TRUNCATE icinga2_admitted_batch,
        icinga2_stream_lease, icinga2_stream_status, icinga2_stream_resync''');
        snapshot = await publishStreamDb(session);
        db = await openStreamDatabase(session.serverpod);
        addTearDown(db.close);
        leases = StreamLeaseStore(db);
        statuses = StreamStatusStore(db);
        progress = SyncProgressStore(db);
        lease = (await leases.acquire(icinga2DbSourceId, 'worker-a'))!;
        expect(await statuses.startConnection(lease, _connection), 1);
      });

      Future<String> start({String connection = _connection}) async {
        final result = await progress.start(lease, connectionId: connection);
        expect(result.disposition, SyncStartDisposition.started);
        expect(result.syncId, isNotNull);
        return result.syncId!;
      }

      Future<void> ageStart(String id) => session.db.unsafeExecute('''
      UPDATE icinga2_sync_progress SET started_at=clock_timestamp()-interval '61 seconds'
      WHERE sync_id='$id'::uuid''');

      Future<void> ageEnd(String id, String interval) =>
          session.db.unsafeExecute('''
      UPDATE icinga2_sync_progress SET ended_at=clock_timestamp()-interval '$interval',
        read_end_at=clock_timestamp()-interval '$interval',
        started_at=clock_timestamp()-interval '$interval'-interval '1 minute'
      WHERE sync_id='$id'::uuid''');

      Future<void> admit(String id, {bool invalid = false}) async {
        final item = invalid
            ? <String, Object?>{'type': 'Unknown'}
            : streamDbCheck(
                streamDbNow.subtract(const Duration(seconds: 10)),
                sync: true,
              );
        final batch = StreamRawBatch(
          id: const Uuid().v4(),
          connectionId: _connection,
          origin: IcingaStreamOrigin.sync,
          syncId: id,
          rows: [
            [StreamAdmissionItem.text(streamDbNow, jsonEncode(item))],
          ],
        );
        expect(
          await ConsumerAdmission(
            db,
          ).admit(lease: lease, snapshotId: snapshot, batch: batch),
          StreamAdmissionResult.committed,
        );
      }

      Future<void> process() => processIcinga2(session, streamDbNow);
      Future<void> expire() => session.db.unsafeExecute('''
      UPDATE icinga2_stream_lease SET "expiresAt"=clock_timestamp()-interval '1 second'
      WHERE "sourceId"='$icinga2DbSourceId'::uuid''');

      Future<void> failStreamRow() async {
        final batch = StreamRawBatch(
          id: const Uuid().v4(),
          connectionId: _connection,
          origin: IcingaStreamOrigin.stream,
          rows: [
            [
              StreamAdmissionItem.text(
                streamDbNow,
                jsonEncode(<String, Object?>{'type': 'Unknown'}),
              ),
            ],
          ],
        );
        expect(
          await ConsumerAdmission(db).admit(
            lease: lease,
            snapshotId: snapshot,
            batch: batch,
          ),
          StreamAdmissionResult.committed,
        );
        await processIcinga2(session, streamDbNow);
      }

      Future<StreamLease> takeover() async {
        await expire();
        return (await leases.acquire(icinga2DbSourceId, 'worker-b'))!;
      }

      Future<void> request(int number) => session.db.unsafeExecute(
        '''
      INSERT INTO icinga2_stream_resync ("sourceId", "requestSeq")
      VALUES ('$icinga2DbSourceId'::uuid, $number)
      ON CONFLICT ("sourceId") DO UPDATE SET "requestSeq"=EXCLUDED."requestSeq"''',
      );

      Future<void> publishSources(
        int revision,
        List<Object?> sources, {
        bool material = false,
      }) async {
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publishConfig(
          streamBootstrap(revision, sources),
          material ? streamMaterial() : <String, Object?>{},
          runMode: 'test',
          clock: () => streamDbNow,
        );
      }

      Future<SyncReadReport> readBadObjects(
        String id,
        Map<String, Object?> bad,
        int count,
        List<String> logs,
      ) async {
        final encoded = utf8.encode(jsonEncode(bad));
        Stream<List<int>> body() async* {
          yield utf8.encode('{"results":[');
          for (var i = 0; i < count; i++) {
            if (i != 0) yield const [44];
            yield encoded;
          }
          yield utf8.encode(']}');
        }

        final clock = StreamReaderClock();
        return SyncReader(
          request: streamDecodeRequest(''),
          policy: StreamStateTypePolicy.softAndHard,
          redactor: PasswordRedactor(utf8.encode('secret-not-in-fixture')),
          connectionId: _connection,
          syncId: id,
          open: (projection) async => SyncResponse(
            200,
            projection == SyncProjection.hosts
                ? Stream.value(utf8.encode('{"results":[]}'))
                : body(),
          ),
          admit: (batch) => ConsumerAdmission(db).admit(
            lease: lease,
            snapshotId: snapshot,
            batch: batch,
          ),
          log: logs.add,
          receiptClock: () => streamDbNow,
          monotonic: () => clock.elapsed,
          schedule: clock.schedule,
        ).run();
      }

      test('unreadable_name', () async {
        final id = await start();
        final object = streamDbCheck(streamDbNow, sync: true);
        final bad = {
          ...object,
          'name': 'unsafe\nname',
          'attrs': {
            ...object['attrs']! as Map<String, Object?>,
            'name': 'unsafe\nname',
            'last_check_result': 42,
          },
        };
        final logs = <String>[];
        final report = await readBadObjects(id, bad, 1, logs);
        expect(await progress.finish(lease, id, report), isTrue);
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.failed);
        expect(row.samples.single.identifier, 'results[0]');
        expect(row.samples.single.code, 'invalid_object');
        expect(row.counts['invalid_object'], 1);
        expect(logs.join('\n'), contains('results[0]'));
        expect(logs.join('\n'), isNot(contains('unsafe')));
      });

      test('every_object_bad', () async {
        final id = await start();
        final object = streamDbCheck(
          streamDbNow,
          sync: true,
          host: 'h' * 255,
          service: 's' * 255,
        );
        final bad = {
          ...object,
          'attrs': {
            ...object['attrs']! as Map<String, Object?>,
            'last_check_result': 42,
          },
        };
        final logs = <String>[];
        final report = await readBadObjects(id, bad, 100000, logs);
        await progress.finish(lease, id, report);
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.failed);
        expect(row.counts['invalid_object'], 100000);
        expect(row.samples, hasLength(20));
        expect(logs.length, lessThanOrEqualTo(21));
        expect(logs.join('\n'), contains('100000'));
        for (final sample in row.samples) {
          expect(
            utf8.encode('${sample.identifier}${sample.code}').length,
            lessThanOrEqualTo(600),
          );
        }
      });

      test('all_rows_applied', () async {
        final id = await start();
        await admit(id);
        await progress.finish(
          lease,
          id,
          const SyncReadReport(counts: {'objects': 1, 'no_result': 2}),
        );
        expect((await progress.read(id))!.phase, SyncPhase.applying);
        await process();
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.complete);
        expect([row.rowsAdmitted, row.rowsDone, row.rowsFailed], [1, 1, 0]);
        expect(row.counts, containsPair('objects', 1));
        expect(row.counts, containsPair('no_result', 2));
        expect(row.counts['applied'], 1);
      });

      test('last_row_done_before_reading_ends', () async {
        final id = await start();
        await admit(id);
        await process();
        expect((await progress.read(id))!.phase, SyncPhase.reading);
        await progress.finish(lease, id, const SyncReadReport());
        expect((await progress.read(id))!.phase, SyncPhase.complete);
      });

      test('sync_with_no_object', () async {
        final id = await start();
        await progress.finish(
          lease,
          id,
          const SyncReadReport(counts: {'no_result': 1}),
        );
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.complete);
        expect(row.counts['no_result'], 1);
        expect(row.rowsAdmitted, 0);
      });

      test('failed_row_while_reading', () async {
        final id = await start();
        await admit(id, invalid: true);
        await process();
        expect((await progress.read(id))!.phase, SyncPhase.failed);
        expect((await progress.read(id))!.readEndAt, isNull);
        await admit(id);
        await process();
        await progress.finish(lease, id, const SyncReadReport());
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.failed);
        expect([row.rowsAdmitted, row.rowsDone, row.rowsFailed], [2, 1, 1]);
      });

      test('still_applying', () async {
        final id = await start();
        await admit(id);
        await progress.finish(lease, id, const SyncReadReport());
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.applying);
        expect([row.rowsAdmitted, row.rowsDone], [1, 0]);
      });

      test('application_blocked_on_a_reachable_database', () async {
        final id = await start();
        await admit(id);
        await progress.finish(lease, id, const SyncReadReport());
        await ageEnd(id, '16 minutes');
        expect(await progress.markStalled(lease), isTrue);
        expect((await progress.read(id))!.phase, SyncPhase.stalled);
        final next = await start();
        expect(next, isNot(id));
        await process();
        expect((await progress.read(id))!.phase, SyncPhase.complete);
      });

      test('takeover_during_a_sync', () async {
        final id = await start();
        await ageStart(id);
        lease = await takeover();
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        final next = await start(connection: _nextConnection);
        final old = (await progress.read(id))!;
        expect(old.phase, SyncPhase.failed);
        expect(old.reason, 'holder_lost');
        expect(old.readEndAt, isNotNull);
        expect(next, isNot(id));
      });

      test('reconnect_during_a_sync_same_generation', () async {
        final id = await start();
        await ageStart(id);
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        final next = await start(connection: _nextConnection);
        final old = (await progress.read(id))!;
        expect(old.phase, SyncPhase.failed);
        expect(old.reason, 'interrupted');
        expect(old.readEndAt, isNotNull);
        expect(next, isNot(id));
      });

      test('close_not_recorded_before_the_reconnect', () async {
        final id = await start();
        await ageStart(id);
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        await start(connection: _nextConnection);
        final old = (await progress.read(id))!;
        expect(old.readEndAt, isNotNull);
        final stale = await progress.start(lease, connectionId: _connection);
        expect(stale.disposition, SyncStartDisposition.busy);
        expect(
          (await statuses.read(icinga2DbSourceId))?.currentSyncId,
          isNotNull,
        );
        expect(old.phase, SyncPhase.failed);
        expect(old.reason, 'interrupted');
      });

      test('takeover_after_a_row_failed_during_reading', () async {
        final id = await start();
        await admit(id, invalid: true);
        await process();
        final failed = (await progress.read(id))!;
        expect(failed.readEndAt, isNull);
        final originalReason = failed.reason;
        await ageStart(id);
        lease = await takeover();
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        await start(connection: _nextConnection);
        final old = (await progress.read(id))!;
        expect(old.phase, SyncPhase.failed);
        expect(old.reason, originalReason);
        expect(old.readProblem, 'holder_lost');
        expect(old.readEndAt, isNotNull);
        expect(old.rowsFailed, 1);
      });

      test('source_removed_during_a_database_outage', () async {
        final id = await start();
        await admit(id);
        await publishSources(2, []);
        await expire();
        expect(
          await progress.retire(
            icinga2DbSourceId,
            generation: lease.generation,
          ),
          isTrue,
        );
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.failed);
        expect(row.reason, 'source_retired');
        expect(row.readEndAt, isNotNull);
        final status = (await statuses.read(icinga2DbSourceId))!;
        expect(status.state, StreamConsumerState.retired);
        expect(status.gapCount, 1);
        await ageEnd(id, '31 days');
        expect(await progress.prune(icinga2DbSourceId), 0);
        await process();
        expect(await progress.prune(icinga2DbSourceId), 1);
      });

      test('disabled_source_s_progress_pruned', () async {
        final id = await start();
        await progress.finish(lease, id, const SyncReadReport());
        await ageEnd(id, '31 days');
        await publishSources(2, [
          streamSource(icinga2DbSourceId, enabled: false),
        ]);
        await expire();
        await progress.retire(icinga2DbSourceId, generation: lease.generation);
        expect(await progress.prune(icinga2DbSourceId), 1);
        expect(await progress.read(id), isNull);
      });

      test('source_re_added_after_a_long_absence', () async {
        final id = await start();
        await request(7);
        await publishSources(2, []);
        await expire();
        await progress.retire(icinga2DbSourceId, generation: lease.generation);
        await ageEnd(id, '40 days');
        expect(await progress.prune(icinga2DbSourceId), 1);
        await publishSources(3, [
          streamSource(icinga2DbSourceId),
        ], material: true);
        final next = (await leases.acquire(icinga2DbSourceId, 'worker-b'))!;
        expect(next.generation, greaterThan(lease.generation));
        expect(await statuses.startConnection(next, _nextConnection), 2);
        final result = await progress.start(
          next,
          connectionId: _nextConnection,
        );
        expect(result.servedResyncSeq, 7);
        expect((await statuses.read(icinga2DbSourceId))!.servedResyncSeq, 7);
      });

      test('source_re_enabled_during_the_retirement_sweep', () async {
        final id = await start();
        await publishSources(2, [
          streamSource(icinga2DbSourceId, enabled: false),
        ]);
        await expire();
        final endpoint = await StreamDatabaseEndpoint.resolve(
          session.serverpod,
        );
        final other = await endpoint.open(
          queryTimeout: const Duration(minutes: 5),
        );
        addTearDown(other.close);
        final contender = await endpoint.open(
          queryTimeout: const Duration(minutes: 5),
        );
        addTearDown(contender.close);
        final witness = await PostgresLockWitness.start(session);
        addTearDown(witness.close);
        final locked = Completer<LockActor>();
        final release = ContentionGate();
        final publication = release.run(
          () => other.runTx((tx) async {
            final actor = await lockActor(tx);
            await tx.execute('''UPDATE ingest_source SET enabled=true
          WHERE "sourceId"='$icinga2DbSourceId'::uuid''');
            locked.complete(actor);
            await release.future;
          }),
        );
        final blocker = await Future.any([
          locked.future,
          publication.then<LockActor>(
            (_) => throw StateError('Publication did not lock the source'),
          ),
        ]);
        final entered = Completer<LockActor>();
        final sweep = release.run(
          () => SyncProgressStore(contender).retire(
            icinga2DbSourceId,
            generation: lease.generation,
            beforeSourceLockForTest: (tx) async => entered.complete(
              await lockActor(tx, waiter: SqlTimeouts.streamWrite),
            ),
          ),
        );
        try {
          final waiter = await Future.any([
            entered.future,
            sweep.then<LockActor>(
              (_) =>
                  throw StateError('Retirement did not wait for publication'),
            ),
          ]);
          await witness.blockedBy(
            waiter,
            blocker,
            sweep,
            statement: 'SELECT enabled FROM ingest_source',
          );
        } finally {
          await release.join();
        }
        await publication;
        expect(await sweep, isFalse);
        lease = (await leases.acquire(icinga2DbSourceId, 'worker-b'))!;
        expect((await progress.read(id))!.readEndAt, isNull);
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        expect(
          (await statuses.read(icinga2DbSourceId))!.state,
          isNot(StreamConsumerState.retired),
        );
      });

      test('rows_removed_before_the_outcome_is_read', () async {
        final id = await start();
        await admit(id);
        await process();
        await progress.finish(
          lease,
          id,
          const SyncReadReport(counts: {'objects': 1}),
        );
        await session.db.unsafeExecute(
          "DELETE FROM raw_inbox WHERE status='done'",
        );
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.complete);
        expect(row.rowsDone, 1);
        expect(row.counts['objects'], 1);
        expect(row.counts['applied'], 1);
      });

      test('row_done_after_a_takeover', () async {
        final id = await start();
        await admit(id);
        await ageStart(id);
        lease = await takeover();
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        await start(connection: _nextConnection);
        await process();
        final row = (await progress.read(id))!;
        expect(row.phase, SyncPhase.failed);
        expect(row.reason, 'holder_lost');
        expect(row.rowsDone, 1);
        expect(row.counts['applied'], 1);
      });

      test('row_pending_past_30_days', () async {
        final id = await start();
        await admit(id);
        await progress.finish(
          lease,
          id,
          const SyncReadReport(problem: SyncReadProblem.truncated),
        );
        await ageEnd(id, '31 days');
        expect(await progress.prune(icinga2DbSourceId), 0);
        await process();
        expect(await progress.prune(icinga2DbSourceId), 1);
      });

      test('request_during_a_sync', () async {
        final id = await start();
        await failStreamRow();
        final busy = await progress.start(lease, connectionId: _connection);
        expect(busy.disposition, SyncStartDisposition.busy);
        expect((await statuses.read(icinga2DbSourceId))!.servedResyncSeq, 0);
        await progress.finish(lease, id, const SyncReadReport());
        await ageStart(id);
        final next = await progress.start(lease, connectionId: _connection);
        expect(next.disposition, SyncStartDisposition.started);
        expect(next.servedResyncSeq, 1);
        expect(await progress.read(id), isNotNull);
        expect(await progress.read(next.syncId!), isNotNull);
      });

      test('request_and_start_at_the_same_moment', () async {
        await request(1);
        final first = await progress.start(lease, connectionId: _connection);
        expect(first.servedResyncSeq, 1);
        await request(2);
        expect((await statuses.read(icinga2DbSourceId))!.servedResyncSeq, 1);
        await progress.finish(lease, first.syncId!, const SyncReadReport());
        await ageStart(first.syncId!);
        final next = await progress.start(lease, connectionId: _connection);
        expect(next.servedResyncSeq, 2);
      });

      test('request_while_paused', () async {
        await request(1);
        final paused = await progress.start(
          lease,
          connectionId: _connection,
          paused: true,
        );
        expect(paused.disposition, SyncStartDisposition.paused);
        expect((await statuses.read(icinga2DbSourceId))!.servedResyncSeq, 0);
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        final next = await progress.start(lease, connectionId: _nextConnection);
        expect(next.disposition, SyncStartDisposition.started);
        expect(next.servedResyncSeq, 1);
      });

      test('connection_flapping', () async {
        final id = await start();
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        for (var i = 0; i < 10; i++) {
          final result = await progress.start(
            lease,
            connectionId: _nextConnection,
          );
          expect(result.disposition, SyncStartDisposition.tooSoon);
          expect(result.retryAfter, greaterThan(Duration.zero));
        }
        expect(await countRows(session, 'icinga2_sync_progress'), 1);
        await ageStart(id);
        expect(
          (await progress.start(
            lease,
            connectionId: _nextConnection,
          )).disposition,
          SyncStartDisposition.started,
        );
      });

      test('takeover_inside_the_spacing_window', () async {
        final id = await start();
        lease = await takeover();
        expect(await statuses.startConnection(lease, _nextConnection), 2);
        final early = await progress.start(
          lease,
          connectionId: _nextConnection,
        );
        expect(early.disposition, SyncStartDisposition.tooSoon);
        expect(early.retryAfter, greaterThan(Duration.zero));
        await ageStart(id);
        final next = await progress.start(lease, connectionId: _nextConnection);
        expect(next.disposition, SyncStartDisposition.started);
        expect((await progress.read(id))!.reason, 'holder_lost');
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    ephemeralDatabase: false,
    configOverride: cluster.override,
    testGroupTagsOverride: ['db'],
  );
}
