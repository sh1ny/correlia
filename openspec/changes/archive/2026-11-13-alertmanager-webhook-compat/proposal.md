# Proposal

## Why

The M1 close on 2026-11-12 showed the user-verified exit criterion failing: "the owner points a real
Alertmanager at a dev instance and sees the alerts in the console and on a NATS subscriber". Every webhook
from Alertmanager 0.35.0 failed the decode as `unknown_field`. Nothing reached the console or NATS, and the
pipeline failure row showed the field only as `*`.

Real payloads were captured from the latest patch of each Alertmanager minor, 0.16.2 to 0.35.0, firing and
resolved. The current decoder passes all of them through 0.33. It fails 0.34 and 0.35 on one top-level field,
`routeLabels`, added in 0.34. Every release sends `"version": "4"`, so the payload cannot tell which release
sent it. Alertmanager adds top-level fields over time (`notification_reason` in 0.32, `routeLabels` in 0.34),
so a decoder that fails every unknown top-level field breaks ingest at each such release, until Correlia ships
support. Operators cannot be asked to pin or downgrade their Alertmanager.

This change closes that M1 gap. The criterion stays user-verified and is judged at the next M1 close: the owner
re-runs the real-Alertmanager check (the Docker demo of 2026-11-12) against 0.35. A `[user]` task in tasks.md
records it, so the change cannot be archived as done before the owner has seen it work.

## What Changes

- Accept `routeLabels`, type-checked as a string map like `groupLabels`. It stays in the raw delivery as group
  metadata and is never substituted for alert fields or carried into the canonical event. The existing
  `externalURL` link mapping is unchanged.
- An unknown **top-level** field no longer fails the delivery. The alerts are processed. The delivery's raw
  processing result, on the same row as the raw body, records the sorted, bounded field names. A best-effort
  warning gives the source, the count and a short SHA-256 tag per name. Names and values never reach logs, since a
  name can itself be a credential.
- Unknown **per-alert** fields, and a known field with the wrong type, still fail the whole delivery with a field
  path, as today.
- `routeLabels` joins the field names allowed in failure paths and logs, so a failure inside it is named, not
  shown as `*`.
- A compatibility suite: one captured firing and one resolved payload per supported minor, 0.16 to 0.35, each
  decoded and checked for status and identity.
- `docs/ingest-pipeline.md` documents the supported Alertmanager versions and how unknown fields are treated.
  AGENTS.md's "reject unmapped fields loudly" rule gets this one exception.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `integration-alertmanager`: "Per alert webhook decoding" changes. Unknown top-level fields are processed and
  flagged instead of failing, `routeLabels` is a recognised group field, and supported releases are proven by
  version fixtures.

## Impact

- Code: `correlia_server/lib/src/ingest/alertmanager_decoder.dart` (top-level allowlist, `AlertmanagerBatch`),
  `correlia_server/lib/src/pipeline/pipeline.dart` (safe path names, the raw outcome JSON, the warning log).
- Tests: the decoder unit tests, new fixtures under `correlia_server/test/`, and the pipeline db test that reads
  the raw outcome.
- Canonical event contract (`correlia.event.v1`), identity (ADR 0019), ingress, outputs, schema and migrations:
  unchanged.
- Docs: `docs/ingest-pipeline.md`, `AGENTS.md`.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Unknown top-level fields are processed and flagged

- **Choice:** An unknown top-level field is recorded and warned about, and the alerts are processed. Unknown
  per-alert fields and wrong types on known fields still fail the delivery.
- **Rejected:** Keep failing every unknown field, which breaks ingest at each additive Alertmanager release.
  Tolerate unknown fields at every level, which hides a change to the fields that carry alert evidence.
- **Reversal cost:** low (one decoder rule and its tests)
- **Important:** yes: it changes behaviour operators see and relaxes a project rule in AGENTS.md
- **Chosen by:** user (owner, 2026-11-12: "Process + flag")

### S2: `routeLabels` stays raw-only group metadata

- **Choice:** Type-check `routeLabels` as a string map and keep it only in the raw delivery, like the other group
  fields.
- **Rejected:** Map it into the canonical event, which would change the `correlia.event.v1` contract and leak an
  integration-specific field past normalization.
- **Reversal cost:** low (a later change can map it once a consumer needs it)
- **Important:** no
- **Chosen by:** agent

### S3: No per-version decoding

- **Choice:** One decoder accepts the union of fields across supported releases, each optional where a release
  omits it. Per-minor fixtures prove every supported release.
- **Rejected:** A per-source `alertmanager_version` setting selecting a field map, which breaks on the day an
  operator upgrades without updating Correlia's configuration. Detecting the release from the payload is not
  possible: every release sends `version` `4`.
- **Reversal cost:** low
- **Important:** yes: it binds the supported-version contract operators read in the docs
- **Chosen by:** agent
