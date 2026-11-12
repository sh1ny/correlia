import 'dart:convert';

import 'package:serverpod/serverpod.dart';

import 'slot_scheduler.dart';
import 'supervision_policy.dart';

/// Persists bounded per-definition supervision history outside running slots.
final class PluginHealthRepository {
  const PluginHealthRepository(this.session, this.hostInstanceId);
  final Session session;
  final String hostInstanceId;

  /// Loads a definition's durable health, or its initial state.
  Future<SupervisionPolicy> load(
    PluginKey key,
    DateTime Function() clock, {
    SupervisionDurations durations = const SupervisionDurations(),
  }) async {
    final rows = await session.db.unsafeQuery(
      '''SELECT "failureTimes", "backoffStep",
      "nextStartAt", "circuit", "nextProbeAt", "lastErrorClass"
      FROM plugin_definition_health WHERE "hostInstanceId"=@host
      AND "outputId"=@output AND "definitionDigest"=@digest''',
      parameters: QueryParameters.named({
        'host': hostInstanceId,
        'output': key.outputId,
        'digest': key.digest,
      }),
      timeoutInSeconds: 5,
    );
    if (rows.isEmpty) {
      return SupervisionPolicy(clock: clock, durations: durations);
    }
    final row = rows.single;
    final times = (jsonDecode(row[0] as String) as List<Object?>)
        .cast<String>()
        .map(DateTime.parse);
    return SupervisionPolicy(
      clock: clock,
      durations: durations,
      failures: times,
      backoffStep: row[1] as int,
      nextStartAt: row[2] as DateTime?,
      circuit: PluginCircuit.values.byName(row[3] as String),
      nextProbeAt: row[4] as DateTime?,
      lastError: row[5] as String?,
    );
  }

  /// Writes history before releasing a slot.
  Future<void> save(
    PluginKey key,
    SupervisionPolicy policy, {
    Transaction? transaction,
  }) async {
    await session.db.unsafeExecute(
      '''INSERT INTO plugin_definition_health
      ("hostInstanceId","outputId","definitionDigest","failureTimes","backoffStep",
       "nextStartAt","circuit","nextProbeAt","lastErrorClass")
      VALUES (@host,@output,@digest,@failures,@step,@nextStart,@circuit,@nextProbe,@error)
      ON CONFLICT ("hostInstanceId","outputId","definitionDigest") DO UPDATE SET
      "failureTimes"=EXCLUDED."failureTimes", "backoffStep"=EXCLUDED."backoffStep",
      "nextStartAt"=EXCLUDED."nextStartAt", "circuit"=EXCLUDED."circuit",
      "nextProbeAt"=EXCLUDED."nextProbeAt", "lastErrorClass"=EXCLUDED."lastErrorClass"''',
      parameters: QueryParameters.named({
        'host': hostInstanceId,
        'output': key.outputId,
        'digest': key.digest,
        'failures': jsonEncode(
          policy.failures.map((t) => t.toUtc().toIso8601String()).toList(),
        ),
        'step': policy.backoffStep,
        'nextStart': policy.nextStartAt?.toUtc(),
        'circuit': policy.circuit.name,
        'nextProbe': policy.nextProbeAt?.toUtc(),
        'error': policy.lastError,
      }),
      transaction: transaction,
      timeoutInSeconds: 5,
    );
  }

  /// Removes health for this host when no queued or delivering intent remains.
  Future<void> prune() async {
    await session.db.unsafeExecute(
      '''DELETE FROM plugin_definition_health h
      WHERE h."hostInstanceId"=@host AND NOT EXISTS (SELECT 1 FROM outbox o
        WHERE o.output_id::text=h."outputId" AND o.definition_digest=h."definitionDigest"
        AND o.output_kind='plugin' AND o.status IN ('queued','delivering'))''',
      parameters: QueryParameters.named({'host': hostInstanceId}),
      timeoutInSeconds: 5,
    );
  }
}
