import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:correlia_server/src/secrets/commitments.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_stream_fixture.dart';
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../support/secret_reuse_fixture.dart';

const _streamId = '11111111-1111-4111-8111-111111111111';
const _webhookId = '22222222-2222-4222-8222-222222222222';
const _outputId = '33333333-3333-4333-8333-333333333333';

Uint8List _bytes(int n) => Uint8List(32)..fillRange(0, 32, n);

String _material(List<int> bytes) => base64Url.encode(bytes).split('=').first;
TypeMatcher<BootstrapError> _code(String code) => isA<BootstrapError>().having(
  (error) => error.code,
  'code',
  code,
);

void main() {
  withServerpod(
    'secret password reuse',
    (builder, _) {
      late Session session;
      late IngestConfigRepository repository;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeExecute('''TRUNCATE ingest_source_credential,
          ingest_source, secret_record, ingest_config_snapshot,
          ingest_active_config, ingest_secret_commitment CASCADE''');
        repository = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
      });

      Future<IngestBootstrap> publish(
        int revision, {
        int? password,
        int? credential,
        int? signingKey,
        List<int>? ca,
        String passwordRef = 'icinga-password',
      }) {
        final source = streamSource(_streamId);
        (source['api']! as Map<String, Object?>)['password_ref'] = passwordRef;
        final config = streamBootstrap(revision, [
          if (password != null) source,
          if (credential != null)
            {
              'id': _webhookId,
              'kind': 'icinga2',
              'enabled': true,
              'credentials': [
                {'ref': 'webhook-credential', 'type': 'bearer'},
              ],
              'output_ids': <String>[],
            },
        ]);
        if (signingKey != null) {
          config['outputs'] = [
            {
              'id': _outputId,
              'kind': 'webhook',
              'url': 'http://127.0.0.1:9191/events',
              'signing_key_ref': 'webhook-signing',
            },
          ];
        }
        return repository.publishConfig(config, {
          if (password != null) ...{
            'icinga-ca': ca == null
                ? streamMaterial()['icinga-ca']
                : {'bytes': _material(ca)},
            passwordRef: {'bytes': _material(_bytes(password))},
          },
          if (credential != null)
            'webhook-credential': _material(_bytes(credential)),
          if (signingKey != null)
            'webhook-signing': _material(_bytes(signingKey)),
        }, runMode: 'test');
      }

      Future<void> refuse(
        Future<IngestBootstrap> operation,
        int revision,
      ) async {
        await expectLater(operation, throwsA(_code('password_reuse')));
        expect((await repository.activeSnapshot())?['revision'], revision);
      }

      test('password_imported', () async {
        final published = await publish(1, password: 21);
        final rows = await session.db.unsafeQuery(
          '''SELECT reference, commitment, ciphertext
          FROM secret_record ORDER BY reference''',
        );
        expect(rows.map((row) => row[0]), ['icinga-ca', 'icinga-password']);
        expect(
          rows.map((row) => row[1]),
          everyElement(startsWith('hmac-sha256:')),
        );
        expect(rows.last[2], hasLength(48));
        expect(rows.last[2], isNot(containsAllInOrder(_bytes(21))));
        expect(published.publicJson, isNot(contains(_material(_bytes(21)))));
        expect(
          published.publicJson,
          isNot(contains(legacySecretCommitment(_bytes(21)))),
        );
      });

      test('ca_bundle_too_large', () async {
        await publish(1);
        await expectLater(
          publish(2, password: 21, ca: Uint8List(16385)),
          throwsA(
            isA<BootstrapError>()
                .having((e) => e.fileKind, 'file', 'secrets')
                .having((e) => e.field, 'field', 'value'),
          ),
        );
        expect((await repository.activeSnapshot())!['revision'], 1);
      });

      test('password_equals_a_signing_key', () async {
        await publish(1, signingKey: 21);
        await expectLater(
          publish(2, password: 21),
          throwsA(
            _code(
              'password_reuse',
            ).having((e) => e.field, 'field', 'sources[0].api.password_ref'),
          ),
        );
        expect((await repository.activeSnapshot())!['revision'], 1);
      });

      test('credential_added_after_the_password', () async {
        await publish(1, password: 21);
        await refuse(publish(2, credential: 21), 1);
        expect(
          await session.db.unsafeQuery(
            'SELECT digest FROM ingest_source_credential',
          ),
          isEmpty,
        );
      });

      test('credential_added_after_the_password_was_rotated_away', () async {
        await publish(1, password: 21);
        await publish(2, password: 22, passwordRef: 'next-icinga-password');
        await refuse(publish(3, credential: 21), 2);
      });

      test('same_bytes_in_one_publication', () async {
        await publish(1);
        await refuse(publish(2, credential: 21, password: 21), 1);
      });

      test('different_bytes', () async {
        await publish(1, credential: 22, password: 21, signingKey: 23);
        expect((await repository.activeSnapshot())!['revision'], 1);
      });

      test('removed_password_still_checked', () async {
        await publish(1, password: 21);
        await publish(2);
        await refuse(publish(3, signingKey: 21), 2);
      });

      test('reuse_digest_holds_no_bare_digest', () async {
        await publish(1, password: 21);
        final rows = await session.db.unsafeQuery(
          "SELECT digest FROM secret_reuse_digest WHERE kind = 'password'",
        );
        final data = [
          ...utf8.encode('correlia-password-reuse-v1'),
          ..._bytes(21),
        ];
        final keyed = Hmac(
          sha256,
          deriveCommitmentKey(Uint8List(32)),
        ).convert(data).toString();
        expect(rows.single[0], keyed);
        expect(rows.single[0], isNot(legacySecretCommitment(_bytes(21))));
      });

      test('upgrade_with_removed_secrets', () async {
        await prepareHistoricalReuse(session);
        final history = jsonEncode({
          'format_version': 2,
          'sources': [
            {
              'id': _webhookId,
              'credentials': [
                {'digest': legacySecretCommitment(_bytes(21))},
              ],
            },
          ],
          'outputs': [
            {
              'id': _outputId,
              'kind': 'webhook',
              'signing_key_ref': 'webhook-signing',
              'signing_key_commitment': legacySecretCommitment(_bytes(22)),
            },
          ],
        });
        await session.db.unsafeExecute('''
          INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson")
          VALUES ('removed-secrets',1,@json)
        ''', parameters: QueryParameters.named({'json': history}));
        await session.db.unsafeExecute('''
          INSERT INTO ingest_active_config (singleton,"snapshotId")
          VALUES (1,'removed-secrets')
        ''');
        await session.db.transaction(
          (tx) => testSecretStore.insert(
            session,
            tx,
            'webhook-signing',
            _bytes(22),
            plugin: true,
          ),
        );
        await initializeSchema(session);
        await refuse(publish(2, password: 21), 1);
        await refuse(publish(2, password: 22), 1);
      });
    },
    testGroupTagsOverride: ['db'],
  );
}
