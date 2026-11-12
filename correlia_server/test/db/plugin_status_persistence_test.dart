import 'package:correlia_server/src/plugin/plugin_health_repository.dart';
import 'package:correlia_server/src/plugin/plugin_status_repository.dart';
import 'package:correlia_server/src/plugin/slot_scheduler.dart';
import 'package:correlia_server/src/plugin/supervision_policy.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

void main() {
  withServerpod(
    'plugin status retention',
    (builder, _) {
      test('stale_dead_hosts_and_nonlive_health_are_pruned', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final now = DateTime.utc(2026);
        final old = now.subtract(const Duration(hours: 25));
        const live = PluginKey('22222222-2222-4222-8222-222222222222', 'live');
        const terminal = PluginKey(
          '22222222-2222-4222-8222-222222222222',
          'terminal',
        );
        final owner = PluginStatusRepository(session, 'owner');
        final dead = PluginStatusRepository(session, 'dead');
        Future<void> write(
          PluginStatusRepository repository,
          PluginKey key,
          String state,
          DateTime heartbeat,
        ) {
          final policy = SupervisionPolicy(clock: () => now)
            ..start()
            ..failed('plugin_start_failed');
          return repository.write(
            PluginStatusSnapshot(
              key: key,
              state: state,
              restartCount: 1,
              crashesInWindow: 1,
              heartbeatAt: heartbeat,
            ),
            policy,
          );
        }

        await write(owner, live, 'ready', now);
        await write(
          owner,
          terminal,
          'stopped',
          now.subtract(const Duration(seconds: 61)),
        );
        await write(dead, live, 'ready', old);
        expect(await dead.isStale(live, now), isTrue);
        expect(await owner.isStale(live, now), isFalse);
        expect(
          await owner.isStale(live, now.add(const Duration(seconds: 59))),
          isFalse,
        );
        expect(
          await owner.isStale(live, now.add(const Duration(seconds: 60))),
          isFalse,
        );
        expect(
          await owner.isStale(live, now.add(const Duration(seconds: 61))),
          isTrue,
        );
        expect(
          await owner.isStale(const PluginKey('missing', 'missing'), now),
          isNull,
        );
        await session.db.unsafeExecute(
          '''INSERT INTO outbox
        (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
         config_snapshot_id,payload,output_kind,definition_digest)
        VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',CAST(@output AS uuid),
          'snapshot',decode('7b7d','hex'),'plugin',@digest)''',
          parameters: QueryParameters.named({
            'output': live.outputId,
            'digest': live.digest,
          }),
        );
        await owner.prune(now);
        await PluginHealthRepository(session, 'owner').prune();
        await owner.prune(now.add(const Duration(minutes: 1)));
        final statuses = await session.db.unsafeQuery(
          'SELECT "hostInstanceId",state FROM plugin_instance_status',
        );
        expect(statuses.map((row) => row.toList()).toList(), [
          ['owner', 'ready'],
        ]);
        final health = await session.db.unsafeQuery(
          'SELECT "hostInstanceId","definitionDigest" FROM plugin_definition_health',
        );
        expect(health.map((row) => row.toList()).toList(), [
          ['owner', 'live'],
        ]);
      });
      test(
        'configure_rejection_keeps_host_and_plugin_classes_separate',
        () async {
          final session = builder.build();
          final now = DateTime.utc(2026);
          final policy = SupervisionPolicy(clock: () => now)
            ..start()
            ..failed('plugin_config_rejected');
          final repository = PluginStatusRepository(session, 'diagnostic-host');
          await repository.write(
            PluginStatusSnapshot(
              key: const PluginKey('output', 'digest'),
              state: 'backoff',
              restartCount: 1,
              crashesInWindow: 1,
              heartbeatAt: now,
              lastErrorClass: 'plugin_config_rejected',
              lastPluginErrorClass: 'stream_missing',
            ),
            policy,
          );
          final row = (await session.db.unsafeQuery(
            '''SELECT "lastErrorClass","lastPluginErrorClass"
        FROM plugin_instance_status WHERE "hostInstanceId"='diagnostic-host' ''',
          )).single;
          expect(row.toList(), ['plugin_config_rejected', 'stream_missing']);
          final health = (await session.db.unsafeQuery(
            '''SELECT "lastErrorClass"
        FROM plugin_definition_health WHERE "hostInstanceId"='diagnostic-host' ''',
          )).single;
          expect(health[0], 'plugin_config_rejected');
        },
      );
      test('live_host_with_only_stopped_rows_keeps_health', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final now = DateTime.utc(2026);
        const host = 'alive-stopped';
        await _seedStoppedHealth(session, host, now);
        final before = await _healthState(session, host);
        expect(before.single.take(2), [1, 1]);

        await PluginStatusRepository(session, 'observer-stopped').prune(now);

        expect(await _healthState(session, host), before);
        final statuses = await session.db.unsafeQuery(
          'SELECT state FROM plugin_instance_status WHERE "hostInstanceId"=@host',
          parameters: QueryParameters.named({'host': host}),
        );
        expect(statuses.map((row) => row[0]).toList(), ['stopped']);
      });
      test('dead_host_health_expires_after_self_prune', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final now = DateTime.utc(2026);
        const host = 'stopped-then-dead';
        final deliveryId = await _seedStoppedHealth(session, host, now);
        final before = await _healthState(session, host);
        expect(before.single.take(2), [1, 1]);

        await PluginStatusRepository(session, host).prune(now);

        final retained = await session.db.unsafeQuery(
          'SELECT state FROM plugin_instance_status WHERE "hostInstanceId"=@host',
          parameters: QueryParameters.named({'host': host}),
        );
        expect(retained.map((row) => row[0]).toList(), ['stopped']);
        expect(await _healthState(session, host), before);

        await PluginStatusRepository(
          session,
          'expiry-observer',
        ).prune(now.add(const Duration(hours: 24)));

        expect(await _healthState(session, host), isEmpty);
        final expired = await session.db.unsafeQuery(
          'SELECT state FROM plugin_instance_status WHERE "hostInstanceId"=@host',
          parameters: QueryParameters.named({'host': host}),
        );
        expect(expired, isEmpty);
        final work = await session.db.unsafeQuery(
          'SELECT status FROM outbox WHERE delivery_id=CAST(@delivery AS uuid)',
          parameters: QueryParameters.named({'delivery': deliveryId}),
        );
        expect(work.single[0], 'queued');
      });
      test('pruning_spans_bounded_batches_and_preserves_live_host', () async {
        final session = builder.build();
        await session.db.unsafeSimpleExecute(
          'DELETE FROM plugin_definition_health',
        );
        await session.db.unsafeSimpleExecute(
          'DELETE FROM plugin_instance_status',
        );
        final now = DateTime.utc(2026);
        await session.db.unsafeExecute(
          '''INSERT INTO plugin_instance_status
        ("hostInstanceId","outputId","definitionDigest",state,"restartCount","crashesInWindow",version,"heartbeatAt")
        SELECT host,'output',i::text,'stopped',0,0,1,heartbeat
        FROM (VALUES ('dead-many',@dead::timestamp),('alive-many',@alive::timestamp))
          hosts(host,heartbeat),generate_series(1,300) i''',
          parameters: QueryParameters.named({
            'dead': now.subtract(const Duration(hours: 25)),
            'alive': now.subtract(const Duration(seconds: 61)),
          }),
        );
        await session.db.unsafeExecute(
          '''INSERT INTO plugin_instance_status
        ("hostInstanceId","outputId","definitionDigest",state,"restartCount","crashesInWindow",version,"heartbeatAt")
        VALUES ('alive-many','output','active','ready',0,0,1,@now)''',
          parameters: QueryParameters.named({'now': now}),
        );
        await session.db.unsafeSimpleExecute(
          '''INSERT INTO plugin_definition_health
        ("hostInstanceId","outputId","definitionDigest","failureTimes","backoffStep",circuit)
        SELECT host,'output',i::text,'[]',1,'closed'
        FROM (VALUES ('dead-many'),('alive-many')) hosts(host),generate_series(1,300) i''',
        );
        await PluginStatusRepository(session, 'observer').prune(now);
        final statuses = await session.db.unsafeQuery(
          '''SELECT "hostInstanceId",state,count(*) FROM plugin_instance_status
          GROUP BY "hostInstanceId",state ORDER BY "hostInstanceId",state''',
        );
        expect(statuses.map((row) => row.toList()).toList(), [
          ['alive-many', 'ready', 1],
          ['alive-many', 'stopped', 300],
        ]);
        final health = await session.db.unsafeQuery(
          '''SELECT "hostInstanceId",count(*)
        FROM plugin_definition_health GROUP BY "hostInstanceId"''',
        );
        expect(health.map((row) => row.toList()).toList(), [
          ['alive-many', 300],
        ]);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}

Future<String> _seedStoppedHealth(
  Session session,
  String host,
  DateTime now,
) async {
  const key = PluginKey('22222222-2222-4222-8222-222222222222', 'kept-health');
  await PluginStatusRepository(session, host).write(
    PluginStatusSnapshot(
      key: key,
      state: 'stopped',
      restartCount: 1,
      crashesInWindow: 1,
      heartbeatAt: now.subtract(const Duration(seconds: 61)),
    ),
    SupervisionPolicy(clock: () => now)
      ..start()
      ..failed('plugin_start_failed'),
  );
  final rows = await session.db.unsafeQuery(
    '''INSERT INTO outbox
    (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
     config_snapshot_id,payload,output_kind,definition_digest)
    VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'ready',CAST(@output AS uuid),
      'snapshot',decode('7b7d','hex'),'plugin',@digest)
    RETURNING delivery_id::text''',
    parameters: QueryParameters.named({
      'output': key.outputId,
      'digest': key.digest,
    }),
  );
  return rows.single[0] as String;
}

Future<List<List<Object?>>> _healthState(Session session, String host) async {
  final rows = await session.db.unsafeQuery(
    '''SELECT "backoffStep",jsonb_array_length("failureTimes"::jsonb),"failureTimes",
      "nextStartAt",circuit,"nextProbeAt","lastErrorClass"
    FROM plugin_definition_health WHERE "hostInstanceId"=@host''',
    parameters: QueryParameters.named({'host': host}),
  );
  return rows.map((row) => row.toList()).toList();
}
