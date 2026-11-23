# Correlia Strategy

## Purpose
Correlia turns the alert noise of many monitoring systems into a small number of trustworthy incidents. It
does three jobs:
1. **Normalizes** every inbound alert format (Icinga2, Prometheus Alertmanager/Thanos and many more) into
   one canonical, versioned, enriched event, and publishes it to outputs such as NATS.
2. **Correlates** related alerts into incidents with a correct lifecycle.
3. **Notifies and automates** around those incidents.

It is a self-hosted, Postgres-only alert-management and correlation service. It is built for correctness under alert
storms rather than for breadth of shallow integrations.

## Users
- **Operators / on-call engineers:** watch the console during an outage, acknowledge and close incidents,
  silence noise, follow links to runbooks and dashboards. They need fast, live, dense views and actions
  they can trust.
- **Monitoring / platform engineers:** connect sources, write enrichment, correlation, routing and
  notification rules, and publish canonical events to their event bus. They need rules they can test
  before activating (simulator), versioned config and clear failure visibility.
- **Integrators / plugin authors:** consume the canonical event stream (NATS, webhooks), or write plugins
  in any language over gRPC.

## Boundaries
- Self-hosted only. No SaaS and no telemetry by default.
- Linux is the supported platform (owner, 2026-11-03; ADR 0014). Windows is not a target; if it is ever
  added, it is added as a CI job.
- PostgreSQL 16+ is the only database, in every mode. Embedded Postgres for development and tests.
- Single tenant in 1.0. The tenant is in the event format, fixed to `default`.
- Not a metrics, log or trace store. It never evaluates time series; it reacts to alerts and can query
  sources for context.
- No arbitrary code execution integrations (bash/python/ssh steps). Automation calls typed plugin actions.
- AI/LLM correlation is out of scope for 1.0. The data model keeps room for suggested-vs-committed
  correlations later.
- Plugins never redefine event identity, severity or status; the core owns those semantics.

## Success measures
- **No silent loss:** every accepted inbound alert is either in an incident/alert view, in an output's
  delivery record, in a visible dead-letter entry with replay, or in a recorded, policy-driven discard
  (dead-letter expiry or output overflow under `discard_new`). Verified by crash and restart tests.
- **Storm behaviour:** a burst of 10,000 alerts in 60 seconds on a reference single node (4 vCPU, 8 GB,
  local Postgres) is accepted without 5xx. It is processed with p95 ingest-to-console latency under 5 s
  once the burst ends, and yields one incident per correlation group.
- **Noise reduction:** the console shows the deduplication and correlation ratio per source. On the
  owner's real Icinga2 + Alertmanager traffic, operators work incidents, not alerts.
- **Integration reach at 1.0:** the P0 integrations (docs/plan/integrations.md) work end to end, each with a
  mapping table, fixtures from real payloads and a setup guide. P1 integrations meet the same definition of
  done, but ship in milestones or 1.x point releases and do not hold back 1.0 (owner, 2026-11-03, D27).

## Tracks
- **Ingest and normalization:** sources, decoders, the canonical event, enrichment.
- **Correlation and lifecycle:** alert state, incidents, noise control (silences, maintenance, flapping).
- **Delivery and automation:** outputs, notifications, workflows, ticketing.
- **Console and access:** Flutter web console, auth, RBAC, rule editors and simulators.
- **Platform:** plugin host and SDKs, operations, performance, packaging, upgrades.

## Assumptions
Decided without the owner's answer (owner instruction 2026-11-02: plan the roadmap autonomously). Each one
is a candidate question.
1. First users are the owner's own environments: Icinga2 and Prometheus/Alertmanager/Thanos at work-like
   scale, about 1-5k monitored hosts.
2. There is no legacy data to migrate. The Python version's database is disposable, and no consumer needs
   its `/v1` or Vigilo-compatible API (legacy audit, owner questions 1 and 9).
3. Monitored-object identity is scoped per source instance by default. An operator can declare sources
   that share a namespace (legacy question 2; ADR 0019).
4. The threshold policy is selectable per correlation rule: distinct active alerts (default), distinct
   hosts, or event count (legacy question 3).
5. Ordering authority is effective source time (source time clamped to observed time + 5 min skew), then
   observed time, then event id, per alert. An older event never overrides a newer state. Events older than
   a 7-day lateness horizon are kept as evidence but change no state (legacy question 4; ADR 0017).
6. Notifications fire on incident open, on escalation and on resolve, with reminders while unacknowledged.
   They are delivered at least once, and duplicates are possible and documented (legacy question 5).
7. Acknowledgement means "someone owns it": it records an owner, can be removed or transferred, and never
   changes status (legacy question 7).
8. Rules are edited in the console with versioning and rollback, and can also be provisioned from YAML
   files (GitOps). Provisioned rules are read-only in the UI (legacy question 12).
9. Licence: open source, to be chosen by the owner before the first public release.
10. Manual close of an incident with still-firing alerts keeps them attached and does not reopen it; a new
    transition of one of them opens a new incident linked to the closed one (legacy question 6).
11. Sign-up is invite-only; the first admin comes from a one-time bootstrap token (ADR 0009).

## Decision summary
<!-- Written by roadmap runs in every mode. One run line per run, then one table; rows are never deleted. -->
<!-- Run line: `- <run> <YYYY-MM-DD>: <mode> (source: setting)` or `(source: user, "<words>")`; <run> is `init`, `close M<n>` or `pack <name>`. -->
<!-- Chosen by: `agent`, `user`, or `pending` (awaiting the owner). A pending or agent row the owner later settles is updated in place to `user` with the answer. -->

- close M1 2026-11-18: autonomous (source: setting)
- roadmap cuts 2026-11-23: autonomous (source: setting); the owner's four cuts of 2026-11-22, relayed by the coordinator

| # | Run | Decision | Choice | Rejected | Reason | Important | Chosen by |
|---|---|---|---|---|---|---|---|
| R1 | close M1 | Split of M2 | Six changes: source model and secrets; Icinga2 ingest; Thanos and generic webhook; matcher rules and versions; rule simulator and query enricher; dead letters, backpressure and retention | One change per source; a single enrichment change | Sources, namespaces and credentials come first because every source and rule depends on them; the rule engine is split from the simulator and enricher to keep each change about one PR | yes | agent |
| R2 | close M1 | Order of the M2 changes | The source model first, then the two source changes, then rules, then the simulator, then dead letters and retention | Dead letters before the sources | Replay with the configuration active at replay time (DUR-13) needs the declarative mapping of change 3 to exist | no | agent |
| R3 | close M1 | Golden fixtures in M2 | Captured from real Icinga2 and Thanos releases, never hand-authored | Fixtures written from the documentation | M1's real-Alertmanager check failed on fields the documentation omitted (0.32+), which cost a gap-closing change | yes | agent |
| R4 | close M1 | M1 user criterion evidence | Real Alertmanager v0.35.0 in Docker against a dev instance, seen by the owner in the console and on a NATS subscriber, firing and resolved | A production Alertmanager | The owner has no production Alertmanager; the runbook's isolated check uses the real release binary, and the owner chose it ("we have to fake it") and verified the result on 2026-11-18 | no | user |
| R5 | roadmap cuts | M8 integration wave and plugin SDKs | Moved after 1.0, into 1.x | Keeping them in M8 | Owner's cut of 2026-11-22 | yes | user |
| R6 | roadmap cuts | Pre-ship review rounds | At most 4 per change; after round 4 the owner decides whether to continue, ship or rework | Specwright's built-in stop after 2; no cap | Owner's cut of 2026-11-22 | yes | user |
| R7 | roadmap cuts | Minimal container image and compose file | Pulled forward from M10 to the end of M3 | Leaving all packaging in M10 | Owner's cut of 2026-11-22 | yes | user |
| R8 | roadmap cuts | M3 console | A read-only incident list, so the M3 replay check is done in the UI | Checking the replay through the API | Owner's cut of 2026-11-22 | yes | user |
| R9 | roadmap cuts | Milestone numbering after M8 leaves | M8 is retired, not reused; M9 and M10 keep their names | Renumbering M9 and M10 to M8 and M9 | Accepted ADR 0018 and archived changes name M8 and M10, and they are never edited; renumbering would make them point at the wrong milestone | no | agent |
| R10 | roadmap cuts | Where the review cap lives | `review.preship_max_rounds: 4` in `openspec/specwright.yaml`, read by a patched `specwright-review` skill, with the rule in `AGENTS.md` | Prose in the roadmap only | Specwright 0.19.0 has no round-cap setting and hard-codes 2; only a key the skill reads changes what the review loop does | no | agent |
| R11 | roadmap cuts | M3 exit check for the packaging | An agent check that compose starts Correlia from the image and an Alertmanager webhook shows up as an incident in the list | No new exit criterion | The pulled-forward packaging needs a test that proves it runs | no | agent |
| R12 | roadmap cuts | Questions the cuts force | D32 (what the minimal image includes), D33 (which M8 plugin items stay in M10), D34 (what the incident list shows), D35 (what a review round counts) | Deciding them in the plan | They are product scope and process choices for the owner | yes | pending |
