@Tags(['plugin'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/plugin_fixture_suite.dart';
import 'support/plugin_gate_report.dart';

void main() {
  late PluginFixtureSuite suite;
  setUpAll(() async {
    suite = PluginFixtureSuite.create();
    await suite.build();
  });
  tearDownAll(() async => suite.dispose());

  test(
    'gate report reconciles four observed passing criteria without owner approval',
    () async {
      final report = await runPluginGate(suite);
      expect(
        report.criteria.map((c) => c.status),
        everyElement(PluginGateStatus.passed),
        reason: jsonEncode(report.toJson()),
      );
      expect(report.runtimePassed, isTrue);
      expect(
        PluginGateReport(
          report.criteria.take(3).toList(),
          report.versions,
        ).runtimePassed,
        isFalse,
        reason: 'Three observed criteria cannot grant a four-criterion verdict',
      );
      final handshake = report.criteria[0].evidence;
      expect(handshake['version'], 1);
      expect(handshake['unix_connect'], isTrue);
      expect(handshake['socket_mode'], 0x180);
      final tls = report.criteria[1].evidence;
      expect(tls['health_serving'], isTrue);
      expect(tls['protected_probe'], isTrue);
      expect(tls['tls_protocol'], 'TLSv1.3');
      expect(tls['server_curve'], anyOf('P-521', 'secp521r1'));
      expect(tls['client_curve'], anyOf('P-521', 'secp521r1'));
      final owner = report.toJson()['owner_decisions'] as Map<String, Object?>;
      expect(owner['transport'], 'pending');
      expect(owner['custom_connector_interpretation'], 'pending');
      expect(owner['task'], '5.5');
      stdout.writeln(jsonEncode(report.toJson()));
    },
    skip: Platform.isLinux ? false : 'Linux process receipts required',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'observed gate failure prevents a passing spike verdict',
    () async {
      final report = await runPluginGate(suite, withoutP521Signatures: true);
      expect(
        report.criteria[0].status,
        PluginGateStatus.passed,
        reason: jsonEncode(report.toJson()),
      );
      expect(report.criteria[0].evidence['unix_connect'], isTrue);
      final tls = report.criteria[1];
      expect(tls.status, PluginGateStatus.failed);
      expect(tls.evidence['cause_type'], 'HandshakeException');
      expect(tls.evidence['unix_connect'], isTrue);
      expect(tls.evidence['version'], 1);
      expect(tls.evidence['socket_mode'], 0x180);
      expect(tls.evidence['certificate_present'], isTrue);
      expect(tls.evidence['protected_probe'], isNot(isTrue));
      expect(report.criteria[2].status, PluginGateStatus.notRun);
      expect(report.criteria[3].status, PluginGateStatus.notRun);
      expect(report.runtimePassed, isFalse);
      stdout.writeln(jsonEncode(report.toJson()));
    },
    skip: Platform.isLinux ? false : 'Linux process receipts required',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'explicit diagnostic run preserves failed TLS verdict and independent evidence',
    () async {
      final report = await runPluginGate(
        suite,
        withoutP521Signatures: true,
        diagnosticPlaintext: true,
      );
      expect(
        report.criteria[0].status,
        PluginGateStatus.passed,
        reason: jsonEncode(report.toJson()),
      );
      expect(report.criteria[0].evidence['unix_connect'], isTrue);
      final tls = report.criteria[1];
      expect(tls.status, PluginGateStatus.failed);
      expect(tls.evidence['cause_type'], 'HandshakeException');
      expect(tls.evidence['unix_connect'], isTrue);
      expect(tls.evidence['version'], 1);
      expect(tls.evidence['socket_mode'], 0x180);
      expect(tls.evidence['certificate_present'], isTrue);
      expect(
        report.criteria[2].status,
        PluginGateStatus.passed,
        reason: jsonEncode(report.toJson()),
      );
      expect(
        report.criteria[3].status,
        PluginGateStatus.passed,
        reason: jsonEncode(report.toJson()),
      );
      expect(report.criteria[2].securityMode, 'diagnostic-plaintext');
      expect(report.criteria[3].securityMode, 'diagnostic-plaintext');
      expect(report.runtimePassed, isFalse);
      final owner = report.toJson()['owner_decisions'] as Map<String, Object?>;
      expect(owner['transport'], 'pending');
      expect(owner['custom_connector_interpretation'], 'pending');
      final refusal = await observeDiagnosticSocketRefusal(suite);
      expect(refusal['effective_umask'], 0x12);
      expect(refusal['socket_mode'], 0x1ed);
      expect((refusal['socket_mode'] as int) & 0x12, 0);
      expect(refusal['cause_type'], 'StateError');
      expect(refusal['journal_empty'], isTrue);
      stdout.writeln(
        jsonEncode({
          'report': report.toJson(),
          'diagnostic_socket_refusal': refusal,
        }),
      );
    },
    skip: Platform.isLinux ? false : 'Linux process receipts required',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
