import 'dart:io';

import 'package:serverpod/serverpod.dart';

import '../secrets/key_file.dart';
import '../secrets/secret_store.dart';
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
    this.log = _logToStderr,
  });
  final Serverpod pod;
  final ProcessRole role;
  final String runMode;
  final Map<String, String> environment;
  final void Function(String) log;

  /// The validated process-local startup material, absent when unconfigured.
  IngestBootstrap? bootstrap;

  /// The process-local resolver shared by runtime consumers.
  SecretResolver? resolver;

  /// The lookup limit shared by ingress and the secret store.
  final lookupGate = SecretLookupGate();

  /// Whether admission may run after startup publication.
  bool ready = false;

  @override
  String get name => 'ingest-bootstrap';
  @override
  Set<ProcessRole> get roles => ProcessRole.values.toSet();

  @override
  Future<void> start() async {
    ready = false;
    final keyPath = environment['CORRELIA_SECRET_KEY_FILE'];
    final configured = environment['CORRELIA_INGEST_CONFIG'] != null;
    final store = configured
        ? SecretStore(
            await loadSecretKey(
              keyPath ??
                  (throw const BootstrapError(
                    'secret_key',
                    r'$',
                    'regular_file',
                  )),
            ),
          )
        : null;
    final session = await pod.createSession(enableLogging: false);
    try {
      final repository = IngestConfigRepository(session, secretStore: store);
      final input = await IngestBootstrap.load(
        environment,
        runMode: runMode,
        requirePluginDirectory: role != ProcessRole.api,
        publish: store == null
            ? null
            : (config, secrets) => repository.publishConfig(
                config,
                secrets,
                runMode: runMode,
                requireLiveSecrets: role != ProcessRole.api,
              ),
      );
      if (input == null && role != ProcessRole.api) {
        await repository.validateWithoutBootstrap();
      }
      resolver = store == null
          ? null
          : SecretResolver(
              store: store,
              openSession: () => pod.createSession(enableLogging: false),
              log: log,
              gate: lookupGate,
            );
      if (input != null) {
        await resolver!.prefill(session, [
          for (final source in input.sources)
            for (final credential in source.credentials) credential.reference,
          for (final output in input.outputs) ...output.commitments.keys,
        ]);
      }
      bootstrap = input?.withoutImport();
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

void _logToStderr(String message) => stderr.writeln(message);
