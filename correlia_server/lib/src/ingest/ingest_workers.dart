import 'dart:async';

import 'package:serverpod/serverpod.dart';

import '../output/relay_subsystem.dart';
import '../pipeline/pipeline.dart';
import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import 'ingest_startup.dart';
import 'ingest_test_gates.dart';

/// Starts durable processing only after a validated bootstrap is available.
final class IngestWorkers extends Subsystem {
  IngestWorkers({
    required this.pod,
    required this.startup,
    required this.runMode,
    required this.gates,
    required this.log,
  });
  final Serverpod pod;
  final IngestStartup startup;
  final String runMode;
  final IngestTestGates gates;
  final void Function(String) log;
  final _stopping = Completer<void>();
  PipelineSubsystem? _pipeline;
  RelaySubsystem? _relay;

  @override
  String get name => 'ingest-workers';
  @override
  Set<ProcessRole> get roles => const {ProcessRole.worker, ProcessRole.all};

  @override
  Future<void> start() async {
    final bootstrap = startup.bootstrap;
    // Unconfigured workspaces intentionally have no polling loops.
    if (bootstrap == null) return;
    final pin = gates.pipelinePin;
    final acquire = gates.relayAcquire;
    final pipeline = PipelineSubsystem(
      openSession: () => pod.createSession(enableLogging: false),
      afterPin: pin == null
          ? null
          : () => awaitIngestTestGate(pin, _stopping.future),
    );
    final relay = RelaySubsystem(
      pod: pod,
      bootstrap: bootstrap,
      runMode: runMode,
      beforeAcquire: acquire == null
          ? null
          : () => awaitIngestTestGate(acquire, _stopping.future),
      onUnavailable: (output, reference) => log(
        'output-relay output=$output signing_reference=$reference unavailable',
      ),
    );
    await pipeline.start();
    _pipeline = pipeline;
    try {
      await relay.start();
      _relay = relay;
    } catch (_) {
      if (!_stopping.isCompleted) _stopping.complete();
      await pipeline.stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    startup.ready = false;
    if (!_stopping.isCompleted) _stopping.complete();
    // Signal both owners before awaiting either; neither may acquire new work.
    await Future.wait([
      if (_relay case final relay?) relay.stop(),
      if (_pipeline case final pipeline?) pipeline.stop(),
    ]);
  }
}
