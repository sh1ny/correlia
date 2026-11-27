import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/matcher_content_digest.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;

const _key = 'correlia.noise_class';
const _source = 'bbbbbbbb-bbbb-4bbb-8bbb-777777777777';
final _now = DateTime.utc(2026, 11, 1);

Map<String, Object?> _config(
  int revision,
  Object? expected,
  Object? matcher, {
  bool source = false,
  String? output,
}) => {
  'format_version': 2,
  'revision': revision,
  'expected_active_snapshot': expected,
  'sources': source
      ? [
          {
            'id': _source,
            'kind': 'alertmanager',
            'enabled': true,
            'output_ids': [?output],
            'credentials': [
              {'type': 'bearer', 'ref': 'reserved-token'},
            ],
          },
        ]
      : <Object?>[],
  'outputs': [
    if (output != null)
      {
        'id': output,
        'kind': 'webhook',
        'url': 'http://127.0.0.1:9099/events',
        'signing_key_ref': 'reserved-key',
      },
  ],
  'matcher': ?matcher,
};

Map<String, Object?> _matcher(
  List<Map<String, Object?>> actions, {
  Object? when = const {'field': 'summary', 'op': 'exists'},
}) => {
  'language': 'matcher',
  'version': 1,
  'rules': [
    {'id': 'example', 'when': when, 'actions': actions},
  ],
};

Map<String, Object?> _write(String value, {String type = 'set_label'}) =>
    switch (type) {
      'set_label' => {'type': 'set_label', 'key': _key, 'value': value},
      _ => {
        'type': 'extract',
        'field': 'labels.alertname',
        'pattern': '(.+)',
        'group': 1,
        'key': _key,
      },
    };

const _benign = [
  {'type': 'set_label', 'key': 'team', 'value': 'ops'},
];

const _output = '44444444-4444-4444-8444-444444444444';

final _reserved = {
  'reserved-token': base64Url
      .encode(List<int>.filled(32, 7))
      .replaceAll('=', ''),
  'reserved-key': base64Url.encode(List<int>.filled(32, 9)).replaceAll('=', ''),
};

/// The matcher JSON a snapshot stores for [section].
Map<String, Object?> _stored(Object? section) =>
    MatcherDocument.parse(section, const {}).snapshotJson;

/// Stores [config] the way the previous binary did: a snapshot row and the
/// active pointer, with no digest. It never ran the new reserved-key check.
Future<void> _asPublisher(
  Session session,
  Future<void> Function(Transaction) write,
) => session.db.transaction((transaction) async {
  await session.db.unsafeSimpleExecute(
    "SET LOCAL correlia.publisher_version = '2'",
    transaction: transaction,
  );
  await write(transaction);
});

Future<IngestBootstrap> _installPreChange(
  Session session,
  Object? config,
) async {
  final parsed = IngestBootstrap.parse(
    config,
    const <String, Object?>{},
    runMode: 'test',
  );
  await _asPublisher(session, (transaction) async {
    await session.db.unsafeExecute(
      '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
      VALUES (@id,@revision,@json)''',
      parameters: QueryParameters.named({
        'id': parsed.snapshotId,
        'revision': parsed.revision,
        'json': parsed.publicJson,
      }),
      transaction: transaction,
    );
    await session.db.unsafeExecute(
      '''INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@id)
      ON CONFLICT (singleton) DO UPDATE SET "snapshotId"=EXCLUDED."snapshotId"''',
      parameters: QueryParameters.named({'id': parsed.snapshotId}),
      transaction: transaction,
    );
  });
  return parsed;
}

/// Returns the database to its state after step 14: no digest tables and no
/// record that steps 15 to 17 ran. The next `initializeSchema` is then the
/// upgrade.
Future<void> _rewindToBeforeStep15(Session session) async {
  await session.db.unsafeSimpleExecute(
    '''DROP TABLE matcher_content_digest;
    DROP TABLE matcher_content_digest_fill;
    DELETE FROM correlia_schema_versions WHERE version IN (15, 16, 17)''',
  );
}

Future<int> _count(Session session, String table) async =>
    (await session.db.unsafeQuery('SELECT count(*) FROM $table')).single[0]!
        as int;

/// Rewrites the stored matcher of [snapshotId], as if an older binary had
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
  document['matcher'] = _stored(section);
  await session.db.unsafeExecute(
    'UPDATE ingest_config_snapshot SET "publicJson"=@json WHERE "snapshotId"=@id',
    parameters: QueryParameters.named({
      'id': snapshotId,
      'json': jsonEncode(document),
    }),
  );
}

/// Inserts [count] snapshots with distinct key-writing matcher content, the way
/// the previous binary stored them. Returns each one's operator matcher.
Future<List<Map<String, Object?>>> _insertHistory(
  Session session,
  int count,
) async {
  final sections = <Map<String, Object?>>[];
  for (var start = 0; start < count; start += 500) {
    final end = start + 500 < count ? start + 500 : count;
    final values = <String>[];
    final parameters = <String, Object?>{};
    for (var i = start; i < end; i++) {
      final section = _matcher([_write('history-$i')]);
      sections.add(section);
      final json = jsonEncode({'matcher': _stored(section)});
      parameters['id$i'] = sha256.convert(utf8.encode(json)).toString();
      parameters['json$i'] = json;
      values.add('(@id$i, ${1000000 + i}, @json$i)');
    }
    await _asPublisher(
      session,
      (transaction) => session.db.unsafeExecute(
        '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
        VALUES ${values.join(',')}''',
        parameters: QueryParameters.named(parameters),
        transaction: transaction,
      ),
    );
  }
  return sections;
}

/// Inserts one snapshot of [section] under [id], the way the previous binary
/// stored it, with no digest.
Future<void> _insertSnapshot(
  Session session,
  String id,
  int revision,
  Object? section,
) => _asPublisher(
  session,
  (transaction) => session.db.unsafeExecute(
    '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
    VALUES (@id, @revision, @json)''',
    parameters: QueryParameters.named({
      'id': id,
      'revision': revision,
      'json': jsonEncode({'matcher': _stored(section)}),
    }),
    transaction: transaction,
  ),
);

Future<void> _deleteSnapshot(Session session, String id) =>
    session.db.unsafeExecute(
      'DELETE FROM ingest_config_snapshot WHERE "snapshotId"=@id',
      parameters: QueryParameters.named({'id': id}),
    );

Matcher get _foreignKeyViolation => isA<DatabaseQueryException>().having(
  (e) => e.code,
  'code',
  '23503',
);

IngestConfigRepository _repository(Session session) =>
    IngestConfigRepository(session, secretStore: testSecretStore);

Future<IngestBootstrap> _publish(
  Session session,
  int revision,
  Object? expected,
  Object? matcher, {
  bool source = false,
  String? output,
}) => _repository(session).publishConfig(
  _config(revision, expected, matcher, source: source, output: output),
  source ? _reserved : const <String, Object?>{},
  runMode: 'test',
);

Matcher _reservedKeyError(String field) => isA<BootstrapError>()
    .having((e) => e.field, 'field', field)
    .having((e) => e.code, 'code', reservedKeyCode)
    .having((e) => e.toString(), 'message', contains(_key))
    .having((e) => e.toString(), 'fix', contains('classify'));

PipelineRepository _worker(Session session) => PipelineRepository(
  session,
  clock: () => _now,
  elapsedForTest: () => Duration.zero,
);

Future<void> _insertRaw(Session session, int number, String summary) async {
  final id = 'bbbbbbbb-bbbb-4bbb-8bbb-${number.toString().padLeft(12, '0')}';
  final body = utf8.encode(
    jsonEncode(
      payload.groupOf([
        payload.alert(
          startsAt: _now.toIso8601String(),
          labels: {'alertname': summary},
        ),
      ]),
    ),
  );
  await session.db.unsafeExecute(
    '''INSERT INTO raw_inbox (observed_at, raw_id, source_id, body, body_sha256, content_type)
    VALUES (@observed, @id::uuid, '$_source', @body, @digest, 'application/json')''',
    parameters: QueryParameters.named({
      'id': id,
      'observed': _now,
      'body': body,
      'digest': sha256.convert(body).toString(),
    }),
  );
}

Future<List<CanonicalEvent>> _events(Session session) async => [
  for (final row in await session.db.unsafeQuery(
    "SELECT payload FROM events WHERE source_id='$_source' ORDER BY raw_id",
  ))
    CloudEvent.decode(row[0]! as Uint8List).event,
];

void _dbTest(String name, Future<void> Function(TestSessionBuilder) body) {
  withServerpod(
    'matcher reserved label: $name',
    (builder, _) {
      test(name, () => body(builder));
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}

/// Waits, by polling the lock table without sleeping, for a backend to wait on
/// the publication advisory lock.
Future<void> _waitForLockWaiter(Session session) async {
  for (var i = 0; i < 20000; i++) {
    final rows = await session.db.unsafeQuery(
      '''SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=0
      AND objid=$publicationLockKey AND NOT granted''',
    );
    if (rows.isNotEmpty) return;
  }
  fail('no backend waited for the publication lock');
}

void main() {
  _dbTest('other_actions_cannot_write_the_reserved_key', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final base = await _publish(session, 1, null, _matcher(_benign));
    var revision = 2;
    for (final action in [_write('heartbeat'), _write('x', type: 'extract')]) {
      await expectLater(
        _publish(session, revision++, base.snapshotId, _matcher([action])),
        throwsA(_reservedKeyError('matcher.rules[0].actions[0].key')),
      );
      final active = await _repository(session).activeSnapshot();
      expect(active?['snapshotId'], base.snapshotId);
    }
    expect(await _count(session, 'ingest_config_snapshot'), 1);
    // classify is the one way to write it.
    final classified = await _publish(
      session,
      revision,
      base.snapshotId,
      _matcher([
        {'type': 'classify', 'value': 'heartbeat'},
      ]),
    );
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      classified.snapshotId,
    );
    // A different key is an ordinary label.
    await _publish(
      session,
      revision + 1,
      classified.snapshotId,
      _matcher([
        {'type': 'set_label', 'key': 'correlia.noise_classes', 'value': 'x'},
      ]),
    );
  });

  _dbTest('malformed_classify_is_rejected_at_publication', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final base = await _publish(session, 1, null, _matcher(_benign));
    var revision = 2;
    for (final (action, field) in [
      ({'type': 'classify'}, 'matcher.rules[0].actions[0].value'),
      (
        {'type': 'classify', 'value': 'test', 'key': 'x'},
        'matcher.rules[0].actions[0]',
      ),
      (
        {'type': 'classify', 'value': 'urgent'},
        'matcher.rules[0].actions[0].value',
      ),
    ]) {
      await expectLater(
        _publish(session, revision++, base.snapshotId, _matcher([action])),
        throwsA(isA<BootstrapError>().having((e) => e.field, 'field', field)),
        reason: '$action',
      );
      expect(
        (await _repository(session).activeSnapshot())?['snapshotId'],
        base.snapshotId,
      );
    }
    expect(await _count(session, 'ingest_config_snapshot'), 1);
  });

  _dbTest('a_classified_watchdog_keeps_its_live_alert_state', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final worker = _worker(session);
    await _publish(
      session,
      1,
      null,
      _matcher(
        [
          {'type': 'classify', 'value': 'heartbeat'},
        ],
        when: const {
          'field': 'labels.alertname',
          'op': 'equals',
          'value': 'Watchdog',
        },
      ),
      source: true,
      output: _output,
    );
    // The same alert shape twice: one is classified, the other is not.
    await _insertRaw(session, 1, 'Watchdog');
    await _insertRaw(session, 2, 'Other');
    for (var i = 0; i < 2; i++) {
      expect(await worker.pinOne(), isTrue);
      expect(await worker.processOne(), isTrue);
    }
    final events = {
      for (final event in await _events(session))
        event.labels['alertname']: event,
    };
    final watchdog = events['Watchdog']!;
    expect(watchdog.labels, containsPair(_key, 'heartbeat'));
    expect(watchdog.labelsOrigin, containsPair(_key, 'matcher'));
    expect(watchdog.kind, EventKind.alert);
    expect(events['Other']!.labels, isNot(contains(_key)));
    // The hint changes neither the live alert nor its state.
    final alerts = {
      for (final row in await session.db.unsafeQuery(
        '''SELECT fingerprint, status, severity, summary, silent_tombstone,
        "firingSince" IS NOT NULL FROM alerts''',
      ))
        row[0]! as String: row.sublist(1),
    };
    expect(
      alerts.keys,
      unorderedEquals([
        for (final event in events.values) event.fingerprint,
      ]),
    );
    final classified = alerts[watchdog.fingerprint]!;
    final plain = alerts[events['Other']!.fingerprint]!;
    expect(classified[0], plain[0], reason: 'status');
    expect(classified[1], plain[1], reason: 'severity');
    expect(classified[3], plain[3], reason: 'silent tombstone');
    expect(classified[4], plain[4], reason: 'firing since set');
    expect(classified[2], watchdog.summary);
    // The hint changes no delivery: both alerts reach the source's output,
    // and the Watchdog delivery carries the stored event, hint included.
    final deliveries = {
      for (final row in await session.db.unsafeQuery(
        '''SELECT outbox.event_id::text, outbox.output_id::text,
        outbox.payload = events.payload FROM outbox
        JOIN events ON events.event_id = outbox.event_id
          AND events.observed_at = outbox.event_observed_at
          AND events.disposition = outbox.event_disposition''',
      ))
        row[0]! as String: row.sublist(1),
    };
    expect(
      deliveries.keys,
      unorderedEquals([for (final event in events.values) event.eventId]),
    );
    for (final delivery in deliveries.values) {
      expect(delivery, [_output, true]);
    }
  });

  _dbTest('a_snapshot_pinned_before_the_change_keeps_running', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final worker = _worker(session);
    // The previous binary published and pinned a row to content that writes the
    // key with set_label. Its stored matcher is rewritten to that content, then
    // the upgrade (step 15 and the fill) runs.
    final old = await _publish(
      session,
      1,
      null,
      _matcher(_benign),
      source: true,
    );
    await _insertRaw(session, 1, 'pinned');
    expect(await worker.pinOne(), isTrue);
    await _rewriteStoredMatcher(
      session,
      old.snapshotId,
      _matcher([_write('legacy')]),
    );
    await _rewindToBeforeStep15(session);
    await initializeIngestSchema(session);
    // New content can still be published; the pinned row keeps its snapshot.
    await _publish(session, 2, old.snapshotId, _matcher(_benign), source: true);
    expect(await worker.processOne(), isTrue);
    final event = (await _events(session)).single;
    expect(event.labels, containsPair(_key, 'legacy'));
    expect(event.labelsOrigin, containsPair(_key, 'matcher'));
    expect(event.kind, EventKind.alert);
  });

  _dbTest('upgrade_with_a_file_that_writes_the_reserved_key', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final old = await _installPreChange(
      session,
      _config(1, null, _matcher(_benign)),
    );
    await _rewindToBeforeStep15(session);
    await initializeIngestSchema(session);
    final directory = await Directory.systemTemp.createTemp(
      'correlia-reserved-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ingest.yaml');
    Future<IngestBootstrap?> load() => IngestBootstrap.load(
      {'CORRELIA_INGEST_CONFIG': file.path},
      runMode: 'test',
      publish: (config, secrets) =>
          _repository(session).publishConfig(config, secrets, runMode: 'test'),
    );
    for (final (action, field) in [
      (
        '{type: set_label, key: $_key, value: heartbeat}',
        'matcher.rules[0].actions[0].key',
      ),
      (
        '{type: extract, field: summary, pattern: "(.+)", group: 1, key: $_key}',
        'matcher.rules[0].actions[0].key',
      ),
    ]) {
      await file.writeAsString('''
format_version: 2
revision: 2
expected_active_snapshot: "${old.snapshotId}"
sources: []
outputs: []
matcher:
  language: matcher
  version: 1
  rules:
    - id: example
      when: {field: summary, op: exists}
      actions:
        - $action
''');
      await expectLater(load(), throwsA(_reservedKeyError(field)));
      expect(
        (await _repository(session).activeSnapshot())?['snapshotId'],
        old.snapshotId,
      );
    }
    expect(await _count(session, 'ingest_config_snapshot'), 1);
  });

  _dbTest('exact_restart_with_a_pre_change_file_that_writes_the_reserved_key', (
    builder,
  ) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final directory = await Directory.systemTemp.createTemp(
      'correlia-reserved-',
    );
    addTearDown(() => directory.delete(recursive: true));
    // One file on disk, unchanged across the upgrade.
    final file = File('${directory.path}/ingest.yaml');
    await file.writeAsString('''
format_version: 2
revision: 1
sources: []
outputs: []
matcher:
  language: matcher
  version: 1
  rules:
    - id: example
      when: {field: summary, op: exists}
      actions:
        - {type: set_label, key: $_key, value: legacy}
''');
    Future<IngestBootstrap?> start(
      Future<IngestBootstrap> Function(Object? config) publish,
    ) => IngestBootstrap.load(
      {'CORRELIA_INGEST_CONFIG': file.path},
      runMode: 'test',
      publish: (config, secrets) => publish(config),
    );
    // The previous binary started from the file and stored this snapshot.
    // The ID and JSON are what revision 1bfa471's IngestBootstrap.parse
    // produced for the file, frozen here so that a change to today's parser
    // cannot make the test agree with itself.
    const frozenId =
        '9a0f6d9e884e950c5f0014202f2b785a600f472272160c4f5d4d3518a07fb730';
    const frozenJson =
        '{"format_version":2,"revision":1,"sources":[],"outputs":[],'
        '"matcher":{"language":"matcher","rules":[{"actions":[{"key":'
        '"correlia.noise_class","type":"set_label","value":"legacy"}],'
        '"id":"example","when":{"field":"summary","op":"exists"}}],'
        '"version":1}}';
    await _asPublisher(session, (transaction) async {
      await session.db.unsafeExecute(
        '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
        VALUES (@id,1,@json)''',
        parameters: QueryParameters.named({
          'id': frozenId,
          'json': frozenJson,
        }),
        transaction: transaction,
      );
      await session.db.unsafeExecute(
        'INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@id)',
        parameters: QueryParameters.named({'id': frozenId}),
        transaction: transaction,
      );
    });
    await _rewindToBeforeStep15(session);
    await initializeIngestSchema(session);
    // This binary starts from the same file through the startup path.
    final restarted = (await start(
      (config) => _repository(
        session,
      ).publishConfig(config, const <String, Object?>{}, runMode: 'test'),
    ))!;
    expect(restarted.snapshotId, frozenId);
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      frozenId,
    );
    expect(await _count(session, 'ingest_config_snapshot'), 1);
  });

  _dbTest('exact_restart_with_an_active_classify_snapshot', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final directory = await Directory.systemTemp.createTemp(
      'correlia-classify-',
    );
    addTearDown(() => directory.delete(recursive: true));
    // One file, unchanged across the restart: JSON is valid YAML.
    final file = File('${directory.path}/ingest.yaml');
    await file.writeAsString(
      jsonEncode(
        _config(
          1,
          null,
          _matcher(
            [
              {'type': 'classify', 'value': 'heartbeat'},
            ],
            when: const {
              'field': 'labels.alertname',
              'op': 'equals',
              'value': 'Watchdog',
            },
          ),
          source: true,
        ),
      ),
    );
    Future<IngestBootstrap> start() async => (await IngestBootstrap.load(
      {'CORRELIA_INGEST_CONFIG': file.path},
      runMode: 'test',
      publish: (config, secrets) => _repository(
        session,
      ).publishConfig(config, _reserved, runMode: 'test'),
    ))!;
    final first = await start();
    // The restart: the schema steps run again, then the same file loads.
    await initializeIngestSchema(session);
    final restarted = await start();
    expect(restarted.snapshotId, first.snapshotId);
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      first.snapshotId,
    );
    expect(await _count(session, 'ingest_config_snapshot'), 1);
    // The snapshot still classifies after the restart.
    await _insertRaw(session, 1, 'Watchdog');
    final worker = _worker(session);
    expect(await worker.pinOne(), isTrue);
    expect(await worker.processOne(), isTrue);
    final event = (await _events(session)).single;
    expect(event.labels, containsPair(_key, 'heartbeat'));
    expect(event.labelsOrigin, containsPair(_key, 'matcher'));
  });

  _dbTest('an_ordinary_pre_upgrade_snapshot_restarts_and_still_applies', (
    builder,
  ) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final directory = await Directory.systemTemp.createTemp(
      'correlia-ordinary-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final matcher = _matcher(
      _benign,
      when: const {
        'field': 'labels.alertname',
        'op': 'equals',
        'value': 'Watchdog',
      },
    );
    (matcher['rules']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .single['id'] =
        'ordinary';
    // One file, unchanged across the upgrade: JSON is valid YAML.
    final file = File('${directory.path}/ingest.yaml');
    await file.writeAsString(
      jsonEncode(_config(1, null, matcher, source: true)),
    );
    // The previous binary stored this snapshot for the file. The ID and JSON
    // are what revision 1bfa471's IngestBootstrap.parse produced, frozen here
    // so that today's parser cannot make the test agree with itself. Its
    // matcher writes no reserved key.
    const frozenId =
        '472f3f10b07431260a4ae08a6fa9746fbc13dae85b8a36ef170b19956fdf0357';
    const frozenJson =
        '{"format_version":2,"revision":1,"sources":[{"id":"bbbbbbbb-'
        'bbbb-4bbb-8bbb-777777777777","kind":"alertmanager","namespac'
        'e":"bbbbbbbb-bbbb-4bbb-8bbb-777777777777","enabled":true,"cr'
        'edentials":[{"ref":"reserved-token","type":"bearer","digest"'
        ':"4bb06f8e4e3a7715d201d573d0aa423762e55dabd61a2c02278fa56cc6'
        'd294e0"}],"path_token_enabled":false,"body_limit_bytes":1048'
        '576,"rate_limit":{"per_second":20,"burst":40},"excluded_iden'
        'tity_labels":[],"output_ids":[]}],"outputs":[],"matcher":{"l'
        'anguage":"matcher","rules":[{"actions":[{"key":"team","type"'
        ':"set_label","value":"ops"}],"id":"ordinary","when":{"field"'
        ':"labels.alertname","op":"equals","value":"Watchdog"}}],"ver'
        'sion":1}}';
    await _asPublisher(session, (transaction) async {
      await session.db.unsafeExecute(
        '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
        VALUES (@id,1,@json)''',
        parameters: QueryParameters.named({'id': frozenId, 'json': frozenJson}),
        transaction: transaction,
      );
      await session.db.unsafeExecute(
        'INSERT INTO ingest_active_config (singleton,"snapshotId") VALUES (1,@id)',
        parameters: QueryParameters.named({'id': frozenId}),
        transaction: transaction,
      );
    });
    await _rewindToBeforeStep15(session);
    await initializeIngestSchema(session);
    // This binary starts from the same file and republishes it through the
    // repository.
    final restarted = (await IngestBootstrap.load(
      {'CORRELIA_INGEST_CONFIG': file.path},
      runMode: 'test',
      publish: (config, secrets) => _repository(
        session,
      ).publishConfig(config, _reserved, runMode: 'test'),
    ))!;
    expect(restarted.snapshotId, frozenId);
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      frozenId,
    );
    expect(await _count(session, 'ingest_config_snapshot'), 1);
    // The stored rule still applies.
    await _insertRaw(session, 1, 'Watchdog');
    final worker = _worker(session);
    expect(await worker.pinOne(), isTrue);
    expect(await worker.processOne(), isTrue);
    final event = (await _events(session)).single;
    expect(event.labels, containsPair('team', 'ops'));
    expect(event.labelsOrigin, containsPair('team', 'matcher'));
  });

  _dbTest('an_older_binary_publishing_after_the_fill_stores_its_content', (
    builder,
  ) async {
    final session = builder.build();
    Future<int> watermark() async =>
        (await session.db.unsafeQuery(
              'SELECT filled_through FROM matcher_content_digest_fill',
            )).single[0]!
            as int;
    Future<int> lastSnapshot() async =>
        (await session.db.unsafeQuery(
              'SELECT max(id) FROM ingest_config_snapshot',
            )).single[0]!
            as int;
    // This release ran, published once and restarted, so the startup fill
    // has read that snapshot and the watermark is past zero.
    await initializeIngestSchema(session);
    await _publish(session, 1, null, _matcher(_benign));
    await initializeIngestSchema(session);
    final before = await watermark();
    expect(before, await lastSnapshot());
    expect(before, greaterThan(0));
    expect(await _count(session, 'matcher_content_digest'), 1);
    final directory = await Directory.systemTemp.createTemp(
      'correlia-reserved-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ingest.yaml');
    await file.writeAsString('''
format_version: 2
revision: 2
sources: []
outputs: []
matcher:
  language: matcher
  version: 1
  rules:
    - id: downgraded
      when: {field: summary, op: exists}
      actions:
        - {type: set_label, key: $_key, value: legacy}
''');
    Future<IngestBootstrap?> start(
      Future<IngestBootstrap> Function(Object? config) publish,
    ) => IngestBootstrap.load(
      {'CORRELIA_INGEST_CONFIG': file.path},
      runMode: 'test',
      publish: (config, secrets) => publish(config),
    );
    // An offline downgrade: the previous binary publishes the file.
    final old = (await start((config) => _installPreChange(session, config)))!;
    expect(await lastSnapshot(), greaterThan(before));
    // This release starts again. Its schema step fills the suffix before
    // the configuration file is read: the old binary's content is recorded
    // and the watermark moves past it.
    await initializeIngestSchema(session);
    expect(await _count(session, 'matcher_content_digest'), 2);
    expect(await watermark(), await lastSnapshot());
    final restarted = (await start(
      (config) => _repository(
        session,
      ).publishConfig(config, const <String, Object?>{}, runMode: 'test'),
    ))!;
    expect(restarted.snapshotId, old.snapshotId);
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      old.snapshotId,
    );
  });

  _dbTest('rollback_to_pre_change_content_that_writes_the_reserved_key', (
    builder,
  ) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final writer = _matcher([_write('legacy')]);
    final old = await _installPreChange(session, _config(1, null, writer));
    await _rewindToBeforeStep15(session);
    await initializeIngestSchema(session);
    final next = await _publish(session, 2, old.snapshotId, _matcher(_benign));
    // A guarded rollback at a higher revision to earlier content succeeds.
    final restored = await _publish(session, 3, next.snapshotId, writer);
    expect(restored.snapshotId, isNot(old.snapshotId));
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      restored.snapshotId,
    );
    // Different content that writes the key is still new.
    await expectLater(
      _publish(
        session,
        4,
        restored.snapshotId,
        _matcher([_write('different')]),
      ),
      throwsA(_reservedKeyError('matcher.rules[0].actions[0].key')),
    );
  });

  _dbTest('pinned_pre_change_snapshot_keeps_running', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final worker = _worker(session);
    // The same flow with an extract action and the digest tables already empty.
    final old = await _publish(
      session,
      1,
      null,
      _matcher(_benign),
      source: true,
    );
    await _insertRaw(session, 1, 'extracted-value');
    expect(await worker.pinOne(), isTrue);
    await _rewriteStoredMatcher(
      session,
      old.snapshotId,
      _matcher([_write('', type: 'extract')]),
    );
    await _rewindToBeforeStep15(session);
    await initializeIngestSchema(session);
    expect(await worker.processOne(), isTrue);
    final event = (await _events(session)).single;
    expect(event.labels, containsPair(_key, 'extracted-value'));
    expect(event.labelsOrigin, containsPair(_key, 'matcher'));
  });

  _dbTest('a_digest_cannot_outlive_the_snapshot_it_names', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final base = await _publish(session, 1, null, _matcher(_benign));
    final legacy = _matcher([_write('legacy')]);
    await _insertSnapshot(session, 'legacy-only', 1000001, legacy);
    await initializeIngestSchema(session);
    expect(await _count(session, 'matcher_content_digest'), 2);
    // The database refuses to delete the snapshot while its digest exists.
    await expectLater(
      _deleteSnapshot(session, 'legacy-only'),
      throwsA(_foreignKeyViolation),
    );
    // Removing the digest first lets the snapshot go, and its content is new
    // again: it no longer passes as a restore.
    await session.db.unsafeSimpleExecute(
      "DELETE FROM matcher_content_digest WHERE first_snapshot_id='legacy-only'",
    );
    await _deleteSnapshot(session, 'legacy-only');
    await expectLater(
      _publish(session, 2, base.snapshotId, legacy),
      throwsA(_reservedKeyError('matcher.rules[0].actions[0].key')),
    );
  });

  _dbTest('upgrade_removes_digests_whose_snapshot_is_gone', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final base = await _publish(session, 1, null, _matcher(_benign));
    final kept = _matcher([_write('kept')]);
    final lost = _matcher([_write('lost')]);
    // Two snapshots share `kept`; the digest names the first. `lost` has one.
    await _insertSnapshot(session, 'kept-first', 1000001, kept);
    await _insertSnapshot(session, 'kept-second', 1000002, kept);
    await _insertSnapshot(session, 'lost-only', 1000003, lost);
    await initializeIngestSchema(session);
    expect(await _count(session, 'matcher_content_digest'), 3);
    // A database from before step 17, where both snapshots a digest names
    // were deleted by hand.
    await session.db.unsafeSimpleExecute('''
ALTER TABLE matcher_content_digest
  DROP CONSTRAINT matcher_content_digest_first_snapshot_fk;
DELETE FROM correlia_schema_versions WHERE version = 17''');
    await _deleteSnapshot(session, 'kept-first');
    await _deleteSnapshot(session, 'lost-only');
    await initializeIngestSchema(session);
    // Both orphans are gone, and the fill read every snapshot again, so the
    // content a surviving snapshot holds is recorded under it.
    final rows = await session.db.unsafeQuery(
      'SELECT first_snapshot_id FROM matcher_content_digest ORDER BY 1',
    );
    expect(
      [for (final row in rows) row[0]],
      [
        base.snapshotId,
        'kept-second',
      ]..sort(),
    );
    await expectLater(
      _deleteSnapshot(session, 'kept-second'),
      throwsA(_foreignKeyViolation),
    );
    // Surviving content still restores; content with no snapshot left is new.
    final restored = await _publish(session, 2, base.snapshotId, kept);
    await expectLater(
      _publish(session, 3, restored.snapshotId, lost),
      throwsA(_reservedKeyError('matcher.rules[0].actions[0].key')),
    );
  });

  _dbTest('upgrade_with_an_unreadable_inactive_snapshot', (builder) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final legacy = _matcher([_write('legacy')]);
    await _insertSnapshot(session, 'readable-history', 1000001, legacy);
    await _asPublisher(
      session,
      (transaction) => session.db.unsafeExecute(
        '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
        VALUES ('unreadable', 1000002, '{"matcher": secret-text')''',
        transaction: transaction,
      ),
    );
    final base = await _publish(session, 1, null, _matcher(_benign));
    await _rewindToBeforeStep15(session);
    final skipped = <String>[];
    // The upgrade fills every readable snapshot and skips the damaged one.
    await initializeSchema(session, onUnreadableSnapshot: skipped.add);
    expect(skipped, ['unreadable']);
    expect(await _count(session, 'matcher_content_digest'), 2);
    expect(await _count(session, 'matcher_content_digest_fill'), 1);
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      base.snapshotId,
    );
    // A later start does not read it again, and readable content restores.
    await initializeSchema(session, onUnreadableSnapshot: skipped.add);
    expect(skipped, ['unreadable']);
    final restored = await _publish(session, 2, base.snapshotId, legacy);
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      restored.snapshotId,
    );
  });

  _dbTest('a_long_history_of_distinct_content_keeps_one_probe', (
    builder,
  ) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final base = await _publish(session, 1, null, _matcher(_benign));
    final history = await _insertHistory(session, 5000);
    await _rewindToBeforeStep15(session);
    final pages = <int>[];
    await initializeSchema(session, onFillPageForTest: pages.add);
    // 5001 snapshots in keyset pages of 100.
    expect(pages, [...List.filled(50, 100), 1]);
    expect(await _count(session, 'matcher_content_digest'), 5001);
    expect(await _count(session, 'matcher_content_digest_fill'), 1);
    await session.db.unsafeSimpleExecute('ANALYZE matcher_content_digest');
    final plan = (await session.db.unsafeQuery(
      'EXPLAIN $matcherDigestLookupSql',
      parameters: QueryParameters.named({
        'digest': matcherContentDigest(_stored(history[2500])),
      }),
    )).map((row) => row[0]! as String).join('\n');
    expect(
      plan,
      matches(RegExp(r'Index (Only )?Scan using matcher_content_digest_pkey')),
    );
    expect(plan, isNot(contains('Seq Scan')));
    // Restoring earlier distinct content succeeds through real publication.
    final restored = await _publish(session, 2, base.snapshotId, history[2500]);
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      restored.snapshotId,
    );
    expect(await _count(session, 'matcher_content_digest'), 5001);
    // New content that writes the key is rejected.
    await expectLater(
      _publish(
        session,
        3,
        restored.snapshotId,
        _matcher([_write('brand-new')]),
      ),
      throwsA(_reservedKeyError('matcher.rules[0].actions[0].key')),
    );
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      restored.snapshotId,
    );
  });

  _dbTest('upgrade_with_a_nul_in_a_plugin_configuration_and_a_matcher_operand', (
    builder,
  ) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final worker = _worker(session);
    // An inactive snapshot whose matcher compares with an encoded NUL, pinned by
    // a row that has not run yet.
    final nul = await _publish(
      session,
      1,
      null,
      _matcher(
        _benign,
        when: {'field': 'summary', 'op': 'equals', 'value': '\u0000'},
      ),
      source: true,
    );
    await _insertRaw(session, 1, 'nul-operand');
    expect(await worker.pinOne(), isTrue);
    await _publish(session, 2, nul.snapshotId, _matcher(_benign), source: true);
    // An inactive snapshot with U+0000 in a plugin configuration: the JSON
    // escape cannot become jsonb.
    final plugin = jsonEncode({
      'format_version': 2,
      'revision': 1000000,
      'sources': <Object?>[],
      'outputs': [
        {
          'id': '33333333-3333-4333-8333-333333333333',
          'kind': 'plugin',
          'config': {'token': '\u0000'},
        },
      ],
    });
    expect(plugin, contains(r'\u0000'));
    await _asPublisher(
      session,
      (transaction) => session.db.unsafeExecute(
        '''INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
        VALUES ('plugin-nul',1000000,@json)''',
        parameters: QueryParameters.named({'json': plugin}),
        transaction: transaction,
      ),
    );
    await expectLater(
      session.db.unsafeQuery(
        '''SELECT "publicJson"::jsonb FROM ingest_config_snapshot
        WHERE "snapshotId"='plugin-nul' ''',
      ),
      throwsA(anything),
    );
    await _rewindToBeforeStep15(session);
    await initializeIngestSchema(session);
    expect(await _count(session, 'matcher_content_digest_fill'), 1);
    // The row pinned to the NUL-operand snapshot runs through the worker.
    expect(await worker.processOne(), isTrue);
    expect(await _events(session), hasLength(1));
    expect(await _count(session, 'matcher_failure'), 0);
  });

  _dbTest('a_fill_interrupted_after_some_inserts_restarts_and_restores', (
    builder,
  ) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final base = await _publish(session, 1, null, _matcher(_benign));
    final history = await _insertHistory(session, 300);
    await _rewindToBeforeStep15(session);
    await expectLater(
      initializeSchema(
        session,
        afterFillInsertForTest: (inserted) async {
          if (inserted == 150) throw StateError('injected failure');
        },
      ),
      throwsA(
        isA<SchemaStepException>()
            .having((e) => e.version, 'version', 15)
            .having((e) => e.failureClass, 'class', SchemaFailureClass.failed),
      ),
    );
    // The whole fill rolled back: no digest and no completion row.
    expect(await _count(session, 'matcher_content_digest'), 0);
    expect(await _count(session, 'matcher_content_digest_fill'), 0);
    // The next start fills again, and a snapshot the failed run never reached
    // restores.
    await initializeIngestSchema(session);
    expect(await _count(session, 'matcher_content_digest'), 301);
    final restored = await _publish(session, 2, base.snapshotId, history.last);
    expect(
      (await _repository(session).activeSnapshot())?['snapshotId'],
      restored.snapshotId,
    );
  });

  _dbTest('a_publication_that_finds_no_completion_row_fills_first', (
    builder,
  ) async {
    final session = builder.build();
    await initializeIngestSchema(session);
    final base = await _publish(session, 1, null, _matcher(_benign));
    final history = await _insertHistory(session, 250);
    await _rewindToBeforeStep15(session);
    for (final file in [
      'schema/0015_matcher_content_digest.sql',
      'schema/0016_matcher_digest_watermark.sql',
      'schema/0017_matcher_digest_snapshot_fk.sql',
    ]) {
      await session.db.unsafeSimpleExecute(File(file).readAsStringSync());
    }
    await session.db.unsafeSimpleExecute(
      'INSERT INTO correlia_schema_versions (version) VALUES (15), (16), (17)',
    );
    expect(await _count(session, 'matcher_content_digest_fill'), 0);
    final restored = await _publish(session, 2, base.snapshotId, history[249]);
    expect(restored.snapshotId, isNotEmpty);
    expect(await _count(session, 'matcher_content_digest_fill'), 1);
    // The restore repeats stored content, so it adds no digest.
    expect(await _count(session, 'matcher_content_digest'), 251);
  });

  _dbTest(
    'a_concurrent_starter_waits_on_the_lock_and_finds_the_completion_row',
    (
      builder,
    ) async {
      final first = builder.build();
      final second = builder.build();
      final observer = builder.build();
      await initializeIngestSchema(first);
      await _publish(first, 1, null, _matcher(_benign));
      await _insertHistory(first, 250);
      await _rewindToBeforeStep15(first);
      final inFill = Completer<void>();
      final release = Completer<void>();
      final firstPages = <int>[];
      final secondPages = <int>[];
      final starter = initializeSchema(
        first,
        onFillPageForTest: firstPages.add,
        beforeFillCompletionForTest: () async {
          inFill.complete();
          await release.future;
        },
      );
      await inFill.future;
      final waiter = initializeSchema(
        second,
        onFillPageForTest: secondPages.add,
      );
      await _waitForLockWaiter(observer);
      release.complete();
      await Future.wait([starter, waiter]);
      expect(firstPages, [100, 100, 51]);
      expect(secondPages, isEmpty, reason: 'the second starter found the row');
      expect(await _count(first, 'matcher_content_digest_fill'), 1);
      expect(await _count(first, 'matcher_content_digest'), 251);
    },
  );

  _dbTest('a_starter_that_times_out_on_the_lock_fails_with_lock_timeout', (
    builder,
  ) async {
    final holder = builder.build();
    final starter = builder.build();
    await initializeIngestSchema(holder);
    final acquired = Completer<void>();
    final release = Completer<void>();
    final holding = holder.db.transaction((transaction) async {
      await holder.db.unsafeQuery(
        'SELECT pg_advisory_xact_lock($publicationLockKey)',
        transaction: transaction,
      );
      acquired.complete();
      await release.future;
    });
    try {
      await acquired.future;
      await expectLater(
        initializeSchema(
          starter,
          fillLockTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<SchemaStepException>()
              .having((e) => e.version, 'version', 15)
              .having(
                (e) => e.failureClass,
                'class',
                SchemaFailureClass.lockTimeout,
              )
              .having(
                (e) => e.toString(),
                'text',
                'Schema step 15 failed: lock_timeout',
              ),
        ),
      );
    } finally {
      release.complete();
      await holding;
    }
    // The next start retries and succeeds.
    await initializeIngestSchema(starter);
  });
}
