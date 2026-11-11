@Tags(['plugin'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/plugin_fixture_suite.dart';
import 'support/plugin_host_death_observer.dart';
import 'support/plugin_shutdown_observer.dart';

void main() {
  late PluginFixtureSuite suite;

  setUpAll(() async {
    suite = PluginFixtureSuite.create();
    await suite.build();
  });
  tearDownAll(() async => suite.dispose());

  test('host SIGKILL yields verified stdin-EOF child exit', () async {
    final observation = await observePluginHostDeath(suite);
    expect(observation.marker, 'stdin-eof\n');
    expect(observation.pluginParentPid, observation.host.pid);
    expect(observation.pluginState, anyOf('absent', 'Z'));
    expect(observation.hostExitCode, -ProcessSignal.sigkill.signalNumber);
    expect(observation.tlsProtocol, 'TLSv1.3');
    expect(observation.socketMode, 0x180);
    expect(observation.elapsed, lessThanOrEqualTo(const Duration(seconds: 5)));
    expect(observation.decoyAliveAfter, isTrue);
    stdout.writeln(jsonEncode(observation.toJson()));
  }, skip: Platform.isLinux ? false : 'Linux process receipts required');

  test('uncooperative child is forcibly stopped and reaped', () async {
    final observation = await observePluginShutdown(suite);
    expect(observation.normal.forcedStop, isFalse);
    expect(observation.normal.exitCode, 0);
    expect(observation.normal.reaped, isTrue);
    expect(observation.uncooperative.forcedStop, isTrue);
    expect(
      observation.uncooperative.exitCode,
      -ProcessSignal.sigkill.signalNumber,
    );
    expect(observation.uncooperative.reaped, isTrue);
    expect(observation.uncooperative.decoySurvived, isTrue);
    expect(
      observation.uncooperative.elapsedMicroseconds,
      lessThanOrEqualTo(7 * Duration.microsecondsPerSecond),
    );
    stdout.writeln(jsonEncode(observation.toJson()));
  }, skip: Platform.isLinux ? false : 'Linux process receipts required');
}
