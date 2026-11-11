import 'package:serverpod/serverpod.dart';

import '../runtime/process_options.dart';
import '../runtime/subsystem.dart';
import 'bootstrap.dart';
import 'config_repository.dart';

/// Publishes ingest configuration after schema readiness and before worker start.
final class IngestStartup extends Subsystem {
  IngestStartup({
    required this.pod,
    required this.role,
    required this.runMode,
    required this.environment,
  });
  final Serverpod pod;
  final ProcessRole role;
  final String runMode;
  final Map<String, String> environment;

  /// The validated process-local startup material, absent when unconfigured.
  IngestBootstrap? bootstrap;

  /// Whether admission may run after startup publication.
  bool ready = false;

  @override
  String get name => 'ingest-bootstrap';
  @override
  Set<ProcessRole> get roles => ProcessRole.values.toSet();

  @override
  Future<void> start() async {
    ready = false;
    final input = await IngestBootstrap.load(environment, runMode: runMode);
    final session = await pod.createSession(enableLogging: false);
    try {
      final repository = IngestConfigRepository(session);
      if (input == null) {
        if (role != ProcessRole.api) {
          await repository.validateWithoutBootstrap();
        }
      } else {
        await repository.publish(
          input,
          requireLiveSecrets: role != ProcessRole.api,
        );
      }
      bootstrap = input;
      ready = true;
    } finally {
      await session.close();
    }
  }

  @override
  Future<void> stop() async {
    ready = false;
  }
}
