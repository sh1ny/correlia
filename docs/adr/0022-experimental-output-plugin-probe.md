# 0022. Experimental output plugin probe: unstable namespace, gate scope and evidence

- Status: accepted (2026-11-11)
- Date: 2026-11-11
- Supersedes: none; adds precision to [0020](0020-plugin-architecture.md) without changing it
- Chosen by: agent; the transport confirmation and any fallback stay owner-only and are not granted here

## Context

ADR 0020 defines the hybrid plugin model and a spike gate with four Linux criteria. That gate runs before
the production plugin work and before the NATS output plugin, and it needs a wire contract that carries
real canonical events between a Dart host and a stock Go plugin.

Publishing the complete `correlia.plugin.v1` protocol now would freeze decisions no gate needs: source,
decoder, enricher, config, metadata and patch semantics, plus the supervision surface that the output-NATS
change owns. Sending only counters would prove nothing about event interoperability. So the gate needs its
own small contract, and the repository needs a record of what that contract is and is not, so that later
work cannot mistake it for the stable plugin SDK.

Two questions stay with the owner and are not settled by a spike: D24, the production transport choice, and
the fallback that ADR 0020 allows if mutual TLS fails. This ADR records the probe boundary and the
evidence rules; it grants neither.

## Decision

### An unstable, output-only probe namespace

`correlia.plugin.spike.v1` is a Correlia-owned protobuf namespace under `proto/correlia/plugin/spike/v1/`.
It is a gate probe, not the stable SDK.

- **Output-only.** One bidirectional `Deliver` RPC carries batches of `(event_id, canonical structured-JSON
  bytes)` and whole-batch acknowledgements carrying a connection epoch and a batch sequence. No source,
  decoder, enricher, config, metadata or patch surface is defined. `correlia.plugin.v1` remains the
  production target and is not implemented by this probe.
- **Unstable.** The namespace carries no compatibility promise. Service and message names, field numbers,
  the epoch and sequence scheme and the acknowledgement semantics may change or disappear without a
  deprecation window. It does not establish the eventual `correlia.plugin.v1` contract.
- **Acknowledgement shape.** An acknowledgement means the whole batch was accepted; there are no partial
  outcomes. Epochs change per connection and sequences never repeat within an epoch. A stale callback is
  fenced out by epoch; an unknown or repeated current-epoch acknowledgement fails the connection.
- **Not a delivery system.** The probe has no durable queue, no plugin registry, no lock file, no status
  persistence and no restart policy. Its lifetime ends with the spike.

### The four ADR 0020 criteria, reported independently

The probe exists to retire ADR 0020's four Linux criteria, unchanged:

1. a Dart host completes the handshake with an unmodified Go plugin built on stock `plugin.Serve()`;
2. AutoMTLS works both ways, with P-521 certificates and the client certificate presented by grpc-dart;
3. a batched stream with credits delivers 10,000 events and survives a plugin crash with redelivery;
4. killing the host with `kill -9` leaves no plugin process on Linux, for a Go plugin that wraps stock
   `plugin.Serve()` with the stdin watcher of ADR 0018.

Each criterion is reported separately, with its command, Linux and tool versions, result, failure cause and
security mode. A failed criterion is reported as failed. It is not narrowed, re-scoped or marked passed by
another criterion or by a diagnostic run, and handshake evidence survives a TLS failure.

### Stock compatibility is the point

- go-plugin is pinned, unmodified, at v1.8.0 in a fixture Go module with checksums: no fork, no patch, no
  vendored upstream source. Criterion 1 uses a plain stock `plugin.Serve()` entry point; criterion 4 uses a
  separate entry point that wraps the same stock serving with the stdin watcher. The probe proves the
  unmodified handshake, not a Correlia-forked one.
- The upstream go-plugin interoperability methods are described by hand-written Dart descriptors kept
  outside the Buf module. No upstream `.proto`, schema or template is copied into this repository; the
  linted `proto` module holds only Correlia-owned definitions.
- The `correlia.event.v1` contract, its frozen v1.0 baseline and its generation stages stay unchanged. The
  probe reuses already validated canonical events; it never extends the event schema, and the event
  generation inputs stay event-only.

### The credential helper is test-only and ephemeral

The mutual-TLS evidence needs a host client identity. A small Go standard-library test helper generates an
ephemeral P-521 host credential into owner-only scratch, restricted to the current uid and to the lifetime
of one attempt, and destroys it afterwards.

- It is not a production certificate dependency and not a certificate-issuance design. It proves that Dart
  can load an identity-bearing security context, pin a peer certificate and complete an authenticated RPC.
  It makes no claim about production Dart certificate issuance, which belongs to the real plugin
  integration.
- No private key is committed, and no credential is reused across attempts.
- Trust is exact, never permissive: the handshake's unpadded standard-base64 DER certificate is PEM-wrapped
  and loaded with `withTrustedRoots: false`, the authority is `localhost`, and there is no accept-all
  callback. An untrusted server, a missing or wrong client identity, or a runtime that cannot use the
  required P-521 certificates fails visibly.
- A failed authentication never triggers a plaintext retry.

### Immutable canonical bytes cross the boundary

The probe carries canonical event bytes, not a re-serialized event.

- A batch entry is an event id plus the canonical structured-JSON bytes of an already validated canonical
  event (ADR 0021). The bytes are frozen on admission and never re-encoded: a re-batch or a restart after
  a plugin crash re-delivers byte-identical bytes under the same event id, and no id is ever associated
  with changed bytes.
- Ids are validated against the canonical envelope before admission, so a batch never carries an id its
  bytes do not support.
- Acknowledgement is whole-batch, and the receiver records whole batches before acknowledging. A batch
  recorded but not acknowledged can be delivered again, which is why the guarantee is at-least-once.

### Bounded, at-least-once, surviving-host-only pending work

- The authoritative pending set lives in the surviving host process, in memory. Admission is bounded to
  1,024 events and 16 MiB; batches carry at most 64 events and 1 MiB; at most 4 batches are outstanding; a
  10 s acknowledgement-progress deadline applies while work is outstanding; gRPC messages are capped at
  2 MiB.
- The delivery owner is the sole writer of the pending set and the in-flight map. On a plugin crash or a
  restart that cannot become ready, the outstanding batches return to pending exactly once and are
  re-delivered byte-identically under a fresh epoch. Acknowledged work is never replayed.
- The guarantee is at-least-once within the surviving host's lifetime. It is not exactly-once and it is not
  durable: pending work does not survive the host's death, and no durable queue, outbox or database queue
  is part of this probe. Durable delivery across host death belongs to the ingest and output changes.

### Transport and fallback stay owner decisions

- D24, the production transport choice of ADR 0020, is not settled by the probe. The listener and socket
  mode that stock go-plugin actually uses are recorded as evidence. A stock mode that differs from ADR
  0020's exact 0600 wording is escalated to the owner, not chmodded, repaired or worked around by
  modifying the plugin.
- The probe may run an explicitly selected diagnostic mode, a 0600 socket without AutoMTLS, to gather
  criteria 3 and 4 evidence after criterion 2 fails. That mode is test-only, is recorded with the results
  it produced, and never counts as adopting ADR 0020's fallback.
- Any fallback or transport change is an owner decision recorded in a superseding ADR, with renewed review
  before adoption. Neither a failed gate, nor a diagnostic run, nor this ADR grants one.
- ADR 0020's criteria and fallback wording stay in force unchanged. This decision is additive.

## Consequences

- The spike can prove the process and transport boundary without publishing a plugin SDK, and the
  repository states plainly what the probe namespace is and is not.
- Because the namespace is unstable, downstream work must not depend on it; the production plugin protocol
  remains `correlia.plugin.v1` under ADR 0020.
- The evidence separates the handshake, mutual TLS, crash redelivery and child-exit criteria instead of
  collapsing them into one verdict.
- The credential helper answers a feasibility question only. Production certificate issuance stays a
  decision of the real plugin integration.
- The delivery guarantee is bounded and host-scoped. Durable delivery, supervision, status persistence and
  plugin distribution remain out of scope here.
- A failed gate pauses dependent plugin work for owner disposition, and the D24 confirmation remains an
  owner task.
- Accepted ADRs remain unchanged; this ADR records the additive probe boundary.
