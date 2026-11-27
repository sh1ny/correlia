# Correlia Roadmap

Strategy: openspec/strategy.md · Architecture: openspec/architecture.md

<!-- Status is derived: a change is done when archived; a milestone is done when its changes are done and its exit criteria pass. Do not add status checkboxes for changes. -->

The long-form feature plan for every milestone up to 1.0 is in `docs/plan/milestones.md`. The integration
backlog is in `docs/plan/integrations.md`, the named acceptance scenarios in
`docs/plan/acceptance-scenarios.md`, and the owner's open decisions in `docs/plan/open-decisions.md`.

**Pre-ship review cap** (owner, 2026-11-22): every change gets at most 4 pre-ship review rounds. After
round 4, the owner decides whether to continue, ship or rework. The cap is `review.preship_max_rounds` in
`openspec/specwright.yaml`.

## Now: M2 - Icinga2, Thanos and the ingest track

**Outcome:** The owner's two real sources flow in, are enriched by rules that can be tested in a
simulator, and failures are visible and replayable. M2 retires the risk that real source payloads
(Icinga2 soft/hard states, flapping, acknowledgements) do not fit the canonical event and identity model.

**Exit criteria:**
- Golden fixtures for Icinga2 (webhook and Event Streams), Alertmanager and Thanos pass. Fixtures are
  captured from real releases, never hand-authored. (agent)
- Scenarios ORD-4, ORD-6, ORD-7, ID-2, ID-3, ID-7 (a), DUR-4, DUR-5, DUR-9, DUR-10, DUR-11, DUR-12,
  DUR-13, RUL-1, RUL-2, RUL-3, RUL-4, RUL-6, RUL-7, RUL-8, SEC-2 and SEC-3 pass as named tests. (agent)
- The owner's real Icinga2 and Alertmanager/Thanos feed a dev instance for a day, and the owner checks
  that the enriched events look right. (user)

**Changes** (in order; each about one PR):
1. `source-model-and-secrets`:
   - source instances with their own credentials (bearer or HMAC, rotation with overlap);
   - the namespace setting (D3; ID-2) and per-source rate and body limits;
   - display-field truncation that leaves identity untouched (ID-3);
   - encrypted plugin config secrets, never returned or logged (SEC-3).
2. `icinga2-ingest`:
   - the Icinga2 webhook (shipped notification command) with acknowledgements, downtimes and flapping;
   - SOFT states as information; a WARNING to CRITICAL change updates one alert's severity (ID-7 a);
   - captured golden webhook fixtures; skew clamp and late-event fence (ORD-4, ORD-6, ORD-7).

   Needs 1.
3. `icinga2-event-streams` (split from change 2 by the owner, 2026-11-19, after three design-review rounds):
   - the Event Streams API consumer (`StateChange`, acknowledgements, downtimes and flapping), with a
     per-source lease and bounded backpressure into Icinga 2. Decision S2 deliberately excludes `CheckResult`;
   - state sync on connect and its reconciliation ordering; the soft/hard state policy per source;
   - captured golden Event Streams fixtures.

   Needs 2.
4. `thanos-and-generic-webhook`:
   - Thanos Ruler through the Alertmanager decoder, tenant headers and a documented setup, with captured
     fixtures;
   - the generic webhook with a versioned declarative mapping document and a preview against a sample;
     activation rejects a mapping with neither an observation id nor a source time (RUL-8).

   Needs 1.
5. `matcher-rules-and-versions`:
   - matcher rules (ADR 0008): labels and tags, severity mapping, owner/team, links, hostname/CIDR tables,
     regex extraction with timeouts (RUL-3); a rule that times out on every event is skipped, counted
     and self-alerted (RUL-7);
   - one evaluator semantics in memory and as SQL over stored events (RUL-6);
   - rule set versions with atomic activation and rollback (RUL-4), YAML provisioning;
   - parameterized rule filters only (SEC-2); activation rejects unknown outputs (DUR-5).

   Needs 1.
6. `rule-simulator-and-classification` (query enrichment split out by the owner, 2026-11-25, after five
   design-review rounds):
   - the rule simulator API over a sample or a stored event, against the active or a draft rule set
     (RUL-1, RUL-2);
   - event classification (kind and noise class hints);
   - a simulator command line.

   The end-to-end demo moved to its own change (owner, 2026-11-25, after ten design-review rounds), and
   then to the end of the milestone (owner, 2026-11-25), so that it tests all of M2.

   Needs 5.
7. `query-enrichment`:
   - the Prometheus/Thanos query enricher with per-rule deadlines, evaluated outside the processing
     transaction. Change 6's design ("Handed to query-enrichment") lists the decisions already taken and
     the open review findings.

   Needs 6.
8. `dead-letters-backpressure-and-retention`:
   - the dead-letter list and replay API, in bulk by filter, replaying with the configuration active at
     replay time (DUR-4, DUR-13);
   - inbox lag bounds with 429/503 and `Retry-After` (DUR-9); output storage budgets (DUR-11);
   - raw inbox and event partitioning, drop by age, expiry to `discarded` (DUR-10, DUR-12).

   Needs 4.
9. `enrichment-demo` (moved to the end of M2 by the owner, 2026-11-25, so that one run tests all of M2's
   functionality):
   - a fully simulated end-to-end demo (`mise run demo:enrichment`): it starts NATS and the dev server,
     sends fake alerts from each M2 webhook source, compares the delivered events with an expected
     table, and the owner checks the console;
   - its expected table covers every M2 capability: each webhook source, matcher rules and
     classification, the simulator command line, query enrichment, and dead letters, replay and
     backpressure;
   - the process lifecycle it needs: per-run folders and locks, shutdown on parent death and on Ctrl-C.
     Change 6's design ("Handed to enrichment-demo") lists the decisions already taken and the open
     review findings.

   Needs 6, 7 and 8.

## Next: M3 - Correlation and incidents

Related alerts become incidents with a correct lifecycle under storms, and the legacy defects are proven
fixed: correlation rules with structured group-by keys, a threshold policy per rule (D4), time windows with
a quiet period and priority order; the incident lifecycle with acknowledgement orthogonal to status and the
manual close policy (D6); relational incident membership with a partial unique index on the open group
key; one transaction per event batch with serialization retries and hot-group handling; current versus
peak severity; incident events on NATS and webhook out; manual merge, split, link, owner and note through
the API. It retires the risk that grouping stays correct under a 10k/60 s storm on one hot group.

Two owner cuts of 2026-11-22 add to M3:
- a read-only incident list in the console (D34), so the owner checks the M3 replay of a recorded day
  of traffic in the UI rather than through the API;
- at the end of M3, a minimal container image and a compose file (D32), pulled forward from M10's
  packaging, so the owner can run Correlia outside the dev checkout.

## Later

- M4 - Console v1 and access control:
  - invite-only email OTP, roles, teams and API keys;
  - incident and alert views (extending M3's read-only incident list with filters, detail and actions);
  - rule editors and the simulator UI;
  - source wizards; plugin and system pages; REST `/api/v1/`.
- M5 - Noise control: silences, maintenance windows (including Icinga2 downtime sync), flapping, inhibition
  and noise-ratio insight.
- M6 - Notifications and routing:
  - a routing tree and policies, templates, reminders and escalation;
  - email, Slack, Teams, Mattermost, Telegram, PagerDuty and webhook-out.
- M7 - Workflows and ticketing: durable typed-action workflows, Jira and ServiceNow, two-way sync and
  runbooks.
- M8 - Moved after 1.0 (owner, 2026-11-22): the integration wave and the Go and Python SDKs are now the
  1.x integration wave below. The number M8 is retired, not reused, so M9 and M10 keep their names.
- M9 - Topology and context: the NetBox enricher, CMDB import, a service model, topology-aware
  correlation and context panels.
- M10 - Hardening for 1.0:
  - multi-instance; load and soak qualification; partition maintenance;
  - backup and restore; OIDC; OpenTelemetry;
  - packaging: the production image and compose (hardening M3's minimal ones), systemd and Helm;
  - the plugin install layout, a plugin lockfile with checksums and a protocol conformance suite for the
    first-party external plugins (kept from M8, D33);
  - a security review, docs and the licence.
- 1.0 - Stable release (owner, 2026-11-03, D27): the P0 integrations; event format, plugin protocol and
  `/api/v1/` declared stable under semver; every acceptance scenario green; documented upgrade and restore.
  The P1 integrations planned in M2, M6, M7 and M9 ship there or in 1.x point releases (M2's is the basic
  Prometheus/Thanos query enricher); the former M8 wave ships in 1.x.
- 1.x - Integration wave and plugin SDKs (moved from M8 by the owner, 2026-11-22):
  - the P1 monitoring sources;
  - Kafka;
  - NATS consume;
  - Go and Python SDKs with a conformance suite;
  - the signed-manifest option and the plugin catalog page (D33).
  At 1.0 only part of `correlia.plugin.v1` is frozen: the subprocess handshake, `PluginService`
  (`GetMetadata`, `Configure`, `CheckHealth`) and `OutputService` (`Deliver`); the other plugin kinds join it as additive minor versions in 1.x (D36).

## Done
- M1 - Walking skeleton (2026-11-18): Alertmanager to canonical event to NATS and the live console, on
  embedded Postgres in WSL. Learned: real releases differ from the documented payload (0.32+ fields), so
  decoders start from captured fixtures; and full-suite load exposed timing, port and shutdown races that
  took three gap-closing changes, so e2e and plugin tests get explicit deadlines and retries from the start.
