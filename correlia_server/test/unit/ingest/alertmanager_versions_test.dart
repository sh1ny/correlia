import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/ingest/alertmanager_decoder.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  final directory = Directory('test/unit/ingest/fixtures/alertmanager');
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  AlertmanagerBatch decode(File file) {
    final bytes = file.readAsBytesSync();
    return decodeAlertmanager(
      bytes: bytes,
      sourceInstance: '11111111-1111-4111-8111-111111111111',
      rawRef: 'raw:${file.path}',
      rawSha256: sha256.convert(bytes).toString(),
      observedAt: EventTimestamp.parse('2026-11-12T20:32:00Z'),
      processedAt: EventTimestamp.parse('2026-11-12T20:33:00Z'),
      configVersion: 'compatibility',
    );
  }

  group('every_supported_release_decodes', () {
    final latest = File('${directory.path}/v0.35.0-firing.json');
    for (final file in files) {
      test(file.uri.pathSegments.last, () {
        final batch = decode(file);
        expect(batch.events, hasLength(1));
        expect(
          batch.events.single.status,
          file.path.endsWith('-resolved.json')
              ? EventStatus.resolved
              : EventStatus.firing,
        );
        expect(batch.unknownTopLevelFields, isEmpty);
        expect(batch.unknownTopLevelOverflow, 0);
        expect(
          batch.events.single.fingerprint,
          decode(latest).events.single.fingerprint,
        );
      });
    }
  });

  test('release_without_fingerprint_or_truncated_alerts', () {
    final latest = decode(
      File('${directory.path}/v0.35.0-firing.json'),
    ).events.single;
    for (final file in files.where(
      (file) => RegExp(r'v0\.(16|17|18)\.').hasMatch(file.path),
    )) {
      final input = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(input.containsKey('truncatedAlerts'), isFalse);
      final alerts = input['alerts']! as List<Object?>;
      expect(
        (alerts.single! as Map<String, Object?>).containsKey('fingerprint'),
        isFalse,
      );
      final batch = decode(file);
      expect(batch.upstreamOmissions, 0);
      expect(batch.events.single.fingerprint, latest.fingerprint);
      if (file.path.endsWith('-firing.json')) {
        expect(batch.events.single.eventId, latest.eventId);
      }
    }
  });
}
