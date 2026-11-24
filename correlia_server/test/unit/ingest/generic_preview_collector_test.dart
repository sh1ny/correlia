import 'dart:convert';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/bootstrap.dart';
import 'package:correlia_server/src/ingest/generic_decoder.dart';
import 'package:correlia_server/src/ingest/source_decoder.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../support/generic_webhook_fixture.dart';

void main() {
  test('dense_unmapped_subtree', () {
    const source = '11111111-1111-4111-8111-111111111111';
    final time = EventTimestamp.parse('2026-11-24T05:20:00Z');
    final bytes = utf8.encode(
      jsonEncode({
        'items': [
          {
            'host': 'api',
            'time': time.toRfc3339(),
            'state': 'PROBLEM',
            'summary': 'down',
            'extra': List<int>.filled(200000, 0),
          },
        ],
        'page': 1,
      }),
    );
    final report = previewGeneric(
      DecodeRequest(
        bytes: bytes,
        sourceInstance: source,
        namespace: source,
        excludedLabels: const [],
        rawRef: 'raw:$source',
        rawSha256: sha256.convert(bytes).toString(),
        observedAt: time,
        processedAt: time,
        configVersion: 'preview',
      ),
      GenericMapping.parse({
        ...checkMapping(),
        'items': '/items',
        'unmapped_fields': 'count',
      }),
    );
    final expected = [for (var i = 0; i < 200000; i++) '$i']..sort();
    expect(report.events, hasLength(1));
    expect(report.diagnostics.map((d) => d.path), [
      '/page',
      for (final index in expected.take(99)) '/items/0/extra/$index',
    ]);
    expect(report.overflow, 199901);
    expect(report.retainedHighWater, 100);
  });
}
