@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:correlia_client/correlia_client.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../support/child_server.dart';
import '../support/output_process.dart';
import '../support/queue_operator.dart';

Future<(int, String)> _operatorRequest(
  ChildServer child, {
  required String method,
  String? token,
  Map<String, Object?> arguments = const {},
}) async {
  final http = HttpClient();
  try {
    final request = await http.postUrl(
      Uri.parse('http://127.0.0.1:${child.apiPort}/deadLetter/$method'),
    );
    request.headers.contentType = ContentType.json;
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    request.write(jsonEncode(arguments));
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  } finally {
    http.close(force: true);
  }
}

void main() {
  final timeout = Timeout(const Duration(minutes: 6));
  test('operator_success_redacts_and_attributes', () async {
    await withOutputProcess((db, env, _, children) async {
      final file = await operatorCredentials(env['TEST_GATE_PATH']!);
      final child = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: db,
        args: ['--mode', 'test', '--apply-migrations', '--process-role', 'api'],
        environment: {
          ...env,
          'CORRELIA_DEAD_LETTER_CREDENTIALS_FILE': file.path,
        },
      );
      children.add(child);
      await child.waitForReadyEvent();
      final pg = await outputConnection(db);
      final client = operatorClient(child);
      try {
        await pg.execute('''
          WITH raw AS (
            INSERT INTO raw_inbox (observed_at,raw_id,source_id,body,body_sha256,content_type,status)
            VALUES (now(),gen_random_uuid(),'$outputSource',convert_to('raw-canary','UTF8'),'digest','application/json','failed')
            RETURNING observed_at,raw_id,source_id
          ) SELECT correlia_record_raw_failure(observed_at,raw_id,source_id,NULL,'invalid_json',NULL,now()) FROM raw
        ''');
        await pg.execute('''
          INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
            config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,dead_reason)
          VALUES (now(),gen_random_uuid(),now(),gen_random_uuid(),'accepted','$outputId',
            'old-snapshot','https://example.test/destination-canary','reference-canary','commitment-canary',
            convert_to('delivery-canary','UTF8'),'dead','network')
        ''');
        final raw = await client.deadLetter.list(
          QueueFailureFilter(kind: QueueFailureKind.raw),
          limit: 10,
        );
        final delivery = await client.deadLetter.list(
          QueueFailureFilter(kind: QueueFailureKind.delivery),
          limit: 10,
        );
        expect(raw.failures.single.errorClass, 'invalid_json');
        expect(delivery.failures.single.errorClass, 'network');
        final result = await client.deadLetter.replay(
          QueueFailureKind.raw,
          raw.failures.single.occurrence,
        );
        expect(result.queued, 1);
        final status = await client.deadLetter.status();
        expect(status.pendingRows, 1);
        expect(
          (await pg.execute(
            Sql.named(
              'SELECT actor_kind,actor_ref,entity_id FROM activity WHERE change_kind=@change',
            ),
            parameters: {'change': 'dead_letter_replayed'},
          )).single.toList(),
          ['machine', operatorMachine, raw.failures.single.occurrence],
        );
        final replies = jsonEncode([
          raw.toJson(),
          delivery.toJson(),
          result.toJson(),
          status.toJson(),
        ]);
        final logs = (await pg.execute('''
          SELECT row_to_json(s)::text FROM serverpod_session_log s
          UNION ALL SELECT row_to_json(l)::text FROM serverpod_log l
          UNION ALL SELECT row_to_json(q)::text FROM serverpod_query_log q
        ''')).map((row) => row.single).join('\n');
        for (final canary in [
          operatorToken,
          'raw-canary',
          'destination-canary',
          'reference-canary',
          'commitment-canary',
          'delivery-canary',
        ]) {
          expect(replies, isNot(contains(canary)));
          expect(child.output, isNot(contains(canary)));
          expect(logs, isNot(contains(canary)));
        }
      } on ServerpodClientException catch (error) {
        fail('Operator request failed ($error):\n${child.output}');
      } finally {
        client.close();
        await pg.close();
      }
    });
  }, timeout: timeout);

  test('fileless_api_replays_with_the_configured_encryption_key', () async {
    await withOutputProcess((db, env, _, children) async {
      final publisher = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: db,
        args: ['--mode', 'test', '--apply-migrations', '--process-role', 'api'],
        environment: env,
      );
      children.add(publisher);
      await publisher.waitForReadyEvent();
      final pg = await outputConnection(db);
      try {
        await pg.execute('''
          INSERT INTO outbox (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
            config_snapshot_id,target_url,signing_key_ref,signing_key_commitment,payload,status,dead_reason)
          SELECT now(),gen_random_uuid(),now(),gen_random_uuid(),'ready','$outputId',
            a."snapshotId",o->>'url',o->>'signing_key_ref',o->>'signing_key_commitment',
            convert_to('{}','UTF8'),'dead','network'
          FROM ingest_active_config a JOIN ingest_config_snapshot s USING ("snapshotId")
          CROSS JOIN LATERAL jsonb_array_elements(s."publicJson"::jsonb->'outputs') o
        ''');
        final file = await operatorCredentials(env['TEST_GATE_PATH']!);
        final child = await ChildServer.startOnSharedCluster(
          serverDir: Directory.current,
          database: db,
          args: [
            '--mode',
            'test',
            '--apply-migrations',
            '--process-role',
            'api',
          ],
          environment: {
            'CORRELIA_DEAD_LETTER_CREDENTIALS_FILE': file.path,
            'CORRELIA_SECRET_KEY_FILE': db.secretKeyFile,
          },
        );
        children.add(child);
        await child.waitForReadyEvent();
        final client = operatorClient(child);
        try {
          final page = await client.deadLetter.list(
            QueueFailureFilter(kind: QueueFailureKind.delivery),
            limit: 10,
          );
          final result = await client.deadLetter.replay(
            QueueFailureKind.delivery,
            page.failures.single.occurrence,
          );
          expect(result.items.single.outcome, 'queued');
          expect(
            (await pg.execute('SELECT status FROM outbox')).single[0],
            'queued',
          );
        } finally {
          client.close();
        }
      } finally {
        await pg.close();
      }
    });
  }, timeout: timeout);

  test('operator_denies_disabled_wrong_scope_and_worker', () async {
    await withOutputProcess((db, env, _, children) async {
      final file = await operatorCredentials(env['TEST_GATE_PATH']!);
      for (final (role, enabled) in [
        ('api', false),
        ('api', true),
        ('worker', true),
      ]) {
        final child = await ChildServer.startOnSharedCluster(
          serverDir: Directory.current,
          database: db,
          args: [
            '--mode',
            'test',
            '--apply-migrations',
            '--process-role',
            role,
          ],
          environment: {
            ...env,
            if (enabled) 'CORRELIA_DEAD_LETTER_CREDENTIALS_FILE': file.path,
          },
        );
        children.add(child);
        await child.waitForReadyEvent();
        final pg = await outputConnection(db);
        try {
          if (!enabled) {
            await pg.execute('''
              WITH raw AS (
                INSERT INTO raw_inbox (observed_at,raw_id,source_id,body,body_sha256,content_type,status)
                VALUES (now(),gen_random_uuid(),'$outputSource',decode('ff','hex'),'digest','application/json','failed')
                RETURNING observed_at,raw_id,source_id
              ) SELECT correlia_record_raw_failure(observed_at,raw_id,source_id,NULL,'invalid_json',NULL,now()) FROM raw
            ''');
          }
          final occurrence = (await pg.execute(
            'SELECT occurrence_id FROM pipeline_dead_letter',
          )).single[0];
          final malformed = '${operatorToken.substring(0, 42)}B';
          final tokens = role == 'worker' || !enabled
              ? [operatorToken]
              : [null, outputToken, 'invalid-token', malformed];
          final filter = QueueFailureFilter(
            kind: QueueFailureKind.raw,
          ).toJson();
          for (final token in tokens) {
            for (final (method, arguments) in <(String, Map<String, Object?>)>[
              ('status', const {}),
              ('list', {'filter': filter, 'limit': 10}),
              (
                'replay',
                {'kind': QueueFailureKind.raw.name, 'occurrence': occurrence},
              ),
              ('replayBatch', {'filter': filter, 'limit': 10}),
            ]) {
              final result = await _operatorRequest(
                child,
                method: method,
                token: token,
                arguments: arguments,
              );
              expect(
                result.$2,
                contains('operator_access_denied'),
                reason: child.output,
              );
              expect(result.$2, isNot(contains(operatorToken)));
              expect(child.output, isNot(contains(operatorToken)));
              expect(child.output, isNot(contains(outputToken)));
              expect(result.$2, isNot(contains(outputToken)));
              expect(result.$2, isNot(contains('invalid_json')));
              expect(result.$2, isNot(contains(outputSource)));
              expect(result.$2, isNot(contains('"occurrence"')));
              expect(result.$2, isNot(contains(malformed)));
            }
          }
          expect(child.output, isNot(contains(malformed)));
          final logs = (await pg.execute('''
            SELECT row_to_json(s)::text FROM serverpod_session_log s
            UNION ALL SELECT row_to_json(l)::text FROM serverpod_log l
            UNION ALL SELECT row_to_json(q)::text FROM serverpod_query_log q
          ''')).map((row) => row.single).join('\n');
          expect(logs, isNot(contains(malformed)));
          expect(
            (await pg.execute('SELECT status FROM raw_inbox')).single[0],
            'failed',
          );
          expect(
            (await pg.execute(
              'SELECT occurrence_id FROM pipeline_dead_letter',
            )).single[0],
            occurrence,
          );
          expect(
            (await pg.execute(
              "SELECT count(*) FROM activity WHERE change_kind='dead_letter_replayed'",
            )).single[0],
            0,
          );
        } finally {
          await pg.close();
        }
        expect(await child.closeStdin(), 0);
      }
    });
  }, timeout: timeout);

  test('bad_operator_file_fails_startup_without_echo', () async {
    await withOutputProcess((db, env, _, children) async {
      const canary = 'sensitive-credential-file-value';
      final file = await File(
        env['TEST_GATE_PATH']!,
      ).writeAsString('{"operator":"$canary"}');
      expect((await Process.run('chmod', ['600', file.path])).exitCode, 0);
      final child = await ChildServer.startOnSharedCluster(
        serverDir: Directory.current,
        database: db,
        args: ['--mode', 'test', '--apply-migrations', '--process-role', 'api'],
        environment: {
          ...env,
          'CORRELIA_DEAD_LETTER_CREDENTIALS_FILE': file.path,
        },
      );
      children.add(child);
      final pattern = RegExp('dead-letter operator file invalid');
      await child.waitForOutput(pattern, timeout: const Duration(seconds: 90));
      expect(await child.exitCode, isNot(0));
      expect(child.output, isNot(contains(canary)));
      expect(child.output, isNot(contains(file.path)));
    });
  }, timeout: timeout);
}
