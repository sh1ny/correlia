## Purpose

Lets operators enrich normalized events with declarative rules and publish or restore those rules without changing work already pinned to an earlier configuration.

## ADDED Requirements

### Requirement: Declarative matcher enrichment

The system SHALL parse matcher documents against a typed field catalog and persist their language and format version. Conditions SHALL support equals, not_equals, regex, in, cidr, exists and glob with all, any and not. Rules SHALL support labels and tags, severity mapping, owner/team, runbook and dashboard links, hostname/CIDR tables and bounded regex extraction without changing identity.

#### Scenario: Match and enrich a normalized event
- **WHEN** a rule matches an event and sets metadata, maps severity, looks up site/environment and extracts a captured value
- **THEN** the resulting event carries the configured enrichment and keeps its event ID, fingerprint and observation identity

#### Scenario: Enrichment cannot alter alert state or reconciliation
- **WHEN** a matcher maps a retained event's severity, and the same mapping would make an otherwise-confirming observation appear to diverge
- **THEN** the retained event and its delivery payloads carry the mapped severity, live alert state keeps the original severity, and the confirming observation remains a confirmation without creating a retained event or delivery

#### Scenario: Rules do not chain or replace source routes
- **WHEN** an early rule changes a field, later conditions or extraction read that field, and several successful rules add the same output
- **THEN** conditions and extraction read the original normalized event, successful writes apply in document order with later scalar or key writes winning and links appended, and output routes are the deduplicated union of source and successful-rule routes

#### Scenario: Matcher routes follow source delivery eligibility
- **WHEN** a deliverable stale webhook and a stale Icinga stream event each match an additive route
- **THEN** the webhook gets both source and matcher routes; the Icinga stream event gets neither

#### Scenario: Reject invalid operands before activation
- **WHEN** a rule uses an unknown field, an invalid label or annotation key, or an operand incompatible with its field type
- **THEN** validation rejects the document with a field error and the active snapshot is unchanged

#### Scenario: Matcher language and version survive publication
- **WHEN** an operator publishes a supported matcher document and a worker reads it by its pinned snapshot
- **THEN** the persisted document identifies the same language and version; attempts to activate unsupported or missing discriminators leave the active snapshot unchanged

#### Scenario: Reject nonportable regex syntax
- **WHEN** a matcher or extraction uses backreferences, lookaround, inline flags, engine-specific escapes, a counted repeat greater than 255, or a pattern whose expanded complexity exceeds the shared limit
- **THEN** the shared parser rejects the pattern before either engine compiles it or the configuration activates

### Requirement: Stored and in-memory condition parity

The system SHALL evaluate the same typed condition tree in memory and against stored events, with matching results for missing fields, nulls, case, severity order and wildcard values. SQL expressions SHALL come from the field catalog and bind all rule values; only declared glob syntax SHALL act as a wildcard.

#### Scenario: RUL-6 condition corpus agrees in both evaluators
- **WHEN** the same corpus of events and conditions is evaluated in memory and filtered from PostgreSQL
- **THEN** the matching event IDs agree, including for missing and null values, case and wildcard characters, and both evaluators order severity as critical > error > warning > unknown > info

#### Scenario: Historical text with NUL stays distinct
- **WHEN** the corpus contains pre-change stored events with U+0000, U+0001, literal escape text, and reserved punctuation
- **THEN** both evaluators agree for literal, membership, wildcard and regex matching without conflating them or changing stored payloads

#### Scenario: A page with no matches still advances
- **WHEN** the first candidate page contains no matches, the next page contains a matching row, and several candidates share the same observed time
- **THEN** the first page returns a continuation and the matching row appears exactly once across the pages

#### Scenario: SEC-2 SQL-shaped input is only data
- **WHEN** a rule filter uses SQL fragments or SQL wildcard characters as a literal operand
- **THEN** only events matching that literal are returned and the filter does not change query structure or stored data

#### Scenario: Stored filter budget expiry is not a negative match
- **WHEN** PostgreSQL cancels a matcher filter that reaches its statement budget
- **THEN** the caller receives a filter error, not an empty or partial result

### Requirement: Atomic matcher publication and restore

The ingest input SHALL accept YAML and JSON with matcher definitions and separate secrets. A new snapshot SHALL require an expected active ID for matcher changes, reject any supplied mismatch, and publish atomically. Rollback SHALL republish current configuration with earlier rules at a higher revision and the expected active ID. Identical restart from that file SHALL accept its original expectation without activating another snapshot. Activation SHALL NOT rewrite pins.

#### Scenario: RUL-4 workers switch at a version boundary
- **WHEN** a new snapshot activates while work is pinned to the old one and an operator subsequently republishes the old matcher set at a higher revision
- **THEN** each worker uses one complete snapshot per claim boundary, later unpinned claims observe the newly active snapshot, and existing pins still refer to their original snapshots

#### Scenario: Concurrent publication invalidates a prepared restore
- **WHEN** a higher-revision rollback file expects A but B rotates a credential and removes an output before it acquires the publication lock, even if B happens to have the rollback's matcher content
- **THEN** publication rejects the file, B stays active, and neither the old credential nor the removed output returns

#### Scenario: A successful rollback restarts from the exact same file
- **WHEN** a publisher exits after a guarded rollback commits and the operator restarts using the exact normal file that published it
- **THEN** the same revision and snapshot remain active, with current credentials and unchanged pins, without creating another snapshot

#### Scenario: Older workers cannot commit under matcher pins
- **WHEN** an older worker tries to claim a matcher-bearing pin, update a pinned outcome, or finalize reconciliation by deleting a pending matcher-pinned row
- **THEN** the pin or outcome mutation is blocked, prior effects in the same transaction including sync progress roll back, and an upgraded worker can process the row with the pinned matcher set

#### Scenario: DUR-5 unknown output blocks activation
- **WHEN** a matcher configuration references an output absent from the candidate registry, including an empty registry
- **THEN** validation rejects activation, names the missing output and leaves the active snapshot unchanged

#### Scenario: A pending matcher pin retains its output material
- **WHEN** a publication imports a secret required solely by an output removed from the active registry, while a pending matcher pin can still reach that output and no intent exists yet
- **THEN** the import is checked against the historical commitment; correct material is accepted and the pending row can route by its pinned output definition, while different material is rejected

#### Scenario: Pending and live routes share the existing output capacity
- **WHEN** a first pin races a candidate publication and the candidate registry plus a removed route reachable from that pending pin would exceed 64 distinct output IDs
- **THEN** if pinning wins, publication rejects before the route becomes an intent; if publication wins, the newly pinned row sees only the new registry
- **AND** a candidate within the bound restarts identically after a pending route becomes a live intent

#### Scenario: Legacy over-capacity work can drain before upgrade
- **WHEN** a populated pre-upgrade database has a pending pin to an output outside the 64 active output IDs
- **THEN** cutover fails without installing either fence or changing pins, old workers can drain that work, and after draining the upgrade and identical restart succeed

#### Scenario: NUL operands do not break existing snapshot readers
- **WHEN** a matcher with a literal U+0000 operand is published, a snapshot reader admits Icinga stream evidence, and a worker reads the pinned matcher
- **THEN** admission can read the snapshot and the worker distinguishes that literal from U+0001 and the literal escape text

### Requirement: Isolated runtime rule failure

A runtime rule failure SHALL leave no partial rule effects. The event SHALL continue, the failure SHALL count against its pinned snapshot and rule, and the first failure for that pair SHALL emit one durable activity-feed notice (the self-alert), not an ingest alert or output delivery. Runtime failure SHALL NOT publish, replace or disable configuration. An operator fix SHALL use normal publication and validation.

#### Scenario: RUL-3 regex computation exhausts its budget
- **WHEN** a regex evaluation or extraction times out
- **THEN** that rule is skipped and counted for the pinned version, and the event continues through the remaining rules and pipeline

#### Scenario: Regex worker exits before readiness or exhausts its regex budget
- **WHEN** the regex worker exits before readiness or the regex-only budget is exhausted across events in one raw row, before the shared write reserve
- **THEN** affected regex rules are skipped and counted, eligible non-regex work continues, and processing does not wait for a replacement worker for that row

#### Scenario: Optional matcher work leaves time to commit the skip
- **WHEN** a controlled clock reaches the shared optional cutoff during a regex or non-regex rule step
- **THEN** the incomplete patch is discarded and counted, previously admitted effects and baseline work commit, later optional evaluations do not start and are reported separately rather than counted as failing rules, and no raw retry attempt is consumed

#### Scenario: Late action failure discards all staged changes
- **WHEN** a rule stages a label and route then fails a later action and another rule succeeds
- **THEN** neither staged effect leaks, the later rule's effects commit, the failure is counted only if the event commits, and the stored and delivered events carry the same bounded sanitized diagnostic when it fits

#### Scenario: Matcher additions exceed the raw batch fanout budget
- **WHEN** otherwise admissible events in a raw batch would exceed the fanout budget only after applying a matcher patch
- **THEN** only that whole patch is skipped and counted, later fitting patches and all source routes remain, and the raw batch commits within its pre-existing bound

#### Scenario: A losing quarantine insert does not reserve matcher capacity
- **WHEN** another transaction wins a concurrent quarantine insert and a later patch fits only if the losing candidate is not charged
- **THEN** the losing candidate uses no baseline capacity and produces no matcher failure count, the fitting patch commits, and the quarantine event exists once without an output intent

#### Scenario: A diagnostic does not overflow the event wire bound
- **WHEN** a matcher fails on an otherwise valid event with room in the raw batch but no room for another diagnostic in the event
- **THEN** the event and its matching delivery bytes commit without an overflowing diagnostic, and the matcher failure still counts

#### Scenario: RUL-7 repeated timeouts do not publish configuration
- **WHEN** a rule times out on every event across multiple workers
- **THEN** each event continues, each committed failure counts against the pinned snapshot and rule, exactly one activity notice exists for that pair, and the active snapshot is unchanged

#### Scenario: RUL-7 operator publishes a correction
- **WHEN** an operator publishes a higher-revision replacement for a failing rule
- **THEN** a valid correction activates only for new pins, and a correction referencing a removed output is rejected without changing the active snapshot or any pin
