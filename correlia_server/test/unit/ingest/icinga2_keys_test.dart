import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/event/identity.dart';
import 'package:correlia_server/src/ingest/icinga2/mapper.dart';
import 'package:correlia_server/src/ingest/icinga2/webhook_parser.dart';
import 'package:test/test.dart';

import '../../support/icinga2_delivery.dart';

/// One committed example delivery and what Correlia derives from it.
///
/// The key text, bytes, fingerprint and event id were computed independently
/// of the decoder (a separate script over the identity and key encodings in
/// ADR 0024), so a change to the key shape fails here before it changes a
/// published event id.
typedef Vector = ({
  String fixture,
  String key,
  String keyHex,
  String fingerprint,
  String eventId,
});

const vectors = <Vector>[
  (
    fixture: 'state_service_problem',
    key: '["icinga2.notify.v1","CRITICAL","HARD","1763571234123456"]',
    keyHex:
        '0000000200000006646f6d61696e00000012636f7272656c69612e6e61746976652e7631000000036b65790000003b005b226963696e6761322e6e6f746966792e7631222c22435249544943414c222c2248415244222c2231373633353731323334313233343536225d',
    fingerprint:
        '9020f8d2488ef66d28d5d66687099c71cfba9f69e51f0ba7a6e57859a0239f47',
    eventId: 'cb898922-1d9f-5bbc-986c-fd3ec79e7d3e',
  ),
  (
    fixture: 'top_of_range_a',
    key: '["icinga2.notify.v1","DOWN","HARD","8589934592000001"]',
    keyHex:
        '0000000200000006646f6d61696e00000012636f7272656c69612e6e61746976652e7631000000036b657900000037005b226963696e6761322e6e6f746966792e7631222c22444f574e222c2248415244222c2238353839393334353932303030303031225d',
    fingerprint:
        '27a9e5b71892a58df454f4628b4b7aaef36cc70f8dc414abe7d59a9f0ca1f256',
    eventId: 'c3cb1123-59e8-5869-9bba-09254e64cfc2',
  ),
  (
    fixture: 'top_of_range_b',
    key: '["icinga2.notify.v1","DOWN","HARD","8589934592000002"]',
    keyHex:
        '0000000200000006646f6d61696e00000012636f7272656c69612e6e61746976652e7631000000036b657900000037005b226963696e6761322e6e6f746966792e7631222c22444f574e222c2248415244222c2238353839393334353932303030303032225d',
    fingerprint:
        '27a9e5b71892a58df454f4628b4b7aaef36cc70f8dc414abe7d59a9f0ca1f256',
    eventId: '567e6ec1-38ca-51b9-94ad-1ff1040399e1',
  ),
  (
    fixture: 'end_of_range_recovery',
    key: '["icinga2.notify.v1","UP","HARD","253402300799999999"]',
    keyHex:
        '0000000200000006646f6d61696e00000012636f7272656c69612e6e61746976652e7631000000036b657900000037005b226963696e6761322e6e6f746966792e7631222c225550222c2248415244222c22323533343032333030373939393939393939225d',
    fingerprint:
        '27a9e5b71892a58df454f4628b4b7aaef36cc70f8dc414abe7d59a9f0ca1f256',
    eventId: '1005d372-cd7d-51fc-8a23-c5f3ab28b076',
  ),
  (
    fixture: 'ack',
    key:
        '["icinga2.notify.ACKNOWLEDGEMENT.v1","ACKNOWLEDGEMENT","1763571300000001","alice"]',
    keyHex:
        '0000000200000006646f6d61696e00000012636f7272656c69612e6e61746976652e7631000000036b657900000053005b226963696e6761322e6e6f746966792e41434b4e4f574c454447454d454e542e7631222c2241434b4e4f574c454447454d454e54222c2231373633353731333030303030303031222c22616c696365225d',
    fingerprint:
        '9020f8d2488ef66d28d5d66687099c71cfba9f69e51f0ba7a6e57859a0239f47',
    eventId: '390727fb-477f-512e-b4de-1a6b3b357163',
  ),
  (
    fixture: 'downtime',
    key:
        '["icinga2.notify.DOWNTIMESTART.v1","DOWNTIMESTART","1763571310000002",""]',
    keyHex:
        '0000000200000006646f6d61696e00000012636f7272656c69612e6e61746976652e7631000000036b65790000004a005b226963696e6761322e6e6f746966792e444f574e54494d4553544152542e7631222c22444f574e54494d455354415254222c2231373633353731333130303030303032222c22225d',
    fingerprint:
        '9020f8d2488ef66d28d5d66687099c71cfba9f69e51f0ba7a6e57859a0239f47',
    eventId: '82c77c17-56b0-53e8-a1ec-a454fff75637',
  ),
  (
    fixture: 'flapping',
    key:
        '["icinga2.notify.FLAPPINGSTART.v1","FLAPPINGSTART","1763571320000003",""]',
    keyHex:
        '0000000200000006646f6d61696e00000012636f7272656c69612e6e61746976652e7631000000036b65790000004a005b226963696e6761322e6e6f746966792e464c415050494e4753544152542e7631222c22464c415050494e475354415254222c2231373633353731333230303030303033222c22225d',
    fingerprint:
        '9020f8d2488ef66d28d5d66687099c71cfba9f69e51f0ba7a6e57859a0239f47',
    eventId: '8b53827e-5c25-5d9e-a576-4c5d77a959f2',
  ),
  (
    fixture: 'custom',
    key: '["icinga2.notify.CUSTOM.v1","CUSTOM","1763571330000004","bob"]',
    keyHex:
        '0000000200000006646f6d61696e00000012636f7272656c69612e6e61746976652e7631000000036b65790000003f005b226963696e6761322e6e6f746966792e435553544f4d2e7631222c22435553544f4d222c2231373633353731333330303030303034222c22626f62225d',
    fingerprint:
        '9020f8d2488ef66d28d5d66687099c71cfba9f69e51f0ba7a6e57859a0239f47',
    eventId: 'd654b026-a462-59de-94e7-0a9fffb11e44',
  ),
];

String hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('non_state_key_without_the_state_change_time', () {
    for (final type in [
      'ACKNOWLEDGEMENT',
      'DOWNTIMESTART',
      'FLAPPINGSTART',
      'CUSTOM',
    ]) {
      final present = delivery(
        set: {'notification_type': type, 'notification_author': 'alice'},
      );
      final absent = {...present}..remove('last_state_change');
      final withField = decodeOne(present);
      final without = decodeOne(absent);
      expect(
        hex(without.observationKey.bytes),
        hex(withField.observationKey.bytes),
        reason: type,
      );
      expect(without.eventId, withField.eventId, reason: type);
      expect(without.sourceTime, withField.sourceTime, reason: type);
    }
  });

  test('fixed_key_vectors', () {
    final directory = 'test/unit/ingest/fixtures/icinga2/key_vectors';
    // Every committed example is a vector, and every vector is committed.
    final files =
        Directory(directory)
            .listSync()
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .toList()
          ..sort();
    expect(files, [for (final v in vectors) '${v.fixture}.json']..sort());
    for (final vector in vectors) {
      final bytes = File('$directory/${vector.fixture}.json').readAsBytesSync();
      final fact = parseIcinga2Webhook(bytes);
      final text = icinga2KeyText(fact);
      expect(text, vector.key, reason: vector.fixture);
      expect(
        hex(ObservationKey.native(text).bytes),
        vector.keyHex,
        reason: vector.fixture,
      );
      final event = decodeOne(bytes);
      expect(
        hex(event.observationKey.bytes),
        vector.keyHex,
        reason: vector.fixture,
      );
      expect(event.fingerprint, vector.fingerprint, reason: vector.fixture);
      expect(event.eventId, vector.eventId, reason: vector.fixture);
    }
    // The two texts that round to one IEEE double stay two observations.
    expect(
      vectors.firstWhere((v) => v.fixture == 'top_of_range_a').eventId,
      isNot(vectors.firstWhere((v) => v.fixture == 'top_of_range_b').eventId),
    );
    // The key string is a JSON array of strings with no whitespace.
    for (final vector in vectors) {
      final decoded = jsonDecode(vector.key) as List<Object?>;
      expect(decoded.every((item) => item is String), isTrue);
      expect(jsonEncode(decoded), vector.key);
    }
  });
}
