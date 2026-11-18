part of 'bootstrap.dart';

int _inputVersion(Map<String, Object?> root) =>
    switch (root['format_version']) {
      1 => 1,
      2 => 2,
      _ => _bad('config', 'format_version', 'version'),
    };

/// A source assertion method; the same key cannot cross authentication modes.
enum SourceCredentialType { bearer, hmac }

/// One immutable credential pin and its UTC receipt-time validity window.
final class SourceCredential {
  const SourceCredential(
    this.reference,
    this.type,
    this.digest,
    this.notBefore,
    this.notAfter,
  );
  final String reference;
  final SourceCredentialType type;
  final String digest;
  final DateTime? notBefore;
  final DateTime? notAfter;

  /// Whether [receipt] falls within this inclusive-start, exclusive-end window.
  bool validAt(DateTime receipt) =>
      !(notBefore?.isAfter(receipt) ?? false) &&
      (notAfter?.isAfter(receipt) ?? true);

  Map<String, Object?> toJson() => {
    'ref': reference,
    'type': type.name,
    'digest': digest,
    'not_before': ?notBefore?.toIso8601String(),
    'not_after': ?notAfter?.toIso8601String(),
  };
}

/// Per-output-process admission budget for a source.
final class SourceRateLimit {
  const SourceRateLimit({this.perSecond = 20, this.burst = 40});
  final int perSecond;
  final int burst;
  Map<String, int> toJson() => {'per_second': perSecond, 'burst': burst};
}

/// A source definition pinned by an immutable configuration snapshot.
final class IngestSource {
  IngestSource({
    required this.id,
    required this.kind,
    required this.namespace,
    required this.enabled,
    required List<SourceCredential> credentials,
    required this.pathTokenEnabled,
    required this.bodyLimitBytes,
    required this.rateLimit,
    required Set<String> excludedIdentityLabels,
    required List<String> outputIds,
  }) : credentials = List.unmodifiable(credentials),
       excludedIdentityLabels = Set.unmodifiable(excludedIdentityLabels),
       outputIds = List.unmodifiable(outputIds);
  final String id;
  final String kind;
  final String namespace;
  final bool enabled;
  final List<SourceCredential> credentials;
  final bool pathTokenEnabled;
  final int bodyLimitBytes;
  final SourceRateLimit rateLimit;
  final Set<String> excludedIdentityLabels;
  final List<String> outputIds;

  /// The deterministic public representation; old routing keys retain their shape.
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'namespace': namespace,
    'enabled': enabled,
    'credentials': credentials
        .map((credential) => credential.toJson())
        .toList(),
    'path_token_enabled': pathTokenEnabled,
    'body_limit_bytes': bodyLimitBytes,
    'rate_limit': rateLimit.toJson(),
    'excluded_identity_labels': excludedIdentityLabels.toList()..sort(),
    'output_ids': outputIds,
  };
}

typedef _CredentialInput = ({
  String reference,
  String field,
  SourceCredentialType type,
  DateTime? before,
  DateTime? after,
});

List<_CredentialInput> _credentialInputs(
  Map<String, Object?> row,
  int version,
  String field,
) {
  if (version == 1) {
    final path = '$field.token_ref';
    return [
      (
        reference: _ref(row['token_ref'], path),
        field: path,
        type: SourceCredentialType.bearer,
        before: null,
        after: null,
      ),
    ];
  }
  final entries = _list(row['credentials'], 4, '$field.credentials');
  if (entries.isEmpty) _bad('config', '$field.credentials', 'empty');
  final references = <String>{};
  return [
    for (final (i, value) in entries.indexed)
      _credentialInput(value, '$field.credentials[$i]', references),
  ];
}

_CredentialInput _credentialInput(
  Object? value,
  String field,
  Set<String> references,
) {
  final row = _map(value, 'config', field);
  _sourceFields(row, {'ref', 'type', 'not_before', 'not_after'}, field);
  final reference = _ref(row['ref'], '$field.ref');
  if (!references.add(reference)) _bad('config', '$field.ref', 'duplicate');
  final type = switch (row['type']) {
    'bearer' => SourceCredentialType.bearer,
    'hmac' => SourceCredentialType.hmac,
    _ => _bad('config', '$field.type', 'credential_type'),
  };
  final before = _instant(row['not_before'], '$field.not_before');
  final after = _instant(row['not_after'], '$field.not_after');
  if (before != null && after != null && !after.isAfter(before)) {
    _bad('config', '$field.not_after', 'credential_window');
  }
  return (
    reference: reference,
    field: '$field.ref',
    type: type,
    before: before,
    after: after,
  );
}

final _instantPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$',
);
DateTime? _instant(Object? value, String field) {
  if (value == null) return null;
  if (value is! String ||
      value.length > 32 ||
      !_instantPattern.hasMatch(value)) {
    _bad('config', field, 'instant');
  }
  final instant = DateTime.tryParse(value);
  final local = DateTime.tryParse('${value.substring(0, 19)}Z');
  final offsetStart = value.length - 6;
  if (instant == null ||
      local == null ||
      !local.toIso8601String().startsWith(value.substring(0, 19)) ||
      (!value.endsWith('Z') &&
          (int.parse(value.substring(offsetStart + 1, offsetStart + 3)) > 23 ||
              int.parse(value.substring(offsetStart + 4)) > 59))) {
    _bad('config', field, 'instant');
  }
  return instant;
}

Set<String> _namespaces(Object? value) {
  if (value == null) return const {};
  final declared = <String>{};
  for (final (i, item) in _list(value, 64, 'namespaces').indexed) {
    final field = 'namespaces[$i]';
    final name = _string(item, 128, field);
    if (_uuidPattern.hasMatch(name)) _bad('config', field, 'namespace_uuid');
    if (!declared.add(name)) _bad('config', field, 'duplicate');
  }
  return declared;
}

void _sourceFields(
  Map<String, Object?> row,
  Set<String> allowed,
  String field,
) {
  for (final key in row.keys) {
    if (!allowed.contains(key)) {
      // Only reflect short, field-like names; never raw content disguised as a key.
      final suffix = _fieldName.hasMatch(key) ? '.$key' : '';
      _bad('config', '$field$suffix', 'unknown_field');
    }
  }
}

final _fieldName = RegExp(r'^[a-z][a-z_]{0,31}$');

IngestSource _parseSource(
  Map<String, Object?> row,
  String field,
  int version,
  Set<String> namespaces,
  Set<String> outputs,
  Map<String, Uint8List> secrets,
  DateTime now,
) {
  _sourceFields(row, {
    'id',
    'namespace',
    'enabled',
    'path_token_enabled',
    'body_limit_bytes',
    'excluded_identity_labels',
    'output_ids',
    if (version == 1) 'token_ref' else ...{'kind', 'credentials', 'rate_limit'},
  }, field);
  final id = _uuid(row['id'], '$field.id');
  final kind = version == 1 ? 'alertmanager' : row['kind'];
  if (kind != 'alertmanager') _bad('config', '$field.kind', 'kind');
  final namespace = row['namespace'] == null
      ? id
      : _string(
          row['namespace'],
          version == 1 ? 1024 : 128,
          '$field.namespace',
        );
  if (version == 2 &&
      row['namespace'] != null &&
      !namespaces.contains(namespace)) {
    _bad('config', '$field.namespace', 'namespace_undeclared');
  }
  final parsed = _credentialInputs(row, version, field);
  if (!parsed.any((entry) => entry.after?.isAfter(now) ?? true)) {
    _bad('config', '$field.credentials', 'credentials_expired');
  }
  final credentials = <SourceCredential>[];
  for (final entry in parsed) {
    final bytes = secrets[entry.reference];
    if (bytes == null) _bad('config', entry.field, 'missing_secret');
    if (bytes.length != 32) _bad('secrets', 'value', 'credential_encoding');
    credentials.add(
      SourceCredential(
        entry.reference,
        entry.type,
        sha256.convert(bytes).toString(),
        entry.before,
        entry.after,
      ),
    );
  }
  credentials.sort((a, b) => a.reference.compareTo(b.reference));
  final routes = _list(
    row['output_ids'],
    8,
    '$field.output_ids',
  ).map((value) => _uuid(value, '$field.output_ids')).toSet().toList()..sort();
  if (routes.any((route) => !outputs.contains(route))) {
    _bad('config', '$field.output_ids', 'missing_output');
  }
  final exclusions =
      _list(
            row['excluded_identity_labels'] ?? <Object?>[],
            128,
            '$field.excluded_identity_labels',
          )
          .map(
            (value) => _string(value, 256, '$field.excluded_identity_labels'),
          )
          .toSet();
  var rate = const SourceRateLimit();
  if (row['rate_limit'] case final Object raw) {
    final path = '$field.rate_limit';
    final fields = _map(raw, 'config', path);
    _sourceFields(fields, {'per_second', 'burst'}, path);
    rate = SourceRateLimit(
      perSecond: _integer(
        fields['per_second'] ?? 20,
        1,
        1000,
        '$path.per_second',
      ),
      burst: _integer(fields['burst'] ?? 40, 1, 10000, '$path.burst'),
    );
  }
  return IngestSource(
    id: id,
    kind: 'alertmanager',
    namespace: namespace,
    enabled: _boolean(row['enabled'], '$field.enabled'),
    credentials: credentials,
    pathTokenEnabled: _boolean(
      row['path_token_enabled'] ?? false,
      '$field.path_token_enabled',
    ),
    bodyLimitBytes: _integer(
      row['body_limit_bytes'] ?? 1048576,
      1,
      1048576,
      '$field.body_limit_bytes',
    ),
    rateLimit: rate,
    excludedIdentityLabels: exclusions,
    outputIds: routes,
  );
}
