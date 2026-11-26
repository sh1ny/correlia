import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/generated/protocol.dart';
import 'package:correlia_server/src/ingest/admission.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/pipeline/queue_operations.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart' as icinga;
import '../support/icinga2_pipeline.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as cfg;
import 'pipeline_test.dart' as fixture;

const _parents = ['events', 'outbox', 'raw_inbox'];
const _predecessorVersion = 14;
const _cutoverVersion = 15;

Future<List<Object?>> _partitionedParents(Session session) async => [
  for (final row in await session.db.unsafeQuery('''
    SELECT relname FROM pg_class
    WHERE oid IN ('events'::regclass,'outbox'::regclass,'raw_inbox'::regclass)
      AND relkind='p' ORDER BY relname
  '''))
    row[0],
];

Future<void> _predecessor(Session session) => applySchemaSteps(session, [
  for (final step in schemaSteps)
    if (step.version <= _predecessorVersion) step,
]);

Future<void> _seed(Session session, {bool placeholderLiveWork = true}) async {
  await session.db.unsafeSimpleExecute('''
    INSERT INTO raw_inbox (observed_at,raw_id,source_id,body,body_sha256,content_type,status,config_snapshot_id)
    SELECT '2020-01-01 UTC',id::uuid,'a0000000-0000-4000-8000-000000000001',
      decode('0102ff','hex'),'digest','application/json',status,'fixture-pin'
    FROM (VALUES
      ('a0000000-0000-4000-8000-000000000010','pending'),
      ('a0000000-0000-4000-8000-000000000011','failed'),
      ('a0000000-0000-4000-8000-000000000012','done')) AS r(id,status)
    ${placeholderLiveWork ? '' : "WHERE status<>'pending'"};
    INSERT INTO events (observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,
      config_snapshot_id,source_time,payload,state_outcome)
    VALUES ('2020-01-01 UTC','a0000000-0000-4000-8000-000000000020','ready',
      '2020-01-01 UTC','a0000000-0000-4000-8000-000000000012',
      'a0000000-0000-4000-8000-000000000001','fixture-pin', '2020-01-01 06:00 UTC',
      convert_to('{"subject":"upgrade","data":{}}','UTF8'),'applied');
    INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,
      output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status)
    SELECT '2020-01-02 UTC',gen_random_uuid(),observed_at,event_id,disposition,
      'a0000000-0000-4000-8000-000000000002',config_snapshot_id,'https://example.com/events',
      'historical-key','historical-commitment',payload,state
    FROM events CROSS JOIN unnest(ARRAY[${placeholderLiveWork ? "'queued'," : ''}'dead','delivered']) state;
    INSERT INTO pipeline_failures
      ("rawObservedAt","rawId","configSnapshotId","errorClass","createdAt")
    SELECT observed_at,raw_id,config_snapshot_id,'invalid_json',clock_timestamp()
    FROM raw_inbox WHERE status='failed';
  ''');
}

Future<Map<String, List<List<Object?>>>> _evidence(Session session) async => {
  for (final (table, sql) in [
    (
      'raw_inbox',
      'SELECT tableoid::bigint,ctid::text,xmin::text,pg_relation_filenode(tableoid)::bigint,'
          'observed_at,raw_id::text,source_id::text,'
          'encode(body,\'hex\'),status,config_snapshot_id FROM raw_inbox ORDER BY raw_id',
    ),
    (
      'events',
      'SELECT tableoid::bigint,ctid::text,xmin::text,pg_relation_filenode(tableoid)::bigint,'
          'observed_at,event_id::text,disposition,'
          'raw_observed_at,raw_id::text,encode(payload,\'hex\'),state_outcome FROM events',
    ),
    (
      'outbox',
      'SELECT tableoid::bigint,ctid::text,xmin::text,pg_relation_filenode(tableoid)::bigint,'
          'created_at,delivery_id::text,event_id::text,'
          'encode(payload,\'hex\'),status,config_snapshot_id FROM outbox ORDER BY delivery_id',
    ),
  ])
    table: [for (final row in await session.db.unsafeQuery(sql)) row.toList()],
};

void main() {
  withServerpod(
    'pipeline partition cutover',
    (builder, _) {
      test('partition_cutover_fresh_and_populated', () async {
        final session = builder.build();
        await _predecessor(session);
        await _seed(session, placeholderLiveWork: false);
        final first = cfg.input(1);
        final destination = first.outputs.single as WebhookIngestOutput;
        final oldReceipt = DateTime.utc(2020, 1, 1);
        await seedSigningSecret(
          session,
          destination.signingKeyRef,
          base64Url.decode(base64Url.normalize(cfg.token(2))),
        );
        // Step 14 has these tables, but not the new publication queue helper.
        await session.db.transaction((tx) async {
          await session.db.unsafeSimpleExecute(
            "SET LOCAL correlia.publisher_version='2'",
            transaction: tx,
          );
          await session.db.unsafeExecute(
            '''
            INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson") VALUES (@pin,1,@json)
          ''',
            parameters: QueryParameters.named({
              'pin': first.snapshotId,
              'json': first.publicJson,
            }),
            transaction: tx,
          );
          await session.db.unsafeExecute(
            '''
            INSERT INTO ingest_active_config(singleton,"snapshotId") VALUES (1,@pin)
          ''',
            parameters: QueryParameters.named({'pin': first.snapshotId}),
            transaction: tx,
          );
        });
        await fixture.seed(session, [
          payload.alert(
            startsAt: oldReceipt.toIso8601String(),
            labels: {'alertname': 'pre-cutover'},
          ),
        ], observed: oldReceipt);
        final migratedRaw =
            (await session.db.unsafeQuery(
                  '''
          UPDATE raw_inbox SET config_snapshot_id=@pin WHERE status='pending' RETURNING raw_id::text
        ''',
                  parameters: QueryParameters.named({'pin': first.snapshotId}),
                )).single[0]!
                as String;
        final legacyDelivery = (await session.db.unsafeQuery(
          '''
          INSERT INTO outbox(created_at,delivery_id,event_observed_at,event_id,event_disposition,
            output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload)
          SELECT '2020-01-02 UTC',gen_random_uuid(),observed_at,event_id,disposition,
            @output::uuid,@pin,'http://127.0.0.1:9099/events',@ref,@commitment,payload
          FROM events RETURNING delivery_id::text,payload
        ''',
          parameters: QueryParameters.named({
            'pin': first.snapshotId,
            'output': cfg.outputId,
            'ref': destination.signingKeyRef,
            'commitment': destination.signingKeyCommitment,
          }),
        )).single;
        await session.db.unsafeExecute(
          "UPDATE raw_admission_cutoff SET cutoff='2020-01-08 00:00 UTC' WHERE singleton=1",
        );
        final before = await _evidence(session);
        await applySchemaSteps(session, schemaSteps);
        expect(await _partitionedParents(session), _parents);
        expect(await _evidence(session), before);
        expect(
          (await session.db.unsafeQuery(
            'SELECT effective_floor FROM pipeline_icinga2_replay_floor',
          )).single[0],
          DateTime.utc(2020),
        );
        expect(
          (await session.db.unsafeQuery('''
            SELECT work_id::text FROM pipeline_dead_letter WHERE kind='raw'
          ''')).single[0],
          'a0000000-0000-4000-8000-000000000011',
        );
        final active = cfg.input(2);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(active);
        final receipt = DateTime.utc(2020, 1, 9);
        final worker = PipelineRepository(
          session,
          clock: () => receipt,
          elapsedForTest: () => Duration.zero,
        );
        final relay = OutputRelayRepository(
          session,
          testSecretResolver(session).resolve,
        );
        final oldClaim = (await relay.claim(cfg.outputId))!.claims.single;
        expect(oldClaim.deliveryId, legacyDelivery[0]);
        expect(oldClaim.payload, legacyDelivery[1]);
        expect(
          await relay.complete(oldClaim, const DeliveryAcknowledged()),
          isTrue,
        );
        expect(await worker.processOne(), isTrue);
        final newBody = utf8.encode(
          jsonEncode(
            payload.groupOf([
              payload.alert(
                startsAt: receipt.toIso8601String(),
                labels: {'alertname': 'post-cutover'},
              ),
            ]),
          ),
        );
        expect(
          await IngestAdmission(session).admit(
            sourceId: cfg.sourceId,
            kind: 'alertmanager',
            credential: active.sources.single.credentials.single,
            pathToken: false,
            body: newBody,
            contentType: 'application/json',
            observedAt: receipt,
          ),
          AdmissionOutcome.accepted,
        );
        expect(await worker.pinOne(), isTrue);
        expect(await worker.processOne(), isTrue);
        final finished = await session.db.unsafeQuery('''
          SELECT raw_id::text,tableoid::bigint,config_snapshot_id,status FROM raw_inbox
          WHERE source_id=@source::uuid ORDER BY observed_at
        ''', parameters: QueryParameters.named({'source': cfg.sourceId}));
        expect(finished, hasLength(2));
        expect(finished.first.toList(), [
          migratedRaw,
          before['raw_inbox']!.first[0],
          first.snapshotId,
          'done',
        ]);
        expect(finished.last[1], isNot(finished.first[1]));
        expect(finished.last.toList().skip(2), [active.snapshotId, 'done']);
        final saved = await session.db.unsafeQuery('''
          SELECT raw_id::text,config_snapshot_id,disposition FROM events
          WHERE source_id=@source::uuid ORDER BY observed_at
        ''', parameters: QueryParameters.named({'source': cfg.sourceId}));
        expect(saved.map((row) => row.toList()), [
          [migratedRaw, first.snapshotId, 'ready'],
          [finished.last[0], active.snapshotId, 'ready'],
        ]);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'Icinga2 work pending at cutover',
    (builder, _) {
      test('post_cutover_failure_does_not_inherit_the_legacy_floor', () async {
        final session = builder.build();
        await _predecessor(session);
        final observed = DateTime.utc(2026, 11, 10);
        final document = icinga.delivery(
          set: {
            'last_state_change': timeText(observed),
            'notification_time': timeText(observed),
          },
        );
        final id = await seedIcinga2(session, document, observed);
        final legacy = await seedIcinga2(
          session,
          icinga.delivery(set: {...document, 'host': 'pre-cutover-failure'}),
          observed,
        );
        await session.db.unsafeSimpleExecute('''
          UPDATE raw_inbox SET status='failed' WHERE raw_id='$legacy';
          INSERT INTO pipeline_failures ("rawObservedAt","rawId","errorClass","createdAt")
          VALUES ('${observed.toIso8601String()}','$legacy','validation','${observed.toIso8601String()}')
        ''');
        await session.db.unsafeQuery(
          'UPDATE raw_admission_cutoff SET cutoff=@cutoff',
          parameters: QueryParameters.named({
            'cutoff': observed.add(const Duration(days: 8)),
          }),
        );
        await applySchemaSteps(session, schemaSteps);
        await publishIcinga2Config(session);
        final now = observed.add(const Duration(days: 9));
        final broken = PipelineRepository(
          session,
          clock: () => now,
          elapsedForTest: () => Duration.zero,
          retryDelay: (_) => Duration.zero,
          afterClaim: () async => throw StateError('fixture'),
        );
        expect(await broken.pinOne(), isTrue);
        for (var i = 0; i < 5; i++) {
          expect(await broken.processOne(), isTrue);
        }
        final operations = QueueOperations(
          session,
          clock: () => now,
          secretStore: testSecretStore,
        );
        final failures = (await operations.list(
          QueueFailureFilter(kind: QueueFailureKind.raw),
        )).failures;
        expect(
          failures.map((entry) => entry.workId),
          unorderedEquals([id, legacy]),
        );
        final failure = failures.singleWhere((entry) => entry.workId == id);
        expect(
          (await operations.replayOne(
            QueueFailureKind.raw,
            failure.occurrence,
            'operator',
          )).queued,
          1,
        );
        expect(
          await PipelineRepository(
            session,
            clock: () => now,
            elapsedForTest: () => Duration.zero,
          ).processOne(),
          isTrue,
        );
        final outcome = await outcomeOf(session, id);
        expect(outcome['late'], 0);
        expect(outcome['committed'], 1);
        expect(await countRows(session, 'outbox'), 2);
        expect(
          (await operations.replayOne(
            QueueFailureKind.raw,
            failures.singleWhere((entry) => entry.workId == legacy).occurrence,
            'operator',
          )).queued,
          1,
        );
        expect(
          await PipelineRepository(
            session,
            clock: () => now,
            elapsedForTest: () => Duration.zero,
          ).processOne(),
          isTrue,
        );
        final replayedLegacy = await outcomeOf(session, legacy);
        expect(replayedLegacy['late'], 1);
        expect(replayedLegacy['committed'], 0);
        expect(await countRows(session, 'outbox'), 2);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'terminal delivery times at cutover',
    (builder, _) {
      test('oversized_plugin_does_not_inherit_an_old_retry_time', () async {
        final session = builder.build();
        await _predecessor(session);
        await _seed(session, placeholderLiveWork: false);
        await session.db.unsafeSimpleExecute('''
          UPDATE outbox SET output_kind='plugin',definition_digest=repeat('a',64),
            target_url=NULL,signing_key_ref=NULL,signing_key_commitment=NULL,
            attempt_count=1,dead_reason='payload_too_large'
          WHERE status='dead';
          UPDATE outbox SET attempt_count=1,status='dead',dead_reason='http_permanent'
          WHERE status='delivered';
          INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId",
            "startedAt","finishedAt",outcome,"errorClass")
          SELECT created_at,delivery_id,1,gen_random_uuid(),'2020-01-03 UTC','2020-01-03 UTC',
            CASE WHEN output_kind='plugin' THEN 'retryable' ELSE 'permanent' END,
            CASE WHEN output_kind='plugin' THEN 'plugin_connection_lost' ELSE 'http_permanent' END
          FROM outbox;
          INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,
            output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,attempt_count)
          SELECT created_at,gen_random_uuid(),event_observed_at,event_id,event_disposition,
            output_id,config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,'delivered',1
          FROM outbox WHERE output_kind='webhook';
          INSERT INTO delivery_attempts ("outboxCreatedAt","deliveryId","attemptNumber","claimId",
            "startedAt","finishedAt",outcome)
          SELECT created_at,delivery_id,1,gen_random_uuid(),'2020-01-03 UTC','2020-01-03 UTC','acknowledged'
          FROM outbox WHERE status='delivered';
        ''');
        await applySchemaSteps(session, schemaSteps);
        final times = await session.db.unsafeQuery('''
          SELECT o.output_kind,f.failed_at FROM outbox o
          JOIN pipeline_dead_letter f ON (f.work_at,f.work_id)=(o.created_at,o.delivery_id)
          WHERE f.kind='delivery' ORDER BY o.output_kind
        ''');
        expect(
          (times.last[0], times.last[1]),
          ('webhook', DateTime.utc(2020, 1, 3)),
        );
        expect(times.first[0], 'plugin');
        expect(times.first[1], isNot(DateTime.utc(2020, 1, 3)));
        expect(
          (await session.db.unsafeQuery(
            "SELECT correlia_maintain('outbox','2020-01-10 UTC',100)",
          )).single[0],
          0,
        );
        expect(
          (await session.db.unsafeQuery(
            "SELECT correlia_maintain('outbox','2020-01-10 00:00:00.000001 UTC',100)",
          )).single[0],
          1,
        );
        await session.db.unsafeQuery(
          "SELECT correlia_maintain('expiry',clock_timestamp(),100)",
        );
        expect(
          (await session.db.unsafeQuery('''
          SELECT status FROM outbox ORDER BY output_kind
        ''')).map((row) => row[0]),
          ['dead', 'discarded'],
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'pipeline partition catalog',
    (builder, _) {
      test('parent_indexes_helper_and_cross_child_cutoff', () async {
        final session = builder.build();
        await _predecessor(session);
        await _seed(session);
        await applySchemaSteps(session, schemaSteps);
        expect(await _partitionedParents(session), _parents);
        final daily = {
          for (final row in await session.db.unsafeQuery('''
            SELECT DISTINCT ON (parent_name) parent_name,child_name
            FROM pipeline_partition_range WHERE isfinite(first_day)
            ORDER BY parent_name,first_day DESC
          '''))
            row[0]: row[1],
        };
        final indexes = await session.db.unsafeQuery('''
          SELECT p.relname,i.indrelid::regclass::text FROM pg_inherits h
          JOIN pg_class p ON p.oid=h.inhparent
          JOIN pg_index i ON i.indexrelid=h.inhrelid AND i.indisvalid
          WHERE p.relname IN ('raw_pending_receipt_idx','raw_stream_retained_idx',
            'events_subject_idx','outbox_definition_status_idx')
        ''');
        expect(
          indexes.map((row) => (row[0], row[1])),
          containsAll([
            for (final (parent, index) in [
              ('events', 'events_subject_idx'),
              ('outbox', 'outbox_definition_status_idx'),
              ('raw_inbox', 'raw_pending_receipt_idx'),
              ('raw_inbox', 'raw_stream_retained_idx'),
            ]) ...[
              (index, 'legacy_$parent'),
              (index, daily[parent]),
            ],
          ]),
        );
        final times = await session.db.unsafeQuery(
          'SELECT events_effective_source_time(e) FROM events e',
        );
        expect(times.single[0], DateTime.utc(2020, 1, 1, 0, 5));
        await session.db.unsafeExecute('''
          UPDATE raw_admission_cutoff SET cutoff='2020-01-01 00:01 UTC'
          WHERE singleton=1
        ''');
        await expectLater(
          session.db.unsafeQuery('''
            INSERT INTO raw_inbox (observed_at,raw_id,source_id,body,body_sha256,content_type)
            SELECT receipt,gen_random_uuid(),gen_random_uuid(),decode('02','hex'),
              'digest','application/json' FROM unnest(ARRAY[
              '2020-01-01 00:00 UTC'::timestamptz,
              (SELECT max(first_day)::timestamp AT TIME ZONE 'UTC'
               FROM pipeline_partition_range WHERE parent_name='raw_inbox')]) receipt
          '''),
          throwsA(
            isA<DatabaseQueryException>().having(
              (e) => e.code,
              'code',
              'CR001',
            ),
          ),
        );
        expect((await _evidence(session))['raw_inbox'], hasLength(3));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'pipeline partition deadline defaults',
    (builder, _) {
      test(
        'production_cutover_has_a_separate_client_deadline',
        () async {
          final session = builder.build();
          await _predecessor(session);
          await _seed(session);
          var cutoverStarted = false;
          final deadlines = <Duration>[];
          Future<void> observe(Transaction tx, SchemaStep step) async {
            expect(step.version, _cutoverVersion);
            expect(
              (await session.db.unsafeQuery(
                "SELECT current_setting('lock_timeout')",
                transaction: tx,
              )).single[0],
              '30s',
            );
            cutoverStarted = true;
          }

          await runZoned(
            () => applySchemaSteps(
              session,
              [schemaSteps.singleWhere((s) => s.version == _cutoverVersion)],
              beforeStepForTest: observe,
            ),
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, delay, callback) {
                if (cutoverStarted) deadlines.add(delay);
                return parent.createTimer(zone, delay, callback);
              },
            ),
          );
          expect(deadlines, contains(const Duration(hours: 1)));
          expect(await _partitionedParents(session), _parents);
        },
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'pipeline partition transaction',
    (builder, _) {
      test('partition_cutover_rollback_and_retry', () async {
        final session = builder.build();
        await _predecessor(session);
        await _seed(session);
        final before = await _evidence(session);
        final step = schemaSteps
            .where((step) => step.version == _cutoverVersion)
            .singleOrNull;
        expect(
          step,
          isNotNull,
          reason: 'the partition cutover must be present',
        );
        await expectLater(
          applySchemaSteps(session, [
            SchemaStep(_cutoverVersion, '${step!.sql}\nSELECT 1 / 0;'),
          ]),
          throwsA(
            isA<SchemaStepException>().having(
              (e) => e.version,
              'version',
              _cutoverVersion,
            ),
          ),
        );
        expect(await _partitionedParents(session), isEmpty);
        expect(await _evidence(session), before);
        final failed = await session.db.unsafeQuery('''
          SELECT version FROM correlia_schema_versions WHERE version=$_cutoverVersion
        ''');
        expect(failed, isEmpty);
        final deadlines = <Duration>[];
        var scriptsStarted = false;
        await runZoned(
          () => applySchemaSteps(
            session,
            schemaSteps,
            partitionCutoverTimeoutSeconds: 7200,
            beforeStepForTest: (tx, step) async {
              expect(step.version, _cutoverVersion);
              expect(
                (await session.db.unsafeQuery(
                  "SELECT current_setting('lock_timeout')",
                  transaction: tx,
                )).single[0],
                '30s',
              );
              scriptsStarted = true;
            },
          ),
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, delay, callback) {
              if (scriptsStarted) deadlines.add(delay);
              return parent.createTimer(zone, delay, callback);
            },
          ),
        );
        expect(deadlines, contains(const Duration(hours: 2)));
        expect(
          (await session.db.unsafeQuery('''
            SELECT version FROM correlia_schema_versions WHERE version=$_cutoverVersion
          ''')).single[0],
          _cutoverVersion,
        );
        expect(await _partitionedParents(session), _parents);
        expect(await _evidence(session), before);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'pipeline partitions on fresh install',
    (builder, _) {
      test('fresh schema has the same partitioned parents', () async {
        final session = builder.build();
        await initializeSchema(session);
        expect(await _partitionedParents(session), _parents);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
