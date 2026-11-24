part of 'bootstrap.dart';

/// An RFC 6901 pointer validated at activation, relative to the body or alert.
final class GenericPointer {
  GenericPointer._(Iterable<String> segments)
    : segments = List.unmodifiable(segments);

  /// Unescaped path tokens. An empty list selects the root.
  final List<String> segments;

  static final _badEscape = RegExp(r'~(?:[^01]|$)');

  static GenericPointer _parse(Object? value, String field) {
    if (value is! String ||
        value.length > 512 ||
        utf8.encode(value).length > 512 ||
        (value.isNotEmpty && !value.startsWith('/')) ||
        _badEscape.hasMatch(value)) {
      _bad('config', field, 'invalid_pointer');
    }
    _validateMappingText(value, field, (min: 0, max: 512));
    return GenericPointer._(
      value.isEmpty
          ? const []
          : value
                .substring(1)
                .split('/')
                .map(
                  (token) => token.replaceAll('~1', '/').replaceAll('~0', '~'),
                ),
    );
  }
}

/// The exact timestamp representation expected at a time pointer.
enum GenericTimeFormat { rfc3339, epochSeconds, epochMillis }

/// The action taken when leaves are not read by the mapping.
enum GenericUnmappedFields { reject, count }

/// A validated canonical state mapping.
sealed class GenericStateValue<T extends Enum> {
  const GenericStateValue._();
}

/// A sender value table with an optional default for unlisted values.
final class GenericValueTable<T extends Enum> extends GenericStateValue<T> {
  GenericValueTable._(this.pointer, Map<String, T> values, this.defaultValue)
    : values = Map.unmodifiable(values),
      super._();

  /// The required value's location in the alert.
  final GenericPointer pointer;

  /// Sender strings or decimal integer text, mapped to canonical states.
  final Map<String, T> values;

  /// The state for unlisted inputs, not for absent or wrong-typed fields.
  final T? defaultValue;
}

/// A fixed canonical state that does not read a sender field.
final class GenericStateConstant<T extends Enum> extends GenericStateValue<T> {
  const GenericStateConstant._(this.value) : super._();

  /// The state assigned to every alert.
  final T value;
}

/// A validated assignment to one display field.
sealed class GenericDisplayValue {
  const GenericDisplayValue._();
}

/// An assignment copied from the selected sender field.
final class GenericDisplayCopy extends GenericDisplayValue {
  const GenericDisplayCopy._(this.pointer) : super._();

  /// The location to read inside the alert.
  final GenericPointer pointer;
}

/// An assignment independent of the sender body.
final class GenericDisplayConstant extends GenericDisplayValue {
  const GenericDisplayConstant._(this.value) : super._();

  /// The canonical text value.
  final String value;
}

/// An immutable, fully validated format-1 generic webhook mapping.
final class GenericMapping {
  GenericMapping._({
    required this.name,
    required this.items,
    required this.unmappedFields,
    required this.identity,
    required this.observationId,
    required this.sourceTime,
    required this.status,
    required this.severity,
    required this.summary,
    required this.description,
    required this.labels,
    required this.links,
    required Map<String, Object?> json,
    required int jsonBytes,
  }) : _json = json,
       _jsonBytes = jsonBytes;

  /// The format-1 document's entire top-level key set.
  static const keys = {
    'name',
    'mapping_format',
    'items',
    'unmapped_fields',
    'identity',
    'observation_id',
    'source_time',
    'status',
    'severity',
    'summary',
    'description',
    'labels',
    'links',
  };

  /// The maximum canonical JSON size of one mapping document, in bytes.
  static const maxBytes = 32 * 1024;

  /// The bootstrap-local name this source references.
  final String name;

  /// The body's alert-array pointer, absent for a single alert.
  final GenericPointer? items;

  /// How delivery decoding treats leaves no pointer selects.
  final GenericUnmappedFields unmappedFields;

  /// Canonical identity names and their required sender pointers.
  final Map<String, GenericPointer> identity;

  /// The optional native observation ID pointer.
  final GenericPointer? observationId;

  /// The required source time pointer and format.
  final ({GenericPointer pointer, GenericTimeFormat format}) sourceTime;

  /// The required status translation.
  final GenericValueTable<EventStatus> status;

  /// The required severity translation or constant.
  final GenericStateValue<EventSeverity> severity;

  /// The required summary assignment.
  final GenericDisplayValue summary;

  /// The optional description assignment.
  final GenericDisplayValue? description;

  /// Optional display labels, keyed by their canonical names.
  final Map<String, GenericDisplayValue> labels;

  /// Optional link targets, keyed by their canonical relationships.
  final Map<String, GenericDisplayValue> links;

  final Map<String, Object?> _json;
  final int _jsonBytes;

  /// The canonical form persisted with the snapshot, without runtime state.
  Map<String, Object?> toJson() => _json;

  /// Validates [document] without reflecting operator-supplied field values.
  static GenericMapping parse(
    Object? document, {
    String field = 'mappings[0]',
  }) {
    final row = _map(document, 'config', field);
    _sourceFields(row, keys, field);
    final name = _mappingName(row['name'], '$field.name');
    final format = row['mapping_format'];
    if (format is! int || format != 1) {
      _bad('config', '$field.mapping_format', 'mapping_format');
    }
    final items = row.containsKey('items')
        ? GenericPointer._parse(row['items'], '$field.items')
        : null;
    final unmapped = switch (row['unmapped_fields']) {
      'reject' => GenericUnmappedFields.reject,
      'count' => GenericUnmappedFields.count,
      null when !row.containsKey('unmapped_fields') =>
        GenericUnmappedFields.reject,
      _ => _bad('config', '$field.unmapped_fields', 'unmapped_fields'),
    };
    final identity = _mappingFields(
      row['identity'],
      '$field.identity',
      CanonicalEventBounds.CanonicalEventIdentityFieldsLength,
      CanonicalEventBounds.CanonicalEventIdentityFieldsKeyLength,
      (value, _, path) => GenericPointer._parse(value, path),
    );
    final observationId = row.containsKey('observation_id')
        ? GenericPointer._parse(row['observation_id'], '$field.observation_id')
        : null;
    final time = _map(row['source_time'], 'config', '$field.source_time');
    _sourceFields(time, const {'pointer', 'format'}, '$field.source_time');
    final sourceTime = (
      pointer: GenericPointer._parse(
        time['pointer'],
        '$field.source_time.pointer',
      ),
      format: switch (time['format']) {
        'rfc3339' => GenericTimeFormat.rfc3339,
        'epoch_seconds' => GenericTimeFormat.epochSeconds,
        'epoch_millis' => GenericTimeFormat.epochMillis,
        _ => _bad('config', '$field.source_time.format', 'time_format'),
      },
    );
    final status = _valueTable(
      row['status'],
      '$field.status',
      EventStatus.values,
    );
    final severityPath = '$field.severity';
    final severityRow = _map(row['severity'], 'config', severityPath);
    final GenericStateValue<EventSeverity> severity;
    if (severityRow.containsKey('constant')) {
      _sourceFields(severityRow, const {'constant'}, severityPath);
      severity = GenericStateConstant._(
        _mappingEnum(
          severityRow['constant'],
          '$severityPath.constant',
          EventSeverity.values,
        ),
      );
    } else {
      severity = _valueTable(severityRow, severityPath, EventSeverity.values);
    }
    final summary = _displayValue(
      row['summary'],
      '$field.summary',
      CanonicalEventBounds.CanonicalEventSummaryLength,
    );
    final description = row.containsKey('description')
        ? _displayValue(
            row['description'],
            '$field.description',
            CanonicalEventBounds.CanonicalEventDescriptionLength,
          )
        : null;
    final labels = row.containsKey('labels')
        ? _mappingFields(
            row['labels'],
            '$field.labels',
            CanonicalEventBounds.CanonicalEventLabelsLength,
            CanonicalEventBounds.CanonicalEventLabelsKeyLength,
            (value, _, path) => _displayValue(
              value,
              path,
              CanonicalEventBounds.CanonicalEventLabelsValueLength,
            ),
          )
        : const <String, GenericDisplayValue>{};
    final links = row.containsKey('links')
        ? _mappingFields(
            row['links'],
            '$field.links',
            CanonicalEventBounds.CanonicalEventLinksLength,
            CanonicalEventBounds.LinkRelationLength,
            (value, name, path) => _displayValue(
              value,
              path,
              CanonicalEventBounds.LinkHrefLength,
              linkRelation: name,
            ),
          )
        : const <String, GenericDisplayValue>{};
    final json = _canonical(row) as Map<String, Object?>;
    final jsonBytes = utf8.encode(jsonEncode(json)).length;
    if (jsonBytes > maxBytes) _bad('config', field, 'mapping_bound');
    return GenericMapping._(
      name: name,
      items: items,
      unmappedFields: unmapped,
      identity: identity,
      observationId: observationId,
      sourceTime: sourceTime,
      status: status,
      severity: severity,
      summary: summary,
      description: description,
      labels: labels,
      links: links,
      json: json,
      jsonBytes: jsonBytes,
    );
  }
}

String _mappingName(Object? value, String field) {
  final name = _string(value, GenericMapping.maxBytes, field);
  _validateMappingText(name, field, (min: 1, max: GenericMapping.maxBytes));
  return name;
}

void _validateMappingText(
  String text,
  String field,
  ({int? min, int? max}) bound,
) {
  try {
    validateText(text, field, min: bound.min ?? 0, max: bound.max!);
  } on EventValidationError catch (error) {
    _bad('config', field, error.code);
  }
}

Map<String, T> _mappingFields<T>(
  Object? value,
  String field,
  ({int? min, int? max}) count,
  ({int? min, int? max}) keyBound,
  T Function(Object? value, String name, String field) parse,
) {
  final row = _map(value, 'config', field);
  if (row.length < (count.min ?? 0) || row.length > count.max!) {
    _bad('config', field, 'bound');
  }
  final fields = <String, T>{};
  for (final (index, MapEntry(:key, :value)) in row.entries.indexed) {
    _validateMappingText(key, field, keyBound);
    final path = _fieldName.hasMatch(key) ? '$field.$key' : '$field[$index]';
    fields[key] = parse(value, key, path);
  }
  return Map.unmodifiable(fields);
}

T _mappingEnum<T extends Enum>(Object? value, String field, List<T> options) {
  for (final option in options) {
    if (value == option.name) return option;
  }
  _bad('config', field, 'enum');
}

GenericValueTable<T> _valueTable<T extends Enum>(
  Object? value,
  String field,
  List<T> options,
) {
  final row = _map(value, 'config', field);
  _sourceFields(row, const {'pointer', 'values', 'default'}, field);
  final pointer = GenericPointer._parse(row['pointer'], '$field.pointer');
  final valuesPath = '$field.values';
  final table = _map(row['values'], 'config', valuesPath);
  if (table.length > 256) _bad('config', valuesPath, 'bound');
  final values = <String, T>{};
  for (final MapEntry(:key, :value) in table.entries) {
    _validateMappingText(key, valuesPath, (min: 0, max: 256));
    if (utf8.encode(key).length > 256) _bad('config', valuesPath, 'bound');
    values[key] = _mappingEnum(value, valuesPath, options);
  }
  final fallback = row.containsKey('default')
      ? _mappingEnum(row['default'], '$field.default', options)
      : null;
  return GenericValueTable._(pointer, values, fallback);
}

GenericDisplayValue _displayValue(
  Object? value,
  String field,
  ({int? min, int? max}) bound, {
  String? linkRelation,
}) {
  final row = _map(value, 'config', field);
  _sourceFields(row, const {'copy', 'constant'}, field);
  if (row.length == 1) {
    if (row.containsKey('copy')) {
      return GenericDisplayCopy._(
        GenericPointer._parse(row['copy'], '$field.copy'),
      );
    }
    if (row['constant'] case final String text) {
      _validateMappingText(text, field, bound);
      if (linkRelation != null) {
        try {
          EventLink(href: text, relation: linkRelation);
        } on EventValidationError catch (error) {
          _bad('config', field, error.code);
        }
      }
      return GenericDisplayConstant._(text);
    }
  }
  _bad('config', field, 'display_assignment');
}

Map<String, GenericMapping> _parseMappings(Object? value) {
  final result = <String, GenericMapping>{};
  var bytes = 2; // The enclosing square brackets.
  for (final (i, document) in _list(value, 64, 'mappings').indexed) {
    final field = 'mappings[$i]';
    final mapping = GenericMapping.parse(document, field: field);
    if (result.containsKey(mapping.name))
      _bad('config', '$field.name', 'duplicate');
    bytes += mapping._jsonBytes + (i == 0 ? 0 : 1);
    if (bytes > 64 * 1024) _bad('config', 'mappings', 'mappings_bound');
    result[mapping.name] = mapping;
  }
  if (result.isEmpty) return const {};
  final ordered = result.keys.toList()..sort();
  return Map.unmodifiable({for (final name in ordered) name: result[name]!});
}
