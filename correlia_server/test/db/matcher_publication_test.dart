import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/admission.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/database.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/decoder.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/lease.dart';
import 'package:correlia_server/src/matcher/matcher_document.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_pipeline.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/icinga2_stream_pipeline.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/event/fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;

const _removedOutput = '22222222-2222-4222-8222-222222222222';

Map<String, Object?> _config(int revision) => {
  'format_version': 2,
  'revision': revision,
  'sources': <Object?>[],
  'outputs': <Object?>[],
};

Map<String, Object?> _section({
  Object? version = 1,
  Object? when = const {'field': 'summary', 'op': 'exists'},
  Object? actions = const [
    {'type': 'set_label', 'key': 'team', 'value': 'ops'},
  ],
}) => {
  'language': 'matcher',
  'version': ?version,
  'rules': [
    {'id': 'example', 'when': when, 'actions': actions},
  ],
};

void main() {
  withServerpod(
    'matcher publication',
    (builder, _) {
      test('typed version survives and rejects unknown', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final input = _config(1)
          ..['expected_active_snapshot'] = null
          ..['matcher'] = _section();
        final published = await repository.publishConfig(
          input,
          const <String, Object?>{},
          runMode: 'test',
        );
        expect(published.publicJson, contains('"language":"matcher"'));
        for (final version in [null, 2]) {
          final invalid = _config(3)
            ..['expected_active_snapshot'] = published.snapshotId
            ..['matcher'] = _section(version: version);
          await expectLater(
            repository.publishConfig(
              invalid,
              const <String, Object?>{},
              runMode: 'test',
            ),
            throwsA(isA<BootstrapError>()),
          );
          expect(
            (await repository.activeSnapshot())?['snapshotId'],
            published.snapshotId,
          );
        }
      });

      test('DUR-5 unknown output and empty registry', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final active = (await repository.activeSnapshot())?['snapshotId'];
        final candidate = _config(4)
          ..['expected_active_snapshot'] = active
          ..['matcher'] = _section(
            actions: const [
              {'type': 'route', 'output_id': _removedOutput},
            ],
          );
        await expectLater(
          repository.publishConfig(
            candidate,
            const <String, Object?>{},
            runMode: 'test',
          ),
          throwsA(
            isA<BootstrapError>()
                .having((error) => error.code, 'code', 'unknown_output')
                .having(
                  (error) => error.toString(),
                  'diagnostic',
                  contains(_removedOutput),
                ),
          ),
        );
        expect((await repository.activeSnapshot())?['snapshotId'], active);
      });

      test('guarded YAML rollback restarts identically', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final active = await repository.activeSnapshot();
        final first = ((active?['revision'] as int?) ?? 0) + 1;
        final directory = await Directory.systemTemp.createTemp(
          'correlia-matcher-yaml-',
        );
        final file = File('${directory.path}/ingest.yaml');
        Future<IngestBootstrap> load() async => (await IngestBootstrap.load(
          {'CORRELIA_INGEST_CONFIG': file.path},
          runMode: 'test',
          publish: (config, secrets) =>
              repository.publishConfig(config, secrets, runMode: 'test'),
        ))!;
        Future<IngestBootstrap> publish(
          int revision,
          String? expected,
          String label,
        ) async {
          await file.writeAsString('''
format_version: 2
revision: $revision
expected_active_snapshot: ${expected == null ? 'null' : '"$expected"'}
sources: []
outputs: []
matcher:
  language: matcher
  version: 1
  rules:
    - id: example
      when: {field: summary, op: exists}
      actions:
        - {type: set_label, key: team, value: "$label"}
''');
          return load();
        }

        try {
          final a = await publish(
            first,
            active?['snapshotId'] as String?,
            'original',
          );
          final b = await publish(first + 1, a.snapshotId, 'new');
          final rollback = await publish(first + 2, b.snapshotId, 'original');
          final restart = await load();
          expect(restart.snapshotId, rollback.snapshotId);
          expect(restart.matcher.snapshotJson, a.matcher.snapshotJson);
          expect((await repository.activeSnapshot())?['revision'], first + 2);
        } finally {
          await directory.delete(recursive: true);
        }
      });

      test('invalid operands leave active unchanged', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final active = await repository.activeSnapshot();
        final revision = ((active?['revision'] as int?) ?? 0) + 1;
        for (final when in [
          {'field': 'not_in_catalog', 'op': 'exists'},
          {'field': 'labels.invalid key', 'op': 'exists'},
          {'field': 'severity', 'op': 'equals', 'value': 'almost'},
          for (final op in ['regex', 'glob'])
            {'field': 'summary', 'op': op, 'value': jsonDecode(r'"\ud800"')},
        ]) {
          final input = _config(revision)
            ..['expected_active_snapshot'] = active?['snapshotId']
            ..['matcher'] = _section(when: when);
          await expectLater(
            repository.publishConfig(
              input,
              const <String, Object?>{},
              runMode: 'test',
            ),
            throwsA(
              isA<BootstrapError>().having(
                (e) => e.field,
                'field',
                'matcher.rules[0].when',
              ),
            ),
          );
          expect(
            (await repository.activeSnapshot())?['snapshotId'],
            active?['snapshotId'],
          );
        }
      });

      test('reject nonportable regex at publication', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final active = await repository.activeSnapshot();
        final revision = ((active?['revision'] as int?) ?? 0) + 1;
        for (final pattern in [
          r'(a)\1',
          'a(?=b)',
          '(?i)z',
          r'\d',
          'a{256}',
          '((a{255}){255}){255}|b',
        ]) {
          final input = _config(revision)
            ..['expected_active_snapshot'] = active?['snapshotId']
            ..['matcher'] = _section(
              when: {'field': 'summary', 'op': 'regex', 'value': pattern},
            );
          await expectLater(
            repository.publishConfig(
              input,
              const <String, Object?>{},
              runMode: 'test',
            ),
            throwsA(
              isA<BootstrapError>().having(
                (e) => e.field,
                'field',
                'matcher.rules[0].when',
              ),
            ),
          );
          expect(
            (await repository.activeSnapshot())?['snapshotId'],
            active?['snapshotId'],
          );
        }
      });

      test('matcher-only historical secret import', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final active = await repository.activeSnapshot();
        final first = ((active?['revision'] as int?) ?? 0) + 1;
        const source = '33333333-3333-4333-8333-333333333333';
        String secret(int byte) =>
            base64Url.encode(List<int>.filled(32, byte)).replaceAll('=', '');
        final sources = [
          {
            'id': source,
            'kind': 'alertmanager',
            'enabled': true,
            'credentials': [
              {'type': 'bearer', 'ref': 'token'},
            ],
            'output_ids': <Object?>[],
          },
        ];
        final original = await repository.publishConfig(
          _config(first)
            ..['expected_active_snapshot'] = active?['snapshotId']
            ..['sources'] = sources
            ..['outputs'] = [
              {
                'id': _removedOutput,
                'kind': 'webhook',
                'url': 'http://127.0.0.1:8089/events',
                'signing_key_ref': 'historical-key',
              },
            ]
            ..['matcher'] = _section(
              actions: const [
                {'type': 'route', 'output_id': _removedOutput},
              ],
            ),
          <String, Object?>{'token': secret(1), 'historical-key': secret(2)},
          runMode: 'test',
        );
        final overCapacity = _config(first + 2)
          ..['sources'] = sources
          ..['outputs'] = [
            for (var i = 0; i < 64; i++)
              {
                'id':
                    'aaaaaaaa-aaaa-4aaa-8aaa-${i.toString().padLeft(12, '0')}',
                'kind': 'webhook',
                'url': 'http://127.0.0.1:8089/new',
                'signing_key_ref': 'new-route-key',
              },
          ];
        Future<void> refused() => expectLater(
          repository.publishConfig(overCapacity, <String, Object?>{
            'new-route-key': secret(4),
          }, runMode: 'test'),
          throwsA(
            isA<BootstrapError>().having(
              (e) => e.code,
              'code',
              'retained_output_bound',
            ),
          ),
        );
        final body = utf8.encode(
          jsonEncode(
            payload.groupOf([payload.alert(startsAt: '2026-11-01T00:00:00Z')]),
          ),
        );
        await session.db.unsafeExecute(
          '''
INSERT INTO raw_inbox (observed_at, raw_id, source_id, body, body_sha256, content_type)
VALUES ('2026-11-01T00:00:00Z', '$source', '$source', @body, @digest, 'application/json')
''',
          parameters: QueryParameters.named({
            'body': body,
            'digest': sha256.convert(body).toString(),
          }),
        );
        final pinned = Completer<void>();
        final releasePin = Completer<void>();
        final observer = builder.build();
        final publishing = IngestConfigRepository(
          builder.build(),
          secretStore: testSecretStore,
        );
        final worker = PipelineRepository(
          session,
          elapsedForTest: () => Duration.zero,
          beforePinCommitForTest: (_) async {
            pinned.complete();
            await releasePin.future;
          },
        );
        final pinning = worker.pinOne();
        try {
          await pinned.future;
          await expectLater(
            observer.db.unsafeSimpleQuery(
              'SELECT singleton FROM ingest_active_config WHERE singleton=1 FOR UPDATE NOWAIT',
            ),
            throwsA(
              isA<DatabaseQueryException>().having(
                (e) => e.code,
                'code',
                '55P03',
              ),
            ),
          );
          final racing = expectLater(
            publishing.publishConfig(
              overCapacity..['expected_active_snapshot'] = original.snapshotId,
              <String, Object?>{'new-route-key': secret(4)},
              runMode: 'test',
            ),
            throwsA(
              isA<BootstrapError>().having(
                (e) => e.code,
                'code',
                'retained_output_bound',
              ),
            ),
          );
          releasePin.complete();
          expect(await pinning, isTrue);
          await racing;
          overCapacity.remove('expected_active_snapshot');
        } finally {
          if (!releasePin.isCompleted) releasePin.complete();
          await pinning;
        }
        final replacement = _config(first + 1)
          ..['expected_active_snapshot'] = original.snapshotId
          ..['sources'] = sources;
        Future<List<Object?>>
        referenceCounts() async => (await session.db.unsafeQuery(
          "SELECT pinned_count,live_count FROM pipeline_output_commitment WHERE reference='historical-key'",
        )).single.toList();
        expect(await referenceCounts(), [1, 0]);
        Future<IngestBootstrap> publish(int byte) => repository.publishConfig(
          replacement,
          <String, Object?>{'historical-key': secret(byte)},
          runMode: 'test',
        );
        await expectLater(
          publish(3),
          throwsA(
            isA<BootstrapError>().having(
              (e) => e.code,
              'code',
              'reference_rebound',
            ),
          ),
        );
        expect(
          (await repository.activeSnapshot())?['snapshotId'],
          original.snapshotId,
        );
        final replaced = await publish(2);
        expect(replaced.snapshotId, isNot(original.snapshotId));
        await refused();
        expect(
          await PipelineRepository(
            session,
            clock: () => DateTime.utc(2026, 11, 1),
            elapsedForTest: () => Duration.zero,
          ).processOne(),
          isTrue,
        );
        expect(
          (await session.db.unsafeSimpleQuery(
            "SELECT status, outcome_json FROM raw_inbox WHERE raw_id='$source'",
          )).single[0],
          'done',
        );
        final historicalOutput = original.outputs.single as WebhookIngestOutput;
        expect(
          (await session.db.unsafeSimpleQuery('''
SELECT output_id::text, config_snapshot_id, target_url, signing_key_ref,
       signing_key_commitment
FROM outbox WHERE config_snapshot_id = '${original.snapshotId}'
''')).single,
          [
            _removedOutput,
            original.snapshotId,
            historicalOutput.url.toString(),
            historicalOutput.signingKeyRef,
            historicalOutput.signingKeyCommitment,
          ],
        );
        expect(await referenceCounts(), [0, 1]);
        await refused();
        await expectLater(
          publish(3),
          throwsA(
            isA<BootstrapError>().having(
              (e) => e.code,
              'code',
              'reference_rebound',
            ),
          ),
        );
        expect((await publish(2)).snapshotId, replaced.snapshotId);
        expect(
          (await repository.publishConfig(
            replacement,
            const <String, Object?>{},
            runMode: 'test',
          )).snapshotId,
          replaced.snapshotId,
        );
        final rows = await session.db.unsafeSimpleQuery(
          "SELECT config_snapshot_id FROM raw_inbox WHERE raw_id = '$source'",
        );
        expect(rows.single[0], original.snapshotId);

        await session.db.unsafeSimpleExecute(
          "UPDATE outbox SET status='delivered'",
        );
        final restored = await repository.publishConfig(
          _config(first + 3)
            ..['expected_active_snapshot'] = replaced.snapshotId
            ..['sources'] = sources
            ..['outputs'] = [
              {
                'id': _removedOutput,
                'kind': 'webhook',
                'url': 'http://127.0.0.1:8089/events',
                'signing_key_ref': 'historical-key',
              },
            ]
            ..['matcher'] = _section(
              actions: const [
                {'type': 'route', 'output_id': _removedOutput},
              ],
            ),
          const <String, Object?>{},
          runMode: 'test',
        );
        const newRaw = '55555555-5555-4555-8555-555555555555';
        await session.db.unsafeSimpleExecute('''
INSERT INTO raw_inbox (observed_at, raw_id, source_id, body, body_sha256, content_type)
VALUES (now(), '$newRaw', '$source', ''::bytea, 'none', 'application/json')
''');
        final locked = Completer<void>();
        final releasePublication = Completer<void>();
        final publisher = IngestConfigRepository(
          builder.build(),
          secretStore: testSecretStore,
          beforeInventoryForTest: (_) async {
            locked.complete();
            await releasePublication.future;
          },
        );
        final committing = publisher.publishConfig(
          overCapacity
            ..['revision'] = first + 4
            ..['expected_active_snapshot'] = restored.snapshotId,
          <String, Object?>{'new-route-key': secret(4)},
          runMode: 'test',
        );
        try {
          await locked.future;
          final pinAfterPublication = PipelineRepository(observer).pinOne();
          releasePublication.complete();
          final active = await committing;
          expect(await pinAfterPublication, isTrue);
          expect(
            (await observer.db.unsafeSimpleQuery(
              "SELECT config_snapshot_id FROM raw_inbox WHERE raw_id='$newRaw'",
            )).single[0],
            active.snapshotId,
          );
        } finally {
          if (!releasePublication.isCompleted) releasePublication.complete();
          await committing;
        }
      });

      test('RUL-4 pins activation and rollback', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final current = await repository.activeSnapshot();
        final revision = ((current?['revision'] as int?) ?? 0) + 1;
        final firstMatcher = _section();
        const source = 'bbbbbbbb-bbbb-4bbb-8bbb-999999999999';
        final now = DateTime.utc(2026, 11, 1);
        final worker = PipelineRepository(
          session,
          clock: () => now,
          elapsedForTest: () => Duration.zero,
        );
        Future<IngestBootstrap> publish(
          int next,
          Object? expectation,
          Object rules,
        ) => repository.publishConfig(
          _config(next)
            ..['expected_active_snapshot'] = expectation
            ..['sources'] = [
              {
                'id': source,
                'kind': 'alertmanager',
                'enabled': true,
                'output_ids': <String>[],
                'credentials': [
                  {'type': 'bearer', 'ref': 'rollback-token'},
                ],
              },
            ]
            ..['matcher'] = rules,
          {
            'rollback-token': base64Url
                .encode(List<int>.filled(32, 7))
                .replaceAll('=', ''),
          },
          runMode: 'test',
        );
        final first = await publish(
          revision,
          current?['snapshotId'],
          firstMatcher,
        );
        Future<String> pin(int number) async {
          final id =
              'bbbbbbbb-bbbb-4bbb-8bbb-${number.toString().padLeft(12, '0')}';
          final body = utf8.encode(
            jsonEncode(
              payload.groupOf([
                payload.alert(
                  startsAt: now.toIso8601String(),
                  labels: {'alertname': 'rollback-$number'},
                ),
              ]),
            ),
          );
          await session.db.unsafeExecute(
            '''
INSERT INTO raw_inbox (observed_at, raw_id, source_id, body, body_sha256, content_type)
VALUES (@observed, @id::uuid, '$source', @body, @digest, 'application/json')
''',
            parameters: QueryParameters.named({
              'id': id,
              'observed': now,
              'body': body,
              'digest': sha256.convert(body).toString(),
            }),
          );
          expect(await worker.pinOne(), isTrue);
          final rows = await session.db.unsafeQuery(
            'SELECT config_snapshot_id FROM raw_inbox WHERE raw_id=@id::uuid',
            parameters: QueryParameters.named({'id': id}),
          );
          return rows.single[0] as String;
        }

        expect(await pin(1), first.snapshotId);
        final second = await publish(
          revision + 1,
          first.snapshotId,
          _section(
            actions: const [
              {'type': 'team', 'value': 'platform'},
            ],
          ),
        );
        expect(await pin(2), second.snapshotId);
        await expectLater(
          publish(revision + 3, first.snapshotId, second.matcher.snapshotJson),
          throwsA(
            isA<BootstrapError>().having(
              (e) => e.code,
              'code',
              'snapshot_mismatch',
            ),
          ),
        );
        final rollback = await publish(
          revision + 2,
          second.snapshotId,
          firstMatcher,
        );
        expect(await pin(3), rollback.snapshotId);
        final pins = await session.db.unsafeSimpleQuery('''
SELECT config_snapshot_id FROM raw_inbox
WHERE raw_id::text LIKE 'bbbbbbbb-bbbb-4bbb-8bbb-%' ORDER BY raw_id
''');
        expect(pins.map((row) => row[0]), [
          first.snapshotId,
          second.snapshotId,
          rollback.snapshotId,
        ]);
        for (var i = 0; i < 3; i++) {
          expect(await worker.processOne(), isTrue);
        }
        final events = await session.db.unsafeQuery('''
SELECT config_snapshot_id, payload FROM events WHERE source_id='$source' ORDER BY raw_id
''');
        expect(events.map((row) => row[0]), [
          first.snapshotId,
          second.snapshotId,
          rollback.snapshotId,
        ]);
        expect(
          events.map(
            (row) =>
                CloudEvent.decode(row[1] as Uint8List).event.labels['team'],
          ),
          ['ops', 'platform', 'ops'],
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'matcher snapshot readers',
    (builder, _) {
      test('NUL operand leaves stream admission readable', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final published = await repository.publishConfig(
          streamBootstrap(1, [streamSource(icinga2DbSourceId)])
            ..['expected_active_snapshot'] = null
            ..['matcher'] = _section(
              when: {'field': 'summary', 'op': 'equals', 'value': '\u0000'},
            ),
          streamMaterial(),
          runMode: 'test',
          clock: () => streamDbNow,
        );
        final db = await openStreamDatabase(session.serverpod);
        addTearDown(db.close);
        final lease = (await StreamLeaseStore(db).acquire(
          icinga2DbSourceId,
          'aaaaaaaa-0000-4000-8000-000000000002',
        ))!;
        expect(
          await ConsumerAdmission(db).admit(
            lease: lease,
            snapshotId: published.snapshotId,
            batch: StreamRawBatch(
              id: 'aaaaaaaa-0000-4000-8000-000000000003',
              connectionId: 'aaaaaaaa-0000-4000-8000-000000000001',
              rows: [
                [
                  StreamAdmissionItem.text(
                    streamDbNow,
                    jsonEncode(streamDbCheck(streamDbNow)),
                  ),
                ],
              ],
              origin: IcingaStreamOrigin.stream,
            ),
          ),
          StreamAdmissionResult.committed,
        );
        expect(await PipelineRepository(session).pinOne(), isTrue);
        final row = (await session.db.unsafeSimpleQuery(
          'SELECT config_snapshot_id FROM raw_inbox',
        )).single;
        final snapshot = await repository.snapshot(row[0] as String);
        final pinned = MatcherDocument.fromSnapshot(
          snapshot['matcher'],
          const {},
        );
        for (final (summary, expected) in [
          ('\u0000', true),
          ('\u0001', false),
          (r'\u0000', false),
        ]) {
          final data = eventFixture()['data']! as Map<String, Object?>;
          data['summary'] = summary;
          expect(
            await pinned.rules.single.condition.matches(
              CanonicalEvent.fromJson(data),
            ),
            expected,
          );
        }
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );

  withServerpod(
    'matcher publication ordering',
    (builder, _) {
      test('stale rollback cannot overwrite rotation', () async {
        final writer = builder.build();
        final contender = builder.build();
        final observer = builder.build();
        await initializeIngestSchema(writer);
        final initial = IngestConfigRepository(
          writer,
          secretStore: testSecretStore,
        );
        Map<String, Object?> config(int revision, String credential) =>
            _config(revision)
              ..['matcher'] = _section()
              ..['sources'] = [
                {
                  'id': _removedOutput,
                  'kind': 'alertmanager',
                  'enabled': true,
                  'credentials': [
                    {'type': 'bearer', 'ref': credential},
                  ],
                  'output_ids': <Object?>[],
                },
              ];
        String secret(int byte) =>
            base64Url.encode(List<int>.filled(32, byte)).replaceAll('=', '');
        final a = await initial.publishConfig(
          config(1, 'credential-a')
            ..['expected_active_snapshot'] = null
            ..['outputs'] = [
              {
                'id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
                'kind': 'webhook',
                'url': 'http://127.0.0.1:8089/events',
                'signing_key_ref': 'removed-key',
              },
            ],
          <String, Object?>{
            'credential-a': secret(1),
            'removed-key': secret(2),
          },
          runMode: 'test',
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        final gated = IngestConfigRepository(
          writer,
          secretStore: testSecretStore,
          beforeInventoryForTest: (tx) async {
            entered.complete();
            await release.future;
          },
        );
        final activating = gated.publishConfig(
          config(2, 'credential-b'),
          <String, Object?>{'credential-b': secret(3)},
          runMode: 'test',
        );
        try {
          await entered.future;
          await expectLater(
            observer.db.unsafeSimpleQuery(
              'SELECT singleton FROM ingest_active_config WHERE singleton=1 FOR SHARE NOWAIT',
            ),
            throwsA(
              isA<DatabaseQueryException>().having(
                (e) => e.code,
                'code',
                '55P03',
              ),
            ),
          );
          final restoring =
              IngestConfigRepository(
                contender,
                secretStore: testSecretStore,
              ).publishConfig(
                config(3, 'credential-a')
                  ..['expected_active_snapshot'] = a.snapshotId,
                const <String, Object?>{},
                runMode: 'test',
              );
          final rejected = expectLater(
            restoring,
            throwsA(
              isA<BootstrapError>().having(
                (e) => e.code,
                'code',
                'snapshot_mismatch',
              ),
            ),
          );
          release.complete();
          final b = await activating;
          await rejected;
          expect((await initial.activeSnapshot())?['snapshotId'], b.snapshotId);
          await observer.db.unsafeSimpleExecute('''
INSERT INTO raw_inbox (observed_at, raw_id, source_id, body, body_sha256, content_type)
VALUES (now(), '44444444-4444-4444-8444-444444444444',
        '44444444-4444-4444-8444-444444444444', ''::bytea, 'none', 'application/json')
''');
          expect(await PipelineRepository(observer).pinOne(), isTrue);
          expect(
            (await observer.db.unsafeSimpleQuery(
              'SELECT config_snapshot_id FROM raw_inbox',
            )).single[0],
            b.snapshotId,
          );
        } finally {
          if (!release.isCompleted) release.complete();
          await activating;
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
