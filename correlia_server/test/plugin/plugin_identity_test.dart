@Tags(['plugin'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/src/plugin/openssl_engine.dart';
import 'package:test/test.dart';

import 'support/plugin_fixture_support.dart';

void main() {
  late PluginFixtureSuite suite;
  late String inspector;
  setUpAll(() async {
    suite = PluginFixtureSuite.create();
    final build = await suite.build();
    inspector = build.binaries[PluginFixtureBinary.identityInspect]!.path;
  });
  tearDownAll(() async => suite.dispose());

  test(
    'fresh identity has P-521, localhost SAN, 30-day validity and matching key',
    () async {
      final first = mintPluginIdentity();
      final second = mintPluginIdentity();
      expect(first.certificatePem, isNot(equals(second.certificatePem)));
      expect(first.privateKeyPem, isNot(equals(second.privateKeyPem)));
      for (final identity in [first, second]) {
        final process = await Process.start(inspector, []);
        final stdoutDone = process.stdout.transform(utf8.decoder).join();
        final stderrDone = process.stderr.transform(utf8.decoder).join();
        process.stdin.write(
          jsonEncode({
            'certificate': utf8.decode(identity.certificatePem),
            'key': utf8.decode(identity.privateKeyPem),
          }),
        );
        await process.stdin.close();
        final code = await process.exitCode;
        final output = await stdoutDone;
        final errors = await stderrDone;
        expect(code, 0, reason: errors);
        expect(output.trim(), 'valid');
      }
    },
  );

  test(
    'repeated in-memory identity minting releases native allocations',
    () async {
      final output = '${suite.scratchDirectory.path}/identity-alloc-counter.so';
      final built = await runBoundedProcess('mise', [
        'exec',
        '--',
        'cc',
        '-shared',
        '-fPIC',
        '-o',
        output,
        'test/plugin/fixtures/native/alloc_counter.c',
        '-lcrypto',
      ]);
      expect(built.exitCode, 0, reason: built.diagnostics);
      final result = await runBoundedProcess(Platform.resolvedExecutable, [
        'test/plugin/fixtures/native/identity_allocation_child.dart',
        output,
      ]);
      expect(result.exitCode, 0, reason: result.diagnostics);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
