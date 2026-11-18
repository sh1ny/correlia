import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/secrets/aead.dart';
import 'package:correlia_server/src/secrets/commitments.dart';
import 'package:test/test.dart';

Uint8List hex(String input) => Uint8List.fromList([
  for (var i = 0; i < input.length; i += 2)
    int.parse(input.substring(i, i + 2), radix: 16),
]);

Uint8List changed(Uint8List bytes, int index) =>
    Uint8List.fromList(bytes)..[index] ^= 1;

void main() {
  group('AES-256-GCM', () {
    late SecretAead aead;
    setUp(() => aead = SecretAead(Uint8List(32)));

    test('opens the NIST zero-key empty-message vector', () {
      expect(
        aead.open(
          Uint8List(12),
          hex('530f8afbc74536b9a963b4f1c4cb738b'),
          Uint8List(0),
        ),
        isEmpty,
      );
    });

    test('opens the NIST zero-key block vector', () {
      expect(
        aead.open(
          Uint8List(12),
          hex(
            'cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919',
          ),
          Uint8List(0),
        ),
        orderedEquals(Uint8List(16)),
      );
    });

    test('rejects changes to AAD, nonce, ciphertext, or tag', () {
      final bytes = utf8.encode('sealed data');
      final aad = utf8.encode('config-key');
      final sealed = aead.seal(bytes, aad);
      expect(
        aead.open(sealed.nonce, sealed.ciphertext, aad),
        orderedEquals(bytes),
      );
      for (final (nonce, ciphertext, associated) in [
        (sealed.nonce, sealed.ciphertext, changed(aad, 0)),
        (changed(sealed.nonce, 0), sealed.ciphertext, aad),
        (sealed.nonce, changed(sealed.ciphertext, 0), aad),
        (
          sealed.nonce,
          changed(sealed.ciphertext, sealed.ciphertext.length - 1),
          aad,
        ),
      ]) {
        expect(
          () => aead.open(nonce, ciphertext, associated),
          throwsA(isA<SecretIntegrityError>()),
        );
      }
    });

    test('sealing equal bytes twice uses independent nonces', () {
      final bytes = utf8.encode('sealed data');
      final aad = utf8.encode('config-key');
      final first = aead.seal(bytes, aad);
      final second = aead.seal(bytes, aad);
      expect(first.nonce, isNot(orderedEquals(second.nonce)));
      expect(first.ciphertext, isNot(orderedEquals(second.ciphertext)));
      expect(
        aead.open(second.nonce, second.ciphertext, aad),
        orderedEquals(bytes),
      );
    });
  });

  test(
    'key commitment, HKDF and keyed plugin commitment match fixed vectors',
    () {
      final key = Uint8List.fromList(List.generate(32, (index) => index));
      final commitments = SecretCommitments(key);
      expect(
        commitments.keyCommitment,
        '7574950143d706198a5dc6fabbb5c35b42d2962b0801879a31cc41ecb7873d94',
      );
      expect(
        deriveCommitmentKey(key),
        orderedEquals(
          hex(
            '75db9a7f61d89ca2caa6a111c4b2d1e7e4dde5e882079d8143ef6d9440085363',
          ),
        ),
      );
      expect(
        commitments.plugin('config-key', utf8.encode('plugin secret')),
        'hmac-sha256:81a6b8847abfd2b190a08d1aca8781479f0c5ff8a2a36038bca950f4df742811',
      );
    },
  );

  test('each commitment scheme validates only its own value', () {
    final commitments = SecretCommitments(Uint8List(32));
    final bytes = utf8.encode('plugin secret');
    final plain = legacySecretCommitment(bytes);
    final plugin = commitments.plugin('config-key', bytes);
    expect(commitments.verify('config-key', plain, bytes), isTrue);
    expect(commitments.verify('config-key', plugin, bytes), isTrue);
    expect(
      commitments.verify('config-key', 'hmac-sha256:$plain', bytes),
      isFalse,
    );
    expect(
      commitments.verify('config-key', plugin.substring(12), bytes),
      isFalse,
    );
    expect(commitments.verify('different-key', plugin, bytes), isFalse);
    expect(
      commitments.verify('config-key', plugin, changed(bytes, 0)),
      isFalse,
    );
    expect(commitments.verify('config-key', 'unknown:$plain', bytes), isFalse);
  });
}
