import 'dart:convert';

const _tokens = {0: '~!!', 0x21: '~!^', 0x5e: '~^!', 0x7e: '~^^'};

/// Encodes matcher text into PostgreSQL's NUL-free scalar alphabet.
String encodeMatcherText(String text) {
  StringBuffer? out;
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final token = _tokens[text.codeUnitAt(i)];
    if (token == null) continue;
    (out ??= StringBuffer())
      ..write(text.substring(start, i))
      ..write(token);
    start = i + 1;
  }
  if (out == null) return text;
  out.write(text.substring(start));
  return out.toString();
}

/// Reads an encoded matcher string and rejects malformed scalar tokens.
String decodeMatcherText(String text) {
  if (text.contains('\u0000')) {
    throw const FormatException('matcher_encoding');
  }
  final start = text.indexOf(_reservedText);
  if (start == -1) return text;
  final result = StringBuffer(text.substring(0, start));
  for (var i = start; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code == 0x7e && i + 2 < text.length) {
      final token = text.substring(i, i + 3);
      final rune = switch (token) {
        '~!!' => 0,
        '~!^' => 0x21,
        '~^!' => 0x5e,
        '~^^' => 0x7e,
        _ => throw const FormatException('matcher_encoding'),
      };
      result.writeCharCode(rune);
      i += 2;
    } else {
      if (_tokens.containsKey(code)) {
        throw const FormatException('matcher_encoding');
      }
      result.writeCharCode(code);
    }
  }
  return result.toString();
}

final _reservedText = RegExp(r'[~!^]');

/// A case-sensitive pattern validated for both matcher engines.
final class MatcherRegex {
  const MatcherRegex._(this.dartPattern, this.sqlPattern, this.groupCount);

  /// Parses the portable dialect and rejects excessively expanded patterns.
  static MatcherRegex parse(String source) {
    if (source.length > 256 || utf8.encode(source).length > 256) {
      throw const FormatException('regex_too_long');
    }
    final parser = _Parser(source.runes.iterator);
    final result = parser.expression();
    if (parser.current != null) _invalid();
    return MatcherRegex._(result.dart, result.sql, parser.groupCount);
  }

  /// The Dart pattern, for Unicode matching with dot-all enabled.
  final String dartPattern;

  /// The PostgreSQL ARE pattern, for C collation with `s` mode.
  final String sqlPattern;

  /// The number of capturing groups available to extraction.
  final int groupCount;
}

typedef _Fragment = ({String dart, String sql, int cost});

Never _invalid() => throw const FormatException('invalid_regex');

const _limit = 2048;

int _checkCost(int cost) {
  if (cost > _limit) throw const FormatException('regex_too_complex');
  return cost;
}

_Fragment _literal(int rune) {
  final dart = RegExp.escape(String.fromCharCode(rune));
  final token = _tokens[rune];
  if (token == null) return (dart: dart, sql: dart, cost: 1);
  return (dart: dart, sql: '(?:${RegExp.escape(token)})', cost: 5);
}

final class _Parser {
  _Parser(this._runes) {
    advance();
  }

  final RuneIterator _runes;
  int? current;
  int groupCount = 0;

  void advance() => current = _runes.moveNext() ? _runes.current : null;

  bool eat(int rune) {
    if (current != rune) return false;
    advance();
    return true;
  }

  _Fragment expression() {
    final first = sequence();
    if (current != 0x7c) return first;
    final dart = StringBuffer(first.dart);
    final sql = StringBuffer(first.sql);
    var cost = first.cost;
    while (eat(0x7c)) {
      final branch = sequence();
      cost = _checkCost(cost + branch.cost + 2);
      dart.write('|${branch.dart}');
      sql.write('|${branch.sql}');
    }
    return (dart: dart.toString(), sql: sql.toString(), cost: cost);
  }

  _Fragment sequence() {
    final dart = StringBuffer();
    final sql = StringBuffer();
    var cost = 0;
    while (current != null && current != 0x29 && current != 0x7c) {
      final next = repetition(atom());
      cost = _checkCost(cost + next.cost);
      dart.write(next.dart);
      sql.write(next.sql);
    }
    if (dart.isEmpty) _invalid();
    return (dart: dart.toString(), sql: sql.toString(), cost: cost);
  }

  _Fragment atom() {
    final rune = current!;
    advance();
    switch (rune) {
      case 0x28:
        groupCount++;
        final group = expression();
        if (!eat(0x29)) _invalid();
        return (
          dart: '(${group.dart})',
          sql: '(?:${group.sql})',
          cost: _checkCost(group.cost + 2),
        );
      case 0x5b:
        return characterClass();
      case 0x2e:
        return (dart: '.', sql: r'(?:~[!^][!^]|[^~!^])', cost: 8);
      case 0x5c:
        return _literal(escaped());
      case 0x2a || 0x2b || 0x3f || 0x7b || 0x7d || 0x5d || 0x5e || 0x24:
        _invalid();
      default:
        return _literal(rune);
    }
  }

  _Fragment repetition(_Fragment body) {
    final String suffix;
    final int copies;
    if (eat(0x2a)) {
      suffix = '*';
      copies = 1;
    } else if (eat(0x2b)) {
      suffix = '+';
      copies = 1;
    } else if (eat(0x3f)) {
      suffix = '?';
      copies = 1;
    } else if (eat(0x7b)) {
      final min = count();
      if (eat(0x2c)) {
        if (eat(0x7d)) {
          suffix = '{$min,}';
          copies = min + 1;
        } else {
          final max = count();
          if (min > max || !eat(0x7d)) _invalid();
          suffix = '{$min,$max}';
          copies = max;
        }
      } else {
        if (!eat(0x7d)) _invalid();
        suffix = '{$min}';
        copies = min;
      }
    } else {
      return body;
    }
    return (
      dart: '${body.dart}$suffix',
      sql: '${body.sql}$suffix',
      cost: _checkCost(body.cost * (copies == 0 ? 1 : copies) + 2),
    );
  }

  int count() {
    var value = 0;
    var digits = 0;
    while (true) {
      final rune = current;
      if (rune == null || rune < 0x30 || rune > 0x39) break;
      value = value * 10 + rune - 0x30;
      if (value > 255) _invalid();
      digits++;
      advance();
    }
    if (digits == 0) _invalid();
    return value;
  }

  int escaped() {
    final next = current;
    if (next == null ||
        !r'\.^$|?*+()[]{}-!~'.contains(String.fromCharCode(next))) {
      _invalid();
    }
    advance();
    return next;
  }

  int classMember() {
    if (eat(0x5c)) return escaped();
    final rune = current;
    if (rune == null ||
        rune > 127 ||
        rune == 0x5d ||
        rune == 0x5b ||
        rune == 0x2d ||
        rune == 0x5e) {
      _invalid();
    }
    advance();
    return rune;
  }

  _Fragment characterClass() {
    // Coalesce ranges before projection so repeated members cannot increase
    // generated regex size. Reserved members are removed from the SQL class.
    final members = List<bool>.filled(128, false);
    do {
      final first = classMember();
      final last = eat(0x2d) ? classMember() : first;
      if (last < first) _invalid();
      for (var i = first; i <= last; i++) {
        members[i] = true;
      }
    } while (!eat(0x5d));
    final dart = '[${_classRanges(members)}]';
    final tokens = <String>[];
    for (final entry in _tokens.entries) {
      if (!members[entry.key]) continue;
      members[entry.key] = false;
      tokens.add(RegExp.escape(entry.value));
    }
    final unreserved = _classRanges(members);
    if (tokens.isEmpty) return (dart: dart, sql: dart, cost: 1);
    if (unreserved.isNotEmpty) tokens.add('[$unreserved]');
    final cost =
        (unreserved.isEmpty ? 0 : 1) +
        (tokens.length - (unreserved.isEmpty ? 0 : 1)) * 3 +
        (tokens.length - 1) * 2 +
        2;
    return (dart: dart, sql: '(?:${tokens.join('|')})', cost: cost);
  }
}

String _classRanges(List<bool> members) {
  final out = StringBuffer();
  for (var i = 0; i < members.length; i++) {
    if (!members[i]) continue;
    final start = i;
    while (i + 1 < members.length && members[i + 1]) {
      i++;
    }
    out.write(_classEscape(start));
    if (i > start + 1) out.write('-');
    if (i > start) out.write(_classEscape(i));
  }
  return out.toString();
}

String _classEscape(int rune) {
  final char = String.fromCharCode(rune);
  return r'\-[]^'.contains(char) ? '\\$char' : char;
}

/// A whole-value glob whose only wildcards are `*` and `?`.
final class MatcherGlob {
  const MatcherGlob._(this._pattern, this.sqlPattern);

  final List<int> _pattern;

  /// The anchored PostgreSQL pattern over encoded matcher text.
  final String sqlPattern;

  static const _star = -1;
  static const _one = -2;
  static const _scalar = r'(?:~[!^][!^]|[^~!^])';

  /// Parses a glob, where backslash can escape a wildcard or backslash.
  static MatcherGlob parse(String source) {
    if (source.length > 256 || utf8.encode(source).length > 256) {
      throw const FormatException('glob_too_long');
    }
    final pattern = <int>[];
    final sql = StringBuffer('^');
    final runes = source.runes.iterator;
    while (runes.moveNext()) {
      final rune = runes.current;
      switch (rune) {
        case 0x2a:
          if (pattern.isNotEmpty && pattern.last == _star) continue;
          pattern.add(_star);
          sql.write('$_scalar*');
        case 0x3f:
          pattern.add(_one);
          sql.write(_scalar);
        case 0x5c:
          if (!runes.moveNext() ||
              !const {0x5c, 0x2a, 0x3f}.contains(runes.current)) {
            throw const FormatException('invalid_glob_escape');
          }
          pattern.add(runes.current);
          sql.write(_literal(runes.current).sql);
        default:
          pattern.add(rune);
          sql.write(_literal(rune).sql);
      }
    }
    sql.write(r'$');
    return MatcherGlob._(pattern, sql.toString());
  }

  /// Matches [input] with at most one active wildcard backtracking point.
  bool matches(String input) {
    var i = 0;
    var p = 0;
    var star = -1;
    var retry = 0;
    while (i < input.length) {
      final (rune, width) = _runeAt(input, i);
      if (p < _pattern.length) {
        final atom = _pattern[p];
        if (atom == _one || atom == rune) {
          p++;
          i += width;
          continue;
        }
        if (atom == _star) {
          star = p++;
          retry = i;
          continue;
        }
      }
      if (star < 0) return false;
      retry += _runeAt(input, retry).$2;
      i = retry;
      p = star + 1;
    }
    return p == _pattern.length ||
        (p == _pattern.length - 1 && _pattern[p] == _star);
  }
}

(int, int) _runeAt(String text, int index) {
  final high = text.codeUnitAt(index);
  if (high >= 0xd800 && high <= 0xdbff && index + 1 < text.length) {
    final low = text.codeUnitAt(index + 1);
    if (low >= 0xdc00 && low <= 0xdfff) {
      return (0x10000 + ((high - 0xd800) << 10) + low - 0xdc00, 2);
    }
  }
  return (high, 1);
}
