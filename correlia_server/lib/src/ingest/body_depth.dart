import 'dart:typed_data';

import '../event/validation.dart';

/// The deepest JSON nesting a webhook body may have.
const maxBodyDepth = 32;

/// Rejects a body nested deeper than [maxBodyDepth] with `depth_bound` on `body`.
///
/// Run it before `jsonDecode`, so deeply nested input cannot overflow the
/// parser's stack. It scans bytes and tracks strings, so it needs no parse.
void checkBodyDepth(Uint8List bytes) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final byte in bytes) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (byte == 0x5c) {
        escaped = true;
      } else if (byte == 0x22) {
        inString = false;
      }
    } else if (byte == 0x22) {
      inString = true;
    } else if (byte == 0x7b || byte == 0x5b) {
      if (++depth > maxBodyDepth) {
        throw const EventFieldError('body', 'depth_bound');
      }
    } else if (byte == 0x7d || byte == 0x5d) {
      depth--;
    }
  }
}
