@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:correlia_client/correlia_client.dart';
import 'package:correlia_server/src/feed/feed_runtime.dart';
import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/generic_pipeline_fixture.dart';
import '../support/generic_webhook_fixture.dart';
import '../support/icinga2_pipeline.dart' show clearPipelineTables;

final _now = DateTime.utc(2026, 11, 24, 12);

String _escapeHeavySample(int size) {
  String body(String padding) => jsonEncode({
    ...genericAlert(_now),
    'padding': padding,
  });
  final available = size - body('').length;
  return body('\\' * (available ~/ 2)).padRight(size);
}

void main() {
  withServerpod(
    'Mapping preview RPC transport',
    (builder, _) {
      test('escape_heavy_sample_and_draft_fit_the_rpc_limit', () async {
        final session = builder.build();
        await clearPipelineTables(session);
        await publishGenericConfig(session, now: _now);
        final role = FeedRuntime.role;
        FeedRuntime.role = ProcessRole.api;
        addTearDown(() => FeedRuntime.role = role);
        final client = Client(
          'http://127.0.0.1:${session.serverpod.server.port}/',
        );
        addTearDown(client.close);

        final sample = _escapeHeavySample(1024 * 1024);
        final draft = jsonEncode({
          ...checkMapping(),
          'unmapped_fields': 'count',
        }).padRight(32 * 1024);
        expect(sample.length, 1024 * 1024);
        expect(draft.length, 32 * 1024);
        final result = await client.mappingPreview.preview(
          genericPipelineSource,
          sample,
          draftMapping: draft,
        );
        expect(result.events.single.summary, 'Check status');
        expect(result.diagnostics.single.path, '/padding');
        expect(result.rowWouldFail, isFalse);
        final biggerSample = await client.mappingPreview.preview(
          genericPipelineSource,
          '$sample ',
          draftMapping: draft,
        );
        expect(biggerSample.validationError?.field, 'sample');
        expect(biggerSample.events, isEmpty);
        final biggerDraft = await client.mappingPreview.preview(
          genericPipelineSource,
          sample,
          draftMapping: '$draft ',
        );
        expect(biggerDraft.validationError?.field, 'draftMapping');
        expect(biggerDraft.events, isEmpty);
      });
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}
