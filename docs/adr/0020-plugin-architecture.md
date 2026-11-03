# 0020. Hybrid plugin model: built-ins in process, external plugins over gRPC (go-plugin style)

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: [0015](0015-plugin-architecture-linux.md)

## Context

This ADR restates ADR 0015 (itself ADR 0006 without its Windows parts; Linux is the supported platform,
ADR 0014) with the corrections of the 2026-11-03 design review to the spike gate:
- **Criterion 4** cannot pass with a stock go-plugin plugin: a host killed with kill -9 signals nothing to
  its children, and stock plugins do not watch stdin. It is now tested against a Go plugin that wraps stock
  `plugin.Serve()` with a small stdin watcher, as the first-party NATS plugin does (ADR 0018).
- **The criterion 2 fallback** is now a 0600 Unix socket without AutoMTLS, which stock plugins support. The
  earlier token-interceptor fallback broke stock compatibility.
- **D24 (transport):** stock go-plugin chooses the listener on the plugin side and uses a Unix socket on
  every OS but Windows, so TCP loopback would require modified plugins.

Everything else is unchanged from ADR 0015.

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
  - the host keeps each plugin's stdin open and never writes to it. Plugins built with Correlia's SDKs, and
    first-party Go plugins (a stdin watcher around stock `plugin.Serve()`), exit when it closes, so they
    never outlive the host. A third-party stock go-plugin plugin does not watch stdin and can outlive a
    host killed with kill -9.
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
  4. Killing the host with kill -9 leaves no plugin process on Linux, for a Go plugin that wraps stock
     `plugin.Serve()` with the stdin watcher of ADR 0018: the test plugin in `plugin-host-spike`, and the
     NATS plugin itself in `output-nats-plugin`. Criterion 1 still uses a plain stock `plugin.Serve()`
     plugin for the handshake. A process group does not help here: nothing signals the group when the host
     is killed.

  If 2 fails, the fallback on Linux is a Unix socket with mode 0600 and AutoMTLS off. go-plugin's TLS is
  optional, so stock plugins stay compatible, and the socket mode limits access to the owner. If 4 fails,
  the cause and a fix are an owner decision. Any fallback is an owner decision recorded as a superseding
  ADR, never taken silently.
- **Transport (D24):** stock go-plugin picks the listener on the plugin side and uses a Unix socket on every
  OS but Windows (a 0600 socket file under `PLUGIN_UNIX_SOCKET_DIR`), so TCP loopback would require
  modifying plugins. Recommendation: a Unix socket. The owner confirms it in the `plugin-host-spike`
  change.
