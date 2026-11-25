import 'package:serverpod/serverpod.dart';

import '../event/canonical_event.dart';
import '../event/event_timestamp.dart';
import 'ordering_key.dart';
import 'transition.dart';

/// Evidence for one alert decision or lock-only webhook retention check.
final class StateInput {
  const StateInput(
    this.event, {
    required this.duplicate,
    this.reconcile = false,
    this.eligibility = StreamEligibility.ready,
  });
  final CanonicalEvent event;
  final bool duplicate;
  final bool reconcile;
  final StreamEligibility eligibility;
}

DateTime _date(EventTimestamp value) => DateTime.fromMicrosecondsSinceEpoch(
  value.seconds * 1000000 + value.nanos ~/ 1000,
  isUtc: true,
);
EventTimestamp _timestamp(DateTime value) =>
    EventTimestamp.parse(value.toUtc().toIso8601String());

Observation _observation(CanonicalEvent event, Duration skew) {
  String? generator;
  for (final link in event.links) {
    if (link.relation == 'generator') {
      // Keep the canonical href unchanged; PostgreSQL text cannot hold NUL.
      generator = link.href.replaceAll('\u0000', '%00');
      break;
    }
  }
  return Observation(
    status: event.status,
    severity: event.severity,
    summary: event.summary,
    sourceInstance: event.observer.sourceInstance,
    firingSince: event.startsAt == null ? null : _date(event.startsAt!),
    generatorUrl: generator,
    orderingKey: OrderingKey.fromSource(
      sourceTime: event.sourceTime!,
      observedAt: event.observedAt,
      eventId: event.eventId,
      skewAllowance: skew,
    ),
  );
}

/// Mutates alert rows and appends activity within the caller's transaction.
final class AlertStateService {
  const AlertStateService(
    this.session, {
    required this.skewAllowance,
    required this.beforeQuery,
    this.afterInsertConflict,
  });
  final Session session;
  final Duration skewAllowance;
  final Future<void> Function() beforeQuery;
  final Future<void> Function()? afterInsertConflict;

  /// Applies ready inputs in fingerprint and ordering-key order.
  ///
  /// Every input is classified under the same fingerprint-ordered locks.
  Future<Map<CanonicalEvent, StreamDecision>> apply(
    Transaction tx,
    List<StateInput> inputs, {
    required String rawId,
    required DateTime now,
  }) async {
    final groups = <String, List<StateInput>>{};
    final observations = <CanonicalEvent, Observation>{};
    for (final input in inputs) {
      (groups[input.event.fingerprint] ??= []).add(input);
      observations[input.event] = _observation(
        input.event,
        skewAllowance,
      );
    }
    final fingerprints = groups.keys.toList()..sort();
    final locked = <String, ({int id, AlertState? state})>{};
    for (final fingerprint in fingerprints) {
      final group = groups[fingerprint]!
        ..sort((a, b) {
          if (a.duplicate != b.duplicate) return a.duplicate ? 1 : -1;
          return observations[a.event]!.orderingKey.compareTo(
            observations[b.event]!.orderingKey,
          );
        });
      CanonicalEvent? candidate;
      var lock = false;
      for (final input in group) {
        lock |=
            !input.reconcile || input.eligibility == StreamEligibility.ready;
        if (!input.duplicate &&
            input.eligibility == StreamEligibility.ready &&
            input.event.status != EventStatus.info) {
          candidate = input.event;
          break;
        }
      }
      var created = false;
      while (true) {
        if (candidate != null) {
          final event = candidate;
          final observation = observations[event]!;
          final key = observation.orderingKey;
          await beforeQuery();
          final inserted = await session.db.unsafeQuery(
            '''INSERT INTO alerts
(tenant,fingerprint,status,severity,summary,"sourceInstance","firingSince","generatorUrl","fenceEffectiveSeconds","fenceEffectiveNanos","fenceObservedSeconds","fenceObservedNanos","fenceEventId","lastObservedAt",version,"createdAt","updatedAt")
VALUES (@tenant,@fingerprint,@status,@severity,@summary,@source,@firing,@url,@es,@en,@os,@on,@event,@observed,1,@now,@now)
ON CONFLICT (tenant,fingerprint) DO NOTHING RETURNING id''',
            parameters: QueryParameters.named({
              'tenant': event.tenant,
              'fingerprint': fingerprint,
              'status': event.status.name,
              'severity': event.severity.name,
              'summary': event.summary,
              'source': observation.sourceInstance,
              'firing': observation.firingSince,
              'url': observation.generatorUrl,
              'es': key.effectiveAt.seconds,
              'en': key.effectiveAt.nanos,
              'os': key.observedAt.seconds,
              'on': key.observedAt.nanos,
              'event': key.eventId,
              'observed': _date(key.observedAt),
              'now': now,
            }),
            transaction: tx,
            timeoutInSeconds: 5,
          );
          created = inserted.isNotEmpty;
          if (!created) await afterInsertConflict?.call();
        }
        await beforeQuery();
        final result = await session.db.unsafeQuery(
          'SELECT * FROM alerts WHERE tenant=@tenant AND fingerprint=@fingerprint'
          '${lock ? ' FOR UPDATE' : ''}',
          parameters: QueryParameters.named({
            'tenant': group.first.event.tenant,
            'fingerprint': fingerprint,
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (result.isEmpty) {
          if (candidate != null) continue;
          break;
        }
        final row = result.single.toColumnMap();
        final state = created
            ? null
            : AlertState(
                status: EventStatus.values.byName(row['status'] as String),
                severity: EventSeverity.values.byName(
                  row['severity'] as String,
                ),
                summary: row['summary'] as String,
                sourceInstance: row['sourceInstance'] as String,
                firingSince: row['firingSince'] as DateTime?,
                generatorUrl: row['generatorUrl'] as String?,
                fence: OrderingKey(
                  effectiveAt: EventTimestamp.fromParts(
                    row['fenceEffectiveSeconds'] as int,
                    row['fenceEffectiveNanos'] as int,
                  ),
                  observedAt: EventTimestamp.fromParts(
                    row['fenceObservedSeconds'] as int,
                    row['fenceObservedNanos'] as int,
                  ),
                  eventId: row['fenceEventId'] as String,
                ),
                version: row['version'] as int,
                lastObservedAt: _timestamp(row['lastObservedAt'] as DateTime),
              );
        locked[fingerprint] = (id: row['id'] as int, state: state);
        break;
      }
    }

    final outcomes = <CanonicalEvent, StreamDecision>{};
    for (final fingerprint in fingerprints) {
      final entry = locked[fingerprint];
      var state = entry?.state;
      final group = groups[fingerprint]!;
      for (final input in group) {
        final event = input.event;
        final decision = decideStreamTransition(
          state,
          observations[event]!,
          reconcile: input.reconcile,
          duplicate: input.duplicate,
          eligibility: input.eligibility,
        );
        outcomes[event] = decision;
        final result = decision.transition;
        if (result == null) continue;
        state = result.state!;
        final id = entry!.id;
        if (result is Stale) {
          await beforeQuery();
          await session.db.unsafeExecute(
            'UPDATE alerts SET "lastObservedAt"=GREATEST("lastObservedAt",@observed) WHERE id=@id',
            parameters: QueryParameters.named({
              'observed': _date(state.lastObservedAt),
              'id': id,
            }),
            transaction: tx,
            timeoutInSeconds: 5,
          );
          continue;
        }
        if (decision.outcome == StreamOutcome.tombstoned) {
          await beforeQuery();
          await session.db.unsafeExecute(
            'UPDATE alerts SET silent_tombstone=true WHERE id=@id',
            parameters: QueryParameters.named({'id': id}),
            transaction: tx,
            timeoutInSeconds: 5,
          );
          continue;
        }
        final fence = state.fence;
        if (decision.outcome == StreamOutcome.confirmed) {
          await beforeQuery();
          await session.db.unsafeExecute(
            '''UPDATE alerts SET "fenceEffectiveSeconds"=@es,"fenceEffectiveNanos"=@en,
              "fenceObservedSeconds"=@os,"fenceObservedNanos"=@on,"fenceEventId"=@event,
              "lastObservedAt"=GREATEST("lastObservedAt",@observed) WHERE id=@id''',
            parameters: QueryParameters.named({
              'id': id,
              'es': fence.effectiveAt.seconds,
              'en': fence.effectiveAt.nanos,
              'os': fence.observedAt.seconds,
              'on': fence.observedAt.nanos,
              'event': fence.eventId,
              'observed': _date(state.lastObservedAt),
            }),
            transaction: tx,
            timeoutInSeconds: 5,
          );
          continue;
        }
        await beforeQuery();
        await session.db.unsafeExecute(
          '''UPDATE alerts SET status=@status,severity=@severity,summary=@summary,"sourceInstance"=@source,"firingSince"=@firing,"generatorUrl"=@url,"fenceEffectiveSeconds"=@es,"fenceEffectiveNanos"=@en,"fenceObservedSeconds"=@os,"fenceObservedNanos"=@on,"fenceEventId"=@event,"lastObservedAt"=GREATEST("lastObservedAt",@observed),version=@version,"updatedAt"=@now,
          silent_tombstone=CASE WHEN @visible THEN false ELSE silent_tombstone END
          WHERE id=@id''',
          parameters: QueryParameters.named({
            'id': id,
            'visible': result.activityKind != null,
            'status': state.status.name,
            'severity': state.severity.name,
            'summary': state.summary,
            'source': state.sourceInstance,
            'firing': state.firingSince,
            'url': state.generatorUrl,
            'es': fence.effectiveAt.seconds,
            'en': fence.effectiveAt.nanos,
            'os': fence.observedAt.seconds,
            'on': fence.observedAt.nanos,
            'event': fence.eventId,
            'observed': _date(state.lastObservedAt),
            'version': state.version,
            'now': now,
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        final kind = result.activityKind;
        if (kind != null) {
          final change = switch (kind) {
            ActivityKind.created => 'created',
            ActivityKind.resolved => 'resolved',
            ActivityKind.refired => 'refired',
            ActivityKind.severityChanged => 'severity_changed',
            ActivityKind.displayChanged => 'display_changed',
          };
          await beforeQuery();
          await session.db.unsafeExecute(
            '''INSERT INTO activity (occurred_at,entity_kind,entity_id,entity_version,change_kind,actor_kind,actor_ref,cause_event_id,cause_raw_id)
VALUES (@now,'alert',@id,@version,@kind,'pipeline',NULL,CAST(@event AS uuid),CAST(@raw AS uuid))''',
            parameters: QueryParameters.named({
              'now': now,
              'id': id,
              'version': state.version,
              'kind': change,
              'event': event.eventId,
              'raw': rawId,
            }),
            transaction: tx,
            timeoutInSeconds: 5,
          );
        }
      }
    }
    return outcomes;
  }
}
