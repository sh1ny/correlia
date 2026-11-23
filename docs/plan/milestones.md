# Milestones to 1.0: detailed feature plan

`openspec/roadmap.md` is the Specwright roadmap: short, and only the current milestone is split into
changes. This document is the long form behind it. It lists every feature planned for each milestone up to a
stable 1.0, so nothing discussed is lost. When a milestone becomes Now, `specwright-roadmap close`/`next`
splits its features into changes. The split may move features between milestones, and this file is updated
when it does.

Related: [integrations](integrations.md) · [acceptance scenarios](acceptance-scenarios.md) ·
[open decisions](open-decisions.md).

Each milestone ends with something demoable. Exit criteria are marked **[agent]** (checked by tests or
commands) or **[user]** (the owner checks).

**Owner cuts, 2026-11-22.** Four decisions changed this plan:
1. The M8 integration wave and the Go and Python SDKs move after 1.0, into 1.x
   ([below](#1x-integration-wave-and-plugin-sdks)). The number M8 is retired, not reused: M9 and M10 keep
   their names, so references to them in ADRs and archived changes stay right.
2. Pre-ship review is capped at 4 rounds per change; after round 4 the owner decides whether to continue,
   ship or rework (`review.preship_max_rounds` in `openspec/specwright.yaml`).
3. A minimal container image and a compose file move from M10 to the end of M3 (open decision D32).
4. M3 gets a read-only incident list in the console, so the M3 replay check is done in the UI (D34).

---

## M1: Walking skeleton

**Outcome:** An Alertmanager webhook arrives. It becomes a canonical event, updates alert state, is
published to NATS by an external Go plugin, and shows up live in a minimal Flutter web alert list. Everything
runs on embedded Postgres, developed and tested inside WSL (ADR 0014).

**Retires the riskiest assumptions:**
- Serverpod 4.1 with embedded Postgres in dev/test, tiered tests on Linux.
- The durable staged pipeline with `SKIP LOCKED` claims and a transactional outbox.
- A Dart host speaking the go-plugin handshake and the Correlia plugin protocol to a Go process.
- The canonical event contract (protobuf, buf, CloudEvents).

**Features:**
- **Workspace:**
  - `serverpod create` layout (`correlia_server`, `correlia_client`, `correlia_flutter`);
  - mise tasks (`check`, `test`, `generate`, `analyze`, `proto`);
  - the Serverpod CLI pinned;
  - the Serverpod MCP server added to the agent configs;
  - Go and buf toolchains via mise;
  - `dart analyze` clean with strict lints.
- **Test tiers:** `mise run test` runs `dart test` by tag on Linux and cleans up its embedded Postgres without
  touching any other Postgres on the machine (ADR 0014).
- **Roles:** `role=api|worker|all` in one binary (ADR 0001); health endpoints `/livez`, `/readyz`, `/startupz`.
- **Canonical event v1:**
  - `proto/correlia/event/v1`: identity, time fields (source, observed, ingested), observer and resource
    split, severity and status enums, labels/annotations, links, raw reference, `pipeline` metadata;
  - generated Dart types;
  - a JSON Schema export;
  - the `buf lint` and `buf breaking` gates;
  - the CloudEvents envelope;
  - deterministic UUIDv5 event ids.
- **Ingest:**
  - `/hooks/alertmanager/<instance>` with a per-instance bearer token;
  - a body limit;
  - `raw_inbox` insert, then 202.
- **Pipeline v0:**
  - decode, normalize and route stages with claims;
  - no processing order: the alert ordering fence (ADR 0017) is the only ordering;
  - dead-letter rows (no UI yet).
- **Alert state v0:**
  - firing/resolved per fingerprint with ordering fencing (ORD-1..3, ORD-5);
  - the activity ledger rows.
- **Schema step:** Correlia's own forward-only SQL scripts for the tables Serverpod cannot express
  (`activity` first), run at startup after Serverpod's migrations on fresh and upgraded databases alike
  (`openspec/architecture.md`, Database). The first change that adds such a table adds the step.
- **Outbox and relay:** one outbox per output; retry with backoff; attempts recorded.
- **Plugin host v0:**
  - spawn, magic-cookie handshake, gRPC over protected Unix sockets with stock AutoMTLS through
    in-process OpenSSL 3 and grpc-dart's custom connector (D24 and native dependencies accepted by
    the owner on 2026-11-11);
  - `GetMetadata`, `Configure`, `CheckHealth`;
  - a batched output stream with credit windows;
  - restart with backoff; status rows.
- **output-nats (Go):**
  - stock `plugin.Serve()` wrapped with a stdin watcher that exits on stdin close (ADR 0018);
  - JetStream publish with `Nats-Msg-Id`;
  - the subject scheme;
  - structured CloudEvents JSON.
- **Console v0:**
  - a Flutter web alert list fed by a Serverpod stream;
  - served by the api role;
  - no auth yet: dev mode only, bound to localhost.
- **Scenarios:** ORD-1, ORD-2, ORD-3, ORD-5, ID-4, ID-6, ID-7 (b, c), DUR-1, DUR-2, DUR-3, DUR-8, UI-3, SEC-1, SEC-5, UPG-3.

**Exit criteria:**
- [agent] `mise run check` and every test tier except `load` pass from a clean clone in WSL.
- [agent] Scenarios above pass.
- [agent] Kill -9 of the worker during a 1,000-alert burst loses nothing: every accepted alert is
  either in NATS or dead-lettered.
- [user] The owner points a real Alertmanager at a dev instance and sees alerts in the console and on a NATS
  subscriber.

---

## M2: Icinga2, Thanos and the ingest track

**Outcome:** The owner's two real sources flow in, are enriched by rules that can be tested in a
simulator, and failures are visible and replayable.

**Features:**
- **Icinga2:**
  - webhook (notification command) and Event Streams API consumer (`CheckResult`, `StateChange`,
    `AcknowledgementSet/Cleared`, `DowntimeStarted/Removed`, `Flapping`);
  - state sync on startup (pull);
  - soft vs hard state policy per source.
- **Thanos:** Ruler via the Alertmanager decoder; tenant headers; documented setup.
- **Generic webhook:**
  - a declarative mapping document with a versioned format;
  - a preview against a pasted sample.
- **Sources model:**
  - source instances with their own credentials (bearer or HMAC; rotation with overlap);
  - a namespace setting (D3);
  - per-source rate and body limits.
- **Enrichment:**
  - matcher rules (ADR 0008): set labels/tags, severity mapping, owner/team, runbook and dashboard links,
    hostname/CIDR → site/environment tables, regex extraction with timeouts;
  - rule versions with atomic activation and rollback (RUL-4);
  - YAML provisioning.
- **Prometheus/Thanos query enricher:** a PromQL query adds context values; per-rule deadlines.
- **Classification:** event kind (alert, state change, heartbeat, info), noise class hints.
- **Rule simulator:** run a sample or a stored event through the active or a draft rule set and show every
  decision (RUL-1, RUL-2). Exposed through the API; the console UI comes in M4.
- **Dead letters:** an API to list and replay pipeline failures and outbox deliveries; replay in bulk by
  filter.
- **Backpressure:** inbox lag bounds with 429/503 and `Retry-After` (DUR-9).
- **Secrets:** encrypted plugin config secrets (SEC-3).
- **Retention jobs:** raw inbox and events partitioning; drop by age.
- **Scenarios:** ORD-4, ORD-6, ID-2, ID-3, DUR-4, DUR-5, DUR-9..13, ORD-7, RUL-1..4, SEC-2, SEC-3.

**Exit criteria:**
- [agent] Golden fixtures for Icinga2 (both paths), Alertmanager and Thanos pass.
- [agent] Scenarios above pass.
- [user] The owner's real Icinga2 and Alertmanager/Thanos feed a dev instance for a day; the owner checks
  that the enriched events look right.

---

## M3: Correlation and incidents

**Outcome:** Related alerts become incidents with a correct lifecycle under storms. The legacy defects are
proven fixed.

**Features:**
- **Correlation rules:**
  - matcher selection;
  - structured group-by keys (canonical tuple hash plus display parts);
  - threshold policy per rule (D4);
  - time window with a maximum open duration and a quiet period (COR-5);
  - priority order;
  - a per-rule simulator.
- **Incident lifecycle:** open → resolved/closed; acknowledgement orthogonal to status; manual close policy
  (D6); expiry; reopen-or-link policy.
- **Data model:** `incidents`, `incident_alerts` (relational membership, no JSON blobs), the partial unique
  index on the open group key, and the activity ledger for every change.
- **Concurrency:** one transaction per event batch; serialization retries; hot-group handling (COR-6).
- **Severity:** current severity (the max of active members) vs peak severity, shown separately.
- **Incident outputs:** incident events on NATS (`correlia.v1.incident.*`) and webhook out.
- **Manual operations:** merge incidents, split an alert out, link incidents, set owner, add a note. These go
  through the API; the UI comes in M4.
- **Topology-free grouping helpers:** same host, same service across hosts, same label set.
- **Console incident list (owner, 2026-11-22):** a read-only list of incidents in the console, beside the
  M1 alert list, with no actions and no auth (dev mode, bound to localhost, as in M1). What it shows is
  open decision D34. M4 extends it into the full incident views.
- **Minimal packaging (owner, 2026-11-22), the last change of M3:** a minimal container image and a compose
  file that run Correlia against a real Postgres, pulled forward from M10. What "minimal" includes is open
  decision D32. M10 hardens both for production.
- **Scenarios:** ID-1, COR-1..7.

**Exit criteria:**
- [agent] All correlation scenarios pass, including the 10k/60s hot-group correctness run.
- [agent] The compose file starts Correlia from the minimal image, and an Alertmanager webhook sent to it
  shows up as an incident in the console's incident list; every listener the image enables (API, web
  server and console, Insights) is unreachable on the host's non-loopback IPv4 and IPv6 addresses.
- [user] Replaying a recorded day of the owner's traffic gives incidents the owner agrees with, checked in
  the console's incident list.

---

## M4: Console v1 and access control

**Outcome:** A usable, secure web console for operators and engineers.

**Features:**
- **Auth:**
  - Serverpod email OTP sign-in;
  - sessions;
  - roles viewer/operator/admin;
  - team-scoped permissions;
  - API keys with scopes;
  - an audit of every action with the actor (SEC-4).
- **Incident views** (extending M3's read-only incident list):
  - a dense, live incident list (filters, saved views, grouping, sorting, keyboard navigation);
  - incident detail (timeline from the activity ledger, member alerts, current vs peak severity, links,
    raw payload viewer, related incidents);
  - actions (ack, unack, transfer ownership, close, reopen, merge, split, note).
- **Alert views:** all alerts, by source, by fingerprint history.
- **Change feed:** a monotonic record version per entity and stream invalidation (UI-1); optimistic
  concurrency on actions (UI-2).
- **Rule editors:**
  - enrichment and correlation rules with versioning, diff, rollback and a draft → simulate → activate
    flow;
  - provisioned rules shown read-only (RUL-5).
- **Source setup:** a wizard per source type (credentials, URL, copy-paste config snippet for the sender,
  test event).
- **Plugins page:** status, health, version, restarts, stats; configure secrets.
- **System page:** pipeline lag, outbox depth, dead letters with replay, retention status.
- **REST `/api/v1/`:** incidents, alerts, actions, rule import/export; OpenAPI document.
- **UX:**
  - responsive layout;
  - light and dark themes;
  - English only, with localization scaffolding (D19);
  - accessibility basics (focus order, contrast, screen reader labels).
- **Scenarios:** ID-5, COR-8, UI-1, UI-2, UI-4, RUL-5, SEC-4, SEC-6.

**Exit criteria:**
- [agent] Widget and integration tests for the main flows; scenarios pass.
- [user] The owner runs a simulated outage end to end in the console.

---

## M5: Noise control

**Outcome:** Operators can silence, schedule maintenance and suppress flapping, and see how much noise
Correlia removes.

**Features:**
- **Silences:** matcher-based, with a start, end and author; preview of what they would match; expiry.
- **Maintenance windows:**
  - one-off and recurring (RRULE);
  - per source, host or label set;
  - sync from Icinga2 downtimes (both ways, optional).
- **Flapping detection:** per alert, state-change rate over a window; suppress notifications, keep state.
- **Inhibition:** a firing alert suppresses matching alerts (Alertmanager-style), with the inhibiting alert
  shown.
- **Deduplication insight:** per-source dedup and correlation ratio; top noisy alerts; "would have been
  silenced" previews.
- **Suppressed but kept:** suppressed alerts stay in state and in the ledger, and remain visible behind a
  filter.

**Exit criteria:**
- [agent] Silence, maintenance, flapping and inhibition specs pass, including recurring windows across DST
  changes.
- [user] The noise ratio page on the owner's traffic.

---

## M6: Notifications and routing

**Outcome:** The right people get told, once, through their channel, with retries and visible delivery
state.

**Features:**
- **Routing tree:** matcher-based routes to notification policies; continue/stop semantics; per-team
  defaults.
- **Notification policies:**
  - fire on open, escalation and resolve, with reminders while unacknowledged (D7);
  - quiet hours;
  - rate limits;
  - grouping of notifications.
- **Templates:** a safe template language (logic-less, with filters); per-channel templates; preview;
  subject folding (DUR-7).
- **Channels (P1):** email (SMTP transports), Slack, Microsoft Teams, Mattermost, Telegram, PagerDuty
  (Events v2), webhook out.
- **Delivery:** outbox-backed; at-least-once; delivery state on the incident (DUR-6); dead letters and
  replay.
- **Contacts:** users, teams and channel targets; simple on-call schedules (weekly rotation with overrides).
  Full on-call management is out of scope.
- **Escalation:** time-based escalation steps until acknowledged.

**Exit criteria:**
- [agent] Each channel passes against a local fake or a sandbox; DUR-6 and DUR-7 pass.
- [user] The owner receives Slack/Teams/email notifications from a simulated outage.

---

## M7: Workflows and ticketing

**Outcome:** Incidents can open and update tickets, and simple automations run safely.

**Features:**
- **Workflows:**
  - triggered by incident events (opened, escalated, acknowledged, resolved, label matched);
  - steps are typed plugin actions with inputs from the incident;
  - conditions with the matcher language;
  - durable execution in Postgres (never in memory), with retries and per-step history;
  - manual run;
  - a dry run.
- **Ticketing:** Jira (Cloud and Data Center) and ServiceNow. Create, comment and transition; ticket status
  syncs back to the incident; links shown in the console.
- **Two-way sync:** Icinga2 ack/downtime, PagerDuty ack/resolve, Slack/Mattermost interactive buttons.
- **Runbooks:** links and inline markdown per rule or label; no code execution.
- **Declared actions and approval:** plugins declare their actions in the manifest, marked read-only or
  state-changing. Only declared actions can be called. State-changing actions need a human approval when
  they are proposed by automation that reads untrusted alert text (and always when AI is added later).

**Exit criteria:**
- [agent] Workflows survive a worker restart mid-run; each action has contract tests.
- [user] The owner creates a Jira ticket from an incident and sees its status sync back.

---

## M8: Moved after 1.0

The owner moved this milestone, the integration wave and the plugin SDKs, after 1.0 on 2026-11-22. Its
features are in [1.x: integration wave and plugin SDKs](#1x-integration-wave-and-plugin-sdks). The number is
retired so that M9 and M10 keep their names.

---

## M9: Topology and context

**Outcome:** Incidents carry context about what is affected, and correlation can use dependencies.

**Features:**
- **NetBox enricher:** device, site, tenant, role and owner by hostname or IP; cached with a TTL.
- **Static CMDB import:** CSV or YAML.
- **Service model:** services, components and dependencies (manual plus imported).
- **Topology-aware correlation:** group by service; suppress symptoms downstream of a known root cause
  (suggested, not automatic, in 1.0).
- **Context panels:** Prometheus graphs, Loki logs around the incident time, recent changes from webhook
  sources (deploy events).

**Exit criteria:**
- [agent] Enrichment cache and topology correlation specs pass.
- [user] The owner's NetBox enriches real incidents.

---

## M10: Hardening for 1.0

**Outcome:** Correlia is safe to run in production, upgrade and recover.

**Features:**
- **Scale:**
  - multi-instance api and worker (Redis for Serverpod streams where needed);
  - the 10k/60s storm target with p95 < 5 s on the reference node;
  - long-running soak tests.
- **Data:**
  - partition maintenance for every growing table;
  - retention settings in the console;
  - backup and restore guide with a tested drill (UPG-2);
  - migration tests on populated databases (UPG-1).
- **Identity:** generic OIDC provider (D13), with automated tests against Keycloak and Authentik
  containers (Entra ID best-effort); session hardening; API key rotation.
- **Observability:** OpenTelemetry traces and metrics for the pipeline, relays and plugins; Prometheus
  metrics endpoint; structured logs; Correlia monitors itself (heartbeat alerts).
- **Packaging:** the production container image and docker compose, hardening M3's minimal ones; systemd
  unit for a single binary; Helm chart (D12); versioned releases with changelogs.
- **Security:**
  - security review;
  - dependency audit;
  - least-privilege DB roles;
  - TLS everywhere;
  - CSP for the console;
  - rate limits on auth.
- **Docs:** operator guide, integration guides, plugin author guide, API reference, upgrade notes,
  architecture overview.
- **Licence:** chosen and applied (D10).

**Exit criteria:**
- [agent] Load, soak, upgrade and restore runs pass and are recorded.
- [agent] Every scenario in `acceptance-scenarios.md` passes.
- [user] The owner runs a release candidate on real traffic for two weeks without a data-loss or
  wrong-state bug.

---

## 1.0 release

1.0 means (owner, 2026-11-03, D27):
- every P0 integration;
- a public API, canonical event and plugin protocol declared stable under semver;
- every acceptance scenario green;
- documented upgrade and restore.

P1 integrations and the plugin SDKs are not 1.0 blockers. The P1 integrations planned in M6, M7 and M9 ship
there or in 1.x point releases; the rest, and the SDKs, ship in 1.x (owner, 2026-11-22). Each ships when it
meets the definition of done in `integrations.md`.

From 1.0 on, breaking changes to `correlia.event.v1`, `correlia.plugin.v1` or `/api/v1/` need a new major
version.

## 1.x: integration wave and plugin SDKs

Moved from M8 by the owner on 2026-11-22. Planned after 1.0, in 1.x point releases. Which of the plugin
items below stay in M10 instead is open decision D33.

**Outcome:** The P1 monitoring sources work, and third parties can write plugins in Go or Python.

**Features:**
- **P1 sources:** Grafana, Zabbix, Nagios, Checkmk, Uptime Kuma, VictoriaMetrics, Datadog, Elastic/Kibana,
  Loki, Sentry, CloudWatch, Azure Monitor, GCP Monitoring, Kubernetes events, syslog, SNMP traps, IMAP
  email-in.
- **Event bus:** Kafka output and consume; NATS consume.
- **Plugin SDKs:**
  - Go (stock go-plugin) and Python, with docs, templates and a conformance test suite that every plugin
    must pass;
  - a plugin lockfile with checksums;
  - a signed-manifest option;
  - a plugin install directory layout.
- **Plugin catalog page:** installed plugins, capabilities, versions and docs links.

**Exit criteria:**
- [agent] Each integration meets the definition of done in `integrations.md`; the conformance suite passes
  for all first-party external plugins.
- [user] The owner writes or reviews a toy Python plugin from the SDK docs.

## After 1.0 (not planned in detail)

- CEL rules.
- Multi-tenancy.
- AI-suggested correlations, as suggestions only, never committed automatically.
- P2 integrations.
- A full on-call management product.
- A mobile app (Flutter makes it cheap).
- Status pages.
- Postmortem documents.
- Change correlation from CI/CD events.
