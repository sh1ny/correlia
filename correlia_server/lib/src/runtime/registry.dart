import 'dart:async';
import 'dart:io';

import 'package:serverpod/serverpod.dart';

import '../feed/feed_runtime.dart';
import '../feed/feed_watermark_subsystem.dart';
import '../ingest/ingest_startup.dart';
import '../ingest/ingest_test_gates.dart';
import '../ingest/ingest_workers.dart';
import '../ingest/ingress.dart';
import '../pipeline/maintenance.dart';
import '../pipeline/operator_runtime.dart';
import 'process_options.dart';
import 'role_runtime.dart';
import 'startup_state.dart';
import 'subsystem.dart';

/// Builds application subsystems in startup order, before the console fallback.
List<Subsystem> buildSubsystemRegistry({
  required Serverpod pod,
  required ProcessRole role,
  required String runMode,
  required Map<String, String> environment,
  required StartupState startup,
  required LogSink log,
}) {
  final ingest = IngestStartup(
    pod: pod,
    role: role,
    runMode: runMode,
    environment: environment,
    log: log,
  );
  final watermark = FeedWatermarkSubsystem(
    openSession: () => pod.createSession(enableLogging: false),
    log: log,
  );
  FeedRuntime.role = role;
  FeedRuntime.watermark = role == ProcessRole.worker ? null : watermark;
  final maintenanceGate =
      runMode == 'test' && const bool.fromEnvironment('correlia.testHooks')
      ? environment['CORRELIA_TEST_MAINTENANCE_GATE']
      : null;
  return [
    ingest,
    OperatorRuntime(
      pod,
      path: environment['CORRELIA_DEAD_LETTER_CREDENTIALS_FILE'],
      ready: () => startup.isReady,
      secretStore: () => ingest.secretStore,
    ),
    IngressSubsystem(
      pod: pod,
      bootstrap: () => ingest.bootstrap,
      ready: () => ingest.ready && startup.isReady,
      log: log,
      lookupGate: ingest.lookupGate,
      secretResolver: (reference, commitment) =>
          ingest.resolver!.resolve(reference, commitment),
    ),
    IngestWorkers(
      pod: pod,
      startup: ingest,
      runMode: runMode,
      gates: IngestTestGates.fromEnvironment(runMode, environment),
      log: log,
    ),
    PipelineMaintenance(
      openSession: () => pod.createSession(enableLogging: false),
      log: log,
      beforeCommitForTest: maintenanceGate == null
          ? null
          : (lane) async {
              if (lane != 'expiry') return;
              log('test maintenance: expiry gate');
              await awaitIngestTestGate(
                maintenanceGate,
                Completer<void>().future,
              );
              if (await File(maintenanceGate).readAsString() == 'fail') {
                throw StateError('maintenance fixture failure');
              }
            },
    ),
    watermark,
  ];
}
