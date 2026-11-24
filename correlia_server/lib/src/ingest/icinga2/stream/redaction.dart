import 'dart:convert';
import 'dart:typed_data';

/// The sanitized wire bytes and the original lexical verdict.
final class WireRedaction {
  /// Creates a wire redaction result.
  const WireRedaction({
    required this.bytes,
    required this.invalidJson,
    required this.redacted,
  });

  /// The sanitized input bytes.
  final Uint8List bytes;

  /// Whether the original input was invalid UTF-8 or JSON syntax.
  final bool invalidJson;

  /// Whether an authentication-secret echo was replaced.
  final bool redacted;
}

/// Redacts authentication-secret echoes before input reaches a semantic parser.
final class PasswordRedactor {
  /// Uses [password] and, when provided, the exact outbound Basic [basicToken].
  PasswordRedactor(Uint8List password, {String? basicToken}) {
    if (password.isEmpty) {
      throw ArgumentError('Icinga2 password must not be empty');
    }
    if (basicToken != null && basicToken.isEmpty) {
      throw ArgumentError('Icinga2 Basic token must not be empty');
    }
    final standard = base64.encode(password);
    final url = base64Url.encode(password);
    final forms = <List<int>>[
      List<int>.of(password),
      for (final value in {
        standard,
        standard.split('=').first,
        url,
        url.split('=').first,
        ?basicToken,
      })
        ascii.encode(value),
    ];
    _patterns = forms.map(_Pattern.new).toList(growable: false);
    // All candidates are outside both Base64 alphabets. Avoid the password's
    // ends too, so a match cannot enter the marker from either edge.
    final byte = const [0x21, 0x23, 0x25].firstWhere(
      (value) => value != password.first && value != password.last,
    );
    // A complete crossing would need more bytes than any raw password.
    // A longer username/token must not enlarge the replacement.
    _marker = Uint8List(standard.length)..fillRange(0, standard.length, byte);
  }

  late final List<_Pattern> _patterns;
  late final Uint8List _marker;

  /// Sanitizes input and retains its original JSON and UTF-8 syntax verdict.
  WireRedaction sanitize(Uint8List input) {
    final scanner = _Scanner(input, _patterns);
    final validUtf8 = _validUtf8(input);
    final validJson = scanner.validate();
    if (!validUtf8 || !validJson) {
      scanner.matchBytes(input, null, null);
      scanner.recoverStrings();
    }
    final changes = scanner.changes;
    if (changes == null) {
      return WireRedaction(
        bytes: input,
        invalidJson: !validUtf8 || !validJson,
        redacted: false,
      );
    }
    var depth = 0;
    var start = -1;
    final output = BytesBuilder(copy: false);
    var copied = 0;
    for (var i = 0; i <= input.length; i++) {
      final before = depth;
      depth += changes[i];
      if (before == 0 && depth > 0) start = i;
      if (before > 0 && depth == 0) {
        output.add(Uint8List.sublistView(input, copied, start));
        output.add(_marker);
        copied = i;
      }
    }
    output.add(Uint8List.sublistView(input, copied));
    return WireRedaction(
      bytes: output.takeBytes(),
      invalidJson: !validUtf8 || !validJson,
      redacted: true,
    );
  }
}

// Validate raw UTF-8 without materializing a copy of the unsanitized line.
bool _validUtf8(Uint8List input) {
  var i = 0;
  while (i < input.length) {
    final lead = input[i++];
    if (lead < 0x80) continue;
    final int following;
    if (lead >= 0xc2 && lead <= 0xdf) {
      following = 1;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      following = 2;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      following = 3;
    } else {
      return false;
    }
    if (i + following > input.length) return false;
    final first = input[i];
    if ((lead == 0xe0 && first < 0xa0) ||
        (lead == 0xed && first >= 0xa0) ||
        (lead == 0xf0 && first < 0x90) ||
        (lead == 0xf4 && first >= 0x90)) {
      return false;
    }
    for (var n = 0; n < following; n++) {
      if (input[i++] & 0xc0 != 0x80) return false;
    }
  }
  return true;
}

final class _Pattern {
  _Pattern(this.bytes) : failure = Uint32List(bytes.length) {
    var matched = 0;
    for (var i = 1; i < bytes.length; i++) {
      while (matched > 0 && bytes[i] != bytes[matched]) {
        matched = failure[matched - 1];
      }
      if (bytes[i] == bytes[matched]) matched++;
      failure[i] = matched;
    }
  }

  final List<int> bytes;
  final Uint32List failure;
}

final class _Scanner {
  _Scanner(this.input, this.patterns);

  final Uint8List input;
  final List<_Pattern> patterns;
  Int32List? changes;

  void matchBytes(
    List<int> bytes,
    List<int>? starts,
    List<int>? ends, {
    int from = 0,
    int? to,
  }) {
    final limit = to ?? bytes.length;
    for (final pattern in patterns) {
      var matched = 0;
      for (var i = from; i < limit; i++) {
        while (matched > 0 && bytes[i] != pattern.bytes[matched]) {
          matched = pattern.failure[matched - 1];
        }
        if (bytes[i] == pattern.bytes[matched]) matched++;
        if (matched == pattern.bytes.length) {
          final first = i + 1 - matched;
          final start = starts == null ? first : starts[first];
          final end = ends == null ? i + 1 : ends[i];
          final marks = changes ??= Int32List(input.length + 1);
          marks[start]++;
          marks[end]--;
          matched = pattern.failure[matched - 1];
        }
      }
    }
  }

  bool _space(int c) => c == 32 || c == 9 || c == 10 || c == 13;
  bool _digit(int c) => c >= 48 && c <= 57;

  int _hex(int c) {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 65 && c <= 70) return c - 55;
    if (c >= 97 && c <= 102) return c - 87;
    return -1;
  }

  int _unicode(int position) {
    if (position + 4 > input.length) return -1;
    var result = 0;
    for (var i = position; i < position + 4; i++) {
      final digit = _hex(input[i]);
      if (digit < 0) return -1;
      result = result * 16 + digit;
    }
    return result;
  }

  // Returns the first byte after a complete JSON string, or -1.
  int _string(int position, {bool recover = false}) {
    for (var i = position + 1; i < input.length; i++) {
      switch (input[i]) {
        case 34:
          matchBytes(input, null, null, from: position + 1, to: i);
          return i + 1;
        case 92:
          return _escapedString(position, recover: recover);
        case < 32 when !recover:
          return -1;
      }
    }
    if (recover) matchBytes(input, null, null, from: position + 1);
    return -1;
  }

  int _escapedString(int position, {required bool recover}) {
    final bytes = <int>[];
    final starts = <int>[];
    final ends = <int>[];
    var i = position + 1;
    void append(List<int> decoded, int start, int end) {
      for (final byte in decoded) {
        bytes.add(byte);
        starts.add(start);
        ends.add(end);
      }
    }

    while (i < input.length) {
      final start = i;
      final c = input[i++];
      if (c == 34) {
        matchBytes(bytes, starts, ends);
        return i;
      }
      if (c < 32 && !recover) return -1;
      if (c != 92) {
        bytes.add(c);
        starts.add(start);
        ends.add(i);
        continue;
      }
      if (i >= input.length) {
        if (recover) matchBytes(bytes, starts, ends);
        return -1;
      }
      final escape = input[i++];
      switch (escape) {
        case 34 || 92 || 47:
          append([escape], start, i);
        case 98:
          append([8], start, i);
        case 102:
          append([12], start, i);
        case 110:
          append([10], start, i);
        case 114:
          append([13], start, i);
        case 116:
          append([9], start, i);
        case 117:
          var code = _unicode(i);
          if (code < 0) {
            if (!recover) return -1;
            matchBytes(bytes, starts, ends);
            bytes.clear();
            starts.clear();
            ends.clear();
            continue;
          }
          i += 4;
          if (code >= 0xd800 &&
              code <= 0xdbff &&
              i + 6 <= input.length &&
              input[i] == 92 &&
              input[i + 1] == 117) {
            final low = _unicode(i + 2);
            if (low >= 0xdc00 && low <= 0xdfff) {
              code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00;
              i += 6;
            }
          }
          if (code >= 0xd800 && code <= 0xdfff) {
            // An isolated surrogate is not the UTF-8 replacement character.
            // Treat it as a barrier without changing its wire spelling.
            matchBytes(bytes, starts, ends);
            bytes.clear();
            starts.clear();
            ends.clear();
          } else {
            append(utf8.encode(String.fromCharCode(code)), start, i);
          }
        default:
          if (!recover) return -1;
          matchBytes(bytes, starts, ends);
          bytes.clear();
          starts.clear();
          ends.clear();
      }
    }
    if (recover) matchBytes(bytes, starts, ends);
    return -1;
  }

  void recoverStrings() {
    var i = 0;
    while (i < input.length) {
      if (input[i] != 34) {
        i++;
        continue;
      }
      final end = _string(i, recover: true);
      if (end < 0) return; // Recovery already scanned to the end.
      i = end;
    }
  }

  int _number(int i) {
    if (input[i] == 45) i++;
    if (i >= input.length) return -1;
    if (input[i] == 48) {
      i++;
    } else if (input[i] >= 49 && input[i] <= 57) {
      do {
        i++;
      } while (i < input.length && _digit(input[i]));
    } else {
      return -1;
    }
    if (i < input.length && input[i] == 46) {
      i++;
      if (i >= input.length || !_digit(input[i])) return -1;
      do {
        i++;
      } while (i < input.length && _digit(input[i]));
    }
    if (i < input.length && (input[i] == 101 || input[i] == 69)) {
      i++;
      if (i < input.length && (input[i] == 43 || input[i] == 45)) i++;
      if (i >= input.length || !_digit(input[i])) return -1;
      do {
        i++;
      } while (i < input.length && _digit(input[i]));
    }
    return i;
  }

  int _literal(int i, String text) {
    if (i + text.length > input.length) return -1;
    for (var n = 0; n < text.length; n++) {
      if (input[i + n] != text.codeUnitAt(n)) return -1;
    }
    return i + text.length;
  }

  bool validate() {
    // Root: 8 value, 9 end. Object: 0 first key, 1 colon, 2 value,
    // 3 separator, 4 subsequent key. Array: 5 first value, 6 separator,
    // 7 subsequent value. The explicit stack avoids recursion on deep input.
    final stack = <int>[8];
    var i = 0;
    while (true) {
      while (i < input.length && _space(input[i])) {
        i++;
      }
      final state = stack.last;
      if (state == 9) return i == input.length;
      if (i == input.length) return false;
      final c = input[i];
      if (state == 0 || state == 4) {
        if (state == 0 && c == 125) {
          stack.removeLast();
          i++;
        } else {
          if (c != 34) return false;
          i = _string(i);
          if (i < 0) return false;
          stack[stack.length - 1] = 1;
        }
      } else if (state == 1) {
        if (c != 58) return false;
        stack[stack.length - 1] = 2;
        i++;
      } else if (state == 3 || state == 6) {
        if (c == (state == 3 ? 125 : 93)) {
          stack.removeLast();
        } else if (c == 44) {
          stack[stack.length - 1] = state == 3 ? 4 : 7;
        } else {
          return false;
        }
        i++;
      } else {
        if (state == 5 && c == 93) {
          stack.removeLast();
          i++;
          continue;
        }
        stack[stack.length - 1] = state == 8 ? 9 : (state == 2 ? 3 : 6);
        if (c == 123 || c == 91) {
          stack.add(c == 123 ? 0 : 5);
          i++;
        } else if (c == 34) {
          i = _string(i);
        } else if (c == 45 || _digit(c)) {
          i = _number(i);
        } else if (c == 116) {
          i = _literal(i, 'true');
        } else if (c == 102) {
          i = _literal(i, 'false');
        } else if (c == 110) {
          i = _literal(i, 'null');
        } else {
          return false;
        }
        if (i < 0) return false;
      }
    }
  }
}
