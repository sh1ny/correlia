import 'package:args/args.dart';

/// Exit codes used by the Correlia entry point.
abstract final class ExitCodes {
  /// A subsystem, Serverpod or a shutdown task failed.
  static const int failure = 1;

  /// The command line was rejected before anything was started.
  static const int usage = 2;
}

/// The part of Correlia a process runs.
enum ProcessRole {
  /// The console and HTTP ingress only.
  api,

  /// Background work only.
  worker,

  /// Everything; the default.
  all,
}

/// The outcome of parsing the command line.
sealed class ProcessOptionsResult {
  const ProcessOptionsResult();
}

/// A command line that was rejected, to be reported before exiting.
final class ProcessOptionsError extends ProcessOptionsResult {
  /// Creates a rejection carrying [message].
  const ProcessOptionsError(this.message);

  /// A human-readable explanation naming the offending value.
  final String message;

  /// The process exit code for this rejection.
  int get exitCode => ExitCodes.usage;
}

/// A valid command line: Correlia's role plus the arguments for Serverpod.
///
/// Serverpod's own `CommandLineArgs` logs a warning and falls back to the
/// defaults of every option when any single argument fails to parse, so
/// `--process-role` must never reach it and unknown options must never be
/// forwarded. [parse] therefore validates the whole command line first.
final class ProcessOptions extends ProcessOptionsResult {
  const ProcessOptions._({
    required this.role,
    required this.runMode,
    required this.serverpodArgs,
  });

  /// The role in force.
  final ProcessRole role;

  /// The effective run mode: `--mode`, else `SERVERPOD_RUN_MODE`, else
  /// `development`.
  final String runMode;

  /// The arguments to hand to Serverpod: the command line without
  /// `--process-role`, preceded by `--role monolith` when it names no
  /// Serverpod role.
  ///
  /// Serverpod takes its role from the command line first, then from
  /// `SERVERPOD_SERVER_ROLE`, then from the config file. Passing it on the
  /// command line every time keeps the other two from switching Serverpod to
  /// `maintenance` or `serverless` behind this parser's back.
  final List<String> serverpodArgs;

  static const String _roleOption = 'process-role';

  static const List<String> _runModes = [
    'development',
    'test',
    'staging',
    'production',
  ];

  /// Serverpod's command line options as `name -> abbreviation`.
  ///
  /// A unit test compares this with the declarations in Serverpod's
  /// `CommandLineArgs`, so a Serverpod upgrade that adds an option fails it.
  static const Map<String, String?> serverpodOptions = {
    'mode': 'm',
    'server-id': 'i',
    'logging': 'l',
    'role': 'r',
    'apply-migrations': 'a',
    'apply-repair-migration': 'A',
  };

  static ArgParser _buildParser() => ArgParser()
    ..addOption('mode', abbr: 'm', allowed: _runModes)
    ..addOption('server-id', abbr: 'i')
    ..addOption('logging', abbr: 'l', allowed: ['normal', 'verbose'])
    ..addOption('role', abbr: 'r', allowed: ['monolith'])
    ..addFlag('apply-migrations', abbr: 'a')
    ..addFlag('apply-repair-migration', abbr: 'A')
    ..addOption(
      _roleOption,
      allowed: [for (final role in ProcessRole.values) role.name],
    );

  /// Parses [args], reading `SERVERPOD_RUN_MODE` from [environment].
  static ProcessOptionsResult parse(
    List<String> args, {
    required Map<String, String> environment,
  }) {
    final ArgResults results;
    try {
      results = _buildParser().parse(args);
    } on ArgParserException catch (e) {
      return ProcessOptionsError(_describe(e));
    }

    final roleName = results[_roleOption] as String?;
    final role = roleName == null
        ? ProcessRole.all
        : ProcessRole.values.byName(roleName);

    final runMode =
        results['mode'] as String? ??
        environment['SERVERPOD_RUN_MODE'] ??
        'development';
    if (!_runModes.contains(runMode)) {
      return ProcessOptionsError(
        'Invalid run mode "$runMode" (from SERVERPOD_RUN_MODE). '
        'Valid run modes: ${_runModes.join(', ')}.',
      );
    }

    final forwarded = _withoutRoleOption(args);
    return ProcessOptions._(
      role: role,
      runMode: runMode,
      serverpodArgs: results.wasParsed('role')
          ? forwarded
          : ['--role', 'monolith', ...forwarded],
    );
  }

  static String _describe(ArgParserException e) {
    final message = e.message;
    final roles = ProcessRole.values.map((r) => r.name).join(', ');
    if (message.contains('"--$_roleOption"')) {
      return '$message Valid roles: $roles.';
    }
    if (message.contains('"--role"')) {
      return '$message Correlia always runs Serverpod as monolith; '
          'choose the Correlia role with --$_roleOption ($roles).';
    }
    return message;
  }

  /// Removes `--process-role` and its value, up to a `--` terminator.
  static List<String> _withoutRoleOption(List<String> args) {
    final kept = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--') {
        kept.addAll(args.skip(i));
        break;
      }
      if (arg == '--$_roleOption') {
        i++;
      } else if (!arg.startsWith('--$_roleOption=')) {
        kept.add(arg);
      }
    }
    return kept;
  }
}
