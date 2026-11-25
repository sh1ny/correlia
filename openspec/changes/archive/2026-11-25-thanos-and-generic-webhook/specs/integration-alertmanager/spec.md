# Spec Delta

## ADDED Requirements

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
