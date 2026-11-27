import 'dart:async';
import 'dart:io';

import '../event/canonical_event.dart';
import '../event/validation.dart';
import 'matcher_regex.dart';
import 'matcher_regex_worker.dart';

/// The regex operation supplied by the bounded pipeline evaluator.
typedef MatcherRegexTest = Future<bool> Function(String pattern, String input);

/// A validated condition shared by the Dart and PostgreSQL evaluators.
sealed class MatcherCondition {
  const MatcherCondition();

  /// Parses a single v1 condition tree.
  static MatcherCondition parse(Object? input) {
    var remaining = 1024;
    MatcherCondition visit(Object? node, int depth) {
      if (depth > 16 || --remaining < 0) _invalid('condition_limit');
      if (node is! Map<String, Object?>) _invalid('condition_shape');
      if (node.length == 1) {
        if (node.containsKey('not')) return _Not(visit(node['not'], depth + 1));
        final key = node.keys.single;
        if (key == 'all' || key == 'any') {
          final items = node[key];
          if (items is! List<Object?> || items.isEmpty) {
            _invalid('condition_shape');
          }
          return _Many(key == 'all', [
            for (final item in items) visit(item, depth + 1),
          ]);
        }
      }
      final field = node['field'];
      final op = node['op'];
      if (field is! String || op is! String) _invalid('condition_shape');
      final catalog = _Field.parse(field);
      if (op == 'exists') {
        if (node.length != 2) _invalid('condition_shape');
        return _Leaf(catalog, op, null);
      }
      if (node.length != 3 || !node.containsKey('value')) {
        _invalid('condition_shape');
      }
      final value = node['value'];
      Object operand(Object? raw) {
        if (raw is! String) _invalid('condition_operand');
        validateText(raw, 'condition.value', max: 16384);
        return switch (catalog.type) {
          _Type.text => raw,
          _Type.severity => _enumOperand(raw, EventSeverity.values),
          _Type.kind => _enumOperand(raw, EventKind.values),
          _Type.status => _enumOperand(raw, EventStatus.values),
        };
      }

      final normalized = switch (op) {
        'equals' || 'not_equals' => operand(value),
        'lt' ||
        'lte' ||
        'gt' ||
        'gte' when catalog.type == _Type.severity => operand(value),
        'in'
            when value is List<Object?> &&
                value.isNotEmpty &&
                value.length <= remaining =>
          value.map(operand).toSet(),
        'regex' when catalog.type == _Type.text && value is String =>
          MatcherRegex.parse(operand(value) as String),
        'glob' when catalog.type == _Type.text && value is String =>
          MatcherGlob.parse(operand(value) as String),
        'cidr' when catalog.type == _Type.text && value is String =>
          _Network.parse(value),
        _ => _invalid('condition_operand'),
      };
      if (value is List<Object?>) remaining -= value.length;
      return _Leaf(catalog, op, normalized);
    }

    return visit(input, 1);
  }

  /// Matches a normalized canonical event.
  ///
  /// Pipeline callers supply [regexTest] so user regex runs outside the
  /// pipeline isolate. The synchronous default is used by parity tests.
  Future<bool> matches(CanonicalEvent event, {MatcherRegexTest? regexTest}) =>
      _eval(event, regexTest ?? _localRegex, null);

  /// Evaluates like [matches] and records what each node did.
  ///
  /// The flow is the one [matches] uses: an `all` stops at its first false
  /// child and an `any` at its first true child, and the rest stay
  /// [LeafOutcome.notEvaluated]. A regex failure stops evaluation at once; it
  /// is reported in [ConditionExplanation.failureCode] instead of thrown, so
  /// the partial trace survives. Other errors propagate.
  Future<ConditionExplanation> explain(
    CanonicalEvent event, {
    MatcherRegexTest? regexTest,
  }) async {
    final trace = _newTrace();
    try {
      final result = await _eval(event, regexTest ?? _localRegex, trace);
      return ConditionExplanation._(trace, result, null);
    } on MatcherRegexUnavailable catch (error) {
      return ConditionExplanation._(trace, null, error.code);
    }
  }

  /// The condition tree with every node [LeafOutcome.notEvaluated], for a
  /// rule that was attempted but stopped before its condition ran.
  ConditionTrace unevaluated() => _newTrace();

  /// Compiles a predicate over the fixed `event.data` stored projection.
  ({String expression, Map<String, Object?> parameters}) compileSql() {
    final parameters = <String, Object?>{};
    String bind(Object value) {
      final name = 'matcher_${parameters.length}';
      parameters[name] = value;
      return '@$name';
    }

    return (expression: _sql(bind), parameters: parameters);
  }

  /// The one evaluation. A null [trace] is the no-op sink: nothing is built.
  Future<bool> _eval(
    CanonicalEvent event,
    MatcherRegexTest regex,
    ConditionTrace? trace,
  );
  ConditionTrace _newTrace();
  String _sql(String Function(Object) bind);
}

/// The kind of one node in a [ConditionTrace].
enum TraceKind { all, any, not, leaf }

/// What an evaluated or skipped leaf did.
enum LeafOutcome {
  /// The operator accepted the value.
  matched('matched'),

  /// The field was present and the operator rejected it. A trace names the
  /// operator after this label, as in `no match: value fails not_equals`.
  valueFails('no match: value fails'),

  /// The field was absent from the event.
  fieldMissing('no match: field missing'),

  /// Regex work failed; see [LeafTrace.failureCode].
  failed('failed'),

  /// Short-circuiting skipped the leaf.
  notEvaluated('not evaluated');

  const LeafOutcome(this.label);

  /// The operator-facing wording.
  final String label;
}

/// One node of an explained condition tree.
sealed class ConditionTrace {
  ConditionTrace._();

  /// The node kind.
  TraceKind get kind;

  /// Child nodes in condition order; empty for a leaf.
  List<ConditionTrace> get children;

  /// The node's truth value, or null when it was skipped or a failure
  /// stopped evaluation before it finished.
  bool? get result;
}

/// An `all`, `any` or `not` node.
final class CompositeTrace extends ConditionTrace {
  CompositeTrace._(this.kind, this.children) : super._();

  @override
  final TraceKind kind;

  @override
  final List<ConditionTrace> children;

  @override
  bool? get result => _result;
  bool? _result;
}

/// A leaf comparison.
final class LeafTrace extends ConditionTrace {
  LeafTrace._(this.field, this.operator, this._outcome) : super._();

  /// The dotted field path, such as `labels.site`.
  final String field;

  /// The operator name, such as `equals`.
  final String operator;

  @override
  TraceKind get kind => TraceKind.leaf;

  @override
  List<ConditionTrace> get children => const [];

  /// What the leaf did.
  LeafOutcome get outcome => _outcome;
  LeafOutcome _outcome;

  /// The regex failure code (`regex_timeout`, `regex_budget`, ...) when
  /// [outcome] is [LeafOutcome.failed].
  String? get failureCode => _failureCode;
  String? _failureCode;

  @override
  bool? get result => switch (_outcome) {
    LeafOutcome.matched => true,
    LeafOutcome.valueFails || LeafOutcome.fieldMissing => false,
    LeafOutcome.failed || LeafOutcome.notEvaluated => null,
  };
}

/// The result of [MatcherCondition.explain].
final class ConditionExplanation {
  ConditionExplanation._(this.trace, this.matched, this.failureCode);

  /// The explained tree.
  final ConditionTrace trace;

  /// Whether the condition matched; null when a failure stopped it.
  final bool? matched;

  /// The regex failure code that stopped evaluation, if any.
  final String? failureCode;
}

ConditionTrace? _child(ConditionTrace? trace, int index) =>
    trace?.children[index];

void _finish(ConditionTrace? trace, bool result, [LeafOutcome? outcome]) {
  switch (trace) {
    case CompositeTrace():
      trace._result = result;
    case LeafTrace():
      trace._outcome = outcome!;
    case null:
      break;
  }
}

/// An addressable text field for lookup and extraction actions.
final class MatcherTextField {
  const MatcherTextField._(this._field);
  final _Field _field;

  /// Resolves a text path against the shared condition catalog.
  static MatcherTextField parse(String path) {
    final field = _Field.parse(path);
    if (field.type != _Type.text) _invalid('condition_field');
    return MatcherTextField._(field);
  }

  /// Reads the value from the original event.
  String? read(CanonicalEvent event) => _field.read(event);
}

/// A validated CIDR used by the matcher location table.
final class MatcherNetwork {
  const MatcherNetwork._(this._network);
  final _Network _network;

  /// Parses a network using the same rules as the CIDR filter.
  static MatcherNetwork parse(String source) =>
      MatcherNetwork._(_Network.parse(source));

  /// Whether a textual address lies in this network.
  bool contains(String address) => _network.contains(address);
}

Future<bool> _localRegex(String pattern, String input) async =>
    RegExp(pattern, unicode: true, dotAll: true).hasMatch(input);

Never _invalid(String code) => throw FormatException(code);

String _enumOperand(String token, List<Enum> values) {
  if (!values.any((value) => value.name == token)) {
    _invalid('condition_operand');
  }
  return token;
}

final class _Not extends MatcherCondition {
  const _Not(this.child);
  final MatcherCondition child;

  @override
  ConditionTrace _newTrace() =>
      CompositeTrace._(TraceKind.not, [child._newTrace()]);

  @override
  Future<bool> _eval(
    CanonicalEvent event,
    MatcherRegexTest regex,
    ConditionTrace? trace,
  ) async {
    final result = !(await child._eval(event, regex, _child(trace, 0)));
    _finish(trace, result);
    return result;
  }

  @override
  String _sql(String Function(Object) bind) => '(NOT ${child._sql(bind)})';
}

final class _Many extends MatcherCondition {
  const _Many(this.all, this.children);
  final bool all;
  final List<MatcherCondition> children;

  @override
  ConditionTrace _newTrace() => CompositeTrace._(
    all ? TraceKind.all : TraceKind.any,
    [for (final child in children) child._newTrace()],
  );

  @override
  Future<bool> _eval(
    CanonicalEvent event,
    MatcherRegexTest regex,
    ConditionTrace? trace,
  ) async {
    var result = all;
    for (var i = 0; i < children.length; i++) {
      final childResult = await children[i]._eval(
        event,
        regex,
        _child(trace, i),
      );
      if (childResult != all) {
        result = childResult;
        break;
      }
    }
    _finish(trace, result);
    return result;
  }

  @override
  String _sql(String Function(Object) bind) =>
      '(${children.map((child) => child._sql(bind)).join(all ? ' AND ' : ' OR ')})';
}

final class _Leaf extends MatcherCondition {
  const _Leaf(this.field, this.op, this.operand);
  final _Field field;
  final String op;
  final Object? operand;

  @override
  ConditionTrace _newTrace() =>
      LeafTrace._(field.fullPath, op, LeafOutcome.notEvaluated);

  @override
  Future<bool> _eval(
    CanonicalEvent event,
    MatcherRegexTest regex,
    ConditionTrace? trace,
  ) async {
    final value = field.read(event);
    if (value == null) {
      _finish(trace, false, LeafOutcome.fieldMissing);
      return false;
    }
    final bool result;
    try {
      // Only a regex leaf waits; the other operators answer synchronously.
      final test = _test(value, regex);
      result = test is Future<bool> ? await test : test;
    } on MatcherRegexUnavailable catch (error) {
      if (trace is LeafTrace) {
        trace._outcome = LeafOutcome.failed;
        trace._failureCode = error.code;
      }
      rethrow;
    }
    _finish(
      trace,
      result,
      result ? LeafOutcome.matched : LeafOutcome.valueFails,
    );
    return result;
  }

  FutureOr<bool> _test(String value, MatcherRegexTest regex) {
    return switch (op) {
      'exists' => true,
      'equals' => value == operand,
      'not_equals' => value != operand,
      'in' => (operand! as Set<Object>).contains(value),
      'regex' => regex((operand! as MatcherRegex).dartPattern, value),
      'glob' => (operand! as MatcherGlob).matches(value),
      'cidr' => (operand! as _Network).contains(value),
      _ => switch (op) {
        'lt' => _rank[value]! < _rank[operand]!,
        'lte' => _rank[value]! <= _rank[operand]!,
        'gt' => _rank[value]! > _rank[operand]!,
        'gte' => _rank[value]! >= _rank[operand]!,
        _ => throw StateError('unhandled matcher operator'),
      },
    };
  }

  @override
  String _sql(String Function(Object) bind) {
    final value = field.sql(bind);
    if (op == 'exists') return '($value IS NOT NULL)';
    String text(Object operand) =>
        '${bind(encodeMatcherText(operand as String))}::text';
    final comparison = switch (op) {
      'equals' => '$value = ${text(operand!)}',
      'not_equals' => '$value <> ${text(operand!)}',
      'in' => '$value IN (${(operand! as Set<Object>).map(text).join(',')})',
      'regex' =>
        "regexp_like($value, ${bind((operand! as MatcherRegex).sqlPattern)}::text, 's')",
      'glob' =>
        "regexp_like($value, ${bind((operand! as MatcherGlob).sqlPattern)}::text, 's')",
      'cidr' => _cidrSql(value, bind((operand! as _Network).source)),
      _ =>
        "(CASE $value ${_rank.entries.map((e) => "WHEN '${e.key}' THEN ${e.value}").join(' ')} END) "
            '${_orderOperators[op]!} ${bind(_rank[operand]!)}::int',
    };
    return 'COALESCE(($comparison), FALSE)';
  }
}

const _orderOperators = {'lt': '<', 'lte': '<=', 'gt': '>', 'gte': '>='};
const _rank = {
  'info': 0,
  'unknown': 1,
  'warning': 2,
  'error': 3,
  'critical': 4,
};

enum _Type { text, severity, kind, status }

final class _Field {
  const _Field(this.path, this.type, this.fromEvent, [this.key]);
  final String path;
  final _Type type;
  final String? Function(CanonicalEvent, String?) fromEvent;
  final String? key;

  static _Field parse(String name) {
    final field = _fields[name];
    if (field != null) return field;
    final dot = name.indexOf('.');
    if (dot < 0) _invalid('condition_field');
    final map = name.substring(0, dot);
    final key = name.substring(dot + 1);
    if (key.length > 128 || !_keyPattern.hasMatch(key)) {
      _invalid('condition_field');
    }
    return switch (map) {
      'labels' => _Field(
        map,
        _Type.text,
        (event, key) => event.labels[key],
        key,
      ),
      'resource' => _Field(
        map,
        _Type.text,
        (event, key) => event.resource[key],
        key,
      ),
      'annotations' => _Field(
        map,
        _Type.text,
        (event, key) => event.annotations[key],
        key,
      ),
      _ => _invalid('condition_field'),
    };
  }

  String? read(CanonicalEvent event) => fromEvent(event, key);

  /// The dotted path an operator addressed, such as `labels.site`.
  String get fullPath => key == null ? path : '$path.$key';

  String sql(String Function(Object) bind) {
    final parts = path.split('.');
    final fixed = parts.map((part) => "'$part'").join(',');
    final part = key;
    final parameter = part == null
        ? ''
        : ', ${bind(encodeMatcherText(part))}::text';
    final value =
        '(event.data #>> ARRAY[$fixed$parameter]::text[] COLLATE "C")';
    final values = switch (type) {
      _Type.text => null,
      _Type.kind => EventKind.values,
      _Type.status => EventStatus.values,
      _Type.severity => EventSeverity.values,
    };
    if (values == null) return value;
    final prefix = 'EVENT_${path.toUpperCase()}_';
    final cases = values
        .map((entry) {
          final wire = '$prefix${entry.name.toUpperCase()}';
          return "WHEN '$wire' THEN '${entry.name}'";
        })
        .join(' ');
    return '(CASE $value $cases END COLLATE "C")';
  }
}

final _keyPattern = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_./:-]*$');
final _fields = <String, _Field>{
  for (final (path, type, read)
      in <(String, _Type, String? Function(CanonicalEvent))>[
        ('event_id', _Type.text, (e) => e.eventId),
        ('fingerprint', _Type.text, (e) => e.fingerprint),
        ('tenant', _Type.text, (e) => e.tenant),
        ('namespace', _Type.text, (e) => e.namespace),
        ('kind', _Type.kind, (e) => e.kind.name),
        ('status', _Type.status, (e) => e.status.name),
        ('severity', _Type.severity, (e) => e.severity.name),
        ('severity_original', _Type.text, (e) => e.severityOriginal),
        ('dedup_key', _Type.text, (e) => e.dedupKey),
        ('summary', _Type.text, (e) => e.summary),
        ('description', _Type.text, (e) => e.description),
        (
          'observer.source_instance',
          _Type.text,
          (e) => e.observer.sourceInstance,
        ),
        ('observer.source_kind', _Type.text, (e) => e.observer.sourceKind),
        ('observer.name', _Type.text, (e) => e.observer.name),
        ('observer.version', _Type.text, (e) => e.observer.version),
      ])
    path: _Field(path, type, (event, _) => read(event)),
};

final _v4 = RegExp(r'^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$');
final _v6 = RegExp(r'^[0-9A-Fa-f:.]+$');
InternetAddress? _address(String source) {
  if (!((source.contains(':') && _v6.hasMatch(source)) ||
      _v4.hasMatch(source))) {
    return null;
  }
  return InternetAddress.tryParse(source);
}

String _cidrSql(String value, String network) =>
    "CASE WHEN (($value ~ '^(0|[1-9][0-9]{0,2})([.](0|[1-9][0-9]{0,2})){3}\$') OR "
    "($value ~ '^[0-9A-Fa-f:.]+\$' AND position(':' in $value) > 0)) "
    "AND pg_input_is_valid($value, 'inet') THEN $value::inet <<= $network::cidr END";

final class _Network {
  const _Network(this.source, this.bytes, this.prefix);
  final String source;
  final List<int> bytes;
  final int prefix;

  static _Network parse(String source) {
    final parts = source.split('/');
    if (parts.length != 2) _invalid('condition_cidr');
    final address = _address(parts[0]);
    final prefix = int.tryParse(parts[1]);
    if (address == null || prefix == null || parts[1] != '$prefix') {
      _invalid('condition_cidr');
    }
    final bytes = address.rawAddress;
    if (prefix < 0 || prefix > bytes.length * 8) _invalid('condition_cidr');
    final network = _Network('${address.address}/$prefix', bytes, prefix);
    for (var bit = prefix; bit < bytes.length * 8; bit++) {
      if ((bytes[bit ~/ 8] & (128 >> (bit % 8))) != 0) {
        _invalid('condition_cidr');
      }
    }
    return network;
  }

  bool contains(String input) {
    final address = _address(input);
    if (address == null) return false;
    final other = address.rawAddress;
    if (other.length != bytes.length) return false;
    final whole = prefix ~/ 8;
    for (var i = 0; i < whole; i++) {
      if (other[i] != bytes[i]) return false;
    }
    final left = prefix % 8;
    return left == 0 || (other[whole] ^ bytes[whole]) >> (8 - left) == 0;
  }
}
