import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

/// Runs `dart test` with [args] in [workingDirectory] and returns its exit
/// code. Injected so tests can capture the output of a real run.
typedef DartTestLauncher =
    Future<int> Function(List<String> args, Directory workingDirectory);

/// Launches the running Dart SDK's `dart test`, sharing this process' stdio.
Future<int> launchDartTest(
  List<String> args,
  Directory workingDirectory,
) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['test', ...args],
    workingDirectory: workingDirectory.path,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

/// Builds the arguments for `dart test` from the user's [userArgs] (D4).
///
/// Tests are grouped in tiers by tag (`db`, `e2e`, `plugin`, `load`); untagged
/// tests are the fast tier. With no arguments the result is `-P fast`. With
/// arguments, they are passed through and at most two things are added:
///
/// * `-x load`, unless the arguments select the `load` tag, and
/// * `-P fast`, when the arguments select no tag at all.
///
/// A tag selection is `--tags X`, `--tags=X`, `-t X` or `-tX`, where X is a
/// tag expression such as `db || e2e`. `-x`/`--exclude-tags` does not select a
/// tag. When [all] is true the fast preset is never added: every tier except
/// `load` runs.
List<String> buildDartTestArguments(List<String> userArgs, {bool all = false}) {
  if (userArgs.isEmpty && !all) return const ['-P', 'fast'];
  final selections = _tagSelections(userArgs);
  final selectsLoad = selections.any(_namesTag('load'));
  return [
    if (!all && selections.isEmpty) ...['-P', 'fast'],
    if (!selectsLoad) ...['-x', 'load'],
    ...userArgs,
  ];
}

bool Function(String) _namesTag(String tag) =>
    (expression) => RegExp(
      r'[A-Za-z0-9_-]+',
    ).allMatches(expression).any((match) => match.group(0) == tag);

List<String> _tagSelections(List<String> args) {
  final selections = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--tags' || '-t':
        if (i + 1 < args.length) selections.add(args[++i]);
      case final arg when arg.startsWith('--tags='):
        selections.add(arg.substring('--tags='.length));
      case final arg when arg.startsWith('-t') && !arg.startsWith('--'):
        selections.add(arg.substring(2));
    }
  }
  return selections;
}

/// `tool test`: runs `dart test` in the test package with tier selection.
///
/// Everything after `test` is handed to [buildDartTestArguments], except the
/// `--all` flag, which selects every tier but `load` (the `test:all` task).
class TestCommand extends Command<int> {
  /// Creates the command.
  TestCommand({
    required this.packageDirectory,
    required this.launch,
    required this.err,
  });

  /// The package whose tests run (`correlia_server` in the repository).
  final Directory packageDirectory;

  /// Starts `dart test`; defaults are provided by [launchDartTest].
  final DartTestLauncher launch;

  /// Receives failures of the command itself.
  final StringSink err;

  @override
  String get name => 'test';

  @override
  String get description =>
      'Run tests by tier: fast by default; other arguments go to dart test.';

  @override
  String get invocation => 'tool test [--all] [dart test arguments]';

  // Every argument belongs to `dart test`, so none is parsed here.
  @override
  ArgParser get argParser => _argParser;
  final _argParser = ArgParser.allowAnything();

  @override
  Future<int> run() async {
    final rest = [...argResults!.rest];
    final all = rest.remove('--all');
    if (!packageDirectory.existsSync()) {
      err.writeln('FAIL no such package directory: ${packageDirectory.path}');
      return 1;
    }
    return launch(buildDartTestArguments(rest, all: all), packageDirectory);
  }
}
