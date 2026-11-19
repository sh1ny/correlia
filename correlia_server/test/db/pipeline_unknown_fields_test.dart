import '../support/secret_fixture.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' as fixture;
import 'pipeline_test.dart' as support;

void main() {
  withServerpod(
    'unknown Alertmanager fields',
    (builder, _) {
      final logs = <String>[];
      setUp(() async {
        logs.clear();
        final session = builder.build();
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
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(fixture.input(1));
      });

      Future<void> process(
        Map<String, Object?> extras, {
        void Function(String)? log,
      }) async {
        final session = builder.build();
        final body = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              ...payload.groupOf([
                payload.alert(startsAt: '2026-11-10T12:00:00Z'),
              ]),
              ...extras,
            }),
          ),
        );
        await session.db.unsafeExecute(
          '''INSERT INTO raw_inbox
(observed_at,raw_id,source_id,body,body_sha256,content_type)
VALUES (@time,CAST(@id AS uuid),CAST(@source AS uuid),@body,@digest,'application/json')''',
          parameters: QueryParameters.named({
            'time': support.now,
            'id': const Uuid().v4(),
            'source': fixture.sourceId,
            'body': body,
            'digest': sha256.convert(body).toString(),
          }),
        );
        final repo = PipelineRepository(
          session,
          clock: () => support.now,
          log: log ?? logs.add,
        );
        expect(await repo.pinOne(), isTrue);
        expect(await repo.processOne(), isTrue);
      }

      Future<Map<String, Object?>> outcome() async {
        final rows = await builder.build().db.unsafeQuery(
          'SELECT outcome_json FROM raw_inbox',
        );
        return jsonDecode(rows.single[0] as String) as Map<String, Object?>;
      }

      Future<Map<String, Object?>> event() async {
        final rows = await builder.build().db.unsafeQuery(
          'SELECT payload FROM events',
        );
        final bytes = rows.single[0];
        return jsonDecode(
              utf8.decode(
                bytes is ByteData
                    ? bytes.buffer.asUint8List(
                        bytes.offsetInBytes,
                        bytes.lengthInBytes,
                      )
                    : bytes as Uint8List,
              ),
            )
            as Map<String, Object?>;
      }

      test('future_top_level_field_is_processed_and_flagged', () async {
        await process({'newField': 'never-log-this-value'});
        final first = await event();
        expect(await support.count(builder.build(), 'outbox'), 1);
        final result = await outcome();
        expect(result['unknown_top_level_fields'], ['newField']);
        expect(result['unknown_top_level_overflow'], 0);
        expect(logs, [
          formatUnknownFieldWarning(fixture.sourceId, ['newField'], 0),
        ]);
        expect(logs.single, isNot(contains('newField')));
        expect(logs.single, isNot(contains('never-log-this-value')));
        await builder.build().db.unsafeSimpleExecute(
          'DELETE FROM activity; DELETE FROM alerts; DELETE FROM observation_keys; DELETE FROM outbox; DELETE FROM events; DELETE FROM raw_inbox',
        );
        logs.clear();
        await process({});
        final baseline = await event();
        expect(first['id'], baseline['id']);
        final firstData = Map<String, Object?>.from(
          first['data']! as Map<String, Object?>,
        )..remove('raw');
        final baselineData = Map<String, Object?>.from(
          baseline['data']! as Map<String, Object?>,
        )..remove('raw');
        expect(firstData, baselineData);
        expect((await outcome())['unknown_top_level_fields'], isEmpty);
        expect((await outcome())['unknown_top_level_overflow'], 0);
        expect(logs, isEmpty);
      });

      test('credential_shaped_unknown_key_never_logged', () async {
        final credential = fixture.token(1);
        await process({credential: 'secret-value'});
        expect((await outcome())['unknown_top_level_fields'], [credential]);
        expect(logs, hasLength(1));
        expect(logs.single, isNot(contains(credential)));
        expect(logs.single, isNot(contains('secret-value')));
      });

      test('many_or_oversized_unknown_names', () async {
        await process({
          for (var i = 0; i < 19; i++)
            'field${i.toString().padLeft(2, '0')}': i,
          'x' * 300: true,
        });
        final names = [
          for (var i = 0; i < 16; i++) 'field${i.toString().padLeft(2, '0')}',
        ];
        expect((await outcome())['unknown_top_level_fields'], names);
        expect((await outcome())['unknown_top_level_overflow'], 4);
        expect(logs, [formatUnknownFieldWarning(fixture.sourceId, names, 4)]);
      });

      test('warning_lost_after_commit_is_not_retried', () async {
        var attempts = 0;
        await process(
          {'newField': true},
          log: (_) {
            attempts++;
            throw StateError('logger unavailable');
          },
        );
        expect(attempts, 1);
        expect((await outcome())['unknown_top_level_fields'], ['newField']);
        expect(
          (await builder.build().db.unsafeQuery(
            'SELECT status,attempt_count FROM raw_inbox',
          )).single,
          ['done', 0],
        );
        final repo = PipelineRepository(
          builder.build(),
          clock: () => support.now,
          log: logs.add,
        );
        expect(await repo.pinOne(), isFalse);
        expect(await repo.processOne(), isFalse);
        expect(logs, isEmpty);
        expect(await support.count(builder.build(), 'outbox'), 1);
      });

      for (final entry in <String, Object>{
        'routeLabels': <String>[],
        'notification_reason': 7,
      }.entries) {
        test('wrong_typed_group_metadata ${entry.key}', () async {
          await process({entry.key: entry.value});
          final failure = await builder.build().db.unsafeQuery(
            'SELECT "fieldPath" FROM pipeline_failures',
          );
          expect(failure.single[0], entry.key);
          expect(await support.count(builder.build(), 'events'), 0);
          expect(await support.count(builder.build(), 'outbox'), 0);
          expect(logs, isEmpty);
        });
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
