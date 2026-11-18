# Spec Delta

## MODIFIED Requirements

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

#### Scenario: ID-3 maximum length values through HTTP ingress
- **WHEN** an authenticated delivery carries an `instance` label of 256 bytes and a 4097-scalar description annotation, and a second delivery repeats it with only the description's last scalar changed
- **THEN** both receive 202, the stored events' descriptions are 4096 scalars ending with the truncation marker, the label is stored whole, both events share one fingerprint, and no request or pipeline step returns or records a 500-class failure
