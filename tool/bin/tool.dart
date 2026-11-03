import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:correlia_tool/correlia_tool.dart';

/// Entry point: `dart run tool/bin/tool.dart <command>` from the repository
/// root (the mise tasks do this).
Future<void> main(List<String> args) async {
  final runner = buildRunner(
    repoRoot: Directory.current,
    out: stdout,
    err: stderr,
  );
  try {
    exitCode = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln(e.usage);
    exitCode = 64;
  }
}
