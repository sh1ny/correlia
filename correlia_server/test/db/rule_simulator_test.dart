@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/generated/protocol.dart'
    show RuleSimulationResult;
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/matcher/matcher_regex_worker.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/simulator/rule_simulation.dart';
import 'package:correlia_server/src/simulator/rule_simulator.dart';
import 'package:correlia_server/src/simulator/simulation_input.dart';
import 'package:correlia_server/src/simulator/stored_event_lookup.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/event/fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;
import 'pipeline_test.dart' as support;

const _source = fixture.sourceId;
const _outA = fixture.outputId;
const _outB = '33333333-3333-4333-8333-333333333333';
const _outUnknown = '44444444-4444-4444-8444-444444444444';
const _key = 'correlia.noise_class';
const _startsAt = '2026-11-10T12:00:00Z';

final _t0 = support.now;

Map<String, Object?> _matcher(List<Map<String, Object?>> rules) => {
  'language': 'matcher',
  'version': 1,
  'rules': rules,
};

Map<String, Object?> _rule(
  String id,
  Map<String, Object?> when,
  List<Map<String, Object?>> actions,
) => {'id': id, 'when': when, 'actions': actions};

const _anySummary = {'field': 'summary', 'op': 'exists'};

Map<String, Object?> _label(String key, String value) => {
  'type': 'set_label',
  'key': key,
  'value': value,
};

Map<String, Object?> _route(String output) => {
  'type': 'route',
  'output_id': output,
};

Map<String, Object?> _description(String value) => {
  'field': 'description',
  'op': 'equals',
  'value': value,
};

Map<String, Object?> _alert({
  String name = 'Example',
  String? description,
  String startsAt = _startsAt,
  Map<String, String> labels = const {},
}) => payload.alert(
  labels: {'alertname': name, ...labels},
  annotations: {
    'summary': 'Example alert',
    'description': ?description,
  },
  startsAt: startsAt,
);

IngestConfigRepository _repository(Session session) =>
    IngestConfigRepository(session, secretStore: testSecretStore);

/// Publishes the next revision over the active snapshot.
Future<IngestBootstrap> _publish(
  Session session, {
  Object? matcher,
  List<String> routes = const [_outA],
  bool source = true,
  List<String> excluded = const [],
}) async {
  final repository = _repository(session);
  final active = await repository.activeSnapshot();
  return repository.publishConfig(
    {
      'format_version': 2,
      'revision': ((active?['revision'] as int?) ?? 0) + 1,
      'expected_active_snapshot': active?['snapshotId'],
      'sources': [
        if (source)
          {
            'id': _source,
            'kind': 'alertmanager',
            'enabled': true,
            'credentials': [
              {'type': 'bearer', 'ref': 'token'},
            ],
            'output_ids': routes,
            if (excluded.isNotEmpty) 'excluded_identity_labels': excluded,
          },
      ],
      'outputs': [
        for (final id in [_outA, _outB])
          {
            'id': id,
            'kind': 'webhook',
            'url': 'http://127.0.0.1:9099/events',
            'signing_key_ref': 'key',
          },
      ],
      'matcher': ?matcher,
    },
    {'token': fixture.token(1), 'key': fixture.token(2)},
    runMode: 'test',
  );
}

PipelineRepository _worker(
  Session session, {
  DateTime? at,
  Duration elapsed = Duration.zero,
  MatcherRegexWorker? regex,
}) => PipelineRepository(
  session,
  clock: () => at ?? _t0,
  elapsedForTest: () => elapsed,
  regexWorker: regex,
);

/// Seeds one raw row of [alerts] and processes it under the active snapshot.
Future<void> _process(
  Session session,
  List<Object?> alerts, {
  DateTime? at,
  Duration elapsed = Duration.zero,
  MatcherRegexWorker? regex,
}) async {
  await support.seed(session, alerts, observed: at);
  final worker = _worker(session, at: at, elapsed: elapsed, regex: regex);
  expect(await worker.pinOne(), isTrue);
  expect(await worker.processOne(), isTrue);
}

Uint8List _bytes(Object? value) => switch (value) {
  Uint8List bytes => bytes,
  ByteData data => data.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  ),
  _ => throw StateError('Unexpected byte representation'),
};

typedef _Stored = ({
  String id,
  DateTime observed,
  String disposition,
  String snapshot,
  String raw,
  CanonicalEvent event,
});

Future<List<_Stored>> _stored(Session session) async => [
  for (final row in await session.db.unsafeQuery(
    '''
SELECT event_id::text, observed_at, disposition, config_snapshot_id,
  raw_id::text, payload FROM events ORDER BY observed_at, event_id, disposition''',
  ))
    (
      id: row[0]! as String,
      observed: (row[1]! as DateTime).toUtc(),
      disposition: row[2]! as String,
      snapshot: row[3]! as String,
      raw: row[4]! as String,
      event: CloudEvent.decode(_bytes(row[5])).event,
    ),
];

Future<RuleSimulationResult> _simulateStored(
  Session session,
  _Stored stored, {
  Object? draft,
  String? disposition,
  RuleSimulator? simulator,
}) => (simulator ?? RuleSimulator()).simulate(
  session,
  eventId: stored.id,
  observedAt: stored.observed.toIso8601String(),
  disposition: disposition,
  draftMatcher: draft == null ? null : jsonEncode(draft),
);

List<String> _outcomes(RuleSimulationResult result) => [
  for (final rule in result.trace) rule.outcome,
];

Future<int> _count(Session session, String table) async =>
    (await session.db.unsafeQuery('SELECT count(*) FROM $table')).single[0]!
        as int;

void _stall(SendPort owner) {
  final inbox = ReceivePort();
  owner.send(inbox.sendPort);
  inbox.listen((_) {});
}

/// A regex worker whose first regex call overruns its budget, as if the
/// pattern had run past the row's allowance.
MatcherRegexWorker _overrunningWorker() {
  var armed = 0;
  return MatcherRegexWorker(
    entryPoint: _stall,
    elapsed: () => Duration.zero,
    arm: (_, fire) {
      if (++armed == 2) scheduleMicrotask(fire);
      return () {};
    },
  );
}

/// Rewrites the stored matcher of [snapshotId], as if the previous binary had
/// published [section] under that snapshot.
Future<void> _rewriteStoredMatcher(
  Session session,
  String snapshotId,
  Object? section,
) async {
  final rows = await session.db.unsafeQuery(
    'SELECT "publicJson" FROM ingest_config_snapshot WHERE "snapshotId"=@id',
    parameters: QueryParameters.named({'id': snapshotId}),
  );
  final document =
      jsonDecode(rows.single[0]! as String) as Map<String, Object?>;
  document['matcher'] = MatcherDocument.parse(section, const {}).snapshotJson;
  await session.db.unsafeExecute(
    'UPDATE ingest_config_snapshot SET "publicJson"=@json WHERE "snapshotId"=@id',
    parameters: QueryParameters.named({
      'id': snapshotId,
      'json': jsonEncode(document),
    }),
  );
}

Map<String, Object?> _writeReserved(String value) => _label(_key, value);

String _pasted([void Function(Map<String, Object?> data)? edit]) {
  final envelope = eventFixture();
  edit?.call(envelope['data']! as Map<String, Object?>);
  return jsonEncode(envelope);
}

void main() {
  withServerpod(
    'Rule simulator over stored events',
    (builder, _) {
      late Session session;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
      });

      test('simulate_a_pasted_event_against_the_active_rules', () async {
        final snapshot = await _publish(
          session,
          matcher: _matcher([
            _rule('first', _anySummary, [_label('a', '1')]),
            _rule(
              'second',
              {'field': 'labels.team', 'op': 'exists'},
              [_label('b', '2')],
            ),
          ]),
        );
        final result = await RuleSimulator().simulate(
          session,
          eventJson: _pasted(),
        );
        expect(result.error, isNull);
        expect(result.ruleSource, 'active');
        expect(result.snapshotId, snapshot.snapshotId);
        expect(result.snapshotRevision, 1);
        expect(
          [for (final rule in result.trace) rule.ruleId],
          [
            'first',
            'second',
          ],
        );
        expect(_outcomes(result), ['matched', 'not matched']);
        expect(result.finalLabels, containsPair('a', '1'));
        expect(result.finalLabels, isNot(contains('b')));
        expect(result.baselineRoutes, [_outA]);
        expect(result.storedSnapshotId, isNull);
        expect(result.storedLabels, isNull);
      });

      test('simulate_a_stored_event_against_a_draft', () async {
        final active = await _publish(
          session,
          matcher: _matcher([
            _rule('old', _anySummary, [_label('active', '1')]),
          ]),
        );
        await _process(session, [_alert()]);
        final stored = (await _stored(session)).single;
        final result = await _simulateStored(
          session,
          stored,
          draft: _matcher([
            _rule('draft-rule', _anySummary, [
              _label('draft', 'yes'),
              _route(_outB),
            ]),
          ]),
        );
        expect(result.error, isNull);
        expect(result.ruleSource, 'draft');
        expect([for (final rule in result.trace) rule.ruleId], ['draft-rule']);
        expect(result.finalLabels, containsPair('draft', 'yes'));
        expect(result.finalLabels, isNot(contains('active')));
        expect(result.addedRoutes, [_outB]);
        expect(result.baselineRoutes, [_outA]);
        expect(result.snapshotId, active.snapshotId);
        expect(result.storedSnapshotId, stored.snapshot);
        expect(result.storedLabels, containsPair('active', '1'));
        expect(result.storedLabelOrigins, containsPair('active', 'matcher'));
      });

      test('future_dated_row_and_its_later_ready_row', () async {
        final future = _alert(startsAt: '2026-11-12T12:00:00Z');
        final first = await _publish(
          session,
          matcher: _matcher([
            _rule('phase', _anySummary, [_label('phase', 'one')]),
          ]),
        );
        await _process(session, [future]);
        final second = await _publish(
          session,
          matcher: _matcher([
            _rule('phase', _anySummary, [_label('phase', 'two')]),
          ]),
        );
        await _process(session, [future], at: DateTime.utc(2026, 11, 12));
        final rows = await _stored(session);
        expect(
          [for (final row in rows) row.disposition],
          [
            'future_dated',
            'ready',
          ],
        );
        expect(rows[0].observed, isNot(rows[1].observed));
        expect(rows[0].id, rows[1].id);

        final one = await _simulateStored(session, rows[0]);
        final two = await _simulateStored(session, rows[1]);
        expect(one.error, isNull);
        expect(two.error, isNull);
        expect(one.storedSnapshotId, first.snapshotId);
        expect(two.storedSnapshotId, second.snapshotId);
        expect(one.storedLabels, containsPair('phase', 'one'));
        expect(two.storedLabels, containsPair('phase', 'two'));
        final named = await _simulateStored(
          session,
          rows[0],
          disposition: 'future_dated',
        );
        expect(named.storedSnapshotId, first.snapshotId);
        final wrong = await _simulateStored(
          session,
          rows[0],
          disposition: 'ready',
        );
        expect(wrong.error?.code, 'event_not_found');
      });

      test('several_rows_at_one_key', () async {
        await _publish(
          session,
          matcher: _matcher([
            _rule('phase', _anySummary, [_label('phase', 'one')]),
          ]),
        );
        await _process(session, [_alert()]);
        final ready = (await _stored(session)).single;
        // A second disposition at the same key, told apart by its labels.
        final copy = ready.event.toJson();
        copy['labels'] = {...ready.event.labels, 'copy': 'future'};
        final copyBytes = CloudEvent(
          event: CanonicalEvent.fromJson(copy),
        ).toJsonBytes();
        await session.db.unsafeExecute(
          '''INSERT INTO events (observed_at,event_id,disposition,raw_observed_at,raw_id,source_id,config_snapshot_id,source_time,payload,state_outcome,effective_source_time)
SELECT observed_at,event_id,'future_dated',raw_observed_at,raw_id,source_id,config_snapshot_id,source_time,@payload,state_outcome,effective_source_time FROM events''',
          parameters: QueryParameters.named({'payload': copyBytes}),
        );
        expect(await _stored(session), hasLength(2));
        final byDefault = await _simulateStored(session, ready);
        expect(byDefault.storedLabels, isNot(contains('copy')));
        final future = await _simulateStored(
          session,
          ready,
          disposition: 'future_dated',
        );
        expect(future.storedLabels, containsPair('copy', 'future'));
        final named = await _simulateStored(
          session,
          ready,
          disposition: 'ready',
        );
        expect(named.storedLabels, isNot(contains('copy')));
        expect(named.error, isNull);
      });

      test('same_identity_alerts_in_one_raw_batch', () async {
        await _publish(
          session,
          matcher: _matcher([
            _rule('only-b', _description('desc-b'), [_label('hit', 'yes')]),
          ]),
        );
        Map<String, Object?> member(String text, String startsAt) =>
            _alert(name: 'Twin', description: text, startsAt: startsAt);
        const aFirst = '2026-11-10T11:00:00Z';
        const bFirst = '2026-11-10T11:30:00Z';
        await _process(session, [
          member('desc-a', aFirst),
          member('desc-b', aFirst),
        ]);
        await _process(session, [
          member('desc-b', bFirst),
          member('desc-a', bFirst),
        ]);
        final rows = await _stored(session);
        expect(rows, hasLength(2));
        for (final row in rows) {
          final result = await _simulateStored(session, row);
          expect(result.error, isNull);
          final kept = row.event.description;
          // The simulated decision equals the stored event's.
          expect(_outcomes(result), [
            kept == 'desc-b' ? 'matched' : 'not matched',
          ]);
          expect(
            result.finalLabels.containsKey('hit'),
            row.event.labels.containsKey('hit'),
          );
        }
        expect(
          {for (final row in rows) row.event.description},
          {
            'desc-a',
            'desc-b',
          },
        );
      });

      test('stored_duplicate_from_before_this_change', () async {
        // The old unstable sort kept the second member of this raw row.
        await _publish(session);
        Map<String, Object?> member(String text) =>
            _alert(name: 'Twin', description: text);
        await _process(session, [member('desc-b'), member('desc-a')]);
        final stored = (await _stored(session)).single;
        expect(stored.event.description, 'desc-b');
        final body = utf8.encode(
          jsonEncode(
            payload.groupOf([member('desc-a'), member('desc-b')]),
          ),
        );
        await session.db.unsafeExecute(
          'UPDATE raw_inbox SET body=@body WHERE raw_id=CAST(@raw AS uuid)',
          parameters: QueryParameters.named({
            'body': Uint8List.fromList(body),
            'raw': stored.raw,
          }),
        );
        final result = await _simulateStored(
          session,
          stored,
          draft: _matcher([
            _rule('is-a', _description('desc-a'), [_label('which', 'a')]),
            _rule('is-b', _description('desc-b'), [_label('which', 'b')]),
          ]),
        );
        expect(result.error, isNull);
        expect(_outcomes(result), ['not matched', 'matched']);
        expect(result.finalLabels, containsPair('which', 'b'));
      });

      test('unknown_stored_event', () async {
        await _publish(session);
        final result = await RuleSimulator().simulate(
          session,
          eventId: '86fe3b73-ec2d-5dd3-b104-11f2ec79469c',
          observedAt: '2026-11-10T12:00:00Z',
        );
        expect(result.error?.code, 'event_not_found');
        expect(result.trace, isEmpty);
      });

      test('re_decode_keeps_the_stored_processing_time', () async {
        // The wire size bound counts the timestamp's text, so the re-decoded
        // member must carry the time the pipeline stored, not the clock's.
        await _publish(session);
        await _process(session, [_alert()]);
        final stored = (await _stored(session)).single;
        final found = await session.db.transaction(
          (tx) => lookupStoredEvent(
            session,
            tx,
            StoredEventRequest(
              eventId: stored.id,
              observedAt: stored.observed,
            ),
          ),
        );
        switch (found) {
          case FoundStoredEvent(:final member):
            expect(member.processedAt, stored.event.processedAt);
          case StoredEventLookupFailure(:final error):
            fail('lookup failed: ${error.code}');
        }
      });

      test('raw_row_no_longer_retained', () async {
        await _publish(session);
        await _process(session, [_alert()]);
        final stored = (await _stored(session)).single;
        await session.db.unsafeExecute('DELETE FROM raw_inbox');
        final result = await _simulateStored(session, stored);
        expect(result.error?.code, 'raw_unavailable');
        expect(result.trace, isEmpty);
      });

      test('processing_snapshot_no_longer_stored', () async {
        await _publish(session);
        await _process(session, [_alert()]);
        final stored = (await _stored(session)).single;
        await session.db.unsafeExecute(
          "UPDATE events SET config_snapshot_id='00000000-0000-4000-8000-000000000000'",
        );
        final result = await _simulateStored(session, stored);
        expect(result.error?.code, 'raw_unavailable');
        expect(result.trace, isEmpty);
      });

      test('pinned_decode_settings_that_no_longer_parse', () async {
        await _publish(session);
        await _process(session, [_alert()]);
        final stored = (await _stored(session)).single;
        // The pin now names a generic mapping in a format this binary cannot
        // read, so the row's decode settings cannot be built.
        final pin = (await session.db.unsafeQuery(
          'SELECT config_snapshot_id FROM events',
        )).single[0]!;
        final json =
            (await session.db.unsafeQuery(
                  'SELECT "publicJson" FROM ingest_config_snapshot '
                  'WHERE "snapshotId"=@pin',
                  parameters: QueryParameters.named({'pin': pin}),
                )).single[0]!
                as String;
        final snapshot = jsonDecode(json) as Map<String, Object?>;
        final source =
            (snapshot['sources']! as List<Object?>).single!
                as Map<String, Object?>;
        source
          ..['kind'] = 'generic'
          ..['mapping'] = 'future';
        snapshot['mappings'] = [
          {'name': 'future', 'mapping_format': 2},
        ];
        await session.db.unsafeExecute(
          'UPDATE ingest_config_snapshot SET "publicJson"=@json '
          'WHERE "snapshotId"=@pin',
          parameters: QueryParameters.named({
            'json': jsonEncode(snapshot),
            'pin': pin,
          }),
        );
        final result = await _simulateStored(session, stored);
        expect(result.error?.code, 'raw_unavailable');
        expect(result.trace, isEmpty);
      });

      test('invalid_draft', () async {
        await _publish(session);
        final base = _rule('r', _anySummary, [_label('a', '1')]);
        final drafts = <String, Object?>{
          'unknown field': _matcher([
            {...base, 'bogus': 1},
          ]),
          'unsupported language': {
            ..._matcher([base]),
            'language': 'other',
          },
          'unsupported version': {
            ..._matcher([base]),
            'version': 2,
          },
          'unknown output': _matcher([
            _rule('r', _anySummary, [_route(_outUnknown)]),
          ]),
        };
        for (final MapEntry(:key, :value) in drafts.entries) {
          Object? expected;
          try {
            MatcherDocument.parse(value, {_outA, _outB});
          } on MatcherDocumentError catch (error) {
            expected = (error.code, error.field, error.missingOutputId);
          }
          expect(expected, isNotNull, reason: key);
          final result = await RuleSimulator().simulate(
            session,
            eventJson: _pasted(),
            draftMatcher: jsonEncode(value),
          );
          expect(
            (
              result.error?.code,
              result.error?.field,
              result.error?.missingOutputId,
            ),
            expected,
            reason: key,
          );
          expect(result.trace, isEmpty, reason: key);
          expect(result.ruleSource, 'draft', reason: key);
        }
        final unknown = await RuleSimulator().simulate(
          session,
          eventJson: _pasted(),
          draftMatcher: jsonEncode(drafts['unknown output']),
        );
        expect(unknown.error?.missingOutputId, _outUnknown);
        final reserved = await RuleSimulator().simulate(
          session,
          eventJson: _pasted(),
          draftMatcher: jsonEncode(
            _matcher([
              _rule('r', _anySummary, [_writeReserved('heartbeat')]),
            ]),
          ),
        );
        expect(reserved.error?.code, reservedKeyCode);
        expect(reserved.error?.field, 'matcher.rules[0].actions[0].key');
        expect(reserved.trace, isEmpty);
        final notJson = await RuleSimulator().simulate(
          session,
          eventJson: _pasted(),
          draftMatcher: 'not json',
        );
        expect(notJson.error?.code, 'invalid_json');
        expect(notJson.error?.field, 'draftMatcher');
        final big = await RuleSimulator().simulate(
          session,
          eventJson: _pasted(),
          draftMatcher: ' ' * (64 * 1024 + 1),
        );
        expect(big.error?.code, 'too_large');
        expect(big.error?.field, 'draftMatcher');
      });

      test('a_draft_equal_to_earlier_content_is_still_new', () async {
        final benign = _matcher([
          _rule('example', _anySummary, [_label('team', 'ops')]),
        ]);
        final old = await _publish(session, matcher: benign);
        // The previous binary stored content that writes the reserved key.
        final legacy = _matcher([
          _rule('example', _anySummary, [_writeReserved('legacy')]),
        ]);
        await _rewriteStoredMatcher(session, old.snapshotId, legacy);
        await session.db.unsafeSimpleExecute(
          '''DROP TABLE matcher_content_digest;
DROP TABLE matcher_content_digest_fill;
DELETE FROM correlia_schema_versions WHERE version IN (15, 16)''',
        );
        await initializeIngestSchema(session);
        await _publish(
          session,
          matcher: _matcher([
            _rule('other', _anySummary, [_label('other', '1')]),
          ]),
        );
        final result = await RuleSimulator().simulate(
          session,
          eventJson: _pasted(),
          draftMatcher: jsonEncode(legacy),
        );
        expect(result.error?.code, reservedKeyCode);
        expect(result.error?.field, 'matcher.rules[0].actions[0].key');
        expect(result.trace, isEmpty);
        // A guarded publication of the same text is a restore and succeeds.
        final restored = await _publish(session, matcher: legacy);
        expect(
          (await _repository(session).activeSnapshot())?['snapshotId'],
          restored.snapshotId,
        );
      });

      test('no_active_matcher_configuration', () async {
        final none = await RuleSimulator().simulate(
          session,
          eventJson: _pasted(),
        );
        expect(none.error, isNull);
        expect(none.noRulesActive, isTrue);
        expect(none.snapshotId, isNull);
        expect(none.trace, isEmpty);
        expect(none.baselineRoutes, isEmpty);
        expect(none.sourceAbsent, isTrue);
        expect(
          none.notes,
          contains(startsWith("The event's source is not in the active")),
        );
        expect(none.finalLabels, {
          'alertname': 'Example',
          'severity': 'warning',
        });
        final snapshot = await _publish(session);
        final without = await RuleSimulator().simulate(
          session,
          eventJson: _pasted(),
        );
        expect(without.noRulesActive, isTrue);
        expect(without.snapshotId, snapshot.snapshotId);
        expect(without.trace, isEmpty);
        expect(without.notes, contains('No rules are active.'));
        expect(without.finalSeverity, 'warning');
      });

      test('kept_member_cannot_be_identified', () async {
        await _publish(session);
        await _process(session, [_alert(description: 'desc-a')]);
        final stored = (await _stored(session)).single;
        final body = utf8.encode(
          jsonEncode(payload.groupOf([_alert(description: 'changed')])),
        );
        await session.db.unsafeExecute(
          'UPDATE raw_inbox SET body=@body WHERE raw_id=CAST(@raw AS uuid)',
          parameters: QueryParameters.named({
            'body': Uint8List.fromList(body),
            'raw': stored.raw,
          }),
        );
        final result = await _simulateStored(session, stored);
        expect(result.error?.code, 'ambiguous_member');
        expect(result.trace, isEmpty);
      });

      test('members_differ_only_in_an_excluded_label', () async {
        await _publish(session, excluded: ['pod']);
        await _process(session, [
          _alert(name: 'Pod', labels: {'pod': 'p1'}),
          _alert(name: 'Pod', labels: {'pod': 'p2'}),
        ]);
        final stored = (await _stored(session)).single;
        final result = await _simulateStored(session, stored);
        expect(result.error?.code, 'ambiguous_member');
        expect(result.trace, isEmpty);
      });

      test('pipeline_and_simulator_agree_for_a_deliverable_event', () async {
        await _publish(
          session,
          matcher: _matcher([
            _rule(
              'regex-rule',
              {'field': 'summary', 'op': 'regex', 'value': 'Example.*'},
              [
                _label('tier', 'gold'),
                _route(_outB),
                {
                  'type': 'link',
                  'href': 'https://runbooks.example/run',
                  'relation': 'runbook',
                  'text': 'Runbook',
                },
                {
                  'type': 'map_severity',
                  'values': {'warning': 'critical'},
                },
              ],
            ),
            _rule(
              'plain',
              {'field': 'labels.alertname', 'op': 'equals', 'value': 'Parity'},
              [_label('team', 'ops')],
            ),
          ]),
        );
        await _process(session, [
          _alert(name: 'Parity', labels: {'severity': 'warning'}),
        ]);
        final stored = (await _stored(session)).single;
        final outputs = {
          for (final row in await session.db.unsafeQuery(
            'SELECT output_id::text FROM outbox',
          ))
            row[0]! as String,
        };
        expect(outputs, {_outA, _outB});
        final result = await _simulateStored(session, stored);
        expect(result.error, isNull);
        expect(_outcomes(result), ['matched', 'matched']);
        final event = stored.event;
        expect(result.finalLabels, event.labels);
        expect(result.finalLabelOrigins, {
          for (final key in event.labels.keys)
            key: event.labelsOrigin[key] ?? 'source',
        });
        expect(
          [
            for (final link in result.finalLinks)
              (link.href, link.relation, link.text),
          ],
          [
            for (final link in event.links)
              (link.href, link.relation, link.text),
          ],
        );
        expect(result.finalSeverity, event.severity.name);
        expect(event.severity, EventSeverity.critical);
        expect(
          result.addedRoutes.toSet(),
          outputs.difference(result.baselineRoutes.toSet()),
        );
      });

      test('the_pipeline_s_cutoff_left_rules_unattempted', () async {
        await _publish(
          session,
          matcher: _matcher([
            _rule('one', _anySummary, [_label('one', '1')]),
            _rule('two', _anySummary, [_label('two', '2')]),
          ]),
        );
        await _process(
          session,
          [_alert()],
          elapsed: const Duration(seconds: 9),
        );
        final outcome =
            jsonDecode(
                  (await session.db.unsafeQuery(
                        'SELECT outcome_json FROM raw_inbox',
                      )).single[0]!
                      as String,
                )
                as Map<String, Object?>;
        expect(outcome['matcher_unattempted'], 2);
        final stored = (await _stored(session)).single;
        expect(stored.event.labels, isNot(contains('one')));
        expect(stored.event.pipeline.enrichmentErrors, isEmpty);
        final result = await _simulateStored(session, stored);
        expect(_outcomes(result), ['matched', 'matched']);
        expect(result.finalLabels, containsPair('two', '2'));
        expect(result.storedEnrichmentErrors, isEmpty);
        expect(result.storedBudgetNote, simulationStoredBudgetNote);
        expect(
          result.storedBudgetNote,
          contains('without a recorded error'),
        );
      });

      test('stored_event_processed_under_other_rules', () async {
        final first = await _publish(
          session,
          matcher: _matcher([
            _rule('old', _anySummary, [_label('old', '1')]),
          ]),
        );
        // The old snapshot, as the previous binary published it, also writes
        // the reserved key with set_label.
        await support.seed(session, [_alert()]);
        final worker = _worker(session);
        expect(await worker.pinOne(), isTrue);
        await _rewriteStoredMatcher(
          session,
          first.snapshotId,
          _matcher([
            _rule('old', _anySummary, [
              _label('old', '1'),
              _writeReserved('legacy'),
            ]),
          ]),
        );
        expect(await worker.processOne(), isTrue);
        final second = await _publish(
          session,
          matcher: _matcher([
            _rule('quiet', _anySummary, [
              {'type': 'classify', 'value': 'heartbeat'},
            ]),
          ]),
        );
        final stored = (await _stored(session)).single;
        final result = await _simulateStored(session, stored);
        expect(result.storedSnapshotId, first.snapshotId);
        expect(result.snapshotId, second.snapshotId);
        expect(result.storedLabels, containsPair('old', '1'));
        expect(result.storedLabels, containsPair(_key, 'legacy'));
        expect(result.storedLabelOrigins, containsPair(_key, 'matcher'));
        expect(result.finalLabels, isNot(contains('old')));
        expect(result.noiseClassHint, 'heartbeat');
        expect(result.finalLabels, containsPair(_key, 'heartbeat'));
        expect(result.finalLabelOrigins, containsPair(_key, 'matcher'));
      });

      test('stored_label_is_not_a_hint', () async {
        // A snapshot published by the previous binary writes the key with
        // set_label; the row is pinned to it and the worker applies it.
        final old = await _publish(
          session,
          matcher: _matcher([
            _rule('example', _anySummary, [_label('team', 'ops')]),
          ]),
        );
        await support.seed(session, [_alert()]);
        final worker = _worker(session);
        expect(await worker.pinOne(), isTrue);
        await _rewriteStoredMatcher(
          session,
          old.snapshotId,
          _matcher([
            _rule('example', _anySummary, [_writeReserved('legacy')]),
          ]),
        );
        expect(await worker.processOne(), isTrue);
        final stored = (await _stored(session)).single;
        expect(stored.event.labels, containsPair(_key, 'legacy'));
        expect(stored.event.labelsOrigin, containsPair(_key, 'matcher'));

        // The pre-change snapshot is still active: its set_label is applied in
        // the simulation as a label, and is not a hint.
        final underOld = await _simulateStored(session, stored);
        expect(underOld.error, isNull);
        expect(underOld.finalLabels, containsPair(_key, 'legacy'));
        expect(underOld.noiseClassHint, isNull);

        // Other rules are active and none classifies the event.
        await _publish(
          session,
          matcher: _matcher([
            _rule('other', _anySummary, [_label('other', '1')]),
          ]),
        );
        final result = await _simulateStored(session, stored);
        expect(result.noiseClassHint, isNull);
        expect(result.storedSnapshotId, old.snapshotId);
        expect(result.storedLabels, containsPair(_key, 'legacy'));
        expect(result.storedLabelOrigins, containsPair(_key, 'matcher'));
        expect(result.finalLabels, isNot(contains(_key)));
      });

      test('source_label_with_the_reserved_key_is_not_a_hint', () async {
        await _publish(
          session,
          matcher: _matcher([
            _rule('other', _anySummary, [_label('other', '1')]),
          ]),
        );
        await _process(session, [
          _alert(labels: {_key: 'custom'}),
        ]);
        final stored = (await _stored(session)).single;
        expect(stored.event.labelsOrigin[_key] ?? 'source', 'source');
        final result = await _simulateStored(session, stored);
        expect(result.error, isNull);
        expect(result.noiseClassHint, isNull);
        expect(result.finalLabels, containsPair(_key, 'custom'));
        expect(result.finalLabelOrigins, containsPair(_key, 'source'));
        expect(result.storedLabelOrigins?[_key] ?? 'source', 'source');
      });

      test('a_route_moved_from_source_configuration_to_a_rule', () async {
        await _publish(session, routes: [_outA, _outB]);
        await _process(session, [_alert()]);
        expect(await _count(session, 'outbox'), 2);
        await _publish(
          session,
          routes: [_outA],
          matcher: _matcher([
            _rule('moved', _anySummary, [_route(_outB)]),
          ]),
        );
        final stored = (await _stored(session)).single;
        final result = await _simulateStored(session, stored);
        expect(result.baselineRoutes, [_outA]);
        expect(result.addedRoutes, [_outB]);
        expect(result.sourceAbsent, isFalse);
        final action = result.trace.single.actions.single;
        expect(action.type, 'route');
        expect(action.applied, isTrue);
      });

      test('source_absent_from_the_active_snapshot', () async {
        await _publish(session, routes: [_outA, _outB]);
        await _process(session, [_alert()]);
        await _publish(
          session,
          source: false,
          matcher: _matcher([
            _rule('add', _anySummary, [_route(_outA), _route(_outB)]),
          ]),
        );
        final stored = (await _stored(session)).single;
        final result = await _simulateStored(session, stored);
        expect(result.error, isNull);
        expect(result.sourceAbsent, isTrue);
        expect(result.baselineRoutes, isEmpty);
        expect(result.addedRoutes.toSet(), {_outA, _outB});
        expect(result.notes.join(' '), contains('not in the active snapshot'));
      });

      test('failing_rule_in_simulation_is_not_counted', () async {
        await _publish(
          session,
          matcher: _matcher([
            _rule(
              'regexy',
              {'field': 'summary', 'op': 'regex', 'value': 'Example.*'},
              [_label('a', '1')],
            ),
          ]),
        );
        final failures = await _count(session, 'matcher_failure');
        final activity = await _count(session, 'activity');
        final worker = _overrunningWorker();
        addTearDown(worker.close);
        final result = await RuleSimulator(regexWorker: worker).simulate(
          session,
          eventJson: _pasted(),
        );
        final rule = result.trace.single;
        expect((rule.outcome, rule.failureCode), ('failed', 'regex_timeout'));
        expect(result.finalLabels, isNot(contains('a')));
        expect(await _count(session, 'matcher_failure'), failures);
        expect(await _count(session, 'activity'), activity);
      });

      test('the_pipeline_s_regex_budget_ran_out', () async {
        await _publish(
          session,
          matcher: _matcher([
            _rule(
              'blocked',
              {'field': 'summary', 'op': 'regex', 'value': 'Example.*'},
              [_label('hit', 'yes')],
            ),
          ]),
        );
        final regex = _overrunningWorker();
        addTearDown(regex.close);
        await _process(session, [
          _alert(name: 'First'),
          _alert(name: 'Second'),
        ], regex: regex);
        final rows = await _stored(session);
        final codes = {
          for (final row in rows)
            row.event.pipeline.enrichmentErrors.single.code: row,
        };
        expect(codes.keys.toSet(), {'regex_timeout', 'regex_budget'});
        final ran = codes['regex_budget']!;
        final result = await _simulateStored(session, ran);
        expect(result.error, isNull);
        expect(_outcomes(result), ['matched']);
        expect(result.finalLabels, containsPair('hit', 'yes'));
        final stored = result.storedEnrichmentErrors!.single;
        expect((stored.code, stored.message), ('regex_budget', 'blocked'));
      });

      test('the_pipeline_s_regex_call_overran_its_budget', () async {
        await _publish(
          session,
          matcher: _matcher([
            _rule(
              'slow',
              {'field': 'summary', 'op': 'regex', 'value': 'Example.*'},
              [_label('hit', 'yes')],
            ),
          ]),
        );
        final regex = _overrunningWorker();
        addTearDown(regex.close);
        await _process(session, [_alert()], regex: regex);
        final stored = (await _stored(session)).single;
        final result = await _simulateStored(session, stored);
        expect(_outcomes(result), ['matched']);
        expect(result.finalLabels, containsPair('hit', 'yes'));
        final error = result.storedEnrichmentErrors!.single;
        expect((error.code, error.message), ('regex_timeout', 'slow'));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'Rule simulator over stored Icinga2 Event Streams events',
    (builder, _) {
      late Session session;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
      });

      Future<_Stored> only() async => (await _stored(session)).single;

      test(
        'stream_event_admitted_under_another_snapshot_than_its_pin',
        () async {
          final permissive = await publishStreamDb(session);
          // A soft state is kept under the permissive admission policy.
          await seedStreamDb(session, permissive, [
            streamDbCheck(streamDbNow, stateType: 0),
          ]);
          final strict = await publishStreamDb(
            session,
            revision: 2,
            policy: 'hard_only',
          );
          await processIcinga2(session, streamDbNow);
          final stored = await only();
          expect(stored.snapshot, strict);
          final result = await _simulateStored(session, stored);
          // Decoded through the admission metadata, not the pin's state policy.
          expect(result.error, isNull);
          expect(result.storedSnapshotId, strict);
          expect(result.eventKind, 'alert');
        },
      );

      test('routes_for_an_ineligible_event_are_hypothetical', () async {
        const output = '99999999-9999-4999-8999-999999999999';
        final snapshot = await publishStreamDb(
          session,
          matcherOutput: output,
          matcher: _matcher([
            _rule('extra', _anySummary, [_route(output)]),
          ]),
        );
        DateTime before(int seconds) =>
            streamDbNow.subtract(Duration(seconds: seconds));
        for (final seconds in [60, 120]) {
          await seedStreamDb(session, snapshot, [
            streamDbCheck(before(seconds)),
          ]);
          await processIcinga2(session, streamDbNow);
        }
        final staleId =
            (await session.db.unsafeQuery(
                  "SELECT event_id::text FROM events WHERE state_outcome='stale'",
                )).single[0]!
                as String;
        final stored = (await _stored(
          session,
        )).singleWhere((row) => row.id == staleId);
        final routed = await session.db.unsafeQuery(
          '''SELECT output_id::text FROM outbox WHERE event_id=CAST(@id AS uuid)''',
          parameters: QueryParameters.named({'id': staleId}),
        );
        expect(routed, isEmpty);
        final result = await _simulateStored(session, stored);
        expect(result.error, isNull);
        expect(result.addedRoutes, [output]);
        expect(result.baselineRoutes, [icinga2DbOutputIds.first]);
        expect(
          result.routeNote,
          contains('delivery eligibility is not evaluated'),
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
