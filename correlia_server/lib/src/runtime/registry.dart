import 'package:serverpod/serverpod.dart';

import '../ingest/ingest_startup.dart';
import '../ingest/ingest_test_gates.dart';
import '../ingest/ingest_workers.dart';
import '../ingest/ingress.dart';
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
  );
  return [
    ingest,
    IngressSubsystem(
      pod: pod,
      bootstrap: () => ingest.bootstrap,
      ready: () => ingest.ready && startup.isReady,
      log: log,
    ),
    IngestWorkers(
      pod: pod,
      startup: ingest,
      runMode: runMode,
      gates: IngestTestGates.fromEnvironment(runMode, environment),
      log: log,
    ),
  ];
}
