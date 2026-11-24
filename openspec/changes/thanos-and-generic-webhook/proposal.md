# Proposal

## Why

M2 needs the owner's second real source, Thanos, and a way to take alerts from senders that have no
integration of their own. Thanos Ruler cannot call Correlia directly: it fires into Alertmanager, so
today a Thanos user has no tested setup, no captured fixtures and no answer for Ruler HA replicas or
multi-tenant deployments. And every other sender needs either a new decoder or nothing; a generic
webhook driven by a declarative mapping document closes that gap without code per sender.

This change is M2 change 4 (`openspec/roadmap.md`, Now). It advances these M2 exit criteria:
- golden fixtures for Thanos pass, captured from real releases, never hand-authored (agent);
- scenario RUL-8 passes as a named test (agent);
- the owner's real Alertmanager/Thanos feeds a dev instance for a day (user): this change supplies the
  documented Thanos setup that run uses; the criterion itself is judged at the M2 close, once changes 5
  and 6 have added the enrichment the owner checks.

It is constrained by ADR 0008 (declarative matcher; source mappings publish in the one immutable
configuration version), ADR 0016 (durable staged pipeline, configuration pins), ADR 0019 and ADR 0024
(identity: a mapping declares an observation id or a source time, never arrival time), and D20 (one
tenant, `default`, in 1.0).

## What Changes

- **Thanos through Alertmanager.** Thanos Ruler is supported as a documented and tested configuration:
  Ruler sends to Alertmanager, which posts to an ordinary Correlia `alertmanager` source. No new source
  kind. The setup drops Ruler's HA replica label so replicas never split one alert into two identities.
- **One source per Thanos tenant.** A multi-tenant Thanos deployment maps each tenant to its own
  Correlia source, with its own credentials and namespace. Correlia reads no tenant header; the setup
  documents the tenant header Ruler itself sends to Thanos Query or Receive.
- **Captured Thanos fixtures.** The Alertmanager capture tool is extended to run real Thanos Ruler
  releases through a pinned Alertmanager and record the deliveries Correlia receives, with a manifest of
  the images and digests used.
- **Generic webhook source kind.** A new source kind accepts JSON deliveries and turns them into
  canonical events through a mapping document: which fields give identity, observation id, source time,
  status, severity and display fields. It reuses the existing source authentication, limits, durable
  admission and decode-by-kind pipeline.
- **Versioned mapping documents in the bootstrap configuration.** Mapping documents are written in the
  bootstrap configuration file (JSON), carry their own format version, and activate atomically with the sources in the
  immutable configuration snapshot. Activation validates every mapping and rejects one that declares
  neither an observation id nor a source time (RUL-8).
- **Mapping preview.** A read-only API method, under the console access policy, maps a pasted sample with
  the active mapping or a draft one and returns the events it would produce, with every unmapped or
  rejected field. It stores nothing.

## Capabilities

### New Capabilities
- `integration-generic-webhook`: the generic webhook source kind, its versioned mapping document,
  how a delivery is decoded through a mapping into canonical events, and the mapping preview.

### Modified Capabilities
- `integration-alertmanager`: Thanos Ruler deliveries through Alertmanager become a supported, fixture-
  tested setup, including the HA replica label and the one-source-per-tenant rule.
- `source-ingress`: the supported kinds gain the generic webhook; the configuration format carries
  mapping documents; activation validates them and refuses a mapping without an observation id or a
  source time.
- `durable-pipeline`: rows of the new kind decode through their pinned mapping, including the failure
  path's safe field naming.

## Impact

- Server: `ingest/source_config.dart` (new kind, mapping documents in format version 2 configuration),
  `ingest/bootstrap.dart` and `ingest/config_repository.dart` (validation and activation), a new generic
  decoder beside `ingest/alertmanager_decoder.dart`, `ingest/source_decoder.dart` and
  `pipeline/pipeline.dart` (dispatch and safe failure paths), `ingest/ingress.dart` (route for the new
  kind), a new read-only endpoint for the preview, and generated protocol code for its models.
- Tooling: `tool/alertmanager_capture.sh` (Thanos Ruler capture), new fixtures under
  `correlia_server/test/unit/ingest/fixtures/`.
- Docs: the Thanos setup and the mapping document format (runbooks beside
  `docs/runbooks/alertmanager-compatibility.md`).
- No new dependencies are expected; the capture runs Docker images on the developer machine only.
- No database migration is expected beyond what storing mapping documents in the configuration
  snapshot needs; design decides.

## Decision Making

DECISION_MAKING: important
- **Source:** setting

### S1: How Thanos is supported

- **Choice:** No new source kind. Thanos Ruler → Alertmanager → a Correlia `alertmanager` source is a
  documented, tested setup, with fixtures captured from real Ruler releases through a pinned Alertmanager,
  and the Ruler HA replica label dropped so replicas do not split identity.
- **Rejected:** a separate `thanos` kind reusing the Alertmanager decoder: a new configuration value with
  no behaviour behind it, which every later change would have to carry.
- **Reversal cost:** low
- **Important:** yes (binds future changes: the set of source kinds is a configuration contract)
- **Chosen by:** user (owner via Ormy, 2026-11-24: "S1a")

### S2: What "tenant headers" means

- **Choice:** Each Thanos tenant maps to its own Correlia source with its own credentials and namespace.
  Correlia reads no tenant header; the setup documents the tenant header Ruler sends to Thanos Query or
  Receive.
- **Rejected:** Correlia reading a configured header (such as `THANOS-TENANT`) into a namespace or label:
  a new raw-row field and identity rule, while D20 already rules out tenants inside Correlia.
- **Reversal cost:** medium
- **Important:** yes (changes behaviour and settings users see; binds the raw row format)
- **Chosen by:** user (owner via Ormy, 2026-11-24: "S2a")

### S3: Where mapping documents live in this change

- **Choice:** In the bootstrap configuration file (JSON) only, inside the immutable configuration snapshot and
  activated atomically with the sources (ADR 0008). Console and database editing come in M4 (D9).
- **Rejected:** database-managed mapping versions with a create/activate API now: a second activation
  path before the console exists, and work M4 does anyway.
- **Reversal cost:** medium
- **Important:** yes (binds future changes: the configuration format)
- **Chosen by:** user (owner via Ormy, 2026-11-24: "S3a")

### S4: The mapping preview

- **Choice:** A read-only API method under the console access policy: it takes a sample payload and the
  active mapping or a draft one, returns the events it would produce and every unmapped or rejected
  field, and stores nothing.
- **Rejected:** a CLI command only (no path for the M4 console); both (two surfaces to keep equal).
- **Reversal cost:** low
- **Important:** yes (changes behaviour users see: a new API method)
- **Chosen by:** user (owner via Ormy, 2026-11-24: "S4a")

### S5: Operator replay after a mapping fix

- **Choice:** Out of scope. DUR-13 (replay with the configuration active at replay time, D26) stays in
  change 7, `dead-letters-backpressure-and-retention`, as the roadmap plans; this change only makes the
  mapping a configuration that a later replay can re-pin to.
- **Rejected:** adding replay here: it belongs with the dead-letter list and replay API.
- **Reversal cost:** low
- **Important:** no (follows the roadmap; nothing here binds the replay design)
- **Chosen by:** agent

### S6: Which Thanos releases are captured

- **Choice:** The latest patch of the last four Thanos minor releases, each through one pinned current
  Alertmanager release.
- **Rejected:** only the latest Thanos (no evidence across releases); every minor (cost without a
  matching risk, since Ruler's sending path is stable).
- **Reversal cost:** low
- **Important:** no (fixture coverage, easy to extend)
- **Chosen by:** agent
