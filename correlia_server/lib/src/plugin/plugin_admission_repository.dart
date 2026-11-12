import 'dart:convert';

import 'package:serverpod/serverpod.dart';

import 'slot_scheduler.dart';

/// Queries due plugin definitions without retaining waiting state in memory.
final class PluginAdmissionRepository {
  const PluginAdmissionRepository(this.session, this.hostInstanceId);
  final Session session;
  final String hostInstanceId;

  /// Finds the next due, runnable definition, wrapping the key order once.
  ///
  /// When [respectOutputLimit] is false, this identifies waiting demand even
  /// when its output has exhausted its own slots.
  Future<PluginKey?> next({
    required PluginKey? cursor,
    required Iterable<PluginKey> running,
    bool respectOutputLimit = true,
    int outputLimit = 4,
  }) async {
    final active = running.toList(growable: false);
    final counts = <String, int>{};
    for (final key in active) {
      counts.update(key.outputId, (count) => count + 1, ifAbsent: () => 1);
    }
    final runningJson = jsonEncode({
      for (final key in active) '${key.outputId}/${key.digest}': true,
    });
    Future<PluginKey?> query(bool wrap) async {
      final rows = await session.db.unsafeQuery(
        '''
        SELECT o.output_id::text, o.definition_digest
        FROM outbox o
        LEFT JOIN plugin_definition_health h
          ON h."hostInstanceId"=@host AND h."outputId"=o.output_id::text
          AND h."definitionDigest"=o.definition_digest
        WHERE o.output_kind='plugin' AND o.status='queued'
          AND (o.next_attempt_at IS NULL OR o.next_attempt_at<=clock_timestamp())
          AND (h."nextStartAt" IS NULL OR h."nextStartAt"<=clock_timestamp())
          AND NOT (CAST(@running AS jsonb) ? (o.output_id::text || '/' || o.definition_digest))
          AND (NOT @respect OR COALESCE((CAST(@counts AS jsonb)->>o.output_id::text)::int,0)<@limit)
          AND (CAST(@cursorOutput AS text) IS NULL OR
            (o.output_id::text,o.definition_digest) ${wrap ? '<=' : '>'} (CAST(@cursorOutput AS text),CAST(@cursorDigest AS text)))
        GROUP BY o.output_id, o.definition_digest
        ORDER BY o.output_id::text, o.definition_digest LIMIT 1''',
        parameters: QueryParameters.named({
          'host': hostInstanceId,
          'running': runningJson,
          'respect': respectOutputLimit,
          'counts': jsonEncode(counts),
          'limit': outputLimit,
          'cursorOutput': cursor?.outputId,
          'cursorDigest': cursor?.digest,
        }),
        timeoutInSeconds: 5,
      );
      return rows.isEmpty
          ? null
          : PluginKey(rows.single[0] as String, rows.single[1] as String);
    }

    return await query(false) ?? (cursor == null ? null : await query(true));
  }
}
