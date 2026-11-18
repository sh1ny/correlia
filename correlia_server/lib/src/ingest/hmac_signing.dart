import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Encodes the unambiguous prefix shared by all HMAC comparisons for a request.
List<int> ingressSigningPrefix(String timestamp, String? idempotencyKey) {
  final keyDigest = idempotencyKey == null
      ? '-'
      : sha256.convert(utf8.encode(idempotencyKey)).toString();
  return ascii.encode('$timestamp.$keyDigest.');
}

/// Signs the prefix and exact request body without copying the body.
String signIngress(List<int> key, List<int> prefix, List<int> body) {
  final sink = _DigestSink();
  Hmac(sha256, key).startChunkedConversion(sink)
    ..add(prefix)
    ..add(body)
    ..close();
  return sink.digest.toString();
}

final class _DigestSink implements Sink<Digest> {
  late Digest digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}
