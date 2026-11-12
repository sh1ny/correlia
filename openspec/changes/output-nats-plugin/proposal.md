# Proposal

## Why

M1 (Walking skeleton) promises that an accepted Alertmanager alert is published to NATS by an external Go
plugin. After the first five M1 changes, events and output intents are durable and webhook-out delivers
them. However, nothing launches a production plugin, keeps it alive or connects it to the outbox, and no
NATS output exists. `plugin-host-spike` proved the four ADR 0020 gates over an explicitly unstable probe
protocol with an in-memory queue (ADR 0023). This change builds the production path on that evidence.

This is the last change of M1. It advances these exit criteria:
- **Kill -9 during a burst:** killing the worker during a 1,000-alert burst loses nothing. Every accepted
  alert is either in NATS or dead-lettered with its reason. This change adds that test.
- **Named scenarios:** DUR-3 (the NATS `Nats-Msg-Id` half) and DUR-8 are new here. The ORD-5e test is
  added under its scenario name. The remaining M1 scenarios already have tests and are re-run.
- **ADR 0020 spike gate:** criterion 4 is re-proven with the NATS plugin itself, as ADR 0020 requires.
- **Clean-clone gate:** `mise run check` and every tier except `load`, now including the Go plugin build
  and the NATS-backed tests.

The user-verified criterion has the owner point a real Alertmanager at a dev instance and see the alerts
in the console and on a NATS subscriber. It is judged at the M1 close, not by a `[user]` task here. Two
reasons:
- The criterion is the milestone's, and close walks every criterion together.
- The owner asked not to be blocked on answers (decision mode `autonomous`), and a `[user]` task would
  hold archive.

This change ships the runbook and mise tasks the owner needs for that check. An automated e2e test runs
the same path, Alertmanager payload → console feed → NATS subscriber, with a real NATS server.

## What Changes

- **Production plugin protocol `correlia.plugin.v1` (output subset).** A new protobuf contract under
  `proto/correlia/plugin/v1/` with:
  - metadata (name, version, kinds, config schema);
  - configure (non-secret config plus referenced secrets);
  - health;
  - a batched bidirectional delivery stream with a credit window, sequences and a per-event outcome:
    acknowledged, retryable or rejected, each with an error class.

  The spike's `correlia.plugin.spike.v1` probe stays as it is, still experimental.
- **Plugin outputs on the durable outbox.** A new output kind `plugin` in the bootstrap configuration
  names:
  - a plugin executable in the operator's plugin directory, pinned by SHA-256;
  - the plugin's config;
  - secret references, kept as commitments like signing keys. Secret values may now be any length up
    to 16 KiB, so a NATS token or creds document fits; source and webhook keys stay 32 bytes. Startup
    validation becomes kind-aware: live plugin work never blocks worker startup.

  The relay claims bounded batches of a plugin output's queued rows and sends each batch over the stream.
  It completes every row of a batch from that row's own outcome in one fenced transaction, with the
  existing attempts, backoff and dead letters. The outbox stays the only durable queue. The host keeps no pending queue of its own. Webhook-out
  is unchanged.
- **Supervision.** A worker-role supervisor runs one plugin process per output definition that has
  due work, sharing a bounded number of slots fairly across outputs. It verifies the executable before every launch and applies a start timeout and health checks. It
  restarts with capped exponential backoff and opens a circuit, `degraded`, once the crash budget is
  exceeded. Rows of an output whose plugin is not ready stay queued without spending attempts. A batch in
  flight when a plugin dies is retried (DUR-8).
- **Status rows.** A persisted status row per plugin instance records state, process, restart count,
  last error class and heartbeat. An activity ledger entry is written when a plugin becomes `degraded`
  and when it recovers. The console's plugin page stays in M4; M1 makes the status inspectable by SQL.
- **`plugins/output-nats` (Go).** Stock go-plugin `plugin.Serve()` wrapped with the ADR 0018 stdin
  watcher. It publishes to JetStream:
  - subject: `correlia.v1.ev.<tenant>.<kind>.<source_kind>.<severity>`;
  - body: the exact stored structured CloudEvents JSON;
  - headers: `Nats-Msg-Id` set to the event id, plus the `ce-*` headers and `traceparent`.

  A row is acknowledged only after the JetStream publish acknowledgement, and a duplicate acknowledgement
  counts as success. The plugin never creates or changes streams: configure fails when no stream captures
  the subjects.
- **NATS for tests and the dev demo.** A small pinned Go tool runs an embedded JetStream server, creates
  the demo stream and subscribes. It runs through mise, with no Docker and no system NATS install.
- **Exit-criteria proofs.** The new e2e and plugin-tier tests:
  - a 1,000-alert burst with kill -9 of the worker, reconciled against JetStream and dead letters;
  - DUR-3 deduplication by `Nats-Msg-Id`;
  - DUR-8 crash, backoff and `degraded`;
  - NATS-plugin orphan exit after host SIGKILL;
  - the console-and-NATS demo path.

  ORD-5e also gets a test under its scenario name.
- **ADR.** A new ADR records the `correlia.plugin.v1` output contract, per-event outcomes, the
  durable-outbox-as-queue rule, supervision policy and the Go module layout. It supersedes nothing.

## Capabilities

### New Capabilities

- `plugin-output-protocol`: the `correlia.plugin.v1` output contract a plugin implements. It covers
  metadata, configure with secrets, health, credit-controlled batched delivery and per-event outcomes.
- `plugin-supervision`: launching verified plugin executables, readiness, health, restart backoff, the
  crash budget and `degraded` circuit, shutdown, persisted status and activity entries.
- `integration-nats`: the NATS JetStream output: subject scheme and token rules, body and headers,
  publish acknowledgement and deduplication, stream preconditions, error classes and stdin-close exit.

### Modified Capabilities

- `output-delivery`: adds plugin output definitions, batched acquisition, delivery gated on plugin
  readiness without spending attempts, and per-event completion of a batch. It also adds crash handling
  for a batch in flight. Existing webhook requirements are unchanged.
- `workspace-tooling`: adds reproducible `correlia.plugin.v1` generation for Dart and Go with drift
  checks. It also adds pinned Go plugin builds and the NATS dev/test tool, built by the tiers that need
  them.

## Impact

- **Server (`correlia_server`):**
  - a production plugin client in `lib/src/plugin/`, reusing the spike's launch and OpenSSL TLS internals;
  - a supervisor subsystem;
  - plugin-kind support in `lib/src/output/` (relay batch claims and the plugin output adapter);
  - plugin output parsing in `lib/src/ingest/bootstrap.dart`;
  - schema step `0003`, which adds the output kind and plugin definition columns to `outbox`;
  - a managed `plugin_instance_status` model and migration;
  - new `plugin` and `e2e` tests.
- **Protocol and Go:**
  - `proto/correlia/plugin/v1/`, with generated Dart and Go;
  - a new Go module at `plugins/` holding `output-nats`;
  - a new Go module at `tool/natsdev/`, embedding a pinned `nats-server`;
  - the `nats.go` and `nats-server` dependencies, pinned with checksums;
  - mise tasks to build plugins and to run the dev NATS server, stream and subscriber.
- **Docs:** a NATS output and plugin operations guide, and the owner demo runbook.
- **Unaffected:** the canonical event contract and its frozen baseline, the spike probe, the console UI,
  and the webhook-out behaviour.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Production protocol now, but output-only

- **Choice:** Define `correlia.plugin.v1` for outputs only: metadata, configure, health and delivery.
  Source, decoder and enricher services, `GetStats`, the plugin lock file and the Go SDK stay with M8
  (D16). The spike probe is not promoted.
- **Rejected:**
  - Promoting the spike probe to production. ADR 0023 forbids it: the probe has no compatibility promise,
    and its whole-batch acknowledgements cannot dead-letter one bad event.
  - Specifying every plugin kind now. Those kinds would have no implementation to test them against.
- **Reversal cost:** medium. The protocol is pre-1.0, but a third party may start writing against it.
- **Important:** yes. It binds future changes (a contract).
- **Chosen by:** agent.

### S2: The outbox is the only durable queue

- **Choice:** Plugin delivery is a relay output like webhook-out. Rows are claimed in bounded batches,
  and the host holds only the batch in flight. The spike's in-memory pending queue is not used in
  production.
- **Rejected:** Admitting outbox rows into a host-side queue that outlives the claim. That gives a
  second owner of delivery state, which loses work or double-counts attempts when the worker dies.
- **Reversal cost:** medium.
- **Important:** yes. It binds future changes and is a data-loss risk.
- **Chosen by:** agent.

### S3: Event subjects only; incident subjects wait for incidents

- **Choice:** Publish only canonical events on `correlia.v1.ev.…`. `correlia.v1.incident.…` (ADR 0018)
  starts when M3 creates incidents.
- **Rejected:** Reserving or emitting incident messages now, with nothing to emit.
- **Reversal cost:** low.
- **Important:** no.
- **Chosen by:** agent.

### S4: The owner's real-Alertmanager check is judged at M1 close

- **Choice:** Ship the runbook and an automated equivalent e2e test. The owner's check runs at
  milestone close, with no `[user]` task here.
- **Rejected:** A `[user]` task in this change. It would block archive on an owner who asked not to be
  held up, and the criterion belongs to the milestone.
- **Reversal cost:** low.
- **Important:** yes. It changes what the owner sees and does.
- **Chosen by:** agent.

### S5: Plugin status is visible by SQL and the activity ledger in M1; console pages in M4

- **Choice:** Persist status rows and degraded/recovered activity entries. The console's plugin page
  belongs to M4.
- **Rejected:** Adding a console plugin page now. M4 owns console access control, and an
  unauthenticated system page would widen the dev-only exposure.
- **Reversal cost:** low.
- **Important:** yes. It changes what users see.
- **Chosen by:** agent.
