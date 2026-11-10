import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/event/identity.dart';
import 'package:test/test.dart';

const _source = '11111111-1111-4111-8111-111111111111';
const _other = '22222222-2222-4222-8222-222222222222';
const _time = '2026-11-10T00:00:00Z';
const _fingerprint =
    '09fc69bd0646d8e356c57b6c9b46256eda741ef8924425df1c9cce8ce2137b7f';

void main() {
  final context = SourceContext(
    sourceInstance: _source,
    sourceKind: 'alertmanager',
  );
  Map<String, IdentityComponent> labels([String severity = 'warning']) =>
      selectAlertmanagerIdentity({
        'alertname': 'Example',
        'severity': severity,
      });
  ObservationKey observation() =>
      ObservationKey.alertmanager(status: 'firing', startsAt: _time);
  String id(ObservationKey key, {int generation = 0, SourceContext? source}) =>
      observationId(
        source: source ?? context,
        fingerprint: _fingerprint,
        key: key,
        generation: generation,
      );

  test('ID-4 delimiter collision', () {
    final a = alertFingerprint(
      context,
      identityComponents({'host': 'a|service=b', 'service': 'c'}),
    );
    final b = alertFingerprint(
      context,
      identityComponents({'host': 'a', 'service': 'b|service=c'}),
    );
    expect(
      a,
      '27a91ff7d92d285e3d78dab74114ab81c9e97ca3bb3c4e3ad8ff25e7f7c15f83',
    );
    expect(
      b,
      '6674debf17e1027353db504d51a1c224cf2bf96bf0f0b75c2efb2bf7df07daeb',
    );
  });

  test('Map order and Unicode length', () {
    const expected =
        '5a8d4d2babde02a5d9717ecf7e4e75e3b7552718533d80b1a27f7980ae46a40c';
    expect(
      alertFingerprint(
        context,
        identityComponents({'\u{10000}': '☃', '\ue000': 'é'}),
      ),
      expected,
    );
    expect(
      alertFingerprint(
        context,
        identityComponents({'\ue000': 'é', '\u{10000}': '☃'}),
      ),
      expected,
    );
    expect(
      canonicalTuple([
        ('é', Uint8List.fromList([1, 2])),
      ]),
      [0, 0, 0, 1, 0, 0, 0, 2, 195, 169, 0, 0, 0, 2, 1, 2],
    );
    expect(
      () => canonicalTuple([('x', Uint8List(0)), ('x', Uint8List(0))]),
      throwsA(isA<EventFieldError>()),
    );
  });

  test('ID-7b severity is identity by default', () {
    expect(alertFingerprint(context, labels()), _fingerprint);
    expect(
      alertFingerprint(context, labels('critical')),
      'cabfd680a678b86789ed39940ffe85303563bc6e661baef4428fc4064df463a1',
    );
    final resolved = ObservationKey.alertmanager(
      status: 'resolved',
      startsAt: _time,
      endsAt: '2026-11-10T01:00:00Z',
    );
    expect(
      observationId(
        source: context,
        fingerprint: alertFingerprint(context, labels('critical')),
        key: resolved,
      ),
      isNot(id(resolved)),
    );
  });

  test('ID-7c explicit severity exclusion', () {
    for (final severity in ['warning', 'critical']) {
      final selected = selectAlertmanagerIdentity(
        {'alertname': 'Example', 'severity': severity},
        excludedLabels: ['severity'],
      );
      expect(
        alertFingerprint(context, selected),
        'f3b0a969d2f337190a415e99cde94555c1983fe10cf9254291633acb17e507c0',
      );
    }
    expect(
      () => selectAlertmanagerIdentity(
        {'severity': 'warning'},
        excludedLabels: ['severity'],
      ),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => selectAlertmanagerIdentity({'a': 'x'}, excludedLabels: ['a', 'a']),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => selectAlertmanagerIdentity(
        {'x' * 129: 'value'},
        excludedLabels: ['x' * 129],
      ),
      throwsA(isA<EventFieldError>()),
    );
  });

  test('Separate and explicitly shared namespaces', () {
    final second = SourceContext(
      sourceInstance: _other,
      sourceKind: 'alertmanager',
    );
    expect(alertFingerprint(second, labels()), isNot(_fingerprint));
    final sharedA = SourceContext(
      sourceInstance: _source,
      sourceKind: 'alertmanager',
      namespace: 'shared',
    );
    final sharedB = SourceContext(
      sourceInstance: _other,
      sourceKind: 'alertmanager',
      namespace: 'shared',
    );
    final sharedFingerprint = alertFingerprint(sharedA, labels());
    expect(alertFingerprint(sharedB, labels()), sharedFingerprint);
    expect(
      observationId(
        source: sharedA,
        fingerprint: sharedFingerprint,
        key: observation(),
      ),
      isNot(
        observationId(
          source: sharedB,
          fingerprint: sharedFingerprint,
          key: observation(),
        ),
      ),
    );
  });

  test('ID-6 reordered and re-batched observations', () {
    final observations = [observation(), ObservationKey.native('sample-7')];
    final expected = [
      '86fe3b73-ec2d-5dd3-b104-11f2ec79469c',
      '14e8d912-67ad-596d-9d06-334a19020bce',
    ];
    expect(observations.map(id), expected);
    expect(observations.reversed.map(id), expected.reversed);
    expect(id(observation()), expected.first);
  });

  test('Redelivery after clock clamping changes', () {
    const reported = '2026-11-10T02:00:00.123456789+02:00';
    final key = ObservationKey.fallback(
      status: 'firing',
      severity: 'warning',
      reportedSourceTime: reported,
    );
    expect(key.reportedSourceTime, reported);
    expect(id(key), '90bcf08e-db05-5624-9468-a273bb383ae9');
    // Equivalent normalized instants are deliberately distinct reported evidence.
    final alternate = ObservationKey.fallback(
      status: 'firing',
      severity: 'warning',
      reportedSourceTime: '2026-11-10T00:00:00.123456789Z',
    );
    expect(id(alternate), isNot(id(key)));
  });

  test('Missing fallback evidence', () {
    for (final time in <String?>[
      null,
      '',
      '2026-11-10T00:00:00',
      '2026-02-30T00:00:00Z',
      '2026-11-10T00:00:60Z',
      '2026-11-10T00:00:00.1234567890Z',
      '2026-11-10T00:00:00+24:00',
    ]) {
      expect(
        () => ObservationKey.fallback(
          status: 'firing',
          severity: 'warning',
          reportedSourceTime: time,
        ),
        throwsA(isA<EventFieldError>()),
      );
    }
    expect(
      () => ObservationKey.alertmanager(status: 'firing'),
      throwsA(isA<EventFieldError>()),
    );
    expect(() => ObservationKey.native(''), throwsA(isA<EventFieldError>()));
  });

  test('Different observation or generation', () {
    final native = ObservationKey.native('sample-7');
    expect(id(native, generation: 1), '8c725bb2-0056-5289-a274-9fe214079d2c');
    expect(
      id(native, generation: 4294967295),
      '1e716134-3300-5ee0-8687-3c5de9e51b18',
    );
    expect(id(ObservationKey.native('sample-8')), isNot(id(native)));
    for (final generation in [-1, 4294967296]) {
      expect(
        () => id(native, generation: generation),
        throwsA(isA<EventFieldError>()),
      );
    }
  });

  test('Exact transport retry', () {
    final digest = _hex(
      '230d8358dc8e8890b4c58deeb62912ee2f20357ae92a5cc861b98e68fe31acb5',
    );
    expect(
      transportKey(sourceInstance: _source, bodySha256: digest),
      'aebd013e6cd269fdbe0d6cedd11b0addd06d716a9c94eae730c08ecf3f0b932a',
    );
    expect(
      transportKey(sourceInstance: _source, bodySha256: digest),
      transportKey(
        sourceInstance: _source,
        bodySha256: Uint8List.fromList(digest),
      ),
    );
    expect(
      transportKey(sourceInstance: _other, bodySha256: digest),
      isNot(transportKey(sourceInstance: _source, bodySha256: digest)),
    );
    expect(
      transportKey(sourceInstance: _source, idempotencyKey: 'retry-7'),
      'b1643d671d0b5e4d8bfeab1b4eecf5316f1174044cd9854ce989d4e109a65926',
    );
  });

  test('Distinct delivery evidence', () {
    final a = transportKey(sourceInstance: _source, bodySha256: Uint8List(32));
    final b = transportKey(
      sourceInstance: _source,
      bodySha256: Uint8List.fromList(List.filled(32, 1)),
    );
    expect(a, isNot(b));
    expect(id(observation()), '86fe3b73-ec2d-5dd3-b104-11f2ec79469c');
    expect(
      transportKey(
        sourceInstance: _source,
        idempotencyKey: 'retry-7',
        bodySha256: Uint8List(32),
      ),
      'b1643d671d0b5e4d8bfeab1b4eecf5316f1174044cd9854ce989d4e109a65926',
    );
    for (final key in ['', 'x' * 257]) {
      expect(
        () => transportKey(
          sourceInstance: _source,
          idempotencyKey: key,
          bodySha256: Uint8List(32),
        ),
        throwsA(isA<EventFieldError>()),
      );
    }
    expect(
      () => transportKey(sourceInstance: _source, bodySha256: Uint8List(31)),
      throwsA(isA<EventFieldError>()),
    );
  });

  test('Raw and hash tags, absent and present evidence', () {
    expect(
      alertFingerprint(context, identityComponents({'host': ''})),
      'e1e415588e0ce58657980ae648e738519143ca292f0c31dd914e3e33eeb821cc',
    );
    expect(IdentityComponent.fromText('').encode(), [0]);
    final hashed = identityComponents({'host': 'é' * 513});
    expect(
      alertFingerprint(context, hashed),
      '2df719aaa19bf0b8af3ec5512e85c273aa0998b94d62bd1c07c8ed4436f0d4f8',
    );
    final raw = identityComponents({
      'host':
          'sha256:085638aad30c4fc37eb096d1d73961417bd64ffeba69c29889fe224926179d17',
    });
    expect(
      alertFingerprint(context, raw),
      isNot(alertFingerprint(context, hashed)),
    );
    expect(IdentityComponent.fromText('é' * 512).raw, 'é' * 512);
    final input = Uint8List(32);
    final component = IdentityComponent.fromDigest(input);
    input[0] = 1;
    expect(component.digest!.first, 0);
    expect(() => component.digest![0] = 2, throwsUnsupportedError);
    expect(
      id(ObservationKey.alertmanager(status: 'firing', startsAt: _time)),
      isNot(id(ObservationKey.alertmanager(status: 'firing', endsAt: _time))),
    );
    final bytes = observation().bytes;
    expect(() => bytes[0] = 255, throwsUnsupportedError);
    expect(
      ObservationKey.fromBytes(observation().bytes).bytes,
      observation().bytes,
    );
    expect(
      () => ObservationKey.fromBytes(Uint8List.fromList(utf8.encode('bad'))),
      throwsA(isA<EventFieldError>()),
    );
  });

  test('Identity inputs reject invalid scope, Unicode and aggregate work', () {
    expect(
      () => SourceContext(
        sourceInstance: _source.toUpperCase(),
        sourceKind: 'alertmanager',
        namespace: '',
      ),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => SourceContext(
        sourceInstance: _source,
        sourceKind: 'Bad-Kind!alertmanager',
      ),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => identityComponents({'x': String.fromCharCode(0xd800)}),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => identityComponents({'x': 'x' * 1048577}),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => identityComponents({for (var n = 0; n < 129; n++) 'k$n': 'v'}),
      throwsA(isA<EventFieldError>()),
    );
    expect(
      () => ObservationKey.fallback(
        status: 'invalid',
        severity: 'warning',
        reportedSourceTime: _time,
      ),
      throwsA(isA<EventFieldError>()),
    );
  });
}

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
