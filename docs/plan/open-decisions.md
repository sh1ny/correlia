# Open decisions for the owner

The baseline was planned autonomously on 2026-11-03, on the owner's instruction. Every choice below was
made with a recommended default so planning could proceed. Each is a question for the owner. Answering
one changes the strategy, an ADR (through a superseding ADR) or a milestone; the "Affects" column says
where.

Status: all answered by the owner on 2026-11-03. Every default was confirmed except D11 and D13, which were
changed (the Owner answer column records the change). D18 is done.

| Id | Question | Assumed default | Why | Affects | Needed by | Owner answer (2026-11-03) |
|---|---|---|---|---|---|---|
| D1 | Who are the first users, and at what scale? | The owner's environments: Icinga2 + Prometheus/Alertmanager/Thanos, 1-5k hosts | Matches the owner's request | Strategy, load targets (M10) | M3 | Confirmed |
| D2 | Is there legacy data or a legacy API consumer to keep? | No. Legacy DB is disposable; no `/v1` or Vigilo-compatible API | The legacy audit found no real consumer in the repo | Strategy; no migration milestone | M1 | Confirmed |
| D3 | Are host/service names global or per source? | Per source instance; operators can declare shared namespaces | Avoids the legacy cross-source recovery hazard | ADR 0007, ID-2 | M2 | Confirmed |
| D4 | What does a correlation threshold count? | Selectable per rule: distinct active alerts (default), distinct hosts, or event count | The legacy code mixed these intuitions | ADR 0007, M3 | M3 | Confirmed |
| D5 | What wins in ordering, and what clock skew is allowed? | Effective source time (clamped to observed + 5 min skew), then observed time, then event id; 7-day lateness horizon | Fixes legacy B1 | ADR 0007, ORD-1..4 | M1 | Confirmed |
| D6 | After a manual close, what happens to still-firing alerts? | They stay attached to the closed incident and do not reopen it; a new transition of one of them starts a new incident linked to the old one | Operators close incidents to stop noise; re-firing is a real new signal | M3, COR-7 | M3 | Confirmed |
| D7 | When do notifications fire? | Open, escalation (severity up or threshold crossed), resolve; reminders while unacknowledged (default 30 min); at-least-once | The legacy "first crossing only, no retry" lost notifications | M6, DUR-6 | M6 | Confirmed |
| D8 | What does acknowledgement mean? | "Someone owns it": records the owner, can be removed or transferred, never changes status or silences | Orthogonal to status (legacy P1.4) | ADR 0007, M4 | M4 | Confirmed |
| D9 | Where are rules edited? | Console with versioning and rollback; also YAML provisioning (GitOps) where provisioned rules are read-only in the UI | Both audiences | M2, M4 | M2 | Confirmed |
| D10 | Licence | Open source; Apache-2.0 suggested (matches Serverpod, permissive for plugin authors) | Plugins in any language need a permissive interface licence | Repo | Before first public release | Confirmed |
| D11 | Retention and data sensitivity | Raw inbox 7 d, canonical events 30 d, activity ledger indefinite, delivered outbox 7 d; check output may contain secrets, so outputs can redact by rule | Bounds table growth | Architecture resource bounds, M10 | M2 | **Changed:** retention configurable per table; defaults raw inbox 30 d, canonical events 90 d (delivered outbox 7 d, ledger indefinite, redaction unchanged) |
| D12 | How is 1.0 deployed? | Container image + docker compose, a single static binary + systemd unit, and a Helm chart; HA (2+ instances) supported but not required | Serverpod supports all three | M10 | M9 | Confirmed |
| D13 | Which SSO first? | Generic OIDC (tested with Keycloak, Authentik and Entra ID) before 1.0; email OTP from M4 | Serverpod has no generic OIDC; we build one provider | ADR 0009, M10 | M9 | **Changed:** generic OIDC, automated tests against Keycloak and Authentik containers; Entra ID best-effort, not a test target |
| D14 | Is a Go toolchain acceptable in the build? | Yes, for external first-party plugins (NATS, Kafka, Kubernetes, syslog, SNMP, CloudWatch) | Mature client libraries; reference plugin for authors | ADR 0011 | M1 | Confirmed |
| D15 | Rule language for 1.0 | Declarative matcher (field paths, operators, regex with timeouts) only; CEL after 1.0 | Dart `cel` 0.6.1 is not mature enough | ADR 0008 | M2 | Confirmed |
| D16 | Plugin SDKs at 1.0 | Go SDK (wraps stock go-plugin) and Python SDK; plugin lockfile with checksums | Any-language promise needs at least two SDKs | M8 | M8 | Confirmed |
| D17 | When to re-enable push and create the GitHub repo? | When the owner decides; until then `finish: local` and the push URL is disabled | Owner instruction: no commits on the remote | Specwright `finish`, CI | Any time | Confirmed: stay local until the owner says |
| D18 | Upgrade Specwright to 0.17.0 (`decision_making: all`) before the first `next`? | Yes, as soon as v0.17.0 is tagged; then re-apply the #140 tools edit | Owner wants every decision presented at `next` | Specwright install | Before M1 starts | Done (f4576d8) |
| D19 | Console language(s) | English only for 1.0, with Flutter localization scaffolding in place | Cheap to keep the door open | M4 | M4 | Confirmed |
| D21 | Who can sign in? | Invite-only; optional allowed email domain joins as viewer; first admin via one-time bootstrap token | Email OTP alone proves only mailbox control | ADR 0009 | M4 | Confirmed |
| D22 | Storage budgets | Ingest backpressure at 85 % of the disk budget; per-output budget 500k rows / 1 GiB for pending + dead letters combined, overflow policy `discard_new` by default (`block_ingest` opt-in); dead letters kept 14 d | Never drop accepted work; isolate a failed output | ADR 0005 | M2 | Confirmed |
| D20 | Multi-tenancy | Single tenant in 1.0; the `tenant` field is fixed to `default` | Keeps 1.0 small without closing the door | ADR 0009 | After 1.0 | Confirmed |
