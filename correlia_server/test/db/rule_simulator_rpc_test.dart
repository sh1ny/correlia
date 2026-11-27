@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:correlia_client/correlia_client.dart' as rpc;
import 'package:correlia_server/src/feed/feed_runtime.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/event/fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;
import 'pipeline_test.dart' as support;

const _outA = fixture.outputId;
const _outB = '33333333-3333-4333-8333-333333333333';

Map<String, Object?> _matcher(List<Map<String, Object?>> rules) => {
  'language': 'matcher',
  'version': 1,
  'rules': rules,
};

Map<String, Object?> _rule(
  String id,
  List<Map<String, Object?>> actions,
) => {
  'id': id,
  'when': {'field': 'summary', 'op': 'exists'},
  'actions': actions,
};

Future<void> _publish(Session session, Object matcher) async {
  final repository = IngestConfigRepository(
    session,
    secretStore: testSecretStore,
  );
  final active = await repository.activeSnapshot();
  await repository.publishConfig(
    {
      'format_version': 2,
      'revision': ((active?['revision'] as int?) ?? 0) + 1,
      'expected_active_snapshot': active?['snapshotId'],
      'sources': [
        {
          'id': fixture.sourceId,
          'kind': 'alertmanager',
          'enabled': true,
          'credentials': [
            {'type': 'bearer', 'ref': 'token'},
          ],
          'output_ids': [_outA],
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
      'matcher': matcher,
    },
    {'token': fixture.token(1), 'key': fixture.token(2)},
    runMode: 'test',
  );
}

/// Every table a simulation must leave alone, as comparable text.
Future<Map<String, List<String>>> _state(Session session) async {
  const tables = {
    'events': 'events',
    'outbox': 'outbox',
    'raw_inbox': 'raw_inbox',
    'snapshots': 'ingest_config_snapshot',
    'active': 'ingest_active_config',
    'keys': 'observation_keys',
    'alerts': 'alerts',
    'activity': 'activity',
    'failures': 'matcher_failure',
  };
  return {
    for (final MapEntry(:key, :value) in tables.entries)
      key: [
        for (final row in await session.db.unsafeQuery(
          'SELECT to_jsonb(t)::text FROM $value t ORDER BY 1',
        ))
          row[0]! as String,
      ],
  };
}

Future<int> _sessionLogs(Session session, String endpoint) async =>
    (await session.db.unsafeQuery(
          'SELECT count(*) FROM serverpod_session_log WHERE endpoint=@e',
          parameters: QueryParameters.named({'e': endpoint}),
        )).single[0]!
        as int;

void main() {
  withServerpod(
    'Rule simulator RPC',
    (builder, _) {
      late Session session;
      late rpc.Client client;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await clearPipelineTables(session);
        await _publish(
          session,
          _matcher([
            _rule('active', [
              {'type': 'set_label', 'key': 'active', 'value': '1'},
            ]),
          ]),
        );
        client = rpc.Client(
          'http://127.0.0.1:${session.serverpod.server.port}/',
        );
        addTearDown(client.close);
        final previous = FeedRuntime.role;
        FeedRuntime.role = ProcessRole.api;
        addTearDown(() => FeedRuntime.role = previous);
      });

      test('refused_outside_the_local_console_policy', () async {
        FeedRuntime.role = ProcessRole.worker;
        // No input at all: the policy is checked before the input is, so the
        // refusal is the access error and not an invalid-input result.
        await expectLater(
          client.ruleSimulator.simulate(),
          throwsA(isA<rpc.ConsoleAccessDeniedException>()),
        );
        await expectLater(
          client.ruleSimulator.simulate(eventJson: jsonEncode(eventFixture())),
          throwsA(isA<rpc.ConsoleAccessDeniedException>()),
        );
        FeedRuntime.role = ProcessRole.api;
        final allowed = await client.ruleSimulator.simulate(
          eventJson: jsonEncode(eventFixture()),
        );
        expect(allowed.error, isNull);
        expect(allowed.trace.single.ruleId, 'active');
      });

      test('an_unpaired_surrogate_in_the_rpc_input_is_refused', () async {
        // The Dart client cannot send a lone surrogate, but any HTTP client
        // can: the escape below decodes to one in the `eventJson` argument.
        final fixture = eventFixture();
        (fixture['data']! as Map<String, Object?>)['summary'] = 'beforeMARK';
        final body = jsonEncode({
          'eventJson': jsonEncode(fixture),
        }).replaceFirst('MARK', r'\ud800');
        expect(body, contains(r'\ud800'));
        final http = HttpClient();
        addTearDown(http.close);
        final request = await http.postUrl(
          Uri.parse(
            'http://127.0.0.1:${session.serverpod.server.port}/ruleSimulator/simulate',
          ),
        );
        request.headers.contentType = ContentType.json;
        request.write(body);
        final response = await request.close();
        expect(response.statusCode, 200);
        final result =
            jsonDecode(await utf8.decodeStream(response))
                as Map<String, Object?>;
        expect(result['error'], {
          ...?result['error'] as Map<String, Object?>?,
          'code': 'invalid_unicode',
          'field': 'eventJson',
        });
        expect(result['trace'], isEmpty);
      });

      test('the_endpoint_writes_no_session_log', () async {
        // Control: this configuration persists a session log for a call to an
        // endpoint that logs, so an absent row for the simulator means
        // something.
        const logging = 'alertConsole';
        // The test run mode logs only slow or failed sessions by default.
        final settings = session.serverpod.runtimeSettings;
        await session.serverpod.updateRuntimeSettings(
          settings.copyWith(
            logSettings: settings.logSettings.copyWith(logAllSessions: true),
          ),
        );
        expect(await _sessionLogs(session, logging), 0);
        await client.alertConsole.snapshot();
        await _waitForLogs(session, logging, 1);

        final result = await client.ruleSimulator.simulate(
          eventJson: jsonEncode(eventFixture()),
        );
        expect(result.error, isNull);
        expect(result.trace, isNotEmpty);

        // A later call to the logging endpoint is persisted after the
        // simulator's session closed, so a missing simulator row is not just a
        // log that has not been flushed yet.
        await client.alertConsole.snapshot();
        await _waitForLogs(session, logging, 2);
        expect(await _sessionLogs(session, 'ruleSimulator'), 0);
      });

      test('a_label_key_that_names_a_model_reaches_the_client', () async {
        // `__className__` is a valid label key, and its value names a model
        // the client knows: the labels must still decode as labels.
        await support.seed(session, [
          payload.alert(
            startsAt: '2026-11-10T12:00:00Z',
            labels: {'alertname': 'Example', '__className__': 'RuleTrace'},
          ),
        ]);
        final worker = PipelineRepository(
          session,
          clock: () => support.now,
          elapsedForTest: () => Duration.zero,
        );
        expect(await worker.pinOne(), isTrue);
        expect(await worker.processOne(), isTrue);
        final event = (await session.db.unsafeQuery(
          'SELECT event_id::text, observed_at FROM events',
        )).single;
        final result = await client.ruleSimulator.simulate(
          eventId: event[0]! as String,
          observedAt: (event[1]! as DateTime).toUtc().toIso8601String(),
          draftMatcher: jsonEncode(
            _matcher([
              _rule('draft', [
                {
                  'type': 'set_label',
                  'key': '__className__',
                  'value': 'SimulationError',
                },
              ]),
            ]),
          ),
        );
        expect(result.error, isNull);
        expect(
          labelMap(result.storedLabels!),
          containsPair('__className__', 'RuleTrace'),
        );
        expect(
          labelMap(result.finalLabels),
          containsPair('__className__', 'SimulationError'),
        );
        expect(
          labelMap(result.finalLabelOrigins),
          containsPair('__className__', 'matcher'),
        );
        expect(
          labelMap(result.storedLabelOrigins!),
          isA<Map<String, String>>(),
        );
      });

      test('simulation_leaves_stored_state_unchanged', () async {
        await support.seed(session, [
          payload.alert(
            startsAt: '2026-11-10T12:00:00Z',
            labels: {'alertname': 'Example'},
          ),
        ]);
        final worker = PipelineRepository(
          session,
          clock: () => support.now,
          elapsedForTest: () => Duration.zero,
        );
        expect(await worker.pinOne(), isTrue);
        expect(await worker.processOne(), isTrue);
        final event = (await session.db.unsafeQuery(
          'SELECT event_id::text, observed_at FROM events',
        )).single;
        final before = await _state(session);
        expect(before['events'], hasLength(1));
        expect(before['outbox'], isNotEmpty);

        final result = await client.ruleSimulator.simulate(
          eventId: event[0]! as String,
          observedAt: (event[1]! as DateTime).toUtc().toIso8601String(),
          draftMatcher: jsonEncode(
            _matcher([
              _rule('draft', [
                {'type': 'set_label', 'key': 'draft', 'value': 'yes'},
                {'type': 'route', 'output_id': _outB},
              ]),
            ]),
          ),
        );
        expect(result.error, isNull);
        expect(result.ruleSource, 'draft');
        expect(labelMap(result.finalLabels), containsPair('draft', 'yes'));
        expect(result.addedRoutes, [_outB]);
        expect(await _state(session), before);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}

/// Polls the session log table until [endpoint] has [count] rows.
///
/// Serverpod writes a session's log when the session closes, which can be
/// after the response; the loop reads the table and never sleeps.
Future<void> _waitForLogs(Session session, String endpoint, int count) async {
  for (var i = 0; i < 100000; i++) {
    if (await _sessionLogs(session, endpoint) >= count) return;
  }
  fail('no session log row for $endpoint');
}

/// [labels] as a map, as the client receives them.
Map<String, String> labelMap(List<rpc.SimulatedLabel> labels) => {
  for (final label in labels) label.key: label.value,
};
