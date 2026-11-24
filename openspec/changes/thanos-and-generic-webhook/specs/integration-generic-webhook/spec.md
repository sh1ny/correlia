# Spec Delta

## Purpose

Lets any sender that can POST JSON become a Correlia source: a versioned, declarative mapping document turns
each delivery into canonical events, with the same identity, time and bound guarantees as a built-in decoder.

## ADDED Requirements

### Requirement: Named versioned mapping documents

The bootstrap configuration SHALL accept a top-level `mappings` list. Each mapping SHALL have a unique `name`
and `mapping_format: 1`, and SHALL publish and activate atomically with the sources in the configuration
snapshot. An unknown field, an unsupported `mapping_format`, a duplicate name, or a file over the 64 KiB configuration
cap SHALL fail activation with a bounded error.

#### Scenario: Mapping published with its source
- **WHEN** a configuration declares mapping `checks` with `mapping_format: 1` and a `generic` source naming it
- **THEN** activation succeeds, and a row of that source first claimed while this snapshot is active is decoded with `checks`

#### Scenario: Unsupported mapping format
- **WHEN** a mapping declares `mapping_format: 2`
- **THEN** activation fails with a field error naming `mappings[i].mapping_format`, and the prior snapshot stays active

#### Scenario: Mappings over the file cap
- **WHEN** a configuration file grows over 64 KiB because of its mappings and is published from disk
- **THEN** activation fails with a bounded file-size error, and the prior snapshot stays active

#### Scenario: Duplicate mapping name
- **WHEN** two mappings are both named `checks`
- **THEN** activation fails with a field error naming the second `mappings[i].name`

### Requirement: Fields are selected by JSON Pointer

Every field a mapping reads SHALL be named by a JSON Pointer (RFC 6901) into one alert object. A pointer that is
not valid RFC 6901 syntax SHALL fail activation. A pointer that selects nothing in a delivery SHALL count as an
absent field.

#### Scenario: Key containing dots and slashes
- **WHEN** a mapping reads `/labels/kubernetes.io~1name` and the alert has label `kubernetes.io/name: api`
- **THEN** the selected value is `api`

#### Scenario: Invalid pointer
- **WHEN** a mapping declares the pointer `labels/host`, which lacks the leading `/`
- **THEN** activation fails with a field error naming that pointer's field path

### Requirement: Activation requires observation identity evidence

A mapping SHALL declare at least one identity field and a source time pointer, and MAY declare an observation
id pointer. Activation SHALL refuse a mapping without a source time pointer, so no generic event id or ordering is
ever derived from arrival time (RUL-8).

#### Scenario: Mapping with a source time only
- **WHEN** a mapping declares identity field `host` and a source time pointer but no observation id
- **THEN** activation succeeds

#### Scenario: RUL-8 neither observation id nor source time
- **WHEN** a mapping declares identity fields but neither an observation id pointer nor a source time pointer
- **THEN** activation fails with a field error naming `mappings[i].source_time`, and the prior snapshot stays active

#### Scenario: Observation id without a source time
- **WHEN** a mapping declares identity fields and an observation id pointer but no source time pointer
- **THEN** activation fails with a field error naming `mappings[i].source_time`, and the prior snapshot stays active

#### Scenario: No identity field
- **WHEN** a mapping declares an observation id pointer but no identity field
- **THEN** activation fails with a field error naming `mappings[i].identity`

### Requirement: Batched payloads through an items pointer

A mapping MAY declare an `items` pointer selecting an array of at most 1000 alerts; without it the body is one
alert. A delivery whose `items` pointer selects no array SHALL fail with that pointer named. Decoding SHALL stop
and fail the row once its decoded text passes 16 MiB, before more events are built.

#### Scenario: Copies that expand past the decode budget
- **WHEN** a mapping copies one 900-byte field into 128 labels and a delivery holds 1000 alerts
- **THEN** decoding stops once the decoded bytes pass 16 MiB, the row fails with `decode_bound`, and no event commits

#### Scenario: Three alerts in one delivery
- **WHEN** a delivery's `items` array holds three alerts with distinct identity fields
- **THEN** three events commit, one per element

#### Scenario: Items pointer selects an object
- **WHEN** the `items` pointer selects an object instead of an array
- **THEN** the raw row fails with an error naming the `items` pointer and no event commits

### Requirement: Generic alert identity

A generic fingerprint SHALL hash tenant, namespace, kind `generic` and the mapping's identity fields, whose values
SHALL be JSON strings, with the canonical tuple encoding. The observation key SHALL be the observation id when
mapped, else status, severity and reported source time. Batch position and arrival SHALL NOT affect either.

#### Scenario: ID-6 re-batched generic alerts
- **WHEN** the same two alerts arrive once in one delivery and again as two single deliveries, in reverse order
- **THEN** each alert has the same fingerprint and event id in both deliveries

#### Scenario: Missing identity value
- **WHEN** an alert has no value at one of the mapping's identity field pointers
- **THEN** the raw row fails with an identity-field error naming that pointer, and no event or output intent commits

#### Scenario: Identity value that is not a string
- **WHEN** an identity pointer selects the JSON number `1` in one alert
- **THEN** the raw row fails with `identity_type` naming that pointer, so it never shares an identity with the string `"1"`

#### Scenario: Observation id absent in one alert
- **WHEN** a mapping declares an observation id pointer and an alert lacks a value there
- **THEN** the raw row fails with a field error naming the pointer, and no fallback or arrival-derived id is used

### Requirement: Status and severity value tables

A mapping SHALL declare `status` as a value table and `severity` as a value table or constant level. Table inputs
SHALL be JSON strings or integers; a default covers only unlisted values. An absent value, another type, or an
unlisted value with no default SHALL fail the raw row, naming the pointer, never the value.

#### Scenario: Mapped status and severity
- **WHEN** a mapping maps status `OK` to `resolved` and severity `CRIT` to `critical`, and an alert carries those values
- **THEN** the event is a resolved event with severity `critical`

#### Scenario: Unlisted value with a default
- **WHEN** an alert's severity value is not in the table and the table declares default `warning`
- **THEN** the event's severity is `warning`

#### Scenario: Status value absent
- **WHEN** the status pointer selects nothing in an alert and the status table declares a default
- **THEN** the raw row fails with a field error naming the status pointer; the default is not used

#### Scenario: Unlisted value without a default
- **WHEN** an alert's status value is not in the table and the table declares no default
- **THEN** the raw row fails with a field error naming the status pointer, and the failure evidence holds no payload value

### Requirement: Declared time formats

Each time pointer SHALL declare `rfc3339`, `epoch_seconds` or `epoch_millis`. An epoch value SHALL be a JSON integer
from 0 to year 9999; its reported evidence SHALL be its UTC RFC 3339 rendering, with no fraction for seconds and
three digits for millis. RFC 3339 text is kept as sent. Other values SHALL fail the row; times use the skew clamp.

#### Scenario: Epoch milliseconds
- **WHEN** a source time pointer declared `epoch_millis` selects `1795497600123`
- **THEN** the event's source time and its reported evidence are both `2026-11-24T05:20:00.123Z`, and the same value in another delivery gives the same event id

#### Scenario: Fractional or negative epoch value
- **WHEN** a pointer declared `epoch_seconds` selects `1795497600.5`, or `-1`
- **THEN** the raw row fails with a field error naming that pointer, and no rounded time is used

#### Scenario: RFC 3339 without an offset
- **WHEN** a pointer declared `rfc3339` selects `2026-11-24T05:20:00`
- **THEN** the raw row fails with a field error naming that pointer

#### Scenario: ORD-4 future source time
- **WHEN** a mapped source time is 3 hours after its observed time
- **THEN** the stored event records an effective time of observed time plus 5 minutes, the raw outcome counts one clamped observation, and the published `source_time` is the reported time

### Requirement: Display fields copy or take a constant

A mapping SHALL declare `summary` and MAY declare `description`, up to 128 `labels` and 16 `links`, each copying a
pointer or taking a constant; no templates. Activation SHALL refuse a constant the event could not hold. Long
display text SHALL be truncated with the marker. A copied non-scalar or non-http(s) link SHALL fail the row.

#### Scenario: Copied and constant display fields
- **WHEN** a mapping copies `/check/output` into the description and sets label `team` to the constant `ops`
- **THEN** the event's description is that output and its labels include `team: ops`

#### Scenario: ID-3 long display text
- **WHEN** a copied description is 5000 scalars long
- **THEN** the description is truncated to 4096 scalars with the truncation marker and the fingerprint equals that of the same alert with a short description

#### Scenario: Link that is not a URL
- **WHEN** a link copies `/runbook` and an alert carries `see wiki` there
- **THEN** the raw row fails with a field error naming `/runbook`

#### Scenario: Empty summary constant
- **WHEN** a mapping declares `summary: {constant: ""}`
- **THEN** activation fails with a field error naming `mappings[i].summary`

#### Scenario: Mapping without a summary
- **WHEN** a mapping declares no `summary`
- **THEN** activation fails with a field error naming `mappings[i].summary`

#### Scenario: Object copied into a display field
- **WHEN** the summary pointer selects a JSON object
- **THEN** the raw row fails with a field error naming the summary pointer

### Requirement: Unmapped payload fields

Each mapping SHALL declare `unmapped_fields` as `reject` (the default) or `count`. Under `reject` an alert with a
field the mapping does not read SHALL fail the raw row, naming the field paths with each segment the mapping does
not itself name stored as `*`. Under `count` such fields SHALL be counted on the raw outcome, never by name or value.

#### Scenario: Extra field rejected by default
- **WHEN** a mapping without `unmapped_fields` reads `/labels/host` and receives an alert carrying `/labels/token`
- **THEN** the raw row fails with an error naming `/labels/*`, no event commits, and `token` appears in no stored error, log or metric

#### Scenario: Preview names the full path
- **WHEN** the same alert is sent to the mapping preview
- **THEN** the preview lists `/labels/token` as unmapped, because the preview stores nothing

#### Scenario: Extra fields counted
- **WHEN** a mapping with `unmapped_fields: count` receives an alert carrying two fields it does not read
- **THEN** the event commits and the raw outcome records two unmapped fields, with no field name or value

### Requirement: Mapping preview

A read-only method under the console access policy SHALL map a sample (1 MiB, 100 alerts) with the source's active
mapping or a draft, returning the decoded events, whether decoding and the per-row budget would fail the row, and
unmapped paths and field errors in alert then path order up to 100 entries and 64 KiB, plus an overflow count.

#### Scenario: Preview with a draft mapping
- **WHEN** the method is called in development mode from loopback with a sample of two alerts and a draft mapping
- **THEN** it returns two events with their fingerprints and event ids, the unmapped field paths, and no raw row, event, output intent or snapshot is created

#### Scenario: Preview of a sample with several errors
- **WHEN** a sample holds one valid alert and two alerts each with a different field error
- **THEN** the result holds the valid alert's event, both field errors with their pointers, and states that the row would fail

#### Scenario: Diagnostics over the cap
- **WHEN** a sample's diagnostics repeat a long escaped ancestor path until they exceed 64 KiB before 100 entries
- **THEN** the result holds the diagnostics that fit in alert and path order, and an overflow count of the rest

#### Scenario: Row over the per-row budget
- **WHEN** every alert of a sample maps successfully but the events and their output fan-out exceed the per-row budget
- **THEN** the result states that the row would fail with `batch_bound`

#### Scenario: Preview of an invalid draft
- **WHEN** the draft mapping declares no source time pointer
- **THEN** the method returns the same validation error activation would, and no event

#### Scenario: Preview outside the console access policy
- **WHEN** the method is called from a client the console access policy does not admit
- **THEN** the call is refused and no sample is decoded
