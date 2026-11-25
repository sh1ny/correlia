## Unreleased

- Add versioned matcher rules for event enrichment and routing. Live upgrades are unsupported:
  stop intake, drain pending inbox work and the outbox manually, then stop Correlia before upgrading.
- Add authenticated production output plugin connections with ephemeral in-memory identities,
  separated configuration secrets, bounded batch credits, per-event results and health deadlines.
- Supervise pinned plugin definitions with verified launches, durable crash budgets, fair bounded
  worker slots, readiness-gated delivery and persisted heartbeat and circuit status.
- Add the first-party NATS JetStream output with acknowledged, deduplicated publishes, exact
  CloudEvents bodies and headers, operator-owned stream validation and secret-only authentication.
  Document local tooling, configuration and supervision in `docs/runbooks/output-nats.md`.
- Do not send a new plugin batch after relay shutdown starts, even when its claim was in progress;
  retain unsent started claims for normal lease recovery.
- Preserve held delivery permits while voluntarily retiring a plugin; refuse new acquisitions
  without turning committed work into spurious retries, and still invalidate on observed failure.
- Retain plugin intents larger than their negotiated batch limit as dead with `payload_too_large`,
  without a transport attempt, so they cannot stall later fitting work.
- Preserve live workers' crash history during cross-host pruning, retaining stopped status anchors
  until owner-local health cleanup or the 24-hour cross-host expiry.

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
  shutdown. Document 1 MiB ingress, 1,000-alert/16 MiB batch bounds and the lack of automatic
  retention/replay in `docs/ingest-pipeline.md`.
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
