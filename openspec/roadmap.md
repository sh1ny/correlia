# Correlia Roadmap

Strategy: openspec/strategy.md · Architecture: openspec/architecture.md

<!-- Status is derived: a change is done when archived; a milestone is done when its changes are done and its exit criteria pass. Do not add status checkboxes for changes. -->

The long-form feature plan for every milestone up to 1.0 is in `docs/plan/milestones.md`. The integration
backlog is in `docs/plan/integrations.md`, the named acceptance scenarios in
`docs/plan/acceptance-scenarios.md`, and the owner's open decisions in `docs/plan/open-decisions.md`.

## Now: M1 - Walking skeleton

**Outcome:** An Alertmanager webhook becomes a canonical event and updates alert state with ordering fences.
It is published to NATS by an external Go plugin and appears live in a minimal Flutter web alert list.
Everything runs on embedded Postgres, and the server tests run from WSL.

M1 retires the riskiest assumptions:
- Serverpod 4.1 with embedded Postgres and the WSL runner;
- the durable pipeline and transactional outbox;
- the lossless change feed;
- a Dart host speaking go-plugin to a Go process.

**Exit criteria:**
- `mise run check` and `mise run test:wsl` pass from a clean clone on Windows. (agent)
- Scenarios ORD-1, ORD-2, ORD-3, ORD-5, ID-4, ID-6, ID-7 (b, c), DUR-1, DUR-2, DUR-3, DUR-8, UI-3, SEC-1,
  SEC-5 and UPG-3 pass as named tests. (agent)
- A kill -9 of the worker during a 1,000-alert burst loses nothing. Every accepted alert is either
  published to NATS or dead-lettered with its reason. (agent)
- The plugin spike gate of ADR 0006 passes on Windows and Linux, or the owner has decided a fallback. (agent,
  then user if a fallback is needed)
- The owner points a real Alertmanager at a dev instance and sees the alerts in the console and on a NATS
  subscriber. (user)

**Changes** (in order; each about one PR):
1. `bootstrap-workspace`:
   - `serverpod create` layout (server, client, flutter);
   - mise tasks `check`, `test`, `test:wsl`, `generate`, `analyze`, `proto`;
   - a WSL runner with embedded Postgres and cleanup;
   - `api`/`worker`/`all` roles and health endpoints;
   - the Serverpod MCP in the agent configs;
   - Go and buf toolchains.
2. `canonical-event-v1`:
   - the `correlia.event.v1` protobuf with buf lint/breaking gates, JSON Schema export and Dart codegen;
   - the CloudEvents envelope;
   - a canonical-encoding and identity library (ADR 0012) with collision and re-batching tests.
3. `plugin-host-spike`: a Dart host against a stock go-plugin Go test plugin, proving the four pass criteria
   of the ADR 0006 spike gate. A failed criterion stops for an owner decision.
4. `alertmanager-ingest-pipeline`:
   - source instances with per-instance tokens and log redaction;
   - `/hooks/alertmanager/<instance>` and the raw inbox with transport dedup;
   - lane claims; decode/normalize/route with config pinning; durable observation dedup; pipeline failures;
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
- 1.0 - Stable release: event format, plugin protocol and `/api/v1/` declared stable under semver.

## Done
