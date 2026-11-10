import 'dart:convert';
import 'dart:io';

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
    final path = _pubPackagePath('serverpod_cli');
    if (dart == null || path == null) return null;
    final version = await _versionOf(
      dart,
      ['run', 'serverpod_cli', 'version'],
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

  String? _pubPackagePath(String package) {
    final config = File('${repoRoot.path}/.dart_tool/package_config.json');
    if (!config.existsSync()) return null;
    final decoded = jsonDecode(config.readAsStringSync());
    if (decoded case {'packages': final List<Object?> packages}) {
      for (final entry in packages) {
        if (entry case {
          'name': final String name,
          'rootUri': final String uri,
        } when name == package) {
          return Uri.parse(uri).isAbsolute
              ? Uri.parse(uri).toFilePath()
              : config.parent.uri.resolve(uri).toFilePath();
        }
      }
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
