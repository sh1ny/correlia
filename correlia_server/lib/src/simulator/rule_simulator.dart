import 'dart:convert';

import 'package:serverpod/serverpod.dart';

import '../event/canonical_event.dart';
import '../event/event_timestamp.dart';
import '../generated/protocol.dart' hide ConditionTrace;
import '../ingest/config_repository.dart';
import '../matcher/matcher_document.dart';
import '../matcher/matcher_regex_worker.dart';
import 'rule_simulation.dart';
import 'simulation_input.dart';
import 'stored_event_lookup.dart';

/// The most bytes of draft matcher text a request may carry, as for the ingest
/// configuration file.
const simulationDraftLimit = 64 * 1024;

/// The error code of a draft that is not JSON.
const simulationInvalidJson = 'invalid_json';

/// Runs one rule simulation: validates the request, reads what it needs in one
/// read-only transaction and evaluates the rules after that transaction ends.
///
/// The simulator writes nothing. Its regex worker, clock and budget are
/// injectable so tests need no real waiting.
final class RuleSimulator {
  /// Creates a simulator; [regexWorker] is shared when given, otherwise each
  /// simulation starts and stops its own.
  RuleSimulator({
    this.regexWorker,
    this.elapsed,
    this.optionalBudget = simulationOptionalBudget,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The regex worker to use, or `null` for one per simulation.
  final MatcherRegexWorker? regexWorker;

  /// The elapsed-time source of the optional budget, a stopwatch by default.
  final Duration Function()? elapsed;

  /// The optional time budget of one simulation.
  final Duration optionalBudget;

  final DateTime Function() _clock;

  /// Simulates the one event the request names.
  ///
  /// The input is exactly one of [eventJson] or [eventId] with [observedAt] and
  /// an optional [disposition]; [draftMatcher] is an optional matcher section
  /// as JSON text. Every failure is a [SimulationError] in the result, never a
  /// thrown error.
  Future<RuleSimulationResult> simulate(
    Session session, {
    String? eventJson,
    String? eventId,
    String? observedAt,
    String? disposition,
    String? draftMatcher,
  }) async {
    final source = draftMatcher == null
        ? SimulationRuleSource.active
        : SimulationRuleSource.draft;
    RuleSimulationResult failure(SimulationError error) =>
        simulationFailure(error, ruleSource: source);
    final input = validateSimulationInput(
      eventJson: eventJson,
      eventId: eventId,
      observedAt: observedAt,
      disposition: disposition,
    );
    final SimulationRequest request;
    switch (input) {
      case RejectedSimulationInput(:final error):
        return failure(error);
      case AcceptedSimulationInput(request: final accepted):
        request = accepted;
    }
    final Object? draftJson;
    if (draftMatcher == null) {
      draftJson = null;
    } else {
      if (utf8.encode(draftMatcher).length > simulationDraftLimit) {
        return failure(
          SimulationError(code: simulationTooLarge, field: 'draftMatcher'),
        );
      }
      try {
        draftJson = jsonDecode(draftMatcher);
      } on FormatException {
        return failure(
          SimulationError(code: simulationInvalidJson, field: 'draftMatcher'),
        );
      }
    }
    final loaded = await session.db.transaction(
      (tx) => _load(session, tx, request, draftMatcher != null, draftJson),
      settings: const TransactionSettings(
        isolationLevel: IsolationLevel.repeatableRead,
      ),
    );
    return switch (loaded) {
      _Failed(:final error) => failure(error),
      _Loaded(:final event, :final document, :final context) =>
        simulateWithFreshBudgets(
          event: event,
          document: document,
          context: context,
          worker: regexWorker,
          elapsed: elapsed,
          optionalBudget: optionalBudget,
        ),
    };
  }

  Future<_Load> _load(
    Session session,
    Transaction tx,
    SimulationRequest request,
    bool hasDraft,
    Object? draftJson,
  ) async {
    await session.db.unsafeSimpleExecute(
      'SET TRANSACTION READ ONLY',
      transaction: tx,
    );
    final active = await IngestConfigRepository(
      session,
    ).activeSnapshot(transaction: tx);
    final snapshot = active == null
        ? null
        : jsonDecode(active['publicJson']! as String) as Map<String, Object?>;
    final outputIds = {
      for (final output
          in (snapshot?['outputs'] as List<Object?>? ?? const <Object?>[])
              .cast<Map<String, Object?>>())
        output['id']! as String,
    };
    final MatcherDocument document;
    try {
      if (hasDraft) {
        document = MatcherDocument.parse(draftJson, outputIds);
        if (checkSimulationDraft(document) case final error?) {
          return _Failed(error);
        }
      } else if (snapshot != null && snapshot.containsKey('matcher')) {
        document = MatcherDocument.fromSnapshot(
          snapshot['matcher'],
          outputIds,
        );
      } else {
        document = MatcherDocument.empty;
      }
    } on MatcherDocumentError catch (error) {
      return _Failed(simulationErrorFromDocument(error));
    }
    final CanonicalEvent event;
    StoredEventInfo? stored;
    switch (request) {
      case PastedEventRequest(event: final pasted):
        event = pasted;
      case StoredEventRequest():
        final found = await lookupStoredEvent(
          session,
          tx,
          request,
          processedAt: EventTimestamp.parse(
            _clock().toUtc().toIso8601String(),
          ),
        );
        switch (found) {
          case StoredEventLookupFailure(:final error):
            return _Failed(error);
          case FoundStoredEvent(
            :final member,
            stored: final storedEvent,
            :final snapshotId,
          ):
            event = member;
            stored = StoredEventInfo.fromEvent(
              storedEvent,
              snapshotId: snapshotId,
            );
        }
    }
    final sources =
        (snapshot?['sources'] as List<Object?>? ?? const <Object?>[])
            .cast<Map<String, Object?>>();
    final source = sources
        .where((entry) => entry['id'] == event.source.sourceInstance)
        .firstOrNull;
    return _Loaded(
      event,
      document,
      SimulationContext(
        ruleSource: hasDraft
            ? SimulationRuleSource.draft
            : SimulationRuleSource.active,
        snapshotId: active?['snapshotId'] as String?,
        snapshotRevision: active?['revision'] as int?,
        baselineRoutes: [
          for (final id
              in (source?['output_ids'] as List<Object?>? ?? const []))
            id! as String,
        ],
        sourceAbsent: source == null,
        stored: stored,
      ),
    );
  }
}

sealed class _Load {
  const _Load();
}

final class _Failed extends _Load {
  const _Failed(this.error);
  final SimulationError error;
}

final class _Loaded extends _Load {
  const _Loaded(this.event, this.document, this.context);
  final CanonicalEvent event;
  final MatcherDocument document;
  final SimulationContext context;
}
