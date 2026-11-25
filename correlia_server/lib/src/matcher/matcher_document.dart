import '../event/canonical_event.dart';
import '../event/validation.dart';
import 'matcher_condition.dart';
import 'matcher_regex.dart';

/// One ordered, immutable matcher rule.
final class MatcherRule {
  const MatcherRule._(this.id, this.condition, this.actions);

  /// The unique opaque rule identifier used in failure records.
  final String id;

  /// The predicate evaluated on the original normalized event.
  final MatcherCondition condition;

  /// The validated ordered patch operations.
  final List<MatcherAction> actions;
}

/// The matcher part of an immutable ingest configuration.
final class MatcherDocument {
  const MatcherDocument._(this.rules, this.snapshotJson, this.outputIds);

  /// A configuration without matcher rules.
  static const empty = MatcherDocument._([], {}, {});

  /// Rules evaluated in publication order.
  final List<MatcherRule> rules;

  /// The canonical public representation, with free-form text encoded.
  final Map<String, Object?> snapshotJson;

  /// All routes that this matcher document can add.
  final Set<String> outputIds;

  /// Validates an operator document against [outputs].
  static MatcherDocument parse(Object? input, Set<String> outputs) =>
      _read(input, outputs, persisted: false);

  /// Reads an encoded document from a pinned public snapshot.
  static MatcherDocument fromSnapshot(Object? input, Set<String> outputs) =>
      _read(input, outputs, persisted: true);

  static MatcherDocument _read(
    Object? input,
    Set<String> outputs, {
    required bool persisted,
  }) {
    final root = _object(input, {'language', 'version', 'rules'}, 'matcher');
    if (root['language'] != 'matcher') _bad('matcher.language', 'language');
    if (root['version'] is! int || root['version'] != 1) {
      _bad('matcher.version', 'version');
    }
    var nodes = 0;
    void measure(Object? node, int depth) {
      if (++nodes > 1024 || depth > 16) _bad('matcher', 'shape_bound');
      if (node is Map<String, Object?>) {
        for (final value in node.values) {
          measure(value, depth + 1);
        }
      } else if (node is List<Object?>) {
        for (final value in node) {
          measure(value, depth + 1);
        }
      }
    }

    measure(root, 1);
    final rules = _list(root['rules'], 'matcher.rules');
    if (rules.isEmpty) return empty;
    final buffer = <MatcherRule>[];
    final public = <Map<String, Object?>>[];
    final ids = <String>{};
    final routes = <String>{};
    for (final (index, value) in rules.indexed) {
      final field = 'matcher.rules[$index]';
      final rule = _object(value, {'id', 'when', 'actions'}, field);
      final id = rule['id'];
      if (id is! String || !_identifier.hasMatch(id)) {
        _bad('$field.id', 'identifier');
      }
      if (!ids.add(id)) _bad('$field.id', 'duplicate');
      final conditionJson = _conditionText(
        rule['when'],
        persisted ? decodeMatcherText : (s) => s,
      );
      final condition = _checked(
        '$field.when',
        () => MatcherCondition.parse(conditionJson),
      );
      final actions = <MatcherAction>[];
      final encodedActions = <Map<String, Object?>>[];
      for (final (i, action) in _list(
        rule['actions'],
        '$field.actions',
      ).indexed) {
        final actionField = '$field.actions[$i]';
        final (decoded, encoded) = _parseAction(action, actionField, persisted);
        if (decoded case MatcherRoute(:final outputId)) {
          if (!outputs.contains(outputId)) {
            _bad('$actionField.output_id', 'unknown_output');
          }
          routes.add(outputId);
        }
        actions.add(decoded);
        encodedActions.add(encoded);
      }
      if (actions.isEmpty) _bad('$field.actions', 'empty');
      buffer.add(MatcherRule._(id, condition, List.unmodifiable(actions)));
      public.add(
        Map.unmodifiable({
          'id': id,
          'when': _conditionText(conditionJson, encodeMatcherText),
          'actions': List<Map<String, Object?>>.unmodifiable(encodedActions),
        }),
      );
    }
    return MatcherDocument._(
      List.unmodifiable(buffer),
      Map.unmodifiable({
        'language': 'matcher',
        'version': 1,
        'rules': List<Map<String, Object?>>.unmodifiable(public),
      }),
      Set.unmodifiable(routes),
    );
  }
}

/// A validation error safe to surface without echoing the rule's data.
final class MatcherDocumentError implements Exception {
  const MatcherDocumentError(this.field, this.code);

  /// The fixed field path or numeric rule/action position.
  final String field;

  /// The validation failure class.
  final String code;
}

final _identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$');
final _labelKey = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:/-]{0,127}$');

Never _bad(String field, String code) =>
    throw MatcherDocumentError(field, code);

T _checked<T>(String field, T Function() parse) {
  try {
    return parse();
  } on FormatException catch (error) {
    _bad(field, error.message);
  } on EventValidationError catch (error) {
    _bad(field, error.code);
  }
}

Map<String, Object?> _object(Object? input, Set<String> keys, String field) {
  if (input is! Map<String, Object?> ||
      input.length != keys.length ||
      !input.keys.every(keys.contains)) {
    _bad(field, 'shape');
  }
  return input;
}

List<Object?> _list(Object? input, String field) {
  if (input is! List<Object?>) _bad(field, 'list');
  return input;
}

Object? _conditionText(
  Object? value,
  String Function(String) transform,
) => switch (value) {
  <String, Object?>{'field': final field} => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key: switch ((entry.key, entry.value)) {
        ('value', final String text) => transform(text),
        ('value', final List<Object?> items) => List<Object?>.unmodifiable([
          for (final item in items) item is String ? transform(item) : item,
        ]),
        ('field', _) when field is String => transform(field),
        _ => entry.value,
      },
  }),
  final Map<String, Object?> map => Map<String, Object?>.unmodifiable({
    for (final entry in map.entries)
      entry.key: _conditionText(entry.value, transform),
  }),
  final List<Object?> list => List<Object?>.unmodifiable([
    for (final item in list) _conditionText(item, transform),
  ]),
  _ => value,
};

/// One staged mutation or route request in a matcher rule.
sealed class MatcherAction {
  const MatcherAction();
}

/// Writes an operator-defined label.
final class MatcherLabel extends MatcherAction {
  const MatcherLabel(this.key, this.value);
  final String key;
  final String value;
}

/// Adds one validated output UUID to the allowed source routes.
final class MatcherRoute extends MatcherAction {
  const MatcherRoute(this.outputId);
  final String outputId;
}

/// Maps original severity values to a replacement severity.
final class MatcherSeverity extends MatcherAction {
  const MatcherSeverity(this.values);
  final Map<EventSeverity, EventSeverity> values;
}

/// Adds a validated runbook or dashboard link.
final class MatcherLink extends MatcherAction {
  const MatcherLink(this.link);
  final EventLink link;
}

/// Extracts one capture from a validated text field into a label.
final class MatcherExtract extends MatcherAction {
  const MatcherExtract(this.field, this.pattern, this.group, this.key);
  final MatcherTextField field;
  final MatcherRegex pattern;
  final int group;
  final String key;
}

/// Writes site and environment labels for matching host names or addresses.
final class MatcherLocation extends MatcherAction {
  const MatcherLocation(this.field, this.entries);
  final MatcherTextField field;
  final List<MatcherLocationEntry> entries;
}

/// One ordered location mapping, using a host name or a CIDR.
final class MatcherLocationEntry {
  const MatcherLocationEntry(
    this.hostname,
    this.network,
    this.site,
    this.environment,
  );
  final String? hostname;
  final MatcherNetwork? network;
  final String? site;
  final String? environment;
}

(MatcherAction, Map<String, Object?>) _parseAction(
  Object? input,
  String field,
  bool persisted,
) {
  if (input is! Map<String, Object?> || input['type'] is! String) {
    _bad(field, 'shape');
  }
  final encoded = Map<String, Object?>.of(input);
  String text(String key, {int max = 1024}) {
    final raw = input[key];
    if (raw is! String) _bad('$field.$key', 'text');
    final decoded = _checked(
      '$field.$key',
      () => persisted ? decodeMatcherText(raw) : raw,
    );
    _checked(
      '$field.$key',
      () => validateText(decoded, '$field.$key', max: max),
    );
    encoded[key] = encodeMatcherText(decoded);
    return decoded;
  }

  String labelKey() {
    final key = text('key', max: 128);
    if (!_labelKey.hasMatch(key)) _bad('$field.key', 'label_key');
    return key;
  }

  EventSeverity severity(Object? raw) {
    for (final value in EventSeverity.values) {
      if (raw == value.name) return value;
    }
    return _bad('$field.values', 'severity');
  }

  MatcherAction result;
  switch (input['type']) {
    case 'set_label':
      _object(input, {'type', 'key', 'value'}, field);
      result = MatcherLabel(labelKey(), text('value', max: 1024));
    case 'tag':
      _object(input, {'type', 'key'}, field);
      final key = 'tags.${labelKey()}';
      if (key.length > 128) _bad('$field.key', 'label_key');
      result = MatcherLabel(key, 'true');
    case 'owner' || 'team':
      _object(input, {'type', 'value'}, field);
      result = MatcherLabel(input['type']! as String, text('value'));
    case 'route':
      _object(input, {'type', 'output_id'}, field);
      final id = input['output_id'];
      if (id is! String) _bad('$field.output_id', 'uuid');
      _checked('$field.output_id', () => validateUuid(id, '$field.output_id'));
      result = MatcherRoute(id);
    case 'map_severity':
      _object(input, {'type', 'values'}, field);
      final map = input['values'];
      if (map is! Map<String, Object?> || map.isEmpty) {
        _bad('$field.values', 'shape');
      }
      encoded['values'] = Map<String, Object?>.unmodifiable(map);
      result = MatcherSeverity(
        Map.unmodifiable({
          for (final entry in map.entries)
            severity(entry.key): severity(entry.value),
        }),
      );
    case 'link':
      final keys = {
        'type',
        'href',
        'relation',
        if (input.containsKey('text')) 'text',
      };
      _object(input, keys, field);
      final rel = input['relation'];
      if (rel != 'runbook' && rel != 'dashboard') {
        _bad('$field.relation', 'link_relation');
      }
      result = MatcherLink(
        _checked(
          field,
          () => EventLink(
            href: text('href', max: 2048),
            relation: rel! as String,
            text: input.containsKey('text') ? text('text') : null,
          ),
        ),
      );
    case 'extract':
      _object(input, {'type', 'field', 'pattern', 'group', 'key'}, field);
      final source = _checked(
        '$field.field',
        () => MatcherTextField.parse(text('field', max: 256)),
      );
      final pattern = _checked(
        '$field.pattern',
        () => MatcherRegex.parse(text('pattern', max: 256)),
      );
      final group = input['group'];
      if (group is! int || group < 0 || group > pattern.groupCount) {
        _bad('$field.group', 'group');
      }
      result = MatcherExtract(source, pattern, group, labelKey());
    case 'location':
      _object(input, {'type', 'field', 'entries'}, field);
      final source = _checked(
        '$field.field',
        () => MatcherTextField.parse(text('field', max: 256)),
      );
      final entries = <MatcherLocationEntry>[];
      final publicEntries = <Map<String, Object?>>[];
      for (final (index, raw) in _list(
        input['entries'],
        '$field.entries',
      ).indexed) {
        final path = '$field.entries[$index]';
        if (raw is! Map<String, Object?>) _bad(path, 'shape');
        final host = raw.containsKey('hostname');
        final cidr = raw.containsKey('cidr');
        final site = raw.containsKey('site');
        final environment = raw.containsKey('environment');
        if (host == cidr || (!site && !environment)) _bad(path, 'shape');
        _object(raw, {
          if (host) 'hostname' else 'cidr',
          if (site) 'site',
          if (environment) 'environment',
        }, path);
        final readable = <String, String>{};
        for (final entry in raw.entries) {
          final rawValue = entry.value;
          if (rawValue is! String) _bad(path, 'text');
          final value = _checked(
            path,
            () => persisted ? decodeMatcherText(rawValue) : rawValue,
          );
          _checked(path, () => validateText(value, path, min: 1, max: 1024));
          readable[entry.key] = value;
        }
        publicEntries.add(
          Map.unmodifiable(
            readable.map((k, v) => MapEntry(k, encodeMatcherText(v))),
          ),
        );
        entries.add(
          MatcherLocationEntry(
            readable['hostname'],
            ifNetwork(readable['cidr'], path),
            readable['site'],
            readable['environment'],
          ),
        );
      }
      if (entries.isEmpty) _bad('$field.entries', 'empty');
      encoded['entries'] = List<Map<String, Object?>>.unmodifiable(
        publicEntries,
      );
      result = MatcherLocation(source, List.unmodifiable(entries));
    default:
      _bad('$field.type', 'action_type');
  }
  return (result, Map.unmodifiable(encoded));
}

MatcherNetwork? ifNetwork(String? value, String path) =>
    value == null ? null : _checked(path, () => MatcherNetwork.parse(value));
