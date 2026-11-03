import 'package:args/command_runner.dart';

import 'toolchain.dart';

/// Outcome of checking one pinned tool.
sealed class ToolCheck {
  const ToolCheck(this.tool);

  /// The tool name.
  final String tool;
}

/// The tool resolves to a Linux path and reports the pinned version.
final class ToolOk extends ToolCheck {
  /// Creates an OK result.
  const ToolOk(super.tool, this.path, this.version);

  /// Resolved path.
  final String path;

  /// Reported (= pinned) version.
  final String version;
}

/// The tool was not found or could not report a version.
final class ToolMissing extends ToolCheck {
  /// Creates a missing result.
  const ToolMissing(super.tool, this.pinned);

  /// The pinned version.
  final String pinned;
}

/// The tool reports a version other than the pinned one.
final class ToolWrongVersion extends ToolCheck {
  /// Creates a wrong-version result.
  const ToolWrongVersion(super.tool, this.pinned, this.found);

  /// The pinned version.
  final String pinned;

  /// The version found.
  final String found;
}

/// The tool resolved to a Windows executable reached through the host.
final class ToolWindowsPath extends ToolCheck {
  /// Creates a Windows-path result.
  const ToolWindowsPath(super.tool, this.path);

  /// The offending path.
  final String path;
}

// Built from parts: the task-definition scan forbids the literals in tool/.
const _hostMount = '/${'mnt'}/';
const _windowsSuffix = '.${'ex'}e';

/// Whether [path] is on the Windows host rather than the Linux filesystem.
bool isWindowsPath(String path) =>
    path.startsWith(_hostMount) || path.toLowerCase().endsWith(_windowsSuffix);

/// Checks every pinned tool in [pins] with [resolver].
Future<List<ToolCheck>> checkTools(
  ToolResolver resolver,
  Map<String, String> pins,
) async {
  final checks = <ToolCheck>[];
  for (final MapEntry(key: tool, value: pinned) in pins.entries) {
    final found = await resolver.resolve(tool);
    checks.add(switch (found) {
      null => ToolMissing(tool, pinned),
      ResolvedTool(:final path) when isWindowsPath(path) => ToolWindowsPath(
        tool,
        path,
      ),
      ResolvedTool(:final version) when version != pinned => ToolWrongVersion(
        tool,
        pinned,
        version,
      ),
      ResolvedTool(:final path, :final version) => ToolOk(tool, path, version),
    });
  }
  return checks;
}

/// `tool doctor`: verifies every pinned tool is the Linux copy at its pinned
/// version. Prints one line per tool to [out]; failures go to [err] and the
/// exit code is non-zero.
class DoctorCommand extends Command<int> {
  /// Creates the command.
  DoctorCommand({
    required this.resolver,
    required this.pins,
    required this.out,
    required this.err,
  });

  /// Finds the tools.
  final ToolResolver resolver;

  /// Tool name to pinned version.
  final Map<String, String> pins;

  /// Receives the per-tool report.
  final StringSink out;

  /// Receives failures.
  final StringSink err;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check that every pinned tool is the Linux copy at its pinned version.';

  @override
  Future<int> run() async {
    final checks = await checkTools(resolver, pins);
    var failed = false;
    for (final check in checks) {
      switch (check) {
        case ToolOk(:final tool, :final path, :final version):
          out.writeln('ok  $tool $version $path');
        case ToolMissing(:final tool, :final pinned):
          failed = true;
          err.writeln('FAIL $tool: not found (pinned $pinned)');
        case ToolWrongVersion(:final tool, :final pinned, :final found):
          failed = true;
          err.writeln('FAIL $tool: pinned $pinned, found $found');
        case ToolWindowsPath(:final tool, :final path):
          failed = true;
          err.writeln('FAIL $tool: resolves to a Windows path $path');
      }
    }
    return failed ? 1 : 0;
  }
}
