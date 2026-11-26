import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/matcher/matcher_evaluation.dart';
import 'package:correlia_server/src/matcher/matcher_regex_worker.dart';
import 'package:test/test.dart';

import '../event/fixture.dart';

const _key = 'correlia.noise_class';
const _vocabulary = [
  'heartbeat',
  'informational',
  'test',
  'flapping',
  'maintenance',
];

CanonicalEvent _event({
  Map<String, String> labels = const {'alertname': 'Watchdog'},
  Map<String, String> origin = const {},
}) {
  final data = eventFixture()['data']! as Map<String, Object?>;
  data['labels'] = labels;
  if (origin.isNotEmpty) data['labels_origin'] = origin;
  return CanonicalEvent.fromJson(data);
}

Map<String, Object?> _document(List<Map<String, Object?>> rules) => {
  'language': 'matcher',
  'version': 1,
  'rules': rules,
};

Map<String, Object?> _rule(String id, List<Map<String, Object?>> actions) => {
  'id': id,
  'when': {'field': 'labels.alertname', 'op': 'equals', 'value': 'Watchdog'},
  'actions': actions,
};

Map<String, Object?> _classify(Object? value) => {
  'type': 'classify',
  'value': ?value,
};

MatcherDocumentError _rejected(Map<String, Object?> document) {
  try {
    MatcherDocument.parse(document, const {});
  } on MatcherDocumentError catch (error) {
    return error;
  }
  fail('the document was accepted');
}

MatcherCapture _capture = (pattern, input, group) async => RegExp(
  pattern,
  unicode: true,
  dotAll: true,
).firstMatch(input)?.group(group);

Future<CanonicalEvent> _apply(
  CanonicalEvent event,
  Map<String, Object?> document,
) async {
  var current = event;
  for (final rule in MatcherDocument.parse(document, const {}).rules) {
    final patch = await applyMatcherRule(
      rule,
      original: event,
      current: current,
      capture: _capture,
    );
    if (patch != null) current = patch.event;
  }
  return current;
}

void main() {
  test('classify_a_watchdog_alert', () async {
    final event = _event();
    final enriched = await _apply(
      event,
      _document([
        _rule('watchdog', [_classify('heartbeat')]),
      ]),
    );
    expect(enriched.labels, containsPair(_key, 'heartbeat'));
    expect(enriched.labelsOrigin, containsPair(_key, 'matcher'));
    expect(enriched.kind, EventKind.alert);
    expect(enriched.status, event.status);
    expect(enriched.severity, event.severity);
    expect(enriched.fingerprint, event.fingerprint);
    expect(enriched.eventId, event.eventId);
    expect(enriched.observationKey.bytes, event.observationKey.bytes);
  });

  test('later_classify_wins', () async {
    final enriched = await _apply(
      _event(),
      _document([
        _rule('first', [_classify('test')]),
        _rule('second', [_classify('informational')]),
      ]),
    );
    expect(enriched.labels, containsPair(_key, 'informational'));
    expect(enriched.labelsOrigin, containsPair(_key, 'matcher'));
  });

  test('value_outside_the_vocabulary', () {
    for (final value in ['Heartbeat', 'critical', '', ' heartbeat']) {
      final error = _rejected(
        _document([
          _rule('rule', [_classify(value)]),
        ]),
      );
      expect(error.field, 'matcher.rules[0].actions[0].value', reason: value);
      for (final allowed in _vocabulary) {
        expect(error.code, contains(allowed), reason: value);
      }
    }
    // A non-string value fails the same way.
    for (final value in [1, true, null, <Object?>[]]) {
      final error = _rejected(
        _document([
          _rule('rule', [
            {'type': 'classify', 'value': value},
          ]),
        ]),
      );
      expect(error.field, 'matcher.rules[0].actions[0].value');
    }
    for (final value in _vocabulary) {
      MatcherDocument.parse(
        _document([
          _rule('rule', [_classify(value)]),
        ]),
        const {},
      );
    }
  });

  test('source_label_with_the_reserved_key', () async {
    final event = _event(
      labels: {'alertname': 'Watchdog', _key: 'heartbeat'},
      origin: {_key: 'source'},
    );
    // A rule that does not classify leaves the source label and identity alone.
    final enriched = await _apply(
      event,
      _document([
        _rule('other', [
          {'type': 'owner', 'value': 'platform'},
        ]),
      ]),
    );
    expect(enriched.labels, containsPair(_key, 'heartbeat'));
    expect(enriched.labelsOrigin, containsPair(_key, 'source'));
    expect(enriched.kind, event.kind);
    expect(enriched.fingerprint, event.fingerprint);
    expect(enriched.eventId, event.eventId);
  });

  test('existing_documents_stay_valid', () async {
    final preChange = _document([
      _rule('legacy', [
        {'type': 'set_label', 'key': 'team.tier', 'value': 'gold'},
        {'type': 'owner', 'value': 'platform'},
      ]),
    ]);
    final document = MatcherDocument.parse(preChange, const {});
    expect(document.snapshotJson['language'], 'matcher');
    expect(document.snapshotJson['version'], 1);
    expect(document.writesReservedKey, isNull);
    final reloaded = MatcherDocument.fromSnapshot(
      document.snapshotJson,
      const {},
    );
    expect(reloaded.snapshotJson, document.snapshotJson);
    final enriched = await _apply(_event(), preChange);
    expect(enriched.labels, containsPair('team.tier', 'gold'));
    expect(enriched.labels, containsPair('owner', 'platform'));
    expect(enriched.labels, isNot(contains(_key)));
    // A pre-change document that writes the key still parses, flagged.
    final writer = _document([
      _rule('legacy', [
        {'type': 'set_label', 'key': _key, 'value': 'anything'},
      ]),
    ]);
    final flagged = MatcherDocument.parse(writer, const {});
    expect(flagged.writesReservedKey, 'matcher.rules[0].actions[0].key');
    final applied = await _apply(_event(), writer);
    expect(applied.labels, containsPair(_key, 'anything'));
    expect(applied.labelsOrigin, containsPair(_key, 'matcher'));
    expect(
      MatcherDocument.fromSnapshot(flagged.snapshotJson, const {}).rules,
      hasLength(1),
    );
  });

  test('new_actions_in_one_rule', () async {
    final event = _event();
    final enriched = await _apply(
      event,
      _document([
        _rule('all', [
          {'type': 'set_label', 'key': 'tier', 'value': 'gold'},
          {
            'type': 'link',
            'href': 'https://example.com/runbook',
            'relation': 'runbook',
          },
          _classify('heartbeat'),
        ]),
      ]),
    );
    expect(enriched.labels, containsPair('tier', 'gold'));
    expect(enriched.labels, containsPair(_key, 'heartbeat'));
    expect(enriched.labelsOrigin, containsPair('tier', 'matcher'));
    expect(enriched.labelsOrigin, containsPair(_key, 'matcher'));
    expect(enriched.links.single.relation, 'runbook');
  });

  test('a_failing_action_discards_the_hint', () async {
    final data = eventFixture()['data']! as Map<String, Object?>;
    // The capture would fit as a label, so only the regex timeout can make
    // the extract action fail.
    data['description'] = 'x' * 16;
    data['labels'] = {'alertname': 'Watchdog'};
    final event = CanonicalEvent.fromJson(data);
    final document = MatcherDocument.parse(
      _document([
        _rule('failing', [
          _classify('heartbeat'),
          {
            'type': 'extract',
            'field': 'description',
            'pattern': '.+',
            'group': 0,
            'key': 'extracted',
          },
        ]),
      ]),
      const {},
    );
    var elapsed = Duration.zero;
    final worker = MatcherRegexWorker(
      elapsed: () => elapsed,
      // Every regex deadline is already overdue when it is checked.
      arm: (_, _) {
        elapsed = const Duration(minutes: 1);
        return () {};
      },
    );
    addTearDown(worker.close);
    const clock = Duration(seconds: 1);
    final batch = MatcherBatch(
      document,
      worker.newRow(() => clock),
      () => clock,
      availableBytes: 8 * 1024,
    );
    final result = await batch.enrich(
      event,
      CloudEvent(event: event).toJsonBytes(),
      const {},
      false,
    );
    final out = CloudEvent.decode(result.payload).event;
    expect(out.labels, isNot(contains(_key)));
    expect(out.labels, isNot(contains('extracted')));
    expect(out.labelsOrigin, isNot(contains(_key)));
    expect(batch.failures, {'failing': 1});
    final error = out.pipeline.enrichmentErrors.single;
    expect(
      (error.stage, error.code, error.message),
      (
        'matcher',
        'regex_timeout',
        'failing',
      ),
    );
  });

  test('malformed_classify_action', () {
    final missing = _rejected(
      _document([
        _rule('rule', [
          {'type': 'classify'},
        ]),
      ]),
    );
    expect(missing.field, 'matcher.rules[0].actions[0].value');
    for (final code in _vocabulary) {
      expect(missing.code, contains(code));
    }
    final extra = _rejected(
      _document([
        _rule('rule', [
          {'type': 'classify', 'value': 'test', 'key': 'x'},
        ]),
      ]),
    );
    expect(extra.field, 'matcher.rules[0].actions[0]');
    expect(extra.code, 'shape');
    final outside = _rejected(
      _document([
        _rule('rule', [_classify('urgent')]),
      ]),
    );
    expect(outside.field, 'matcher.rules[0].actions[0].value');
  });
}
