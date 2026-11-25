import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/matcher/matcher_evaluation.dart';
import 'package:correlia_server/src/matcher/matcher_regex_worker.dart';
import 'package:test/test.dart';

import '../event/fixture.dart';

void main() {
  test('enrichment preserves identity', () async {
    final data = eventFixture()['data']! as Map<String, Object?>;
    data['resource'] = {'host.name': 'router-17'};
    final event = CanonicalEvent.fromJson(data);
    final matcher = MatcherDocument.parse({
      'language': 'matcher',
      'version': 1,
      'rules': [
        {
          'id': 'example',
          'when': {'field': 'resource.host.name', 'op': 'exists'},
          'actions': [
            {'type': 'owner', 'value': 'platform'},
            {'type': 'team', 'value': 'network'},
            {'type': 'tag', 'key': 'edge'},
            {
              'type': 'map_severity',
              'values': {'warning': 'critical'},
            },
            {
              'type': 'link',
              'href': 'https://example.com/runbook',
              'relation': 'runbook',
            },
            {
              'type': 'location',
              'field': 'resource.host.name',
              'entries': [
                {
                  'hostname': 'router-17',
                  'site': 'west',
                  'environment': 'prod',
                },
              ],
            },
            {
              'type': 'extract',
              'field': 'resource.host.name',
              'pattern': 'router-([0-9]+)',
              'group': 1,
              'key': 'router',
            },
          ],
        },
      ],
    }, const {});
    final enriched = await applyMatcherRule(
      matcher.rules.single,
      original: event,
      current: event,
      capture: (pattern, input, group) async => RegExp(
        pattern,
        unicode: true,
        dotAll: true,
      ).firstMatch(input)?.group(group),
    );
    final changed = enriched!.event;
    expect(changed.eventId, event.eventId);
    expect(changed.fingerprint, event.fingerprint);
    expect(changed.observationKey.bytes, event.observationKey.bytes);
    expect(changed.severity, EventSeverity.critical);
    expect(changed.labels, containsPair('owner', 'platform'));
    expect(changed.labels, containsPair('team', 'network'));
    expect(changed.labels, containsPair('tags.edge', 'true'));
    expect(changed.labels, containsPair('site', 'west'));
    expect(changed.labels, containsPair('environment', 'prod'));
    expect(changed.labels, containsPair('router', '17'));
    expect(changed.links.single.relation, 'runbook');
  });

  test('fanout skips only over-budget patch', () async {
    const sourceRoute = '22222222-2222-4222-8222-222222222222';
    const extraRoute = '33333333-3333-4333-8333-333333333333';
    final event = _event();
    final worker = _worker();
    addTearDown(worker.close);
    final batch = _batch(
      worker,
      [
        _rule('over', [
          {'type': 'owner', 'value': 'must-not-leak'},
          {'type': 'route', 'output_id': extraRoute},
        ]),
        _rule('fits', [
          {'type': 'team', 'value': 'net'},
          {'type': 'route', 'output_id': sourceRoute},
        ]),
      ],
      budget: 1024,
      outputs: {sourceRoute, extraRoute},
    );
    final baseline = CloudEvent(event: event).toJsonBytes();
    final result = await batch.enrich(event, baseline, {sourceRoute}, true);
    final finalEvent = CloudEvent.decode(result.payload).event;
    expect(finalEvent.labels['owner'], isNull);
    expect(finalEvent.labels['team'], 'net');
    expect(result.routes, isEmpty);
    expect(batch.failures, {'over': 1});
  });

  test('late action cannot leak patch', () async {
    const routed = '33333333-3333-4333-8333-333333333333';
    final event = _event(description: 'x' * 2048);
    final worker = _worker();
    addTearDown(worker.close);
    final batch = _batch(
      worker,
      [
        _rule('invalid', [
          {'type': 'owner', 'value': 'must-not-leak'},
          {'type': 'route', 'output_id': routed},
          {
            'type': 'extract',
            'field': 'description',
            'pattern': '.+',
            'group': 0,
            'key': 'extracted',
          },
        ]),
        _rule('later', [
          {'type': 'team', 'value': 'net'},
        ]),
      ],
      budget: 8 * 1024,
      outputs: {routed},
    );
    final result = await batch.enrich(
      event,
      CloudEvent(event: event).toJsonBytes(),
      const {},
      true,
    );
    final finalEvent = CloudEvent.decode(result.payload).event;
    expect(finalEvent.labels['owner'], isNull);
    expect(finalEvent.labels['extracted'], isNull);
    expect(finalEvent.labels['team'], 'net');
    expect(result.routes, isEmpty);
    expect(finalEvent.pipeline.enrichmentErrors.single.message, 'invalid');
    expect(batch.failures, {'invalid': 1});
  });

  test('non-regex rule crossing shared cutoff discards whole patch', () async {
    final event = _event();
    final worker = _worker();
    addTearDown(worker.close);
    var remaining = const Duration(seconds: 1);
    final batch = _batch(
      worker,
      [
        _rule('crosses', [
          {'type': 'owner', 'value': 'must-not-leak'},
        ]),
        _rule('unattempted', [
          {'type': 'team', 'value': 'must-not-start'},
        ]),
      ],
      budget: 1024,
      remaining: () => remaining,
    );
    final baseline = CloudEvent(event: event).toJsonBytes();
    final running = batch.enrich(event, baseline, const {}, false);
    remaining = Duration.zero;
    final result = await running;
    expect(result.payload, baseline);
    expect(batch.failures, {'crosses': 1});
    expect(batch.unattempted, 1);
  });

  test('near-cap event still commits and counts', () async {
    final event = _event();
    final worker = _worker();
    addTearDown(worker.close);
    final data = event.toJson();
    final pipeline = data['pipeline']! as Map<String, Object?>;
    pipeline['enrichment_errors'] = [
      for (var i = 0; i < 32; i++)
        {'stage': 'test', 'code': 'existing', 'message': '$i'},
    ];
    final saturated = CanonicalEvent.fromJson(data);
    final batch = _batch(
      worker,
      [
        _rule('too_large', [
          {
            'type': 'route',
            'output_id': '33333333-3333-4333-8333-333333333333',
          },
        ]),
      ],
      budget: 2048,
      outputs: {'33333333-3333-4333-8333-333333333333'},
    );
    final baseline = CloudEvent(event: saturated).toJsonBytes();
    final result = await batch.enrich(saturated, baseline, const {}, true);
    expect(result.payload, baseline);
    expect(batch.failures, {'too_large': 1});
  });
}

CanonicalEvent _event({String? description}) {
  final data = eventFixture()['data']! as Map<String, Object?>;
  if (description != null) data['description'] = description;
  return CanonicalEvent.fromJson(data);
}

MatcherRegexWorker _worker() =>
    MatcherRegexWorker(arm: (_, _) => () {}, elapsed: () => Duration.zero);

Map<String, Object?> _rule(String id, List<Map<String, Object?>> actions) => {
  'id': id,
  'when': {'field': 'summary', 'op': 'exists'},
  'actions': actions,
};

MatcherBatch _batch(
  MatcherRegexWorker worker,
  List<Map<String, Object?>> rules, {
  required int budget,
  Set<String> outputs = const {},
  Duration Function()? remaining,
}) {
  final clock = remaining ?? () => const Duration(seconds: 1);
  return MatcherBatch(
    MatcherDocument.parse({
      'language': 'matcher',
      'version': 1,
      'rules': rules,
    }, outputs),
    worker.newRow(clock),
    clock,
    availableBytes: budget,
  );
}
