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

/// The contract a source speaks; fixed for a source UUID's lifetime.
sealed class SourceKind {
  const SourceKind._(this.name);

  /// The Alertmanager webhook kind.
  static const SourceKind alertmanager = AlertmanagerSourceKind._();

  /// The Icinga 2 notification-command kind.
  static const SourceKind icinga2 = Icinga2SourceKind._();

  /// The declaratively mapped webhook kind.
  static const SourceKind generic = GenericSourceKind._();

  /// The configuration and route name of this kind.
  final String name;

  /// The kind named [value], or `null` when it is not supported.
  static SourceKind? named(Object? value) => switch (value) {
    'alertmanager' => alertmanager,
    'icinga2' => icinga2,
    'generic' => generic,
    _ => null,
  };
}

/// See [SourceKind.alertmanager].
final class AlertmanagerSourceKind extends SourceKind {
  const AlertmanagerSourceKind._() : super._('alertmanager');
}

/// See [SourceKind.icinga2].
final class Icinga2SourceKind extends SourceKind {
  const Icinga2SourceKind._() : super._('icinga2');
}

/// See [SourceKind.generic].
final class GenericSourceKind extends SourceKind {
  const GenericSourceKind._() : super._('generic');
}

/// Whether Icinga 2 state comes from a webhook or a leased stream.
enum SourceMode {
  webhook('webhook'),
  eventStreams('event_streams');

  const SourceMode(this.wire);

  /// The stable configuration and database spelling.
  final String wire;
}

/// Which Icinga 2 problem states can open a stream alert.
enum StreamStateTypePolicy {
  hardOnly('hard_only'),
  softAndHard('soft_and_hard');

  const StreamStateTypePolicy(this.wire);

  /// The stable configuration spelling.
  final String wire;
}

/// Public Event Streams settings; secret values are never serialized here.
final class IcingaStreamOptions {
  const IcingaStreamOptions({
    required this.url,
    required this.username,
    required this.passwordRef,
    required this.caRef,
    required this.syncInterval,
    required this.stateTypePolicy,
    required this.maxPendingRows,
  });

  /// Operator-facing default, minimum and maximum interval in seconds.
  static const syncIntervalSeconds = (
    standard: 3600,
    minimum: 300,
    maximum: 86400,
  );

  /// Operator-facing default, minimum and maximum retained rows per source.
  static const pendingRows = (standard: 1000, minimum: 100, maximum: 10000);

  final Uri url;
  final String username;
  final String passwordRef;
  final String caRef;
  final Duration syncInterval;
  final StreamStateTypePolicy stateTypePolicy;
  final int maxPendingRows;

  /// Writes only the non-secret endpoint settings and secret references.
  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'username': username,
    'password_ref': passwordRef,
    'ca_ref': caRef,
    'sync_interval_seconds': syncInterval.inSeconds,
  };
}

/// A source definition pinned by an immutable configuration snapshot.
final class IngestSource {
  IngestSource({
    required this.id,
    required this.kind,
    required this.declaredAt,
    required this.namespace,
    required this.enabled,
    required List<SourceCredential> credentials,
    required this.pathTokenEnabled,
    required this.bodyLimitBytes,
    required this.rateLimit,
    required Set<String> excludedIdentityLabels,
    this.stream,
    this.mapping,
    required List<String> outputIds,
  }) : credentials = List.unmodifiable(credentials),
       excludedIdentityLabels = Set.unmodifiable(excludedIdentityLabels),
       outputIds = List.unmodifiable(outputIds);
  final String id;
  final SourceKind kind;

  /// The index of this source in the file's `sources` list, for field errors.
  final int declaredAt;
  final String namespace;
  final bool enabled;
  final List<SourceCredential> credentials;
  final bool pathTokenEnabled;
  final int? bodyLimitBytes;
  final SourceRateLimit? rateLimit;
  final Set<String> excludedIdentityLabels;
  final List<String> outputIds;

  /// The connection settings of a stream source, absent for webhooks.
  final IcingaStreamOptions? stream;

  /// The mapping name, present only for [SourceKind.generic].
  final String? mapping;

  /// The source's immutable admission mode.
  SourceMode get mode =>
      stream == null ? SourceMode.webhook : SourceMode.eventStreams;

  /// The deterministic public representation; old routing keys retain their shape.
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'namespace': namespace,
    'enabled': enabled,
    if (stream case final api?) ...{
      'mode': SourceMode.eventStreams.wire,
      'api': api.toJson(),
      'state_type_policy': api.stateTypePolicy.wire,
      'max_pending_rows': api.maxPendingRows,
    } else ...{
      'credentials': credentials
          .map((credential) => credential.toJson())
          .toList(),
      'path_token_enabled': pathTokenEnabled,
      'body_limit_bytes': bodyLimitBytes,
      'rate_limit': rateLimit!.toJson(),
    },
    'mapping': ?mapping,
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

SourceMode _sourceMode(
  Map<String, Object?> row,
  SourceKind kind,
  String field,
) {
  if (!row.containsKey('mode')) return SourceMode.webhook;
  if (kind is! Icinga2SourceKind) _bad('config', '$field.mode', 'icinga2_only');
  return switch (row['mode']) {
    'webhook' => SourceMode.webhook,
    'event_streams' => SourceMode.eventStreams,
    _ => _bad('config', '$field.mode', 'mode'),
  };
}

IcingaStreamOptions _streamOptions(Map<String, Object?> row, String field) {
  final path = '$field.api';
  final api = _map(row['api'], 'config', path);
  _sourceFields(api, {
    'url',
    'username',
    'password_ref',
    'ca_ref',
    'sync_interval_seconds',
  }, path);
  final url = Uri.tryParse(_string(api['url'], 2048, '$path.url'));
  if (url == null ||
      url.scheme != 'https' ||
      url.host.isEmpty ||
      url.authority.contains('@') ||
      url.port < 1 ||
      url.port > 65535 ||
      url.path.isNotEmpty ||
      url.hasQuery ||
      url.hasFragment) {
    _bad('config', '$path.url', 'invalid_url');
  }
  const intervals = IcingaStreamOptions.syncIntervalSeconds;
  final interval = api['sync_interval_seconds'] ?? intervals.standard;
  if (interval is! int ||
      interval < intervals.minimum ||
      interval > intervals.maximum) {
    _bad('config', '$path.sync_interval_seconds', 'out_of_range');
  }
  return IcingaStreamOptions(
    url: url,
    username: _string(api['username'], 256, '$path.username'),
    passwordRef: _ref(api['password_ref'], '$path.password_ref'),
    caRef: _ref(api['ca_ref'], '$path.ca_ref'),
    syncInterval: Duration(seconds: interval),
    stateTypePolicy: switch (row['state_type_policy'] ?? 'hard_only') {
      'hard_only' => StreamStateTypePolicy.hardOnly,
      'soft_and_hard' => StreamStateTypePolicy.softAndHard,
      _ => _bad('config', '$field.state_type_policy', 'state_type_policy'),
    },
    maxPendingRows: _integer(
      row['max_pending_rows'] ?? IcingaStreamOptions.pendingRows.standard,
      IcingaStreamOptions.pendingRows.minimum,
      IcingaStreamOptions.pendingRows.maximum,
      '$field.max_pending_rows',
    ),
  );
}

IngestSource _parseSource(
  Map<String, Object?> row,
  int index,
  String field,
  int version,
  Set<String> namespaces,
  Map<String, GenericMapping> mappings,
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
    if (version == 1)
      'token_ref'
    else ...{
      'kind',
      'credentials',
      'rate_limit',
      'mode',
      'api',
      'state_type_policy',
      'max_pending_rows',
      'mapping',
    },
  }, field);
  final id = _uuid(row['id'], '$field.id');
  final kind =
      SourceKind.named(version == 1 ? 'alertmanager' : row['kind']) ??
      _bad('config', '$field.kind', 'kind');
  final mode = _sourceMode(row, kind, field);
  final IcingaStreamOptions? stream;
  if (mode == SourceMode.eventStreams) {
    for (final option in const [
      'credentials',
      'body_limit_bytes',
      'rate_limit',
    ]) {
      if (row.containsKey(option)) {
        _bad('config', '$field.$option', 'webhook_only');
      }
    }
    stream = _streamOptions(row, field);
    final password = secrets[stream.passwordRef];
    if (password == null) {
      _bad('config', '$field.api.password_ref', 'missing_secret');
    }
    if (password.isEmpty || password.length > 1024) {
      _bad('secrets', 'value', 'bound');
    }
    final ca = secrets[stream.caRef];
    if (ca == null) {
      _bad('config', '$field.api.ca_ref', 'missing_secret');
    }
    if (ca.isEmpty || ca.length > 16384) {
      _bad('secrets', 'value', 'bound');
    }
  } else {
    for (final option in const [
      'api',
      'state_type_policy',
      'max_pending_rows',
    ]) {
      if (row.containsKey(option)) {
        _bad('config', '$field.$option', 'stream_only');
      }
    }
    stream = null;
  }
  if (kind is! AlertmanagerSourceKind) {
    // Only Alertmanager has a credential-bearing path and label identity.
    for (final option in const [
      'path_token_enabled',
      'excluded_identity_labels',
    ]) {
      if (row.containsKey(option)) {
        _bad('config', '$field.$option', 'alertmanager_only');
      }
    }
  }
  final String? mapping;
  if (kind is GenericSourceKind) {
    mapping = _mappingName(row['mapping'], '$field.mapping');
    if (!mappings.containsKey(mapping)) {
      _bad('config', '$field.mapping', 'unknown_mapping');
    }
  } else {
    if (row.containsKey('mapping')) {
      _bad('config', '$field.mapping', 'generic_only');
    }
    mapping = null;
  }
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
  final parsed = stream == null
      ? _credentialInputs(row, version, field)
      : const <_CredentialInput>[];
  if (stream == null &&
      !parsed.any((entry) => entry.after?.isAfter(now) ?? true)) {
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
  SourceRateLimit? rate = stream == null ? const SourceRateLimit() : null;
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
    kind: kind,
    declaredAt: index,
    namespace: namespace,
    enabled: _boolean(row['enabled'], '$field.enabled'),
    credentials: credentials,
    pathTokenEnabled: _boolean(
      row['path_token_enabled'] ?? false,
      '$field.path_token_enabled',
    ),
    bodyLimitBytes: stream == null
        ? _integer(
            row['body_limit_bytes'] ?? 1048576,
            1,
            1048576,
            '$field.body_limit_bytes',
          )
        : null,
    rateLimit: rate,
    excludedIdentityLabels: exclusions,
    stream: stream,
    mapping: mapping,
    outputIds: routes,
  );
}
