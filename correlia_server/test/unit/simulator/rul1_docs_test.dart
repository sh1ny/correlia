import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/simulator/rule_simulation.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../event/fixture.dart';

const _doc = '../docs/ingest-pipeline.md';
const _info = 'yaml rul1-example';
const _outputs = {'22222222-2222-4222-8222-222222222222'};

/// The fenced blocks of [_doc] whose info string is [_info], as parsed YAML.
List<Map<String, Object?>> _examples() {
  final lines = File(_doc).readAsLinesSync();
  final found = <Map<String, Object?>>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() != '```$_info') continue;
    final body = <String>[];
    for (i++; i < lines.length && lines[i].trim() != '```'; i++) {
      body.add(lines[i]);
    }
    found.add(
      jsonDecode(jsonEncode(loadYaml(body.join('\n')))) as Map<String, Object?>,
    );
  }
  return found;
}

CanonicalEvent _event(Map<String, Object?> documented) {
  final data = eventFixture()['data']! as Map<String, Object?>;
  data['labels'] = documented['labels'];
  data.remove('labels_origin');
  return CanonicalEvent.fromJson(data);
}

void main() {
  test('rul_1_documented_examples_produce_the_documented_decisions', () async {
    final examples = _examples();
    expect(
      [for (final example in examples) example['name']],
      containsAll(['priority', 'labels', 'topology']),
      reason: 'the document must carry these executable examples',
    );
    for (final example in examples) {
      final name = example['name'];
      final event = _event(example['event']! as Map<String, Object?>);
      final document = MatcherDocument.parse(example['matcher'], _outputs);
      final result = await simulateWithFreshBudgets(
        event: event,
        document: document,
        context: SimulationContext(ruleSource: SimulationRuleSource.draft),
      );
      final expected = example['expect']! as Map<String, Object?>;
      expect(result.error, isNull, reason: '$name');
      // An ordered list: a reordered trace fails as well as a wrong outcome.
      expect(
        [
          for (final rule in result.trace) {rule.ruleId: rule.outcome},
        ],
        expected['rules'],
        reason: '$name: rule outcomes in order',
      );
      expect(result.finalLabels, expected['labels'], reason: '$name: labels');
    }
  });
}
