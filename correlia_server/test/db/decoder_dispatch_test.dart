import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/ingest/source_decoder.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart' as icinga2;
import '../support/ingest_schema.dart';
import '../support/secret_fixture.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;
import 'ingest_config_test.dart' show token;

const _alertmanagerId = '11111111-1111-4111-8111-111111111111';
const _icinga2Id = '33333333-3333-4333-8333-333333333333';
final _now = DateTime.utc(2026, 11, 10, 12);

/// An Icinga2 decoder that only records that it ran.
final class _StubDecoder {
  int calls = 0;

  DecodedBatch call(DecodeRequest request) {
    calls++;
    return DecodedBatch(events: const []);
  }
}

Map<String, Object?> _source(String id, String kind, int key) => {
  'id': id,
  'kind': kind,
  'enabled': true,
  'credentials': [
    {'ref': 'test-key-$key', 'type': 'bearer'},
  ],
  'output_ids': <Object?>[],
};

void main() {
  withServerpod(
    'decoder dispatch by source kind',
    (builder, _) {
      late Session session;

      Future<void> publish(
        int revision, {
        bool icinga2 = true,
        bool icinga2Enabled = true,
      }) =>
          IngestConfigRepository(
            session,
            secretStore: testSecretStore,
          ).publishConfig(
            {
              'format_version': 2,
              'revision': revision,
              'outputs': <Object?>[],
              'sources': [
                _source(_alertmanagerId, 'alertmanager', 1),
                if (icinga2)
                  {
                    ..._source(_icinga2Id, 'icinga2', 2),
                    'enabled': icinga2Enabled,
                  },
              ],
            },
            <String, Object?>{
              for (var i = 1; i <= 2; i++) 'test-key-$i': token(i),
            },
            runMode: 'test',
            clock: () => _now,
          );

      setUp(() async {
        session = builder.build();
        await initializeIngestSchema(session);
        await session.db.unsafeSimpleExecute(
          '''TRUNCATE activity,alerts,pipeline_failures,observation_keys,outbox,
        events,raw_inbox,ingest_active_config,ingest_source_credential,
        ingest_source,ingest_config_snapshot,ingest_secret_commitment,
        secret_record CASCADE''',
        );
      });

      Uint8List alertmanagerBody() => Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            payload.groupOf([payload.alert(startsAt: '2026-11-10T12:00:00Z')]),
          ),
        ),
      );
      Uint8List icinga2Body() => Uint8List.fromList(utf8.encode('{}'));

      Future<String> seed(
        String source,
        Uint8List body, {
        String? pin,
      }) async {
        final id = const Uuid().v4();
        await session.db.unsafeExecute(
          '''INSERT INTO raw_inbox
(observed_at,raw_id,source_id,body,body_sha256,content_type,config_snapshot_id)
VALUES (@time,CAST(@id AS uuid),CAST(@source AS uuid),@body,@digest,'application/json',@pin)''',
          parameters: QueryParameters.named({
            'time': _now,
            'id': id,
            'source': source,
            'body': body,
            'digest': sha256.convert(body).toString(),
            'pin': pin,
          }),
        );
        return id;
      }

      /// Stores a derived snapshot of the active one and returns its id.
      Future<String> derive(
        void Function(Map<String, Object?> json) change,
      ) async {
        final rows = await session.db.unsafeQuery(
          '''SELECT c."publicJson" FROM ingest_active_config a
          JOIN ingest_config_snapshot c ON c."snapshotId"=a."snapshotId"''',
        );
        final json =
            jsonDecode(rows.single[0] as String) as Map<String, Object?>;
        change(json);
        json['revision'] = (json['revision']! as int) + 100;
        final text = jsonEncode(json);
        final id = sha256.convert(utf8.encode(text)).toString();
        await session.db.unsafeExecute(
          'INSERT INTO ingest_config_snapshot ("snapshotId",revision,"publicJson") VALUES (@id,@revision,@json)',
          parameters: QueryParameters.named({
            'id': id,
            'revision': json['revision'],
            'json': text,
          }),
        );
        return id;
      }

      List<Map<String, Object?>> sourcesOf(Map<String, Object?> json) =>
          (json['sources']! as List<Object?>).cast<Map<String, Object?>>();

      Future<void> pinAll(PipelineRepository repo) async {
        while (await repo.pinOne()) {}
      }

      Future<List<List<Object?>>> rows(String sql) async => [
        for (final row in await session.db.unsafeQuery(sql)) row.toList(),
      ];

      Future<int> count(String table) async =>
          (await rows('SELECT count(*) FROM "$table"')).single.single! as int;

      Future<String> status(String raw) async =>
          (await rows(
                "SELECT status FROM raw_inbox WHERE raw_id=CAST('$raw' AS uuid)",
              )).single.single!
              as String;

      Future<String?> failure(String raw) async =>
          (await rows(
                '''SELECT "errorClass" FROM pipeline_failures
        WHERE "rawId"=CAST('$raw' AS uuid)''',
              )).singleOrNull?.single
              as String?;

      PipelineRepository repo(_StubDecoder stub) => PipelineRepository(
        session,
        clock: () => _now,
        icinga2Decoder: stub.call,
      );

      test('two_kinds_in_one_batch', () async {
        await publish(1);
        // Both rows go through the production decoders: each kind's own
        // decoder must decode its row and commit its event.
        final seconds = _now.millisecondsSinceEpoch ~/ 1000 - 60;
        final am = await seed(_alertmanagerId, alertmanagerBody());
        final ic = await seed(
          _icinga2Id,
          icinga2.body(
            icinga2.delivery(
              set: {
                'last_state_change': '$seconds.123456',
                'notification_time': '${seconds + 5}.500000',
              },
            ),
          ),
        );
        final pipeline = PipelineRepository(session, clock: () => _now);
        await pinAll(pipeline);
        expect(await pipeline.processOne(), isTrue);
        expect(await pipeline.processOne(), isTrue);
        expect(await status(am), 'done');
        expect(await status(ic), 'done');
        expect(await count('pipeline_failures'), 0);
        final committed = await rows(
          'SELECT raw_id::text, payload FROM events ORDER BY raw_id',
        );
        final byRaw = {
          for (final row in committed)
            row[0]! as String: CloudEvent.decode(
              Uint8List.fromList(row[1]! as List<int>),
            ).event,
        };
        expect(byRaw.keys.toSet(), {am, ic});
        expect(committed, hasLength(2));
        expect(byRaw[ic]!.source.sourceInstance, _icinga2Id);
        expect(byRaw[ic]!.status, EventStatus.firing);
        expect(byRaw[am]!.source.sourceInstance, _alertmanagerId);
      });

      test('existing_rows_after_the_upgrade', () async {
        await publish(1, icinga2: false);
        final legacy = await derive((json) {
          json['format_version'] = 1;
          for (final source in sourcesOf(json)) {
            source.remove('kind');
          }
        });
        final pinned = await seed(
          _alertmanagerId,
          alertmanagerBody(),
          pin: legacy,
        );
        final unpinned = await seed(_alertmanagerId, alertmanagerBody());
        // The upgraded process publishes a version 2 snapshot, then claims.
        await publish(2, icinga2: false);
        final stub = _StubDecoder();
        final pipeline = repo(stub);
        await pinAll(pipeline);
        while (await pipeline.processOne()) {}
        expect(await status(pinned), 'done');
        expect(await status(unpinned), 'done');
        expect(stub.calls, 0);
        expect(await count('pipeline_failures'), 0);
      });

      test('row_pinned_to_a_format_version_1_snapshot', () async {
        await publish(1, icinga2: false);
        final legacy = await derive((json) {
          json['format_version'] = 1;
          for (final source in sourcesOf(json)) {
            source.remove('kind');
          }
        });
        final raw = await seed(
          _alertmanagerId,
          alertmanagerBody(),
          pin: legacy,
        );
        final stub = _StubDecoder();
        expect(await repo(stub).processOne(), isTrue);
        expect(await status(raw), 'done');
        expect(await count('events'), 1);
        expect(stub.calls, 0);
        expect(
          (await rows(
            "SELECT config_snapshot_id FROM raw_inbox WHERE raw_id=CAST('$raw' AS uuid)",
          )).single.single,
          legacy,
        );
      });

      test('missing_kind_in_a_version_2_snapshot', () async {
        await publish(1);
        final missing = await derive((json) {
          for (final source in sourcesOf(json)) {
            source.remove('kind');
          }
        });
        final am = await seed(
          _alertmanagerId,
          alertmanagerBody(),
          pin: missing,
        );
        final ic = await seed(_icinga2Id, icinga2Body(), pin: missing);
        final stub = _StubDecoder();
        final pipeline = repo(stub);
        expect(await pipeline.processOne(), isTrue);
        expect(await pipeline.processOne(), isTrue);
        for (final raw in [am, ic]) {
          expect(await status(raw), 'failed');
          expect(await failure(raw), 'unsupported_kind');
        }
        expect(stub.calls, 0);
        expect(await count('events'), 0);
      });

      test('body_of_another_kind', () async {
        await publish(1);
        final raw = await seed(_icinga2Id, alertmanagerBody());
        // The real Icinga2 decoder, not a stub: an Alertmanager body is not
        // an Icinga2 document.
        final pipeline = PipelineRepository(session, clock: () => _now);
        await pinAll(pipeline);
        expect(await pipeline.processOne(), isTrue);
        expect(await status(raw), 'failed');
        expect(await failure(raw), 'missing_field');
        expect(
          (await rows(
            '''SELECT "fieldPath" FROM pipeline_failures
        WHERE "rawId"=CAST('$raw' AS uuid)''',
          )).single.single,
          'format',
        );
        expect(await count('events'), 0);
        expect(await count('outbox'), 0);
      });

      test('admitted_row_decodes_with_its_kind', () async {
        await publish(1);
        final raw = await seed(_alertmanagerId, alertmanagerBody());
        await publish(2);
        final stub = _StubDecoder();
        final pipeline = repo(stub);
        await pinAll(pipeline);
        expect(await pipeline.processOne(), isTrue);
        expect(await status(raw), 'done');
        expect(await count('events'), 1);
        expect(stub.calls, 0);
      });

      test('source_disabled_before_the_first_claim', () async {
        await publish(1);
        final am = await seed(_alertmanagerId, alertmanagerBody());
        final ic = await seed(_icinga2Id, icinga2Body());
        await publish(2, icinga2Enabled: false);
        // Disable the Alertmanager source too, in a third revision.
        await IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        ).publishConfig(
          {
            'format_version': 2,
            'revision': 3,
            'outputs': <Object?>[],
            'sources': [
              {
                ..._source(_alertmanagerId, 'alertmanager', 1),
                'enabled': false,
              },
              {..._source(_icinga2Id, 'icinga2', 2), 'enabled': false},
            ],
          },
          <String, Object?>{
            for (var i = 1; i <= 2; i++) 'test-key-$i': token(i),
          },
          runMode: 'test',
          clock: () => _now,
        );
        final stub = _StubDecoder();
        final pipeline = repo(stub);
        await pinAll(pipeline);
        expect(await pipeline.processOne(), isTrue);
        expect(await pipeline.processOne(), isTrue);
        for (final raw in [am, ic]) {
          expect(await status(raw), 'failed');
          expect(await failure(raw), 'source_not_configured');
        }
        expect(stub.calls, 0);
        expect(await count('events'), 0);
      });
    },
    testGroupTagsOverride: ['db'],
  );
}
