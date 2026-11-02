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
- **Integration reach at 1.0:** P0 and P1 integrations (docs/plan/integrations.md) work end to end, each
  with a mapping table, fixtures from real payloads and a setup guide.

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
   that share a namespace (legacy question 2; ADR 0012).
4. The threshold policy is selectable per correlation rule: distinct active alerts (default), distinct
   hosts, or event count (legacy question 3).
5. Ordering authority is effective source time (source time clamped to observed time + 5 min skew), then
   observed time, then event id, per alert. An older event never overrides a newer state. Events older than
   a 7-day lateness horizon are kept as evidence but change no state (legacy question 4; ADR 0007).
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
