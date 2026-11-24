@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:correlia_client/correlia_client.dart' as rpc;
import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/feed/feed_runtime.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/generic_decoder.dart';
import 'package:correlia_server/src/ingest/mapping_preview.dart';
import 'package:correlia_server/src/ingest/source_decoder.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_pipeline_fixture.dart';
import '../support/generic_webhook_fixture.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;

final _now = DateTime.utc(2026, 11, 24, 12, 0, 0, 123);
const _nil = '00000000-0000-0000-0000-000000000000';
const _eventLimit = 262144;

void main() {
  withServerpod(
    'Mapping preview with the console access policy',
    (builder, _) {
      late Session session;
      late rpc.Client client;
      late IngestBootstrap input;

      setUp(() async {
        session = builder.build();
        await clearPipelineTables(session);
        input = await publishGenericConfig(session, now: _now);
        client = rpc.Client(
          'http://127.0.0.1:${session.serverpod.server.port}/',
        );
        addTearDown(client.close);
        final previous = FeedRuntime.role;
        FeedRuntime.role = ProcessRole.api;
        addTearDown(() => FeedRuntime.role = previous);
      });

      Future<rpc.MappingPreviewResult> preview(
        Object? sample, [
        Map<String, Object?>? draft,
      ]) => client.mappingPreview.preview(
        genericPipelineSource,
        jsonEncode(sample),
        draftMapping: draft == null ? null : jsonEncode(draft),
      );

      test('preview_with_a_draft_mapping', () async {
        expect(session.serverpod.runMode, 'development');
        final result = await preview(
          {
            'items': [genericAlert(_now), genericAlert(_now, host: 'cache')],
            'metadata': 'unused',
          },
          {...checkMapping(), 'items': '/items', 'unmapped_fields': 'count'},
        );
        expect(result.events, hasLength(2));
        expect(
          result.events.map((event) => event.fingerprint).toSet(),
          hasLength(2),
        );
        expect(
          result.events.every((event) => event.eventId.isNotEmpty),
          isTrue,
        );
        expect(result.diagnostics.single.path, '/metadata');
        expect(result.diagnostics.single.alertIndex, isNull);
        expect(result.rowWouldFail, isFalse);
        for (final table in ['raw_inbox', 'events', 'outbox']) {
          expect(
            await session.db.unsafeQuery('SELECT 1 FROM $table LIMIT 1'),
            isEmpty,
          );
        }
        final snapshots = await session.db.unsafeQuery(
          'SELECT "snapshotId" FROM ingest_config_snapshot',
        );
        expect(snapshots.map((row) => row[0]), [input.snapshotId]);
      });

      test('preview_of_a_sample_with_several_errors', () async {
        final result = await preview(
          {
            'items': [
              genericAlert(_now),
              {...genericAlert(_now), 'state': '?', 'time': null},
              {...genericAlert(_now), 'host': 6},
            ],
            'meta': 1,
          },
          {...checkMapping(), 'items': '/items', 'unmapped_fields': 'count'},
        );
        expect(result.events.single.summary, 'Check status');
        expect(result.rowWouldFail, isTrue);
        expect(result.diagnostics.map((d) => (d.alertIndex, d.path)), [
          (null, '/meta'),
          (1, '/items/1/state'),
          (1, '/items/1/time'),
          (2, '/items/2/host'),
        ]);
      });

      test('preview_alert_count_bound', () async {
        final alert = genericAlert(_now);
        final draft = {...checkMapping(), 'items': ''};
        final allowed = await preview(List.filled(100, alert), draft);
        expect(allowed.events, hasLength(100));
        final refused = await preview(List.filled(101, alert), draft);
        expect(refused.events, isEmpty);
        expect(refused.rowWouldFail, isTrue);
        expect(refused.diagnostics.single.code, 'items_bound');
        expect(refused.diagnostics.single.alertIndex, isNull);
      });

      test('several_errors_in_one_alert', () async {
        final result = await preview({
          ...genericAlert(_now),
          'state': '?',
          'host': 42,
        });
        expect(result.events, isEmpty);
        expect(result.diagnostics.map((d) => (d.path, d.code)), [
          ('/host', 'identity_type'),
          ('/state', 'unlisted_value'),
        ]);
      });

      test('preview_rejects_nul_in_copied_summary', () async {
        final result = await preview({
          ...genericAlert(_now),
          'summary': 'bad\u0000summary',
        });
        expect(result.events, isEmpty);
        expect(result.rowWouldFail, isTrue);
        final failure = result.diagnostics.single;
        expect((failure.path, failure.code), ('/summary', 'invalid_text'));
        final key = 'x' * 256;
        final bounded = await preview(
          {...genericAlert(_now)..remove('summary'), key: '\u0000'},
          {
            ...checkMapping(),
            'summary': {'copy': '/$key'},
          },
        );
        expect(bounded.events, isEmpty);
        expect(
          (bounded.diagnostics.single.path, bounded.diagnostics.single.code),
          ('/*', 'invalid_text'),
        );
      });

      test('preview_names_the_full_path', () async {
        final result = await preview({
          ...genericAlert(_now),
          'nested': {'dot./~': true},
        });
        expect(result.diagnostics.single.path, '/nested/dot.~1~0');
        expect(result.diagnostics.single.unmapped, isTrue);
        expect(result.events, isEmpty);
      });

      test('wrong_typed_object_with_children', () async {
        final result = await preview({
          ...genericAlert(_now),
          'summary': {'one': 1, 'two': 2},
        });
        expect(result.diagnostics.single.path, '/summary');
        expect(result.diagnostics.single.unmapped, isFalse);
      });

      test('diagnostics_over_the_cap', () async {
        final keys = List.generate(
          60,
          (i) => '${'\u0000' * 245}${i.toString().padLeft(2, '0')}',
        );
        final result = await preview({
          ...genericAlert(_now),
          for (final key in keys.reversed) key: null,
        });
        final diagnostics = result.diagnostics;
        expect(diagnostics.length, lessThan(keys.length));
        expect(result.overflow, keys.length - diagnostics.length);
        expect(
          diagnostics.map((d) => d.path),
          keys.take(diagnostics.length).map((key) => '/$key'),
        );
        expect(
          utf8.encode(jsonEncode(diagnostics)).length,
          lessThanOrEqualTo(64 * 1024),
        );
        final next = diagnostics.last.toJson()
          ..['path'] = '/${keys[diagnostics.length]}';
        expect(
          utf8.encode(jsonEncode([...diagnostics, next])).length,
          greaterThan(64 * 1024),
        );
      });

      test('preview_of_an_invalid_draft', () async {
        final draft = checkMapping()..remove('source_time');
        final BootstrapError activation;
        try {
          GenericMapping.parse(draft);
          fail('Activation must refuse this draft');
        } on BootstrapError catch (error) {
          activation = error;
        }
        final result = await preview(genericAlert(_now), draft);
        expect(result.events, isEmpty);
        expect(result.validationError?.field, activation.field);
        expect(result.validationError?.code, activation.code);
      });

      test('preview_outside_the_console_access_policy', () async {
        FeedRuntime.role = ProcessRole.worker;
        await expectLater(
          client.mappingPreview.preview(
            genericPipelineSource,
            'bad JSON',
            draftMapping: 'bad JSON',
          ),
          throwsA(isA<rpc.ConsoleAccessDeniedException>()),
        );
      });

      test('results_computed_with_preview_metadata', () async {
        final mapping = GenericMapping.parse({
          ...checkMapping(),
          'description': {'copy': '/filler'},
          'labels': {
            for (var i = 0; i < 128; i++) 'k$i': {'copy': '/copy'},
          },
        });
        final source = input.sources.single;
        final body = {
          ...genericAlert(_now),
          'copy': '🦋' * 501,
          'filler': 'x' * 100,
        };
        DecodeRequest request(String text, DateTime at, String rawId) {
          final bytes = utf8.encode(text);
          final iso = at.toIso8601String();
          final time = EventTimestamp.parse(iso);
          return DecodeRequest(
            bytes: bytes,
            sourceInstance: source.id,
            namespace: source.namespace,
            excludedLabels: const [],
            rawRef: 'raw:$iso/$rawId',
            rawSha256: sha256.convert(bytes).toString(),
            observedAt: time,
            processedAt: time,
            configVersion: input.snapshotId,
          );
        }

        final base = decodeGeneric(
          request(jsonEncode(body), _now, _nil),
          mapping,
        ).events.single;
        body['filler'] =
            'x' *
            (100 + _eventLimit - CloudEvent(event: base).toJsonBytes().length);
        final sample = jsonEncode(body);
        final expected = decodeGeneric(
          request(sample, _now, _nil),
          mapping,
        ).events.single;
        expect(
          CloudEvent(event: expected).toJsonBytes(),
          hasLength(_eventLimit),
        );
        final result = await previewMapping(
          session,
          genericPipelineSource,
          sample,
          draftMapping: jsonEncode(mapping.toJson()),
          now: _now,
        );
        expect(result.label, 'computed with preview metadata');
        expect(result.events.single.eventId, expected.eventId);
        expect(result.events.single.fingerprint, expected.fingerprint);
        expect(
          result.toJson().keys,
          unorderedEquals([
            '__className__',
            'label',
            'events',
            'diagnostics',
            'overflow',
            'rowWouldFail',
          ]),
        );
        final shorter = decodeGeneric(
          request(sample, DateTime.utc(2026, 11, 24, 12), source.id),
          mapping,
        ).events.single;
        expect(shorter.eventId, expected.eventId);
        expect(
          () => decodeGeneric(
            request(
              sample,
              _now.add(const Duration(microseconds: 456)),
              source.id,
            ),
            mapping,
          ),
          throwsA(
            isA<EventValidationError>().having(
              (error) => error.code,
              'code',
              'event_too_large',
            ),
          ),
        );

        body['filler'] = '${body['filler']}x';
        final oversized = jsonEncode(body);
        expect(
          decodeGeneric(
            request(oversized, DateTime.utc(2026, 11, 24, 12), source.id),
            mapping,
          ).events.single.eventId,
          expected.eventId,
        );
        final rejected = await previewMapping(
          session,
          genericPipelineSource,
          oversized,
          draftMapping: jsonEncode(mapping.toJson()),
          now: _now,
        );
        expect(rejected.events, isEmpty);
        expect(rejected.diagnostics.single.code, 'event_too_large');
      });
    },
    configOverride: (config) => config.copyWith(runMode: 'development'),
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
