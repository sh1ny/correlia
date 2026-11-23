import 'dart:convert';

import '../../../event/validation.dart';
import '../../body_depth.dart';

/// Decodes an already UTF-8-checked line with the shared nesting bound.
Map<String, Object?> readStreamJson(String text) {
  checkTextBodyDepth(text);
  final Object? value;
  try {
    value = jsonDecode(text);
  } on FormatException {
    throw const EventFieldError('body', 'invalid_json');
  }
  if (value is! Map<String, Object?>) {
    throw const EventFieldError('body', 'invalid_type');
  }
  return value;
}

/// Refuses duplicate and unknown members, naming only schema-owned segments.
///
/// [text] has already passed [readStreamJson]. A token scan is necessary
/// because Dart's JSON decoder discards all but the last duplicate key.
void guardStreamMembers(String text, Map<String, Set<String>> fields) {
  _MemberScan(text, fields).value('');
}

final class _MemberScan {
  _MemberScan(this.text, this.fields);

  final String text;
  final Map<String, Set<String>> fields;
  int offset = 0;

  void _space() {
    while (offset < text.length && text.codeUnitAt(offset) <= 0x20) {
      offset++;
    }
  }

  String? _string({required bool key}) {
    final start = offset++;
    var escaped = false;
    while (true) {
      switch (text.codeUnitAt(offset++)) {
        case 0x5c:
          escaped = true;
          offset++;
        case 0x22:
          return !key
              ? null
              : escaped
              ? jsonDecode(text.substring(start, offset)) as String
              : text.substring(start + 1, offset - 1);
      }
    }
  }

  void value(String path) {
    _space();
    switch (text.codeUnitAt(offset)) {
      case 0x7b: // {
        offset++;
        _space();
        if (text.codeUnitAt(offset) == 0x7d) {
          offset++;
          return;
        }
        final names = <String>{};
        final known = fields[path];
        while (true) {
          final key = _string(key: true)!;
          if (known == null || !known.contains(key)) {
            throw EventFieldError(
              path.isEmpty ? '*' : '$path.*',
              'unknown_field',
            );
          }
          final member = path.isEmpty ? key : '$path.$key';
          if (!names.add(key)) {
            throw EventFieldError(member, 'duplicate_field');
          }
          _space();
          offset++; // :
          value(member);
          _space();
          if (text.codeUnitAt(offset++) == 0x7d) return;
          _space();
        }
      case 0x5b: // [
        offset++;
        _space();
        if (text.codeUnitAt(offset) == 0x5d) {
          offset++;
          return;
        }
        while (true) {
          value(path);
          _space();
          if (text.codeUnitAt(offset++) == 0x5d) return;
        }
      case 0x22:
        _string(key: false);
      default:
        while (offset < text.length) {
          final c = text.codeUnitAt(offset);
          if (c <= 0x20 || c == 0x2c || c == 0x5d || c == 0x7d) return;
          offset++;
        }
    }
  }
}
