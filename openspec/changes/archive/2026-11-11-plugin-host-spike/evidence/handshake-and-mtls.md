# Handshake and mutual TLS: built-in failure and native integration

## Status

The **custom in-process OpenSSL connector** now passes authenticated stock
startup and protected application RPC, with both observed certificate groups
P-521 and negotiated TLSv1.3. Its native/resource checks also pass.
The built-in Dart TLS result remains **FAILED**, preserved below as historical
diagnosis, not reclassified by the custom connector's success.
See [current native integration](#current-native-integration) for new results.
This group does not prove criteria 3/4 or grant D24, production adoption, or the
owner-only ADR 0020 criterion-2 interpretation. Task 5.5 remains open.

## Environment and dependencies

| Component | Observed version |
|---|---|
| Linux | 6.18.33.2-microsoft-standard-WSL2 |
| Dart | 3.13.7 stable, linux_x64 |
| Go | go1.27.3 linux/amd64 |
| Buf | 1.75.0 |
| OpenSpec | 1.16.0 |
| OpenSSL | 3.0.13, 30 Jan 2024 |
| grpc-dart | 5.2.0 |
| Dart protobuf | 6.1.0 |
| go-plugin | v1.8.0, unmodified module |
| Go grpc | v1.75.1 |

Version commands: `uname -sr`, `mise exec -- dart --version`,
`mise exec -- go version`, `mise exec -- buf --version`,
`mise exec -- openspec --version`, `mise exec -- openssl version`.
Dart dependency resolution succeeded without overrides. Go module tidy and
checksum verification passed.

## Historical foundation startup evidence (diagnostic-only)

The foundation smoke built and reused one suite's binaries, generated P-521
credentials, verified directory 0700 and credential files 0600, launched both
plain-stock and stdin-watched executables, observed watched EOF-marker/exit,
removed owned scratch, and preserved an independently launched decoy.
This was not a four-gate run or a host-SIGKILL proof.

Both stock sockets were **0775** under the inherited development umask.
Nothing chmodded a stock socket. Subsequent explicitly selected launches used
`/bin/sh -c 'umask 0177; exec "$@"' <label> <fixture> ...`; observed mode was
**0600**, and exec retained the direct child PID. D24 is still owner-only.

Parsed negotiation: core `1`, application `1`, transport `unix`, protocol
`grpc`, nonempty unpadded-base64 DER server certificate. Certificate/key
material was ephemeral; no private key is recorded here.

## Historical criterion 2 failure: built-in Dart TLS

The P-521 certificate and PKCS8 private key loaded successfully into Dart's
`SecurityContext(withTrustedRoots: false)`. The actual socket probe used only
the handshake certificate as trust, authority `localhost`, ALPN `h2`, and the
matching advertised client identity. The valid-client path failed:

```text
HandshakeException: Handshake error in client (OS Error:
SSLV3_ALERT_HANDSHAKE_FAILURE(tls_record.cc:491)
HANDSHAKE_FAILURE_ON_CLIENT_HELLO(handshake.cc:590))
```

A bounded capture of the actual Dart ClientHello produced:

```json
{"tls_versions":["0x0304","0x0303"],"signature_algorithms":["0x0403","0x0804","0x0401","0x0503","0x0805","0x0501","0x0806","0x0601","0x0201"],"offers_ecdsa_secp521r1_sha512_0x0603":false,"client_identity":"suite-generated P-521","alpn":"h2"}
```

The active Go toolchain's `src/crypto/tls/auth.go:208-227` restricts a P-521
key under TLS 1.3 to `ECDSAWithP521AndSHA512`; lines 290-297 reject peers
without a mutually supported signature algorithm. TLS 1.3 uses scheme
`0x0603`, absent from the captured Dart offer. The same source explicitly
allows broader ECDSA signature schemes under TLS 1.2. No TLS-version forcing,
server certificate substitution, stock TLS modification, or proxy was used.

The active Dart `SecurityContext` public API exposes
`minimumTlsProtocolVersion` (default TLS 1.2), but no maximum-version or
signature-scheme setter. Setting that minimum to TLS 1.2 does not prevent
offering TLS 1.3. No supported client configuration fix was identified.

Independent OpenSSL control against the **same stock fixture configuration**:

| Control | Actual result |
|---|---|
| Matching client certificate/key and exact server trust | exit 0; TLSv1.3; TLS_AES_128_GCM_SHA256; ECDSA/SHA512; verification OK; localhost verified |
| Client certificate absent | exit 1; TLSv1.3 alert `certificate required` (116) |
| Server certificate inspection | P-521 (`secp521r1`) |
| Both control socket modes | 0600 under explicit launch umask 0177 |

These controls establish that the stock P-521 fixture works and enforces
client authentication with a compatible client. They do **not** prove Dart
protected RPC success. Dart wrong-pin/client-identity negatives remain
inconclusive until its valid-client control can succeed.

## Historical parent-owned test evidence

Both new test files were run red before implementation through the parent's
MCP callback. Four mapped host rows failed for absent runtime behavior;
transport oversize/compression checks and protected/authentication RPC tests
also failed for their absent behaviors, not missing imports or compilation.

After implementation, parent MCP `run_tests` request:

```json
{"roots":[{"root":"file:///home/bgshi/Development/dart/correlia/correlia_server","paths":["test/plugin/plugin_host_test.dart","test/plugin/plugin_transport_test.dart"]}],"arguments":{"reporter":"expanded"}}
```

Result: **6 passed, 4 failed** in 7 seconds.

Passed: plain-stock diagnostic handshake/health/application; covered invalid
startup/deadline/cleanup cases; oversize-prefix guard; compressed/truncated
frame rejection; split-prefix rejection/reset; response-cancellation reset.

Failed with the same ClientHello handshake error:
- host `mutual P-521 authentication protects application RPC`;
- host `unauthorized peers fail without plaintext retry` (positive control);
- transport `stock AutoMTLS mutual P-521 authentication protects application RPC`;
- transport `stock AutoMTLS wrong pin and absent or wrong client identity fail after fixture readiness` (positive control).

Targeted analysis reported no errors. A workspace gate was not run or claimed.

## Historical ownership-test resolution and remaining work

The initial user-namespace attempt failed because `newuidmap` was missing.
After the owner installed it, a real namespace/socket probe succeeded:
namespace UID 0 mapped to host UID 1000, and namespace UID 1 mapped into the
subordinate range starting at host UID 100000.

The original Go negative fixture now binds a real socket **inside the host's
0700 attempt directory**, changes its owner to namespace UID 1, and announces
it with mode 0600. The host records the actual UID observed in its own
namespace. The process test verifies it differs from the host UID and is
rejected, with no event delivery and exact-child cleanup. No stat seam or
test substitution was used.

Parent MCP reran `invalid startup fails bounded and reaps own child` with
this added case: **1 passed** in 6 seconds. The case uses
`unshare --user --map-root-user --map-auto`; it requires working subordinate
UID/GID mappings and the namespace mapping helpers.

At that point, late Process.start ownership had not been verified and group 2
was incomplete. The new native/resource results below supersede that interim
status. Criteria 3/4 were not exercised by this historical foundation smoke.
Explicit diagnostics never grant fallback/adoption approval.

## Reproducing the independent diagnosis

The temporary probe sources below contain no credentials. Save each under
root `.dart_tool/` with the displayed name, then execute from
`correlia_server` using the displayed command. Each probe creates and deletes
its own suite scratch and exact children. The ClientHello probe captures only
its own loopback client connection. The OpenSSL control uses a plain-stock
plugin with explicitly selected umask 0177, without modifying stock TLS.

### ClientHello capabilities

Command: `mise exec -- dart ../.dart_tool/plugin-clienthello-probe.dart`.

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import '../correlia_server/test/plugin/support/plugin_fixture_suite.dart';

Future<void> main() async {
  final suite = PluginFixtureSuite.create();
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  Socket? accepted;
  Socket? client;
  try {
    final identity = await suite.createCredentials();
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(await identity.certificate.readAsBytes())
      ..usePrivateKeyBytes(await identity.privateKey.readAsBytes())
      ..setAlpnProtocols(['h2'], false);
    final acceptedFuture = listener.first;
    client = await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
    final tls = SecureSocket.secure(client!, host: 'localhost', context: context)
      .then<void>((value) { value.destroy(); }, onError: (Object _) {});
    accepted = await acceptedFuture;
    final bytes = BytesBuilder(copy: false);
    final complete = Completer<Uint8List>();
    accepted!.listen((chunk) {
      if (complete.isCompleted) return;
      bytes.add(chunk);
      if (bytes.length > 16384) {
        complete.completeError(StateError('ClientHello exceeds probe cap'));
        return;
      }
      final data = bytes.toBytes();
      if (data.length >= 5 && data.length >= 5 + ((data[3] << 8) | data[4])) {
        complete.complete(data);
      }
    }, onError: (Object error) { if (!complete.isCompleted) complete.completeError(error); });
    final data = await complete.future.timeout(const Duration(seconds: 3));
    if (data[0] != 22 || data[5] != 1) throw StateError('not TLS ClientHello');
    int u16(int index) => (data[index] << 8) | data[index + 1];
    var offset = 9 + 2 + 32;
    offset += 1 + data[offset];
    offset += 2 + u16(offset);
    offset += 1 + data[offset];
    final end = offset + 2 + u16(offset);
    offset += 2;
    final algorithms = <String>[];
    final versions = <String>[];
    while (offset < end) {
      final type = u16(offset);
      final length = u16(offset + 2);
      final start = offset + 4;
      if (type == 13) {
        for (var at = start + 2; at < start + 2 + u16(start); at += 2) {
          algorithms.add('0x${u16(at).toRadixString(16).padLeft(4, '0')}');
        }
      }
      if (type == 43) {
        for (var at = start + 1; at < start + 1 + data[start]; at += 2) {
          versions.add('0x${u16(at).toRadixString(16).padLeft(4, '0')}');
        }
      }
      offset = start + length;
    }
    stdout.writeln(jsonEncode({
      'tls_versions': versions,
      'signature_algorithms': algorithms,
      'offers_ecdsa_secp521r1_sha512_0x0603': algorithms.contains('0x0603'),
      'client_identity': 'suite-generated P-521',
      'alpn': 'h2',
    }));
    accepted!.destroy();
    client!.destroy();
    await tls;
  } finally {
    accepted?.destroy();
    client?.destroy();
    await listener.close();
    await suite.dispose();
  }
}

```

### Independent OpenSSL controls

Command: `mise exec -- dart ../.dart_tool/plugin-p521-openssl-control.dart`.

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../correlia_server/test/plugin/support/plugin_fixture_suite.dart';
import '../correlia_server/test/plugin/support/plugin_process_identity.dart';

Future<void> main() async {
  final suite = PluginFixtureSuite.create();
  try {
    final built = await suite.build();
    final identity = await suite.createCredentials();
    final child = await Process.start('/bin/sh', [
      '-c', r'umask 0177; exec "$@"', 'plugin-openssl-control',
      built.binaries[PluginFixtureBinary.plainStock]!.path,
      '--journal', '${suite.scratchDirectory.path}/control.jsonl',
    ], includeParentEnvironment: false, environment: {
      'CORRELIA_PLUGIN_COOKIE': 'correlia-plugin-host-spike',
      'PLUGIN_PROTOCOL_VERSIONS': '1',
      'PLUGIN_CLIENT_CERT': await identity.certificate.readAsString(),
      'PLUGIN_UNIX_SOCKET_DIR': suite.scratchDirectory.path,
    });
    final processIdentity = PluginProcessIdentity.read(child.pid)!;
    final errorsDone = child.stderr.drain<void>();
    try {
      final line = await child.stdout.transform(utf8.decoder)
          .transform(const LineSplitter()).first.timeout(const Duration(seconds: 5));
      final fields = line.split('|');
      final der = base64.decode(base64.normalize(fields[5]));
      final pem = File('${suite.scratchDirectory.path}/server-public.pem')
        ..writeAsStringSync('-----BEGIN CERTIFICATE-----\n${base64.encode(der)}\n-----END CERTIFICATE-----\n');
      final certificate = await Process.run('openssl', [
        'x509', '-in', pem.path, '-text', '-noout',
      ]);
      final serverP521 = (certificate.stdout as String).contains('secp521r1');
      for (final includeIdentity in [true, false]) {
        final result = await Process.run('openssl', [
          's_client', '-unix', fields[3], '-servername', 'localhost',
          '-verify_hostname', 'localhost', '-verify_return_error',
          '-CAfile', pem.path, '-alpn', 'h2', '-brief',
          if (includeIdentity) ...[
            '-cert', identity.certificate.path, '-key', identity.privateKey.path,
          ],
        ]).timeout(const Duration(seconds: 5));
        stdout.writeln(jsonEncode({
          'case': includeIdentity ? 'openssl-valid-client-control' : 'openssl-missing-client-control',
          'exit': result.exitCode,
          'diagnostic': '${result.stdout}${result.stderr}',
          'server_curve': serverP521 ? 'P-521' : 'unexpected',
          'core': fields[0], 'app': fields[1], 'transport': fields[2], 'protocol': fields[4],
          'socket_mode': ((await FileStat.stat(fields[3])).mode & 0x1ff).toRadixString(8),
          'launch_umask': '0177',
        }));
        if (serverP521 == false || (result.exitCode == 0) != includeIdentity) {
          throw StateError('OpenSSL control did not establish expected fixture behavior');
        }
      }
    } finally {
      processIdentity.signalIfExact(ProcessSignal.sigkill);
      await child.exitCode.timeout(const Duration(seconds: 5));
      await errorsDone;
    }
  } finally {
    await suite.dispose();
  }
}

```

## Current native integration

Parent-owned verification on 2026-11-11 uses the permanent implementation,
not the earlier external `openssl s_client` control. `lib/plugin.dart` exposes
only authenticated host construction; the native engine/socket/compatibility
connector run inside the Dart host process. Stock go-plugin v1.8.0 is unchanged.
ADR 0023 restates and supersedes ADR 0022 without editing that accepted ADR.

### Authenticated public API and configuration

Executed from `correlia_server`:

```sh
mise exec -- dart run .dart_tool/plugin-native-verification/public_smoke.dart
```

The throwaway public-import program built the real plain-stock fixture,
generated its ephemeral identity, called `PluginHost.start` and `probe`, then
stopped/reaped the child and disposed its suite. Observed output:

```json
{"public_authenticated_application_rpc":"passed","version":1,"inherited_umask":"0002","effective_umask":"0177","socket_mode":"0600","socket_uid":1000,"server_certificate_curve":"P-521","client_certificate_curve":"P-521","protocol":"TLSv1.3","backend":"OpenSSL 3.0.13 30 Jan 2024","configuration_policy":"system/OPENSSL_CONF","configuration_source":"OPENSSL_CONF=(default); compiled default directory=/usr/lib/ssl","configuration_environment":{"OPENSSL_CONF":null,"OPENSSL_CONF_INCLUDE":null,"OPENSSL_MODULES":null}}
```

Startup validated core/application versions 1, Unix transport, gRPC and the
nonempty DER announcement before requiring authenticated peer SETTINGS and
SERVING health. Curves come from the actual X509 public keys, not the TLS
key-exchange group. No private key, accept-all verifier, external TLS process,
protocol downgrade, permission repair or plaintext retry was involved.

The internal inherited-umask control, still using stock AutoMTLS, produced:

```json
{"inherited_stock_socket":"rejected without chmod","inherited_umask":"0002","effective_umask":"0002","socket_mode":"0775"}
```

Thus 0600 is the observed result of the explicit restrictive launch, not a
claim about go-plugin's intrinsic default. The owner must review both modes.
The mapped invalid-startup test additionally exercised explicit umask 0002,
empty certificate and TLS-protected stalled health, as well as the prior
cookie/version/path/real foreign-UID/handshake/deadline negatives.

A fresh child with an original `OPENSSL_CONF` whose `system_default` sets
both MinProtocol and MaxProtocol to TLSv1.2 was also executed:

```sh
mise exec -- env OPENSSL_CONF=/home/bgshi/Development/dart/correlia/correlia_server/.dart_tool/plugin-native-verification/max-tls12.cnf \
  dart run .dart_tool/plugin-native-verification/public_smoke.dart \
  --expect-tls12-policy-rejection
```

```json
{"tls12_only_configuration":"rejected","cause":"HandshakeException: Checking configured maximum TLS version: OpenSSL reported no further detail"}
```

The selected system configuration is honored, but cannot yield a passing
TLS1.2 result. Native contexts explicitly reset both trust stores to the sole
server pin and clear inherited session identity before installing the caller's
identity. Configuration selections are recorded without copying their contents.

A separate public-import-only kernel compile intentionally attempted the
internal factories/control types, umask selector and old `secure` switch:

```sh
mise exec -- dart compile kernel \
  .dart_tool/plugin-native-verification/private_controls_rejected.dart \
  -o .dart_tool/plugin-native-verification/rejected.dill
```

It exited **254**: internal constructors/factory/enum were undefined and
`PluginHostConfig` had no `secure` parameter. The successful public launch
above is the positive control. Other old advertised-certificate/pin/umask
configuration switches were removed, not retained as compatibility shims.

### Permanent parent-run checks

Dart MCP `run_tests` used the server root and each file separately, with
`reporter: expanded`; project-scoped JSON file reporters retained debugging
output during integration. Final observed results:

| File under `correlia_server/test/plugin/` | Passed | Failed |
|---|---:|---:|
| `plugin_host_test.dart` | 4 | 0 |
| `plugin_transport_test.dart` | 6 | 0 |
| `plugin_native_tls_test.dart` | 7 | 0 |
| `plugin_acquisition_test.dart` | 2 | 0 |

Wrong server pin and absent/wrong client identities failed after the genuine
stock handshake, with no application journal entries. The matching-client
positive passed before negatives, and the transport suite passed a later
matching-client RPC after them. Original native certificate errors survive
startup; Linux may expose peer reset (errno 104) instead of Go's buffered
client-authentication TLS alert. Neither is accepted as a timeout or plaintext
success.

The two 8 MiB native pressure checks use an original controlled P-521 TLS peer
only to isolate adapter flow control. A test-only forwarding observer wraps the
real RawSocket: a positive short kernel write was observed; all original bytes
arrived in order after releasing pressure. With the plaintext subscription
paused, actual ciphertext read bytes stopped, the real sender stalled, and
reads/byte-identical delivery resumed afterward. The plaintext queue remains
within 256 KiB; bounded BIO/staging ownership is independent of source size.
These byte-peer results do not substitute for the stock RPC tests.

| Native/resource row | Actual initial observation | Final observation |
|---|---|---|
| Bounded producer/partial writes | Red: real TLS reached; queue overflow at 256 KiB | Producer pauses; actual short write; 8 MiB byte identity |
| Native ABI unavailable | Initially green for real fixed-path load/missing-symbol faults | No raw connection or per-session allocator call |
| P-521 signature capability | Initially green for actual narrowed native signature profile | Handshake rejected, never plaintext |
| Partial native initialization | Failed baseline comparison: 5959 versus 5957 | Error-queue data is cleared on disposal; stable native and Dart allocation counts |
| Late raw socket | Initially green | Actual late OS connection closes after deadline |
| TLS/HTTP2 readiness stalls | Failed: competing gRPC deadline hid transport timeout | One readiness budget; both real stalls fail bounded and close the connection |
| Paused native consumer | Initially green; strengthened with actual socket-read observation | No read-ahead while paused; 8 MiB byte identity after resume |
| Late process | Red: own late child remained alive for the five-second assertion deadline | Late child killed and reaped |
| Late directory | Red: own late directory remained for the five-second assertion deadline | Late directory deleted |

No red result was fabricated for prototype behavior that already worked.
The producer and two acquisition regressions were captured through parent-owned
red callbacks before their fixes. Partial-initialization cleanup also cleared
residual OpenSSL error data rather than weakening the baseline assertion.
Normal/failed writer cancellation retires its producer; native I/O failure is
reported once through the incoming transport and retained original cause,
avoiding a duplicate canceled-writer error in http2's cleanup future.

### Actual allocation accounting

The permanent cold child installs the original C counter before OpenSSL
initialization, warms 16 success/invalid-key pairs, then measures 100 further
pairs. Its injected allocator also fails at every real Dart-side native
allocation site and requires no outstanding staging pointer after each failure.
The parent independently executed the resource smoke, compiling the C counter
with `-shared -fPIC -std=c11 -Wall -Wextra -Werror -lcrypto`, and observed:

```json
{"iterations":100,"native_live_before":5957,"native_live_after":5957,"dart_allocation_sites":11,"dart_live":0}
```

This is real OpenSSL allocation accounting, not RSS or a counter incremented
around constructors. The shared library and hooks are test-only; they never
enter the production host or the main test runner. The original earlier
prototype baseline was 5959; clearing residual error-queue data explains the
different current baseline, not an allocator exception.

### Limits of this result

This evidence establishes runtime criteria 1/2 through the custom connector
and its named resource checks only. The built-in Dart TLS failure above remains
failed. Criterion 3 reconciliation, criterion 4 direct-host SIGKILL proof and
the integrated gate belong to later groups. Owner task 5.5 still controls D24,
the criterion-2/custom-connector interpretation and production adoption.
Throwaway smoke programs/config/reporters are removed after verification;
permanent named tests and native allocation fixtures remain.

### Tooling validation for this group

Parent-run scoped Dart fix applied one unnecessary-underscore lint fix.
Dart formatting covered `lib/plugin.dart`, `lib/src/plugin` and `test/plugin`;
26 files were checked, 11 formatted. Targeted MCP analysis returned
`No errors`; the Serverpod hot reload completed. Release-note validation
returned `ok: true`, and `mise exec -- openspec validate plugin-host-spike
--strict` reported the change valid. This group did not run or claim the
later workspace check gate.
