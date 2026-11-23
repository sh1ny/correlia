import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:postgres/postgres.dart' show Connection, Sql;
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/secret_fixture.dart';

const _connectionId = 'aaaaaaaa-0000-4000-8000-000000000001';
const _holderId = 'aaaaaaaa-0000-4000-8000-000000000002';
const _nextHolderId = 'aaaaaaaa-0000-4000-8000-000000000003';

void main() {
  withServerpod(
    'Icinga2 fenced consumer admission',
    (builder, _) {
      late Session session;
      late Connection db;
      late String snapshot;
      late StreamLease lease;
      late ConsumerAdmission admission;
      final now = streamDbNow;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        await session.db.unsafeSimpleExecute('''TRUNCATE icinga2_admitted_batch,
        icinga2_stream_lease,icinga2_stream_status,icinga2_stream_resync''');
        snapshot = await publishStreamDb(session);
        db = await openStreamDatabase(session.serverpod);
        addTearDown(db.close);
        lease = (await StreamLeaseStore(
          db,
        ).acquire(icinga2DbSourceId, _holderId))!;
        admission = ConsumerAdmission(db);
      });

      StreamAdmissionItem check({
        DateTime? received,
        bool sync = false,
        int stateType = 1,
        String service = 'stream-service',
      }) => StreamAdmissionItem.text(
        received ?? now,
        jsonEncode(
          streamDbCheck(
            now.subtract(const Duration(seconds: 10)),
            service: service,
            sync: sync,
            stateType: stateType,
          ),
        ),
      );

      StreamRawBatch batch(
        List<List<StreamAdmissionItem>> rows, {
        bool sync = false,
      }) => StreamRawBatch(
        id: const Uuid().v4(),
        connectionId: _connectionId,
        rows: rows,
        origin: sync ? IcingaStreamOrigin.sync : IcingaStreamOrigin.stream,
        syncId: sync ? streamDbSyncId : null,
      );

      Future<StreamAdmissionResult> admit(
        StreamRawBatch payload, {
        ConsumerAdmission? repository,
      }) => (repository ?? admission).admit(
        lease: lease,
        snapshotId: snapshot,
        batch: payload,
      );

      Future<void> removeSource() =>
          IngestConfigRepository(
            session,
            secretStore: testSecretStore,
          ).publishConfig(
            streamBootstrap(2, []),
            <String, Object?>{},
            runMode: 'test',
            clock: () => now,
          );

      Future<void> startSync() => session.db.unsafeExecute(
        '''INSERT INTO icinga2_sync_progress
      (sync_id,source_id,phase,started_at) VALUES ('$streamDbSyncId','$icinga2DbSourceId','reading',now())''',
      );

      Future<int> seq() async =>
          (await session.db.unsafeQuery(
                '''SELECT coalesce((SELECT "requestSeq"
      FROM icinga2_stream_resync WHERE "sourceId"='$icinga2DbSourceId'),0)''',
              )).single[0]!
              as int;

      Future<String> rawId() async =>
          (await session.db.unsafeQuery(
                'SELECT raw_id::text FROM raw_inbox',
              )).single[0]!
              as String;

      Future<void> seedRetained(
        String source,
        int count, {
        String status = 'pending',
      }) => session.db.unsafeExecute(
        '''
      INSERT INTO raw_inbox(observed_at,raw_id,source_id,body,body_sha256,content_type,status)
      SELECT @observed,gen_random_uuid(),CAST(@source AS uuid),decode('00','hex'),'fixture','application/json',@status
      FROM generate_series(1,@count)''',
        parameters: QueryParameters.named({
          'observed': now,
          'source': source,
          'count': count,
          'status': status,
        }),
      );

      test('stream_row_processed', () async {
        final input = batch([
          [for (var i = 0; i < 100; i++) check(service: 'service-$i')],
        ]);
        expect(await admit(input), StreamAdmissionResult.committed);
        final raw = await rawId();
        final initial = (await queryRows(
          session,
          'SELECT config_snapshot_id,status FROM raw_inbox',
        )).single;
        expect(initial, {'config_snapshot_id': null, 'status': 'pending'});
        await processIcinga2(session, now);
        expect(await outcomeOf(session, raw), containsPair('applied', 100));
        expect(await countRows(session, 'alerts'), 100);
        expect(await countRows(session, 'events'), 100);
        expect(await countRows(session, 'outbox'), 100);
        expect(
          (await queryRows(
            session,
            'SELECT config_snapshot_id FROM raw_inbox',
          )).single['config_snapshot_id'],
          snapshot,
        );
      });

      test('items_received_at_different_times', () async {
        final later = now.add(const Duration(milliseconds: 800));
        expect(
          await admit(
            batch([
              [check(received: later, service: 'second'), check()],
            ]),
          ),
          StreamAdmissionResult.committed,
        );
        expect(
          (await queryRows(
            session,
            'SELECT observed_at FROM raw_inbox',
          )).single['observed_at'],
          now,
        );
        await processIcinga2(session, later);
        expect(
          await queryRows(
            session,
            'SELECT observed_at,raw_observed_at FROM events ORDER BY observed_at',
          ),
          [
            {'observed_at': now, 'raw_observed_at': now},
            {'observed_at': later, 'raw_observed_at': now},
          ],
        );
      });

      test('paused_old_holder_after_takeover', () async {
        await session.db.unsafeExecute(
          '''UPDATE icinga2_stream_lease SET "expiresAt"=clock_timestamp()-interval '1 second' ''',
        );
        final other = await openStreamDatabase(session.serverpod);
        addTearDown(other.close);
        final takeover = (await StreamLeaseStore(
          other,
        ).acquire(icinga2DbSourceId, _nextHolderId))!;
        expect(takeover.generation, greaterThan(lease.generation));
        expect(
          await admit(
            batch([
              [check()],
            ]),
          ),
          StreamAdmissionResult.leaseLost,
        );
        expect(await countRows(session, 'raw_inbox'), 0);
        expect(await countRows(session, 'icinga2_admitted_batch'), 0);
      });

      test('publication_between_the_check_and_the_commit', () async {
        final checked = Completer<void>();
        final finish = Completer<void>();
        final repository = ConsumerAdmission(
          db,
          afterFence: () async {
            checked.complete();
            await finish.future;
          },
        );
        final admitting = admit(
          batch([
            [check()],
          ]),
          repository: repository,
        );
        await Future.any([checked.future, admitting.then<void>((_) {})]);
        expect(checked.isCompleted, isTrue);
        final publishing = publishStreamDb(
          builder.build(),
          revision: 2,
          apiUrl: 'https://other-icinga.example:5665',
        );
        try {
          final clock = Stopwatch()..start();
          while (true) {
            final blockers = await session.db.unsafeQuery(
              '''SELECT 1 FROM pg_stat_activity
            WHERE datname=current_database() AND query LIKE '%ingest_source%'
              AND cardinality(pg_blocking_pids(pid))>0''',
            );
            if (blockers.isNotEmpty) break;
            if (clock.elapsed > const Duration(seconds: 1)) {
              fail('Publication did not wait for the admission source lock');
            }
          }
        } finally {
          finish.complete();
          await publishing;
        }
        expect(await admitting, StreamAdmissionResult.committed);
        expect(
          await admit(
            batch([
              [check()],
            ]),
          ),
          StreamAdmissionResult.configChanged,
        );
        expect(await countRows(session, 'raw_inbox'), 1);
        expect(
          (await queryRows(
            session,
            'SELECT admission_snapshot_id FROM icinga2_raw_origin',
          )).single['admission_snapshot_id'],
          snapshot,
        );
      });

      test('lost_acknowledgement_of_a_stream_batch', () async {
        final input = batch([
          [StreamAdmissionItem.text(now, '{malformed')],
        ]);
        expect(await admit(input), StreamAdmissionResult.committed);
        expect(await admit(input), StreamAdmissionResult.committed);
        expect(await countRows(session, 'raw_inbox'), 1);
        await processIcinga2(session, now);
        expect(await countRows(session, 'pipeline_failures'), 1);
        expect(await seq(), 1);
      });

      test('lost_acknowledgement_of_a_sync_batch', () async {
        await startSync();
        final input = batch([
          [check(sync: true)],
          [check(sync: true, service: 'other')],
        ], sync: true);
        expect(await admit(input), StreamAdmissionResult.committed);
        expect(await admit(input), StreamAdmissionResult.committed);
        expect(await countRows(session, 'raw_inbox'), 2);
        expect(
          (await queryRows(
            session,
            'SELECT rows_admitted FROM icinga2_sync_progress',
          )).single['rows_admitted'],
          2,
        );
      });

      test('lost_acknowledgement_of_the_batch_that_filled_the_cap', () async {
        await seedRetained(icinga2DbSourceId, 97, status: 'failed');
        await seedRetained(icinga2DbSourceId, 2);
        await seedRetained(icinga2DbSourceId, 8, status: 'done');
        final input = batch([
          [check()],
        ]);
        expect(await admit(input), StreamAdmissionResult.committed);
        expect(await admit(input), StreamAdmissionResult.committed);
        expect(
          await admit(
            batch([
              [check()],
            ]),
          ),
          StreamAdmissionResult.atCapacity,
        );
        expect(await countRows(session, 'icinga2_admitted_batch'), 1);
        expect(await countRows(session, 'raw_inbox'), 108);
      });

      test('lost_acknowledgement_before_a_settings_change', () async {
        final input = batch([
          [check()],
        ]);
        expect(await admit(input), StreamAdmissionResult.committed);
        await publishStreamDb(
          session,
          revision: 2,
          apiUrl: 'https://other-icinga.example:5665',
        );
        expect(await admit(input), StreamAdmissionResult.committed);
        expect(
          await admit(
            batch([
              [check()],
            ]),
          ),
          StreamAdmissionResult.configChanged,
        );
        expect(await countRows(session, 'raw_inbox'), 1);
      });

      test('committed_batch_survives_cutoff', () async {
        final input = batch([
          [check()],
        ]);
        expect(await admit(input), StreamAdmissionResult.committed);
        await session.db.unsafeExecute(
          'UPDATE raw_admission_cutoff SET cutoff=@time',
          parameters: QueryParameters.named({
            'time': now.add(const Duration(microseconds: 1)),
          }),
        );
        expect(await admit(input), StreamAdmissionResult.committed);
        final rejected = batch([
          [check(received: now.add(const Duration(seconds: 1))), check()],
        ]);
        expect(
          await admit(rejected),
          StreamAdmissionResult.receiptBehindCutoff,
        );
        expect(await countRows(session, 'raw_inbox'), 1);
        expect(await countRows(session, 'icinga2_admitted_batch'), 1);
      });

      test('stream_row_under_a_snapshot_without_the_source', () async {
        expect(
          await admit(
            batch([
              [StreamAdmissionItem.text(now, '{the body cannot decode')],
            ]),
          ),
          StreamAdmissionResult.committed,
        );
        await removeSource();
        await processIcinga2(session, now);
        expect(
          await queryRows(
            session,
            'SELECT "errorClass" FROM pipeline_failures',
          ),
          [
            {'errorClass': 'source_not_configured'},
          ],
        );
        expect(await seq(), 1);
        expect(await countRows(session, 'events'), 0);
      });

      test('stream_row_refused_before_decoding', () async {
        expect(
          await admit(
            batch([
              [check()],
            ]),
          ),
          StreamAdmissionResult.committed,
        );
        await session.db.unsafeExecute(
          '''UPDATE raw_inbox SET body=convert_to('{"format":"unsupported","origin":"sync"}','UTF8')''',
        );
        await processIcinga2(session, now);
        expect(
          (await queryRows(
            session,
            'SELECT "errorClass" FROM pipeline_failures',
          )).single['errorClass'],
          'unsupported_format',
        );
        expect(
          await seq(),
          1,
          reason:
              'Failure uses stream origin from the admission record, not the body',
        );
      });

      test('policy_changed_between_admission_and_claim', () async {
        final original = snapshot;
        expect(
          await admit(
            batch([
              [check(stateType: 0)],
            ]),
          ),
          StreamAdmissionResult.committed,
        );
        final current = await publishStreamDb(
          session,
          revision: 2,
          policy: 'hard_only',
          routed: false,
        );
        await processIcinga2(session, now);
        expect((await theAlert(session))['status'], 'firing');
        expect(
          await countRows(session, 'outbox'),
          0,
          reason: 'Routes use the first-claim revision',
        );
        expect(
          (await queryRows(
            session,
            'SELECT config_snapshot_id,outcome_json FROM raw_inbox',
          )).single['config_snapshot_id'],
          current,
        );
        expect(
          (await queryRows(
            session,
            'SELECT admission_snapshot_id FROM icinga2_raw_origin',
          )).single['admission_snapshot_id'],
          original,
        );
      });
      test('sync_row_whose_source_was_removed', () async {
        await startSync();
        expect(
          await admit(
            batch([
              [check(sync: true)],
            ], sync: true),
          ),
          StreamAdmissionResult.committed,
        );
        await removeSource();
        await processIcinga2(session, now);
        expect(
          (await queryRows(
            session,
            'SELECT rows_failed,phase,reason FROM icinga2_sync_progress',
          )).single,
          {'rows_failed': 1, 'phase': 'failed', 'reason': 'row_failed'},
        );
        expect(
          (await queryRows(
            session,
            'SELECT "errorClass" FROM pipeline_failures',
          )).single['errorClass'],
          'source_not_configured',
        );
        expect(await seq(), 0);
      });

      test('sync_row_exhausts_its_retries', () async {
        await startSync();
        expect(
          await admit(
            batch([
              [check(sync: true)],
            ], sync: true),
          ),
          StreamAdmissionResult.committed,
        );
        final worker = PipelineRepository(
          session,
          clock: () => now,
          retryDelay: (_) => Duration.zero,
          afterClaim: () =>
              throw StateError('injected internal processing failure'),
        );
        expect(await worker.pinOne(), isTrue);
        for (var attempt = 1; attempt <= 5; attempt++) {
          expect(await worker.processOne(), isTrue);
          final counts = (await queryRows(
            session,
            'SELECT rows_done,rows_failed FROM icinga2_sync_progress',
          )).single;
          expect(counts, {'rows_done': 0, 'rows_failed': attempt == 5 ? 1 : 0});
        }
        expect(
          await queryRows(
            session,
            'SELECT "errorClass" FROM pipeline_failures',
          ),
          [
            {'errorClass': 'processing_exhausted'},
          ],
        );
        expect(await seq(), 0);
      });

      test('malformed_json_and_invalid_utf_8', () async {
        const malformed = '{  "unterminated":';
        final duplicate = jsonEncode(streamDbCheck(now)).replaceFirst(
          '"vars_after":{"state":2',
          '"vars_after":{"state":2,"state":0',
        );
        final binary = Uint8List.fromList([0xff, 0xc3]);
        expect(
          await admit(
            batch([
              [StreamAdmissionItem.text(now, malformed)],
              [
                StreamAdmissionItem.text(
                  now.add(const Duration(microseconds: 1)),
                  duplicate,
                ),
              ],
              [
                StreamAdmissionItem.binary(
                  now.add(const Duration(microseconds: 2)),
                  binary,
                ),
              ],
            ]),
          ),
          StreamAdmissionResult.committed,
        );
        final rows = await queryRows(
          session,
          'SELECT body FROM raw_inbox ORDER BY observed_at',
        );
        List<Map<String, Object?>> items(Map<String, Object?> raw) =>
            ((jsonDecode(utf8.decode(raw['body']! as List<int>))
                        as Map<String, Object?>)['items']!
                    as List)
                .cast<Map<String, Object?>>();
        expect(items(rows[0]).single['line'], malformed);
        expect(items(rows[1]).single['line'], duplicate);
        expect(
          base64Decode(items(rows[2]).single['line_b64']! as String),
          binary,
        );
        for (var row = 0; row < 3; row++) {
          await processIcinga2(session, now.add(const Duration(seconds: 1)));
        }
        expect(
          await queryRows(
            session,
            'SELECT "errorClass","fieldPath" FROM pipeline_failures ORDER BY "rawObservedAt"',
          ),
          [
            {'errorClass': 'invalid_json', 'fieldPath': 'body'},
            {
              'errorClass': 'duplicate_field',
              'fieldPath': 'check_result.vars_after.state',
            },
            {'errorClass': 'invalid_json', 'fieldPath': 'body'},
          ],
        );
      });

      for (final nested in [false, true]) {
        test(
          nested
              ? 'unknown_nested_member'
              : 'unknown_member_whose_name_looks_like_a_path',
          () async {
            final input = streamDbCheck(now);
            if (nested) {
              final result = input['check_result']! as Map<String, Object?>;
              (result['vars_after']! as Map<String, Object?>)['secret_hint'] =
                  'not diagnostics';
            } else {
              input['check_result.vars_after.state'] = 'not diagnostics';
            }
            expect(
              await admit(
                batch([
                  [StreamAdmissionItem.text(now, jsonEncode(input))],
                ]),
              ),
              StreamAdmissionResult.committed,
            );
            await processIcinga2(session, now);
            expect(
              await queryRows(
                session,
                'SELECT "errorClass","fieldPath" FROM pipeline_failures',
              ),
              [
                {
                  'errorClass': 'unknown_field',
                  'fieldPath': nested ? 'check_result.vars_after.*' : '*',
                },
              ],
            );
          },
        );
      }

      test('retained_count_uses_source_partial_index', () async {
        await seedRetained(icinga2OtherDbSourceId, 100000);
        await seedRetained(icinga2DbSourceId, 2, status: 'failed');
        await session.db.unsafeExecute('ANALYZE raw_inbox');
        expect(await admission.retained(icinga2DbSourceId, limit: 101), 2);
        final plan = await db.execute(
          Sql.named(
            'EXPLAIN (ANALYZE, BUFFERS) ${ConsumerAdmission.retainedCountSql}',
          ),
          parameters: {'source': icinga2DbSourceId, 'limit': 101},
        );
        final text = plan.map((row) => row[0]).join('\n');
        expect(text, contains('raw_stream_retained_idx'));
        expect(text, contains('Index Cond'));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
