/// The tier tags a `withServerpod` group may carry (design D4).
const tierTags = ['db', 'e2e', 'plugin', 'load'];

/// 1-based lines of the `withServerpod(` calls in [source] whose
/// `testGroupTagsOverride:` argument is missing or names no tier tag.
///
/// Serverpod's `withServerpod` tags its group `integration` unless told
/// otherwise, and the fast preset must never see such a test as untagged.
/// Detection is lexical: comments are blanked and string bodies are ignored
/// when looking for calls and for the argument (so a mention inside a comment
/// or a string is not a call), and the argument must be a direct argument of
/// the call. The tags are read from string literals in its value. It does not
/// resolve constants, so a tag held in a variable is reported.
List<int> untaggedWithServerpodCalls(String source) {
  final code = _blank(source, keepStrings: false);
  final withStrings = _blank(source, keepStrings: true);
  final calls = RegExp(r'(?<![A-Za-z0-9_$])withServerpod\s*\(');
  final lines = <int>[];
  for (final call in calls.allMatches(code)) {
    final open = call.end - 1;
    final close = _closing(code, open);
    final args = (open + 1, close);
    if (!_hasTierOverride(code, withStrings, args)) {
      lines.add('\n'.allMatches(source.substring(0, call.start)).length + 1);
    }
  }
  return lines;
}

bool _hasTierOverride(String code, String withStrings, (int, int) args) {
  final (start, end) = args;
  final key = RegExp(r'testGroupTagsOverride\s*:');
  var depth = 0;
  for (var i = start; i < end; i++) {
    switch (code[i]) {
      case '(' || '[' || '{':
        depth++;
      case ')' || ']' || '}':
        depth--;
      default:
        if (depth == 0) {
          final match = key.matchAsPrefix(code, i);
          if (match != null) {
            final value = _valueEnd(code, match.end, end);
            final text = withStrings.substring(match.end, value);
            return RegExp(
              '[\'"](${tierTags.join('|')})[\'"]',
            ).hasMatch(text);
          }
        }
    }
  }
  return false;
}

/// End of the argument value that starts at [from]: the next top-level comma.
int _valueEnd(String code, int from, int limit) {
  var depth = 0;
  for (var i = from; i < limit; i++) {
    switch (code[i]) {
      case '(' || '[' || '{':
        depth++;
      case ')' || ']' || '}':
        depth--;
      case ',' when depth == 0:
        return i;
    }
  }
  return limit;
}

/// Index of the `)` matching the `(` at [open], or the end of [code].
int _closing(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    switch (code[i]) {
      case '(':
        depth++;
      case ')':
        depth--;
        if (depth == 0) return i;
    }
  }
  return code.length;
}

final _stringStart = RegExp("^r?('''|\"\"\"|'|\")");

/// [source] with comments replaced by spaces and, unless [keepStrings], string
/// bodies too (quotes stay). Newlines are kept, so offsets and lines match.
String _blank(String source, {required bool keepStrings}) {
  final out = StringBuffer();
  var i = 0;
  String blank(String s) => s.replaceAll(RegExp(r'[^\n]'), ' ');
  while (i < source.length) {
    final rest = source.substring(i);
    if (rest.startsWith('//')) {
      final end = source.indexOf('\n', i);
      final stop = end == -1 ? source.length : end;
      out.write(blank(source.substring(i, stop)));
      i = stop;
    } else if (rest.startsWith('/*')) {
      var depth = 0;
      var j = i;
      do {
        if (source.startsWith('/*', j)) {
          depth++;
          j += 2;
        } else if (source.startsWith('*/', j)) {
          depth--;
          j += 2;
        } else {
          j++;
        }
      } while (depth > 0 && j < source.length);
      out.write(blank(source.substring(i, j)));
      i = j;
    } else if (_stringStart.firstMatch(rest) case final match?) {
      final opener = match.group(0)!;
      final raw = opener.startsWith('r');
      final quote = opener.substring(raw ? 1 : 0);
      var j = i + opener.length;
      while (j < source.length && !source.startsWith(quote, j)) {
        // A newline ends a single-quoted string even when unterminated.
        if (quote.length == 1 && source[j] == '\n') break;
        j += !raw && source[j] == r'\' ? 2 : 1;
      }
      j = j > source.length ? source.length : j;
      final body = source.substring(i + opener.length, j);
      final closed = source.startsWith(quote, j) ? quote : '';
      out
        ..write(opener)
        ..write(keepStrings ? body : blank(body))
        ..write(closed);
      i = j + closed.length;
    } else {
      out.write(source[i]);
      i++;
    }
  }
  return out.toString();
}
