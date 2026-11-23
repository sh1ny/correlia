import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';

import '../event/canonical_event.dart';
import '../event/cloud_event.dart';
import '../event/event_timestamp.dart';
import '../event/validation.dart';
import '../ingest/bootstrap.dart'
    show
        AlertmanagerSourceKind,
        Icinga2SourceKind,
        SourceKind,
        SourceMode,
        StreamStateTypePolicy,
        sha256Digest;
import '../ingest/icinga2/decoder.dart';
import '../ingest/icinga2/stream/decoder.dart';
import '../ingest/source_decoder.dart';
import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import '../state/alert_state_service.dart';
import '../state/ordering_key.dart';
import '../state/transition.dart';

const _transactionLimit = Duration(seconds: 10);
const _fanoutLimit = 16 * 1024 * 1024;

/// The maximum source clock lead used by alert-state ordering.
const skewAllowance = Duration(minutes: 5);

/// The disposition of source evidence before observation deduplication.
enum EvidenceDisposition { ready, late, futureDated }

/// Applies the accepted future, skew and lateness policy without changing identity.
EvidenceDisposition classifyEvidence(EventTimestamp source, DateTime observed) {
  final observedMicros = observed.toUtc().microsecondsSinceEpoch;
  final sourceMicros = source.seconds * 1000000 + source.nanos ~/ 1000;
  final futureLimit = observedMicros + const Duration(hours: 24).inMicroseconds;
  if (sourceMicros > futureLimit ||
      (sourceMicros == futureLimit && source.nanos % 1000 != 0)) {
    return EvidenceDisposition.futureDated;
  }
  // The skew cap is later than observed time, so it cannot make evidence late.
  if (sourceMicros < observedMicros - const Duration(days: 7).inMicroseconds) {
    return EvidenceDisposition.late;
  }
  return EvidenceDisposition.ready;
}

EventTimestamp _timestamp(DateTime value) =>
    EventTimestamp.parse(value.toUtc().toIso8601String());
DateTime _date(EventTimestamp value) => DateTime.fromMicrosecondsSinceEpoch(
  value.seconds * 1000000 + value.nanos ~/ 1000,
  isUtc: true,
);

/// Formats a warning without exposing sender-controlled names or values.
String formatUnknownFieldWarning(
  String source,
  List<String> names,
  int overflow,
) {
  final tags = names
      .map(
        (name) => sha256.convert(utf8.encode(name)).toString().substring(0, 12),
      )
      .join(',');
  return 'pipeline source=$source unknown_top_level_fields=${names.length + overflow} tags=$tags';
}

/// The documented field names of Alertmanager's payload and of the canonical
/// event, kept in a stored failure path of an Alertmanager source.
const _alertmanagerPathFields = {
  'body',
  'alerts',
  'version',
  'status',
  'receiver',
  'groupKey',
  'groupLabels',
  'routeLabels',
  'commonLabels',
  'commonAnnotations',
  'externalURL',
  'notification_reason',
  'truncatedAlerts',
  'labels',
  'annotations',
  'startsAt',
  'endsAt',
  'generatorURL',
  'fingerprint',
  'key',
  'identity_fields',
  'observation_key',
  'source_time',
  'reported_source_time',
};

/// The fields of the Icinga2 webhook document v1 and of the canonical event,
/// kept in a stored failure path of an Icinga2 source.
const _icinga2PathFields = {
  'body',
  'format',
  'object_type',
  'host',
  'service',
  'state',
  'state_type',
  'last_state_change',
  'output',
  'notification_type',
  'notification_author',
  'notification_comment',
  'notification_time',
  'labels',
  'annotations',
  'fingerprint',
  'key',
  'identity_fields',
  'observation_key',
  'source_time',
  'reported_source_time',
};

/// Renders a validation path for storage: the documented field names of
/// [kind]'s payload and of the canonical event stay, any other segment (a
/// sender-chosen name) becomes `*`, and the result is bounded. Each kind
/// keeps only its own names, so a name another kind documents is still
/// redacted when a sender chooses it.
String safeFailurePath(String path, SourceKind kind) {
  final (fields, indexed) = switch (kind) {
    AlertmanagerSourceKind() => (
      _alertmanagerPathFields,
      RegExp(r'^alerts\[[0-9]{1,4}\]$'),
    ),
    Icinga2SourceKind() => (_icinga2PathFields, null),
  };
  final safe = path
      .split('.')
      .map(
        (part) => fields.contains(part) || (indexed?.hasMatch(part) ?? false)
            ? part
            : '*',
      )
      .join('.');
  return safe.length > 256 ? safe.substring(0, 256) : safe;
}

final class _Raw {
  const _Raw(
    this.observed,
    this.id,
    this.source,
    this.bytes,
    this.digest,
    this.pin,
  );
  final DateTime observed;
  final String id;
  final String source;
  final Uint8List bytes;
  final String digest;
  final String pin;
}

sealed class _Output {
  const _Output(this.id);
  final String id;
}

final class _WebhookOutput extends _Output {
  const _WebhookOutput(super.id, this.url, this.ref, this.commitment);
  final String url, ref, commitment;
}

final class _PluginOutput extends _Output {
  const _PluginOutput(super.id, this.digest);
  final String digest;
}

final class _Prepared {
  const _Prepared(this.event, this.disposition, this.payload);
  final CanonicalEvent event;
  final EvidenceDisposition disposition;
  final Uint8List payload;
}

final class _Deadline {
  _Deadline() : stopwatch = Stopwatch()..start();
  final Stopwatch stopwatch;
  void check() {
    if (stopwatch.elapsed >= _transactionLimit) {
      throw TimeoutException('pipeline transaction deadline');
    }
  }

  int get remainingMillis {
    check();
    final left = (_transactionLimit - stopwatch.elapsed).inMilliseconds;
    return left < 5000 ? left.clamp(1, 5000) : 5000;
  }
}

/// Process-local counts of fenced retry records committed by pipeline workers.
final class PipelineCounters {
  /// Committed transient retries, which do not spend the internal budget.
  int transientRetries = 0;

  /// Committed internal attempts charged to the raw row.
  int internalAttempts = 0;
}

/// Owns the two durable claim phases for one database session.
final class PipelineRepository {
  /// Creates a repository with an injectable UTC clock and post-commit pin barrier.
  PipelineRepository(
    this.session, {
    DateTime Function()? clock,
    this.afterPin,
    this.afterClaim,
    this.afterAlertInsertConflict,
    Map<String, int>? retryCounts,
    this.retryDelay,
    PipelineCounters? counters,
    this.stateSkewAllowance = skewAllowance,
    this.log,
    this.icinga2Decoder = decodeIcinga2Request,
  }) : clock = clock ?? DateTime.now,
       _retryCounts = retryCounts ?? {},
       counters = counters ?? PipelineCounters();

  final Session session;
  final DateTime Function() clock;
  final Future<void> Function()? afterPin;

  /// Runs inside [processOne]'s transaction right after it claimed a row,
  /// before anything else; tests use it to hold that transaction open.
  final Future<void> Function()? afterClaim;
  final Future<void> Function()? afterAlertInsertConflict;
  final Map<String, int> _retryCounts;
  final Duration Function(int)? retryDelay;
  final PipelineCounters counters;
  final Duration stateSkewAllowance;

  /// The optional best-effort post-commit warning sink.
  final void Function(String)? log;

  /// The decoder of `icinga2` sources, the real one by default; `null` means
  /// that kind has no decoder.
  final KindDecoder? icinga2Decoder;

  Future<void> _limits(Transaction tx, _Deadline deadline) async {
    await session.db.unsafeQuery(
      "SELECT set_config('statement_timeout', @timeout, true), set_config('lock_timeout', '5s', true)",
      parameters: QueryParameters.named({
        'timeout': '${deadline.remainingMillis}ms',
      }),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    deadline.check();
  }

  /// Commits one unpinned row's active snapshot before decoding or returning.
  Future<bool> pinOne() async {
    final deadline = _Deadline();
    final pinned = await session.db.transaction((tx) async {
      await _limits(tx, deadline);
      final rows = await session.db.unsafeQuery(
        '''SELECT observed_at,raw_id::text FROM raw_inbox
WHERE status='pending' AND config_snapshot_id IS NULL ORDER BY observed_at,raw_id
FOR UPDATE SKIP LOCKED LIMIT 1''',
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (rows.isEmpty) return false;
      await _limits(tx, deadline);
      final active = await session.db.unsafeQuery(
        'SELECT "snapshotId" FROM ingest_active_config WHERE singleton=1',
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (active.isEmpty) return false;
      await _limits(tx, deadline);
      await session.db.unsafeExecute(
        '''UPDATE raw_inbox SET config_snapshot_id=@pin
WHERE observed_at=@observed AND raw_id=CAST(@id AS uuid)''',
        parameters: QueryParameters.named({
          'pin': active.single[0] as String,
          'observed': rows.single[0] as DateTime,
          'id': rows.single[1] as String,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      deadline.check();
      return true;
    });
    if (pinned && afterPin != null) await afterPin!();
    return pinned;
  }

  /// Processes one pinned eligible row, or returns false when none is eligible.
  Future<bool> processOne() async {
    _Raw? claimed;
    DecodedBatch? completedBatch;
    final deadline = _Deadline();
    try {
      final processed = await session.db.transaction((tx) async {
        await _limits(tx, deadline);
        final rows = await session.db.unsafeQuery(
          '''SELECT observed_at,raw_id::text,source_id::text,body,body_sha256,config_snapshot_id
FROM raw_inbox WHERE status='pending' AND config_snapshot_id IS NOT NULL
AND (next_attempt_at IS NULL OR next_attempt_at<=@now)
ORDER BY observed_at,raw_id FOR UPDATE SKIP LOCKED LIMIT 1''',
          parameters: QueryParameters.named({'now': clock().toUtc()}),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        if (rows.isEmpty) return false;
        final row = rows.single;
        final Object? body = row[3];
        final bytes = switch (body) {
          Uint8List value => value,
          ByteData value => value.buffer.asUint8List(
            value.offsetInBytes,
            value.lengthInBytes,
          ),
          _ => throw StateError('Unexpected raw byte representation'),
        };
        final raw = _Raw(
          row[0] as DateTime,
          row[1] as String,
          row[2] as String,
          bytes,
          row[4] as String,
          row[5] as String,
        );
        claimed = raw;
        if (afterClaim case final hook?) await hook();
        await _limits(tx, deadline);
        final snapshots = await session.db.unsafeQuery(
          'SELECT "publicJson" FROM ingest_config_snapshot WHERE "snapshotId"=@pin',
          parameters: QueryParameters.named({'pin': raw.pin}),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        final snapshot =
            jsonDecode(snapshots.single[0] as String) as Map<String, Object?>;
        final sources = (snapshot['sources'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final matches = sources.where(
          (source) => source['id'] == raw.source && source['enabled'] == true,
        );
        if (matches.isEmpty) {
          await _fail(tx, deadline, raw, 'source_not_configured', null);
          return true;
        }
        final source = matches.single;
        final outputIds = (source['output_ids'] as List<Object?>)
            .cast<String>()
            .toSet();
        final outputRows = (snapshot['outputs'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final outputs = <_Output>[
          for (final output in outputRows)
            if (outputIds.contains(output['id']))
              switch (output['kind']) {
                'webhook' => _WebhookOutput(
                  output['id'] as String,
                  output['url'] as String,
                  output['signing_key_ref'] as String,
                  output['signing_key_commitment'] as String,
                ),
                'plugin' => _PluginOutput(
                  output['id'] as String,
                  sha256Digest(output),
                ),
                _ => throw StateError('Invalid pinned output kind'),
              },
        ];
        if (outputs.length != outputIds.length) {
          throw StateError('Invalid pinned routing');
        }
        final kind = _kindOf(snapshot, source);
        final decoder = _decoderFor(kind);
        if (kind == null || decoder == null) {
          await _fail(tx, deadline, raw, 'unsupported_kind', null);
          return true;
        }
        final stream =
            kind is Icinga2SourceKind &&
            source['mode'] == SourceMode.eventStreams.wire;
        late final DecodedBatch batch;
        String? syncId;
        final prepared = <_Prepared>[];
        try {
          final request = DecodeRequest(
            bytes: raw.bytes,
            sourceInstance: raw.source,
            namespace: source['namespace'] as String,
            excludedLabels:
                (source['excluded_identity_labels'] as List<Object?>)
                    .cast<String>(),
            rawRef: 'raw:${raw.observed.toUtc().toIso8601String()}/${raw.id}',
            rawSha256: raw.digest,
            observedAt: _timestamp(raw.observed),
            processedAt: _timestamp(clock()),
            configVersion: raw.pin,
          );
          if (stream) {
            final decoded = await _decodeStream(request, raw, tx);
            batch = decoded.batch;
            syncId = decoded.syncId;
          } else {
            batch = decoder(request);
          }
          deadline.check();
          for (final event in batch.events) {
            deadline.check();
            final disposition = classifyEvidence(
              event.sourceTime!,
              stream
                  ? DateTime.fromMicrosecondsSinceEpoch(
                      event.observedAt.seconds * 1000000 +
                          event.observedAt.nanos ~/ 1000,
                      isUtc: true,
                    )
                  : raw.observed,
            );
            final data = CloudEvent(event: event).toJsonBytes();
            prepared.add(_Prepared(event, disposition, data));
          }
        } on EventValidationError catch (error) {
          await _fail(
            tx,
            deadline,
            raw,
            error.code,
            stream ? error.path : safeFailurePath(error.path, kind),
          );
          return true;
        }
        prepared.sort((a, b) => a.event.eventId.compareTo(b.event.eventId));
        var committed = 0,
            duplicates = 0,
            quarantines = 0,
            duplicateQuarantine = 0,
            late = 0,
            unrouted = 0,
            applied = 0,
            stale = 0,
            clamped = 0;
        var confirmed = 0, repaired = 0, tombstoned = 0, diverged = 0;
        final reconcile = syncId != null;
        var aggregate = 0;
        final seen = <String>{};
        final savepoint = await tx.createSavepoint();
        final effects = <_Prepared>[];
        final stateInputs = <StateInput>[];
        try {
          for (final item in prepared) {
            deadline.check();
            final event = item.event;
            final eligibility = switch (item.disposition) {
              EvidenceDisposition.ready => StreamEligibility.ready,
              EvidenceDisposition.late => StreamEligibility.late,
              EvidenceDisposition.futureDated => StreamEligibility.futureDated,
            };
            if (stream && eligibility != StreamEligibility.ready) {
              if (eligibility == StreamEligibility.late) {
                late++;
              } else {
                quarantines++;
              }
              if (reconcile) {
                stateInputs.add(
                  StateInput(
                    event,
                    duplicate: false,
                    reconcile: true,
                    eligibility: eligibility,
                  ),
                );
              }
              continue;
            }
            if (!seen.add(event.eventId)) {
              if (item.disposition == EvidenceDisposition.futureDated) {
                duplicateQuarantine++;
              } else {
                duplicates++;
                if (reconcile) {
                  stateInputs.add(
                    StateInput(event, duplicate: true, reconcile: true),
                  );
                }
              }
              continue;
            }
            final disposition = switch (item.disposition) {
              EvidenceDisposition.ready => 'ready',
              EvidenceDisposition.late => 'late',
              EvidenceDisposition.futureDated => 'future_dated',
            };
            if (item.disposition != EvidenceDisposition.futureDated) {
              await _limits(tx, deadline);
              final key = await session.db.unsafeQuery(
                '''INSERT INTO observation_keys
("eventId",fingerprint,"sourceTime","firstSeenAt",disposition)
VALUES (CAST(@event AS uuid),@fingerprint,@sourceTime,@observed,@disposition)
ON CONFLICT ("eventId") DO NOTHING RETURNING "eventId"''',
                parameters: QueryParameters.named({
                  'event': event.eventId,
                  'fingerprint': event.fingerprint,
                  'sourceTime': _date(event.sourceTime!),
                  'observed': stream ? _date(event.observedAt) : raw.observed,
                  'disposition': disposition,
                }),
                transaction: tx,
                timeoutInSeconds: 5,
              );
              if (key.isEmpty) {
                duplicates++;
                await _limits(tx, deadline);
                final original = await session.db.unsafeQuery(
                  'SELECT disposition FROM observation_keys WHERE "eventId"=CAST(@event AS uuid)',
                  parameters: QueryParameters.named({'event': event.eventId}),
                  transaction: tx,
                  timeoutInSeconds: 5,
                );
                // A duplicate refreshes the alert only when both it and the
                // original are ready: a late or future-dated redelivery of a
                // ready observation says nothing about the object's freshness.
                if (original.single[0] == 'ready' &&
                    item.disposition == EvidenceDisposition.ready) {
                  stateInputs.add(
                    StateInput(event, duplicate: true, reconcile: reconcile),
                  );
                }
                continue;
              }
            }
            stateInputs.add(
              StateInput(
                event,
                duplicate: false,
                reconcile: reconcile,
                eligibility: eligibility,
              ),
            );
            effects.add(item);
          }

          final stateOutcomes = await AlertStateService(
            session,
            skewAllowance: stateSkewAllowance,
            beforeQuery: () => _limits(tx, deadline),
            afterInsertConflict: afterAlertInsertConflict,
          ).apply(tx, stateInputs, rawId: raw.id, now: clock().toUtc());
          for (final decision in stateOutcomes.values) {
            if (decision.diverged) diverged++;
            switch (decision.outcome) {
              case StreamOutcome.applied:
                applied++;
              case StreamOutcome.stale:
                stale++;
              case StreamOutcome.confirmed:
                confirmed++;
              case StreamOutcome.repaired:
                repaired++;
              case StreamOutcome.tombstoned:
                tombstoned++;
              default:
                break;
            }
          }

          for (final item in effects) {
            deadline.check();
            final event = item.event;
            final disposition = switch (item.disposition) {
              EvidenceDisposition.ready => 'ready',
              EvidenceDisposition.late => 'late',
              EvidenceDisposition.futureDated => 'future_dated',
            };
            // The same function the fence uses; the column keeps microseconds.
            final effective = OrderingKey.fromSource(
              sourceTime: event.sourceTime!,
              observedAt: event.observedAt,
              eventId: event.eventId,
              skewAllowance: stateSkewAllowance,
            );
            final isClamped =
                compareTimestamps(event.sourceTime!, effective.effectiveAt) > 0;
            final decision = stateOutcomes[event];
            if (reconcile && decision != null && !decision.keepsEvent) {
              if (isClamped) clamped++;
              await _limits(tx, deadline);
              await session.db.unsafeExecute(
                'DELETE FROM observation_keys WHERE "eventId"=CAST(@event AS uuid)',
                parameters: QueryParameters.named({'event': event.eventId}),
                transaction: tx,
              );
              continue;
            }
            final observed = stream ? _date(event.observedAt) : raw.observed;
            final routes =
                !(stream && decision?.outcome == StreamOutcome.stale);
            await _limits(tx, deadline);
            final inserted = await session.db.unsafeQuery(
              '''INSERT INTO events
(observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,config_snapshot_id,source_time,payload,state_outcome,effective_source_time)
VALUES (@observed,CAST(@event AS uuid),@disposition,@rawObserved,CAST(@raw AS uuid),CAST(@source AS uuid),@pin,@sourceTime,@payload,@stateOutcome,@effective)
ON CONFLICT (observed_at,event_id,disposition) DO NOTHING RETURNING event_id''',
              parameters: QueryParameters.named({
                'observed': observed,
                'rawObserved': raw.observed,
                'event': event.eventId,
                'disposition': disposition,
                'raw': raw.id,
                'source': raw.source,
                'pin': raw.pin,
                'sourceTime': _date(event.sourceTime!),
                'payload': item.payload,
                'stateOutcome': switch (decision?.outcome) {
                  StreamOutcome.applied || StreamOutcome.repaired => 'applied',
                  StreamOutcome.stale => 'stale',
                  _ => null,
                },
                'effective': _date(effective.effectiveAt),
              }),
              transaction: tx,
              timeoutInSeconds: 5,
            );
            if (inserted.isNotEmpty) {
              if (isClamped) clamped++;
              aggregate +=
                  item.payload.length *
                  (1 +
                      (item.disposition == EvidenceDisposition.ready && routes
                          ? outputs.length
                          : 0));
              if (aggregate > _fanoutLimit) {
                throw const EventFieldError('alerts', 'batch_bound');
              }
            }
            if (item.disposition == EvidenceDisposition.futureDated) {
              if (inserted.isEmpty) {
                duplicateQuarantine++;
              } else {
                quarantines++;
              }
              continue;
            }
            if (inserted.isEmpty) {
              throw StateError('Eligible event key conflict');
            }
            if (item.disposition == EvidenceDisposition.late) {
              late++;
              continue;
            }
            committed++;
            if (!routes) continue;
            if (outputs.isEmpty) {
              unrouted++;
            }
            final created = clock().toUtc();
            for (final output in outputs) {
              await _limits(tx, deadline);
              await session.db.unsafeExecute(
                '''INSERT INTO outbox
(created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,config_snapshot_id,output_kind,definition_digest,target_url,signing_key_ref,signing_key_commitment,payload)
VALUES (@created,CAST(@delivery AS uuid),@observed,CAST(@event AS uuid),@disposition,CAST(@output AS uuid),@pin,@kind,@digest,@url,@ref,@commitment,@payload)''',
                parameters: QueryParameters.named({
                  'created': created,
                  'delivery': const Uuid().v4(),
                  'observed': observed,
                  'event': event.eventId,
                  'disposition': disposition,
                  'output': output.id,
                  'pin': raw.pin,
                  'kind': switch (output) {
                    _WebhookOutput() => 'webhook',
                    _PluginOutput() => 'plugin',
                  },
                  'digest': switch (output) {
                    _WebhookOutput() => null,
                    _PluginOutput(:final digest) => digest,
                  },
                  'url': switch (output) {
                    _WebhookOutput(:final url) => url,
                    _PluginOutput() => null,
                  },
                  'ref': switch (output) {
                    _WebhookOutput(:final ref) => ref,
                    _PluginOutput() => null,
                  },
                  'commitment': switch (output) {
                    _WebhookOutput(:final commitment) => commitment,
                    _PluginOutput() => null,
                  },
                  'payload': item.payload,
                }),
                transaction: tx,
                timeoutInSeconds: 5,
              );
            }
          }
        } on EventValidationError catch (error) {
          await savepoint.rollback();
          await _fail(
            tx,
            deadline,
            raw,
            error.code,
            stream ? error.path : safeFailurePath(error.path, kind),
          );
          return true;
        }
        await savepoint.release();
        if (syncId != null) {
          final counts = {
            'applied': applied,
            'confirmed': confirmed,
            'repaired': repaired,
            'tombstoned': tombstoned,
            'duplicate_observation': duplicates,
            'late': late,
            'future_dated': quarantines,
            'stale': stale,
            'soft_info': batch.softInfo,
            'clamped': clamped,
            'diverged': diverged,
          };
          await _limits(tx, deadline);
          final updated = await session.db.unsafeExecute(
            '''UPDATE icinga2_sync_progress AS p
              SET rows_done=rows_done+1, counts=p.counts || (
                SELECT jsonb_object_agg(k, coalesce((p.counts->>k)::bigint,0) + v::bigint)
                FROM jsonb_each_text(CAST(@counts AS jsonb)) AS e(k,v))
              WHERE sync_id=CAST(@sync AS uuid)''',
            parameters: QueryParameters.named({
              'sync': syncId,
              'counts': jsonEncode(counts),
            }),
            transaction: tx,
          );
          if (updated != 1) throw StateError('Missing Icinga sync progress');
          if (committed == 0) {
            await _limits(tx, deadline);
            await session.db.unsafeExecute(
              'DELETE FROM icinga2_raw_origin WHERE raw_id=CAST(@raw AS uuid)',
              parameters: QueryParameters.named({'raw': raw.id}),
              transaction: tx,
            );
            await _limits(tx, deadline);
            await session.db.unsafeExecute(
              'DELETE FROM raw_inbox WHERE observed_at=@observed AND raw_id=CAST(@raw AS uuid)',
              parameters: QueryParameters.named({
                'raw': raw.id,
                'observed': raw.observed,
              }),
              transaction: tx,
            );
            deadline.check();
            return true;
          }
        }
        await _limits(tx, deadline);
        await session.db.unsafeExecute(
          'UPDATE raw_inbox SET status=\'done\',next_attempt_at=NULL,outcome_json=@outcome WHERE observed_at=@observed AND raw_id=CAST(@raw AS uuid)',
          parameters: QueryParameters.named({
            'observed': raw.observed,
            'raw': raw.id,
            'outcome': jsonEncode({
              'upstream_omitted': batch.upstreamOmissions,
              'unknown_top_level_fields': batch.unknownTopLevelFields,
              'unknown_top_level_overflow': batch.unknownTopLevelOverflow,
              'committed': committed,
              'unrouted': unrouted,
              'duplicate_observation': duplicates,
              'future_dated': quarantines,
              'duplicate_quarantine': duplicateQuarantine,
              'late': late,
              'applied': applied,
              'stale': stale,
              'clamped': clamped,
              if (stream) 'soft_info': batch.softInfo,
              if (stream) 'confirmed': confirmed,
              if (stream) 'repaired': repaired,
              if (stream) 'tombstoned': tombstoned,
            }),
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        deadline.check();
        completedBatch = batch;
        return true;
      });
      if (claimed != null) _retryCounts.remove(claimed!.id);
      final batch = completedBatch;
      if (batch != null &&
          (batch.unknownTopLevelFields.isNotEmpty ||
              batch.unknownTopLevelOverflow != 0)) {
        try {
          log?.call(
            formatUnknownFieldWarning(
              claimed!.source,
              batch.unknownTopLevelFields,
              batch.unknownTopLevelOverflow,
            ),
          );
        } catch (_) {
          // The done row is the durable flag; logging cannot retry committed work.
        }
      }
      return processed;
    } catch (error) {
      if (claimed == null) rethrow;
      await _recordError(claimed!, error);
      return true;
    }
  }

  /// The pinned source's kind, or `null` when it has none.
  ///
  /// A format version 1 snapshot carries no kind and defines Alertmanager. In
  /// a version 2 snapshot a missing or unknown kind is none.
  SourceKind? _kindOf(
    Map<String, Object?> snapshot,
    Map<String, Object?> source,
  ) => switch (snapshot['format_version']) {
    1 => SourceKind.alertmanager,
    _ => SourceKind.named(source['kind']),
  };

  /// The decoder of [kind], or `null` when there is no kind.
  KindDecoder? _decoderFor(SourceKind? kind) {
    return switch (kind) {
      null => null,
      AlertmanagerSourceKind() => decodeAlertmanagerRequest,
      Icinga2SourceKind() => icinga2Decoder,
    };
  }

  Future<({DecodedBatch batch, String? syncId})> _decodeStream(
    DecodeRequest request,
    _Raw raw,
    Transaction tx,
  ) async {
    final envelope = IcingaStreamRow.parse(request.bytes);
    final admitted = await session.db.unsafeQuery(
      '''SELECT o.origin, source->>'state_type_policy', o.sync_id::text
        FROM icinga2_raw_origin o
        JOIN ingest_config_snapshot c ON c."snapshotId"=o.admission_snapshot_id
        CROSS JOIN LATERAL jsonb_array_elements(c."publicJson"::jsonb->'sources') source
        WHERE o.raw_id=CAST(@raw AS uuid) AND source->>'id'=@source''',
      parameters: QueryParameters.named({'raw': raw.id, 'source': raw.source}),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    if (admitted.isEmpty) {
      throw const EventFieldError('origin', 'missing_origin');
    }
    final metadata = admitted.single;
    final policy = switch (metadata[1]) {
      'hard_only' => StreamStateTypePolicy.hardOnly,
      'soft_and_hard' => StreamStateTypePolicy.softAndHard,
      _ => throw const EventFieldError(
        'state_type_policy',
        'invalid_state_type_policy',
      ),
    };
    final origin = metadata[0] == 'sync'
        ? IcingaStreamOrigin.sync
        : IcingaStreamOrigin.stream;
    return (
      batch: envelope.decode(request, origin, policy),
      syncId: metadata[2] as String?,
    );
  }

  Future<void> _fail(
    Transaction tx,
    _Deadline deadline,
    _Raw raw,
    String code,
    String? path,
  ) async {
    await _limits(tx, deadline);
    await session.db.unsafeExecute(
      '''INSERT INTO pipeline_failures
("rawObservedAt","rawId","configSnapshotId","errorClass","fieldPath","createdAt")
VALUES (@observed,CAST(@raw AS uuid),@pin,@code,@path,@now)''',
      parameters: QueryParameters.named({
        'observed': raw.observed,
        'raw': raw.id,
        'pin': raw.pin,
        'code': code,
        'path': path,
        'now': clock().toUtc(),
      }),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    await _limits(tx, deadline);
    await session.db.unsafeExecute(
      "UPDATE raw_inbox SET status='failed',next_attempt_at=NULL WHERE observed_at=@observed AND raw_id=CAST(@raw AS uuid)",
      parameters: QueryParameters.named({
        'observed': raw.observed,
        'raw': raw.id,
      }),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    await _limits(tx, deadline);
    await session.db.unsafeExecute(
      '''UPDATE icinga2_sync_progress AS p SET rows_failed=rows_failed+1
      FROM icinga2_raw_origin AS o WHERE o.raw_id=CAST(@raw AS uuid) AND p.sync_id=o.sync_id''',
      parameters: QueryParameters.named({'raw': raw.id}),
      transaction: tx,
    );
    deadline.check();
  }

  Future<void> _recordError(_Raw raw, Object error) async {
    final code = error is DatabaseQueryException ? error.code : null;
    final transient =
        code == '40001' ||
        code == '40P01' ||
        code == '55P03' ||
        (code != null && code.startsWith('08')) ||
        error is SocketException ||
        (error is DatabaseQueryException && code == null);
    final deadline = _Deadline();
    final recorded = await session.db.transaction((tx) async {
      await _limits(tx, deadline);
      final rows = await session.db.unsafeQuery(
        '''SELECT attempt_count FROM raw_inbox WHERE observed_at=@observed
AND raw_id=CAST(@raw AS uuid) AND status='pending' AND config_snapshot_id=@pin FOR UPDATE''',
        parameters: QueryParameters.named({
          'observed': raw.observed,
          'raw': raw.id,
          'pin': raw.pin,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (rows.isEmpty) {
        _retryCounts.remove(raw.id);
        return false;
      }
      final attempts = (rows.single[0] as int) + (transient ? 0 : 1);
      if (attempts >= 5) {
        await _limits(tx, deadline);
        await session.db.unsafeExecute(
          'UPDATE raw_inbox SET attempt_count=@attempts WHERE observed_at=@observed AND raw_id=CAST(@raw AS uuid)',
          parameters: QueryParameters.named({
            'attempts': attempts,
            'observed': raw.observed,
            'raw': raw.id,
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
        await _fail(tx, deadline, raw, 'processing_exhausted', null);
        _retryCounts.remove(raw.id);
      } else {
        // Only scheduling hints live here; the durable next-attempt time and
        // internal-error budget remain authoritative across eviction/restart.
        if (!_retryCounts.containsKey(raw.id) && _retryCounts.length >= 64) {
          _retryCounts.remove(_retryCounts.keys.first);
        }
        final failures = (_retryCounts[raw.id] ?? 0) + 1;
        _retryCounts[raw.id] = failures;
        final seconds = (1 << (failures - 1).clamp(0, 5)).clamp(1, 30);
        final delay = retryDelay?.call(failures) ?? Duration(seconds: seconds);
        await _limits(tx, deadline);
        await session.db.unsafeExecute(
          '''UPDATE raw_inbox SET attempt_count=@attempts,next_attempt_at=@next
WHERE observed_at=@observed AND raw_id=CAST(@raw AS uuid)''',
          parameters: QueryParameters.named({
            'attempts': attempts,
            'next': clock().toUtc().add(delay),
            'observed': raw.observed,
            'raw': raw.id,
          }),
          transaction: tx,
          timeoutInSeconds: 5,
        );
      }
      deadline.check();
      return true;
    });
    if (recorded) {
      if (transient) {
        counters.transientRetries++;
      } else {
        counters.internalAttempts++;
      }
    }
  }
}

/// Runs bounded inbox acquisitions in worker and all roles.
final class PipelineSubsystem extends Subsystem {
  /// Creates a worker using fresh sessions and an optional post-pin barrier.
  PipelineSubsystem({
    required this.openSession,
    this.clock,
    this.afterPin,
    this.backoff,
    this.retryDelay,
    this.log,
  });
  final Future<Session> Function() openSession;
  final DateTime Function()? clock;
  final Future<void> Function()? afterPin;
  final Future<void> Function(Duration)? backoff;
  final Duration Function(int)? retryDelay;

  /// The optional best-effort post-commit warning sink.
  final void Function(String)? log;
  Completer<void>? _stopping;
  Future<void>? _run;
  final _retryCounts = <String, int>{};
  final counters = PipelineCounters();

  @override
  String get name => 'pipeline';
  @override
  Set<ProcessRole> get roles => const {ProcessRole.worker, ProcessRole.all};

  @override
  Future<void> start() async {
    _stopping = Completer<void>();
    _run = _loop();
  }

  Future<void> _loop() async {
    while (!_stopping!.isCompleted) {
      var didWork = false;
      try {
        final session = await openSession();
        try {
          final repository = PipelineRepository(
            session,
            clock: clock,
            afterPin: afterPin,
            retryCounts: _retryCounts,
            counters: counters,
            retryDelay: retryDelay,
            log: log,
          );
          didWork = await repository.pinOne();
          if (!_stopping!.isCompleted) {
            didWork = await repository.processOne() || didWork;
          }
        } finally {
          await session.close();
        }
      } catch (_) {
        if (!_stopping!.isCompleted) await _pause(const Duration(seconds: 1));
      }
      if (!didWork && !_stopping!.isCompleted) {
        await _pause(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> _pause(Duration duration) async {
    await Future.any([
      backoff?.call(duration) ?? Future<void>.delayed(duration),
      _stopping!.future,
    ]);
  }

  /// Stops at once before start, or waits for the existing run to finish.
  @override
  Future<void> stop() async {
    final stopping = _stopping;
    if (stopping == null) return;
    if (!stopping.isCompleted) stopping.complete();
    await _run;
  }
}
