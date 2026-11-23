import 'dart:convert';

import 'package:crypto/crypto.dart';

/// HMAC-SHA-256 of [message] under [key], as 64 lowercase hex digits.
String hmacSha256Hex(List<int> key, List<int> message) =>
    Hmac(sha256, key).convert(message).toString();

/// The Correlia ingress signature of [body] (ADR 0029), as 64 hex digits.
///
/// The signed input is `ASCII(timestamp) 0x2e '-' 0x2e body`: the sender sends
/// no `Idempotency-Key`, so the key digest position holds `-`. The body is the
/// exact byte sequence that goes on the wire.
String ingressSignature(List<int> key, String timestamp, List<int> body) {
  final input = [...ascii.encode('$timestamp.-.'), ...body];
  return hmacSha256Hex(key, input);
}
