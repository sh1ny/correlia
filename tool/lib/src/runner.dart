import 'dart:io';

import 'package:args/command_runner.dart';

import 'doctor.dart';
import 'generated_command.dart';
import 'pins.dart';
import 'setup.dart';
import 'test_command.dart';
import 'toolchain.dart';

/// Builds the `tool` command runner for the repository at [repoRoot].
CommandRunner<int> buildRunner({
  required Directory repoRoot,
  required StringSink out,
  required StringSink err,
}) {
  return CommandRunner<int>('tool', 'Correlia workspace tooling.')
    ..addCommand(
      DoctorCommand(
        resolver: ProcessToolResolver(repoRoot),
        pins: Pins.load(repoRoot).versions,
        out: out,
        err: err,
      ),
    )
    ..addCommand(
      SetupCommand(
        passwordsFile: File(
          '${repoRoot.path}/correlia_server/config/passwords.yaml',
        ),
        generatePassword: generateSecurePassword,
        out: out,
        err: err,
      ),
    )
    ..addCommand(
      GeneratedCommand(
        repoRoot: repoRoot,
        launch: runProcess,
        dartExecutable: Platform.resolvedExecutable,
        out: out,
        err: err,
      ),
    )
    ..addCommand(
      TestCommand(
        packageDirectory: Directory('${repoRoot.path}/correlia_server'),
        launch: launchDartTest,
        err: err,
      ),
    );
}
