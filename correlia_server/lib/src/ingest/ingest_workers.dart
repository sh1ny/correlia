import 'dart:async';

import 'package:serverpod/serverpod.dart';

import '../output/relay_subsystem.dart';
import '../pipeline/pipeline.dart';
import '../plugin/plugin_supervisor.dart';
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
  PluginSupervisor? _supervisor;

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
    final supervisor = PluginSupervisor(
      openSession: () => pod.createSession(enableLogging: false),
      bootstrap: bootstrap,
      pluginDirectory: startup.environment['CORRELIA_PLUGIN_DIR'] ?? '',
      hostInstanceId: const Uuid().v4(),
      beforeLaunch: gates.pluginLaunch?.beforeLaunch,
      log: log,
    );
    final pipeline = PipelineSubsystem(
      openSession: () => pod.createSession(enableLogging: false),
      log: log,
      afterPin: pin == null
          ? null
          : () => awaitIngestTestGate(pin, _stopping.future),
    );
    final relay = RelaySubsystem(
      pod: pod,
      bootstrap: bootstrap,
      runMode: runMode,
      pluginRouter: supervisor,
      beforeAcquire: acquire == null
          ? null
          : () => awaitIngestTestGate(acquire, _stopping.future),
      beforePluginComplete: gates.relayCompletion == null
          ? null
          : (count) =>
                gates.relayCompletion!.beforeComplete(count, _stopping.future),
      onUnavailable: (output, reference) => log(
        'output-relay output=$output signing_reference=$reference unavailable',
      ),
    );
    await supervisor.start();
    _supervisor = supervisor;
    try {
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
    } catch (_) {
      await supervisor.stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    startup.ready = false;
    if (!_stopping.isCompleted) _stopping.complete();
    try {
      if (_relay case final relay?) await relay.stop();
    } finally {
      try {
        if (_pipeline case final pipeline?) await pipeline.stop();
      } finally {
        if (_supervisor case final supervisor?) await supervisor.stop();
      }
    }
  }
}
