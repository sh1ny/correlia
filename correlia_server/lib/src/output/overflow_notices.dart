import 'dart:convert';

import 'package:correlia_server/event.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import 'queue_intents.dart';

final _noticeSource = SourceContext(
  sourceInstance: '2877d040-0025-4a96-a2e7-8f846c6cceaf',
  sourceKind: 'correlia',
);

/// Routes one durable overflow occurrence without creating sender work.
final class OverflowNotices {
  const OverflowNotices(this.session, {this.afterRegistryLockForTest});

  /// A bounded publication barrier for contention fixtures.
  final Future<void> Function()? afterRegistryLockForTest;
  final Session session;

  /// Returns true only when a pending occurrence has been handled.
  Future<bool> routeOne() => session.db.transaction((tx) async {
    await session.db.unsafeSimpleExecute(
      "SET LOCAL statement_timeout='5s'; SET LOCAL lock_timeout='2s'",
      transaction: tx,
    );
    final registry = await session.db.unsafeQuery(
      '''SELECT a."snapshotId",s."publicJson" FROM ingest_active_config a
      JOIN ingest_config_snapshot s USING ("snapshotId")
      WHERE a.singleton=1 AND EXISTS (
        SELECT 1 FROM pipeline_overflow_notice WHERE NOT handled)
      FOR SHARE OF a''',
      transaction: tx,
      timeoutInSeconds: 5,
    );
    final active = registry.singleOrNull;
    if (active == null) return false;
    await afterRegistryLockForTest?.call();
    final pending = (await session.db.unsafeQuery(
      '''SELECT activity_id,output_id::text,occurred_at,evidence
      FROM pipeline_overflow_notice WHERE NOT handled
      ORDER BY activity_id FOR UPDATE SKIP LOCKED LIMIT 1''',
      transaction: tx,
      timeoutInSeconds: 5,
    )).singleOrNull;
    if (pending == null) return false;
    final activity = pending[0]! as int;
    final overflowing = pending[1]! as String;
    final occurred = (pending[2]! as DateTime).toUtc();
    final evidence = utf8.encode(pending[3]! as String);
    final pin = active[0]! as String;
    final snapshot = jsonDecode(active[1]! as String) as Map<String, Object?>;
    final destinations = [
      for (final output
          in (snapshot['outputs']! as List<Object?>)
              .cast<Map<String, Object?>>())
        if (output['id'] != overflowing) QueueDestination.fromSnapshot(output),
    ];
    final when = EventTimestamp.parse(occurred.toIso8601String());
    final event = CanonicalEvent.create(
      source: _noticeSource,
      kind: EventKind.alert,
      status: EventStatus.firing,
      severity: EventSeverity.warning,
      summary: 'Correlia output queue overflow',
      identityFields: {'output_id': IdentityComponent.fromText(overflowing)},
      observationKey: ObservationKey.native('output_overflow:$activity'),
      observedAt: when,
      processedAt: when,
      sourceTime: when,
      reportedSourceTime: occurred.toIso8601String(),
      raw: EventRawReference(
        ref: 'activity:$activity',
        sha256: sha256.convert(evidence).toString(),
        size: evidence.length,
      ),
      pipeline: EventPipeline(
        version: pin,
        generation: 0,
        stagesApplied: const ['overflow_notice'],
      ),
    );
    final payload = CloudEvent(event: event).toJsonBytes();
    final caps = await lockOutputCapacity(
      session,
      tx,
      destinations.map((d) => d.id),
    );
    final fitting = [
      for (final dest in destinations)
        if (caps[dest.id]!.fits(1, payload.length)) dest,
    ];
    if (fitting.isNotEmpty) {
      await session.db.unsafeExecute(
        '''INSERT INTO events (observed_at,event_id,disposition,source_id,config_snapshot_id,
          source_time,effective_source_time,payload,system_activity_id)
          VALUES (@at,@event::uuid,'ready',@source::uuid,@pin,@at,@at,@payload,@activity)''',
        parameters: QueryParameters.named({
          'at': occurred,
          'event': event.eventId,
          'source': _noticeSource.sourceInstance,
          'pin': pin,
          'payload': payload,
          'activity': activity,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      await lockOutputCommitments(session, tx, pin, fitting.map((d) => d.id));
      for (final destination in fitting) {
        await insertQueueIntent(session, tx, pin, occurred, (
          observed: occurred,
          event: event.eventId,
          disposition: 'ready',
          destination: destination,
          payload: payload,
        ));
      }
    }
    await session.db.unsafeExecute(
      'UPDATE pipeline_overflow_notice SET handled=true WHERE activity_id=@id',
      parameters: QueryParameters.named({'id': activity}),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    return true;
  });
}
