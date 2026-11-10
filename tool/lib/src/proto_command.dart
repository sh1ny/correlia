import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'bounds_extractor.dart';
import 'contract_compatibility.dart';
import 'schema_patch.dart';

/// The result of running one bounded subprocess.
typedef BoundedProcessOutcome = ({int exit, String output});

/// Runs a bounded subprocess with captured diagnostics.
typedef BoundedProcessLauncher =
    Future<BoundedProcessOutcome> Function(
      String executable,
      List<String> args,
      Directory workingDirectory,
    );

/// Generates or checks the canonical event protobuf contract.
///
/// `proto` writes generated Dart, schema and bounds into their owned
/// directories. `proto:check` regenerates into disposable scratch, compares
/// every output in both directions and never changes the checkout.
class ProtoCommand extends Command<int> {
  /// Creates a protobuf contract command.
  ProtoCommand({
    required this.repoRoot,
    required this.dartExecutable,
    required this.launch,
    required this.out,
    required this.err,
    required this.write,
    this.compatibilityOnly = false,
  });

  /// The repository root.
  final Directory repoRoot;

  /// The pinned Dart executable.
  final String dartExecutable;

  /// The bounded subprocess launcher.
  final BoundedProcessLauncher launch;

  /// Receives success output.
  final StringSink out;

  /// Receives diagnostics.
  final StringSink err;

  /// Whether generation writes the owned outputs.
  final bool write;

  /// Whether the command stops after compatibility checks.
  final bool compatibilityOnly;

  @override
  String get name => write ? 'proto' : 'proto:check';

  @override
  String get description => write
      ? 'Generate the canonical event contract outputs.'
      : 'Check the canonical event contract for compatibility and drift.';

  /// The generated Dart output directory relative to the repository root.
  static const dartOutputDirectory = 'correlia_server/lib/src/event_generated';

  /// The generated payload schema path relative to the repository root.
  static const schemaOutputPath =
      'contracts/schemas/correlia.event.v1.CanonicalEvent.jsonschema.strict.bundle.json';

  /// The committed v1.0 descriptor baseline path.
  static const baselinePath = 'contracts/baselines/event-v1.0.binpb';

  static const _maxProtoFiles = 256;
  static const _maxImageBytes = 16 * 1024 * 1024;
  static const _maxOutputBytes = 4 * 1024 * 1024;

  @override
  Future<int> run() async {
    final scratch = Directory.systemTemp.createTempSync('correlia_proto_');
    try {
      final inputError = _validateInputs();
      if (inputError != null) {
        err.writeln('FAIL $inputError');
        return 1;
      }

      final lint = await _run('buf lint', 'buf', ['lint']);
      if (lint.exit != 0) return _fail('buf lint', lint);

      final descriptorPath = '${scratch.path}/descriptor.json';
      final build = await _run(
        'buf build',
        'buf',
        ['build', '--as-file-descriptor-set', '-o', descriptorPath],
      );
      if (build.exit != 0) return _fail('buf build', build);
      if (!_withinLimit(File(descriptorPath), _maxImageBytes)) {
        err.writeln('FAIL buf build image exceeds 16 MiB');
        return 1;
      }

      final baseline = File('${repoRoot.path}/$baselinePath');
      if (!baseline.existsSync()) {
        err.writeln(
          'FAIL compatibility baseline is missing: $baselinePath; '
          'it is never rebuilt automatically',
        );
        return 1;
      }
      final breaking = await _run(
        'buf breaking',
        'buf',
        [
          'breaking',
          '--against',
          baseline.path,
          '--config',
          '${repoRoot.path}/buf.yaml',
        ],
      );
      if (breaking.exit != 0) return _fail('buf breaking', breaking);

      final baselineJsonPath = '${scratch.path}/baseline.json';
      final baselineBuild = await _run(
        'buf build baseline descriptor',
        'buf',
        [
          'build',
          baseline.path,
          '--as-file-descriptor-set',
          '-o',
          baselineJsonPath,
        ],
      );
      if (baselineBuild.exit != 0) {
        return _fail('buf build baseline descriptor', baselineBuild);
      }
      final baselineImage = File(baselineJsonPath);
      if (!_withinLimit(baselineImage, _maxImageBytes)) {
        err.writeln('FAIL baseline descriptor image exceeds 16 MiB');
        return 1;
      }
      final descriptorJson = File(descriptorPath).readAsStringSync();
      final baselineJson = baselineImage.readAsStringSync();
      final differences = compareContractDescriptors(
        baselineJson: baselineJson,
        candidateJson: descriptorJson,
      );
      if (differences.isNotEmpty) {
        err.writeln(
          'FAIL canonical event validation contract is incompatible with '
          '$baselinePath:',
        );
        for (final difference in differences) {
          err.writeln('  $difference');
        }
        return 1;
      }
      if (compatibilityOnly) {
        out.writeln('canonical event contract is compatible with v1.0');
        return 0;
      }

      final generated = await _generate(scratch);
      if (generated.exit != 0) return _fail('buf generate', generated);
      final selectedSchema = _selectSchema(scratch);
      if (selectedSchema == null) {
        err.writeln(
          'FAIL buf generate did not produce '
          'correlia.event.v1.CanonicalEvent.jsonschema.strict.bundle.json',
        );
        return 1;
      }
      if (!_withinLimit(selectedSchema, _maxOutputBytes)) {
        err.writeln('FAIL generated payload schema exceeds 4 MiB');
        return 1;
      }

      final patchedSchema = _patchSchema(
        selectedSchema: selectedSchema,
        descriptorJson: descriptorJson,
      );
      if (patchedSchema == null) return 1;

      final bounds = _generateBounds(descriptorJson);
      if (bounds == null) return 1;

      final outputs = <String, String>{
        schemaOutputPath: encodeJson(patchedSchema),
        '$dartOutputDirectory/correlia/event/v1/event_bounds.dart': bounds,
      };
      final validationSchema = File('${scratch.path}/payload.schema.json')
        ..writeAsStringSync(outputs[schemaOutputPath]!);
      final validation = await _run(
        'Ajv payload fixture validation',
        'node',
        [
          '${repoRoot.path}/tool/schema_validation/validate.mjs',
          validationSchema.path,
          '${repoRoot.path}/tool/schema_validation/fixtures',
        ],
      );
      if (validation.exit != 0) {
        return _fail('Ajv payload fixture validation', validation);
      }
      final dartRoot = Directory('${scratch.path}/dart');
      if (dartRoot.existsSync()) {
        for (final entity in dartRoot.listSync(recursive: true)) {
          if (entity is! File) continue;
          if (!_withinLimit(entity, _maxOutputBytes)) {
            err.writeln(
              'FAIL generated output ${entity.path} exceeds 4 MiB',
            );
            return 1;
          }
        }
      }
      final schemaRoot = Directory('${scratch.path}/schema');
      if (schemaRoot.existsSync()) {
        for (final entity in schemaRoot.listSync(recursive: true)) {
          if (entity is! File) continue;
          if (!_withinLimit(entity, _maxOutputBytes)) {
            err.writeln(
              'FAIL generated output ${entity.path} exceeds 4 MiB',
            );
            return 1;
          }
        }
      }
      final dartDirectory = Directory(
        '${scratch.path}/dart/correlia/event/v1',
      )..createSync(recursive: true);
      for (final entity in dartDirectory.listSync()) {
        if (entity is! File) continue;
        final relative = entity.path.substring(
          '${scratch.path}/dart/'.length,
        );
        outputs['$dartOutputDirectory/$relative'] = entity.readAsStringSync();
      }
      if (outputs.keys.any(
        (path) => !path.endsWith('.dart') && !path.endsWith('.json'),
      )) {
        err.writeln('FAIL generated output has an unsupported extension');
        return 1;
      }

      final formatted = await _format(outputs, scratch);
      if (formatted.exit != 0) {
        err
          ..writeln('FAIL dart format failed (exit ${formatted.exit})')
          ..writeln(_boundedDiagnostics(formatted.diagnostics));
        return 1;
      }

      if (write) {
        _writeOutputs(formatted.outputs);
        out.writeln('generated canonical event contract outputs');
        return 0;
      }

      final drift = _compareOutputs(formatted.outputs);
      if (drift.isNotEmpty) {
        err.writeln(
          'FAIL canonical event contract outputs are stale; run `mise run proto`:',
        );
        for (final difference in drift) {
          err.writeln('  $difference');
        }
        return 1;
      }
      out.writeln('canonical event contract is compatible and current');
      return 0;
    } finally {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  String? _validateInputs() {
    final protoRoot = Directory('${repoRoot.path}/proto');
    if (!protoRoot.existsSync()) return 'proto directory is missing';
    var count = 0;
    for (final entity in protoRoot.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('.proto')) continue;
      count++;
      if (count > _maxProtoFiles) {
        return 'proto input exceeds $_maxProtoFiles files';
      }
    }
    return null;
  }

  Future<BoundedProcessOutcome> _run(
    String stage,
    String executable,
    List<String> args, {
    Directory? workingDirectory,
  }) async {
    final outcome = await launch(
      executable,
      args,
      workingDirectory ?? repoRoot,
    );
    return (
      exit: outcome.exit,
      output: '$stage: ${outcome.output}',
    );
  }

  Future<BoundedProcessOutcome> _generate(Directory scratch) async {
    final template = '${scratch.path}/buf.gen.yaml';
    final pluginRoot = Directory('${scratch.path}/plugin')..createSync();
    File('${pluginRoot.path}/pubspec.yaml').writeAsStringSync('''
name: correlia_proto_plugin
publish_to: none

environment:
  sdk: ^3.12.2

dependencies:
  protobuf: 6.1.0

dev_dependencies:
  protoc_plugin: 25.1.0
''');
    final get = await _run(
      'dart pub get --offline for Dart generator',
      dartExecutable,
      ['pub', 'get', '--offline'],
      workingDirectory: pluginRoot,
    );
    if (get.exit != 0) {
      return (exit: get.exit, output: get.output);
    }
    File(template).writeAsStringSync('''
version: v2
plugins:
  - local: ["$dartExecutable", "run", "protoc_plugin:protoc_plugin"]
    out: ${scratch.path}/dart
  - local: ["go", "run", "github.com/bufbuild/protoschema-plugins/cmd/protoc-gen-jsonschema@v0.6.0"]
    out: ${scratch.path}/schema
''');
    return _run(
      'buf generate',
      'buf',
      ['generate', repoRoot.path, '--template', template],
      workingDirectory: pluginRoot,
    );
  }

  File? _selectSchema(Directory scratch) {
    final file = File(
      '${scratch.path}/schema/'
      'correlia.event.v1.CanonicalEvent.jsonschema.strict.bundle.json',
    );
    return file.existsSync() ? file : null;
  }

  Map<String, Object?>? _patchSchema({
    required File selectedSchema,
    required String descriptorJson,
  }) {
    try {
      final decoded = jsonDecode(selectedSchema.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Generated schema is not an object');
      }
      final descriptor = jsonDecode(descriptorJson);
      if (descriptor is! Map<String, Object?>) {
        throw const FormatException('Descriptor image is not an object');
      }
      final files = descriptor['file'];
      if (files is! List<Object?>) {
        throw const FormatException('Descriptor image has no files');
      }
      final eventFile = files.whereType<Map<String, Object?>>().firstWhere(
        (file) => file['package'] == 'correlia.event.v1',
        orElse: () => throw const FormatException(
          'Descriptor image has no canonical event file',
        ),
      );
      final messages = eventFile['messageType'];
      if (messages is! List<Object?>) {
        throw const FormatException('Descriptor image has no messages');
      }
      final canonicalEvent = messages
          .whereType<Map<String, Object?>>()
          .firstWhere(
            (message) => message['name'] == 'CanonicalEvent',
            orElse: () => throw const FormatException(
              'Descriptor image has no CanonicalEvent message',
            ),
          );
      final fields = canonicalEvent['field'];
      if (fields is! List<Object?>) {
        throw const FormatException('CanonicalEvent has no fields');
      }

      final definitions = decoded[r'$defs'];
      if (definitions is! Map<String, Object?>) {
        throw const FormatException('Generated bundle has no definitions');
      }
      final canonicalDefinition = definitions.values
          .whereType<Map<String, Object?>>()
          .firstWhere(
            (definition) => definition['title'] == 'Canonical Event',
            orElse: () => throw const FormatException(
              'Generated bundle has no Canonical Event definition',
            ),
          );
      for (final field in fields.whereType<Map<String, Object?>>()) {
        final name = field['name'];
        if (name is! String) continue;
        final options = field['options'];
        if (options is! Map<String, Object?>) continue;
        final rule = options['[buf.validate.field]'];
        if (rule is! Map<String, Object?>) continue;
        final mapRule = rule['map'];
        if (mapRule is! Map<String, Object?>) continue;
        patchMapEntryBounds(
          schema: canonicalDefinition,
          descriptor: field,
          fieldPath: name,
        );
      }
      return decoded;
    } on FormatException catch (error) {
      err.writeln('FAIL generated schema patch: ${error.message}');
      return null;
    }
  }

  String? _generateBounds(String descriptorJson) {
    try {
      final constants = extractBounds(descriptorJson);
      final buffer = StringBuffer()
        ..writeln('// This is a generated file - do not edit.')
        ..writeln()
        ..writeln(
          '/// Bounds extracted from the canonical event validation rules.',
        )
        ..writeln('abstract final class CanonicalEventBounds {');
      for (final constant in constants) {
        buffer
          ..writeln('  /// The bound for `${constant.fieldPath}`.')
          ..writeln('  ${constant.declaration}');
      }
      buffer.writeln('}');
      return buffer.toString();
    } on FormatException catch (error) {
      err.writeln('FAIL generated bounds: ${error.message}');
      return null;
    }
  }

  Future<({int exit, String diagnostics, Map<String, String> outputs})> _format(
    Map<String, String> outputs,
    Directory scratch,
  ) async {
    final formatRoot = Directory('${scratch.path}/format')..createSync();
    final dartOutputs = <String, String>{};
    for (final entry in outputs.entries) {
      if (!entry.key.endsWith('.dart')) continue;
      final relative = entry.key.substring(dartOutputDirectory.length + 1);
      final file = File('${formatRoot.path}/$relative')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry.value);
      dartOutputs[entry.key] = file.path;
    }
    File(
      '${formatRoot.path}/pubspec.yaml',
    ).writeAsStringSync(_scratchPubspec());
    File(
      '${formatRoot.path}/analysis_options.yaml',
    ).writeAsStringSync(_scratchAnalysisOptions());
    final get = await _run(
      'dart pub get --offline',
      dartExecutable,
      ['pub', 'get', '--offline'],
      workingDirectory: formatRoot,
    );
    if (get.exit != 0) {
      return (exit: get.exit, diagnostics: get.output, outputs: outputs);
    }

    final result = await _run(
      'dart format',
      dartExecutable,
      ['format', '--output=write', ...dartOutputs.values],
    );
    if (result.exit != 0) {
      return (exit: result.exit, diagnostics: result.output, outputs: outputs);
    }
    return (
      exit: 0,
      diagnostics: result.output,
      outputs: {
        for (final entry in outputs.entries)
          if (dartOutputs.containsKey(entry.key))
            entry.key: File(dartOutputs[entry.key]!).readAsStringSync()
          else
            entry.key: entry.value,
      },
    );
  }

  String _scratchPubspec() {
    final source = File(
      '${repoRoot.path}/correlia_server/pubspec.yaml',
    ).readAsStringSync();
    final environment = RegExp(
      r'^environment:\n(?:  .+\n)+',
      multiLine: true,
    ).firstMatch(source)?.group(0);
    if (environment == null) {
      throw StateError('correlia_server pubspec has no environment section');
    }
    return '''
name: correlia_event_format_scratch
publish_to: none

$environment
dev_dependencies:
  lints: ">=3.0.0 <7.0.0"
''';
  }

  String _scratchAnalysisOptions() {
    return File(
      '${repoRoot.path}/analysis_options.yaml',
    ).readAsStringSync();
  }

  void _writeOutputs(Map<String, String> outputs) {
    final ownedRoots = [dartOutputDirectory, 'contracts/schemas'];
    for (final root in ownedRoots) {
      final directory = Directory('${repoRoot.path}/$root');
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
      directory.createSync(recursive: true);
    }
    for (final entry in outputs.entries) {
      File('${repoRoot.path}/${entry.key}')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
  }

  List<String> _compareOutputs(Map<String, String> generated) {
    final differences = <String>[];
    final owned = generated.keys.toSet();
    for (final path in owned) {
      final committed = File('${repoRoot.path}/$path');
      final expected = generated[path];
      if (expected == null) continue;
      if (!committed.existsSync()) {
        differences.add('$path (generated but not committed)');
      } else if (committed.readAsStringSync() != expected) {
        differences.add('$path (content differs)');
      }
    }
    for (final directory in [
      dartOutputDirectory,
      'contracts/schemas',
    ]) {
      final committedDirectory = Directory('${repoRoot.path}/$directory');
      if (!committedDirectory.existsSync()) continue;
      for (final entity in committedDirectory.listSync(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path.substring(repoRoot.path.length + 1);
        if (!owned.contains(path)) {
          differences.add('$path (committed but no longer generated)');
        }
      }
    }
    differences.sort();
    return differences;
  }

  int _fail(String stage, BoundedProcessOutcome outcome) {
    err
      ..writeln('FAIL $stage failed (exit ${outcome.exit})')
      ..writeln(_boundedDiagnostics(outcome.output));
    return 1;
  }
}

String _boundedDiagnostics(String output) {
  const limit = 1024 * 1024;
  if (output.length <= limit) return output;
  return '${output.substring(0, limit)}\n[diagnostics truncated at 1 MiB]';
}

bool _withinLimit(File file, int limit) =>
    file.existsSync() && file.lengthSync() <= limit;

/// Runs a process with a 60-second deadline and bounded captured diagnostics.
///
/// GNU timeout owns the child process group, so the deadline terminates the
/// complete process tree without matching or signalling unrelated processes.
Future<BoundedProcessOutcome> runBoundedProcess(
  String executable,
  List<String> args,
  Directory workingDirectory, {
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    '/usr/bin/timeout',
    [
      '--signal=KILL',
      '--kill-after=2s',
      '60s',
      executable,
      ...args,
    ],
    workingDirectory: workingDirectory.path,
    environment: environment,
  );
  final capture = _BoundedDiagnosticCapture();
  final stdoutDone = process.stdout
      .transform(SystemEncoding().decoder)
      .listen(capture.add)
      .asFuture<void>();
  final stderrDone = process.stderr
      .transform(SystemEncoding().decoder)
      .listen(capture.add)
      .asFuture<void>();
  final exitCode = await process.exitCode;
  await stdoutDone;
  await stderrDone;
  final diagnostics = capture.text;
  return (
    exit: exitCode,
    output: exitCode == 124
        ? '$diagnostics\n[subprocess timed out after 60 seconds]'
        : diagnostics,
  );
}

/// Captures at most one MiB of process diagnostics while draining all input.
final class _BoundedDiagnosticCapture {
  static const _limit = 1024 * 1024;

  final StringBuffer _buffer = StringBuffer();
  int _length = 0;
  bool _truncated = false;

  /// Adds a decoded output fragment without retaining excess text.
  void add(String fragment) {
    if (_length >= _limit) {
      _truncated = true;
      return;
    }
    final remaining = _limit - _length;
    if (fragment.length <= remaining) {
      _buffer.write(fragment);
      _length += fragment.length;
      return;
    }
    _buffer.write(fragment.substring(0, remaining));
    _length = _limit;
    _truncated = true;
  }

  /// The bounded diagnostic text.
  String get text {
    if (!_truncated) return _buffer.toString();
    return '${_buffer.toString()}\n[diagnostics truncated at 1 MiB]';
  }
}
