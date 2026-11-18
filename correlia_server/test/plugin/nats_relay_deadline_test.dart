@Tags(['plugin'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:correlia_server/src/output/delivery_permit.dart';
import 'package:correlia_server/src/output/output_relay.dart';
import 'package:correlia_server/src/output/relay_deadline.dart';
import 'package:correlia_server/src/plugin/output_plugin_connection.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../support/jetstream_inspector.dart';
import '../support/secret_fixture.dart';
import '../unit/event/fixture.dart';
import 'support/natsdev.dart';

const _output = '11111111-1111-4111-8111-111111111111';
const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  withServerpod(
    'NATS relay deadline',
    (builder, _) {
      test('batch_over_its_deadline', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute(
          'DELETE FROM delivery_attempts; DELETE FROM outbox',
        );
        final nats = await NatsTestServer.start();
        OutputPluginConnection? plugin;
        JetStreamInspector? inspector;
        try {
          final stream = await Process.run(
            '${Directory.current.parent.path}/build/plugins/natsdev',
            ['stream', '--url', nats.url.toString()],
          );
          if (stream.exitCode != 0) {
            throw StateError('stream setup failed: ${stream.stderr}');
          }
          inspector = await JetStreamInspector.connect(nats.url);
          plugin = await OutputPluginConnection.start(
            executable:
                '${Directory.current.parent.path}/build/plugins/output-nats',
            configJson: utf8.encode(
              jsonEncode({
                'server': nats.url.toString(),
                'stream': 'CORRELIA_EVENTS',
              }),
            ),
            secrets: const {},
          );
          final envelope = eventFixture();
          final id = envelope['id'] as String;
          final payload = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
          await session.db.unsafeExecute(
            '''INSERT INTO outbox
          (created_at,delivery_id,event_observed_at,event_id,event_disposition,output_id,
           config_snapshot_id,output_kind,definition_digest,payload)
          VALUES (clock_timestamp(),gen_random_uuid(),clock_timestamp(),CAST(@id AS uuid),
           'ready',CAST(@output AS uuid),'snapshot','plugin',@digest,@payload)''',
            parameters: QueryParameters.named({
              'id': id,
              'output': _output,
              'digest': _digest,
              'payload': payload,
            }),
          );
          var elapsed = Duration.zero;
          final source = DeliveryPermitSource();
          final permit = source.acquire()!;
          final repository = OutputRelayRepository(
            session,
            noSigningKey,
            beforeClaimCommit: () async {
              elapsed += const Duration(seconds: 4);
            },
            afterCompletionAttempts: () async {
              elapsed += const Duration(seconds: 4);
            },
            afterCompletionOutbox: () async {
              elapsed += const Duration(seconds: 4);
            },
          );
          final batch = (await repository.claim(
            _output,
            limit: 64,
            readyDigests: {_digest},
            permit: permit,
            deadline: RelayDeadline(elapsed: () => elapsed),
          ))!;
          final first = await plugin.deliver([OutputPluginEvent(id, payload)]);
          expect(first.single.outcome, OutputPluginOutcome.acknowledged);
          elapsed += const Duration(seconds: 16);
          await expectLater(
            repository.completeBatch(batch, [const DeliveryAcknowledged()]),
            throwsA(isA<TimeoutException>()),
          );
          permit.release();
          final rolledBack = await session.db.unsafeQuery(
            'SELECT status,lease_until > clock_timestamp() FROM outbox',
          );
          expect(rolledBack.single[0], 'delivering');
          expect(rolledBack.single[1], isTrue);
          final attempts = await session.db.unsafeQuery(
            'SELECT outcome FROM delivery_attempts',
          );
          expect(attempts.single[0], 'started');
          await session.db.unsafeSimpleExecute(
            "UPDATE outbox SET lease_until=clock_timestamp()-interval '1 second'",
          );
          expect(await repository.recoverExpired(), isTrue);
          await session.db.unsafeSimpleExecute(
            "UPDATE outbox SET next_attempt_at=clock_timestamp()-interval '1 second'",
          );
          final retryPermit = source.acquire()!;
          final retry = (await OutputRelayRepository(session, noSigningKey)
              .claim(
                _output,
                limit: 64,
                readyDigests: {_digest},
                permit: retryPermit,
              ))!;
          final second = await plugin.deliver([
            OutputPluginEvent(
              retry.claims.single.eventId,
              retry.claims.single.payload,
            ),
          ]);
          expect(second.single.outcome, OutputPluginOutcome.acknowledged);
          expect(
            await OutputRelayRepository(
              session,
              noSigningKey,
            ).completeBatch(retry, [const DeliveryAcknowledged()]),
            isTrue,
          );
          retryPermit.release();
          final recorded = await session.db.unsafeQuery(
            'SELECT outcome FROM delivery_attempts ORDER BY "attemptNumber"',
          );
          expect(recorded.map((row) => row[0]), [
            'interrupted',
            'acknowledged',
          ]);
          final messages = await inspector.messages();
          expect(messages, hasLength(1));
          expect(messages.single.headers['nats-msg-id'], id);
          expect(messages.single.body, payload);
        } finally {
          await plugin?.stop();
          await inspector?.close();
          await nats.close();
        }
      }, timeout: const Timeout(Duration(minutes: 3)));
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['plugin'],
  );
}
