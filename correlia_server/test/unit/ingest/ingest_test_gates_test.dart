import 'dart:async';
import 'dart:io';

import 'package:correlia_server/src/ingest/ingest_test_gates.dart';
import 'package:test/test.dart';

void main() {
  test('production cannot activate ingest crash gates', () {
    final gates = IngestTestGates.fromEnvironment('production', {
      'CORRELIA_TEST_PIPELINE_PIN_GATE': '/unused/pin',
      'CORRELIA_TEST_RELAY_ACQUIRE_GATE': '/unused/relay',
      'CORRELIA_TEST_RELAY_COMPLETION_GATE': '/unused/complete',
    });
    expect(gates.pipelinePin, isNull);
    expect(gates.relayAcquire, isNull);
    expect(gates.relayCompletion, isNull);
  });
  test('test run mode accepts independently named gates', () {
    final gates = IngestTestGates.fromEnvironment('test', {
      'CORRELIA_TEST_PIPELINE_PIN_GATE': '/unused/pin',
      'CORRELIA_TEST_RELAY_ACQUIRE_GATE': '/unused/relay',
    });
    expect(gates.pipelinePin, '/unused/pin');
    expect(gates.relayAcquire, '/unused/relay');
  });
  test('completion gate requires compile flag and test mode', () {
    const compiled = bool.fromEnvironment('correlia.testHooks');
    const environment = {
      'CORRELIA_TEST_RELAY_COMPLETION_GATE': '/unused/complete',
      'CORRELIA_TEST_RELAY_COMPLETION_ACKS': '100',
      'CORRELIA_TEST_PLUGIN_LAUNCH_GATE': '/unused/launch',
    };
    expect(
      IngestTestGates.fromEnvironment(
        'production',
        environment,
      ).relayCompletion,
      isNull,
    );
    expect(
      IngestTestGates.fromEnvironment('production', environment).pluginLaunch,
      isNull,
    );
    final gate = IngestTestGates.fromEnvironment(
      'test',
      environment,
    ).relayCompletion;
    if (compiled) {
      expect(gate, isNotNull);
      expect(gate!.threshold, 100);
      expect(
        IngestTestGates.fromEnvironment('test', environment).pluginLaunch,
        isNotNull,
      );
    } else {
      expect(gate, isNull);
      expect(
        IngestTestGates.fromEnvironment('test', environment).pluginLaunch,
        isNull,
      );
    }
  });

  test(
    'completion barrier holds once after the cumulative threshold',
    () async {
      final directory = await Directory.systemTemp.createTemp('correlia-gate-');
      final stopping = Completer<void>();
      final path = '${directory.path}/release';
      final marker = File('$path.entered');
      final entered = Completer<void>();
      final subscription = directory.watch().listen((_) {
        if (marker.existsSync() && !entered.isCompleted) entered.complete();
      });
      try {
        final gate = RelayCompletionTestGate(path, 100);
        await gate.beforeComplete(64, stopping.future);
        expect(marker.existsSync(), isFalse);
        var completed = false;
        final held = gate.beforeComplete(64, stopping.future).then((_) {
          completed = true;
        });
        if (!marker.existsSync()) {
          await entered.future.timeout(const Duration(seconds: 5));
        }
        expect(completed, isFalse);
        await File(path).writeAsString('release');
        await held.timeout(const Duration(seconds: 5));
        expect(completed, isTrue);
        await gate.beforeComplete(64, stopping.future);
      } finally {
        if (!stopping.isCompleted) stopping.complete();
        await subscription.cancel();
        await directory.delete(recursive: true);
      }
    },
  );
}
