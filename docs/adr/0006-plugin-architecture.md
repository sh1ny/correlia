# 0006. Hybrid plugin model: built-ins in process, external plugins over gRPC (go-plugin style)

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: none

## Context

The owner wants plugins "the way Terraform does with Go": standalone executables in any language, launched
by the main process and spoken to over gRPC, so the integration catalog can keep growing (`docs/plan/integrations.md`). The owner also decided that first-party integrations ship built in, behind the same
interface.

The legacy audit (lesson P2.1) warned against a speculative plugin framework. That warning held for one
source and one output, but v1 already needs Icinga2, Alertmanager/Thanos, a generic webhook and NATS.

## Decision

- **One Dart interface per plugin kind:**
  - **Source:** push or pull raw input.
  - **Decoder:** raw input → events.
  - **Enricher:** events → patches.
  - **Output:** events or incident notifications → an external system.

  Correlation, identity/severity/status normalization and classification stay in the core.
- **Built-in plugins** implement the interface in process. **External plugins** run as child processes
  behind an adapter that implements the same interface over gRPC.
- **Handshake:** compatible with HashiCorp go-plugin, so Go plugins can use stock `plugin.Serve()`:
  - magic-cookie env var;
  - protocol version negotiation;
  - one stdout handshake line;
  - AutoMTLS;
  - gRPC health service `plugin`;
  - `Shutdown` controller;
  - JSON logs on stderr.

  The go-plugin broker is not used.
- **Correlia plugin protocol v1** (protobuf, versioned as in ADR 0004):
  - `GetMetadata`: kinds, version, capabilities, and the JSON Schema of the plugin config.
  - `Configure`, `CheckHealth`, `GetStats`.
  - Batched bidirectional streams with acks and a credit window, for outputs and sources.
  - Enrichers return patches, which may not change the id, fingerprint or status.
- **Supervision:**
  - start timeout and health checks;
  - restart with backoff;
  - a circuit breaker, with a `degraded` state shown in the console;
  - plugins exit when stdin closes, so they never outlive the host.
- **Distribution:** plugins are installed from a local directory, and a lock file records a sha256 per
  OS/arch. A public registry is out of scope for 1.0.

Rejected:
- WebAssembly plugins: no mature Dart host with the component model, and outputs need network access.
- NATS as the plugin bus: it would make NATS mandatory.

Reversal cost: medium. The in-process interface is the stable contract, and the transport behind it can
change.

## Consequences

- Every integration, built-in or external, has the same config schema, health and stats surface in the
  console.
- Plugin SDKs are needed per language: Go first (via go-plugin), then Python, then others.
- **Spike gate (first change of the plugin work in M1).** The walking skeleton depends on it, so it has
  explicit pass criteria:
  1. A Dart host completes the handshake with an unmodified Go plugin built on stock `plugin.Serve()`.
  2. AutoMTLS works both ways: P-521 certificates, client certificate presented by grpc-dart.
  3. A batched stream with credits delivers 10k events and survives a plugin crash with redelivery.
  4. Killing the host (kill -9 / task kill) leaves no plugin process on Linux and on Windows (process group
     / job object, plus exit on stdin close).

  If 2 fails, the fallback is TCP loopback (or a Unix socket) with a per-launch random token checked by an
  interceptor, which breaks stock go-plugin compatibility; if 4 fails on Windows, plugins on Windows are
  dev-only. Either fallback is an owner decision recorded as a superseding ADR, never taken silently.
