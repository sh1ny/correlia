import 'dart:io';

import 'resolved_package.dart';

/// A tool found on this machine: where it lives and the version it reports.
class ResolvedTool {
  /// Creates a resolved tool.
  const ResolvedTool({required this.path, required this.version});

  /// Absolute path of the executable (or package, for `serverpod_cli`).
  final String path;

  /// Version the tool reports.
  final String version;
}

/// Finds a pinned tool. Injected so `doctor` is testable without processes.
abstract interface class ToolResolver {
  /// Resolves [tool], or returns `null` when it cannot be found or run.
  Future<ResolvedTool?> resolve(String tool);
}

/// Resolves tools from the process `PATH` and by running them.
///
/// `tool doctor` runs under `mise run`, where the pinned tools are first on
/// `PATH`; the Serverpod CLI is the pub package the workspace resolved.
class ProcessToolResolver implements ToolResolver {
  /// Creates a resolver for the repository at [repoRoot].
  ProcessToolResolver(this.repoRoot);

  /// The repository root.
  final Directory repoRoot;

  static final _semver = RegExp(r'(\d+\.\d+\.\d+)');
  static final _serverpodVersion = RegExp(
    r'^Serverpod version: (\d+\.\d+\.\d+)\s*$',
    multiLine: true,
  );

  static const _versionArgs = <String, List<String>>{
    'dart': ['--version'],
    'flutter': ['--version'],
    'go': ['version'],
    'buf': ['--version'],
    'openspec': ['--version'],
  };

  @override
  Future<ResolvedTool?> resolve(String tool) async {
    if (tool == 'serverpod_cli') return _serverpodCli();
    final args = _versionArgs[tool];
    final path = _onPath(tool);
    if (args == null || path == null) return null;
    final version = await _versionOf(path, args);
    return version == null ? null : ResolvedTool(path: path, version: version);
  }

  Future<ResolvedTool?> _serverpodCli() async {
    final dart = _onPath('dart');
    final path = resolvedPackagePath(repoRoot, 'serverpod_cli');
    if (dart == null || path == null) return null;
    // Version inspection must not refresh pub dependencies or check for updates.
    // Use the resolved entry point; --version exits before CLI startup checks.
    final version = await _versionOf(
      dart,
      [
        '--packages=${repoRoot.path}/.dart_tool/package_config.json',
        '$path/bin/serverpod_cli.dart',
        '--version',
      ],
      workingDirectory: '${repoRoot.path}/correlia_server',
      pattern: _serverpodVersion,
    );
    return version == null ? null : ResolvedTool(path: path, version: version);
  }

  String? _onPath(String name) {
    final path = Platform.environment['PATH'] ?? '';
    for (final dir in path.split(':')) {
      if (dir.isEmpty) continue;
      final candidate = '$dir/$name';
      if (FileSystemEntity.isFileSync(candidate)) return candidate;
    }
    return null;
  }

  Future<String?> _versionOf(
    String executable,
    List<String> args, {
    String? workingDirectory,
    RegExp? pattern,
  }) async {
    final result = await Process.run(
      executable,
      args,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) return null;
    return (pattern ?? _semver)
        .firstMatch('${result.stdout}${result.stderr}')
        ?.group(1);
  }
}
