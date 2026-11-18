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
    'transport deduplication',
    (builder, _) {
      setUp(() async {
        final session = builder.build();
        await initializeIngestSchema(session);
        for (final table in [
          'transport_keys',
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

      test('ord_5a_concurrent_exact_retries', () async {
        final now = DateTime.utc(2026);
        Future<AdmissionOutcome> submit() =>
            IngestAdmission(builder.build()).admit(
              sourceId: fixture.sourceId,
              credentialReference: fixture
                  .input(1)
                  .sources
                  .single
                  .credentials
                  .single
                  .reference,
              tokenDigest: fixture
                  .input(1)
                  .sources
                  .single
                  .credentials
                  .single
                  .digest,
              pathToken: false,
              body: Uint8List.fromList([1, 2, 3]),
              contentType: 'application/json',
              observedAt: now,
              idempotencyKey: 'same',
            );
        final results = await Future.wait([submit(), submit()]);
        expect(
          results,
          containsAll([AdmissionOutcome.accepted, AdmissionOutcome.duplicate]),
        );
        final rows = await builder.build().db.unsafeQuery(
          'SELECT count(*) FROM raw_inbox',
        );
        expect(rows.single[0], 1);
      });

      test('key_conflict_and_expiry', () async {
        final session = builder.build();
        final admission = IngestAdmission(session);
        final now = DateTime.utc(2026);
        Future<AdmissionOutcome> submit(int byte, DateTime time) =>
            admission.admit(
              sourceId: fixture.sourceId,
              credentialReference: fixture
                  .input(1)
                  .sources
                  .single
                  .credentials
                  .single
                  .reference,
              tokenDigest: fixture
                  .input(1)
                  .sources
                  .single
                  .credentials
                  .single
                  .digest,
              pathToken: false,
              body: Uint8List.fromList([byte]),
              contentType: 'application/json',
              observedAt: time,
              idempotencyKey: 'key',
            );
        expect(await submit(1, now), AdmissionOutcome.accepted);
        expect(
          await submit(1, now.add(const Duration(minutes: 9))),
          AdmissionOutcome.duplicate,
        );
        expect(
          await submit(2, now.add(const Duration(minutes: 9))),
          AdmissionOutcome.conflict,
        );
        expect(
          await submit(2, now.add(const Duration(minutes: 10))),
          AdmissionOutcome.accepted,
        );
        expect(
          (await session.db.unsafeQuery(
            'SELECT count(*) FROM raw_inbox',
          )).single[0],
          2,
        );
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
