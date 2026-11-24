# Spec Delta

## Purpose

Lets any sender that can POST JSON become a Correlia source: a versioned, declarative mapping document turns
each delivery into canonical events, with the same identity, time and bound guarantees as a built-in decoder.

## ADDED Requirements

### Requirement: Named versioned mapping documents

The bootstrap configuration SHALL accept a top-level `mappings` list. Each mapping SHALL have a unique `name`
and `mapping_format: 1`, and SHALL publish and activate atomically with the sources in the configuration
snapshot. An unknown field, an unsupported `mapping_format` or a duplicate name SHALL fail activation with a
bounded field error.

#### Scenario: Mapping published with its source
- **WHEN** a configuration declares mapping `checks` with `mapping_format: 1` and a `generic` source naming it
- **THEN** activation succeeds and rows admitted for that source are pinned to the snapshot holding `checks`

#### Scenario: Unsupported mapping format
- **WHEN** a mapping declares `mapping_format: 2`
- **THEN** activation fails with a field error naming `mappings[i].mapping_format`, and the prior snapshot stays active

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

A mapping SHALL declare at least one identity field, and an observation id pointer, a source time pointer, or
both. Activation SHALL refuse a mapping that declares neither, so no generic event id is ever derived from
arrival time (RUL-8).

#### Scenario: Mapping with a source time only
- **WHEN** a mapping declares identity field `host` and a source time pointer but no observation id
- **THEN** activation succeeds

#### Scenario: RUL-8 neither observation id nor source time
- **WHEN** a mapping declares identity fields but neither an observation id pointer nor a source time pointer
- **THEN** activation fails with a validation error naming the mapping, and the prior snapshot stays active

#### Scenario: No identity field
- **WHEN** a mapping declares an observation id pointer but no identity field
- **THEN** activation fails with a field error naming `mappings[i].identity`

### Requirement: Batched payloads through an items pointer

A mapping MAY declare an `items` pointer selecting an array; each element SHALL then be decoded as one alert,
and without it the whole body SHALL be one alert. A delivery whose `items` pointer selects no array SHALL fail
with that pointer named.

#### Scenario: Three alerts in one delivery
- **WHEN** a delivery's `items` array holds three alerts with distinct identity fields
- **THEN** three events commit, one per element

#### Scenario: Items pointer selects an object
- **WHEN** the `items` pointer selects an object instead of an array
- **THEN** the raw row fails with an error naming the `items` pointer and no event commits

### Requirement: Generic alert identity

A generic alert's fingerprint SHALL hash tenant, namespace, kind `generic` and the mapping's identity fields as
ordered name/value pairs, using the canonical tuple encoding. Its observation key SHALL be the declared
observation id when present, else status, severity and the reported source time. Batch position and arrival
SHALL NOT affect either.

#### Scenario: ID-6 re-batched generic alerts
- **WHEN** the same two alerts arrive once in one delivery and again as two single deliveries, in reverse order
- **THEN** each alert has the same fingerprint and event id in both deliveries

#### Scenario: Missing identity value
- **WHEN** an alert has no value at one of the mapping's identity field pointers
- **THEN** the raw row fails with an identity-field error naming that pointer, and no event or output intent commits

#### Scenario: Observation id absent in one alert
- **WHEN** a mapping declares only an observation id pointer and an alert lacks a value there
- **THEN** the raw row fails with a field error naming the pointer, and no arrival-derived id is used

### Requirement: Status and severity value tables

A mapping SHALL derive status (`firing` or `resolved`) and severity from value tables keyed by the sender's
value, each with an optional declared default. A value missing from its table with no default SHALL fail the
raw row, naming the pointer, never the value.

#### Scenario: Mapped status and severity
- **WHEN** a mapping maps status `OK` to `resolved` and severity `CRIT` to `critical`, and an alert carries those values
- **THEN** the event is a resolved event with severity `critical`

#### Scenario: Unlisted value with a default
- **WHEN** an alert's severity value is not in the table and the table declares default `warning`
- **THEN** the event's severity is `warning`

#### Scenario: Unlisted value without a default
- **WHEN** an alert's status value is not in the table and the table declares no default
- **THEN** the raw row fails with a field error naming the status pointer, and the failure evidence holds no payload value

### Requirement: Declared time formats

Each time pointer SHALL declare its format: `rfc3339`, `epoch_seconds` or `epoch_millis`. The reported text or
number SHALL be kept as source evidence, and the normalized source time SHALL go through the existing skew
clamp. An RFC 3339 value without an offset, or a value of another format, SHALL fail the raw row.

#### Scenario: Epoch milliseconds
- **WHEN** a source time pointer declared `epoch_millis` selects `1795497600123`
- **THEN** the event's source time is 2026-11-24T05:20:00.123Z and the reported evidence is `1795497600123`

#### Scenario: RFC 3339 without an offset
- **WHEN** a pointer declared `rfc3339` selects `2026-11-24T05:20:00`
- **THEN** the raw row fails with a field error naming that pointer

#### Scenario: ORD-4 future source time
- **WHEN** a mapped source time is 3 hours after its observed time
- **THEN** the stored event records an effective time of observed time plus 5 minutes, the raw outcome counts one clamped observation, and the published `source_time` is the reported time

### Requirement: Display fields copy or take a constant

A mapping's display fields (summary, description, labels and links) SHALL each copy one pointer's value or take
a literal constant; no templating. Display text over its bound SHALL be truncated with the marker, without
changing identity. A copied value that is not a string or number SHALL fail the raw row.

#### Scenario: Copied and constant display fields
- **WHEN** a mapping copies `/check/output` into the description and sets label `team` to the constant `ops`
- **THEN** the event's description is that output and its labels include `team: ops`

#### Scenario: ID-3 long display text
- **WHEN** a copied description is 5000 scalars long
- **THEN** the description is truncated to 4096 scalars with the truncation marker and the fingerprint equals that of the same alert with a short description

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

A read-only API method, under the console access policy, SHALL map a sample payload with the source's active
mapping or a draft mapping sent with the request, and SHALL return the events it would produce and every
unmapped, rejected or invalid field. It SHALL store nothing and publish nothing.

#### Scenario: Preview with a draft mapping
- **WHEN** the method is called in development mode from loopback with a sample of two alerts and a draft mapping
- **THEN** it returns two events with their fingerprints and event ids, the unmapped field paths, and no raw row, event, output intent or snapshot is created

#### Scenario: Preview of an invalid draft
- **WHEN** the draft mapping declares neither an observation id nor a source time
- **THEN** the method returns the same validation error activation would, and no event

#### Scenario: Preview outside the console access policy
- **WHEN** the method is called from a client the console access policy does not admit
- **THEN** the call is refused and no sample is decoded
