import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/matcher/matcher_condition.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/matcher/matcher_evaluation.dart';
import 'package:correlia_server/src/matcher/matcher_regex_worker.dart';
import 'package:test/test.dart';

import '../event/fixture.dart';

CanonicalEvent _event({Map<String, String> labels = const {}}) {
  final data = eventFixture()['data']! as Map<String, Object?>;
  data['labels'] = labels;
  data.remove('labels_origin');
  return CanonicalEvent.fromJson(data);
}

Map<String, Object?> _leaf(String field, String op, String value) => {
  'field': field,
  'op': op,
  'value': value,
};

/// Records every regex call; throws [failure] when set.
final class _Regex {
  _Regex({this.failure});
  final String? failure;
  final calls = <(String, String)>[];

  Future<bool> call(String pattern, String input) async {
    calls.add((pattern, input));
    if (failure case final code?) throw MatcherRegexUnavailable(code);
    return RegExp(pattern).hasMatch(input);
  }
}

void main() {
  final slow = _leaf('summary', 'regex', '(a+)+b');

  test('a_decisive_any_skips_a_slow_regex', () async {
    final condition = MatcherCondition.parse({
      'any': [_leaf('labels.site', 'equals', 'eu1'), slow],
    });
    final event = _event(labels: {'site': 'eu1'});
    final regex = _Regex(failure: 'regex_timeout');
    expect(await condition.matches(event, regexTest: regex.call), isTrue);
    final explained = await condition.explain(event, regexTest: regex.call);
    expect(explained.matched, isTrue);
    expect(explained.failureCode, isNull);
    expect(regex.calls, isEmpty);
  });

  test('a_decisive_all_skips_a_slow_regex', () async {
    final condition = MatcherCondition.parse({
      'all': [_leaf('labels.site', 'equals', 'eu1'), slow],
    });
    final event = _event(labels: {'site': 'us1'});
    final regex = _Regex(failure: 'regex_timeout');
    expect(await condition.matches(event, regexTest: regex.call), isFalse);
    final explained = await condition.explain(event, regexTest: regex.call);
    expect(explained.matched, isFalse);
    expect(explained.failureCode, isNull);
    expect(regex.calls, isEmpty);
  });

  // The pipeline's rule runner skips the same children: no regex is armed and
  // no failure is counted.
  for (final (name, condition, labels, matched) in [
    (
      'a_decisive_any_skips_a_slow_regex_in_the_pipeline',
      {
        'any': [_leaf('labels.site', 'equals', 'eu1'), slow],
      },
      {'site': 'eu1'},
      true,
    ),
    (
      'a_decisive_all_skips_a_slow_regex_in_the_pipeline',
      {
        'all': [_leaf('labels.site', 'equals', 'eu1'), slow],
      },
      {'site': 'us1'},
      false,
    ),
  ]) {
    test(name, () async {
      final document = MatcherDocument.parse({
        'language': 'matcher',
        'version': 1,
        'rules': [
          {
            'id': 'short',
            'when': condition,
            'actions': [
              {'type': 'set_label', 'key': 'team', 'value': 'ops'},
            ],
          },
        ],
      }, const {});
      var armed = 0;
      var elapsed = Duration.zero;
      final worker = MatcherRegexWorker(
        elapsed: () => elapsed,
        // Any regex that ran would be overdue at once.
        arm: (_, _) {
          armed++;
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
      final event = _event(labels: labels);
      final result = await batch.enrich(
        event,
        CloudEvent(event: event).toJsonBytes(),
        const {},
        false,
      );
      final out = CloudEvent.decode(result.payload).event;
      expect(out.labels['team'], matched ? 'ops' : isNull);
      expect(out.pipeline.enrichmentErrors, isEmpty);
      expect(armed, 0);
      expect(batch.failures, isEmpty);
      expect(batch.unattempted, 0);
    });
  }

  test('rul_2_missing_field_is_visible', () async {
    final condition = MatcherCondition.parse(
      _leaf('labels.site', 'equals', 'eu1'),
    );
    final explained = await condition.explain(_event());
    final leaf = explained.trace as LeafTrace;
    expect(leaf.outcome, LeafOutcome.fieldMissing);
    expect(leaf.outcome.label, 'no match: field missing');
    expect(leaf.field, 'labels.site');
    expect(leaf.operator, 'equals');
    expect(explained.matched, isFalse);
    expect(await condition.matches(_event()), isFalse);
  });

  test('missing_field_under_not', () async {
    final condition = MatcherCondition.parse({
      'not': _leaf('labels.site', 'equals', 'eu1'),
    });
    final explained = await condition.explain(_event());
    final root = explained.trace as CompositeTrace;
    expect(root.kind, TraceKind.not);
    expect(
      (root.children.single as LeafTrace).outcome,
      LeafOutcome.fieldMissing,
    );
    expect(explained.matched, isTrue);
    expect(await condition.matches(_event()), isTrue);
  });

  test('short_circuited_leaves_are_not_evaluated', () async {
    final condition = MatcherCondition.parse({
      'any': [_leaf('labels.site', 'equals', 'eu1'), slow],
    });
    final regex = _Regex();
    final explained = await condition.explain(
      _event(labels: {'site': 'eu1'}),
      regexTest: regex.call,
    );
    final root = explained.trace as CompositeTrace;
    expect(root.kind, TraceKind.any);
    expect(root.result, isTrue);
    expect((root.children[0] as LeafTrace).outcome, LeafOutcome.matched);
    final skipped = root.children[1] as LeafTrace;
    expect(skipped.outcome, LeafOutcome.notEvaluated);
    expect(skipped.outcome.label, 'not evaluated');
    expect(regex.calls, isEmpty);
  });

  test(
    'a_regex_failure_is_a_failed_leaf_and_still_throws_from_matches',
    () async {
      final condition = MatcherCondition.parse({
        'all': [slow, _leaf('labels.site', 'equals', 'eu1')],
      });
      final event = _event(labels: {'site': 'eu1'});
      final regex = _Regex(failure: 'regex_budget');
      await expectLater(
        condition.matches(event, regexTest: regex.call),
        throwsA(isA<MatcherRegexUnavailable>()),
      );
      final explained = await condition.explain(event, regexTest: regex.call);
      expect(explained.matched, isNull);
      expect(explained.failureCode, 'regex_budget');
      final root = explained.trace as CompositeTrace;
      final failed = root.children[0] as LeafTrace;
      expect(failed.outcome, LeafOutcome.failed);
      expect(failed.failureCode, 'regex_budget');
      expect((root.children[1] as LeafTrace).outcome, LeafOutcome.notEvaluated);
    },
  );
}
