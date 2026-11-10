import 'dart:convert';

/// A typed Dart constant extracted from a standard validation rule.
sealed class BoundConstant {
  const BoundConstant(this.fieldPath, this.symbolName);

  /// The dotted field path that owns the rule.
  final String fieldPath;

  /// The stable Dart symbol name for this bound.
  final String symbolName;

  /// The Dart declaration for this constant.
  String get declaration;
}

/// A Unicode-scalar or collection-count length bound.
final class LengthBound extends BoundConstant {
  const LengthBound(
    super.fieldPath,
    super.symbolName,
    this.minimum,
    this.maximum,
  );

  /// The inclusive minimum length, when specified.
  final int? minimum;

  /// The inclusive maximum length, when specified.
  final int? maximum;

  @override
  String get declaration {
    return 'static const ({int? min, int? max}) $symbolName = '
        '(min: $minimum, max: $maximum);';
  }
}

/// A UTF-8 byte length bound.
final class ByteLengthBound extends BoundConstant {
  const ByteLengthBound(
    super.fieldPath,
    super.symbolName,
    this.minimum,
    this.maximum,
  );

  /// The inclusive minimum byte count, when specified.
  final int? minimum;

  /// The inclusive maximum byte count, when specified.
  final int? maximum;

  @override
  String get declaration {
    return 'static const ({int? min, int? max}) $symbolName = '
        '(min: $minimum, max: $maximum);';
  }
}

/// A required-presence rule.
final class RequiredBound extends BoundConstant {
  const RequiredBound(super.fieldPath, super.symbolName);

  @override
  String get declaration => 'static const bool $symbolName = true;';
}

/// A whole-value regular-expression pattern.
final class PatternBound extends BoundConstant {
  const PatternBound(super.fieldPath, super.symbolName, this.pattern);

  /// The RE2-compatible pattern.
  final String pattern;

  @override
  String get declaration => "static const String $symbolName = r'$pattern';";
}

/// A literal string value.
final class StringConstantBound extends BoundConstant {
  const StringConstantBound(super.fieldPath, super.symbolName, this.value);

  /// The required literal value.
  final String value;

  @override
  String get declaration {
    final escaped = value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    return "static const String $symbolName = '$escaped';";
  }
}

/// The exact numeric domain of an enum.
final class EnumDomainBound extends BoundConstant {
  const EnumDomainBound(super.fieldPath, super.symbolName, this.values);

  /// The enum's numeric values in ascending order.
  final List<int> values;

  @override
  String get declaration {
    return 'static const List<int> $symbolName = <int>[${values.join(', ')}];';
  }
}

/// Extracts the supported standard rules used by the canonical event.
///
/// The extractor is intentionally narrow. Any newly used standard rule that
/// is not listed here fails with its owning field path instead of being
/// silently dropped.
List<BoundConstant> extractBounds(String descriptorJson) {
  final decoded = jsonDecode(descriptorJson);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Buf descriptor image is not an object');
  }
  final files = decoded['file'];
  if (files is! List<Object?>) {
    throw const FormatException('Buf descriptor image has no files');
  }

  final constants = <BoundConstant>[];
  for (final file in files.whereType<Map<String, Object?>>()) {
    final package = file['package'];
    if (package is! String || package != 'correlia.event.v1') continue;
    _extractMessage(constants, file, package);
    _extractEnums(constants, file, package);
  }
  constants.sort((a, b) => a.symbolName.compareTo(b.symbolName));
  return constants;
}

void _extractMessage(
  List<BoundConstant> output,
  Map<String, Object?> file,
  String package,
) {
  final messages = file['messageType'];
  if (messages is! List<Object?>) return;
  for (final message in messages.whereType<Map<String, Object?>>()) {
    final name = message['name'];
    if (name is! String) continue;
    final path = '$package.$name';
    final fields = message['field'];
    if (fields is List<Object?>) {
      for (final field in fields.whereType<Map<String, Object?>>()) {
        _extractField(output, path, field);
      }
    }
    final nested = message['nestedType'];
    if (nested is List<Object?>) {
      for (final child in nested.whereType<Map<String, Object?>>()) {
        final childName = child['name'];
        if (childName is! String) continue;
        final childPath = '$path.$childName';
        final childFields = child['field'];
        if (childFields is List<Object?>) {
          for (final field in childFields.whereType<Map<String, Object?>>()) {
            _extractField(output, childPath, field);
          }
        }
      }
    }
  }
}

void _extractField(
  List<BoundConstant> output,
  String messagePath,
  Map<String, Object?> field,
) {
  final name = field['name'];
  if (name is! String) return;
  final fieldPath = '$messagePath.$name';
  final options = field['options'];
  if (options is! Map<String, Object?>) return;
  final rule = options['[buf.validate.field]'];
  if (rule is! Map<String, Object?>) return;

  _rejectUnsupportedFieldRules(fieldPath, rule);
  final base = _symbol(fieldPath, '');
  if (rule['required'] == true) {
    output.add(RequiredBound(fieldPath, '${base}Required'));
  }

  final stringRule = rule['string'];
  if (stringRule is Map<String, Object?>) {
    _extractStringRule(output, fieldPath, base, stringRule);
  }

  final bytesRule = rule['bytes'];
  if (bytesRule is Map<String, Object?>) {
    _extractBytesRule(output, fieldPath, base, bytesRule);
  }

  final uint32Rule = rule['uint32'];
  if (uint32Rule is Map<String, Object?>) {
    _extractUint32Rule(output, fieldPath, base, uint32Rule);
  }

  final repeatedRule = rule['repeated'];
  if (repeatedRule is Map<String, Object?>) {
    final minimum = _unsigned(repeatedRule['minItems']) ?? 0;
    final maximum = _unsigned(repeatedRule['maxItems']);
    if (maximum != null) {
      output.add(LengthBound(fieldPath, '${base}Length', minimum, maximum));
    }
    final items = repeatedRule['items'];
    if (items is Map<String, Object?>) {
      _extractNestedFieldRules(output, fieldPath, '${base}Item', items);
    }
  }

  final mapRule = rule['map'];
  if (mapRule is Map<String, Object?>) {
    final minimum = _unsigned(mapRule['minPairs']) ?? 0;
    final maximum = _unsigned(mapRule['maxPairs']);
    if (maximum != null) {
      output.add(LengthBound(fieldPath, '${base}Length', minimum, maximum));
    }
    final keys = mapRule['keys'];
    if (keys is Map<String, Object?>) {
      _extractNestedFieldRules(output, fieldPath, '${base}Key', keys);
    }
    final values = mapRule['values'];
    if (values is Map<String, Object?>) {
      _extractNestedFieldRules(output, fieldPath, '${base}Value', values);
    }
  }

  final enumRule = rule['enum'];
  if (enumRule is Map<String, Object?>) {
    _rejectUnsupportedKeys(fieldPath, 'enum', enumRule, {'definedOnly'});
  }
}

void _extractNestedFieldRules(
  List<BoundConstant> output,
  String fieldPath,
  String base,
  Map<String, Object?> rules,
) {
  _rejectUnsupportedFieldRules(fieldPath, rules);
  final stringRule = rules['string'];
  if (stringRule is Map<String, Object?>) {
    _extractStringRule(output, fieldPath, base, stringRule);
  }
  final bytesRule = rules['bytes'];
  if (bytesRule is Map<String, Object?>) {
    _extractBytesRule(output, fieldPath, base, bytesRule);
  }
}

void _extractStringRule(
  List<BoundConstant> output,
  String fieldPath,
  String base,
  Map<String, Object?> rule,
) {
  _rejectUnsupportedKeys(fieldPath, 'string', rule, {
    'minLen',
    'maxLen',
    'len',
    'minBytes',
    'maxBytes',
    'lenBytes',
    'pattern',
    'const',
  });
  final exact = _unsigned(rule['len']);
  final minimum = exact ?? _unsigned(rule['minLen']);
  final maximum = exact ?? _unsigned(rule['maxLen']);
  if (minimum != null || maximum != null) {
    output.add(LengthBound(fieldPath, '${base}Length', minimum, maximum));
  }
  final minimumBytes = exact ?? _unsigned(rule['minBytes']);
  final maximumBytes = exact ?? _unsigned(rule['maxBytes']);
  if (minimumBytes != null || maximumBytes != null) {
    output.add(
      ByteLengthBound(
        fieldPath,
        '${base}ByteLength',
        minimumBytes,
        maximumBytes,
      ),
    );
  }
  final pattern = rule['pattern'];
  if (pattern is String) {
    output.add(PatternBound(fieldPath, '${base}Pattern', pattern));
  }
  final constant = rule['const'];
  if (constant is String) {
    output.add(StringConstantBound(fieldPath, '${base}Const', constant));
  }
}

void _extractBytesRule(
  List<BoundConstant> output,
  String fieldPath,
  String base,
  Map<String, Object?> rule,
) {
  _rejectUnsupportedKeys(fieldPath, 'bytes', rule, {'minLen', 'maxLen', 'len'});
  final exact = _unsigned(rule['len']);
  final minimum = exact ?? _unsigned(rule['minLen']);
  final maximum = exact ?? _unsigned(rule['maxLen']);
  if (minimum == null && maximum == null) {
    throw FormatException('$fieldPath has no bytes length bound');
  }
  output.add(ByteLengthBound(fieldPath, '${base}Length', minimum, maximum));
}

void _extractUint32Rule(
  List<BoundConstant> output,
  String fieldPath,
  String base,
  Map<String, Object?> rule,
) {
  _rejectUnsupportedKeys(fieldPath, 'uint32', rule, {'gte', 'lte'});
  final minimum = _unsigned(rule['gte']) ?? 0;
  final maximum = _unsigned(rule['lte']);
  if (maximum == null) {
    throw FormatException('$fieldPath has no uint32 upper bound');
  }
  output.add(LengthBound(fieldPath, '${base}Uint32', minimum, maximum));
}

void _rejectUnsupportedFieldRules(
  String fieldPath,
  Map<String, Object?> rules,
) {
  _rejectUnsupportedKeys(fieldPath, 'field', rules, {
    'required',
    'string',
    'bytes',
    'uint32',
    'repeated',
    'map',
    'enum',
  });
}

void _rejectUnsupportedKeys(
  String fieldPath,
  String kind,
  Map<String, Object?> rule,
  Set<String> supported,
) {
  for (final key in rule.keys) {
    if (!supported.contains(key)) {
      throw FormatException('$fieldPath uses unsupported $kind rule `$key`');
    }
  }
}

void _extractEnums(
  List<BoundConstant> output,
  Map<String, Object?> file,
  String package,
) {
  final enums = file['enumType'];
  if (enums is! List<Object?>) return;
  for (final enumeration in enums.whereType<Map<String, Object?>>()) {
    final name = enumeration['name'];
    if (name is! String) continue;
    final values = enumeration['value'];
    if (values is! List<Object?>) continue;
    final domain = <int>[];
    for (final value in values.whereType<Map<String, Object?>>()) {
      final number = value['number'];
      if (number is int) domain.add(number);
    }
    domain.sort();
    output.add(
      EnumDomainBound(
        '$package.$name',
        _symbol('$package.$name', 'Values'),
        domain,
      ),
    );
  }
}

int? _unsigned(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  throw FormatException('Unexpected unsigned descriptor value: $value');
}

String _symbol(String path, String suffix) {
  const prefix = 'correlia.event.v1.';
  final relative = path.startsWith(prefix)
      ? path.substring(prefix.length)
      : path;
  final buffer = StringBuffer();
  for (final part in relative.split('.')) {
    buffer.write(_pascalCase(part));
  }
  buffer.write(suffix);
  return buffer.toString();
}

String _pascalCase(String value) {
  final buffer = StringBuffer();
  for (final part in value.split('_')) {
    if (part.isEmpty) continue;
    buffer
      ..write(part[0].toUpperCase())
      ..write(part.substring(1));
  }
  return buffer.toString();
}
