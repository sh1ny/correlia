# Proposal

## Why

M1's walking skeleton depends on a Dart host interoperating with stock HashiCorp go-plugin before the NATS output is built. This change proves ADR 0020's four Linux spike criteria: handshake, bidirectional AutoMTLS, 10,000-event credit-controlled crash/redelivery, and stdin-EOF child exit after host SIGKILL. The real Alertmanager/console/NATS user demo remains judged at M1 close: this spike has neither ingest nor NATS.

## What Changes

- Add a bounded Dart subprocess host and a Correlia-owned output-stream probe, exercised against a Go fixture using the unmodified go-plugin library.
- Use distinct plain-stock and stdin-watched fixture entry points so handshake compatibility is not confused with orphan prevention.
- Use an in-process, OpenSSL-backed Dart gRPC transport for stock P-521 AutoMTLS; retain mutual certificate verification, exact server pinning and Unix sockets, without a Go proxy or external TLS bridge.
- Generate only the protobuf/gRPC surface needed for the experiment, reuse canonical event bytes, and keep the probe explicitly experimental rather than publishing a complete plugin SDK.
- Add deterministic `plugin`-tier process tests and committed evidence for each gate, including security-negative checks and exact event reconciliation after a controlled crash.
- Stop for an owner decision on any failed gate; never silently disable AutoMTLS or change transport. Record D24 transport confirmation as an owner task before completion.

## Capabilities

### New Capabilities

- `external-plugin-host`: go-plugin-compatible subprocess startup, authenticated local gRPC, bounded output streaming and lifecycle guarantees.

### Modified Capabilities

None. Existing canonical-event and workspace-tooling contracts are reused unchanged; generation integration must preserve their gates.

## Impact

Additions: `correlia_server/lib/src/plugin/`, a `plugin.dart` entry point, `correlia_server/test/plugin/` and its process fixtures, `proto/correlia/plugin/`, and a small pinned Go fixture module. The authenticated Dart connector uses `ffi` 2.2.0 and the system OpenSSL 3 ABI (`libssl.so.3`, `libcrypto.so.3`), with an explicit runtime dependency rather than bundled third-party source. Plugin-tier native-allocation verification additionally needs a system C compiler and OpenSSL development headers for an original isolated test counter; neither is a production runtime dependency. A new ADR restates and supersedes all of ADR 0022, changing its TLS mechanism and explicitly routing the criterion-2 interpretation to owner review. Tooling changes integrate Go/Dart generation without changing the frozen event-v1.0 baseline. No database, Serverpod endpoints, console, NATS dependency, source/decoder/enricher APIs, plugin registry, production restart policy or status persistence is added.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Prove the four gates, not the entire plugin platform

- **Choice:** A real process/transport spike with a minimal output contract and reproducible evidence; production supervision stays in `output-nats-plugin`.
- **Rejected:** Full SDK and all plugin-kind interfaces now; they do not help retire the named risks.
- **Reversal cost:** low; experimental output types remain explicitly unstable.
- **Important:** yes — binds a boundary, so the experimental scope must be explicit.
- **Chosen by:** agent

### S2: Preserve the accepted security and owner gates

- **Choice:** Attempt AutoMTLS over stock Linux Unix sockets. Require owner D24 confirmation and review of ADR 0020 criterion 2 being satisfied through grpc-dart's in-process OpenSSL custom connector before marking the change adopted or complete. Preserve the built-in TLS failure separately from custom-connector results. Any failed criterion blocks completion pending owner disposition and, for a security fallback, a superseding ADR.
- **Rejected:** Silent plaintext fallback or modified go-plugin listener/certificate generation, which would invalidate the gate.
- **Reversal cost:** medium.
- **Important:** yes — security boundary and weak runtime evidence.
- **Chosen by:** agent

### S3: Separate crash redelivery from database durability

- **Choice:** Keep the authoritative pending set in the surviving spike host and exercise plugin crash/restart. Prove host-crash child exit separately; production outbox durability belongs to ingest/NATS changes.
- **Rejected:** Claiming in-memory redelivery proves durable delivery after host death; adding a speculative database queue here.
- **Reversal cost:** low.
- **Important:** yes — defines the failure guarantee demonstrated.
- **Chosen by:** agent

## Release Notes

Add the experimental output probe, reproducible fixture/generation foundation,
authenticated Linux subprocess startup, bounded acknowledged delivery with
surviving-host crash recovery, direct-host lifetime proof and independent
four-criterion evidence. Runtime passes do not approve owner-gated adoption.

### Added

- Experimental output-only protobuf/gRPC probe, isolated Dart/Go generation and
  generated drift checks, without changing the canonical-event baseline.
- ADR 0023 supersedes the whole experimental-probe ADR 0022, retaining the
  unstable protocol boundary and owner-only transport, fallback and custom
  connector interpretation decisions.
- Stock and stdin-watched Go fixtures, ephemeral P-521 credentials, bounded
  acceptance journal/control barriers, and suite-owned exact-process cleanup.
- Authenticated-only Dart host API using stock go-plugin AutoMTLS over Unix
  sockets, exact certificate pinning and TLS 1.3 through system OpenSSL 3
  (`libssl.so.3`, `libcrypto.so.3`) and `ffi` 2.2.0, without a proxy or downgrade.
- Bounded native/socket ownership, observed TLS/configuration evidence and
  real-process security, backpressure, deadline and allocation verification.
  C compiler/OpenSSL headers are test-only dependencies; shared libraries are
  runtime dependencies. Runtime success does not approve production adoption.
- Immutable count/byte-bounded canonical admission, derived batch credits,
  epoch/sequence acknowledgement validation, cancellation and progress deadlines
  without a whole-stream timeout.
- Explicit restart retaining unacknowledged bytes, with real 10,000-event
  id/digest reconciliation and a second-crash no-acknowledged-replay check.
  This is at-least-once delivery while the host survives, not host-crash durability.
- Direct-Dart-host SIGKILL/EOF-cause proof with exact process identities, pidfd
  exit observation before teardown, and real normal/forced shutdown reaping.
  The host-death guarantee belongs only to the original watched fixture.
- Reproducible independent gate reports preserve real capability failures and
  partial handshake facts; explicitly selected 0600 plaintext diagnostics remain
  distinct from native TLS and never grant fallback or production approval.
- A concurrent terminal stop fails a waiting delivery drain; clearing discarded
  pending work can no longer be mistaken for acknowledged completion.
