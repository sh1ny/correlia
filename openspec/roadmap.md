# Correlia Roadmap

Strategy: openspec/strategy.md · Architecture: openspec/architecture.md

<!-- Status is derived: a change is done when archived; a milestone is done when its changes are done and its exit criteria pass. Do not add status checkboxes for changes. -->

The long-form feature plan for every milestone up to 1.0 is in `docs/plan/milestones.md`. The integration
backlog is in `docs/plan/integrations.md`, the named acceptance scenarios in
`docs/plan/acceptance-scenarios.md`, and the owner's open decisions in `docs/plan/open-decisions.md`.

## Now: M1 - Walking skeleton

**Outcome:** An Alertmanager webhook becomes a canonical event and updates alert state with ordering fences.
It is published to NATS by an external Go plugin and appears live in a minimal Flutter web alert list.
Everything runs on embedded Postgres, developed and tested inside WSL (ADR 0014).

M1 retires the riskiest assumptions:
- Serverpod 4.1 with embedded Postgres in tiered tests on Linux;
- the durable pipeline and transactional outbox;
- the lossless change feed;
- a Dart host speaking go-plugin to a Go process.

**Exit criteria:**
- `mise run check` and every test tier except `load` pass from a clean clone in WSL. (agent)
- Scenarios ORD-1, ORD-2, ORD-3, ORD-5, ID-4, ID-6, ID-7 (b, c), DUR-1, DUR-2, DUR-3, DUR-8, UI-3, SEC-1,
  SEC-5 and UPG-3 pass as named tests. (agent)
- A kill -9 of the worker during a 1,000-alert burst loses nothing. Every accepted alert is either
  published to NATS or dead-lettered with its reason. (agent)
- The plugin spike gate of ADR 0020 passes on Linux, or the owner has decided a fallback. (agent,
  then user if a fallback is needed)
- The owner points a real Alertmanager at a dev instance and sees the alerts in the console and on a NATS
  subscriber. (user)

**Changes** (in order; each about one PR):
1. `bootstrap-workspace`:
   - `serverpod create` layout (server, client, flutter);
   - mise tasks `check`, `test`, `generate`, `analyze`, `proto`;
   - embedded Postgres test tiers with cleanup (ADR 0014);
   - `api`/`worker`/`all` roles and health endpoints;
   - the Serverpod MCP in the agent configs;
   - Go and buf toolchains.
2. `canonical-event-v1`:
   - the `correlia.event.v1` protobuf with buf lint/breaking gates, JSON Schema export and Dart codegen;
   - the CloudEvents envelope;
   - a canonical-encoding and identity library (ADR 0019) with collision and re-batching tests.
3. `plugin-host-spike`: a Dart host against a stock go-plugin Go test plugin, proving the four pass criteria
   of the ADR 0020 spike gate. A failed criterion stops for an owner decision.
4. `alertmanager-ingest-pipeline`:
   - source instances with per-instance tokens and log redaction;
   - `/hooks/alertmanager/<instance>` and the raw inbox with transport dedup;
   - claims (no processing order; the ordering fence orders state); decode/normalize/route with config
     pinning; durable observation dedup; pipeline failures;
   - the transactional outbox and a relay with a built-in webhook-out output.
5. `alert-state-and-live-console`:
   - `StateMutationService` for alert state with ordering fences, lateness and skew;
   - the activity ledger and the `(txid, id)` change feed;
   - a Flutter web alert list fed by snapshot plus feed.

   Needs 4.
6. `output-nats-plugin`:
   - plugin supervision (restart, backoff, `degraded`, status rows);
   - the Go `output-nats` plugin (JetStream, `Nats-Msg-Id`, the subject scheme);
   - the end-to-end demo for the exit criteria.

   Needs 3 and 5.
7. `alertmanager-webhook-compat` (gap-closing; the M1 close of 2026-11-12 showed the real-Alertmanager
   criterion failing: Alertmanager 0.32+ adds top-level `notification_reason` and `routeLabels`, which the
   decoder rejects):
   - decode every webhook field Alertmanager 0.16 to 0.35 sends, each optional where some versions omit it;
   - a captured fixture per supported minor;
   - an unknown top-level field is processed and flagged (names recorded on the raw delivery; a count and hash tags logged), not failed (owner,
     2026-11-12); unknown per-alert fields and wrong types still fail.

   Needs 4.
8. `plugin-health-timeout-classification` (gap-closing; the M1 close of 2026-11-13 showed `mise run test:all`
   failing 439/440 from a clean clone: under full-suite load a stalled plugin health call was reported as
   `plugin_connection_lost`, not `plugin_health_timeout`):
   - a health call whose own deadline expires is always a health timeout, never a lost connection;
   - only a real transport failure marks the connection lost;
   - the plugin protocol tests hold under full-suite load.

   Needs 3 and 6.

## Next: M2 - Icinga2, Thanos and the ingest track

The owner's two real sources flow in, enriched by testable rules, and every failure is visible and
replayable:
- Icinga2 by webhook, the Event Streams API and state sync;
- Thanos Ruler and tenant headers;
- a generic webhook with declarative mappings;
- source namespaces;
- the matcher rule language with atomic configuration versions, YAML provisioning and the simulator API;
- a Prometheus/Thanos query enricher;
- dead-letter replay;
- storage budgets and backpressure;
- retention and partitioning;
- encrypted plugin secrets.

It retires the risk that real source payloads (Icinga2 soft/hard states, flapping, acknowledgements) do not
fit the canonical event and identity model.

## Later

- M3 - Correlation and incidents: correlation rules, the full mutation protocol with group locks,
  thresholds, lifecycle and the legacy regression scenarios under a 10k/60 s storm.
- M4 - Console v1 and access control:
  - invite-only email OTP, roles, teams and API keys;
  - incident and alert views; rule editors and the simulator UI;
  - source wizards; plugin and system pages; REST `/api/v1/`.
- M5 - Noise control: silences, maintenance windows (including Icinga2 downtime sync), flapping, inhibition
  and noise-ratio insight.
- M6 - Notifications and routing:
  - a routing tree and policies, templates, reminders and escalation;
  - email, Slack, Teams, Mattermost, Telegram, PagerDuty and webhook-out.
- M7 - Workflows and ticketing: durable typed-action workflows, Jira and ServiceNow, two-way sync and
  runbooks.
- M8 - Integration wave and plugin SDKs:
  - the P1 sources;
  - Kafka;
  - NATS consume;
  - Go and Python SDKs with a conformance suite;
  - the plugin lockfile.
- M9 - Topology and context: the NetBox enricher, CMDB import, a service model, topology-aware
  correlation and context panels.
- M10 - Hardening for 1.0:
  - multi-instance; load and soak qualification; partition maintenance;
  - backup and restore; OIDC; OpenTelemetry;
  - packaging (image, compose, systemd, Helm);
  - a security review, docs and the licence.
- 1.0 - Stable release (owner, 2026-11-03, D27): the P0 integrations; event format, plugin protocol and
  `/api/v1/` declared stable under semver; every acceptance scenario green; documented upgrade and restore.
  P1 integrations and the plugin SDKs ship in the milestones above or in 1.x point releases.

## Done
