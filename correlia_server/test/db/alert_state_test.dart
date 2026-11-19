import '../support/secret_fixture.dart';

import 'dart:async';
import 'dart:convert';

import 'package:correlia_server/src/event/canonical_event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/state/alert_state_service.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;
import 'pipeline_test.dart' as pipeline;

final base = DateTime.utc(2026, 11, 10, 12);

Map<String, Object?> firing(
  String start, {
  String name = 'Example',
  String severity = 'warning',
}) => payload.alert(
  startsAt: start,
  labels: {'alertname': name, 'severity': severity},
);
Map<String, Object?> recovery(
  String start,
  String end, {
  String name = 'Example',
  String severity = 'warning',
}) => payload.alert(
  status: 'resolved',
  startsAt: start,
  endsAt: end,
  labels: {'alertname': name, 'severity': severity},
);

Future<void> reset(Session session, {bool excludeSeverity = false}) async {
  await initializeIngestSchema(session);
  for (final table in [
    'activity',
    'alerts',
    'pipeline_failures',
    'observation_keys',
    'outbox',
    'events',
    'raw_inbox',
    'ingest_active_config',
    'ingest_source',
    'ingest_config_snapshot',
    'ingest_secret_commitment',
    'secret_record',
    'ingest_source_credential',
  ]) {
    await session.db.unsafeSimpleExecute('DELETE FROM "$table"');
  }
  final config = excludeSeverity
      ? IngestBootstrap.parse(
          {
            'format_version': 1,
            'revision': 1,
            'sources': [
              {
                'id': fixture.sourceId,
                'enabled': true,
                'token_ref': 'source-token',
                'output_ids': [fixture.outputId],
                'excluded_identity_labels': ['severity'],
              },
            ],
            'outputs': [
              {
                'id': fixture.outputId,
                'kind': 'webhook',
                'url': 'http://127.0.0.1:9099/events',
                'signing_key_ref': 'key',
              },
            ],
          },
          {'source-token': fixture.token(1), 'key': fixture.token(2)},
          runMode: 'test',
        )
      : fixture.input(1);
  await IngestConfigRepository(
    session,
    secretStore: testSecretStore,
  ).publish(config);
}

Future<void> deliver(
  Session session,
  List<Object?> alerts,
  DateTime observed,
) async {
  await pipeline.seed(session, alerts, observed: observed);
  final repo = PipelineRepository(session, clock: () => observed);
  expect(await repo.pinOne(), isTrue);
  expect(await repo.processOne(), isTrue);
}

Future<List<Map<String, Object?>>> rows(Session session, String sql) async =>
    (await session.db.unsafeQuery(
      sql,
    )).map((row) => row.toColumnMap()).toList();
Future<Map<String, Object?>> state(Session session) async =>
    (await rows(session, 'SELECT * FROM alerts')).single;
Future<Map<String, Object?>> latestOutcome(Session session) async =>
    jsonDecode(
          (await session.db.unsafeQuery(
                'SELECT outcome_json FROM raw_inbox ORDER BY observed_at DESC LIMIT 1',
              )).single[0]
              as String,
        )
        as Map<String, Object?>;

void main() {
  withServerpod(
    'alert state transaction',
    (builder, _) {
      setUp(() async => reset(builder.build()));
      final first = firing('2026-11-10T11:59:00Z');
      final resolved = recovery('2026-11-10T11:59:00Z', '2026-11-10T12:00:00Z');

      test('first_firing_observation_creates_firing_alert', () async {
        final s = builder.build();
        await deliver(s, [first], base);
        final a = await state(s);
        expect(a['status'], 'firing');
        expect(a['severity'], 'warning');
        expect(a['version'], 1);
        expect(
          a['fenceEventId'],
          (await rows(
            s,
            'SELECT event_id::text AS id FROM events',
          )).single['id'],
        );
      });
      test('first_observation_is_a_recovery', () async {
        final s = builder.build();
        await deliver(s, [resolved], base);
        await deliver(s, [first], base.add(const Duration(seconds: 1)));
        final a = await state(s);
        expect(a['status'], 'resolved');
        expect(a['version'], 1);
      });
      test('concurrent_first_observations_of_one_fingerprint', () async {
        final s = builder.build();
        final s1 = builder.build();
        final s2 = builder.build();
        await pipeline.seed(s, [first], observed: base);
        await pipeline.seed(s, [
          resolved,
        ], observed: base.add(const Duration(seconds: 1)));
        final r1 = PipelineRepository(
          s1,
          clock: () => base.add(const Duration(minutes: 1)),
        );
        final r2 = PipelineRepository(
          s2,
          clock: () => base.add(const Duration(minutes: 1)),
        );
        await Future.wait([r1.pinOne(), r2.pinOne()]);
        final ready = Completer<void>();
        final go = Completer<void>();
        Future<bool> run(PipelineRepository repo, bool signal) async {
          if (signal) ready.complete();
          await go.future;
          return repo.processOne();
        }

        final a = run(r1, true);
        final b = run(r2, false);
        await ready.future;
        go.complete();
        expect(await Future.wait([a, b]), everyElement(isTrue));
        expect(await pipeline.count(s, 'alerts'), 1);
        final outcomes = await rows(s, 'SELECT state_outcome FROM events');
        expect(outcomes, hasLength(2));
        expect(
          outcomes.map((e) => e['state_outcome']),
          everyElement(anyOf('applied', 'stale')),
        );
        expect(
          (await rows(
            s,
            'SELECT status FROM raw_inbox',
          )).map((r) => r['status']),
          everyElement('done'),
        );
      });
      test('ord_1_delayed_recovery_does_not_clear_newer_problem', () async {
        final s = builder.build();
        await deliver(s, [firing('2026-11-10T12:00:00Z')], base);
        await deliver(s, [
          recovery('2026-11-10T11:58:00Z', '2026-11-10T11:59:00Z'),
        ], base.add(const Duration(seconds: 1)));
        final a = await state(s);
        expect(a['status'], 'firing');
        expect(a['version'], 1);
        expect((await latestOutcome(s))['stale'], 1);
      });
      test('ord_2_stale_problem_does_not_resurrect_resolved_alert', () async {
        final s = builder.build();
        await deliver(s, [resolved], base);
        await deliver(s, [first], base.add(const Duration(seconds: 1)));
        expect((await state(s))['status'], 'resolved');
        expect((await latestOutcome(s))['stale'], 1);
      });
      test('ord_3_equal_source_times_ordered_deterministically', () async {
        final s = builder.build();
        final f = firing('2026-11-10T12:00:00Z');
        final r = recovery('2026-11-10T11:59:00Z', '2026-11-10T12:00:00Z');
        await deliver(s, [f], base);
        await deliver(s, [r], base.add(const Duration(seconds: 1)));
        final a = await state(s);
        expect(a['status'], 'resolved');
        await reset(s);
        await deliver(s, [r], base.add(const Duration(seconds: 1)));
        await deliver(s, [f], base);
        final b = await state(s);
        expect(b['status'], a['status']);
        expect(b['fenceEventId'], a['fenceEventId']);
        expect(b['version'], 1);
      });
      test('source_times_less_than_a_microsecond_apart', () async {
        final s = builder.build();
        await deliver(s, [firing('2026-11-10T11:59:00.000000900Z')], base);
        await deliver(s, [
          recovery('2026-11-10T11:58:00Z', '2026-11-10T11:59:00.000000800Z'),
        ], base.add(const Duration(seconds: 1)));
        final a = await state(s);
        expect(a['status'], 'firing');
        expect(a['fenceEffectiveNanos'], 900);
        expect((await latestOutcome(s))['stale'], 1);
      });
      test('id_7c_severity_changes_in_place', () async {
        final s = builder.build();
        await reset(s, excludeSeverity: true);
        await deliver(s, [first], base);
        await deliver(s, [
          firing('2026-11-10T12:00:00Z', severity: 'critical'),
        ], base.add(const Duration(seconds: 1)));
        final a = await state(s);
        expect(a['severity'], 'critical');
        expect(a['version'], 2);
      });
      test('id_7b_severity_labelled_alerts_are_separate', () async {
        final s = builder.build();
        await deliver(s, [
          first,
          firing('2026-11-10T11:59:00Z', severity: 'critical'),
        ], base);
        await deliver(s, [
          recovery(
            '2026-11-10T11:59:00Z',
            '2026-11-10T12:00:00Z',
            severity: 'critical',
          ),
        ], base.add(const Duration(seconds: 1)));
        final a = await rows(
          s,
          'SELECT severity,status,version FROM alerts ORDER BY severity',
        );
        expect(a, hasLength(2));
        expect(a[0]['status'], 'resolved');
        expect(a[1]['status'], 'firing');
        expect(a[1]['version'], 1);
      });
      test('stale_observation_with_later_observed_time', () async {
        final s = builder.build();
        await deliver(s, [resolved], base);
        final before = await state(s);
        final later = base.add(const Duration(minutes: 1));
        await deliver(s, [first], later);
        final after = await state(s);
        expect(after['lastObservedAt'], later);
        expect(after['version'], before['version']);
        expect(after['fenceEventId'], before['fenceEventId']);
      });
      test('older_observed_time_never_moves_it_backwards', () async {
        final s = builder.build();
        final later = base.add(const Duration(minutes: 1));
        await deliver(s, [resolved], later);
        await deliver(s, [first], base);
        expect((await state(s))['lastObservedAt'], later);
      });
      test('late_observation_advances_nothing', () async {
        final s = builder.build();
        await deliver(s, [first], base);
        final before = await state(s);
        await deliver(s, [
          recovery('2026-11-01T10:00:00Z', '2026-11-01T11:00:00Z'),
        ], base.add(const Duration(minutes: 1)));
        final after = await state(s);
        expect(after['lastObservedAt'], before['lastObservedAt']);
        expect(after['fenceEventId'], before['fenceEventId']);
        expect(after['version'], before['version']);
        await deliver(s, [
          firing('2026-11-01T10:00:00Z', name: 'unknown'),
        ], base.add(const Duration(minutes: 2)));
        expect(await pipeline.count(s, 'alerts'), 1);
      });
      test('effect_counts_per_raw_row', () async {
        final s = builder.build();
        await deliver(s, [resolved], base);
        await deliver(s, [
          resolved,
          first,
          firing('2026-11-10T12:00:01Z', name: 'Other'),
        ], base.add(const Duration(seconds: 1)));
        final o = await latestOutcome(s);
        expect(o['applied'], 1);
        expect(o['stale'], 1);
        expect(o['duplicate_observation'], 1);
      });
      test('opposite_fingerprint_order_in_concurrent_deliveries', () async {
        final s = builder.build();
        final a = firing('2026-11-10T11:59:00Z', name: 'A');
        final b = firing('2026-11-10T11:59:00Z', name: 'B');
        final ar = recovery(
          '2026-11-10T11:59:00Z',
          '2026-11-10T12:00:00Z',
          name: 'A',
        );
        final br = recovery(
          '2026-11-10T11:59:00Z',
          '2026-11-10T12:00:00Z',
          name: 'B',
        );
        await pipeline.seed(s, [a, b], observed: base);
        await pipeline.seed(s, [
          br,
          ar,
        ], observed: base.add(const Duration(seconds: 1)));
        final r1 = PipelineRepository(
          builder.build(),
          clock: () => base.add(const Duration(minutes: 1)),
        );
        final r2 = PipelineRepository(
          builder.build(),
          clock: () => base.add(const Duration(minutes: 1)),
        );
        await Future.wait([r1.pinOne(), r2.pinOne()]);
        final ready = Completer<void>();
        final go = Completer<void>();
        Future<bool> run(PipelineRepository r, bool signal) async {
          if (signal) ready.complete();
          await go.future;
          return r.processOne();
        }

        final one = run(r1, true);
        final two = run(r2, false);
        await ready.future;
        go.complete();
        await Future.wait([one, two]);
        expect(
          (await rows(
            s,
            'SELECT status FROM raw_inbox',
          )).map((r) => r['status']),
          everyElement('done'),
        );
        final alerts = await rows(s, 'SELECT status FROM alerts');
        expect(alerts, hasLength(2));
        expect(alerts.map((r) => r['status']), everyElement('resolved'));
      });
      test('ord_5c_retry_of_firing_after_recovery', () async {
        final s = builder.build();
        final f = firing('2026-11-10T12:00:00Z');
        final r = recovery('2026-11-10T11:59:00Z', '2026-11-10T12:00:00Z');
        await deliver(s, [f], base);
        await deliver(s, [r], base.add(const Duration(minutes: 1)));
        final before = await state(s);
        final later = base.add(const Duration(minutes: 20));
        await deliver(s, [f], later);
        final after = await state(s);
        expect(after['status'], 'resolved');
        expect(after['version'], before['version']);
        expect(after['lastObservedAt'], later);
        expect((await latestOutcome(s))['duplicate_observation'], 1);
      });
      test('ord_5d_retry_after_observation_key_expired', () async {
        final s = builder.build();
        final f = firing('2026-11-10T13:00:00Z');
        final r = recovery('2026-11-10T12:00:00Z', '2026-11-10T12:10:00Z');
        await deliver(s, [f], base);
        await deliver(s, [r], base.add(const Duration(minutes: 10)));
        final before = await state(s);
        await s.db.unsafeSimpleExecute('DELETE FROM observation_keys');
        await deliver(s, [f], base.add(const Duration(days: 8)));
        final after = await state(s);
        expect(after['status'], 'resolved');
        expect(after['version'], before['version']);
        expect(after['lastObservedAt'], before['lastObservedAt']);
        expect((await latestOutcome(s))['late'], 1);
      });
      test('ord_5f_retry_without_native_id', () async {
        final s = builder.build();
        final f = firing('2026-11-10T13:00:00Z');
        final r = recovery('2026-11-10T12:00:00Z', '2026-11-10T12:10:00Z');
        await deliver(s, [f], base);
        await deliver(s, [r], base.add(const Duration(minutes: 10)));
        final before = await state(s);
        final later = base.add(const Duration(minutes: 20));
        await deliver(s, [f], later);
        final after = await state(s);
        expect(after['status'], 'resolved');
        expect(after['version'], before['version']);
        expect(after['lastObservedAt'], later);
        expect((await latestOutcome(s))['duplicate_observation'], 1);
      });
      test('duplicate_of_late_observation', () async {
        final s = builder.build();
        await deliver(s, [first], base);
        final late = firing('2026-11-01T11:00:00Z');
        await deliver(s, [late], base.add(const Duration(minutes: 1)));
        final before = await state(s);
        await deliver(s, [late], base.add(const Duration(minutes: 2)));
        final after = await state(s);
        expect(after['lastObservedAt'], before['lastObservedAt']);
        expect(after['version'], before['version']);
        expect((await latestOutcome(s))['duplicate_observation'], 1);
      });
      test('informational_duplicates_leave_existing_state_unchanged', () async {
        final session = builder.build();
        await deliver(session, [first], base);
        final before = await state(session);
        final stored = await session.db.unsafeQuery(
          "SELECT (convert_from(payload, 'UTF8')::jsonb->'data')::text FROM events",
        );
        final data =
            jsonDecode(stored.single[0] as String) as Map<String, Object?>;
        data['status'] = 'EVENT_STATUS_INFO';
        final service = AlertStateService(
          session,
          skewAllowance: skewAllowance,
          beforeQuery: () async {},
        );
        for (final duplicate in [false, true]) {
          final now = base.add(Duration(minutes: duplicate ? 2 : 1));
          data['observed_at'] = now.toIso8601String();
          final event = CanonicalEvent.fromJson(data);
          await session.db.transaction(
            (tx) => service.apply(
              tx,
              [StateInput(event, duplicate: duplicate)],
              rawId: '00000000-0000-4000-8000-000000000099',
              now: now,
            ),
          );
          expect(await state(session), before);
          expect(await pipeline.count(session, 'activity'), 1);
        }
      });
      test('ORD-5e future-dated observation is quarantined', () async {
        final session = builder.build();
        await deliver(session, [firing('2026-11-13T12:00:00Z')], base);
        expect(await pipeline.count(session, 'alerts'), 0);
        expect(await pipeline.count(session, 'observation_keys'), 0);
        expect(await pipeline.count(session, 'activity'), 0);
        expect(await pipeline.count(session, 'outbox'), 0);
        final evidence = (await rows(
          session,
          'SELECT source_time, disposition FROM events',
        )).single;
        expect(evidence['source_time'], DateTime.utc(2026, 11, 13, 12));
        expect(evidence['disposition'], 'future_dated');
        expect((await latestOutcome(session))['future_dated'], 1);
      });
      test('source_clock_ahead_within_future_limit', () async {
        final session = builder.build();
        await deliver(session, [firing('2026-11-10T14:00:00Z')], base);
        final alert = await state(session);
        final event = (await session.db.unsafeQuery(
          """SELECT source_time,
          convert_from(payload, 'UTF8')::jsonb->'data'->>'source_time'
          FROM events""",
        )).single;
        expect(event[0], base.add(const Duration(hours: 2)));
        expect(event[1], '2026-11-10T14:00:00Z');
        expect(
          alert['fenceEffectiveSeconds'],
          base.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
        );
        expect(alert['fenceEffectiveNanos'], 0);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
