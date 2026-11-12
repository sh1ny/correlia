## Unreleased

- Add authenticated production output plugin connections with ephemeral in-memory identities,
  separated configuration secrets, bounded batch credits, per-event results and health deadlines.

- Add bounded authenticated Alertmanager webhook-v4 ingress with credential-safe session-independent
  routing, exact raw storage and atomic non-sliding transport deduplication.
- Publish immutable bootstrap revisions and source credentials transactionally; keep signing material
  in owner-only local files and retain historical key commitments for pending output work.
- Initialize SQL-owned composite-key inbox/event/outbox tables after managed migrations on every role.
  Pin configuration before processing and atomically commit event, observation-key and routed intent
  outcomes, including quarantine, late, duplicate and explicitly unrouted evidence.
- Deliver exact structured CloudEvents through independent signed webhook relays with fenced leases,
  durable attempts, finite retries/dead letters and at-least-once crash recovery.
- Gate admission on startup, compose api/worker/all ownership and stop acquisition/HTTP before database
  shutdown. Document 1 MiB ingress, 1,000-alert/16 MiB batch bounds, no automatic retention/replay and the
  later alert-state/live-console/NATS milestone boundary in `docs/ingest-pipeline.md`.
- Add deterministic v1 alert fingerprints, observation UUIDv5 and source-scoped transport keys.
  Preserve original nanosecond timestamp evidence, bound identity work, and publish independent
  vectors in `contracts/identity-vectors.json`. These pure helpers apply no durable dedup/state effects.
- Add immutable canonical payload values and strict protobuf/JSON codecs through `package:correlia_server/event.dart`.
  Validate CloudEvents agreement, nanosecond timestamps, identity evidence, aggregate size, and Unicode
  before acceptance. Preserve native unknown protobuf fields while reporting exact, known-core-only,
  or unknown validation scope; JSON output is the current-minor known-field projection.
- Publish complete positive, negative, and synthetic newer-minor wire fixtures with payload-only
  JSON Schema cross-checks in `contracts/runtime-fixtures/` and `contracts/envelope-fixtures/`.
- Reject overflowing binary int32/uint32 wire values before protobuf narrowing can turn them into
  valid raw metadata, generations, enums, or timestamp nanos.
- Count only non-null CloudEvents extension attributes against the 32-attribute allowance.
- Reject varints wider than 64 bits before Int64 conversion, retaining aligned decoding and native
  unknown-field handling across every wire type.

## 1.0.0

- Initial version, created by Stagehand
