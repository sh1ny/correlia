# Proposal

## Why

M1's walking skeleton depends on a Dart host interoperating with stock HashiCorp go-plugin before the NATS output is built. This change proves ADR 0020's four Linux spike criteria: handshake, bidirectional AutoMTLS, 10,000-event credit-controlled crash/redelivery, and stdin-EOF child exit after host SIGKILL. The real Alertmanager/console/NATS user demo remains judged at M1 close: this spike has neither ingest nor NATS.

## What Changes

- Add a bounded Dart subprocess host and a Correlia-owned output-stream probe, exercised against a Go fixture using the unmodified go-plugin library.
- Use distinct plain-stock and stdin-watched fixture entry points so handshake compatibility is not confused with orphan prevention.
- Generate only the protobuf/gRPC surface needed for the experiment, reuse canonical event bytes, and keep the probe explicitly experimental rather than publishing a complete plugin SDK.
- Add deterministic `plugin`-tier process tests and committed evidence for each gate, including security-negative checks and exact event reconciliation after a controlled crash.
- Stop for an owner decision on any failed gate; never silently disable AutoMTLS or change transport. Record D24 transport confirmation as an owner task before completion.

## Capabilities

### New Capabilities

- `external-plugin-host`: go-plugin-compatible subprocess startup, authenticated local gRPC, bounded output streaming and lifecycle guarantees.

### Modified Capabilities

None. Existing canonical-event and workspace-tooling contracts are reused unchanged; generation integration must preserve their gates.

## Impact

Proposed additions: `correlia_server/lib/src/plugin/`, a `plugin.dart` entry point, `correlia_server/test/plugin/` and its process fixtures, `proto/correlia/plugin/`, and a small pinned Go fixture module. Tooling changes integrate Go/Dart generation without changing the frozen event-v1.0 baseline. No database, Serverpod endpoints, console, NATS dependency, source/decoder/enricher APIs, plugin registry, production restart policy or status persistence is added.

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

- **Choice:** Attempt AutoMTLS over stock Linux Unix sockets; require owner D24 confirmation before marking this change complete. Any failed criterion blocks completion pending owner disposition and, for a fallback, a superseding ADR.
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
