# Spec Delta

## ADDED Requirements

### Requirement: Reproducible event contract generation
`mise run proto` SHALL generate Dart event types, a payload JSON Schema and Dart bound constants from protobuf with standard annotations and pinned Linux tools, without global plugins. Identical inputs SHALL produce identical bytes. Generation failure SHALL name the stage and exit non-zero. The check/proto task chains SHALL prepare pinned validator dependencies automatically, with network needed only to fill missing first-run caches.

#### Scenario: Generate in a fresh clone
- **WHEN** pinned mise tools and Dart dependencies are installed in a clean clone with no Node validator modules and `mise run proto` runs twice
- **THEN** its task chain installs the pinned validator dependencies without a manual step and both runs produce byte-identical Dart, payload schema and bound constants

#### Scenario: Generator cannot run
- **WHEN** a required pinned plugin cannot run or protobuf input is invalid
- **THEN** generation exits non-zero naming the tool or input error instead of reporting current outputs

### Requirement: Event compatibility gate
`mise run check` SHALL lint protobuf and run Buf FILE breaking checks against the committed v1.0 descriptor baseline. Existing v1.0 field rules and enum domains SHALL remain unchanged, including scalar, collection and numeric bounds. Optional additions SHALL pass without editing the baseline; deleting or renaming fields, reusing numbers or adding required fields SHALL fail. The gate SHALL fail if its baseline is missing.

#### Scenario: Add optional bounded field
- **WHEN** a candidate minor contract adds an optional bounded field without altering existing fields
- **THEN** compatibility checks pass against the initial baseline without changing its bytes

#### Scenario: Existing value domains cannot widen in a minor
- **WHEN** a v1.1 candidate increases summary maxLength from 256 to 512 or widens an existing collection limit or numeric range
- **THEN** compatibility fails naming the changed constraint; a new optional field or major is required because older readers retain the original limits

#### Scenario: Break existing consumers
- **WHEN** a candidate removes a v1.0 field, changes its JSON name, reuses its number, changes its validation rules or adds a required field
- **THEN** compatibility checks exit non-zero naming the incompatible change

#### Scenario: Missing compatibility baseline
- **WHEN** the committed v1.0 descriptor baseline is missing
- **THEN** the compatibility gate fails rather than skipping or silently rebuilding it

### Requirement: Generated event outputs are current
`mise run check` SHALL regenerate event outputs in disposable scratch space and compare every generated file in both directions. Missing, extra or changed outputs SHALL fail with paths and the regeneration command. The check SHALL NOT modify the checkout and SHALL remove its scratch files on success or failure. Existing Serverpod generation verification SHALL remain enabled.

#### Scenario: Current contract outputs
- **WHEN** the committed Dart event code, payload JSON Schema and bound constants match regeneration
- **THEN** the check exits successfully without changing checkout files

#### Scenario: Deleted or obsolete output
- **WHEN** a generated schema is missing or an obsolete generated Dart file remains
- **THEN** the check fails naming each differing path and `mise run proto`, leaves checkout bytes unchanged and removes scratch files

### Requirement: Payload schemas have executable fixture validation
Generated payload schemas SHALL be checked with a pinned validator supporting their schema draft. Validation SHALL cover the canonical JSON representation, required presence, scalar limits, map entry/key/value limits and timestamp formats. This is a build-time check; runtime readers SHALL additionally enforce identity consistency, decoded byte limits and aggregate wire bounds.

#### Scenario: Canonical payload is schema valid
- **WHEN** a positive payload fixture contains snake_case fields, numeric bounded raw size, a nanosecond timestamp and base64 byte data
- **THEN** the generated payload schema accepts it with the pinned draft-2020-12 validator

#### Scenario: Payload constraints reject invalid values
- **WHEN** payload fixtures omit a required field, use an undeclared alias, exceed a string or map-entry bound, or contain an invalid timestamp
- **THEN** the generated schema validator rejects each fixture at its offending field

### Requirement: Shared patterns match complete field values
Contract string patterns SHALL be anchored whole-value patterns using syntax shared by RE2, ECMA-262 and Dart. Generated-schema and runtime validation SHALL reject strings containing only a valid substring rather than a valid complete value.

#### Scenario: Valid source-kind token
- **WHEN** schema and runtime validators receive source kind `alertmanager`
- **THEN** both accept it as a complete valid token

#### Scenario: Valid substring does not validate the whole token
- **WHEN** schema and runtime validators receive source kind `Bad-Kind!alertmanager`
- **THEN** both reject it despite its valid `alertmanager` substring
