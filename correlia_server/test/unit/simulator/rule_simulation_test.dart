import 'dart:convert';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/generated/protocol.dart'
    hide ConditionTrace;
import 'package:correlia_server/src/generated/protocol.dart'
    as wire
    show ConditionTrace;
import 'package:correlia_server/src/matcher/matcher_condition.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/matcher/matcher_evaluation.dart';
import 'package:correlia_server/src/matcher/matcher_regex_worker.dart';
import 'package:correlia_server/src/simulator/rule_simulation.dart';
import 'package:correlia_server/src/simulator/simulation_input.dart';
import 'package:test/test.dart';

import '../event/fixture.dart';

const _routeA = '22222222-2222-4222-8222-222222222222';
const _routeB = '33333333-3333-4333-8333-333333333333';
const _outputs = {_routeA, _routeB};
const _key = 'correlia.noise_class';
const _observed = '2026-11-10T00:00:00Z';
const _id = '86fe3b73-ec2d-5dd3-b104-11f2ec79469c';

CanonicalEvent _event({
  Map<String, String> labels = const {'alertname': 'Watchdog'},
  Map<String, String> origin = const {},
}) {
  final data = eventFixture()['data']! as Map<String, Object?>;
  data['labels'] = labels;
  data.remove('labels_origin');
  if (origin.isNotEmpty) data['labels_origin'] = origin;
  return CanonicalEvent.fromJson(data);
}

Map<String, Object?> _leaf(String field, String op, String value) => {
  'field': field,
  'op': op,
  'value': value,
};

final _always = _leaf('labels.alertname', 'equals', 'Watchdog');

Map<String, Object?> _rule(
  String id,
  List<Map<String, Object?>> actions, {
  Map<String, Object?>? when,
}) => {'id': id, 'when': when ?? _always, 'actions': actions};

Map<String, Object?> _label(String key, String value) => {
  'type': 'set_label',
  'key': key,
  'value': value,
};

MatcherDocument _document(List<Map<String, Object?>> rules) =>
    MatcherDocument.parse({
      'language': 'matcher',
      'version': 1,
      'rules': rules,
    }, _outputs);

Future<String?> _capture(String pattern, String input, int group) async =>
    RegExp(
      pattern,
      unicode: true,
      dotAll: true,
    ).firstMatch(input)?.group(group);

/// A regex fake: the first call fails with `regex_timeout`, later ones with
/// `regex_budget`, as a row's worker does once its budget is gone.
final class _FailingRegex {
  int calls = 0;
  void Function()? onFirst;

  Future<bool> call(String pattern, String input) async {
    calls++;
    if (calls == 1) {
      onFirst?.call();
      throw const MatcherRegexUnavailable('regex_timeout');
    }
    throw const MatcherRegexUnavailable('regex_budget');
  }
}

Future<bool> _regexTest(String pattern, String input) async =>
    RegExp(pattern, unicode: true, dotAll: true).hasMatch(input);

Future<RuleSimulationResult> _simulate(
  CanonicalEvent event,
  MatcherDocument document, {
  SimulationContext? context,
  MatcherRegexTest? regexTest,
  MatcherCapture? capture,
  Duration Function()? remaining,
  int? fanoutLimit,
}) => simulateRules(
  event: event,
  document: document,
  context: context ?? SimulationContext(ruleSource: SimulationRuleSource.draft),
  regexTest: regexTest ?? _regexTest,
  capture: capture ?? _capture,
  optionalRemaining: remaining ?? () => const Duration(seconds: 8),
  fanoutLimit: fanoutLimit ?? 16 * 1024 * 1024,
);

SimulationError _rejected(SimulationInputCheck check) => switch (check) {
  RejectedSimulationInput(:final error) => error,
  AcceptedSimulationInput() => fail('the input was accepted'),
};

SimulationRequest _accepted(SimulationInputCheck check) => switch (check) {
  AcceptedSimulationInput(:final request) => request,
  RejectedSimulationInput(:final error) => fail(
    'rejected: ${error.code} ${error.field}',
  ),
};

String _envelope([void Function(Map<String, Object?> envelope)? edit]) {
  final envelope = eventFixture();
  edit?.call(envelope);
  return jsonEncode(envelope);
}

void main() {
  test('both_or_neither_input_given', () {
    final both = validateSimulationInput(
      eventJson: _envelope(),
      eventId: _id,
      observedAt: _observed,
    );
    expect(_rejected(both).code, 'invalid_input');
    final neither = validateSimulationInput();
    final error = _rejected(neither);
    expect(error.code, 'invalid_input');
    expect(error.field, 'eventJson');
  });

  test('partial_or_orphaned_key_fields', () {
    void expectField(String field, SimulationInputCheck check) {
      final error = _rejected(check);
      expect(error.code, 'invalid_input', reason: field);
      expect(error.field, field);
    }

    expectField(
      'disposition',
      validateSimulationInput(eventJson: _envelope(), disposition: 'ready'),
    );
    expectField(
      'eventId',
      validateSimulationInput(eventJson: _envelope(), eventId: _id),
    );
    expectField(
      'observedAt',
      validateSimulationInput(eventJson: _envelope(), observedAt: _observed),
    );
    expectField('observedAt', validateSimulationInput(eventId: _id));
    expectField('eventId', validateSimulationInput(observedAt: _observed));
    expectField(
      'disposition',
      validateSimulationInput(disposition: 'ready'),
    );
    expectField(
      'eventId',
      validateSimulationInput(observedAt: _observed, disposition: 'ready'),
    );
  });

  test('invalid_pasted_event', () {
    final missing = _rejected(
      validateSimulationInput(
        eventJson: _envelope(
          (e) => (e['data']! as Map<String, Object?>).remove('summary'),
        ),
      ),
    );
    expect(missing.field, 'summary');
    expect(missing.code, isNot('invalid_input'));
    final notJson = _rejected(validateSimulationInput(eventJson: '{nope'));
    expect(notJson.field, isNotNull);
    final huge = _rejected(
      validateSimulationInput(
        eventJson: _envelope((e) => e['pad'] = 'x' * 300000),
      ),
    );
    expect(huge.code, 'too_large');
    expect(huge.field, 'eventJson');
  });

  test('invalid_stored_key', () {
    final badId = _rejected(
      validateSimulationInput(eventId: 'not-a-uuid', observedAt: _observed),
    );
    expect((badId.code, badId.field), ('invalid_input', 'eventId'));
    final badDisposition = _rejected(
      validateSimulationInput(
        eventId: _id,
        observedAt: _observed,
        disposition: 'archived',
      ),
    );
    expect(
      (badDisposition.code, badDisposition.field),
      ('invalid_input', 'disposition'),
    );
    for (final disposition in ['ready', 'late', 'future_dated', null]) {
      final request = _accepted(
        validateSimulationInput(
          eventId: _id.toUpperCase(),
          observedAt: _observed,
          disposition: disposition,
        ),
      );
      expect(request, isA<StoredEventRequest>());
      expect((request as StoredEventRequest).eventId, _id);
      expect(request.disposition, disposition);
    }
  });

  test('malformed_observed_at', () {
    for (final value in [
      '2026-02-30T00:00:00Z',
      '2026-13-01T00:00:00Z',
      '2026-11-10T00:00:00',
      '2026-11-10T00:00:00+0100',
      '2026-11-10',
      'yesterday',
      '',
    ]) {
      final error = _rejected(
        validateSimulationInput(eventId: _id, observedAt: value),
      );
      expect((error.code, error.field), ('invalid_input', 'observedAt'));
    }
    final request =
        _accepted(
              validateSimulationInput(
                eventId: _id,
                observedAt: '2026-11-10T01:00:00.1234567+01:00',
              ),
            )
            as StoredEventRequest;
    expect(request.observedAt.isUtc, isTrue);
    expect(
      request.observedAt,
      DateTime.utc(2026, 11, 10, 0, 0, 0, 123, 456),
    );
  });

  test('explicit_null_in_a_pasted_event', () {
    final error = _rejected(
      validateSimulationInput(
        eventJson: _envelope(
          (e) => (e['data']! as Map<String, Object?>)['summary'] = null,
        ),
      ),
    );
    expect(error.field, 'summary');
    expect(error.code, isNot('invalid_input'));
  });

  test('a_valid_pasted_event_is_decoded', () {
    final request = _accepted(
      validateSimulationInput(eventJson: _envelope()),
    );
    expect((request as PastedEventRequest).event.summary, 'Example alert');
  });

  test('a_draft_that_writes_the_reserved_key_is_rejected', () {
    final draft = _document([
      _rule('r', [_label(_key, 'heartbeat')]),
    ]);
    final error = checkSimulationDraft(draft)!;
    expect(error.code, reservedKeyCode);
    expect(error.field, 'matcher.rules[0].actions[0].key');
    expect(
      checkSimulationDraft(
        _document([
          _rule('r', [
            {'type': 'classify', 'value': 'heartbeat'},
          ]),
        ]),
      ),
      isNull,
    );
  });

  test('rul_2_a_missing_field_is_a_visible_non_match', () async {
    final result = await _simulate(
      _event(labels: {'alertname': 'Watchdog'}),
      _document([
        _rule('site-rule', [
          _label('team', 'a'),
        ], when: _leaf('labels.site', 'equals', 'eu1')),
        _rule('later', [_label('team', 'b')]),
      ]),
    );
    final first = result.trace[0];
    expect(first.ruleId, 'site-rule');
    expect(first.outcome, 'not matched');
    expect(first.conditions.single.outcome, 'no match: field missing');
    expect(first.conditions.single.field, 'labels.site');
    expect(first.actions, isEmpty);
    expect(result.trace[1].outcome, 'matched');
    expect(result.finalLabels['team'], 'b');
  });

  test('a_not_attempted_rule_has_no_entries', () async {
    final result = await _simulate(
      _event(),
      _document([
        _rule('one', [_label('a', '1')]),
        _rule('two', [_label('b', '2')]),
      ]),
      remaining: () => Duration.zero,
    );
    expect(result.trace.map((t) => t.outcome), [
      'not attempted',
      'not attempted',
    ]);
    for (final trace in result.trace) {
      expect(trace.conditions, isEmpty);
      expect(trace.actions, isEmpty);
      expect(trace.failureCode, isNull);
    }
    expect(result.finalLabels, {'alertname': 'Watchdog'});
  });

  test('conditions_are_a_flat_list_with_parent_indexes', () async {
    final result = await _simulate(
      _event(labels: {'alertname': 'Watchdog', 'site': 'eu1'}),
      _document([
        _rule(
          'tree',
          [_label('x', 'y')],
          when: {
            'any': [
              _leaf('labels.site', 'equals', 'eu1'),
              _leaf('summary', 'regex', '(a+)+b'),
            ],
          },
        ),
      ]),
      regexTest: (p, i) => fail('a skipped regex must not run'),
    );
    final nodes = result.trace.single.conditions;
    expect(nodes.map((n) => (n.parentIndex, n.kind, n.outcome)), [
      (null, 'any', 'matched'),
      (0, 'leaf', 'matched'),
      (0, 'leaf', 'not evaluated'),
    ]);
    expect(nodes[1].op, 'equals');
    expect(nodes[2].failureCode, isNull);
  });

  test('regex_leaf_times_out', () async {
    final regex = _FailingRegex();
    final result = await _simulate(
      _event(),
      _document([
        _rule(
          'slow',
          [_label('a', '1')],
          when: _leaf('summary', 'regex', '(a+)+b'),
        ),
        _rule(
          'also-regex',
          [_label('b', '2')],
          when: _leaf('summary', 'regex', 'x'),
        ),
        _rule('plain', [_label('c', '3')]),
      ]),
      regexTest: regex.call,
    );
    final slow = result.trace[0];
    expect((slow.outcome, slow.failureCode), ('failed', 'regex_timeout'));
    expect(slow.conditions.single.outcome, 'failed');
    expect(slow.conditions.single.failureCode, 'regex_timeout');
    expect(slow.actions, isEmpty);
    final later = result.trace[1];
    expect((later.outcome, later.failureCode), ('failed', 'regex_budget'));
    expect(result.trace[2].outcome, 'matched');
    expect(result.finalLabels, containsPair('c', '3'));
    expect(result.finalLabels, isNot(contains('a')));
    expect(result.finalLabels, isNot(contains('b')));
  });

  test('simulation_reaches_the_optional_cutoff', () async {
    var expired = false;
    final regex = _FailingRegex()..onFirst = () => expired = true;
    final result = await _simulate(
      _event(),
      _document([
        _rule('first', [_label('a', '1')]),
        _rule(
          'in-progress',
          [_label('b', '2')],
          when: _leaf('summary', 'regex', 'x'),
        ),
        _rule('after', [_label('c', '3')]),
        _rule('last', [_label('d', '4')]),
      ]),
      regexTest: regex.call,
      remaining: () => expired ? Duration.zero : const Duration(seconds: 1),
    );
    expect(result.trace[0].outcome, 'matched');
    final cut = result.trace[1];
    expect((cut.outcome, cut.failureCode), ('failed', 'matcher_cutoff'));
    expect(cut.actions, isEmpty);
    for (final trace in result.trace.skip(2)) {
      expect(trace.outcome, 'not attempted');
      expect(trace.conditions, isEmpty);
      expect(trace.actions, isEmpty);
    }
    expect(result.finalLabels, containsPair('a', '1'));
    expect(result.finalLabels, isNot(contains('b')));
    expect(result.finalLabels, isNot(contains('c')));
  });

  test('later_rule_wins_a_shared_key', () async {
    final result = await _simulate(
      _event(),
      _document([
        _rule('first', [_label('team', 'net')]),
        _rule('second', [_label('team', 'platform')]),
      ]),
    );
    expect(result.trace.map((t) => t.outcome), ['matched', 'matched']);
    expect(result.trace[0].actions.single.applied, isTrue);
    expect(result.trace[1].actions.single.applied, isTrue);
    expect(result.finalLabels['team'], 'platform');
    expect(result.finalLabelOrigins['team'], 'matcher');
    expect(result.finalLabelOrigins['alertname'], 'source');
  });

  test('a_failing_action_discards_only_its_rule_s_patch', () async {
    final result = await _simulate(
      _event(),
      _document([
        _rule('breaks', [
          _label('staged', 'x'),
          {
            'type': 'extract',
            'field': 'summary',
            'pattern': '(.*)',
            'group': 1,
            'key': 'long',
          },
        ]),
        _rule('works', [_label('kept', 'y')]),
      ]),
      capture: (pattern, input, group) async => 'v' * 1025,
    );
    final broken = result.trace[0];
    expect(broken.conditions.single.outcome, 'matched');
    expect(broken.outcome, 'failed');
    expect(broken.failureCode, isNotNull);
    expect(broken.failureCode, isNot('matcher_cutoff'));
    expect(broken.actions.map((a) => a.applied), [false, false]);
    expect(result.trace[1].outcome, 'matched');
    expect(result.finalLabels, containsPair('kept', 'y'));
    expect(result.finalLabels, isNot(contains('staged')));
    expect(result.finalLabels, isNot(contains('long')));
  });

  test('simulated_effect_beyond_the_fanout_bound', () async {
    final event = _event();
    final size = CloudEvent(event: event).toJsonBytes().length;
    final result = await _simulate(
      event,
      _document([
        _rule('too-big', [_label('big', 'z' * 200)]),
      ]),
      fanoutLimit: size + 10,
    );
    final trace = result.trace.single;
    expect((trace.outcome, trace.failureCode), ('failed', 'batch_bound'));
    expect(trace.conditions.single.outcome, 'matched');
    expect(trace.actions.single.applied, isFalse);
    expect(result.finalLabels, isNot(contains('big')));
    expect(result.baselineOverFanout, isFalse);
  });

  test('baseline_already_over_the_fanout_bound', () async {
    final event = _event();
    final size = CloudEvent(event: event).toJsonBytes().length;
    final result = await _simulate(
      event,
      _document([
        _rule('one', [_label('a', '1')]),
        _rule('two', [_label('b', '2')]),
      ]),
      context: SimulationContext(
        ruleSource: SimulationRuleSource.active,
        baselineRoutes: const [_routeA],
      ),
      fanoutLimit: size * 2 - 1,
    );
    expect(result.baselineOverFanout, isTrue);
    expect(result.trace.map((t) => t.outcome), [
      'not attempted',
      'not attempted',
    ]);
    expect(result.notes.join(' '), contains('baseline'));
    expect(result.finalLabels, {'alertname': 'Watchdog'});
  });

  test('no_rules_active_returns_the_event_unchanged', () async {
    final event = _event();
    final result = await _simulate(
      event,
      MatcherDocument.empty,
      context: SimulationContext(
        ruleSource: SimulationRuleSource.active,
        snapshotId: 'snap-1',
        snapshotRevision: 4,
      ),
    );
    expect(result.noRulesActive, isTrue);
    expect(result.trace, isEmpty);
    expect(result.ruleSource, 'active');
    expect((result.snapshotId, result.snapshotRevision), ('snap-1', 4));
    expect(result.finalLabels, event.labels);
    expect(result.finalSeverity, event.severity.name);
    expect(result.eventKind, event.kind.name);
    expect(result.error, isNull);
  });

  test('routes_beyond_the_baseline_are_added_and_hypothetical', () async {
    final result = await _simulate(
      _event(),
      _document([
        _rule('routes', [
          {'type': 'route', 'output_id': _routeA},
          {'type': 'route', 'output_id': _routeB},
        ]),
      ]),
      context: SimulationContext(
        ruleSource: SimulationRuleSource.active,
        baselineRoutes: const [_routeA],
      ),
    );
    expect(result.baselineRoutes, [_routeA]);
    expect(result.addedRoutes, [_routeB]);
    expect(result.routeNote, contains('delivery eligibility'));
    expect(result.sourceAbsent, isFalse);
    expect(result.trace.single.actions.map((a) => a.type), [
      'route',
      'route',
    ]);
  });

  test('an_absent_source_has_an_empty_baseline', () async {
    final result = await _simulate(
      _event(),
      _document([
        _rule('routes', [
          {'type': 'route', 'output_id': _routeA},
        ]),
      ]),
      context: SimulationContext(
        ruleSource: SimulationRuleSource.active,
        sourceAbsent: true,
      ),
    );
    expect(result.sourceAbsent, isTrue);
    expect(result.baselineRoutes, isEmpty);
    expect(result.addedRoutes, [_routeA]);
    expect(result.notes.join(' '), contains('source'));
  });

  test('actions_record_their_effect_and_the_final_event', () async {
    final result = await _simulate(
      _event(),
      _document([
        _rule('all', [
          _label('team', 'net'),
          {
            'type': 'link',
            'href': 'https://example.com/runbook',
            'relation': 'runbook',
          },
          {
            'type': 'map_severity',
            'values': {'warning': 'critical'},
          },
          {
            'type': 'extract',
            'field': 'resource.host.name',
            'pattern': 'x',
            'group': 0,
            'key': 'nohost',
          },
        ]),
      ]),
    );
    final actions = result.trace.single.actions;
    expect(actions.map((a) => a.type), [
      'label',
      'link',
      'severity',
      'extract',
    ]);
    expect(actions.map((a) => a.index), [0, 1, 2, 3]);
    expect(actions[0].effect, 'staged');
    expect(actions[3].effect, isNot('staged'));
    expect(result.finalSeverity, 'critical');
    expect(result.finalLinks.single.href, 'https://example.com/runbook');
    expect(result.finalLinks.single.relation, 'runbook');
    expect(result.finalLabels, isNot(contains('nohost')));
  });

  test('only_a_simulated_classify_sets_the_hint', () async {
    final result = await _simulate(
      _event(),
      _document([
        _rule('c', [
          {'type': 'classify', 'value': 'heartbeat'},
        ]),
      ]),
    );
    expect(result.noiseClassHint, 'heartbeat');
    expect(result.finalLabels[_key], 'heartbeat');
    expect(result.finalLabelOrigins[_key], 'matcher');
  });

  test('a_source_label_with_the_reserved_key_is_not_a_hint', () async {
    final result = await _simulate(
      _event(
        labels: {'alertname': 'Watchdog', _key: 'heartbeat'},
        origin: {_key: 'source'},
      ),
      _document([
        _rule('other', [_label('team', 'net')]),
      ]),
    );
    expect(result.noiseClassHint, isNull);
    expect(result.finalLabels[_key], 'heartbeat');
    expect(result.finalLabelOrigins[_key], 'source');
  });

  test('a_later_write_to_the_reserved_key_is_not_a_hint', () async {
    final result = await _simulate(
      _event(),
      _document([
        _rule('c', [
          {'type': 'classify', 'value': 'heartbeat'},
        ]),
        _rule('legacy', [_label(_key, 'other')]),
      ]),
    );
    expect(result.noiseClassHint, isNull);
    expect(result.finalLabels[_key], 'other');
  });

  test('stored_event_data_is_shown_apart_from_the_hint', () async {
    final stored = _event(
      labels: {'alertname': 'Watchdog', _key: 'heartbeat'},
      origin: {_key: 'matcher'},
    );
    final result = await _simulate(
      _event(),
      _document([
        _rule('other', [_label('team', 'net')]),
      ]),
      context: SimulationContext(
        ruleSource: SimulationRuleSource.draft,
        stored: StoredEventInfo(
          snapshotId: 'old-snap',
          labels: stored.labels,
          labelsOrigin: stored.labelsOrigin,
          enrichmentErrors: [
            EventEnrichmentError(
              stage: 'matcher',
              code: 'regex_budget',
              message: 'other',
            ),
          ],
        ),
      ),
    );
    expect(result.noiseClassHint, isNull);
    expect(result.storedSnapshotId, 'old-snap');
    expect(result.storedLabels, containsPair(_key, 'heartbeat'));
    expect(result.storedLabelOrigins, containsPair(_key, 'matcher'));
    expect(result.finalLabels, isNot(contains(_key)));
    final error = result.storedEnrichmentErrors!.single;
    expect(
      (error.stage, error.code, error.message),
      (
        'matcher',
        'regex_budget',
        'other',
      ),
    );
    expect(result.storedBudgetNote, contains('budgets'));
    expect(result.ruleSource, 'draft');
  });

  test('a_pasted_event_carries_no_stored_data', () async {
    final result = await _simulate(_event(), MatcherDocument.empty);
    expect(result.storedSnapshotId, isNull);
    expect(result.storedLabels, isNull);
    expect(result.storedEnrichmentErrors, isNull);
    expect(result.storedBudgetNote, isNull);
  });

  test('a_failed_simulation_carries_only_its_error', () {
    final result = simulationFailure(
      SimulationError(code: 'event_not_found'),
    );
    expect(result.error!.code, 'event_not_found');
    expect(result.trace, isEmpty);
    expect(result.noRulesActive, isFalse);
  });

  test('the_trace_model_does_not_clash_with_the_matcher_tree', () {
    expect(
      wire.ConditionTrace(kind: 'leaf', outcome: 'matched').kind,
      'leaf',
    );
  });
}
