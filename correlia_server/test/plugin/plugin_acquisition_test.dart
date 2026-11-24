@Tags(['plugin'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';

import 'package:correlia_server/src/plugin/plugin_host.dart';
import 'package:correlia_server/src/plugin/plugin_rpc_connection.dart';
import 'package:test/test.dart';

/// Captures the watchdog only after the fixture has entered its acquisition.
final class _AcquisitionDeadline implements Timer {
  var armed = false;
  void Function()? _callback;

  Future<void> start(PluginHost host) => runZoned(
    host.start,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, delay, callback) {
        if (!armed) return parent.createTimer(zone, delay, callback);
        armed = false;
        _callback = callback;
        return this;
      },
    ),
  );

  void expire() {
    final callback = _callback!;
    cancel();
    callback();
  }

  @override
  void cancel() => _callback = null;

  @override
  bool get isActive => _callback != null;

  @override
  int get tick => isActive ? 0 : 1;
}

void main() {
  PluginHostConfig config() => PluginHostConfig(
    executable: '/bin/true',
    arguments: [],
    identity: PluginClientIdentity(certificatePem: [], privateKeyPem: []),
    timeout: const Duration(minutes: 3),
  );

  test(
    'late process result is killed and reaped after the startup deadline',
    () async {
      final started = Completer<Process>();
      final release = Completer<void>();
      final deadline = _AcquisitionDeadline();
      final host = createPluginHostForTesting(
        config(),
        controls: PluginHostTestControls(
          processStarter: (executable, arguments, environment) async {
            final pending = Process.start('/bin/sh', [
              '-c',
              'exec /bin/cat',
            ]);
            deadline.armed = true;
            final process = await pending;
            started.complete(process);
            await release.future;
            return process;
          },
        ),
      );
      final failed = expectLater(
        deadline.start(host),
        throwsA(isA<PluginStartupException>()),
      )..ignore();
      final process = await started.future;
      try {
        deadline.expire();
        await failed;
        expect(await File('/proc/${process.pid}/stat').exists(), isTrue);
        release.complete();
        await process.exitCode;
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
      final deadline = _AcquisitionDeadline();
      final host = createPluginHostForTesting(
        config(),
        controls: PluginHostTestControls(
          directoryStarter: () async {
            deadline.armed = true;
            entered.complete();
            await release.future;
            return directory;
          },
        ),
      );
      final failed = expectLater(
        deadline.start(host),
        throwsA(isA<PluginStartupException>()),
      )..ignore();
      await entered.future;
      StreamSubscription<FileSystemEvent>? subscription;
      try {
        deadline.expire();
        await failed;
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
        await deleted.future;
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
