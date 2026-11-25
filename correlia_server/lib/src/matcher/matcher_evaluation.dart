import 'dart:typed_data';

import '../event/canonical_event.dart';
import '../event/cloud_event.dart';
import '../event/validation.dart';
import 'matcher_condition.dart';
import 'matcher_document.dart';
import 'matcher_regex_worker.dart';

/// A capture operation implemented by the cancellable regex worker.
typedef MatcherCapture =
    Future<String?> Function(String pattern, String input, int group);

/// Stages and validates one rule's changes against the current event.
///
/// A non-match yields `null`. Operands read [original] rather than changes
/// from earlier rules. A thrown error discards the entire patch.
Future<({CanonicalEvent event, Set<String> routes})?> applyMatcherRule(
  MatcherRule rule, {
  required CanonicalEvent original,
  required CanonicalEvent current,
  MatcherRegexTest? regexTest,
  required MatcherCapture capture,
  void Function()? check,
}) async {
  check?.call();
  final matched = await rule.condition.matches(original, regexTest: regexTest);
  check?.call();
  if (!matched) return null;
  final labels = <String, String>{};
  final links = <EventLink>[];
  final routes = <String>{};
  EventSeverity? severity;
  for (final action in rule.actions) {
    check?.call();
    switch (action) {
      case MatcherLabel(:final key, :final value):
        labels[key] = value;
      case MatcherClassify(:final value):
        labels[reservedNoiseKey] = value.name;
      case MatcherRoute(:final outputId):
        routes.add(outputId);
      case MatcherSeverity(:final values):
        severity = values[original.severity] ?? severity;
      case MatcherLink(:final link):
        links.add(link);
      case MatcherExtract(
        :final field,
        :final pattern,
        :final key,
        :final group,
      ):
        final input = field.read(original);
        if (input == null) continue;
        final value = await capture(pattern.dartPattern, input, group);
        check?.call();
        if (value != null) labels[key] = value;
      case MatcherLocation(:final field, :final entries):
        final input = field.read(original);
        if (input == null) continue;
        for (final entry in entries) {
          if (entry.hostname == input ||
              entry.network?.contains(input) == true) {
            if (entry.site case final site?) labels['site'] = site;
            if (entry.environment case final environment?) {
              labels['environment'] = environment;
            }
            break;
          }
        }
    }
    check?.call();
  }
  if (labels.isEmpty &&
      links.isEmpty &&
      (severity == null || severity == current.severity)) {
    return (event: current, routes: routes);
  }
  final projection = current.toJson();
  if (labels.isNotEmpty) {
    projection['labels'] = {...current.labels, ...labels};
    projection['labels_origin'] = {
      ...current.labelsOrigin,
      for (final key in labels.keys) key: 'matcher',
    };
  }
  if (links.isNotEmpty) {
    projection['links'] = [
      for (final link in [...current.links, ...links])
        <String, Object?>{
          'href': link.href,
          'relation': link.relation,
          'text': ?link.text,
        },
    ];
  }
  if (severity != null) {
    projection['severity'] = 'EVENT_SEVERITY_${severity.name.toUpperCase()}';
  }
  final event = CanonicalEvent.fromJson(projection);
  check?.call();
  return (event: event, routes: routes);
}

/// Adds bounded failure diagnostics without changing event identity.
CanonicalEvent withMatcherDiagnostics(
  CanonicalEvent event,
  List<EventEnrichmentError> errors,
) {
  final projection = event.toJson();
  final pipeline = projection['pipeline']! as Map<String, Object?>;
  final previous = pipeline['enrichment_errors'] as List<Object?>?;
  projection['pipeline'] = <String, Object?>{
    ...pipeline,
    'enrichment_errors': [
      ...?previous,
      for (final error in errors)
        {'stage': error.stage, 'code': error.code, 'message': error.message},
    ],
  };
  return CanonicalEvent.fromJson(projection);
}

/// Applies optional matcher patches within one row's remaining fanout budget.
final class MatcherBatch {
  MatcherBatch(
    this._document,
    this._regex,
    this._optionalRemaining, {
    required int availableBytes,
  }) : _available = availableBytes;

  final MatcherDocument _document;
  final MatcherRegexRow _regex;
  final Duration Function() _optionalRemaining;
  int _available;
  bool _stopped = false;

  /// Failure counts for committed retained events, keyed by rule ID.
  final failures = <String, int>{};

  /// Number of rule evaluations left unattempted at the shared cutoff.
  int unattempted = 0;

  void _check() {
    if (_optionalRemaining() <= Duration.zero) throw const _OptionalCutoff();
  }

  /// Evaluates one retained event and returns its final bytes and extra routes.
  Future<({Uint8List payload, Set<String> routes})> enrich(
    CanonicalEvent original,
    Uint8List baseline,
    Set<String> baseRoutes,
    bool deliverable,
  ) async {
    final rules = _document.rules;
    if (_stopped) {
      unattempted += rules.length;
      return (payload: baseline, routes: const <String>{});
    }
    final routes = <String>{};
    final errors = <EventEnrichmentError>[];
    var event = original;
    var payload = baseline;
    var copies = 1 + (deliverable ? baseRoutes.length : 0);
    var cost = payload.length * copies;
    void fail(String id, String code) {
      failures.update(id, (value) => value + 1, ifAbsent: () => 1);
      errors.add(
        EventEnrichmentError(stage: 'matcher', code: code, message: id),
      );
    }

    for (var i = 0; i < rules.length; i++) {
      if (_optionalRemaining() <= Duration.zero) {
        _stopped = true;
        unattempted += rules.length - i;
        break;
      }
      final rule = rules[i];
      try {
        final patch = await applyMatcherRule(
          rule,
          original: original,
          current: event,
          regexTest: _regex.matches,
          capture: _regex.capture,
          check: _check,
        );
        if (patch == null) continue;
        final bytes = identical(patch.event, event)
            ? payload
            : CloudEvent(event: patch.event).toJsonBytes();
        final added = deliverable
            ? patch.routes
                  .where(
                    (id) => !baseRoutes.contains(id) && !routes.contains(id),
                  )
                  .toList()
            : const <String>[];
        final delta = (copies + added.length) * bytes.length - cost;
        _check();
        if (delta > _available) {
          fail(rule.id, 'batch_bound');
          continue;
        }
        _available -= delta;
        cost += delta;
        copies += added.length;
        event = patch.event;
        payload = bytes;
        routes.addAll(added);
      } on _OptionalCutoff {
        fail(rule.id, 'matcher_cutoff');
        _stopped = true;
      } on MatcherRegexUnavailable catch (error) {
        _stopped = _optionalRemaining() <= Duration.zero;
        fail(rule.id, _stopped ? 'matcher_cutoff' : error.code);
      } on EventValidationError catch (error) {
        _stopped = _optionalRemaining() <= Duration.zero;
        fail(rule.id, _stopped ? 'matcher_cutoff' : error.code);
      }
      if (_stopped) {
        unattempted += rules.length - i - 1;
        break;
      }
    }
    if (errors.isNotEmpty && !_stopped) {
      final accepted = <EventEnrichmentError>[];
      for (final error in errors) {
        try {
          _check();
          accepted.add(error);
          final withErrors = withMatcherDiagnostics(event, accepted);
          final bytes = CloudEvent(event: withErrors).toJsonBytes();
          final delta = bytes.length * copies - cost;
          _check();
          if (delta <= _available) {
            _available -= delta;
            cost += delta;
            payload = bytes;
          } else {
            accepted.removeLast();
          }
        } on EventValidationError {
          accepted.removeLast();
        } on _OptionalCutoff {
          _stopped = true;
          break;
        }
      }
    }
    return (payload: payload, routes: routes);
  }
}

final class _OptionalCutoff implements Exception {
  const _OptionalCutoff();
}
