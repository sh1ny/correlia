import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import '../event/canonical_event.dart';
import '../event/validation.dart';
import '../event_generated/correlia/event/v1/event_bounds.dart';
import '../matcher/matcher_document.dart';

part 'generic_mapping.dart';
part 'pipeline_policy.dart';
part 'source_config.dart';

/// A sanitized bootstrap rejection without operator-controlled values.
final class BootstrapError implements Exception {
  /// Creates a rejection with a fixed file kind, field path and code.
  const BootstrapError(
    this.fileKind,
    this.field,
    this.code, {
    this.missingOutputId,
  });

  /// The input category.
  final String fileKind;

  /// The bounded configuration path, never a supplied value.
  final String field;

  /// The allowlisted failure code.
  final String code;

  /// The validated UUID of a missing matcher output.
  final String? missingOutputId;

  @override
  String toString() =>
      'ingest bootstrap $fileKind ${field.length > 256 ? field.substring(0, 256) : field}: $code'
      '${missingOutputId == null ? '' : ' ($missingOutputId)'}';
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
    this.mappings,
    this.matcher,
    this.pipelinePolicy,
    this.expectation,
    Map<String, Uint8List> secrets,
  ) : sources = List.unmodifiable(sources),
      outputs = List.unmodifiable(outputs),
      _secrets = Map.unmodifiable(secrets);

  final int revision;
  final List<IngestSource> sources;
  final List<IngestOutput> outputs;

  /// The validated mappings in snapshot order, keyed by name.
  final Map<String, GenericMapping> mappings;

  /// Rules persisted with the source and output registry.
  final MatcherDocument matcher;

  /// The versioned policy shared by workers, admission and maintenance.
  final PipelinePolicy pipelinePolicy;

  /// The publication-only expectation, if the operator supplied one.
  final ({String? snapshotId})? expectation;

  IngestBootstrap._runtime(
    this.revision,
    this.sources,
    this.outputs,
    this.mappings,
    this.matcher,
    this.pipelinePolicy,
    this.expectation,
  ) : _secrets = const {};

  /// Returns the validated configuration without its publication material.
  IngestBootstrap withoutImport() => IngestBootstrap._runtime(
    revision,
    sources,
    outputs,
    mappings,
    matcher,
    pipelinePolicy,
    null,
  );
  final Map<String, Uint8List> _secrets;

  /// The loaded reference names; values never enter persisted configuration.
  Set<String> get loadedReferences => Set.unmodifiable(_secrets.keys);

  /// Returns immutable loaded signing bytes for a reference.
  Uint8List? secret(String reference) =>
      _secrets[reference]?.asUnmodifiableView();

  /// The canonical public snapshot bytes.
  ///
  /// A configuration without mappings retains its pre-mapping bytes and ID.
  String get publicJson => jsonEncode({
    'format_version': 2,
    'revision': revision,
    'sources': sources.map((source) => source.toJson()).toList(),
    'outputs': outputs.map((output) => output.toJson()).toList(),
    if (mappings.isNotEmpty)
      'mappings': [for (final mapping in mappings.values) mapping.toJson()],
    if (matcher.rules.isNotEmpty) 'matcher': _canonical(matcher.snapshotJson),
    if (pipelinePolicy.snapshotJson() case final policy when policy.isNotEmpty)
      'pipeline_operations': policy,
  });

  /// The content address, including revision but never secret bytes.
  String get snapshotId => sha256.convert(utf8.encode(publicJson)).toString();

  /// Parses the bounded source and destination registry without reflecting input.
  static IngestBootstrap parse(
    Object? config,
    Object? secretInput, {
    required String runMode,
    String Function(String reference, List<int> bytes)? pluginCommitment,
    DateTime Function()? clock,
  }) {
    final parsed = parseResolved(
      config,
      decodeBootstrapSecrets(secretInput),
      runMode: runMode,
      pluginCommitment: pluginCommitment,
      clock: clock,
    );
    parsed.validateStreamImportEncoding(secretInput);
    return parsed;
  }

  /// Requires byte-object syntax for stream material supplied by this import.
  /// References absent from the import have already been resolved from storage.
  void validateStreamImportEncoding(Object? secretInput) {
    final imports = _map(secretInput, 'secrets', r'$');
    for (final source in sources) {
      if (source.stream case final stream?) {
        if (imports[stream.passwordRef] is String ||
            imports[stream.caRef] is String) {
          _bad('secrets', 'value', 'credential_encoding');
        }
      }
    }
  }

  /// Parses a publication using material already decoded or read from the store.
  static IngestBootstrap parseResolved(
    Object? config,
    Map<String, Uint8List> secrets, {
    required String runMode,
    String Function(String reference, List<int> bytes)? pluginCommitment,
    DateTime Function()? clock,
  }) {
    try {
      final root = _map(config, 'config', r'$');
      final version = _inputVersion(root);
      _sourceFields(root, {
        'format_version',
        'revision',
        'sources',
        'outputs',
        if (version == 2) ...{
          'namespaces',
          'mappings',
          'matcher',
          'expected_active_snapshot',
          'pipeline_operations',
        },
      }, r'$');
      final revision = _integer(root['revision'], 1, 2147483647, 'revision');
      final namespaces = version == 2
          ? _namespaces(root['namespaces'])
          : const <String>{};
      final mappings = root.containsKey('mappings')
          ? _parseMappings(root['mappings'])
          : const <String, GenericMapping>{};
      final now = (clock ?? DateTime.now)();

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
                pluginCommitment?.call(ref, bytes) ??
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
        final source = _parseSource(
          _map(value, 'config', field),
          index,
          field,
          version,
          namespaces,
          mappings,
          outputIds,
          secrets,
          now,
        );
        if (!sourceIds.add(source.id)) _bad('config', '$field.id', 'duplicate');
        sources.add(source);
      }
      sources.sort((a, b) => a.id.compareTo(b.id));
      outputs.sort((a, b) => a.id.compareTo(b.id));
      final matcher = root.containsKey('matcher')
          ? MatcherDocument.parse(root['matcher'], outputIds)
          : MatcherDocument.empty;
      final policy = root.containsKey('pipeline_operations')
          ? PipelinePolicy._parse(root['pipeline_operations'], outputIds)
          : PipelinePolicy._defaults;
      final expected = root['expected_active_snapshot'];
      if (expected != null &&
          (expected is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected))) {
        _bad('config', 'expected_active_snapshot', 'snapshot_id');
      }
      return IngestBootstrap._(
        revision,
        sources,
        outputs,
        mappings,
        matcher,
        policy,
        root.containsKey('expected_active_snapshot')
            ? (snapshotId: expected as String?)
            : null,
        secrets,
      );
    } on BootstrapError {
      rethrow;
    } on MatcherDocumentError catch (error) {
      throw BootstrapError(
        'config',
        error.field,
        error.code,
        missingOutputId: error.missingOutputId,
      );
    } catch (_) {
      throw const BootstrapError('config', r'$', 'invalid');
    }
  }

  /// Lists configuration references with the same source parser used at activation.
  static Iterable<String> references(Object? config) sync* {
    final root = _map(config, 'config', r'$');
    final version = _inputVersion(root);
    for (final (index, value) in _list(
      root['sources'],
      64,
      'sources',
    ).indexed) {
      final field = 'sources[$index]';
      final row = _map(value, 'config', field);
      final kind =
          SourceKind.named(version == 1 ? 'alertmanager' : row['kind']) ??
          _bad('config', '$field.kind', 'kind');
      if (_sourceMode(row, kind, field) == SourceMode.eventStreams) {
        final api = _map(row['api'], 'config', '$field.api');
        yield _ref(api['password_ref'], '$field.api.password_ref');
        yield _ref(api['ca_ref'], '$field.api.ca_ref');
        continue;
      }
      for (final credential in _credentialInputs(row, version, field)) {
        yield credential.reference;
      }
    }
    for (final output in _list(root['outputs'], 64, 'outputs')) {
      switch (output) {
        case {'kind': 'webhook', 'signing_key_ref': final String ref}
            when _reference.hasMatch(ref):
          yield ref;
        case {'kind': 'plugin', 'secret_refs': final Map<String, Object?> refs}
            when refs.length <= 8:
          yield* refs.values.whereType<String>().where(_reference.hasMatch);
      }
    }
  }

  /// Reads both startup files with a hard byte cap and secret ownership checks.
  static Future<IngestBootstrap?> load(
    Map<String, String> environment, {
    required String runMode,
    bool requirePluginDirectory = true,
    Future<IngestBootstrap> Function(Object? config, Object? secrets)? publish,
  }) async {
    final configPath = environment['CORRELIA_INGEST_CONFIG'];
    final secretPath = environment['CORRELIA_INGEST_SECRETS'];
    if (configPath == null && secretPath == null) return null;
    if (configPath == null) {
      throw const BootstrapError('config', r'$', 'paired_files_required');
    }
    final config = await _readFile(configPath, 'config');
    final secrets = secretPath == null
        ? <String, Object?>{}
        : await _readFile(secretPath, 'secrets');
    if (publish != null) {
      final outputs = config is Map<String, Object?> ? config['outputs'] : null;
      if (requirePluginDirectory &&
          outputs is List<Object?> &&
          outputs.any(
            (o) => o is Map<String, Object?> && o['kind'] == 'plugin',
          )) {
        await _validatePluginDirectory(environment['CORRELIA_PLUGIN_DIR']);
      }
      return publish(config, secrets);
    }
    final input = parse(config, secrets, runMode: runMode);
    if (requirePluginDirectory &&
        input.outputs.any((o) => o is PluginIngestOutput)) {
      await _validatePluginDirectory(environment['CORRELIA_PLUGIN_DIR']);
    }
    return input;
  }
}

/// Decodes the bounded import file without exposing its values in errors.
Map<String, Uint8List> decodeBootstrapSecrets(Object? input) {
  final entries = _map(input, 'secrets', r'$');
  if (entries.length > 128) _bad('secrets', r'$', 'bound');
  final secrets = <String, Uint8List>{};
  var total = 0;
  for (final MapEntry(:key, :value) in entries.entries) {
    if (!_reference.hasMatch(key)) _bad('secrets', r'$', 'reference');
    final bytes = _decodeSecret(value);
    total += bytes.length;
    if (total > 256 * 1024) _bad('secrets', r'$', 'bound');
    secrets[key] = bytes;
  }
  return secrets;
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
    final text = utf8.decode(bytes);
    final lowerPath = path.toLowerCase();
    if (!secrets &&
        (lowerPath.endsWith('.yaml') || lowerPath.endsWith('.yml'))) {
      return _yamlData(loadYamlNode(text));
    }
    return jsonDecode(text);
  } on BootstrapError {
    rethrow;
  } catch (_) {
    throw BootstrapError(kind, r'$', 'read_or_parse');
  }
}

Object? _yamlData(YamlNode root) {
  var remaining = 64 * 1024;
  Object? visit(YamlNode node, int depth) {
    if (--remaining < 0 || depth > 32) _bad('config', r'$', 'yaml_bound');
    return switch (node) {
      YamlMap() => <String, Object?>{
        for (final entry in node.nodes.entries)
          _yamlKey(entry.key): visit(entry.value, depth + 1),
      },
      YamlList() => <Object?>[
        for (final element in node.nodes) visit(element, depth + 1),
      ],
      YamlScalar(:final value)
          when value == null ||
              value is String ||
              value is bool ||
              value is int ||
              (value is double && value.isFinite) =>
        value,
      _ => _bad('config', r'$', 'yaml_value'),
    };
  }

  return visit(root, 1);
}

String _yamlKey(Object? key) => switch (key) {
  YamlScalar(value: final String text) => text,
  _ => _bad('config', r'$', 'yaml_key'),
};

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
