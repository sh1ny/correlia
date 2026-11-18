import '../support/secret_fixture.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/config_repository.dart';
import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:correlia_server/src/plugin/plugin_admission_repository.dart';
import 'package:correlia_server/src/plugin/slot_scheduler.dart';
import 'package:crypto/crypto.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/ingest_schema.dart';
import '../unit/ingest/alertmanager_decoder_test.dart' as payload;

String id(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

IngestBootstrap snapshot(int revision) => IngestBootstrap.parse(
  {
    'format_version': 1,
    'revision': revision,
    'sources': [
      for (var i = 0; i < 8; i++)
        {
          'id': id(1000 + i),
          'enabled': true,
          'token_ref': 'token',
          'output_ids': [for (var j = 0; j < 8; j++) id(i * 8 + j)],
        },
    ],
    'outputs': [
      for (var i = 0; i < 64; i++)
        {
          'id': id(i),
          'kind': 'plugin',
          'plugin': 'output-nats',
          'sha256': 'a' * 64,
          'config': {'revision': revision},
          'secret_refs': <String, String>{},
        },
    ],
  },
  {'token': base64Url.encode(List<int>.filled(32, 1)).replaceAll('=', '')},
  runMode: 'test',
);

Future<void> seed(Session session, int source, int generation) async {
  final body = Uint8List.fromList(
    utf8.encode(
      jsonEncode(
        payload.groupOf([
          payload.alert(
            startsAt: '2026-11-10T12:00:00Z',
            labels: {'alertname': 'alert-$source-$generation'},
          ),
        ]),
      ),
    ),
  );
  await session.db.unsafeExecute(
    '''INSERT INTO raw_inbox
    (observed_at,raw_id,source_id,body,body_sha256,content_type)
    VALUES (@time,CAST(@id AS uuid),CAST(@source AS uuid),@body,@digest,'application/json')''',
    parameters: QueryParameters.named({
      'time': DateTime.utc(2026, 11, 10, 12),
      'id': const Uuid().v4(),
      'source': id(1000 + source),
      'body': body,
      'digest': sha256.convert(body).toString(),
    }),
  );
}

void main() {
  withServerpod(
    'plugin admission',
    (builder, _) {
      test('pinned_generations_beyond_one_page', () async {
        final session = builder.build();
        await initializeIngestSchema(session);
        final config = IngestConfigRepository(
          session,
          secretStore: testSecretStore,
        );
        final first = snapshot(1);
        final second = snapshot(2);
        await config.publish(first);
        final pipeline = PipelineRepository(
          session,
          clock: () => DateTime.utc(2026, 11, 10, 12),
        );
        for (var i = 0; i < 7; i++) {
          await seed(session, i, 1);
          await pipeline.pinOne();
        }
        await seed(session, 7, 1);
        final entered = Completer<void>();
        final resume = Completer<void>();
        final pinnedPipeline = PipelineRepository(
          session,
          clock: () => DateTime.utc(2026, 11, 10, 12),
          afterPin: () {
            entered.complete();
            return resume.future;
          },
        );
        final pin = pinnedPipeline.pinOne();
        await entered.future;
        try {
          await config.publish(second);
        } finally {
          resume.complete();
          await pin;
        }
        for (var i = 0; i < 8; i++) {
          await pipeline.processOne();
        }
        for (var i = 0; i < 8; i++) {
          await seed(session, i, 2);
          await pipeline.pinOne();
          await pipeline.processOne();
        }
        final repo = PluginAdmissionRepository(session, 'test-host');
        PluginKey? cursor;
        final found = <PluginKey>{};
        for (var i = 0; i < 128; i++) {
          final key = await repo.next(cursor: cursor, running: const []);
          expect(key, isNotNull);
          expect(found.add(key!), isTrue);
          cursor = key;
        }
        expect(found, hasLength(128));
        final sameOutput = found.where((key) => key.outputId == id(0)).toList()
          ..sort();
        expect(sameOutput, hasLength(2));
        final waiting = await repo.next(
          cursor: null,
          running: [sameOutput.first],
          respectOutputLimit: false,
          outputLimit: 1,
        );
        final admissible = await repo.next(
          cursor: null,
          running: [sameOutput.first],
          outputLimit: 1,
        );
        expect(waiting, sameOutput.last);
        expect(admissible?.outputId, isNot(id(0)));
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
