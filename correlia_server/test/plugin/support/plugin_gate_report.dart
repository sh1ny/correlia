import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/plugin.dart';
import 'package:correlia_server/src/plugin/plugin_host.dart'
    show PluginHostTestControls, PluginLaunchUmask, createPluginHostForTesting;
import 'package:correlia_server/src/plugin/plugin_tls.dart';

import 'plugin_delivery_observer.dart';
import 'plugin_fixture_support.dart';
import 'plugin_host_death_observer.dart';
import 'plugin_shutdown_observer.dart';

/// The outcome of an independently observed criterion.
enum PluginGateStatus { passed, failed, notRun }

/// A bounded record of one actual criterion observation.
final class PluginGateCriterion {
  /// Creates a criterion record.
  PluginGateCriterion({
    required this.status,
    required this.securityMode,
    required List<List<String>> commands,
    required Map<String, Object?> evidence,
    this.failure,
  }) : commands = List.unmodifiable(commands.map(List<String>.unmodifiable)),
       evidence = Map.unmodifiable(evidence);

  /// The independently observed outcome.
  final PluginGateStatus status;

  /// The explicitly selected security profile.
  final String securityMode;

  /// Commands actually executed for this observation.
  final List<List<String>> commands;

  /// Observed facts, without private credentials.
  final Map<String, Object?> evidence;

  /// The original failure description, absent for a passing result.
  final String? failure;

  /// Serializes the observed result without credentials.
  Map<String, Object?> toJson() => {
    'status': status.name,
    'security_mode': securityMode,
    'commands': commands,
    'evidence': evidence,
    'failure': failure,
  };
}

/// Four runtime observations, separate from pending owner decisions.
final class PluginGateReport {
  /// Creates a report from independent observations.
  PluginGateReport(this.criteria, this.versions);
  final List<PluginGateCriterion> criteria;
  final Map<String, Object?> versions;

  /// Whether all four runtime criteria passed; this does not authorize adoption.
  bool get runtimePassed =>
      criteria.length == 4 &&
      criteria.every(
        (c) =>
            c.status == PluginGateStatus.passed &&
            c.securityMode != 'diagnostic-plaintext',
      );

  /// Serializes runtime and owner-gate evidence.
  Map<String, Object?> toJson() => {
    'criteria': criteria.map((c) => c.toJson()).toList(),
    'versions': versions,
    'runtime_passed': runtimePassed,
    'owner_decisions': {
      'task': '5.5',
      'transport': 'pending',
      'custom_connector_interpretation': 'pending',
      'native_dependency': 'pending',
    },
    'historical_builtin_dart_tls': {
      'status': 'failed historically, not rerun',
      'source':
          'openspec/changes/plugin-host-spike/evidence/handshake-and-mtls.md',
    },
    'plain_stock_vs_watched':
        'plain stock has no proven stdin-EOF guarantee; lifecycle uses the watched fixture',
  };
}

/// Runs actual stock, native TLS, delivery and lifecycle observations.
///
/// Diagnostic plaintext is used only for criteria three and four when selected
/// before the run; it never changes criterion two or owner decisions.
Future<PluginGateReport> runPluginGate(
  PluginFixtureSuite suite, {
  bool withoutP521Signatures = false,
  bool diagnosticPlaintext = false,
}) async {
  final build = await suite.build();
  final credentials = await suite.createCredentials();
  final identity = PluginClientIdentity(
    certificatePem: await credentials.certificate.readAsBytes(),
    privateKeyPem: await credentials.privateKey.readAsBytes(),
  );
  final executable = build.binaries[PluginFixtureBinary.plainStock]!.path;
  final versions = <String, Object?>{};
  for (final command in <List<String>>[
    ['uname', '-sr'],
    ['mise', 'exec', '--', 'dart', '--version'],
    ['mise', 'exec', '--', 'go', 'version'],
  ]) {
    final result = await runBoundedProcess(command.first, command.sublist(1));
    versions[command.join(' ')] = {
      'exit_code': result.exitCode,
      'output': result.diagnostics.trim(),
    };
  }
  final first = await _observeHandshake(suite, credentials, executable);
  final second = await _observeTls(
    suite,
    identity,
    executable,
    withoutP521Signatures,
  );
  final mode = diagnosticPlaintext
      ? 'diagnostic-plaintext'
      : 'native-authenticated-tls';
  PluginGateCriterion third;
  PluginGateCriterion fourth;
  if (second.status != PluginGateStatus.passed && !diagnosticPlaintext) {
    third = _notRun(mode);
    fourth = _notRun(mode);
  } else {
    try {
      final delivery = await observePluginDelivery(
        suite,
        diagnosticPlaintext: diagnosticPlaintext,
      );
      third = PluginGateCriterion(
        status: PluginGateStatus.passed,
        securityMode: delivery.securityMode,
        commands: delivery.commands,
        evidence: delivery.toJson(),
      );
    } on Object catch (error) {
      third = PluginGateCriterion(
        status: PluginGateStatus.failed,
        securityMode: mode,
        commands: const [],
        evidence: const {},
        failure: '$error',
      );
    }
    final evidence = <String, Object?>{};
    final commands = <List<String>>[];
    final failures = <String>[];
    try {
      final death = await observePluginHostDeath(
        suite,
        diagnosticPlaintext: diagnosticPlaintext,
      );
      evidence['host_death'] = death.toJson();
      commands.add(death.command);
    } on Object catch (error) {
      failures.add('host death: $error');
    }
    try {
      final shutdown = await observePluginShutdown(
        suite,
        diagnosticPlaintext: diagnosticPlaintext,
      );
      evidence['shutdown'] = shutdown.toJson();
      commands.add([shutdown.normal.executable, ...shutdown.normal.arguments]);
      commands.add([
        shutdown.uncooperative.executable,
        ...shutdown.uncooperative.arguments,
      ]);
    } on Object catch (error) {
      failures.add('shutdown: $error');
    }
    fourth = PluginGateCriterion(
      status: failures.isEmpty
          ? PluginGateStatus.passed
          : PluginGateStatus.failed,
      securityMode: mode,
      commands: commands,
      evidence: evidence,
      failure: failures.isEmpty ? null : failures.join('; '),
    );
  }
  return PluginGateReport(
    List.unmodifiable([first, second, third, fourth]),
    Map.unmodifiable(versions),
  );
}

PluginGateCriterion _notRun(String mode) => PluginGateCriterion(
  status: PluginGateStatus.notRun,
  securityMode: mode,
  commands: const [],
  evidence: const {},
  failure: 'AutoMTLS prerequisite failed; diagnostic mode was not selected',
);

Future<PluginGateCriterion> _observeHandshake(
  PluginFixtureSuite suite,
  PluginFixtureCredentials credentials,
  String executable,
) async {
  final args = PluginFixtureArguments(
    journalPath: '${suite.scratchDirectory.path}/gate-handshake.jsonl',
    tlsMode: PluginFixtureTlsMode.required,
  ).toArguments();
  final command = [
    '/bin/sh',
    '-c',
    'umask 0177; exec "\$@"',
    'plugin-gate',
    executable,
    ...args,
  ];
  final facts = <String, Object?>{};
  Process? process;
  StreamIterator<String>? lines;
  Future<void>? stderrDone;
  try {
    process = await Process.start(
      command.first,
      command.sublist(1),
      environment: PluginFixtureEnvironment.standard(
        suite: suite,
        clientCertificatePem: await credentials.certificate.readAsString(),
      ).toEnvironment(),
      includeParentEnvironment: false,
    );
    final id = PluginProcessIdentity.read(process.pid);
    facts['pid'] = process.pid;
    facts['start_time'] = id?.startTime;
    stderrDone = process.stderr.drain<void>();
    lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    if (!await lines.moveNext().timeout(const Duration(seconds: 10))) {
      throw StateError('stock fixture exited before handshake');
    }
    final fields = lines.current.split('|');
    if ((fields.length != 6 && fields.length != 7) ||
        fields[0] != '1' ||
        fields[1] != '1' ||
        fields[2] != 'unix' ||
        fields[4] != 'grpc' ||
        fields[5].isEmpty ||
        (fields.length == 7 && fields[6] != 'false')) {
      throw const FormatException('invalid stock handshake');
    }
    final socket = await File(fields[3]).resolveSymbolicLinks();
    if (!socket.startsWith('${suite.scratchDirectory.path}/')) {
      throw StateError('socket outside private directory');
    }
    final stat = await Process.run('/usr/bin/stat', [
      '-Lc',
      '%u:%a:%F',
      '--',
      socket,
    ]);
    if (stat.exitCode != 0) {
      throw StateError('cannot stat stock socket: ${stat.stderr}');
    }
    final parts = (stat.stdout as String).trim().split(':');
    if (parts.length != 3) {
      throw const FormatException('unexpected socket stat');
    }
    final uid = int.parse(parts[0]);
    final socketMode = int.parse(parts[1], radix: 8);
    final selfStatus = await File('/proc/self/status').readAsString();
    final uidMatch = RegExp(
      r'^Uid:\s+(\d+)',
      multiLine: true,
    ).firstMatch(selfStatus);
    if (uidMatch == null) throw StateError('cannot determine current uid');
    facts.addAll({
      'core_version': fields[0],
      'version': int.parse(fields[1]),
      'network': fields[2],
      'protocol': fields[4],
      'certificate_present': true,
      'socket_mode': socketMode,
      'socket_uid': uid,
      'launch_umask': '0177',
      'socket_type': parts[2],
    });
    if (parts[2] != 'socket' ||
        socketMode != 0x180 ||
        uid != int.parse(uidMatch.group(1)!)) {
      throw StateError('unsafe stock socket');
    }
    var expired = false;
    final connecting = RawSocket.connect(
      InternetAddress(socket, type: InternetAddressType.unix),
      0,
    );
    unawaited(
      connecting.then<void>((raw) {
        if (expired) raw.close();
      }, onError: (Object _, StackTrace _) {}),
    );
    RawSocket raw;
    try {
      raw = await connecting.timeout(const Duration(seconds: 5));
    } on Object {
      expired = true;
      rethrow;
    }
    await raw.close();
    facts['unix_connect'] = true;
    facts['tls_negotiated'] = false;
    facts['application_rpc'] = false;
    return PluginGateCriterion(
      status: PluginGateStatus.passed,
      securityMode: 'stock-automtls-handshake-only',
      commands: [command],
      evidence: facts,
    );
  } on Object catch (error) {
    return PluginGateCriterion(
      status: PluginGateStatus.failed,
      securityMode: 'stock-automtls-handshake-only',
      commands: [command],
      evidence: facts,
      failure: '$error',
    );
  } finally {
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
      await lines?.cancel();
      try {
        await process.stdin.close();
      } on IOException {
        /* Child already closed stdin. */
      }
      await stderrDone;
    }
  }
}

Future<PluginGateCriterion> _observeTls(
  PluginFixtureSuite suite,
  PluginClientIdentity identity,
  String executable,
  bool withoutP521Signatures,
) async {
  final arguments = PluginFixtureArguments(
    journalPath: '${suite.scratchDirectory.path}/gate-tls.jsonl',
    tlsMode: PluginFixtureTlsMode.required,
  ).toArguments();
  final commands = <List<String>>[];
  final facts = <String, Object?>{
    'signature_offer_restricted': withoutP521Signatures,
  };
  final host = createPluginHostForTesting(
    PluginHostConfig(
      executable: executable,
      arguments: arguments,
      identity: identity,
      timeout: const Duration(seconds: 10),
    ),
    controls: PluginHostTestControls(
      processStarter: (exe, args, env) async {
        commands.add([exe, ...args]);
        final child = await Process.start(
          exe,
          args,
          environment: env,
          includeParentEnvironment: false,
        );
        facts['pid'] = child.pid;
        facts['start_time'] = PluginProcessIdentity.read(child.pid)?.startTime;
        return child;
      },
      tls: PluginTlsTestControls(
        withoutP521Signatures: withoutP521Signatures,
        socketConnector: (address, port) async {
          final raw = await RawSocket.connect(address, port);
          facts['unix_connect'] = true;
          return raw;
        },
      ),
    ),
  );
  try {
    await host.start();
    facts['health_serving'] = true;
    await host.probe();
    facts['protected_probe'] = true;
    final tls = host.tlsEvidence!;
    facts.addAll({
      'tls_protocol': tls.protocol,
      'server_curve': tls.serverCertificateCurve,
      'client_curve': tls.clientCertificateCurve,
      'backend_version': tls.backendVersion,
      'configuration_policy': tls.configurationPolicy,
      'configuration_source': tls.configurationSource,
      'configuration_environment': tls.configurationEnvironment,
    });
    final handshake = host.evidence!;
    facts.addAll(_handshakeFacts(handshake));
    facts['effective_umask'] = host.effectiveUmask;
    if (tls.protocol != 'TLSv1.3' ||
        !['P-521', 'secp521r1'].contains(tls.serverCertificateCurve) ||
        !['P-521', 'secp521r1'].contains(tls.clientCertificateCurve)) {
      throw StateError(
        'unexpected negotiated TLS protocol or certificate curves',
      );
    }
    return PluginGateCriterion(
      status: PluginGateStatus.passed,
      securityMode: 'native-authenticated-tls',
      commands: commands,
      evidence: facts,
    );
  } on Object catch (error) {
    if (error is PluginStartupException) {
      if (error.evidence != null) {
        facts.addAll(_handshakeFacts(error.evidence!));
      }
      facts['cause_type'] = error.cause.runtimeType.toString();
      facts['cause'] = '${error.cause}';
    }
    return PluginGateCriterion(
      status: PluginGateStatus.failed,
      securityMode: 'native-authenticated-tls',
      commands: commands,
      evidence: facts,
      failure: '$error',
    );
  } finally {
    await host.stop();
  }
}

Map<String, Object?> _handshakeFacts(PluginHandshakeEvidence evidence) => {
  'version': evidence.version,
  'socket_mode': evidence.socketMode,
  'socket_uid': evidence.socketUid,
  'certificate_present': evidence.certificate?.isNotEmpty ?? false,
};

/// Observes the exact-mode diagnostic guard using a real readable socket.
Future<Map<String, Object?>> observeDiagnosticSocketRefusal(
  PluginFixtureSuite suite,
) async {
  final build = await suite.build();
  final credentials = await suite.createCredentials();
  final journal = File('${suite.scratchDirectory.path}/gate-readable.jsonl');
  final arguments = PluginFixtureArguments(
    journalPath: journal.path,
    tlsMode: PluginFixtureTlsMode.plaintext,
  ).toArguments();
  final host = createPluginHostForTesting(
    PluginHostConfig(
      executable: build.binaries[PluginFixtureBinary.plainStock]!.path,
      arguments: arguments,
      identity: PluginClientIdentity(
        certificatePem: await credentials.certificate.readAsBytes(),
        privateKeyPem: await credentials.privateKey.readAsBytes(),
      ),
      timeout: const Duration(seconds: 10),
    ),
    controls: const PluginHostTestControls(
      diagnosticPlaintext: true,
      launchUmask: PluginLaunchUmask.readable0022,
    ),
  );
  try {
    try {
      await host.start();
      throw StateError('readable diagnostic socket was accepted');
    } on PluginStartupException catch (error) {
      return {
        'socket_mode': error.evidence?.socketMode,
        'socket_uid': error.evidence?.socketUid,
        'effective_umask': host.effectiveUmask,
        'cause': '${error.cause}',
        'cause_type': error.cause.runtimeType.toString(),
        'journal_empty':
            !await journal.exists() || (await journal.length()) == 0,
      };
    }
  } finally {
    await host.stop();
  }
}
