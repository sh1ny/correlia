import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A sanitized bootstrap rejection without operator-controlled values.
final class BootstrapError implements Exception {
  /// Creates a rejection with a fixed file kind, field path and code.
  const BootstrapError(this.fileKind, this.field, this.code);

  /// The input category.
  final String fileKind;

  /// The bounded configuration path, never a supplied value.
  final String field;

  /// The allowlisted failure code.
  final String code;

  @override
  String toString() =>
      'ingest bootstrap $fileKind ${field.length > 256 ? field.substring(0, 256) : field}: $code';
}

/// A source definition pinned by an immutable configuration snapshot.
final class IngestSource {
  /// Creates an immutable source definition.
  IngestSource({
    required this.id,
    required this.namespace,
    required this.enabled,
    required this.tokenRef,
    required this.tokenDigest,
    required this.pathTokenEnabled,
    required this.bodyLimitBytes,
    required Set<String> excludedIdentityLabels,
    required List<String> outputIds,
  }) : excludedIdentityLabels = Set.unmodifiable(excludedIdentityLabels),
       outputIds = List.unmodifiable(outputIds);
  final String id;
  final String namespace;
  final bool enabled;
  final String tokenRef;
  final String tokenDigest;
  final bool pathTokenEnabled;
  final int bodyLimitBytes;
  final Set<String> excludedIdentityLabels;
  final List<String> outputIds;

  /// The deterministic public source representation.
  Map<String, Object?> toJson() => {
    'id': id,
    'namespace': namespace,
    'enabled': enabled,
    'token_ref': tokenRef,
    'token_digest': tokenDigest,
    'path_token_enabled': pathTokenEnabled,
    'body_limit_bytes': bodyLimitBytes,
    'excluded_identity_labels': excludedIdentityLabels.toList()..sort(),
    'output_ids': outputIds.toList()..sort(),
  };
}

/// A validated output definition pinned in a configuration snapshot.
sealed class IngestOutput {
  const IngestOutput(this.id);

  /// The output identity.
  final String id;

  /// The public definition, without secret bytes.
  Map<String, Object?> toJson();

  /// The reference commitments used by this definition.
  Map<String, String> get commitments;
}

/// A validated immutable webhook destination.
final class WebhookIngestOutput extends IngestOutput {
  const WebhookIngestOutput({
    required String id,
    required this.url,
    required this.signingKeyRef,
    required this.signingKeyCommitment,
  }) : super(id);
  final Uri url;
  final String signingKeyRef;
  final String signingKeyCommitment;

  @override
  Map<String, String> get commitments => {signingKeyRef: signingKeyCommitment};

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': 'webhook',
    'url': url.toString(),
    'signing_key_ref': signingKeyRef,
    'signing_key_commitment': signingKeyCommitment,
  };
}

/// A secret reference and its digest, without secret material.
final class PluginSecretReference {
  const PluginSecretReference(this.reference, this.commitment);
  final String reference;
  final String commitment;
}

/// A validated plugin definition with canonical public configuration.
final class PluginIngestOutput extends IngestOutput {
  PluginIngestOutput({
    required String id,
    required this.plugin,
    required this.sha256,
    required Map<String, Object?> config,
    required Map<String, PluginSecretReference> secretRefs,
  }) : config = _canonical(config)! as Map<String, Object?>,
       secretRefs = Map.unmodifiable(secretRefs),
       super(id);
  final String plugin;
  final String sha256;
  final Map<String, Object?> config;
  final Map<String, PluginSecretReference> secretRefs;

  @override
  Map<String, String> get commitments => {
    for (final ref in secretRefs.values) ref.reference: ref.commitment,
  };

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': 'plugin',
    'plugin': plugin,
    'sha256': sha256,
    'config': config,
    'secret_refs': {
      for (final entry in secretRefs.entries)
        entry.key: {
          'reference': entry.value.reference,
          'commitment': entry.value.commitment,
        },
    },
  };

  /// The content address of the canonical public definition.
  String get definitionDigest => sha256Digest(toJson());
}

/// Computes the SHA-256 of a canonical JSON value.
String sha256Digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return Map<String, Object?>.unmodifiable({
      for (final key in keys) key: _canonical(value[key]),
    });
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_canonical));
  }
  return value;
}

/// A validated publication input and process-local immutable signing material.
final class IngestBootstrap {
  IngestBootstrap._(
    this.revision,
    List<IngestSource> sources,
    List<IngestOutput> outputs,
    Map<String, Uint8List> secrets,
  ) : sources = List.unmodifiable(sources),
      outputs = List.unmodifiable(outputs),
      _secrets = Map.unmodifiable(secrets);

  final int revision;
  final List<IngestSource> sources;
  final List<IngestOutput> outputs;
  final Map<String, Uint8List> _secrets;

  /// The loaded reference names; values never enter persisted configuration.
  Set<String> get loadedReferences => Set.unmodifiable(_secrets.keys);

  /// Returns immutable loaded signing bytes for a reference.
  Uint8List? secret(String reference) =>
      _secrets[reference]?.asUnmodifiableView();

  /// The canonical public snapshot bytes.
  String get publicJson => jsonEncode({
    'format_version': 1,
    'revision': revision,
    'sources': sources.map((source) => source.toJson()).toList(),
    'outputs': outputs.map((output) => output.toJson()).toList(),
  });

  /// The content address, including revision but never secret bytes.
  String get snapshotId => sha256.convert(utf8.encode(publicJson)).toString();

  /// Parses the bounded source and destination registry without reflecting input.
  static IngestBootstrap parse(
    Object? config,
    Object? secretInput, {
    required String runMode,
  }) {
    try {
      final root = _map(config, 'config', r'$');
      _keys(
        root,
        {'format_version', 'revision', 'sources', 'outputs'},
        'config',
        r'$',
      );
      if (root['format_version'] != 1) {
        _bad('config', 'format_version', 'version');
      }
      final revision = _integer(root['revision'], 1, 2147483647, 'revision');
      final secretMap = _map(secretInput, 'secrets', r'$');
      if (secretMap.length > 128) _bad('secrets', r'$', 'bound');
      final secrets = <String, Uint8List>{};
      var totalBytes = 0;
      for (final MapEntry(:key, :value) in secretMap.entries) {
        if (!_reference.hasMatch(key)) _bad('secrets', r'$', 'reference');
        final bytes = _decodeSecret(value);
        totalBytes += bytes.length;
        if (totalBytes > 256 * 1024) _bad('secrets', r'$', 'bound');
        secrets[key] = bytes;
      }
      final outputs = <IngestOutput>[];
      final outputIds = <String>{};
      for (final (index, value) in _list(
        root['outputs'],
        64,
        'outputs',
      ).indexed) {
        final field = 'outputs[$index]';
        final row = _map(value, 'config', field);
        final id = _uuid(row['id'], '$field.id');
        if (!outputIds.add(id)) _bad('config', '$field.id', 'duplicate');
        switch (row['kind']) {
          case 'webhook':
            _keys(
              row,
              {'id', 'kind', 'url', 'signing_key_ref'},
              'config',
              field,
            );
            final ref = _ref(row['signing_key_ref'], '$field.signing_key_ref');
            final key = secrets[ref];
            if (key == null) {
              _bad('config', '$field.signing_key_ref', 'missing_secret');
            }
            if (key.length != 32) {
              _bad('secrets', 'value', 'credential_encoding');
            }
            outputs.add(
              WebhookIngestOutput(
                id: id,
                url: validateWebhookUrl(
                  row['url'],
                  runMode: runMode,
                  field: '$field.url',
                ),
                signingKeyRef: ref,
                signingKeyCommitment: sha256.convert(key).toString(),
              ),
            );
          case 'plugin':
            _keys(
              row,
              {'id', 'kind', 'plugin', 'sha256', 'config', 'secret_refs'},
              'config',
              field,
            );
            final name = _string(row['plugin'], 64, '$field.plugin');
            if (!_pluginName.hasMatch(name)) {
              _bad('config', '$field.plugin', 'plugin');
            }
            final digest = _string(row['sha256'], 64, '$field.sha256');
            if (!_sha256Pattern.hasMatch(digest)) {
              _bad('config', '$field.sha256', 'digest');
            }
            final pluginConfig = _map(row['config'], 'config', '$field.config');
            if (utf8.encode(jsonEncode(pluginConfig)).length > 16384) {
              _bad('config', '$field.config', 'bound');
            }
            final refs = _map(
              row['secret_refs'],
              'config',
              '$field.secret_refs',
            );
            if (refs.length > 8) _bad('config', '$field.secret_refs', 'bound');
            final references = <String, PluginSecretReference>{};
            final names = refs.keys.toList()..sort();
            for (final name in names) {
              if (!_reference.hasMatch(name)) {
                _bad('config', '$field.secret_refs', 'reference');
              }
              final ref = _ref(refs[name], '$field.secret_refs');
              final bytes = secrets[ref];
              if (bytes == null) {
                _bad('config', '$field.secret_refs', 'missing_secret');
              }
              references[name] = PluginSecretReference(
                ref,
                sha256.convert(bytes).toString(),
              );
            }
            outputs.add(
              PluginIngestOutput(
                id: id,
                plugin: name,
                sha256: digest,
                config: pluginConfig,
                secretRefs: references,
              ),
            );
          default:
            _bad('config', '$field.kind', 'kind');
        }
      }
      final sources = <IngestSource>[];
      final sourceIds = <String>{};
      for (final (index, value) in _list(
        root['sources'],
        64,
        'sources',
      ).indexed) {
        final field = 'sources[$index]';
        final row = _map(value, 'config', field);
        _keys(
          row,
          {
            'id',
            'namespace',
            'enabled',
            'token_ref',
            'path_token_enabled',
            'body_limit_bytes',
            'excluded_identity_labels',
            'output_ids',
          },
          'config',
          field,
        );
        final id = _uuid(row['id'], '$field.id');
        if (!sourceIds.add(id)) _bad('config', '$field.id', 'duplicate');
        final ref = _ref(row['token_ref'], '$field.token_ref');
        final token = secrets[ref];
        if (token == null) _bad('config', '$field.token_ref', 'missing_secret');
        if (token.length != 32) _bad('secrets', 'value', 'credential_encoding');
        final namespace = row['namespace'] == null
            ? id
            : _string(row['namespace'], 1024, '$field.namespace');
        final routes =
            _list(row['output_ids'], 8, '$field.output_ids')
                .map((value) => _uuid(value, '$field.output_ids'))
                .toSet()
                .toList()
              ..sort();
        if (routes.any((id) => !outputIds.contains(id))) {
          _bad('config', '$field.output_ids', 'missing_output');
        }
        final exclusions =
            _list(
                  row['excluded_identity_labels'] ?? <Object?>[],
                  128,
                  '$field.excluded_identity_labels',
                )
                .map(
                  (value) =>
                      _string(value, 256, '$field.excluded_identity_labels'),
                )
                .toSet();
        sources.add(
          IngestSource(
            id: id,
            namespace: namespace,
            enabled: _boolean(row['enabled'], '$field.enabled'),
            tokenRef: ref,
            tokenDigest: sha256.convert(token).toString(),
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
            excludedIdentityLabels: exclusions,
            outputIds: routes,
          ),
        );
      }
      sources.sort((a, b) => a.id.compareTo(b.id));
      outputs.sort((a, b) => a.id.compareTo(b.id));
      return IngestBootstrap._(revision, sources, outputs, secrets);
    } on BootstrapError {
      rethrow;
    } catch (_) {
      throw const BootstrapError('config', r'$', 'invalid');
    }
  }

  /// Reads both startup files with a hard byte cap and secret ownership checks.
  static Future<IngestBootstrap?> load(
    Map<String, String> environment, {
    required String runMode,
    bool requirePluginDirectory = true,
  }) async {
    final configPath = environment['CORRELIA_INGEST_CONFIG'];
    final secretPath = environment['CORRELIA_INGEST_SECRETS'];
    if (configPath == null && secretPath == null) return null;
    if (configPath == null || secretPath == null) {
      throw const BootstrapError('config', r'$', 'paired_files_required');
    }
    final config = await _readFile(configPath, 'config');
    final secrets = await _readFile(secretPath, 'secrets');
    final input = parse(config, secrets, runMode: runMode);
    if (requirePluginDirectory &&
        input.outputs.any((o) => o is PluginIngestOutput)) {
      await _validatePluginDirectory(environment['CORRELIA_PLUGIN_DIR']);
    }
    return input;
  }
}

final _reference = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');
final _uuidPattern = RegExp(
  r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
);
final _credential = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _pluginName = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
final _base64url = RegExp(r'^[A-Za-z0-9_-]+$');

Uint8List _decodeSecret(Object? value) {
  if (value is String) {
    return decodeCredential(value, fileKind: 'secrets', field: 'value');
  }
  if (value is! Map<String, Object?> ||
      value.length != 1 ||
      !value.containsKey('bytes')) {
    _bad('secrets', 'value', 'credential_encoding');
  }
  final encoded = value['bytes'];
  if (encoded is! String || !_base64url.hasMatch(encoded)) {
    _bad('secrets', 'value', 'credential_encoding');
  }
  if (encoded.length > 21846) _bad('secrets', 'value', 'bound');
  try {
    final bytes = base64Url.decode(base64Url.normalize(encoded));
    if (bytes.isEmpty || bytes.length > 16384) {
      _bad('secrets', 'value', 'bound');
    }
    if (base64Url.encode(bytes).replaceAll('=', '') != encoded) {
      _bad('secrets', 'value', 'credential_encoding');
    }
    return bytes;
  } on BootstrapError {
    rethrow;
  } catch (_) {
    _bad('secrets', 'value', 'credential_encoding');
  }
}

Future<void> _validatePluginDirectory(String? path) async {
  try {
    if (path == null ||
        path.isEmpty ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory) {
      _bad('config', 'CORRELIA_PLUGIN_DIR', 'directory');
    }
    final stat = await Directory(path).stat();
    if ((stat.mode & 0x12) != 0) {
      _bad('config', 'CORRELIA_PLUGIN_DIR', 'permissions');
    }
    final owner = await Process.run('/usr/bin/stat', ['-c', '%u', '--', path]);
    final user = await Process.run('/usr/bin/id', ['-u']);
    if (owner.exitCode != 0 ||
        user.exitCode != 0 ||
        owner.stdout.toString().trim() != user.stdout.toString().trim()) {
      _bad('config', 'CORRELIA_PLUGIN_DIR', 'owner');
    }
  } on BootstrapError {
    rethrow;
  } catch (_) {
    _bad('config', 'CORRELIA_PLUGIN_DIR', 'directory');
  }
}

/// Decodes exactly 32 bytes in canonical unpadded base64url form.
Uint8List decodeCredential(
  Object? value, {
  String fileKind = 'config',
  String field = 'credential',
}) {
  if (value is! String || !_credential.hasMatch(value)) {
    _bad(fileKind, field, 'credential_encoding');
  }
  try {
    final bytes = base64Url.decode('$value=');
    if (bytes.length != 32 ||
        base64Url.encode(bytes).replaceAll('=', '') != value) {
      _bad(fileKind, field, 'credential_encoding');
    }
    return bytes;
  } on BootstrapError {
    rethrow;
  } catch (_) {
    throw BootstrapError(fileKind, field, 'credential_encoding');
  }
}

/// Validates an operator destination without exposing it in failures.
Uri validateWebhookUrl(
  Object? value, {
  required String runMode,
  String field = 'url',
}) {
  try {
    final text = _string(value, 2048, field);
    final uri = Uri.parse(text);
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      _bad('config', field, 'url');
    }
    final loopback =
        uri.host == 'localhost' ||
        (InternetAddress.tryParse(uri.host)?.isLoopback ?? false);
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' &&
            loopback &&
            {'development', 'test'}.contains(runMode))) {
      _bad('config', field, 'url');
    }
    return uri;
  } on BootstrapError {
    rethrow;
  } catch (_) {
    throw BootstrapError('config', field, 'url');
  }
}

/// Reads a regular input file with a bounded size and sanitized failures.
///
/// Private inputs are checked against the process owner and mode 0600 or
/// stricter. [effectiveUid] allows testing the owner comparison without root.
Future<Uint8List> readBootstrapFile(
  String path,
  String kind, {
  required int cap,
  bool private = false,
  int? effectiveUid,
}) async {
  try {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      _bad(kind, r'$', 'regular_file');
    }
    final file = File(path);
    final stat = await file.stat();
    if (stat.size > cap) _bad(kind, r'$', 'bound');
    if (private) {
      if ((stat.mode & 0x7f) != 0) _bad(kind, r'$', 'permissions');
      final owner = await Process.run('/usr/bin/stat', [
        '-c',
        '%u',
        '--',
        path,
      ]);
      final int uid;
      if (effectiveUid != null) {
        uid = effectiveUid;
      } else {
        final user = await Process.run('/usr/bin/id', ['-u']);
        if (user.exitCode != 0) _bad(kind, r'$', 'owner');
        uid = int.parse((user.stdout as String).trim());
      }
      if (owner.exitCode != 0 ||
          int.tryParse((owner.stdout as String).trim()) != uid) {
        _bad(kind, r'$', 'owner');
      }
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > cap) _bad(kind, r'$', 'bound');
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } on BootstrapError {
    rethrow;
  } catch (_) {
    throw BootstrapError(kind, r'$', 'read_or_parse');
  }
}

Future<Object?> _readFile(String path, String kind) async {
  final secrets = kind == 'secrets';
  final bytes = await readBootstrapFile(
    path,
    kind,
    cap: (secrets ? 512 : 64) * 1024,
    private: secrets,
  );
  try {
    return jsonDecode(utf8.decode(bytes));
  } catch (_) {
    throw BootstrapError(kind, r'$', 'read_or_parse');
  }
}

Never _bad(String kind, String field, String code) =>
    throw BootstrapError(kind, field, code);
Map<String, Object?> _map(Object? value, String kind, String field) {
  if (value is! Map<String, Object?>) _bad(kind, field, 'object');
  return value;
}

void _keys(
  Map<String, Object?> value,
  Set<String> allowed,
  String kind,
  String field,
) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    _bad(kind, field, 'unknown_field');
  }
}

List<Object?> _list(Object? value, int max, String field) {
  if (value is! List<Object?>) _bad('config', field, 'list');
  if (value.length > max) _bad('config', field, 'bound');
  return value;
}

String _string(Object? value, int max, String field) {
  if (value is! String || value.isEmpty || utf8.encode(value).length > max) {
    _bad('config', field, 'string_bound');
  }
  return value;
}

String _uuid(Object? value, String field) {
  final text = _string(value, 36, field);
  if (!_uuidPattern.hasMatch(text)) _bad('config', field, 'uuid');
  return text.toLowerCase();
}

String _ref(Object? value, String field) {
  final text = _string(value, 128, field);
  if (!_reference.hasMatch(text)) _bad('config', field, 'reference');
  return text;
}

bool _boolean(Object? value, String field) {
  if (value is! bool) _bad('config', field, 'boolean');
  return value;
}

int _integer(Object? value, int min, int max, String field) {
  if (value is! int || value < min || value > max) {
    _bad('config', field, 'integer_bound');
  }
  return value;
}
