import 'dart:async';
import 'dart:io';

import 'package:correlia_server/plugin.dart';
import 'package:correlia_server/src/plugin/plugin_host.dart'
    show PluginHostTestControls, createPluginHostForTesting;

import 'plugin_fixture_modes.dart';
import 'plugin_fixture_suite.dart';
import 'plugin_process_identity.dart';
import 'plugin_process_listing.dart';

/// Facts observed while stopping one real plugin process.
final class PluginShutdownCaseObservation {
  /// Creates an immutable shutdown receipt.
  PluginShutdownCaseObservation({
    required this.lifecycle,
    required this.executable,
    required List<String> arguments,
    required this.pid,
    required this.startTime,
    required this.parentPid,
    required this.initialState,
    required this.socketMode,
    required this.tlsProtocol,
    required this.serverCurve,
    required this.clientCurve,
    required this.forcedStop,
    required this.exitCode,
    required this.elapsedMicroseconds,
    required this.reaped,
    required this.decoySurvived,
  }) : arguments = List.unmodifiable(arguments);

  /// The fixture lifecycle mode.
  final String lifecycle;

  /// The fixture executable path.
  final String executable;

  /// The exact fixture arguments.
  final List<String> arguments;

  /// The plugin process ID.
  final int pid;

  /// The Linux process start tick.
  final int startTime;

  /// The observed parent process ID.
  final int parentPid;

  /// The observed process state before shutdown.
  final String initialState;

  /// The observed Unix socket permission bits.
  final int socketMode;

  /// The negotiated TLS protocol, or null for explicit plaintext.
  final String? tlsProtocol;

  /// The observed server certificate curve.
  final String? serverCurve;

  /// The observed client certificate curve.
  final String? clientCurve;

  /// Whether the host recorded a forced stop.
  final bool forcedStop;

  /// The actual child exit status.
  final int exitCode;

  /// The elapsed time from the stop request to its completion.
  final int elapsedMicroseconds;

  /// Whether the captured child identity was absent after its exit receipt.
  final bool reaped;

  /// Whether the exact decoy identity remained live after shutdown.
  final bool decoySurvived;

  /// Serializes the observed facts at the evidence boundary.
  Map<String, Object?> toJson() => {
    'lifecycle': lifecycle,
    'executable': executable,
    'arguments': arguments,
    'pid': pid,
    'startTime': startTime,
    'parentPid': parentPid,
    'initialState': initialState,
    'socketMode': socketMode,
    'tlsProtocol': tlsProtocol,
    'serverCurve': serverCurve,
    'clientCurve': clientCurve,
    'forcedStop': forcedStop,
    'exitCode': exitCode,
    'elapsedMicroseconds': elapsedMicroseconds,
    'reaped': reaped,
    'decoySurvived': decoySurvived,
    'healthAndProtectedProbeSucceeded': true,
  };
}

/// Actual normal and forced shutdown receipts for one security mode.
final class PluginShutdownObservation {
  /// Creates an immutable combined receipt.
  const PluginShutdownObservation({
    required this.securityMode,
    required this.decoyPid,
    required this.decoyStartTime,
    required this.normal,
    required this.uncooperative,
  });

  /// The explicitly selected transport-security mode.
  final String securityMode;

  /// The unrelated decoy process ID.
  final int decoyPid;

  /// The decoy's Linux start tick.
  final int decoyStartTime;

  /// The stock cooperative controller shutdown receipt.
  final PluginShutdownCaseObservation normal;

  /// The uncooperative forced-shutdown receipt.
  final PluginShutdownCaseObservation uncooperative;

  /// Serializes the observed facts at the evidence boundary.
  Map<String, Object?> toJson() => {
    'securityMode': securityMode,
    'decoyPid': decoyPid,
    'decoyStartTime': decoyStartTime,
    'normal': normal.toJson(),
    'uncooperative': uncooperative.toJson(),
  };
}

/// Observes and validates stock and forced shutdown of real plugin children.
///
/// Plaintext is available only when explicitly requested for diagnostics.
Future<PluginShutdownObservation> observePluginShutdown(
  PluginFixtureSuite suite, {
  bool diagnosticPlaintext = false,
}) async {
  if (!Platform.isLinux) {
    throw UnsupportedError('Linux process receipts required');
  }
  final build = await suite.build();
  final executable = build.binaries[PluginFixtureBinary.plainStock]!.path;
  final credentials = await suite.createCredentials();
  final identity = PluginClientIdentity(
    certificatePem: await credentials.certificate.readAsBytes(),
    privateKeyPem: await credentials.privateKey.readAsBytes(),
  );
  final scratch = await suite.scratchDirectory.createTemp('shutdown-');
  Process? decoy;
  PluginProcessIdentity? decoyIdentity;
  try {
    decoy = await Process.start('/bin/cat', const []);
    final decoyOut = decoy.stdout.drain<void>();
    final decoyErr = decoy.stderr.drain<void>();
    final capturedDecoy = PluginProcessIdentity.read(decoy.pid);
    if (capturedDecoy == null) {
      throw StateError('Cannot capture decoy PID ${decoy.pid} start identity');
    }
    decoyIdentity = capturedDecoy;
    Future<PluginShutdownCaseObservation> runCase(
      PluginFixtureLifecycleMode lifecycle,
    ) async {
      Process? process;
      PluginProcessIdentity? processIdentity;
      Future<void>? stopping;
      final arguments = PluginFixtureArguments(
        journalPath: '${scratch.path}/${lifecycle.argument}.jsonl',
        lifecycleMode: lifecycle,
        tlsMode: diagnosticPlaintext
            ? PluginFixtureTlsMode.plaintext
            : PluginFixtureTlsMode.stock,
      ).toArguments();
      final host = createPluginHostForTesting(
        PluginHostConfig(
          executable: executable,
          arguments: arguments,
          identity: identity,
        ),
        controls: PluginHostTestControls(
          diagnosticPlaintext: diagnosticPlaintext,
          processStarter: (command, argv, environment) async {
            final child = await Process.start(
              command,
              argv,
              environment: environment,
              includeParentEnvironment: false,
            );
            process = child;
            processIdentity = PluginProcessIdentity.read(child.pid);
            if (processIdentity == null) {
              child.kill(ProcessSignal.sigkill);
              await child.stdin.close();
              await Future.wait([
                child.stdout.drain<void>(),
                child.stderr.drain<void>(),
              ]);
              await child.exitCode.timeout(const Duration(seconds: 5));
              throw StateError(
                'Cannot capture plugin PID ${child.pid} start identity',
              );
            }
            return child;
          },
        ),
      );
      try {
        await host.start();
        await host.probe();
        final child = process!;
        final captured = processIdentity!;
        final snapshot = readPluginProcessSnapshot(child.pid);
        final decoyBefore = readPluginProcessSnapshot(capturedDecoy.pid);
        final handshake = host.evidence!;
        final tls = host.tlsEvidence;
        if (host.childPid != captured.pid ||
            snapshot == null ||
            snapshot.identity != captured ||
            snapshot.parentPid != pid ||
            snapshot.state == 'Z' ||
            decoyBefore == null ||
            decoyBefore.identity != capturedDecoy ||
            decoyBefore.state == 'Z' ||
            handshake.socketMode != 0x180 ||
            (diagnosticPlaintext
                ? tls != null
                : tls == null ||
                      tls.protocol != 'TLSv1.3' ||
                      !const {
                        'P-521',
                        'secp521r1',
                      }.contains(tls.serverCertificateCurve) ||
                      !const {
                        'P-521',
                        'secp521r1',
                      }.contains(tls.clientCertificateCurve) ||
                      handshake.certificate == null)) {
          throw StateError(
            'Invalid pre-stop receipts: plugin=$snapshot decoy=$decoyBefore '
            'socket=${handshake.socketMode} tls=${tls?.protocol}',
          );
        }
        final watch = Stopwatch()..start();
        stopping = host.stop();
        await stopping.timeout(const Duration(seconds: 7));
        final code = await child.exitCode.timeout(const Duration(seconds: 5));
        watch.stop();
        final remaining = PluginProcessIdentity.read(captured.pid);
        final after = readPluginProcessSnapshot(capturedDecoy.pid);
        final reaped = remaining == null || remaining != captured;
        final survived =
            after != null &&
            after.identity == capturedDecoy &&
            after.state != 'Z';
        final forced = host.forcedStop;
        final expectedForce =
            lifecycle == PluginFixtureLifecycleMode.uncooperative;
        if (!reaped ||
            !survived ||
            forced != expectedForce ||
            (expectedForce
                ? code != -ProcessSignal.sigkill.signalNumber
                : code != 0) ||
            watch.elapsed > const Duration(seconds: 7)) {
          throw StateError(
            'Shutdown failed: lifecycle=${lifecycle.argument}, pid=${captured.pid}, '
            'start=${captured.startTime}, exit=$code, forced=$forced, '
            'elapsed=${watch.elapsed}, reaped=$reaped, decoySurvived=$survived',
          );
        }
        return PluginShutdownCaseObservation(
          lifecycle: lifecycle.argument,
          executable: executable,
          arguments: arguments,
          pid: captured.pid,
          startTime: captured.startTime,
          parentPid: snapshot.parentPid,
          initialState: snapshot.state,
          socketMode: handshake.socketMode,
          tlsProtocol: tls?.protocol,
          serverCurve: tls?.serverCertificateCurve,
          clientCurve: tls?.clientCertificateCurve,
          forcedStop: forced,
          exitCode: code,
          elapsedMicroseconds: watch.elapsedMicroseconds,
          reaped: reaped,
          decoySurvived: survived,
        );
      } finally {
        final child = process;
        final captured = processIdentity;
        if (child != null &&
            captured != null &&
            captured.matchesCurrentProcess()) {
          captured.signalIfExact(ProcessSignal.sigkill);
          await child.exitCode.timeout(const Duration(seconds: 5));
        }
        if (stopping != null) {
          await stopping.timeout(const Duration(seconds: 35));
        } else {
          await host.stop().timeout(const Duration(seconds: 35));
        }
      }
    }

    try {
      final normal = await runCase(PluginFixtureLifecycleMode.cooperative);
      final uncooperative = await runCase(
        PluginFixtureLifecycleMode.uncooperative,
      );
      return PluginShutdownObservation(
        securityMode: diagnosticPlaintext
            ? 'diagnostic-plaintext'
            : 'native-authenticated-tls',
        decoyPid: capturedDecoy.pid,
        decoyStartTime: capturedDecoy.startTime,
        normal: normal,
        uncooperative: uncooperative,
      );
    } finally {
      await decoy.stdin.close();
      await decoy.exitCode.timeout(const Duration(seconds: 5));
      await Future.wait([decoyOut, decoyErr]);
    }
  } finally {
    if (decoy != null &&
        decoyIdentity != null &&
        decoyIdentity.matchesCurrentProcess()) {
      decoyIdentity.signalIfExact(ProcessSignal.sigkill);
      await decoy.exitCode.timeout(const Duration(seconds: 5));
    } else if (decoy != null && decoyIdentity == null) {
      decoy.kill(ProcessSignal.sigkill);
      await decoy.exitCode.timeout(const Duration(seconds: 5));
    }
    if (await scratch.exists()) await scratch.delete(recursive: true);
  }
}
