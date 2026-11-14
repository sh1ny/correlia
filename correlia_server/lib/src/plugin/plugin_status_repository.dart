import 'dart:convert';

import 'package:serverpod/serverpod.dart';

import 'plugin_health_repository.dart';
import 'slot_scheduler.dart';
import 'supervision_policy.dart';

/// Returns whether [heartbeatAt] is more than 60 seconds before [now].
bool isPluginHeartbeatStale(DateTime heartbeatAt, DateTime now) =>
    now.difference(heartbeatAt) > const Duration(seconds: 60);

/// A complete status snapshot written by the owning supervisor.
final class PluginStatusSnapshot {
  const PluginStatusSnapshot({
    required this.key,
    required this.state,
    required this.restartCount,
    required this.crashesInWindow,
    required this.heartbeatAt,
    this.pluginName,
    this.pluginVersion,
    this.pid,
    this.lastErrorClass,
    this.lastPluginErrorClass,
  });
  final PluginKey key;
  final String state;
  final int restartCount, crashesInWindow;
  final DateTime heartbeatAt;
  final String? pluginName, pluginVersion, lastErrorClass, lastPluginErrorClass;
  final int? pid;
}

/// Writes owned status, durable health and circuit activity transactionally.
final class PluginStatusRepository {
  const PluginStatusRepository(this.session, this.hostInstanceId);
  final Session session;
  final String hostInstanceId;

  /// Replaces the snapshot, optionally recording one circuit transition.
  Future<void> write(
    PluginStatusSnapshot status,
    SupervisionPolicy health, {
    String? activity,
  }) async {
    if (activity != null &&
        activity != 'plugin_degraded' &&
        activity != 'plugin_recovered') {
      throw ArgumentError.value(activity, 'activity');
    }
    await session.db.transaction((tx) async {
      final previous = await session.db.unsafeQuery(
        '''SELECT circuit FROM plugin_definition_health
        WHERE "hostInstanceId"=@host AND "outputId"=@output AND "definitionDigest"=@digest
        FOR UPDATE''',
        parameters: QueryParameters.named({
          'host': hostInstanceId,
          'output': status.key.outputId,
          'digest': status.key.digest,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      final oldCircuit = previous.isEmpty
          ? 'closed'
          : previous.single[0] as String;
      final rows = await session.db.unsafeQuery(
        '''INSERT INTO plugin_instance_status
        ("hostInstanceId","outputId","definitionDigest",state,"pluginName","pluginVersion",
         pid,"restartCount","crashesInWindow","lastErrorClass","lastPluginErrorClass",version,"heartbeatAt")
        VALUES (@host,@output,@digest,@state,@name,@pluginVersion,@pid,@restarts,@crashes,@error,@pluginError,1,@heartbeat)
        ON CONFLICT ("hostInstanceId","outputId","definitionDigest") DO UPDATE SET
          state=EXCLUDED.state,"pluginName"=EXCLUDED."pluginName","pluginVersion"=EXCLUDED."pluginVersion",
          pid=EXCLUDED.pid,"restartCount"=EXCLUDED."restartCount","crashesInWindow"=EXCLUDED."crashesInWindow",
          "lastErrorClass"=EXCLUDED."lastErrorClass",version=plugin_instance_status.version+1,
          "lastPluginErrorClass"=EXCLUDED."lastPluginErrorClass",
          "heartbeatAt"=EXCLUDED."heartbeatAt" RETURNING id,version''',
        parameters: QueryParameters.named({
          'host': hostInstanceId,
          'output': status.key.outputId,
          'digest': status.key.digest,
          'state': status.state,
          'name': status.pluginName,
          'pluginVersion': status.pluginVersion,
          'pid': status.pid,
          'restarts': status.restartCount,
          'crashes': status.crashesInWindow,
          'error': status.lastErrorClass,
          'pluginError': status.lastPluginErrorClass,
          'heartbeat': status.heartbeatAt,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (previous.isNotEmpty ||
          health.failures.isNotEmpty ||
          health.backoffStep != 0 ||
          health.circuit != PluginCircuit.closed) {
        await PluginHealthRepository(
          session,
          hostInstanceId,
        ).save(status.key, health, transaction: tx);
      }
      if (activity != null &&
          ((activity == 'plugin_degraded' &&
                  oldCircuit == 'closed' &&
                  health.circuit == PluginCircuit.open) ||
              (activity == 'plugin_recovered' &&
                  oldCircuit == 'probing' &&
                  health.circuit == PluginCircuit.closed))) {
        await session.db.unsafeExecute(
          '''INSERT INTO activity
          (occurred_at,entity_kind,entity_id,entity_version,change_kind,actor_kind)
          VALUES (@time,'plugin',@id,@version,@change,'supervisor')''',
          parameters: QueryParameters.named({
            'time': status.heartbeatAt,
            'id': rows.single[0],
            'version': rows.single[1],
            'change': activity,
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
      }
    });
  }

  /// Records a definition waiting for a worker or output slot.
  Future<void> writeWaiting(PluginKey key, DateTime now) async {
    await session.db.unsafeExecute(
      '''INSERT INTO plugin_instance_status
      ("hostInstanceId","outputId","definitionDigest",state,"restartCount","crashesInWindow",
       "lastErrorClass",version,"heartbeatAt")
      VALUES (@host,@output,@digest,'waiting',0,0,'instance_limit',1,@now)
      ON CONFLICT ("hostInstanceId","outputId","definitionDigest") DO UPDATE SET
        state='waiting',"lastErrorClass"='instance_limit',pid=NULL,
        version=plugin_instance_status.version+1,"heartbeatAt"=EXCLUDED."heartbeatAt"
      WHERE plugin_instance_status.state<>'waiting'
         OR plugin_instance_status."heartbeatAt"<@refresh''',
      parameters: QueryParameters.named({
        'host': hostInstanceId,
        'output': key.outputId,
        'digest': key.digest,
        'now': now,
        'refresh': now.subtract(const Duration(seconds: 15)),
      }),
      timeoutInSeconds: 5,
    );
  }

  /// Marks owned rows stopped, restoring forced reasons in the final statement.
  ///
  /// Keys in [forcedKeys] receive `plugin_forced_stop`; other errors are preserved.
  Future<void> markStopped(
    DateTime now, {
    required Set<PluginKey> forcedKeys,
  }) async {
    await session.db.unsafeExecute(
      '''UPDATE plugin_instance_status
      SET state='stopped',version=version+1,"heartbeatAt"=@now,
        "lastErrorClass"=CASE WHEN EXISTS (
          SELECT 1 FROM jsonb_array_elements(CAST(@forced AS jsonb)) AS forced(key)
          WHERE forced.key->>0="outputId" AND forced.key->>1="definitionDigest"
        ) THEN 'plugin_forced_stop' ELSE "lastErrorClass" END
      WHERE "hostInstanceId"=@host''',
      parameters: QueryParameters.named({
        'host': hostInstanceId,
        'now': now,
        'forced': jsonEncode([
          for (final key in forcedKeys) [key.outputId, key.digest],
        ]),
      }),
      timeoutInSeconds: 5,
    );
  }

  /// Reads whether the latest owned heartbeat is stale at [now].
  Future<bool?> isStale(PluginKey key, DateTime now) async {
    final rows = await session.db.unsafeQuery(
      '''SELECT "heartbeatAt"
      FROM plugin_instance_status WHERE "hostInstanceId"=@host
      AND "outputId"=@output AND "definitionDigest"=@digest''',
      parameters: QueryParameters.named({
        'host': hostInstanceId,
        'output': key.outputId,
        'digest': key.digest,
      }),
      timeoutInSeconds: 5,
    );
    if (rows.isEmpty) return null;
    return isPluginHeartbeatStale(rows.single[0] as DateTime, now);
  }

  /// Prunes owned stale stopped rows only when their key has no health.
  ///
  /// Other hosts' rows expire after a day, with health after their last row.
  Future<void> prune(DateTime now) async {
    while (true) {
      final removed = await session.db.transaction((tx) async {
        final rows = await session.db.unsafeQuery(
          '''WITH doomed AS (
          SELECT s.id FROM plugin_instance_status s
          WHERE (s."hostInstanceId"=@host AND s.state='stopped'
            AND s."heartbeatAt"<@stale AND NOT EXISTS (
              SELECT 1 FROM plugin_definition_health h
              WHERE h."hostInstanceId"=s."hostInstanceId"
                AND h."outputId"=s."outputId"
                AND h."definitionDigest"=s."definitionDigest"))
            OR (s."hostInstanceId"<>@host AND s."heartbeatAt"<@day)
          ORDER BY id LIMIT 256 FOR UPDATE SKIP LOCKED
        ), deleted AS (
          DELETE FROM plugin_instance_status s USING doomed d
          WHERE s.id=d.id RETURNING s.id,s."hostInstanceId"
        ), deleted_health AS (
          DELETE FROM plugin_definition_health h
          WHERE h."hostInstanceId"<>@host
            AND EXISTS (SELECT 1 FROM deleted d WHERE d."hostInstanceId"=h."hostInstanceId")
            AND NOT EXISTS (SELECT 1 FROM plugin_instance_status s
              WHERE s."hostInstanceId"=h."hostInstanceId"
                AND NOT EXISTS (SELECT 1 FROM deleted d WHERE d.id=s.id))
          RETURNING 1
        )
        SELECT count(*) FROM deleted''',
          parameters: QueryParameters.named({
            'host': hostInstanceId,
            'stale': now.subtract(const Duration(seconds: 60)),
            'day': now.subtract(const Duration(hours: 24)),
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        return rows.single[0] as int;
      });
      if (removed < 256) break;
    }
  }
}
