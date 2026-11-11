import 'dart:async';
import 'dart:io';

/// File barriers honored only by the test run mode.
final class IngestTestGates {
  const IngestTestGates._({this.pipelinePin, this.relayAcquire});

  /// Rejects activation outside test mode by ignoring test-only environment keys.
  factory IngestTestGates.fromEnvironment(
    String runMode,
    Map<String, String> environment,
  ) => runMode == 'test'
      ? IngestTestGates._(
          pipelinePin: environment['CORRELIA_TEST_PIPELINE_PIN_GATE'],
          relayAcquire: environment['CORRELIA_TEST_RELAY_ACQUIRE_GATE'],
        )
      : const IngestTestGates._();

  /// The barrier entered immediately after the durable first pin commits.
  final String? pipelinePin;

  /// The barrier entered before relay acquisition.
  final String? relayAcquire;
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
