import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';

import 'resolved_package.dart';

/// The result of running one process: its exit code and combined output.
typedef ProcessOutcome = ({int exit, String output});

/// Runs [executable] with [args] in [workingDirectory]. Injected so tests can
/// substitute the processes `tool generated` starts.
typedef ProcessLauncher =
    Future<ProcessOutcome> Function(
      String executable,
      List<String> args,
      Directory workingDirectory,
    );

/// Runs a real process, capturing stdout and stderr.
Future<ProcessOutcome> runProcess(
  String executable,
  List<String> args,
  Directory workingDirectory,
) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory.path,
  );
  return (exit: result.exitCode, output: '${result.stdout}${result.stderr}');
}

/// How a committed generated file differs from what the generator produces.
sealed class GeneratedDifference {
  const GeneratedDifference(this.path);

  /// Path relative to the repository root.
  final String path;
}

/// The committed file has other content than the generated one.
final class ContentDiffers extends GeneratedDifference {
  /// Creates the difference.
  const ContentDiffers(super.path);

  @override
  String toString() => '$path (content differs)';
}

/// The generator produces a file that is not committed.
final class MissingInCheckout extends GeneratedDifference {
  /// Creates the difference.
  const MissingInCheckout(super.path);

  @override
  String toString() => '$path (generated but not committed)';
}

/// A committed file in a generated directory that is no longer generated.
final class NoLongerGenerated extends GeneratedDifference {
  /// Creates the difference.
  const NoLongerGenerated(super.path);

  @override
  String toString() => '$path (committed but no longer generated)';
}

/// `tool generated`: fails when the committed Serverpod generated code is not
/// what the pinned generator produces from the models and endpoints (D5).
///
/// It never writes the checkout. It builds a self-contained temporary
/// workspace of `correlia_server` and `correlia_client` holding only the
/// generator inputs, resolves it with `dart pub get --offline`, runs the
/// pinned `serverpod_cli generate` there and compares its output with the
/// checkout.
///
/// Inputs copied: the root `pubspec.yaml` (workspace list replaced by the two
/// packages), the root `pubspec.lock` and `analysis_options.yaml`; for each
/// package its `pubspec.yaml`, `analysis_options.yaml` and `lib/` without the
/// generated directory; and `correlia_server/config/generator.yaml`. Never
/// `.dart_tool/`, `build/`, `passwords.yaml` or a package configuration.
///
/// Outputs compared (every file, both directions): [generatedDirectories].
class GeneratedCommand extends Command<int> {
  /// Creates the command for the repository at [repoRoot].
  GeneratedCommand({
    required this.repoRoot,
    required this.launch,
    required this.dartExecutable,
    required this.out,
    required this.err,
  });

  /// The generated directories, relative to the repository root.
  static const generatedDirectories = [
    'correlia_server/lib/src/generated',
    'correlia_server/test/integration/test_tools',
    'correlia_client/lib/src/protocol',
  ];

  static const _packages = ['correlia_server', 'correlia_client'];

  /// The repository root (the checkout, which is only read).
  final Directory repoRoot;

  /// Starts the processes; defaults are provided by [runProcess].
  final ProcessLauncher launch;

  /// The Dart SDK's `dart` executable.
  final String dartExecutable;

  /// Receives progress messages.
  final StringSink out;

  /// Receives failures.
  final StringSink err;

  @override
  String get name => 'generated';

  @override
  String get description =>
      'Fail when the committed generated code differs from the generator.';

  @override
  Future<int> run() async {
    final scratch = Directory.systemTemp.createTempSync('correlia_generated_');
    try {
      final workspace = Directory('${scratch.path}/workspace')..createSync();
      _buildWorkspace(workspace);
      final server = Directory('${workspace.path}/correlia_server');

      final get = await launch(dartExecutable, [
        'pub',
        'get',
        '--offline',
      ], workspace);
      if (get.exit != 0) return _fail('dart pub get --offline failed', get);

      final drift = _lockDrift(
        File('${repoRoot.path}/pubspec.lock'),
        File('${workspace.path}/pubspec.lock'),
      );
      if (drift.isNotEmpty) {
        err.writeln(
          'FAIL the temporary workspace resolved other versions than the '
          'committed pubspec.lock:',
        );
        for (final line in drift) {
          err.writeln('  $line');
        }
        return 1;
      }

      final cli = resolvedPackagePath(workspace, 'serverpod_cli');
      if (cli == null) {
        err.writeln(
          'FAIL serverpod_cli is missing from the resolved workspace',
        );
        return 1;
      }
      // Code generation needs no native assets. dart run would download CLI
      // transitive native libraries into this disposable workspace on every run.
      final generate = await launch(dartExecutable, [
        '--packages=${workspace.path}/.dart_tool/package_config.json',
        '$cli/bin/serverpod_cli.dart',
        'generate',
      ], server);
      if (generate.exit != 0) {
        return _fail('serverpod_cli generate failed', generate);
      }

      final differences = [
        for (final directory in generatedDirectories)
          ..._compare(directory, workspace),
      ];
      if (differences.isNotEmpty) {
        err.writeln('FAIL generated code is stale; run `mise run generate`:');
        for (final difference in differences) {
          err.writeln('  $difference');
        }
        return 1;
      }
      out.writeln('generated code is current');
      return 0;
    } finally {
      scratch.deleteSync(recursive: true);
    }
  }

  int _fail(String message, ProcessOutcome outcome) {
    err
      ..writeln('FAIL $message (exit ${outcome.exit})')
      ..writeln(outcome.output);
    return 1;
  }

  void _buildWorkspace(Directory workspace) {
    final rootPubspec = File('${repoRoot.path}/pubspec.yaml');
    final text = rootPubspec.readAsStringSync();
    final header = text.substring(0, text.indexOf('workspace:'));
    File('${workspace.path}/pubspec.yaml').writeAsStringSync(
      '${header}workspace:\n${_packages.map((p) => '  - $p\n').join()}',
    );
    for (final file in ['pubspec.lock', 'analysis_options.yaml']) {
      _copy(File('${repoRoot.path}/$file'), workspace, file);
    }
    for (final package in _packages) {
      for (final file in ['pubspec.yaml', 'analysis_options.yaml']) {
        _copy(
          File('${repoRoot.path}/$package/$file'),
          workspace,
          '$package/$file',
        );
      }
      final lib = Directory('${repoRoot.path}/$package/lib');
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File) continue;
        final relative = entity.path.substring(repoRoot.path.length + 1);
        if (_isGenerated(relative)) continue;
        _copy(entity, workspace, relative);
      }
    }
    _copy(
      File('${repoRoot.path}/correlia_server/config/generator.yaml'),
      workspace,
      'correlia_server/config/generator.yaml',
    );
  }

  static bool _isGenerated(String relative) => generatedDirectories.any(
    (directory) => relative.startsWith('$directory/'),
  );

  static void _copy(File source, Directory root, String relative) {
    if (!source.existsSync()) return;
    final target = File('${root.path}/$relative')
      ..parent.createSync(recursive: true);
    source.copySync(target.path);
  }

  List<GeneratedDifference> _compare(String directory, Directory workspace) {
    final committed = _files(Directory('${repoRoot.path}/$directory'));
    final generated = _files(Directory('${workspace.path}/$directory'));
    return [
      for (final path in {
        ...committed.keys,
        ...generated.keys,
      }.toList()..sort())
        switch ((committed[path], generated[path])) {
          (final File c, final File g) when !_sameBytes(c, g) => ContentDiffers(
            '$directory/$path',
          ),
          (final File _, null) => NoLongerGenerated('$directory/$path'),
          (null, final File _) => MissingInCheckout('$directory/$path'),
          _ => null,
        },
    ].whereType<GeneratedDifference>().toList();
  }

  static Map<String, File> _files(Directory directory) => {
    if (directory.existsSync())
      for (final entity in directory.listSync(recursive: true))
        if (entity is File)
          entity.path.substring(directory.path.length + 1): entity,
  };

  static bool _sameBytes(File a, File b) {
    final Uint8List x = a.readAsBytesSync();
    final Uint8List y = b.readAsBytesSync();
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  /// Lines naming each package in [resolved] whose version is not the one in
  /// [pinned]. Pub drops lock entries the two-package workspace does not need;
  /// it must never choose another version.
  static List<String> _lockDrift(File pinned, File resolved) {
    final before = _versions(pinned.readAsStringSync());
    final after = _versions(resolved.readAsStringSync());
    return [
      for (final MapEntry(:key, :value) in after.entries)
        if (before[key] != value) '$key: ${before[key] ?? 'absent'} -> $value',
    ];
  }

  static Map<String, String> _versions(String lock) => {
    for (final match in RegExp(
      r'^  (\S+):\n(?:    .*\n)*?    version: "([^"]+)"',
      multiLine: true,
    ).allMatches(lock))
      match.group(1)!: match.group(2)!,
  };
}
