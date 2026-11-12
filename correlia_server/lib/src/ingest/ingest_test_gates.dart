import 'dart:async';
import 'dart:io';

/// File barriers honored only by the test run mode.
final class IngestTestGates {
  const IngestTestGates._({
    this.pipelinePin,
    this.relayAcquire,
    this.relayCompletion,
    this.pluginLaunch,
  });

  /// Rejects activation outside test mode by ignoring test-only environment keys.
  factory IngestTestGates.fromEnvironment(
    String runMode,
    Map<String, String> environment,
  ) => runMode == 'test'
      ? IngestTestGates._(
          pipelinePin: environment['CORRELIA_TEST_PIPELINE_PIN_GATE'],
          relayAcquire: environment['CORRELIA_TEST_RELAY_ACQUIRE_GATE'],
          relayCompletion: _completionFromEnvironment(environment),
          pluginLaunch: _pluginLaunchFromEnvironment(environment),
        )
      : const IngestTestGates._();

  /// The barrier entered immediately after the durable first pin commits.
  final String? pipelinePin;

  /// The barrier entered before relay acquisition.
  final String? relayAcquire;

  /// The compile-time and test-mode guarded plugin completion barrier.
  final RelayCompletionTestGate? relayCompletion;

  /// The compile-time and test-mode guarded plugin launch barrier.
  final PluginLaunchTestGate? pluginLaunch;

  static PluginLaunchTestGate? _pluginLaunchFromEnvironment(
    Map<String, String> environment,
  ) {
    const enabled = bool.fromEnvironment('correlia.testHooks');
    if (!enabled) return null;
    final path = environment['CORRELIA_TEST_PLUGIN_LAUNCH_GATE'];
    return path == null || path.isEmpty ? null : PluginLaunchTestGate(path);
  }

  static RelayCompletionTestGate? _completionFromEnvironment(
    Map<String, String> environment,
  ) {
    const enabled = bool.fromEnvironment('correlia.testHooks');
    if (!enabled) return null;
    final path = environment['CORRELIA_TEST_RELAY_COMPLETION_GATE'];
    if (path == null || path.isEmpty) return null;
    final threshold = int.tryParse(
      environment['CORRELIA_TEST_RELAY_COMPLETION_ACKS'] ?? '1',
    );
    if (threshold == null || threshold < 1) {
      throw FormatException('Invalid test relay completion threshold');
    }
    return RelayCompletionTestGate(path, threshold);
  }
}

/// Holds plugin launch until a test-owned release file appears.
final class PluginLaunchTestGate {
  /// Creates a barrier at [path].
  const PluginLaunchTestGate(this.path);

  /// The release file, with a sibling `.entered` marker.
  final String path;

  /// Waits for release or worker shutdown before launching.
  Future<void> beforeLaunch(Future<void> stopping) =>
      awaitIngestTestGate(path, stopping);
}

/// Holds one plugin completion after a cumulative number of acknowledgements.
final class RelayCompletionTestGate {
  /// Creates a one-shot barrier using a test-owned file.
  RelayCompletionTestGate(this.path, this.threshold);

  /// The release file, with a sibling `.entered` marker.
  final String path;

  /// The minimum cumulative successful acknowledgements before holding.
  final int threshold;
  int _acknowledgements = 0;
  bool _entered = false;

  /// Records a batch's acknowledgements and enters the barrier at its threshold.
  Future<void> beforeComplete(
    int acknowledgedCount,
    Future<void> stopping,
  ) async {
    if (_entered) return;
    _acknowledgements += acknowledgedCount;
    if (_acknowledgements < threshold) return;
    _entered = true;
    await awaitIngestTestGate(path, stopping);
  }
}

/// Waits for a test file using filesystem events, or exits when stopping.
Future<void> awaitIngestTestGate(String path, Future<void> stopping) async {
  final file = File(path);
  final ready = Completer<void>();
  final subscription = file.parent.watch().listen(
    (_) {
      if (!ready.isCompleted && file.existsSync()) ready.complete();
    },
    onError: (Object _, StackTrace stack) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('ingest test gate failed'), stack);
      }
    },
  );
  try {
    if (await file.exists()) return;
    await File('$path.entered').writeAsString('entered');
    // Watch before the final check so publication cannot race registration.
    if (await file.exists()) return;
    await Future.any([ready.future, stopping]);
  } finally {
    await subscription.cancel();
  }
}
