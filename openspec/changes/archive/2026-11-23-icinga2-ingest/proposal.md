# Proposal

## Why

M2 (Icinga2, Thanos and the ingest track) exists to bring the owner's two real sources in and to retire the
risk that real Icinga2 payloads (soft and hard states, flapping, acknowledgements, downtimes) do not fit the
canonical event and identity model. M1 and `source-model-and-secrets` built the source model, the durable
pipeline and the ordering fence, but only Alertmanager can feed them: there is no Icinga2 decoder and the
pipeline decodes every row as Alertmanager. This is change 2 of M2, after `source-model-and-secrets` (done),
on which it builds.

Three design-review rounds showed that the Event Streams consumer and state sync carry most of the risk
(leasing, backpressure into Icinga 2, reconciliation ordering when Icinga 2 accepts results with regressing
execution times). The owner split them into a new change, `icinga2-event-streams` (S2), so this change brings
Icinga2 in through the webhook path first and fixes the mapping, identity and ordering rules that the stream
will reuse.

It advances these M2 exit criteria:

- "Golden fixtures for Icinga2 (webhook and Event Streams) … pass. Fixtures are captured from real releases"
  (agent): the webhook half, captured from official Icinga 2 release images by a committed capture script.
  The Event Streams half is `icinga2-event-streams`.
- "Scenarios ORD-4, ORD-6, ORD-7, ID-7 (a) … pass as named tests" (agent). ID-3 is re-proven with Icinga2's
  host name and check output, as `source-model-and-secrets` S3 planned.
- The user-verified criterion (the owner's real Icinga2 and Alertmanager/Thanos feeding a dev instance for a
  day) is not checked here: it needs Thanos and the enrichment changes, so it is judged at the M2 close. This
  change documents the Icinga2 webhook setup the owner can use for it.

## What Changes

- **New source kind `icinga2`** in the bootstrap configuration (format version 2), with no kind-specific
  options. A source's kind can no longer change once published (`kind_changed`), so an accepted delivery whose pinned
  snapshot configures its source decodes with the kind it was admitted under.
- **Icinga2 webhook path.** Icinga 2 has no built-in webhook; Correlia ships a notification command (a compiled
  sender, `correlia-icinga2-notify`, plus the Icinga 2 `NotificationCommand` definitions) that posts a documented, versioned JSON document to
  `/hooks/icinga2/<source>`, authenticated by bearer or HMAC as any source. The document reports the object's
  state when the command runs, with the last state change time at sub-second precision. The webhook converges
  on Icinga 2's state only under stated conditions (coherent, eligible and unclamped deliveries; strictly
  increasing state change times); otherwise an alert can stay stale until a later eligible observation
  outranks it. Path tokens stay Alertmanager-only. Icinga 2 does not retry a failed
  notification command and sends none for SOFT states or while notifications are suppressed, so a webhook-only
  source can miss changes; the documentation says so.
- **Decoder dispatch by source kind.** The pipeline decodes a raw row with its pinned source's kind instead
  of always as Alertmanager.
- **Mapping.** Identity is namespace, kind `icinga2`, host and optional service (ADR 0024). Host UP and
  service OK resolve; host DOWN and UNREACHABLE and service CRITICAL are `critical`, WARNING `warning`,
  UNKNOWN `unknown`. Severity is not identity, so a WARNING to CRITICAL change updates one alert (ID-7 a).
  Acknowledgement, downtime, flapping and custom notifications become `ack`, `downtime`, `state` and `comment`
  events with status `info`: stored and routed to outputs, with no alert-state effect until noise control (M5).
- **SOFT states are informational on the webhook.** A SOFT problem (sampled only by a delayed notification) is
  an `info` state event with no alert effect; an OK/UP state always resolves. A per-source soft/hard policy
  needs a feed that reports SOFT transitions and their recoveries, so it moves to `icinga2-event-streams`.
- **Ordering scenarios.** ORD-4 (a future source time beyond the skew limit is clamped for ordering, and the
  clamp is recorded on the stored event and counted), ORD-6 (a late firing after the alert resolved and its
  events and observation keys are gone stays `late` and the fence holds) and ORD-7 (freshness in any
  processing order, including concurrent transactions) as named tests.
- **Golden fixtures** captured through the shipped command from official Icinga 2 release images, with the
  capture script and a supported-release statement; a version-matrix test decodes every capture.
- **Roadmap amendment.** M2 gains change 3, `icinga2-event-streams`; the later M2 changes move down one.

## Capabilities

### New Capabilities

- `integration-icinga2`: the Icinga2 webhook contract and shipped notification command, the decoder mapping
  (identity, status, severity, observation key, event kinds, display bounds), SOFT states as information, the
  webhook convergence contract, and the supported releases with their captured fixtures.

### Modified Capabilities

- `source-ingress`: the `icinga2` source kind in configuration format version 2; the `/hooks/icinga2/<source>`
  route; a source's kind is immutable.
- `durable-pipeline`: rows decode by their source's kind; a clamped effective source time is recorded on the
  stored event and counted on the raw outcome (ORD-4).
- `alert-state`: named scenarios for ORD-6 (late firing after the resolved alert's events and keys expired)
  and ORD-7 (freshness under any order and concurrent transactions).

## Impact

- Server: a new `correlia_server/lib/src/ingest/icinga2/` (webhook parser and mapper), the bootstrap parser
  and source model, the pipeline's decoder dispatch and outcome counters, one Correlia schema step (event
  clamp column, catalog-only, no row rewrite). No managed migration. The upgrade is offline: every older process, of every role,
  stops before any process of this release starts; pending rows wait and resume.
- Operator interface: the `icinga2` source kind; `docs/ingest-pipeline.md` gains an
  Icinga2 section; `contrib/icinga2/` holds the command definitions; a new package `correlia_icinga2_notify/` builds the
  compiled sender for linux-x64 and linux-arm64 (`mise run build:icinga2-notify`); a capture script
  in `tool/`.
- Outputs see new event types `io.correlia.ack.v1`, `io.correlia.downtime.v1`, `io.correlia.state.v1` and
  `io.correlia.comment.v1` (already defined by the canonical event contract, not produced before).
- `openspec/roadmap.md`: M2 change list amended (S2). `docs/plan/acceptance-scenarios.md`: the ORD-4 row is
  aligned with ADR 0017 (the clamp orders; expiry and windows use observed time).
- No change to the canonical event format, to identity bytes of Alertmanager sources, or to the console.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: The webhook contract is Correlia's own, sent by a shipped notification command

- **Choice:** Define a versioned Correlia JSON document for Icinga 2 notifications, built from runtime
  macros and runtime functions, and ship a compiled Dart sender and the `NotificationCommand`s that run it (D3;
  the owner chose the compiled sender over a shell script on 2026-11-19, after design review round 13).
  Fixtures are captured from a real Icinga 2 running that command.
- **Rejected:** Accept "native Icinga 2 webhooks" (Icinga 2 has none; every webhook is a user script);
  the legacy custom contract (it dropped numeric states and sub-second times, which identity needs).
- **Reversal cost:** medium (senders deploy the binary and command definitions).
- **Important:** yes — binds a sender-facing contract.
- **Chosen by:** agent

### S2: The Event Streams consumer and state sync move to a new change, `icinga2-event-streams`

- **Choice:** This change delivers the webhook path, the mapping and the ordering scenarios. A new M2 change 3,
  `icinga2-event-streams` (needs this change), delivers the Event Streams consumer, its lease and
  backpressure, state sync on connect, the current-state reconciliation rule, the stream secrets, the per-source
  soft/hard policy (S3) and the Event Streams fixtures. Design review rounds 1-3 of this change, and their
  findings, are its starting input.
- **Rejected:** A fourth review round on the full scope (three rounds kept finding ordering and resource
  problems in the consumer); proceeding with open findings.
- **Reversal cost:** low (the roadmap list changes; no code yet).
- **Important:** yes — changes the roadmap's change list.
- **Chosen by:** user (owner, 2026-11-19, after the round 3 escalation: "Split the change")

### S3: SOFT problems are informational on the webhook; the soft/hard policy moves to the stream change

- **Choice:** A webhook delivery with a SOFT non-OK state is kept as an `info` state event; OK/UP resolves
  whatever its state type. The per-source `state_type_policy` (`hard_only` default, `soft_and_hard`) is
  specified with `icinga2-event-streams`, whose feed reports SOFT transitions and their recoveries, together
  with which revision's policy owns an observation (round 4 Critical 5).
- **Rejected:** A `soft_and_hard` policy on the webhook (Icinga 2 sends no recovery notification for a SOFT
  problem, so a SOFT problem sampled by a delayed notification would fire forever); dropping SOFT deliveries
  (loses evidence operators want to see).
- **Reversal cost:** low.
- **Important:** yes — changes behaviour users see, and moves an option the roadmap lists for M2 into change 3.
- **Chosen by:** agent

### S4: Acknowledgements, downtimes and flapping are published but do not change alert state yet

- **Choice:** Emit them as `ack`, `downtime` and `state` events with status `info` (custom notifications as
  `comment`), carrying the object's fingerprint, and route them to outputs. Suppression and maintenance are M5.
- **Rejected:** Drop them until M5 (the roadmap lists them for M2, and consumers can use them now); change
  alert state now (pre-empts M5's silence and maintenance model).
- **Reversal cost:** low.
- **Important:** yes — changes what outputs receive.
- **Chosen by:** agent

### S5: ORD-4, ORD-6 and ORD-7 are proven pipeline-wide in this change

- **Choice:** The skew clamp, lateness horizon and fence already exist from M1; this change records the clamp
  (ORD-4's missing part) and proves all three with named tests that use Icinga2 events, without
  Icinga-specific ordering rules. ORD-6 removes the resolved alert's event rows and keys directly, because
  retention arrives in `dead-letters-backpressure-and-retention`.
- **Rejected:** Defer ORD-6 to the retention change (the roadmap places it here, and the fence does not depend
  on how rows expire).
- **Reversal cost:** low.
- **Important:** no.
- **Chosen by:** agent

### S6: Supported releases are the official Icinga 2 images the capture script can run

- **Choice:** Capture the webhook path from each Icinga 2 minor release published as an official container
  image from 2.13 onwards (the exact list is fixed by the capture task and written into the supported-release
  statement), and decode them all in a version-matrix test.
- **Rejected:** Only the latest release (the owner's site may run an older one); hand-written fixtures (M1's
  real-Alertmanager check failed on fields the documentation omitted; strategy R3).
- **Reversal cost:** low.
- **Important:** yes — binds what Correlia claims to support.
- **Chosen by:** agent
