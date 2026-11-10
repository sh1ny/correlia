# canonical-event Specification

## Purpose

Defines the portable, bounded event contract and deterministic identities used by Correlia normalizers, state processing and output consumers.

## Requirements

### Requirement: Versioned canonical payload
The system SHALL define `correlia.event.v1` in protobuf with explicit snake_case JSON names, a generated v1.0 JSON Schema and validated Dart values. It SHALL separate kind, status, severity, resource and observer, and carry labels with origin evidence, annotations, links, raw reference, pipeline metadata and source/observed/processed times. Unspecified enums and missing required fields SHALL be rejected with a field path and error code.

#### Scenario: Complete event survives both representations
- **WHEN** a valid event with optional fields and map entries is serialized to protobuf and structured JSON and read back
- **THEN** both round trips retain its fields, explicit optional presence, identity and timestamp precision, and the payload JSON in CloudEvents `data` validates against the generated payload schema

#### Scenario: Invalid enum or absent required metadata
- **WHEN** an event has an unknown or unspecified kind/status/severity, missing fingerprint, source instance, summary, observed time, processed time, raw reference or pipeline metadata
- **THEN** validation fails with the offending field path and no valid event is returned

### Requirement: Structured CloudEvents envelope
Events SHALL use CloudEvents 1.0.2 structured JSON with `specversion` equal to `1.0`, `type` equal to `io.correlia.<kind>.v1`, an exact minor-version `dataschema`, JSON object `data`, and source-instance `source`. Envelope `id` SHALL equal the observation id; `subject` and `partitionkey` SHALL equal the fingerprint; `correliatenant` SHALL equal payload tenant. Optional `traceparent` SHALL be validated. Envelope and payload disagreement SHALL fail validation.

#### Scenario: Publish a canonical alert
- **WHEN** a validated alert is encoded as structured JSON
- **THEN** its media type is `application/cloudevents+json`, `datacontenttype` is `application/json`, `type` is `io.correlia.alert.v1`, the payload is an object rather than a JSON string, and the envelope identities match the payload

#### Scenario: Conflicting or unsupported envelope
- **WHEN** a structured event has a mismatched subject, tenant, source or id, unsupported schema major, invalid traceparent, or `data_base64` instead of canonical JSON data
- **THEN** validation fails with a field error before the event is usable

#### Scenario: Intermediary adds a valid extension
- **WHEN** an otherwise valid v1.0 CloudEvent includes an unknown top-level extension such as `brokertrace` with a valid CloudEvents scalar value
- **THEN** the reader accepts its known attributes and payload and ignores that extension without treating it as a payload-version change or promising lossless forwarding

#### Scenario: Invalid extension attribute
- **WHEN** an unknown envelope attribute has uppercase or punctuation in its name, or an object or array value
- **THEN** the reader returns an attribute field error rather than treating it as canonical payload data

### Requirement: Stable time evidence
Source evidence SHALL retain the reported timestamp text separately from normalized UTC timestamps. Valid source timestamps SHALL contain an explicit offset and at most nanosecond precision. Observation identity SHALL use reported evidence, never arrival time, processed time or a clamped effective timestamp. Optional CloudEvents `time` SHALL reflect the normalized source time when present and otherwise be omitted.

#### Scenario: Redelivery after clock clamping changes
- **WHEN** an observation with unchanged reported timestamp text is received at a different observed time and a later consumer clamps its effective time differently
- **THEN** its observation id is unchanged and its original evidence remains available

#### Scenario: Missing fallback evidence
- **WHEN** identity construction has neither a native observation key nor a reported source timestamp, or a supplied timestamp lacks an offset
- **THEN** it returns a field error rather than deriving an id from arrival time

### Requirement: Bounded event fields
Every string and collection SHALL have a documented bound enforced before a valid event is returned. Normalization SHALL truncate only display text with a visible marker, preserving valid Unicode; oversize identity values SHALL use tagged SHA-256 representations, never truncation. Wire readers SHALL reject over-bound values without silent mutation. Non-display oversize fields, excess collection entries and events over 256 KiB structured UTF-8 JSON SHALL return field errors.

#### Scenario: Display truncation and long identity
- **WHEN** normalization receives a 4097-scalar description and an identity value over its 1024-byte inline threshold
- **THEN** the description is at most 4096 scalars ending with a truncation marker, the identity retains a tagged full-value SHA-256 representation, and no prefix-only identity is used

#### Scenario: Collection or encoded size overflow
- **WHEN** a labels map exceeds 128 entries, an annotation exceeds its limit, or the encoded event exceeds 262144 bytes
- **THEN** validation returns an error identifying the bound without dropping entries or producing a valid event

#### Scenario: Raw metadata is independent of the default ingress limit
- **WHEN** an otherwise valid event references a raw body larger than the 1 MiB default but within uint32, under a source configured to accept it
- **THEN** raw.size represents that body without embedding it; the v1 maximum is 4294967295 bytes, and larger metadata is rejected

### Requirement: Unambiguous canonical tuple encoding
Identity inputs SHALL use ordered field-name/value pairs with UTF-8 byte-length prefixes and sorted label keys, SHA-256 fingerprints and UUIDv5 event ids under a fixed published Correlia namespace UUID. The contract SHALL publish exact byte vectors. Raw and hashed identity components SHALL be distinguishable. Unicode SHALL be preserved without normalization and malformed Unicode SHALL be rejected.

#### Scenario: ID-4 delimiter collision
- **WHEN** fingerprints are computed from `(host='a|service=b', service='c')` and `(host='a', service='b|service=c')` in the same scope
- **THEN** their canonical bytes and fingerprints differ

#### Scenario: Map order and Unicode length
- **WHEN** the same identity label map is supplied in different insertion orders with multibyte keys and values
- **THEN** its bytes and fingerprint equal the published vector regardless of insertion order, with lengths measured in UTF-8 bytes rather than UTF-16 code units

### Requirement: Namespace scoped alert identity
A fingerprint SHALL hash tenant, namespace, source kind and the decoder-declared identity fields. Alertmanager identity SHALL include the full label set including severity, minus explicit per-source exclusions. Normalized status/severity, display text and timestamps SHALL NOT independently affect fingerprints. Source instance SHALL affect observation identity even when instances share an alert namespace.

#### Scenario: ID-7b severity is identity by default
- **WHEN** Alertmanager warning and critical label sets differ only in severity with no exclusions
- **THEN** they yield different fingerprints and a critical resolve retains only the critical fingerprint; it cannot target the warning fingerprint

#### Scenario: ID-7c explicit severity exclusion
- **WHEN** severity is explicitly excluded and its label changes while other identity labels stay the same
- **THEN** the fingerprint is unchanged even though normalized severity changes

#### Scenario: Separate and explicitly shared namespaces
- **WHEN** equal labels are fingerprinted under two distinct namespaces, then under one shared namespace
- **THEN** the distinct namespaces produce distinct fingerprints, the shared namespace produces equal fingerprints, and distinct source instances still produce distinct observation ids

### Requirement: Delivery independent observation identity
An event id SHALL be UUIDv5 over canonical source instance, fingerprint, observation key and nonnegative pipeline generation. Alertmanager's observation key SHALL contain status and the original startsAt/endsAt evidence with explicit absent-field representation. Fallback keys SHALL contain status, severity and reported source time. Generation zero SHALL serve first processing and replay; a new reprocess generation SHALL change the id and retain the original id as lineage.

#### Scenario: ID-6 reordered and re-batched observations
- **WHEN** equal Alertmanager observations are reordered, split into new webhook bodies or redelivered with different arrival metadata at generation zero
- **THEN** each observation has the same event id across all deliveries, independent of body hash and array index

#### Scenario: Different observation or generation
- **WHEN** source-native observation evidence or pipeline generation changes while the fingerprint stays constant
- **THEN** the event id changes; a reprocessed payload carries its original event id

### Requirement: Transport identity is distinct from observation identity
Transport-key construction SHALL scope an explicit idempotency key to source instance when supplied, otherwise scope a raw-body SHA-256 to source instance. Header-based and body-based keys SHALL be domain separated. It SHALL NOT assign event ids from transport keys or implement a storage dedup window in this library.

#### Scenario: Exact transport retry
- **WHEN** identical body bytes and source instance are supplied twice without an idempotency key
- **THEN** the computed transport keys are equal, and changing source instance changes the key

#### Scenario: Distinct delivery evidence
- **WHEN** two differently batched bodies carry the same individual observations
- **THEN** their body-derived transport keys differ while their observation ids remain equal

### Requirement: Version aware validation and forward parsing
The v1 reader SHALL reject malformed known fields and unsupported majors. Exact-minor payload JSON SHALL reject undeclared fields outside namespaced extensions. Newer v1 minors SHALL parse known fields, ignore unknown JSON fields and report known-core-only validation. For protobuf input, the validated wrapper's protobuf output SHALL re-emit unknown field data. JSON output SHALL remain a known-field projection. Payload extensions SHALL stay in `data.extensions`.

#### Scenario: Namespaced extension retained
- **WHEN** a valid event carries a bounded `example.org/context` extension
- **THEN** the extension survives JSON and protobuf round trips unchanged

#### Scenario: Unsupported field or major version
- **WHEN** an exact-v1.0 event contains an undeclared payload field, an unnamespaced extension key or a v2 dataschema
- **THEN** the reader reports the field or unsupported major without silently discarding input

#### Scenario: UPG-3 older consumers parse a newer minor
- **WHEN** a v1.1 fixture adds an optional field and uses its exact v1.1 dataschema
- **THEN** v1.0 consumers parse the unchanged known core; JSON readers ignore unknown fields and report known-core-only validation, while the validated wrapper's protobuf output retains the newer field's number and wire value for a newer parser to recover

#### Scenario: Extensions have one location
- **WHEN** a structured event contains `data.extensions` with `example.org/context` and the declared envelope `partitionkey`
- **THEN** both survive unchanged, while placing `example.org/context` at the envelope top level of an exact-v1.0 document is rejected

### Requirement: Binary validation scope
Binary readers SHALL validate known fields without requiring source dataschema metadata. If supplied, metadata SHALL select the validation scope and unsupported majors SHALL fail. Without metadata, scope SHALL be unknown rather than claiming an exact minor. Binary parsing SHALL NOT infer a minor from the absence of optional fields.

#### Scenario: Newer binary minor omits its optional addition
- **WHEN** a v1.1 payload omits its new optional field and is read with optional source dataschema `urn:correlia:schema:event:1.1`
- **THEN** the known core parses and scope is known-core-only rather than being inferred as v1.0

#### Scenario: Binary input has no provenance
- **WHEN** a valid binary payload is read without source dataschema metadata
- **THEN** its known fields parse and validation scope is unknown; no exact-minor claim is returned

#### Scenario: Supplied binary provenance is invalid
- **WHEN** supplied binary dataschema metadata is malformed or identifies a v2 major
- **THEN** the reader returns a source_dataschema field error
