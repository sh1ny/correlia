# integration-alertmanager Specification

## Purpose

Convert Alertmanager webhook v4 observations into portable canonical alerts with explicit field mapping, stable identity and accountable validation failures.

## Requirements

### Requirement: Per alert webhook decoding

The system SHALL decode webhook version `4` into one kind `alert` canonical event per supplied alert, using each alert's own firing/resolved status, labels and annotations rather than group status or common-field substitution. Empty groups SHALL complete with zero events. Nonzero truncatedAlerts SHALL be retained and counted as upstream omissions without fabricating missing alerts. Unknown per-alert fields SHALL fail with a field path; unknown top-level fields follow top-level field tolerance.

#### Scenario: Mixed group and upstream truncation
- **WHEN** a v4 group marked firing contains firing and resolved alerts and a nonzero truncatedAlerts count
- **THEN** event statuses match individual alerts, exactly the supplied alerts are emitted and the omission count is durably visible on the raw processing result

#### Scenario: Unsupported version or malformed member
- **WHEN** a group has an unsupported version, an unknown per-alert field, invalid status or a non-string label/annotation value
- **THEN** the whole raw delivery fails with a field path and no canonical event or output intent from that delivery commits

#### Scenario: Empty group
- **WHEN** a structurally valid v4 notification contains an empty alerts array
- **THEN** its raw delivery completes with zero events and its upstream omission count remains visible

### Requirement: Canonical identity from original labels

Alert identity SHALL use source namespace and the full original label set, including severity unless explicitly excluded, via the canonical identity contract. Observation ids SHALL use source instance, fingerprint, per-alert status and original startsAt/endsAt strings at generation zero. The upstream fingerprint SHALL be evidence only, stored as `correlia.io/alertmanager_fingerprint` in extensions, never injected into identity labels.

#### Scenario: ID-6 rebatching and fingerprint independence
- **WHEN** identical observations are reordered/rebatched and their upstream fingerprint metadata changes
- **THEN** each canonical fingerprint and event id remains equal across deliveries while the upstream evidence remains available without becoming an identity input

#### Scenario: ID-7b and ID-7c severity labels
- **WHEN** warning and critical observations differ only in severity, first under default identity and then with severity explicitly excluded
- **THEN** default fingerprints differ and excluded-severity fingerprints match; a resolved critical observation cannot identify the warning alert under the default

#### Scenario: Empty selected identity
- **WHEN** source exclusions remove every original label
- **THEN** the raw delivery fails with an identity-field error and no arrival-derived fingerprint, event or output intent is created

### Requirement: Explicit timestamp evidence

The decoder SHALL validate offset-bearing timestamps without arrival-time fallback. Firing source time SHALL be startsAt; resolved source time SHALL be a nonzero endsAt. Original timestamp strings, including a supplied zero-time endsAt, SHALL remain observation-key evidence. Zero-time endsAt on firing alerts SHALL not become a canonical resolution time. Missing/zero required source time or reversed nonzero interval SHALL fail the delivery.

#### Scenario: Firing zero end and resolved end
- **WHEN** a firing alert carries startsAt plus Alertmanager's year-1 zero endsAt and a resolved alert carries a valid nonzero interval
- **THEN** firing source_time equals startsAt, its canonical ends_at is absent, resolved source_time equals endsAt, and both observation keys preserve the exact supplied timestamp strings

#### Scenario: Invalid source evidence
- **WHEN** a required time is absent/zero, a timestamp has no offset, or a nonzero endsAt precedes startsAt
- **THEN** decoding fails with the alert's field path and does not derive source time or observation identity from arrival time

### Requirement: Bounded explicit display and metadata mapping

The decoder SHALL map critical/error/warning/info exactly and preserve bounded original text for unknown severity. Use the first nonempty summary annotation, alertname label or `Alertmanager alert`. Project the original description at 4096 scalars and its stored annotation at 1024. Mark truncated display text, annotation values and labels; derive identity from complete originals. Reject other canonical map or count overflow and require canonical HTTP(S) links.

#### Scenario: Display and provenance mapping
- **WHEN** a bounded alert contains labels, annotations, unknown severity text, generatorURL and a long display summary
- **THEN** severity is unknown with its original text, summary is visibly truncated, maps are preserved, generatorURL is a generator link, and raw/source/config provenance is present in the structured CloudEvent

#### Scenario: Map or aggregate event overflow
- **WHEN** an alert exceeds a canonical map/count/key or annotation count/key bound, an identity's original-input byte bound, or the structured event's aggregate byte bound
- **THEN** the complete raw delivery fails with a bound-specific field error; entries are not silently removed to force acceptance

#### Scenario: Oversize identity label projection
- **WHEN** an original label exceeds the canonical label-value limit but fits original-identity input bounds
- **THEN** its full original value determines the tagged identity hash, its label projection is visibly truncated, and equal display prefixes with different full originals still produce different fingerprints

#### Scenario: Oversize annotation value
- **WHEN** an alert's description annotation exceeds the canonical annotation value bound
- **THEN** the delivery completes and the stored annotation visibly truncates; the display description is whole up to its own bound and visibly truncates beyond it. Full original text remains in raw bytes, and the fingerprint and event id are unchanged.

#### Scenario: ID-3 maximum length values through HTTP ingress
- **WHEN** an authenticated delivery carries an `instance` label of 256 bytes and a 4097-scalar description annotation, and a second delivery repeats it with only the description's last scalar changed
- **THEN** both receive 202 and their exact, distinct bodies are stored; only one event is emitted and the second delivery records a duplicate observation. The event has the whole label, a 4096-scalar description and a 1024-scalar stored description annotation, both ending with the truncation marker. Neither delivery nor processing returns or records a 500-class failure.

### Requirement: Recognised group metadata

The decoder SHALL recognise the top-level fields Alertmanager 0.16 to 0.35 sends: version, status, alerts, receiver, groupKey, groupLabels, commonLabels, commonAnnotations, externalURL, truncatedAlerts, notification_reason and routeLabels; only version, status and alerts are required. Each SHALL be type-checked, a wrong type failing the delivery with its path. Group metadata SHALL never replace per-alert evidence; only externalURL keeps its existing link mapping.

#### Scenario: Group metadata of a current release
- **WHEN** a notification carries a string notification_reason and a routeLabels object of string values, including an empty routeLabels object
- **THEN** the delivery completes, and each alert's fingerprint, event id, status, labels, annotations, severity, summary and links equal those decoded from the same notification without those two fields; raw reference, size, digest, observed_at and processed_at may differ; each event retains its own delivery's correct raw metadata and supplied observation and processing timestamps, and neither field appears in the canonical event

#### Scenario: externalURL link is kept
- **WHEN** a notification carries a nonempty canonical HTTP(S) externalURL
- **THEN** each alert's event keeps the Alertmanager link derived from it, as before this change

#### Scenario: Wrong-typed group metadata
- **WHEN** routeLabels is not an object of string values, or notification_reason is not a string
- **THEN** the whole raw delivery fails with the field path `routeLabels` or `notification_reason` (a named path, never `*`) and no canonical event or output intent from that delivery commits

### Requirement: Top-level field tolerance

An unknown top-level field SHALL NOT fail the delivery; its alerts SHALL be processed as if it were absent. The raw processing result SHALL list the first 16 unknown names, sorted, that are 1-64 letters, digits, `_`, `.` or `-`, and count the rest. After commit the worker SHALL log, best-effort, one warning with the source, the unknown-field count and a 12-hex SHA-256 tag per listed name; never a name or a value.

#### Scenario: A future Alertmanager adds a field
- **WHEN** an otherwise valid notification carries an unknown top-level field `newField`
- **THEN** its alerts become canonical events and output intents with the same identity and alert content as without the field, the raw processing result lists `newField`, and one warning gives the source, a count of 1 and the tag of `newField`, without the name `newField` or its value

#### Scenario: Credential-shaped unknown key
- **WHEN** an otherwise valid notification carries a top-level key that is a 43-character base64url string equal to a source token
- **THEN** the delivery completes, the key appears only in the raw body and the raw processing result, and no log line contains it

#### Scenario: Many or oversized unknown names
- **WHEN** a notification carries 20 unknown top-level fields, one with a 300-character name
- **THEN** the delivery completes, the raw processing result lists the first 16 valid names and counts the other 4 including the 300-character one, and the warning gives a count of 20 and 16 tags

#### Scenario: Worker dies between commit and warning
- **WHEN** the worker stops after the delivery's transaction commits and before the warning is written
- **THEN** the raw processing result still lists the unknown names, the delivery is not processed again, and no later warning is required

#### Scenario: Unknown field inside an alert stays fatal
- **WHEN** an alert object carries an unknown field
- **THEN** the whole raw delivery fails with that alert's field path, as before this change

### Requirement: Supported Alertmanager releases

Notifications from the latest patch of every Alertmanager minor release from 0.16 to 0.35 SHALL decode without failure and without being flagged, for both firing and resolved notifications, with per-alert identity unaffected by the release that sent them.

#### Scenario: Every supported release decodes
- **WHEN** the captured firing and resolved notification of each supported minor release is decoded
- **THEN** each completes with its alert in the captured status, records no unknown top-level field, and alerts with the same labels produce the same canonical fingerprint across all releases

#### Scenario: Release without fingerprint or truncatedAlerts
- **WHEN** a notification from 0.16 to 0.18 omits truncatedAlerts and the per-alert fingerprint
- **THEN** the delivery completes with zero upstream omissions and the alert's identity equals that of the same alert from a release that sends both

### Requirement: Thanos Ruler through Alertmanager

Thanos Ruler alerts SHALL be received as Alertmanager notifications on an `alertmanager` source; there SHALL be no
Thanos source kind. Notifications captured from the latest patch of each of the last four Thanos minor releases,
through one pinned Alertmanager release, SHALL decode with identity equal to the same labels sent by Alertmanager alone.

#### Scenario: Every captured Thanos release decodes
- **WHEN** the captured firing and resolved notification of each covered Thanos release is decoded
- **THEN** each completes with its alert in the captured status, and alerts with the same labels produce the same fingerprint across all covered releases

#### Scenario: Thanos source kind
- **WHEN** a version 2 source declares kind `thanos`
- **THEN** activation fails with a field error naming `sources[i].kind`, and the prior snapshot stays active

### Requirement: Thanos fixtures are captured, never hand-authored

Each Thanos fixture SHALL be recorded by the capture tool from real Ruler, Alertmanager and query containers with
valid HTTP(S) external and generator URLs, and listed in a manifest naming those images and digests. The fixture
test SHALL fail on a file without an entry, an entry without its file, a missing release, run or status of the
pinned matrix, or a run without both replicas' sent-alert evidence.

#### Scenario: Manifest matches the fixtures
- **WHEN** the fixture test runs over the Thanos fixture directory
- **THEN** every fixture has a manifest entry with the Thanos, Alertmanager and query image names and digests, and every entry has its fixture

#### Scenario: Capture matrix incomplete
- **WHEN** the manifest and fixtures of one release lack the resolved notification of the drop run, though files and entries still match
- **THEN** the fixture test fails naming that release, run and status

#### Scenario: Replica evidence missing
- **WHEN** a run's manifest entry shows no rise in one Ruler replica's sent-alert counter
- **THEN** the fixture test fails naming that run and replica

#### Scenario: Fixture added by hand
- **WHEN** a Thanos fixture file is present that the manifest does not list
- **THEN** the fixture test fails naming that file

### Requirement: Ruler HA replicas share one identity

The documented Thanos setup SHALL keep Ruler's HA replica label out of identity, by dropping it in Ruler or by
listing it in the source's `excluded_identity_labels`. With either, the same rule fired by two Ruler replicas
SHALL yield one fingerprint; with neither, the documentation SHALL state that the replicas yield two. If the capture
shows Ruler cannot drop the label, Thanos support SHALL NOT be claimed until the owner decides the setup.

#### Scenario: Two Ruler replicas, replica label excluded
- **WHEN** two Ruler replicas fire the same rule, differing only in the replica label, and the source excludes that label
- **THEN** both notifications yield the same fingerprint

#### Scenario: Replica label dropped by Ruler
- **WHEN** both Ruler replicas send the rule, each send shown by that replica's own sent-alert counter, and Ruler drops the replica label
- **THEN** the captured notifications carry no replica label and yield one fingerprint with no identity exclusions on the source

#### Scenario: Replica label kept in identity
- **WHEN** the same two notifications arrive at a source that neither excludes nor drops the replica label
- **THEN** they yield two distinct fingerprints, as the setup documentation states

### Requirement: One source per Thanos tenant

A multi-tenant Thanos deployment SHALL map each tenant to its own `alertmanager` source with its own credentials
and namespace. Correlia SHALL NOT read a tenant from any request header, so a tenant header on a delivery SHALL
change neither identity nor routing.

#### Scenario: Two tenants with equal labels
- **WHEN** two tenants' Alertmanagers send alerts with equal labels to two sources with distinct namespaces
- **THEN** the alerts have distinct fingerprints and distinct event ids

#### Scenario: Tenant header on a delivery
- **WHEN** the same notification is delivered twice to one source with distinct `Idempotency-Key` values, once with a `THANOS-TENANT: team-a` header and once without
- **THEN** two raw rows are processed, both decode to the same fingerprint and event id, and the second is a duplicate observation
