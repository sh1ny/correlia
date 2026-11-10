import 'dart:convert';

/// A bounded JSON object used while patching the generated schema.
typedef JsonObject = Map<String, Object?>;

/// Adds standard `buf.validate` map entry bounds to a generated schema.
///
/// The upstream draft-2020-12 generator emits map key and value rules but
/// omits the map entry count. This narrow patch copies only `min_pairs` and
/// `max_pairs` from the descriptor into `minProperties` and `maxProperties`.
/// Other schema and validation rules remain owned by the pinned generator.
///
/// Throws [FormatException] when [schema] is not a JSON object or when
/// [descriptor] does not contain a usable map rule for [fieldPath].
JsonObject patchMapEntryBounds({
  required JsonObject schema,
  required JsonObject descriptor,
  required String fieldPath,
}) {
  final rule = _fieldRule(descriptor);
  final mapRule = rule?['map'];
  if (mapRule is! JsonObject) {
    throw FormatException('No buf.validate map rule for $fieldPath');
  }

  final properties = _objectProperty(schema, 'properties');
  final fieldSchema = properties[fieldPath];
  if (fieldSchema is! JsonObject) {
    throw FormatException('No generated schema property for $fieldPath');
  }

  final minPairs = _unsigned(mapRule['minPairs']);
  final maxPairs = _unsigned(mapRule['maxPairs']);
  if (minPairs == null && maxPairs == null) {
    throw FormatException('No map entry bound for $fieldPath');
  }
  if (minPairs != null) {
    if (fieldSchema.containsKey('minProperties')) {
      throw FormatException('Generated schema already has minProperties');
    }
    fieldSchema['minProperties'] = minPairs;
  }
  if (maxPairs != null) {
    if (fieldSchema.containsKey('maxProperties')) {
      throw FormatException('Generated schema already has maxProperties');
    }
    fieldSchema['maxProperties'] = maxPairs;
  }
  return schema;
}

/// Reads the standard field rule object from a Buf descriptor field.
JsonObject? _fieldRule(JsonObject descriptor) {
  final options = descriptor['options'];
  if (options is! JsonObject) return null;
  final rule = options['[buf.validate.field]'];
  return rule is JsonObject ? rule : null;
}

/// Reads a map field schema from a strict bundled schema.
JsonObject _objectProperty(JsonObject schema, String name) {
  final value = schema[name];
  if (value is! JsonObject) {
    throw FormatException('Generated schema has no $name object');
  }
  return value;
}

/// Parses an unsigned decimal descriptor value.
int? _unsigned(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  throw FormatException('Unexpected unsigned descriptor value: $value');
}

/// Encodes a JSON object as stable, human-readable UTF-8 JSON.
String encodeJson(JsonObject value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';
