# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

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
