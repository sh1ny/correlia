import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/plugin.dart';
import 'package:correlia_server/src/plugin/plugin_host.dart';

import '../../support/plugin_fixture_modes.dart';
import '../../support/plugin_process_identity.dart';

Future<void> main(List<String> args) async {
  final executable = args[0];
  final attemptDirectory = Directory(args[1]);
  final credentials = PluginClientIdentity(
    certificatePem: await File(args[2]).readAsBytes(),
    privateKeyPem: await File(args[3]).readAsBytes(),
  );
  final diagnostic = args[4] == 'diagnostic-plaintext';
  final fixtureArguments = PluginFixtureArguments(
    journalPath: '${attemptDirectory.path}/journal.jsonl',
    eofMarkerPath: '${attemptDirectory.path}/stdin-eof.marker',
    tlsMode: diagnostic
        ? PluginFixtureTlsMode.plaintext
        : PluginFixtureTlsMode.required,
  ).toArguments();
  Future<void> send(Map<String, Object?> value) async {
    stdout.writeln(jsonEncode(value));
    await stdout.flush();
  }

  final host = createPluginHostForTesting(
    PluginHostConfig(
      executable: executable,
      arguments: fixtureArguments,
      identity: credentials,
      timeout: const Duration(seconds: 10),
    ),
    controls: PluginHostTestControls(
      diagnosticPlaintext: diagnostic,
      directoryStarter: () async => Directory('${attemptDirectory.path}/host'),
      processStarter: (executable, arguments, environment) async {
        final process = await Process.start(
          executable,
          arguments,
          environment: environment,
          includeParentEnvironment: false,
        );
        final identity = PluginProcessIdentity.read(process.pid);
        if (identity == null) {
          throw StateError('cannot identify spawned plugin');
        }
        File('${attemptDirectory.path}/spawned.json').writeAsStringSync(
          jsonEncode({'pid': identity.pid, 'startTime': identity.startTime}),
          flush: true,
        );
        await send({
          'event': 'spawned',
          'hostPid': pid,
          'pluginPid': process.pid,
        });
        return process;
      },
    ),
  );
  try {
    await host.start();
    await host.probe();
    await send({
      'event': 'ready',
      'hostPid': pid,
      'pluginPid': host.childPid,
      'socketMode': host.evidence!.socketMode,
      'socketUid': host.evidence!.socketUid,
      'tlsProtocol': host.tlsEvidence?.protocol,
    });
    await stdin.drain<void>();
  } finally {
    await host.stop();
  }
}
