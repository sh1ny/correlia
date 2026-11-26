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
        GenericMapping,
        GenericPointer,
        GenericSourceKind,
        Icinga2SourceKind,
        SourceKind,
        sha256Digest;
import '../ingest/icinga2/decoder.dart';
import '../ingest/source_decoder.dart';
import '../matcher/matcher_document.dart';
import '../matcher/matcher_evaluation.dart';
import '../matcher/matcher_regex_worker.dart';
import '../output/queue_intents.dart';
import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import '../state/alert_state_service.dart';
import '../state/ordering_key.dart';
import '../state/transition.dart';
import 'row_decode.dart';

/// Monotonic processing budget for a claimed raw row.
const pipelineRowDeadline = Duration(seconds: 10);

/// The most bytes one raw row's retained events and their copies may take.
const pipelineFanoutLimit = 16 * 1024 * 1024;

/// The maximum source clock lead used by alert-state ordering.
const skewAllowance = Duration(minutes: 5);

/// Evidence older than this relative to receipt is not applied.
const evidenceLatenessHorizon = Duration(days: 7);

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
  if (sourceMicros < observedMicros - evidenceLatenessHorizon.inMicroseconds) {
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

/// Renders a bounded validation path for storage. For generic sender errors,
/// [senderPath] only keeps array indexes and matching prefixes authored in
/// the pinned [mapping]. Canonical and legacy paths use a field allow-list.
String safeFailurePath(
  String path,
  SourceKind kind, {
  GenericMapping? mapping,
  List<EventPointerSegment>? senderPath,
}) {
  if (kind is GenericSourceKind && senderPath != null) {
    return boundedEventPointer(_safeGenericSegments(senderPath, mapping!));
  }
  final (fields, indexed) = switch (kind) {
    AlertmanagerSourceKind() => (
      _alertmanagerPathFields,
      RegExp(r'^alerts\[[0-9]{1,4}\]$'),
    ),
    Icinga2SourceKind() => (_icinga2PathFields, null),
    GenericSourceKind() => (const {'event', 'identity_fields'}, null),
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

Iterable<EventPointerSegment> _safeGenericSegments(
  List<EventPointerSegment> path,
  GenericMapping mapping,
) sync* {
  final items = mapping.items?.segments;
  var inItems = items != null;
  var alertOffset = 0;
  final candidates = items == null
      ? mapping.alertPointers.toList()
      : <GenericPointer>[];
  for (var i = 0; i < path.length; i++) {
    final part = path[i];
    var authored = false;
    if (inItems) {
      if (i < items!.length) {
        authored = items[i] == part.token;
        if (!authored) inItems = false;
      } else {
        inItems = false;
        if (part.arrayIndex) {
          alertOffset = i + 1;
          candidates.addAll(mapping.alertPointers);
        }
      }
    } else if (candidates.isNotEmpty) {
      final depth = i - alertOffset;
      candidates.removeWhere(
        (p) => p.segments.length <= depth || p.segments[depth] != part.token,
      );
      authored = candidates.isNotEmpty;
    }
    yield (
      token: part.arrayIndex || authored ? part.token : '*',
      arrayIndex: part.arrayIndex,
    );
  }
}

final class _Raw {
  const _Raw(
    this.observed,
    this.id,
    this.source,
    this.bytes,
    this.digest,
    this.pin,
    this.epoch,
  );
  final DateTime observed;
  final String id;
  final String source;
  final Uint8List bytes;
  final String digest;
  final String pin;
  final int epoch;
  bool get replayed => epoch != 0;
  String get retryKey => '$id:$epoch';
}

final class _OutputDeferral implements Exception {
  const _OutputDeferral(this.demands);

  final Map<String, ({int rows, int bytes})> demands;
}

Future<void> _writeIntents(
  Session session,
  Transaction tx,
  _Deadline deadline,
  _Raw raw,
  List<QueueIntent> intents,
  Iterable<String> destinations,
  DateTime created,
) async {
  if (intents.isEmpty) return;
  final caps = await lockOutputCapacity(session, tx, destinations);
  final demands = <String, ({int rows, int bytes})>{};
  for (final intent in intents) {
    final id = intent.destination.id;
    final old = demands[id] ?? (rows: 0, bytes: 0);
    demands[id] = (
      rows: old.rows + 1,
      bytes: old.bytes + intent.payload.length,
    );
  }
  final blocked = <String, ({int rows, int bytes})>{
    for (final MapEntry(key: id, value: demand) in demands.entries)
      if (caps[id]!.blocking && !caps[id]!.fits(demand.rows, demand.bytes))
        id: demand,
  };
  if (blocked.isNotEmpty) throw _OutputDeferral(blocked);

  await lockOutputCommitments(session, tx, raw.pin, destinations);
  final ignored = <String, ({int rows, int bytes})>{};
  for (final intent in intents) {
    deadline.check();
    final id = intent.destination.id;
    final bytes = intent.payload.length;
    if (caps[id]!.take(bytes)) {
      await insertQueueIntent(session, tx, raw.pin, created, intent);
    } else {
      final old = ignored[id] ?? (rows: 0, bytes: 0);
      ignored[id] = (
        rows: old.rows + 1,
        bytes: old.bytes > bytes ? old.bytes : bytes,
      );
    }
  }
  for (final id in demands.keys) {
    final cap = caps[id]!;
    final discarded = ignored[id];
    if (discarded != null || cap.rows == 0 || cap.bytes == 0) {
      await recordOutputOverflow(
        session,
        tx,
        id,
        created,
        reason: discarded == null ? 'saturated' : 'discard_new',
        discarded: discarded?.rows ?? 0,
        rows: 1,
        bytes: discarded?.bytes ?? 1,
      );
    }
  }
}

final class _Prepared {
  const _Prepared(this.event, this.disposition, this.payload, this.position);
  final CanonicalEvent event;
  final EvidenceDisposition disposition;
  final Uint8List payload;

  /// The event's position in its decoded batch.
  final int position;
}

typedef _Retained = ({
  _Prepared item,
  String disposition,
  DateTime observed,
  DateTime effective,
  String? stateOutcome,
  bool routes,
});

final class _Deadline {
  _Deadline(this._testElapsed)
    : _stopwatch = _testElapsed == null ? (Stopwatch()..start()) : null;

  final Duration Function()? _testElapsed;
  final Stopwatch? _stopwatch;
  Duration get _elapsed => _stopwatch?.elapsed ?? _testElapsed!();

  Duration get optionalRemaining =>
      pipelineRowDeadline - const Duration(seconds: 2) - _elapsed;

  void check() {
    if (_elapsed >= pipelineRowDeadline) {
      throw TimeoutException('pipeline transaction deadline');
    }
  }

  int get remainingMillis {
    check();
    final left = (pipelineRowDeadline - _elapsed).inMilliseconds;
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
    this.afterKeyReservationForTest,
    this.elapsedForTest,
    Map<String, int>? retryCounts,
    this.retryDelay,
    PipelineCounters? counters,
    this.stateSkewAllowance = skewAllowance,
    this.log,
    this.icinga2Decoder = decodeIcinga2Request,
    this.regexWorker,
    this.beforePinCommitForTest,
    this.beforeRecordErrorForTest,
    this.fanoutLimitForTest,
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

  /// Runs after inserting the key, before acquiring the alert.
  final Future<void> Function()? afterKeyReservationForTest;

  /// Test transaction elapsed time, independent of the worker receipt clock.
  final Duration Function()? elapsedForTest;
  final Map<String, int> _retryCounts;
  final Duration Function(int)? retryDelay;
  final PipelineCounters counters;
  final Duration stateSkewAllowance;

  /// The optional best-effort post-commit warning sink.
  final void Function(String)? log;

  /// The decoder of `icinga2` sources, the real one by default; `null` means
  /// that kind has no decoder.
  final KindDecoder? icinga2Decoder;

  /// The shared optional-regex worker, if the caller owns one.
  final MatcherRegexWorker? regexWorker;

  /// Fixture barrier after a pin is written but before its lock is released.
  final Future<void> Function(Transaction)? beforePinCommitForTest;

  /// Fixture barrier after the work rollback and before recording its error.
  final Future<void> Function()? beforeRecordErrorForTest;

  /// Fixture override for exact fanout boundary tests.
  final int? fanoutLimitForTest;

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

  Future<void> _lockRawPin(Transaction tx, _Deadline deadline, _Raw raw) async {
    await _limits(tx, deadline);
    await session.db.unsafeQuery(
      'SELECT correlia_lock_raw_pin(@pin,@source::uuid)',
      parameters: QueryParameters.named({'pin': raw.pin, 'source': raw.source}),
      transaction: tx,
      timeoutInSeconds: 5,
    );
  }

  /// Commits one unpinned row's active snapshot before decoding or returning.
  Future<bool> pinOne() async {
    final deadline = _Deadline(elapsedForTest);
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
        'SELECT "snapshotId" FROM ingest_active_config WHERE singleton=1 FOR SHARE',
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
      await beforePinCommitForTest?.call(tx);
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
    final deadline = _Deadline(elapsedForTest);
    MatcherRegexWorker? ownedRegex;
    try {
      final processed = await session.db.transaction((tx) async {
        await _limits(tx, deadline);
        final rows = await session.db.unsafeQuery(
          '''SELECT observed_at,raw_id::text,source_id::text,body,body_sha256,config_snapshot_id,processing_epoch
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
          row[6] as int,
        );
        claimed = raw;
        if (afterClaim case final hook?) await hook();
        await _limits(tx, deadline);
        final inputs = await readDecodeInputs(
          session,
          tx,
          RawKey(raw.observed, raw.id),
          raw.pin,
          sourceId: raw.source,
          digest: raw.digest,
          bytes: raw.bytes,
        );
        final snapshot = inputs.snapshot;
        if (inputs.rejection == DecodeRejection.sourceNotConfigured) {
          await _fail(tx, deadline, raw, 'source_not_configured', null);
          return true;
        }
        final source = inputs.source!;
        final outputIds = (source['output_ids'] as List<Object?>)
            .cast<String>()
            .toSet();
        final outputRows = (snapshot['outputs'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final matcher = snapshot.containsKey('matcher')
            ? MatcherDocument.fromSnapshot(
                snapshot['matcher'],
                {for (final output in outputRows) output['id'] as String},
              )
            : MatcherDocument.empty;
        final registry = <String, QueueDestination>{
          for (final output in outputRows)
            if (outputIds.contains(output['id']) ||
                matcher.outputIds.contains(output['id']))
              output['id'] as String: QueueDestination.fromSnapshot(output),
        };
        final outputs = [for (final id in outputIds) registry[id]!];
        final mapping = inputs.mapping;
        if (inputs.rejection == DecodeRejection.unsupportedMapping) {
          await _fail(tx, deadline, raw, 'unsupported_mapping', null);
          return true;
        }
        if (inputs.rejection == DecodeRejection.unsupportedKind ||
            (inputs.kind is Icinga2SourceKind && icinga2Decoder == null)) {
          await _fail(tx, deadline, raw, 'unsupported_kind', null);
          return true;
        }
        final kind = inputs.kind!;
        final stream = inputs.stream;
        late final DecodedBatch batch;
        String? syncId;
        final prepared = <_Prepared>[];
        try {
          final decoded = decodeRow(
            inputs,
            raw.bytes,
            processedAt: _timestamp(clock()),
            icinga2Decoder: icinga2Decoder ?? decodeIcinga2Request,
          );
          batch = decoded.batch;
          syncId = decoded.syncId;
          int? floorMicros;
          if (raw.replayed && kind is Icinga2SourceKind) {
            final floors = await session.db.unsafeQuery(
              '''
              SELECT effective_floor FROM pipeline_icinga2_replay_floor
              WHERE singleton=1 AND isfinite(effective_floor)
                AND @receipt::timestamptz < effective_floor + interval '7 days'
              ''',
              parameters: QueryParameters.named({'receipt': raw.observed}),
              transaction: tx,
              timeoutInSeconds: 5,
            );
            if (floors.isNotEmpty) {
              floorMicros =
                  (floors.single[0]! as DateTime).microsecondsSinceEpoch;
            }
          }
          deadline.check();
          for (final event in batch.events) {
            deadline.check();
            final source = event.sourceTime!;
            final receipt = stream ? _date(event.observedAt) : raw.observed;
            var disposition = classifyEvidence(source, receipt);
            // A legacy batch can span the old fence. Compare each item's
            // effective time, keeping the normal future quarantine intact.
            if (floorMicros != null &&
                disposition == EvidenceDisposition.ready &&
                (source.seconds * 1000000 + source.nanos ~/ 1000 <
                        floorMicros ||
                    receipt.microsecondsSinceEpoch +
                            stateSkewAllowance.inMicroseconds <
                        floorMicros)) {
              disposition = EvidenceDisposition.late;
            }
            final data = CloudEvent(event: event).toJsonBytes();
            prepared.add(_Prepared(event, disposition, data, prepared.length));
          }
        } on EventValidationError catch (error) {
          await _fail(
            tx,
            deadline,
            raw,
            error.code,
            stream
                ? error.path
                : safeFailurePath(
                    error.path,
                    kind,
                    mapping: mapping,
                    senderPath: switch (error) {
                      EventPointerError(:final segments) => segments,
                      EventFieldError() => null,
                    },
                  ),
          );
          return true;
        }
        // `List.sort` is not stable, so equal event IDs are ordered by input
        // position: the same-ID check below then admits the earliest member.
        prepared.sort((a, b) {
          final byId = a.event.eventId.compareTo(b.event.eventId);
          return byId != 0 ? byId : a.position.compareTo(b.position);
        });
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
        MatcherBatch? matcherBatch;
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
              await afterKeyReservationForTest?.call();
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

          Future<bool> insertEvent(_Retained retained, Uint8List bytes) async {
            final event = retained.item.event;
            await _limits(tx, deadline);
            final rows = await session.db.unsafeQuery(
              '''INSERT INTO events
(observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,config_snapshot_id,source_time,payload,state_outcome,effective_source_time)
VALUES (@observed,CAST(@event AS uuid),@disposition,@rawObserved,CAST(@raw AS uuid),CAST(@source AS uuid),@pin,@sourceTime,@payload,@stateOutcome,@effective)
ON CONFLICT (observed_at,event_id,disposition) DO NOTHING RETURNING event_id''',
              parameters: QueryParameters.named({
                'observed': retained.observed,
                'rawObserved': raw.observed,
                'event': event.eventId,
                'disposition': retained.disposition,
                'raw': raw.id,
                'source': raw.source,
                'pin': raw.pin,
                'sourceTime': _date(event.sourceTime!),
                'payload': bytes,
                'stateOutcome': retained.stateOutcome,
                'effective': retained.effective,
              }),
              transaction: tx,
              timeoutInSeconds: 5,
            );
            return rows.isNotEmpty;
          }

          final retained = <_Retained>[];
          for (final item in effects) {
            deadline.check();
            final event = item.event;
            final effective = OrderingKey.fromSource(
              sourceTime: event.sourceTime!,
              observedAt: event.observedAt,
              eventId: event.eventId,
              skewAllowance: stateSkewAllowance,
            ).effectiveAt;
            final isClamped =
                compareTimestamps(event.sourceTime!, effective) > 0;
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
            final effect = (
              item: item,
              disposition: switch (item.disposition) {
                EvidenceDisposition.ready => 'ready',
                EvidenceDisposition.late => 'late',
                EvidenceDisposition.futureDated => 'future_dated',
              },
              observed: stream ? _date(event.observedAt) : raw.observed,
              effective: _date(effective),
              stateOutcome: switch (decision?.outcome) {
                StreamOutcome.applied || StreamOutcome.repaired => 'applied',
                StreamOutcome.stale => 'stale',
                _ => null,
              },
              routes:
                  item.disposition == EvidenceDisposition.ready &&
                  !(stream && decision?.outcome == StreamOutcome.stale),
            );
            if (item.disposition == EvidenceDisposition.futureDated) {
              if (!await insertEvent(effect, item.payload)) {
                duplicateQuarantine++;
                continue;
              }
              quarantines++;
            }
            if (isClamped) clamped++;
            aggregate +=
                item.payload.length *
                (1 + (effect.routes ? outputs.length : 0));
            if (aggregate > (fanoutLimitForTest ?? pipelineFanoutLimit)) {
              throw const EventFieldError('alerts', 'batch_bound');
            }
            retained.add(effect);
          }

          if (matcher.rules.isNotEmpty && retained.isNotEmpty) {
            final regex = regexWorker ?? (ownedRegex = MatcherRegexWorker());
            Duration remaining() => deadline.optionalRemaining;
            matcherBatch = MatcherBatch(
              matcher,
              regex.newRow(remaining),
              remaining,
              availableBytes:
                  (fanoutLimitForTest ?? pipelineFanoutLimit) - aggregate,
            );
          }
          final intents = <QueueIntent>[];
          for (final effect in retained) {
            deadline.check();
            final (
              :item,
              :observed,
              :disposition,
              :routes,
              effective: _,
              stateOutcome: _,
            ) = effect;
            final event = item.event;
            final enriched = matcherBatch == null
                ? null
                : await matcherBatch.enrich(
                    event,
                    item.payload,
                    outputIds,
                    routes,
                  );
            final payload = enriched?.payload ?? item.payload;
            final addedRoutes = enriched?.routes ?? const <String>{};
            if (item.disposition == EvidenceDisposition.futureDated) {
              if (!identical(payload, item.payload)) {
                await _limits(tx, deadline);
                await session.db.unsafeExecute(
                  'UPDATE events SET payload=@payload WHERE observed_at=@observed AND event_id=@id::uuid AND disposition=@disposition',
                  parameters: QueryParameters.named({
                    'payload': payload,
                    'observed': observed,
                    'id': event.eventId,
                    'disposition': disposition,
                  }),
                  transaction: tx,
                );
              }
              continue;
            }
            if (!await insertEvent(effect, payload)) {
              throw StateError('Eligible event key conflict');
            }
            if (item.disposition == EvidenceDisposition.late) {
              late++;
              continue;
            }
            committed++;
            if (!routes) continue;
            if (outputs.isEmpty && addedRoutes.isEmpty) {
              unrouted++;
            }
            if (outputs.isEmpty && addedRoutes.isEmpty) continue;
            final destinations = addedRoutes.isEmpty
                ? outputs
                : [...outputs, for (final id in addedRoutes) registry[id]!];
            for (final output in destinations) {
              intents.add((
                observed: observed,
                event: event.eventId,
                disposition: disposition,
                destination: output,
                payload: payload,
              ));
            }
          }
          await _limits(tx, deadline);
          await _writeIntents(
            session,
            tx,
            deadline,
            raw,
            intents,
            registry.keys,
            clock().toUtc(),
          );
          // If no intent was emitted, pin release still takes output locks
          // before the sync-progress and pending-count fences.
          if (intents.isEmpty) await _lockRawPin(tx, deadline, raw);
        } on _OutputDeferral catch (error) {
          await savepoint.rollback();
          await _limits(tx, deadline);
          final caps = await lockOutputCapacity(
            session,
            tx,
            error.demands.keys,
          );
          final now = clock().toUtc();
          for (final MapEntry(key: id, value: demand)
              in error.demands.entries) {
            if (caps[id]!.blocking &&
                !caps[id]!.fits(demand.rows, demand.bytes)) {
              await recordOutputOverflow(
                session,
                tx,
                id,
                now,
                reason: 'block_ingest',
                rows: demand.rows,
                bytes: demand.bytes,
              );
            }
          }
          await _limits(tx, deadline);
          await session.db.unsafeExecute(
            'UPDATE raw_inbox SET next_attempt_at=@next WHERE observed_at=@observed AND raw_id=@id::uuid',
            parameters: QueryParameters.named({
              'next': now.add(const Duration(seconds: 1)),
              'observed': raw.observed,
              'id': raw.id,
            }),
            transaction: tx,
            timeoutInSeconds: 5,
          );
          return true;
        } on EventValidationError catch (error) {
          await savepoint.rollback();
          await _fail(
            tx,
            deadline,
            raw,
            error.code,
            kind is GenericSourceKind
                ? null
                : stream
                ? error.path
                : safeFailurePath(error.path, kind),
          );
          return true;
        }
        await savepoint.release();
        if (matcherBatch case final match? when match.failures.isNotEmpty) {
          await _limits(tx, deadline);
          await session.db.unsafeQuery(
            'SELECT correlia_record_matcher_batch(@pin, @failures::jsonb, @raw::uuid, @occurred)',
            parameters: QueryParameters.named({
              'pin': raw.pin,
              'failures': jsonEncode(match.failures),
              'raw': raw.id,
              'occurred': clock().toUtc(),
            }),
            transaction: tx,
          );
        }
        if (syncId != null && !raw.replayed) {
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
          await _finalizeSync(tx, deadline, syncId);
        }
        if (reconcile) {
          if (raw.replayed
              ? committed + late + quarantines == 0
              : committed == 0) {
            if (raw.replayed) {
              await _limits(tx, deadline);
              await session.db.unsafeExecute(
                '''
                INSERT INTO activity (occurred_at,entity_kind,entity_id,entity_version,
                  change_kind,actor_kind,cause_raw_id)
                VALUES (@now,'pipeline_failure',0,@count,'replayed_reconcile_no_event','system',@raw::uuid)
              ''',
                parameters: QueryParameters.named({
                  'now': clock().toUtc(),
                  'raw': raw.id,
                  'count':
                      confirmed + tombstoned + duplicates + stale + diverged,
                }),
                transaction: tx,
                timeoutInSeconds: 5,
              );
            }
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
              if (kind is GenericSourceKind)
                'unmapped_fields': batch.unmappedFields,
              'committed': committed,
              'unrouted': unrouted,
              'duplicate_observation': duplicates,
              'future_dated': quarantines,
              'duplicate_quarantine': duplicateQuarantine,
              'late': late,
              'applied': applied,
              'stale': stale,
              'clamped': clamped,
              if (matcherBatch case final match? when match.unattempted != 0)
                'matcher_unattempted': match.unattempted,
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
      if (claimed != null) _retryCounts.remove(claimed!.retryKey);
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
      await beforeRecordErrorForTest?.call();
      await _recordError(claimed!, error);
      return true;
    } finally {
      ownedRegex?.close();
    }
  }

  Future<void> _fail(
    Transaction tx,
    _Deadline deadline,
    _Raw raw,
    String code,
    String? path,
  ) async {
    await _lockRawPin(tx, deadline, raw);
    await _limits(tx, deadline);
    await session.db.unsafeQuery(
      '''WITH failure AS (
  INSERT INTO pipeline_failures
    ("rawObservedAt","rawId","configSnapshotId","errorClass","fieldPath","createdAt")
  VALUES (@observed::timestamptz AT TIME ZONE 'UTC',@raw::uuid,@pin,@code,@path,
    @now::timestamptz AT TIME ZONE 'UTC') RETURNING id
) SELECT correlia_record_raw_failure(@observed,@raw::uuid,@source::uuid,@pin,@code,@path,@now)
FROM failure''',
      parameters: QueryParameters.named({
        'observed': raw.observed,
        'raw': raw.id,
        'source': raw.source,
        'pin': raw.pin,
        'code': code,
        'path': path,
        'now': clock().toUtc(),
      }),
      transaction: tx,
      timeoutInSeconds: 5,
    );
    await _limits(tx, deadline);
    final failedSync = await session.db.unsafeQuery(
      '''WITH admission AS MATERIALIZED (
          SELECT origin,sync_id FROM icinga2_raw_origin WHERE raw_id=CAST(@raw AS uuid)
        ), failed_sync AS (
          UPDATE icinga2_sync_progress AS p SET rows_failed=rows_failed+1
          FROM admission a WHERE a.origin='sync' AND p.sync_id=a.sync_id AND NOT @replayed
          RETURNING p.sync_id::text AS sync_id
        ), request_sync AS (
          INSERT INTO icinga2_stream_resync ("sourceId","requestSeq")
          SELECT CAST(@source AS uuid),1 FROM admission WHERE origin='stream'
          ON CONFLICT ("sourceId") DO UPDATE SET "requestSeq"=icinga2_stream_resync."requestSeq"+1
        ) SELECT sync_id FROM failed_sync''',
      parameters: QueryParameters.named({
        'raw': raw.id,
        'source': raw.source,
        'replayed': raw.replayed,
      }),
      transaction: tx,
    );
    if (failedSync.isNotEmpty) {
      await _finalizeSync(tx, deadline, failedSync.single[0]! as String);
    }
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
    deadline.check();
  }

  Future<void> _finalizeSync(
    Transaction tx,
    _Deadline deadline,
    String syncId,
  ) async {
    await _limits(tx, deadline);
    await session.db.unsafeQuery(
      'SELECT icinga2_finalize_sync(CAST(@sync AS uuid), false)',
      parameters: QueryParameters.named({'sync': syncId}),
      transaction: tx,
    );
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
    final deadline = _Deadline(elapsedForTest);
    final recorded = await session.db.transaction((tx) async {
      await _limits(tx, deadline);
      final rows = await session.db.unsafeQuery(
        '''SELECT attempt_count FROM raw_inbox WHERE observed_at=@observed
AND raw_id=CAST(@raw AS uuid) AND status='pending' AND config_snapshot_id=@pin
AND processing_epoch=@epoch FOR UPDATE''',
        parameters: QueryParameters.named({
          'observed': raw.observed,
          'raw': raw.id,
          'pin': raw.pin,
          'epoch': raw.epoch,
        }),
        transaction: tx,
        timeoutInSeconds: 5,
      );
      if (rows.isEmpty) {
        _retryCounts.remove(raw.retryKey);
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
        _retryCounts.remove(raw.retryKey);
      } else {
        // Only scheduling hints live here; the durable next-attempt time and
        // internal-error budget remain authoritative across eviction/restart.
        final key = raw.retryKey;
        if (!_retryCounts.containsKey(key) && _retryCounts.length >= 64) {
          _retryCounts.remove(_retryCounts.keys.first);
        }
        final failures = (_retryCounts[key] ?? 0) + 1;
        _retryCounts[key] = failures;
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
  final _regex = MatcherRegexWorker();
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
            regexWorker: _regex,
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
    _regex.close();
  }
}
