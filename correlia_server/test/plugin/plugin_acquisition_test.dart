@Tags(['plugin'])
library;

import 'dart:async';
import 'dart:io';

import 'package:correlia_server/src/plugin/plugin_host.dart';
import 'package:correlia_server/src/plugin/plugin_rpc_connection.dart';
import 'package:test/test.dart';

void main() {
  PluginHostConfig config() => PluginHostConfig(
    executable: '/bin/true',
    arguments: [],
    identity: PluginClientIdentity(certificatePem: [], privateKeyPem: []),
    timeout: const Duration(milliseconds: 200),
  );

  test(
    'late process result is killed and reaped after the startup deadline',
    () async {
      final started = Completer<Process>();
      final release = Completer<void>();
      final host = createPluginHostForTesting(
        config(),
        controls: PluginHostTestControls(
          processStarter: (executable, arguments, environment) async {
            final process = await Process.start('/bin/sh', [
              '-c',
              'exec /bin/cat',
            ]);
            started.complete(process);
            await release.future;
            return process;
          },
        ),
      );
      final starting = host.start();
      final process = await started.future;
      try {
        await expectLater(starting, throwsA(isA<PluginStartupException>()));
        expect(await File('/proc/${process.pid}/stat').exists(), isTrue);
        release.complete();
        await process.exitCode.timeout(const Duration(seconds: 5));
        expect(await File('/proc/${process.pid}/stat').exists(), isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await host.stop();
      }
    },
  );

  test(
    'late private directory result is removed after the startup deadline',
    () async {
      final directory = await Directory.systemTemp.createTemp('correlia-late-');
      final release = Completer<void>();
      final entered = Completer<void>();
      final host = createPluginHostForTesting(
        config(),
        controls: PluginHostTestControls(
          directoryStarter: () async {
            entered.complete();
            await release.future;
            return directory;
          },
        ),
      );
      final starting = host.start();
      await entered.future;
      StreamSubscription<FileSystemEvent>? subscription;
      try {
        await expectLater(starting, throwsA(isA<PluginStartupException>()));
        expect(await directory.exists(), isTrue);
        final deleted = Completer<void>();
        subscription = directory.parent
            .watch(events: FileSystemEvent.delete)
            .listen((event) {
              if (event.path == directory.path && !deleted.isCompleted) {
                deleted.complete();
              }
            });
        release.complete();
        await deleted.future.timeout(const Duration(seconds: 5));
        expect(await directory.exists(), isFalse);
      } finally {
        await subscription?.cancel();
        if (!release.isCompleted) release.complete();
        if (await directory.exists()) await directory.delete(recursive: true);
        await host.stop();
      }
    },
  );
}
