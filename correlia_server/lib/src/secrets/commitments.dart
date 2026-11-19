import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _keyDomain = utf8.encode('correlia-kek-commitment-v1');
final _pluginDomain = utf8.encode('correlia-plugin-secret-v1');
final _commitmentInfo = utf8.encode('correlia-commitment-key-v1\u0001');
const _prefix = 'hmac-sha256:';

/// Returns the legacy lowercase SHA-256 commitment of [bytes].
String legacySecretCommitment(List<int> bytes) =>
    sha256.convert(bytes).toString();

/// Derives a 32-byte commitment key using HKDF-SHA256 with the default salt.
List<int> deriveCommitmentKey(Uint8List key) {
  final extracted = Hmac(sha256, Uint8List(32)).convert(key).bytes;
  return Hmac(sha256, extracted).convert(_commitmentInfo).bytes;
}

/// Compares equal-sized inputs without a data-dependent early exit.
bool secretBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var i = 0; i < left.length; i++) {
    difference |= left[i] ^ right[i];
  }
  return difference == 0;
}

/// Computes and verifies commitments for one encryption key.
final class SecretCommitments {
  /// Derives the plugin commitment key and the external key's commitment.
  SecretCommitments(Uint8List key)
    : keyCommitment = _digest(sha256, _keyDomain, key).toString(),
      _pluginMac = Hmac(sha256, deriveCommitmentKey(key));

  /// The SHA-256 commitment of the domain and raw encryption key.
  final String keyCommitment;
  final Hmac _pluginMac;

  /// Returns the keyed commitment of [reference] and [bytes].
  String plugin(String reference, List<int> bytes) =>
      '$_prefix${_digest(_pluginMac, _pluginDomain, utf8.encode(reference), bytes)}';

  /// Checks [expected] by its scheme independently of the record's scheme.
  bool verify(String reference, String expected, List<int> bytes) {
    final String computed;
    if (expected.length == 64) {
      computed = legacySecretCommitment(bytes);
    } else if (expected.length == _prefix.length + 64 &&
        expected.startsWith(_prefix)) {
      computed = plugin(reference, bytes);
    } else {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < computed.length; i++) {
      difference |= computed.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }
}

Digest _digest(
  Converter<List<int>, Digest> hash,
  List<int> first,
  List<int> second, [
  List<int>? third,
]) {
  final output = _DigestSink();
  final input = hash.startChunkedConversion(output);
  input.add(first);
  input.add(second);
  if (third != null) input.add(third);
  input.close();
  return output.value;
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
