import 'dart:io';
import 'dart:isolate';

import 'package:correlia_server/src/runtime/process_options.dart';
import 'package:serverpod/serverpod.dart' show ServerpodConfig;
// ignore: implementation_imports
import 'package:serverpod/src/server/command_line_args.dart';
import 'package:test/test.dart';

ProcessOptions _parsed(List<String> args, {Map<String, String>? env}) {
  final result = ProcessOptions.parse(args, environment: env ?? const {});
  return switch (result) {
    final ProcessOptions options => options,
    final ProcessOptionsError error => fail(
      'unexpected error: ${error.message}',
    ),
  };
}

ProcessOptionsError _rejected(List<String> args) {
  final result = ProcessOptions.parse(args, environment: const {});
  return switch (result) {
    final ProcessOptionsError error => error,
    final ProcessOptions options => fail('unexpected success: ${options.role}'),
  };
}

void main() {
  group('--process-role', () {
    test('defaults to all', () {
      expect(_parsed([]).role, ProcessRole.all);
    });

    for (final role in ProcessRole.values) {
      test('accepts ${role.name}', () {
        expect(_parsed(['--process-role=${role.name}']).role, role);
        expect(_parsed(['--process-role', role.name]).role, role);
      });
    }

    test('an unknown role names the value and the valid roles', () {
      final error = _rejected(['--process-role=frontend']);
      expect(error.message, contains('frontend'));
      expect(
        error.message,
        allOf(contains('api'), contains('worker'), contains('all')),
      );
      expect(error.exitCode, 2);
    });

    test('a missing value is an error', () {
      expect(_rejected(['--process-role']).exitCode, 2);
    });
  });

  group('startup options', () {
    test('production mode and api role both survive parsing', () {
      final options = _parsed(['--mode', 'production', '--process-role=api']);
      expect(options.role, ProcessRole.api);
      expect(options.runMode, 'production');
      expect(options.serverpodArgs, [
        '--role',
        'monolith',
        '--mode',
        'production',
      ]);
    });

    test('Serverpod options pass through unchanged and in order', () {
      final args = [
        '--process-role',
        'worker',
        '-m',
        'staging',
        '--server-id=s1',
        '--logging',
        'verbose',
        '--role=monolith',
        '--apply-migrations',
      ];
      final options = _parsed(args);
      expect(options.serverpodArgs, [
        '-m',
        'staging',
        '--server-id=s1',
        '--logging',
        'verbose',
        '--role=monolith',
        '--apply-migrations',
      ]);
      expect(options.runMode, 'staging');
    });

    test('the run mode falls back to SERVERPOD_RUN_MODE, then development', () {
      expect(_parsed([], env: {'SERVERPOD_RUN_MODE': 'test'}).runMode, 'test');
      expect(_parsed([]).runMode, 'development');
      expect(
        _parsed(
          ['--mode', 'production'],
          env: {'SERVERPOD_RUN_MODE': 'test'},
        ).runMode,
        'production',
      );
    });

    test('an unknown option names it and never falls back to defaults', () {
      final error = _rejected(['--bogus', '--mode', 'production']);
      expect(error.message, contains('--bogus'));
      expect(error.exitCode, 2);
    });

    test('an invalid mode is an error rather than a silent default', () {
      expect(_rejected(['--mode', 'prod']).message, contains('prod'));
    });

    test('a Serverpod role other than monolith is rejected', () {
      for (final role in ['serverless', 'maintenance']) {
        final error = _rejected(['--role=$role']);
        expect(error.message, allOf(contains(role), contains('monolith')));
      }
    });

    test('Serverpod runs as monolith whatever SERVERPOD_SERVER_ROLE or the '
        'config file says', () {
      final overrides = <(Map<String, String>, Map<String, String>)>[
        (const {'SERVERPOD_SERVER_ROLE': 'maintenance'}, const {}),
        (const {'SERVERPOD_SERVER_ROLE': 'serverless'}, const {}),
        (const {}, const {'role': 'maintenance'}),
        (const {}, const {'role': 'serverless'}),
      ];
      for (final args in [
        <String>[],
        ['--process-role=worker'],
        ['--role=monolith'],
        ['-r', 'monolith'],
      ]) {
        final options = _parsed(args);
        for (final (environment, configFile) in overrides) {
          final config = ServerpodConfig.loadFromMap(
            'development',
            null,
            const {},
            configFile,
            environment: environment,
            commandLineArgs: CommandLineArgs(options.serverpodArgs).toMap(),
          );
          expect(
            config.role.name,
            'monolith',
            reason: '$args with $environment and $configFile',
          );
        }
      }
    });

    test('an explicit --role is not repeated', () {
      expect(_parsed(['--role=monolith']).serverpodArgs, ['--role=monolith']);
      expect(_parsed(['-r', 'monolith']).serverpodArgs, ['-r', 'monolith']);
    });

    test('--process-role after -- is left alone', () {
      final options = _parsed(['--', '--process-role=api']);
      expect(options.role, ProcessRole.all);
      expect(options.serverpodArgs, [
        '--role',
        'monolith',
        '--',
        '--process-role=api',
      ]);
    });
  });

  group('Serverpod option list', () {
    test('equals the options in Serverpod CommandLineArgs', () async {
      final uri = await Isolate.resolvePackageUri(
        Uri.parse('package:serverpod/src/server/command_line_args.dart'),
      );
      expect(uri, isNotNull);
      final source = File.fromUri(uri!).readAsStringSync();
      final declaration = RegExp(
        r"\.\.add(?:Option|Flag)\(\s*'([^']+)'(?:\s*,\s*abbr:\s*'([^']+)')?",
      );
      final found = {
        for (final m in declaration.allMatches(source)) m.group(1)!: m.group(2),
      };
      expect(found, isNotEmpty);
      expect(ProcessOptions.serverpodOptions, found);
    });
  });
}
