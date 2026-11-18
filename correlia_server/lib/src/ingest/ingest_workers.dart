import 'dart:async';

import 'package:meta/meta.dart';
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
    this.beforeComponentStop,
  });
  final Serverpod pod;
  final IngestStartup startup;
  final String runMode;
  final IngestTestGates gates;
  final void Function(String) log;

  /// The test-only stop observer/failure hook, ignored outside test mode.
  @visibleForTesting
  final Future<void> Function(String component)? beforeComponentStop;
  final _stopping = Completer<void>();
  Future<void>? _stopFuture;
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
    final resolver = startup.resolver!;
    final pin = gates.pipelinePin;
    final acquire = gates.relayAcquire;
    final supervisor = PluginSupervisor(
      openSession: () => pod.createSession(enableLogging: false),
      resolveSecret: resolver.resolve,
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
      resolveKey: resolver.resolve,
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

  /// Stops each component once; only the first caller receives a stop error.
  ///
  /// Later callers wait for the same stop, then complete without error.
  @override
  Future<void> stop() {
    final stopping = _stopFuture;
    if (stopping != null) {
      return stopping.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    }
    return _stopFuture = _stopOnce();
  }

  Future<void> _stopOnce() async {
    startup.ready = false;
    if (!_stopping.isCompleted) _stopping.complete();
    Object? firstError;
    StackTrace? firstStack;
    Future<void> attempt(String name, Future<void> Function() stop) async {
      try {
        await _stopComponent(name, stop);
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    if (_relay case final relay?) await attempt('relay', relay.stop);
    if (_pipeline case final pipeline?) {
      await attempt('pipeline', pipeline.stop);
    }
    if (_supervisor case final supervisor?) {
      await attempt('supervisor', supervisor.stop);
    }
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
  }

  Future<void> _stopComponent(String name, Future<void> Function() stop) async {
    try {
      if (runMode == 'test') await beforeComponentStop?.call(name);
    } finally {
      await stop();
    }
  }
}
