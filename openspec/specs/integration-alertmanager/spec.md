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

Severity SHALL map exact critical/error/warning/info values and otherwise unknown, preserving bounded original severity. Summary SHALL choose nonempty annotation summary, then nonempty label alertname, then `Alertmanager alert`; description SHALL use annotation description. Display text, annotation values and label projections SHALL truncate with a marker; identity SHALL use complete originals. Other canonical map/count bounds SHALL reject overflow; links SHALL be canonical HTTP(S).

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
- **THEN** the delivery completes, its annotation and description projections visibly truncate, full original text remains in raw bytes, and its fingerprint and event id are unchanged

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
