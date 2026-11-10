import 'dart:convert';

/// A contract compatibility difference between a baseline and a candidate.
sealed class ContractDifference {
  const ContractDifference(this.path, this.message);

  /// The contract path that differs.
  final String path;

  /// A human-readable description of the difference.
  final String message;

  @override
  String toString() => '$path: $message';
}

/// A baseline contract element is missing from the candidate.
final class MissingContractElement extends ContractDifference {
  const MissingContractElement(super.path, super.message);
}

/// A candidate contract element was added.
final class AddedContractElement extends ContractDifference {
  const AddedContractElement(super.path, super.message);
}

/// An existing contract element changed.
final class ChangedContractElement extends ContractDifference {
  const ChangedContractElement(super.path, super.message);
}

/// Compares the standard validation rules and enum domains of two Buf
/// descriptor JSON images.
///
/// Existing fields must keep their exact standard rule object, JSON name and
/// presence. Existing enums and oneofs keep their exact domains and required
/// rules. Optional additions pass; newly required fields and oneofs fail.
List<ContractDifference> compareContractDescriptors({
  required String baselineJson,
  required String candidateJson,
}) {
  final baseline = _ContractDescriptor.parse(baselineJson);
  final candidate = _ContractDescriptor.parse(candidateJson);
  final differences = <ContractDifference>[];

  for (final message in baseline.messages.values) {
    final candidateMessage = candidate.messages[message.name];
    if (candidateMessage == null) {
      differences.add(
        MissingContractElement(message.name, 'message is missing'),
      );
      continue;
    }
    differences.addAll(_compareMessage(message, candidateMessage));
  }

  for (final enumeration in baseline.enums.values) {
    final candidateEnum = candidate.enums[enumeration.name];
    if (candidateEnum == null) {
      differences.add(
        MissingContractElement(enumeration.name, 'enum is missing'),
      );
      continue;
    }
    if (!_sameJson(enumeration.values, candidateEnum.values)) {
      differences.add(
        ChangedContractElement(
          enumeration.name,
          'enum domain changed from ${enumeration.values} to '
          '${candidateEnum.values}',
        ),
      );
    }
  }

  differences.sort((a, b) => a.path.compareTo(b.path));
  return differences;
}

List<ContractDifference> _compareMessage(
  _Message baseline,
  _Message candidate,
) {
  final differences = <ContractDifference>[];

  for (final field in baseline.fields.values) {
    final candidateField = candidate.fields[field.number];
    final path = '${baseline.name}.${field.name}';
    if (candidateField == null) {
      differences.add(MissingContractElement(path, 'field is missing'));
      continue;
    }
    if (candidateField.name != field.name) {
      differences.add(
        ChangedContractElement(
          path,
          'field name changed from ${field.name} to ${candidateField.name}',
        ),
      );
    }
    if (candidateField.jsonName != field.jsonName) {
      differences.add(
        ChangedContractElement(
          path,
          'JSON name changed from ${field.jsonName} to '
          '${candidateField.jsonName}',
        ),
      );
    }
    if (candidateField.presence != field.presence) {
      differences.add(
        ChangedContractElement(
          path,
          'presence changed from ${field.presence} to '
          '${candidateField.presence}',
        ),
      );
    }
    if (!_sameJson(candidateField.rule, field.rule)) {
      differences.add(
        ChangedContractElement(
          path,
          'validation rule changed from ${jsonEncode(field.rule)} to '
          '${jsonEncode(candidateField.rule)}',
        ),
      );
    }
  }

  for (final field in candidate.fields.values) {
    if (baseline.fields.containsKey(field.number)) continue;
    if (field.required) {
      differences.add(
        AddedContractElement(
          '${baseline.name}.${field.name}',
          'new field is required',
        ),
      );
    }
  }

  for (final oneof in baseline.oneofs.values) {
    final candidateOneof = candidate.oneofs[oneof.name];
    if (candidateOneof == null) {
      differences.add(
        MissingContractElement(
          '${baseline.name}.${oneof.name}',
          'oneof is missing',
        ),
      );
      continue;
    }
    if (!_sameJson(candidateOneof.rule, oneof.rule)) {
      differences.add(
        ChangedContractElement(
          '${baseline.name}.${oneof.name}',
          'validation rule changed from ${jsonEncode(oneof.rule)} to '
              '${jsonEncode(candidateOneof.rule)}',
        ),
      );
    }
  }

  for (final oneof in candidate.oneofs.values) {
    if (baseline.oneofs.containsKey(oneof.name)) continue;
    if (oneof.required) {
      differences.add(
        AddedContractElement(
          '${baseline.name}.${oneof.name}',
          'new oneof is required',
        ),
      );
    }
  }

  return differences;
}

/// A parsed contract descriptor with only the compared standard metadata.
final class _ContractDescriptor {
  const _ContractDescriptor({required this.messages, required this.enums});

  /// Messages by fully-qualified name.
  final Map<String, _Message> messages;

  /// Enums by fully-qualified name.
  final Map<String, _Enum> enums;

  /// Parses a Buf JSON descriptor image.
  factory _ContractDescriptor.parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Descriptor image is not an object');
    }
    final files = decoded['file'];
    if (files is! List<Object?>) {
      throw const FormatException('Descriptor image has no files');
    }
    final messages = <String, _Message>{};
    final enums = <String, _Enum>{};
    for (final file in files.whereType<Map<String, Object?>>()) {
      final package = file['package'];
      if (package is! String || !package.startsWith('correlia.event.v1')) {
        continue;
      }
      final messageTypes = file['messageType'];
      if (messageTypes is List<Object?>) {
        for (final message in messageTypes.whereType<Map<String, Object?>>()) {
          final parsed = _Message.parse(package, message);
          messages[parsed.name] = parsed;
        }
      }
      final enumTypes = file['enumType'];
      if (enumTypes is List<Object?>) {
        for (final enumeration in enumTypes.whereType<Map<String, Object?>>()) {
          final parsed = _Enum.parse(package, enumeration);
          enums[parsed.name] = parsed;
        }
      }
    }
    return _ContractDescriptor(messages: messages, enums: enums);
  }
}

/// A parsed message's compared metadata.
final class _Message {
  const _Message({
    required this.name,
    required this.fields,
    required this.oneofs,
  });

  /// Fully-qualified message name.
  final String name;

  /// Fields by protobuf number.
  final Map<int, _Field> fields;

  /// Oneofs by name.
  final Map<String, _Oneof> oneofs;

  /// Parses one message descriptor.
  factory _Message.parse(String package, Map<String, Object?> source) {
    final name = source['name'];
    if (name is! String) {
      throw const FormatException('Descriptor message has no name');
    }
    final oneofs = <String, _Oneof>{};
    final oneofSource = source['oneofDecl'];
    final oneofList = oneofSource is List<Object?> ? oneofSource : <Object?>[];
    for (final oneof in oneofList.whereType<Map<String, Object?>>()) {
      final parsed = _Oneof.parse('$package.$name', oneof);
      oneofs[parsed.name] = parsed;
    }
    final oneofNames = <int, String>{};
    for (var index = 0; index < oneofList.length; index++) {
      final oneof = oneofList[index];
      if (oneof is Map<String, Object?>) {
        final oneofName = oneof['name'];
        if (oneofName is String) oneofNames[index] = oneofName;
      }
    }
    final fields = <int, _Field>{};
    final fieldList = source['field'];
    if (fieldList is List<Object?>) {
      for (final field in fieldList.whereType<Map<String, Object?>>()) {
        final parsed = _Field.parse('$package.$name', field, oneofNames);
        fields[parsed.number] = parsed;
      }
    }
    return _Message(
      name: '$package.$name',
      fields: fields,
      oneofs: oneofs,
    );
  }
}

/// A parsed field's compared metadata.
final class _Field {
  const _Field({
    required this.name,
    required this.number,
    required this.jsonName,
    required this.presence,
    required this.rule,
    required this.required,
  });

  /// Field name.
  final String name;

  /// Protobuf field number.
  final int number;

  /// Explicit or derived JSON name.
  final String jsonName;

  /// Presence representation used for the exact comparison.
  final String presence;

  /// Exact standard field rule object.
  final Map<String, Object?>? rule;

  /// Whether the field is required.
  final bool required;

  /// Parses one field descriptor.
  factory _Field.parse(
    String messagePath,
    Map<String, Object?> source,
    Map<int, String> oneofNames,
  ) {
    final name = source['name'];
    final number = source['number'];
    if (name is! String || number is! int) {
      throw const FormatException('Descriptor field is incomplete');
    }
    final options = source['options'];
    final rule = options is Map<String, Object?>
        ? options['[buf.validate.field]']
        : null;
    final oneofIndex = source['oneofIndex'];
    final proto3Optional = source['proto3Optional'] == true;
    final presence = oneofIndex is int
        ? 'oneof:${oneofNames[oneofIndex] ?? 'index:$oneofIndex'}'
              '${proto3Optional ? ':synthetic' : ''}'
        : 'implicit';
    return _Field(
      name: name,
      number: number,
      jsonName: source['jsonName'] as String? ?? name,
      presence: presence,
      rule: rule is Map<String, Object?>
          ? Map<String, Object?>.from(rule)
          : null,
      required: rule is Map<String, Object?> && rule['required'] == true,
    );
  }
}

/// A parsed oneof's compared metadata.
final class _Oneof {
  const _Oneof({
    required this.name,
    required this.rule,
    required this.required,
  });

  /// Oneof name.
  final String name;

  /// Exact standard oneof rule object.
  final Map<String, Object?>? rule;

  /// Whether the oneof is required.
  final bool required;

  /// Parses one oneof descriptor.
  factory _Oneof.parse(String messagePath, Map<String, Object?> source) {
    final name = source['name'];
    if (name is! String) {
      throw const FormatException('Descriptor oneof has no name');
    }
    final options = source['options'];
    final rule = options is Map<String, Object?>
        ? options['[buf.validate.oneof]']
        : null;
    return _Oneof(
      name: '$messagePath.$name',
      rule: rule is Map<String, Object?>
          ? Map<String, Object?>.from(rule)
          : null,
      required: rule is Map<String, Object?> && rule['required'] == true,
    );
  }
}

/// A parsed enum's compared numeric domain.
final class _Enum {
  const _Enum({required this.name, required this.values});

  /// Fully-qualified enum name.
  final String name;

  /// Named numeric domain in stable order.
  final List<String> values;

  /// Parses one enum descriptor.
  factory _Enum.parse(String package, Map<String, Object?> source) {
    final name = source['name'];
    if (name is! String) {
      throw const FormatException('Descriptor enum has no name');
    }
    final values = <String>[];
    final valueList = source['value'];
    if (valueList is List<Object?>) {
      for (final value in valueList.whereType<Map<String, Object?>>()) {
        final number = value['number'];
        final valueName = value['name'];
        if (number is int && valueName is String) {
          values.add('$valueName=$number');
        }
      }
    }
    values.sort();
    return _Enum(name: '$package.$name', values: values);
  }
}

bool _sameJson(Object? left, Object? right) =>
    jsonEncode(_canonical(left)) == jsonEncode(_canonical(right));

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    return <String, Object?>{
      for (final key in value.keys.toList()..sort())
        key: _canonical(value[key]),
    };
  }
  if (value is List<Object?>) {
    return value.map(_canonical).toList();
  }
  return value;
}
