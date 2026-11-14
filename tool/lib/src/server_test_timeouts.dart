/// Returns the 1-based lines of test calls without a direct timeout.
///
/// Only sources tagged `e2e` or naming `ChildServer` are checked. A library
/// `@Timeout` annotation covers the whole file. Detection is lexical: comments
/// and string contents do not count as calls or identifiers, and nested
/// `timeout:` arguments do not cover an enclosing test.
List<int> testsWithoutTimeout(String source) {
  final code = _blank(source, keepStrings: false);
  final withStrings = _blank(source, keepStrings: true);
  final tags = RegExp(r'@Tags\s*\(');
  final hasE2eTag = tags.allMatches(code).any((tag) {
    final close = _closing(code, tag.end - 1);
    return RegExp(
      r'''['"]e2e['"]''',
    ).hasMatch(withStrings.substring(tag.end, close));
  });
  if (!hasE2eTag &&
      !RegExp(
        r'(?<![A-Za-z0-9_$])ChildServer(?![A-Za-z0-9_$])',
      ).hasMatch(code)) {
    return [];
  }

  final library = RegExp(
    r'\blibrary\s*(?:[A-Za-z_$][\w$.]*\s*)?;',
  ).firstMatch(code);
  if (library != null) {
    for (final annotation in RegExp(r'@Timeout\s*\(').allMatches(code)) {
      if (annotation.start >= library.start) break;
      var next = _closing(code, annotation.end - 1) + 1;
      // Other metadata can appear between Timeout and the library directive.
      final metadata = RegExp(r'\s*@[A-Za-z_$][\w$.]*\s*');
      while (next < library.start) {
        final match = metadata.matchAsPrefix(code, next);
        if (match == null) break;
        next = match.end;
        if (next < code.length && code[next] == '(') {
          next = _closing(code, next) + 1;
        }
      }
      if (code.substring(next, library.start).trim().isEmpty) return [];
    }
  }

  final lines = <int>[];
  final calls = RegExp(r'(?<![A-Za-z0-9_$])test\s*\(');
  for (final call in calls.allMatches(code)) {
    final close = _closing(code, call.end - 1);
    if (!_hasDirectTimeout(code, call.end, close)) {
      lines.add('\n'.allMatches(source.substring(0, call.start)).length + 1);
    }
  }
  return lines;
}

bool _hasDirectTimeout(String code, int start, int end) {
  var depth = 0;
  var argumentStart = start;
  for (var i = start; i <= end; i++) {
    if (i == end || (code[i] == ',' && depth == 0)) {
      if (RegExp(
        r'^\s*timeout\s*:',
      ).hasMatch(code.substring(argumentStart, i))) {
        return true;
      }
      argumentStart = i + 1;
    } else {
      switch (code[i]) {
        case '(' || '[' || '{':
          depth++;
        case ')' || ']' || '}':
          depth--;
      }
    }
  }
  return false;
}

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

String _blank(String source, {required bool keepStrings}) {
  final out = StringBuffer();
  var i = 0;
  String blank(String text) => text.replaceAll(RegExp(r'[^\n]'), ' ');
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
        if (quote.length == 1 && source[j] == '\n') break;
        j += !raw && source[j] == r'\' ? 2 : 1;
      }
      if (j > source.length) j = source.length;
      final closed = source.startsWith(quote, j) ? quote : '';
      final stop = j + closed.length;
      final text = source.substring(i, stop);
      out.write(keepStrings ? text : blank(text));
      i = stop;
    } else {
      out.write(source[i]);
      i++;
    }
  }
  return out.toString();
}
