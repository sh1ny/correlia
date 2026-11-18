import '../support/secret_fixture.dart';

import 'dart:typed_data';

import 'package:correlia_server/src/ingest/admission.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import 'ingest_config_test.dart' as fixture;

void main() {
  withServerpod(
    'admission transaction',
    (builder, _) {
      test('admission_commit_fails', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publish(fixture.input(1));
        await session.db.unsafeSimpleExecute(
          "ALTER TABLE raw_inbox ADD CONSTRAINT forced_admission_failure CHECK (content_type <> 'application/json')",
        );
        try {
          await expectLater(
            IngestAdmission(session).admit(
              sourceId: fixture.sourceId,
              kind: 'alertmanager',
              credential: fixture.input(1).sources.single.credentials.single,
              pathToken: false,
              body: Uint8List.fromList([1]),
              contentType: 'application/json',
              observedAt: DateTime.utc(2026),
              idempotencyKey: 'rollback',
            ),
            throwsA(anything),
          );
          expect(
            (await session.db.unsafeQuery(
              'SELECT count(*) FROM raw_inbox',
            )).single[0],
            0,
          );
          expect(
            (await session.db.unsafeQuery(
              'SELECT count(*) FROM transport_keys',
            )).single[0],
            0,
          );
        } finally {
          await session.db.unsafeSimpleExecute(
            'ALTER TABLE raw_inbox DROP CONSTRAINT forced_admission_failure',
          );
        }
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
