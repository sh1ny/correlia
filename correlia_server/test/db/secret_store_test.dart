import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/secrets/commitments.dart';
import 'package:correlia_server/src/secrets/secret_store.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';

const _source = '11111111-1111-4111-8111-111111111111';
const _output = '22222222-2222-4222-8222-222222222222';
const _ref = 'secret-store-source';
const _signing = 'secret-store-signing';

Uint8List _bytes(int value) => Uint8List(32)..fillRange(0, 32, value);
String _encoded(int value) => base64Url.encode(_bytes(value)).substring(0, 43);

Map<String, Object?> _config(int revision, String reference) => {
  'format_version': 1,
  'revision': revision,
  'sources': [
    {
      'id': _source,
      'token_ref': reference,
      'enabled': true,
      'output_ids': [_output],
    },
  ],
  'outputs': [
    {
      'id': _output,
      'kind': 'webhook',
      'url': 'http://127.0.0.1:9191/events',
      'signing_key_ref': _signing,
    },
  ],
};

Matcher _bootstrapCode(String code) =>
    isA<BootstrapError>().having((error) => error.code, 'code', code);

void main() {
  withServerpod(
    'encrypted secret store',
    (builder, _) {
      late Session session;
      late SecretStore store;
      late SecretResolver resolver;
      late IngestConfigRepository repository;
      late List<String> logs;

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeExecute('''TRUNCATE ingest_source_credential,
          ingest_source, secret_record, ingest_config_snapshot,
          ingest_active_config, ingest_secret_commitment CASCADE''');
        logs = [];
        store = SecretStore(_bytes(9));
        resolver = SecretResolver(
          store: store,
          openSession: () async => builder.build(),
          log: logs.add,
          maxEntries: 4,
        );
        repository = IngestConfigRepository(session, secretStore: store);
      });

      Future<void> publish(
        int revision, {
        String reference = _ref,
        int value = 1,
        bool includeFile = true,
      }) => repository.publishConfig(
        _config(revision, reference),
        includeFile
            ? <String, Object?>{
                reference: _encoded(value),
                _signing: _encoded(2),
              }
            : <String, Object?>{},
        runMode: 'test',
      );

      Future<DatabaseResult> records() => session.db.unsafeQuery(
        'SELECT reference,algorithm,nonce,ciphertext,commitment FROM secret_record ORDER BY reference',
      );

      const digestForOne =
          '72cd6e8422c407fb6d098690f1130b7ded7ec2f7f5e1d30bd9d521f015363793';

      test('import_seals_secrets', () async {
        await publish(1);
        final rows = await records();
        expect(rows.map((row) => row[0]), [_signing, _ref]);
        for (final row in rows) {
          expect(row[1], 'aes-256-gcm-v1');
          expect(row[2], hasLength(12));
          expect(row[3], hasLength(48));
          expect(row[3], isNot(orderedEquals(_bytes(1))));
        }
        final active = (await repository.activeSnapshot())!;
        final public = active['publicJson']! as String;
        expect(public, contains(digestForOne));
        expect(public, isNot(contains(_encoded(1))));
        expect(
          await resolver.resolve(_ref, digestForOne),
          orderedEquals(_bytes(1)),
        );
      });

      test('rebinding_refused', () async {
        await publish(1);
        final before = await records();
        final active = await repository.activeSnapshot();
        await expectLater(
          publish(2, value: 3),
          throwsA(_bootstrapCode('reference_rebound')),
        );
        expect(await repository.activeSnapshot(), active);
        final after = await records();
        expect(after.last[3], orderedEquals(before.last[3]! as List<int>));
        expect(
          await resolver.resolve(_ref, digestForOne),
          orderedEquals(_bytes(1)),
        );
      });

      test('tampered_or_moved_record', () async {
        await publish(1);
        await session.db.unsafeExecute('''INSERT INTO secret_record
          (reference,algorithm,nonce,ciphertext,commitment,"keyCommitment","createdAt")
          SELECT 'moved',algorithm,nonce,ciphertext,commitment,"keyCommitment","createdAt"
          FROM secret_record WHERE reference='$_ref' ''');
        await expectLater(
          resolver.resolve('moved', digestForOne),
          throwsA(isA<SecretResolutionError>()),
        );
        await session.db.unsafeExecute('''UPDATE secret_record SET
          ciphertext=set_byte(ciphertext,0,get_byte(ciphertext,0) # 1)
          WHERE reference='$_ref' ''');
        await expectLater(
          resolver.resolve(_ref, digestForOne),
          throwsA(isA<SecretResolutionError>()),
        );
        expect(
          await resolver.resolve(_signing, legacySecretCommitment(_bytes(2))),
          orderedEquals(_bytes(2)),
        );
      });

      test('new_reference_without_secret_file', () async {
        await publish(1);
        await publish(2, includeFile: false);
        final active = await repository.activeSnapshot();
        await expectLater(
          publish(3, reference: 'unseen', includeFile: false),
          throwsA(_bootstrapCode('missing_secret')),
        );
        expect(await repository.activeSnapshot(), active);
        expect(await records(), hasLength(2));
      });

      test('wrong_key_after_restore', () async {
        await publish(1);
        final active = await repository.activeSnapshot();
        final before = await records();
        final restored = IngestConfigRepository(
          session,
          secretStore: SecretStore(_bytes(8)),
        );
        await expectLater(
          restored.publishConfig(
            _config(2, _ref),
            <String, Object?>{},
            runMode: 'test',
          ),
          throwsA(
            allOf(
              _bootstrapCode('key_mismatch'),
              predicate<Object>((error) => !error.toString().contains(_ref)),
            ),
          ),
        );
        expect(await repository.activeSnapshot(), active);
        expect(
          (await records()).last[3],
          orderedEquals(before.last[3]! as List<int>),
        );
      });

      test('more_stored_references_than_a_process_caches', () async {
        for (var revision = 1; revision <= 6; revision++) {
          await publish(
            revision,
            reference: 'rotating-secret-$revision',
            value: revision,
          );
        }
        for (var pass = 0; pass < 2; pass++) {
          for (var revision = 1; revision <= 6; revision++) {
            final bytes = _bytes(revision);
            expect(
              await resolver.resolve(
                'rotating-secret-$revision',
                legacySecretCommitment(bytes),
              ),
              orderedEquals(bytes),
            );
          }
        }
      });

      test('decryption_failure_stays_sanitized', () async {
        await publish(1);
        await session.db.unsafeExecute(
          '''UPDATE secret_record SET
          nonce=set_byte(nonce,0,get_byte(nonce,0) # 1) WHERE reference='$_ref' ''',
        );
        await expectLater(
          resolver.resolve(_ref, digestForOne),
          throwsA(
            isA<SecretResolutionError>().having(
              (e) => e.code,
              'code',
              'secret_integrity',
            ),
          ),
        );
        final wrongKey = SecretResolver(
          store: SecretStore(_bytes(8)),
          openSession: () async => builder.build(),
          log: logs.add,
        );
        await expectLater(
          wrongKey.resolve(_signing, legacySecretCommitment(_bytes(2))),
          throwsA(
            isA<SecretResolutionError>().having(
              (e) => e.code,
              'code',
              'key_mismatch',
            ),
          ),
        );
        await session.db.unsafeSimpleExecute(
          'ALTER TABLE secret_record RENAME TO secret_record_fixture',
        );
        try {
          await expectLater(
            resolver.resolve(_ref, digestForOne),
            throwsA(
              isA<SecretResolutionError>().having(
                (e) => e.code,
                'code',
                'store_unavailable',
              ),
            ),
          );
        } finally {
          await session.db.unsafeSimpleExecute(
            'ALTER TABLE secret_record_fixture RENAME TO secret_record',
          );
        }
        expect(logs, [
          'secrets reference=$_ref code=secret_integrity',
          'secrets reference=$_signing code=key_mismatch',
          'secrets reference=$_ref code=store_unavailable',
        ]);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
