# Canonical event contract tooling

The canonical event payload is defined by `proto/correlia/event/v1/event.proto`.
Standard `buf.validate` annotations are the source of truth for field
requirements, scalar and collection bounds, numeric domains and whole-value
patterns.

## Generate and check

Run the pinned Linux tools through mise:

```sh
mise run proto
mise run proto:check
```

`proto` generates three owned output sets:

- Dart messages under `correlia_server/lib/src/event_generated/`;
- the strict bundled payload schema under `contracts/schemas/`; and
- Dart bound constants in
  `correlia_server/lib/src/event_generated/correlia/event/v1/event_bounds.dart`.

Generation writes into disposable scratch first, formats generated Dart with
the workspace formatter settings in a scratch package, validates the generated
schema with the pinned Ajv validator and only then replaces owned outputs.
`proto:check` repeats that work in scratch and compares every output in both
directions. It never writes the checkout and removes its scratch directory on
success or failure.

The same commands generate the **experimental** `correlia.plugin.spike.v1`
output probe separately from event inputs:

- Dart protobuf/gRPC under `correlia_server/lib/src/plugin_generated/`;
- Go protobuf/gRPC under `correlia_server/test/plugin/fixtures/go/gen/`.

Plugin generation pins protoc_plugin 25.1.0, protoc-gen-go v1.36.11 and
protoc-gen-go-grpc v1.6.0. Only the plugin stage requests gRPC generation.
The event schema generator receives only `proto/correlia/event/v1`, and the
frozen event baseline is never regenerated. Plugin drift checks compare
changed, missing and obsolete files in both output roots. No upstream
go-plugin schemas enter Buf: compatibility RPC descriptors are handwritten
Dart, outside the Correlia-owned proto module. The probe is not a stable SDK
(ADR 0023, superseding ADR 0022).

The Buf workspace uses STANDARD lint rules and FILE breaking rules. The
committed `contracts/baselines/event-v1.0.binpb` is the one v1.0 descriptor
baseline. `proto:check` fails when it is missing and never rebuilds it
automatically. In addition to Buf's structural checks, the command compares
existing standard validation-rule objects, explicit JSON names, presence and
enum domains exactly. Optional additions pass; changing or widening an
existing domain and adding a required field or oneof fail and name the change.

Before publishing any v1.1 contract, that change must extend compatibility
coverage to the newly published contract while retaining the existing schemas.
The initial baseline does not protect fields that exist only in a future
minor.

## Experimental plugin startup

`package:correlia_server/plugin.dart` exports only authenticated `PluginHost`
construction, `PluginHostConfig`, immutable `PluginClientIdentity`, and
startup/handshake/TLS evidence. It is experimental, not the production plugin SDK.
The host owns one Linux subprocess, keeps stdin open without writing, and drains
stdout/stderr throughout its lifetime. It validates the bounded stock handshake,
0700 attempt directory and actual Unix socket owner/type/mode before connecting.
Startup requires authenticated HTTP/2 SETTINGS and health `plugin` = SERVING;
`probe` validates an empty application acknowledgement. Parsed handshake facts and
the original transport cause survive startup failure.

The normal path always uses stock go-plugin AutoMTLS over the Unix socket.
Original Dart FFI bindings use system `libssl.so.3` and `libcrypto.so.3` through
`ffi` 2.2.0; there is no OpenSSL executable/proxy, bundled crypto or Dart TLS
fallback. TLS 1.3 is mandatory. The handshake certificate is the sole trust pin:
both native trust stores are replaced, inherited identity material is cleared,
then the caller's certificate/key are installed. Certificate/time/signature,
`localhost`, exact DER and ALPN `h2` checks remain enabled. Evidence records the
actual certificate groups, protocol and backend version.

OpenSSL's default system/`OPENSSL_CONF` policy is honored. TLS evidence records
the compiled configuration directory and `OPENSSL_CONF`, `OPENSSL_CONF_INCLUDE`
and `OPENSSL_MODULES` selections, never config contents or private keys. A host
configuration capped at TLS 1.2 fails visibly rather than weakening the profile.
Missing native libraries/symbols fail before connecting or allocating per-session
native state. Runtime needs the OpenSSL 3 shared libraries; the C compiler and
OpenSSL development headers are needed only for allocation-accounting tests.

The engine owns its SSL context/session, 32 KiB BIOs in each direction and three
16 KiB native staging buffers. The socket adapter owns one 16 KiB ciphertext
buffer and at most 256 KiB retained plaintext, pauses its source at capacity and
stops reading while its plaintext consumer is paused. Native write retries retain
the identical buffer; short kernel writes preserve the unsent ciphertext.
Identity/DER inputs and certificate chains are capped at 16 KiB. Partial native
initialization, timeout, late acquisition and close release their owned resources;
private-key/plaintext staging is cleared. The gRPC wire guard rejects messages
above 2 MiB before accepting their body.

Default launch policy is `/bin/sh -c 'umask 0177; exec "$@"'`, preserving the
direct child PID without chmod repair. The observed socket is 0600. This machine's
inherited umask 0002 instead yields stock mode 0775, which is rejected; 0600 is not
an intrinsic go-plugin default. Both inherited/effective masks and actual mode are
reported. `stop` requests controller shutdown, then forcibly terminates and reaps
an uncooperative child within a bounded cleanup period.

A caller with the original test credential helper's PEM files can launch the
real plain-stock fixture through the same public API:

```dart
import 'dart:io';
import 'package:correlia_server/plugin.dart';

Future<void> main(List<String> args) async {
  // Arguments: plain-stock executable, client PEM, client key, journal path.
  final host = PluginHost(PluginHostConfig(
    executable: args[0],
    arguments: ['--journal', args[3]],
    identity: PluginClientIdentity(
      certificatePem: await File(args[1]).readAsBytes(),
      privateKeyPem: await File(args[2]).readAsBytes(),
    ),
  ));
  try {
    await host.start();
    await host.probe();
  } finally {
    await host.stop();
  }
}
```

Credential generation is test-only, not production certificate issuance.
The separate internal `createPluginHostForTesting` factory and
`PluginHostTestControls`/`PluginTlsTestControls` are not exported by `plugin.dart`
or exposed on its constructors/configuration. They select explicit plaintext
diagnostics (exactly 0600), negative umasks/identities/pins, failure-only native
ABI faults, real acquisition/allocator ports and a narrowed signature profile.
No library-replacement or successful-verifier injection is available. There is no
public `secure: false`, umask opt-out, advertised-certificate or trust override.

The pinned Dart built-in TLS engine still **fails** stock P-521 AutoMTLS: its
TLS 1.3 ClientHello omits signature scheme `0x0603`. The custom OpenSSL connector
has separately passed protected stock application RPC and authentication-negative
checks; it does not turn that built-in failure into a pass. See the
[observed evidence](../openspec/changes/plugin-host-spike/evidence/handshake-and-mtls.md).
ADR 0023 keeps D24 and the interpretation of ADR 0020 criterion 2 owner-only.
Neither runtime success nor explicit diagnostics grant production adoption.
The plain-stock fixture makes no host-death guarantee; only the distinct
stdin-watched fixture is intended to prove EOF-driven exit.

## Experimental acknowledged delivery

`PluginDelivery` is the sole owner of a surviving host's pending events and
outstanding batch map. Admission accepts validated `CloudEvent` objects and
reuses their cached immutable structured JSON bytes and derived event ids.
No second event codec, database queue or production supervisor is introduced.
`PluginDeliveryPolicy` validates positive limits:

| Budget | Default |
|---|---:|
| Pending events | 1,024 |
| Pending canonical bytes, including in-flight work | 16 MiB |
| Events per batch | 64 |
| Encoded protobuf request | 1 MiB |
| Outstanding batches | 4 |
| Acknowledgement-progress deadline | 10 seconds |

Available credits are derived from the current epoch's outstanding map, never
an independent counter. Partial batches flush at the end of available input;
`Deliver` opens only when nonempty work exists. Single-event fit reserves the
maximum sequence-header width so admitted bytes stay batchable as sequences
grow. Sequence exhaustion fails visibly and retains work for an explicit
restart rather than wrapping or reusing a sequence.

`admit` waits for count/byte capacity and returns a `PluginDeliveryReceipt`.
Its `acknowledged` future completes only on a valid whole-batch acknowledgement,
not on admission or sending. `PluginDeliveryCancellation` cancels a waiting
admission before ownership transfers; it does not retract admitted work.
`stop` rejects/wakes waiting admissions, errors remaining receipts and discards
the explicitly stopped owner's in-memory queue.

Wrong-epoch/unknown/repeated acknowledgements from the live stream fail that
generation without false completion or credits. Callbacks belonging to a
retired generation are fenced. The first terminal event retires its in-flight
map once; all unacknowledged canonical bytes remain pending. `whenFailed`
returns the cause; only an explicit `restart` creates a new host/epoch and
re-batches retained work. Failed startup/authentication on restart preserves
the same pending ids/bytes. An acknowledged event is never replayed by the owner.

The progress timer runs only while batches are outstanding and is renewed by
valid acknowledgements. There is no whole-stream gRPC deadline or idle timeout
when nothing is outstanding. A simple finite producer can fail promptly while
the separate observer/supervisor decides whether to restart:

```dart
import 'dart:async';
import 'package:correlia_server/event.dart';
import 'package:correlia_server/plugin.dart';

Future<void> sendEvents(
  Iterable<CloudEvent> events,
  PluginHostConfig Function(int attempt) configuration,
) async {
  final delivery = PluginDelivery(
    createHost: (attempt) => PluginHost(configuration(attempt)),
  );
  try {
    await delivery.start();
    final sending = () async {
      for (final event in events) {
        await delivery.admit(event);
      }
      await delivery.drain();
    }();
    await Future.any<void>([
      sending,
      delivery.whenFailed.then<void>((cause) => throw cause),
    ]);
  } finally {
    await delivery.stop();
  }
}
```

The fixture flushes and syncs its acceptance journal before acknowledging.
Its first-launch-only barrier applies to the first nonempty batch; restarts
omit the flag. A crash after recording and before acknowledgement permits
duplicates of that uncertain work. The proven guarantee is **at least once
while this Dart owner survives**, not exactly once or durability across host
death. The separate second-crash check proves acknowledged work is not replayed.
See the [delivery evidence](../openspec/changes/plugin-host-spike/evidence/stream-and-redelivery.md).

Resource-boundary checks also reject an oversized native plaintext source chunk
before any admission/network write; an exact 256 KiB chunk remains usable.
The journal is capped at 32 MiB, retains its accepted prefix on overflow and
rejects torn/invalid evidence. A 4 MiB stderr flood must reach its subsequent
malformed handshake with a bounded retained tail, not merely time out on a
blocked pipe. A separate post-handshake mode floods four MiB across stdout/stderr
before recording and acknowledging a canonical event, proving both output paths
drain during normal authenticated delivery. All runtime results here use stock
AutoMTLS.


## Schema validation and runtime validation

The generated payload schema is a build-time contract check. Ajv 8.17.1 with
`ajv-formats` 3.0.1 validates the committed positive and negative payload
fixtures using JSON Schema draft 2020-12. It covers required presence, scalar
and map bounds, timestamp formats, base64 bytes, numeric raw sizes and anchored
whole-value patterns.

Schema validity is necessary but not sufficient for accepting an event. The
runtime boundary must additionally enforce identity consistency, exact decoded
byte limits, aggregate serialized-size limits and JSON depth. Do not add a
runtime JSON Schema engine.

## First-run dependencies and offline reuse

Resolve workspace dependencies once with `mise exec -- flutter pub get`, and repeat that explicit
step after dependency changes. The analysis and check tasks use Flutter's `--no-pub` flag: they consume
that resolved workspace instead of refreshing pub dependencies or advisories during verification.
`doctor` inspects the resolved Serverpod CLI entry point with its machine-oriented `--version` flag,
without a package refresh or CLI update check.
The Serverpod generated-code check resolves its isolated workspace with offline pub, verifies the
lockfile versions, then executes that resolved CLI entry point directly. Pure code generation needs
no native assets; invoking `dart run` there would otherwise download unrelated transitive CLI native
libraries into every disposable workspace. No generator, comparison, or drift check is skipped.

`mise run proto`, `mise run proto:check` and `mise run check` depend on
`proto:setup`. It runs the locked npm installation with the prefer-offline,
no-script, no-audit and no-fund flags:

```sh
npm ci --prefix tool/schema_validation --prefer-offline --ignore-scripts --no-audit --no-fund
```

The first run may contact the npm registry, the Go module proxy and checksum
database for the pinned JSON Schema generator, the Buf Schema Registry for the
locked standard annotations, and pub for Dart dependencies. After those caches
are warm, generation and checking require no network access. The Node modules
are build-time only and live in the ignored
`tool/schema_validation/node_modules/` directory.

For a deliberately disconnected Linux check, use Go's documented
[filesystem module proxy](https://go.dev/ref/mod#environment-variables) over the warmed download cache:

```sh
GOPROXY="file://$(mise exec -- go env GOMODCACHE)/cache/download" \
  mise exec -- unshare --user --map-current-user --keep-caps --net -- \
  sh -c 'ip link set lo up && exec mise run check'
```

Unlike `GOPROXY=off`, this supplies cached version/deprecation metadata required by versioned `go run`.
Checksum verification remains enabled. Missing cached dependencies fail rather than reaching a network
fallback. The private network namespace has only loopback enabled for the Flutter test harness's
local WebSocket IPC; it has no external interface or route. External network access is disabled for
the complete gate, not just the generators.

A checkout can invalidate generated pub resolution metadata without changing lockfile bytes. If SDK
bootstrap still attempts an advisory refresh, remove only the generated `.dart_tool/package_config.json`,
then run `mise exec -- dart pub get --offline` from the workspace root. Rebuilding this cache resolved
the pinned SDK's bootstrap failure during the clean-workspace proof; it did not change package mappings
or dependency versions. Do not alter the committed lockfile or bypass test execution to obtain a pass.
