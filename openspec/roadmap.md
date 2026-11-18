# Correlia Roadmap

Strategy: openspec/strategy.md · Architecture: openspec/architecture.md

<!-- Status is derived: a change is done when archived; a milestone is done when its changes are done and its exit criteria pass. Do not add status checkboxes for changes. -->

The long-form feature plan for every milestone up to 1.0 is in `docs/plan/milestones.md`. The integration
backlog is in `docs/plan/integrations.md`, the named acceptance scenarios in
`docs/plan/acceptance-scenarios.md`, and the owner's open decisions in `docs/plan/open-decisions.md`.

## Now: M2 - Icinga2, Thanos and the ingest track

**Outcome:** The owner's two real sources flow in, are enriched by rules that can be tested in a
simulator, and failures are visible and replayable. M2 retires the risk that real source payloads
(Icinga2 soft/hard states, flapping, acknowledgements) do not fit the canonical event and identity model.

**Exit criteria:**
- Golden fixtures for Icinga2 (webhook and Event Streams), Alertmanager and Thanos pass. Fixtures are
  captured from real releases, never hand-authored. (agent)
- Scenarios ORD-4, ORD-6, ORD-7, ID-2, ID-3, DUR-4, DUR-5, DUR-9, DUR-10, DUR-11, DUR-12, DUR-13, RUL-1,
  RUL-2, RUL-3, RUL-4, SEC-2 and SEC-3 pass as named tests. (agent)
- The owner's real Icinga2 and Alertmanager/Thanos feed a dev instance for a day, and the owner checks
  that the enriched events look right. (user)

**Changes** (in order; each about one PR):
1. `source-model-and-secrets`:
   - source instances with their own credentials (bearer or HMAC, rotation with overlap);
   - the namespace setting (D3; ID-2) and per-source rate and body limits;
   - display-field truncation that leaves identity untouched (ID-3);
   - encrypted plugin config secrets, never returned or logged (SEC-3).
2. `icinga2-ingest`:
   - the Icinga2 webhook (notification command) and the Event Streams API consumer (`CheckResult`,
     `StateChange`, acknowledgements, downtimes, flapping);
   - state sync on startup; the soft/hard state policy per source;
   - captured golden fixtures for both paths; skew clamp and late-event fence (ORD-4, ORD-6, ORD-7).

   Needs 1.
3. `thanos-and-generic-webhook`:
   - Thanos Ruler through the Alertmanager decoder, tenant headers and a documented setup, with captured
     fixtures;
   - the generic webhook with a versioned declarative mapping document and a preview against a sample.

   Needs 1.
4. `matcher-rules-and-versions`:
   - matcher rules (ADR 0008): labels and tags, severity mapping, owner/team, links, hostname/CIDR tables,
     regex extraction with timeouts (RUL-3);
   - rule set versions with atomic activation and rollback (RUL-4), YAML provisioning;
   - parameterized rule filters only (SEC-2); activation rejects unknown outputs (DUR-5).

   Needs 1.
5. `rule-simulator-and-query-enricher`:
   - the rule simulator API over a sample or a stored event, against the active or a draft rule set
     (RUL-1, RUL-2);
   - the Prometheus/Thanos query enricher with per-rule deadlines;
   - event classification (kind and noise class hints).

   Needs 4.
6. `dead-letters-backpressure-and-retention`:
   - the dead-letter list and replay API, in bulk by filter, replaying with the configuration active at
     replay time (DUR-4, DUR-13);
   - inbox lag bounds with 429/503 and `Retry-After` (DUR-9); output storage budgets (DUR-11);
   - raw inbox and event partitioning, drop by age, expiry to `discarded` (DUR-10, DUR-12).

   Needs 3.

## Next: M3 - Correlation and incidents

Related alerts become incidents with a correct lifecycle under storms, and the legacy defects are proven
fixed: correlation rules with structured group-by keys, a threshold policy per rule (D4), time windows with
a quiet period and priority order; the incident lifecycle with acknowledgement orthogonal to status and the
manual close policy (D6); relational incident membership with a partial unique index on the open group
key; one transaction per event batch with serialization retries and hot-group handling; current versus
peak severity; incident events on NATS and webhook out; manual merge, split, link, owner and note through
the API. It retires the risk that grouping stays correct under a 10k/60 s storm on one hot group.

## Later

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
- M1 - Walking skeleton (2026-11-18): Alertmanager to canonical event to NATS and the live console, on
  embedded Postgres in WSL. Learned: real releases differ from the documented payload (0.32+ fields), so
  decoders start from captured fixtures; and full-suite load exposed timing, port and shutdown races that
  took three gap-closing changes, so e2e and plugin tests get explicit deadlines and retries from the start.
