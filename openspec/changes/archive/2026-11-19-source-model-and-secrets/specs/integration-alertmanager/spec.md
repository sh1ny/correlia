# Spec Delta

## MODIFIED Requirements

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
