@Tags(['plugin'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:correlia_server/plugin.dart';
import 'package:correlia_server/src/plugin/plugin_host.dart'
    show PluginHostTestControls, PluginLaunchUmask, createPluginHostForTesting;
import 'package:test/test.dart';

import 'support/plugin_fixture_support.dart';

void main() {
  late PluginFixtureSuite suite;
  late String executable;
  late PluginClientIdentity identity;
  late PluginClientIdentity otherIdentity;
  late String certificate;
  late String otherCertificate;
  var attempt = 0;

  setUpAll(() async {
    suite = PluginFixtureSuite.create();
    final build = await suite.build();
    executable = build.binaries[PluginFixtureBinary.plainStock]!.path;
    final first = await suite.createCredentials();
    certificate = await first.certificate.readAsString();
    identity = PluginClientIdentity(
      certificatePem: utf8.encode(certificate),
      privateKeyPem: await first.privateKey.readAsBytes(),
    );
    final second = await suite.createCredentials();
    otherCertificate = await second.certificate.readAsString();
    otherIdentity = PluginClientIdentity(
      certificatePem: utf8.encode(otherCertificate),
      privateKeyPem: await second.privateKey.readAsBytes(),
    );
  });

  tearDownAll(() async => suite.dispose());

  (PluginHost, File) host({
    PluginFixtureStartupMode startup = PluginFixtureStartupMode.serve,
    bool omitClient = false,
    PluginClientIdentity? client,
    String? pin,
    String cookie = 'correlia-plugin-host-spike',
    String versions = '1',
    String? executableOverride,
    List<String>? argumentOverride,
    PluginLaunchUmask launchUmask = PluginLaunchUmask.restrictive0177,
    bool foreignUidNamespace = false,
  }) {
    final journal = File(
      '${suite.scratchDirectory.path}/host-${attempt++}.jsonl',
    );
    final arguments = PluginFixtureArguments(
      journalPath: journal.path,
      startupMode: startup,
      tlsMode: PluginFixtureTlsMode.required,
    );
    return (
      createPluginHostForTesting(
        PluginHostConfig(
          executable: foreignUidNamespace
              ? '/usr/bin/unshare'
              : executableOverride ?? executable,
          arguments: foreignUidNamespace
              ? [
                  '--user',
                  '--map-root-user',
                  '--map-auto',
                  '--',
                  executable,
                  ...arguments.toArguments(),
                ]
              : argumentOverride ?? arguments.toArguments(),
          identity: identity,
          cookie: cookie,
          versions: versions,
          timeout: const Duration(seconds: 2),
        ),
        controls: PluginHostTestControls(
          omitIdentity: omitClient,
          identityOverride: client,
          pinOverride: pin,
          launchUmask: launchUmask,
        ),
      ),
      journal,
    );
  }

  Future<PluginStartupException> fails(PluginHost host, File journal) async {
    try {
      PluginStartupException? failure;
      try {
        await host.start();
        fail('startup unexpectedly succeeded');
      } on PluginStartupException catch (error) {
        failure = error;
      }
      expect(
        await journal.exists() ? await journal.readAsString() : '',
        isEmpty,
      );
      if (host.childPid case final int pid) {
        expect(
          await File('/proc/$pid/stat').exists(),
          isFalse,
          reason: 'startup failure must already have reaped the exact child',
        );
      }
      return failure;
    } finally {
      await host.stop();
    }
  }

  test('plain stock plugin negotiates and serves', () async {
    final journal = File(
      '${suite.scratchDirectory.path}/host-${attempt++}.jsonl',
    );
    final plugin = PluginHost(
      PluginHostConfig(
        executable: executable,
        arguments: PluginFixtureArguments(
          journalPath: journal.path,
          tlsMode: PluginFixtureTlsMode.required,
        ).toArguments(),
        identity: identity,
        timeout: const Duration(seconds: 2),
      ),
    );
    try {
      await plugin.start();
      expect(plugin.evidence!.version, 1);
      expect(plugin.evidence!.socketMode, 0x180);
      await plugin.probe();
    } finally {
      await plugin.stop();
    }
    final (inherited, _) = host(launchUmask: PluginLaunchUmask.inherited);
    try {
      try {
        await inherited.start();
        await inherited.probe();
        expect(inherited.evidence!.socketMode & 0x12, 0);
      } on PluginStartupException catch (error) {
        expect(error.message, contains('Unsafe socket'));
        expect(error.evidence!.socketMode & 0x12, isNot(0));
      }
      expect(inherited.inheritedUmask, isNotNull);
      expect(inherited.effectiveUmask, inherited.inheritedUmask);
      expect(inherited.evidence, isNotNull);
    } finally {
      await inherited.stop();
    }
  });

  test('invalid startup fails bounded and reaps own child', () async {
    for (final (mode, reason) in [
      (PluginFixtureStartupMode.malformed, 'handshake fields'),
      (PluginFixtureStartupMode.oversized, 'exceeds 16 KiB'),
      (PluginFixtureStartupMode.incomplete, 'TimeoutException'),
      (PluginFixtureStartupMode.exit, 'before completing handshake'),
      (PluginFixtureStartupMode.stall, 'TimeoutException'),
    ]) {
      final (plugin, journal) = host(startup: mode);
      final failure = await fails(plugin, journal);
      expect(failure.message, contains(reason));
      expect(plugin.childPid, isNotNull);
    }
    for (final values in [
      (
        cookie: 'wrong-cookie',
        versions: '1',
        launchUmask: PluginLaunchUmask.restrictive0177,
        reason: 'before completing handshake',
      ),
      (
        cookie: 'correlia-plugin-host-spike',
        versions: '999',
        launchUmask: PluginLaunchUmask.restrictive0177,
        reason: 'Unsupported plugin handshake',
      ),
      (
        cookie: 'correlia-plugin-host-spike',
        versions: '1',
        launchUmask: PluginLaunchUmask.permissive0002,
        reason: 'Unsafe socket',
      ),
    ]) {
      final (plugin, journal) = host(
        cookie: values.cookie,
        versions: values.versions,
        launchUmask: values.launchUmask,
      );
      final failure = await fails(plugin, journal);
      expect(failure.message, contains(values.reason));
      expect(plugin.childPid, isNotNull);
      if (values.launchUmask == PluginLaunchUmask.permissive0002) {
        expect(plugin.effectiveUmask, 2);
        expect(failure.evidence!.socketMode & 0x12, isNot(0));
      }
    }
    final (stalled, stalledJournal) = host(
      startup: PluginFixtureStartupMode.stallHealth,
    );
    final healthFailure = await fails(stalled, stalledJournal);
    expect(
      healthFailure.evidence,
      isNotNull,
      reason:
          'the stock server must complete its handshake before health stalls',
    );
    expect(stalled.childPid, isNotNull);
    final emptyScript = File(
      '${suite.scratchDirectory.path}/empty-${attempt++}.sh',
    );
    await emptyScript.writeAsString(
      r'''printf '1|1|unix|/dev/null|grpc|\n'
read -r ignored
''',
    );
    final (empty, emptyJournal) = host(
      executableOverride: '/bin/sh',
      argumentOverride: [emptyScript.path],
    );
    final emptyFailure = await fails(empty, emptyJournal);
    expect(emptyFailure.message, contains('Unsupported plugin handshake'));
    for (final script in [
      r'''printf '1|1|unix|/dev/null|grpc|%s\n' "$CERT"
read -r ignored
''',
      r''': > "$PLUGIN_UNIX_SOCKET_DIR/not-socket"
printf '1|1|unix|%s/not-socket|grpc|%s\n' "$PLUGIN_UNIX_SOCKET_DIR" "$CERT"
read -r ignored
''',
    ]) {
      final file = File(
        '${suite.scratchDirectory.path}/unsafe-${attempt++}.sh',
      );
      final der = certificate.replaceAll(RegExp(r'-----[^-]+-----|\s'), '');
      await file.writeAsString("CERT='$der'\n$script");
      final (plugin, journal) = host(
        executableOverride: '/bin/sh',
        argumentOverride: [file.path],
      );
      final failure = await fails(plugin, journal);
      expect(
        failure.message,
        anyOf(contains('escapes'), contains('Unsafe socket')),
      );
      expect(plugin.childPid, isNotNull);
    }
    final (foreign, foreignJournal) = host(
      startup: PluginFixtureStartupMode.foreignOwner,
      foreignUidNamespace: true,
    );
    final foreignFailure = await fails(foreign, foreignJournal);
    final self = await Process.run('id', ['-u']);
    expect(self.exitCode, 0);
    final selfUid = int.parse((self.stdout as String).trim());
    expect(foreignFailure.evidence, isNotNull);
    expect(foreignFailure.evidence!.socketUid, isNot(selfUid));
    expect(foreignFailure.evidence!.socketMode, 0x180);
    expect(foreignFailure.message, contains('Unsafe socket'));
  });

  test('mutual P-521 authentication protects application RPC', () async {
    final (plugin, _) = host(
      client: identity,
    );
    try {
      await plugin.start();
      expect(plugin.evidence!.version, 1);
      expect(plugin.evidence!.certificate, isNotEmpty);
      expect(plugin.evidence!.socketMode, 0x180);
      expect(plugin.tlsEvidence!.protocol, 'TLSv1.3');
      expect(
        plugin.tlsEvidence!.serverCertificateCurve,
        anyOf('secp521r1', 'P-521'),
      );
      expect(
        plugin.tlsEvidence!.clientCertificateCurve,
        anyOf('secp521r1', 'P-521'),
      );
      expect(plugin.inheritedUmask, isNotNull);
      expect(plugin.effectiveUmask, 0x7f);
      await plugin.probe();
    } finally {
      await plugin.stop();
    }
    expect(plugin.tlsEvidence, isNotNull);
  });

  test('unauthorized peers fail without plaintext retry', () async {
    // A cryptography or startup failure must not masquerade as peer rejection.
    final (control, _) = host(
      client: identity,
    );
    try {
      await control.start();
      await control.probe();
    } finally {
      await control.stop();
    }
    for (final values in [
      (client: identity, omit: false, pin: otherCertificate),
      (client: null, omit: true, pin: null),
      (client: otherIdentity, omit: false, pin: null),
    ]) {
      final (plugin, journal) = host(
        client: values.client,
        omitClient: values.omit,
        pin: values.pin,
      );
      final failure = await fails(plugin, journal);
      expect(
        failure.evidence,
        isNotNull,
        reason: 'the genuine stock handshake must precede the TLS failure',
      );
      expect(failure.evidence!.version, 1);
      expect(failure.evidence!.socketMode, 0x180);
      expect(failure.evidence!.certificate, isNotEmpty);
      expect(plugin.childPid, isNotNull);
      if (values.pin != null) {
        expect(failure.cause, isA<HandshakeException>());
      } else {
        // Go can close immediately after rejecting a client identity; Linux
        // may expose the reset instead of delivering its buffered TLS alert.
        expect(
          failure.cause,
          anyOf(
            isA<HandshakeException>(),
            isA<SocketException>().having(
              (error) => error.osError?.errorCode,
              'peer reset after the genuine TLS announcement',
              104,
            ),
          ),
        );
      }
    }
  });
}
