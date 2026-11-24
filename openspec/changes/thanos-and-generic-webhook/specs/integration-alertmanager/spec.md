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

Each Thanos fixture SHALL be recorded by the capture tool from real Ruler and Alertmanager containers, and SHALL
be listed in a manifest naming the Thanos and Alertmanager images and digests that produced it. A fixture file
the manifest does not list, or a manifest entry without its file, SHALL fail the fixture test.

#### Scenario: Manifest matches the fixtures
- **WHEN** the fixture test runs over the Thanos fixture directory
- **THEN** every fixture has a manifest entry with image names and digests, and every entry has its fixture

#### Scenario: Fixture added by hand
- **WHEN** a Thanos fixture file is present that the manifest does not list
- **THEN** the fixture test fails naming that file

### Requirement: Ruler HA replicas share one identity

The documented Thanos setup SHALL keep Ruler's HA replica label out of identity, by dropping it in Ruler or by
listing it in the source's `excluded_identity_labels`. With either, the same rule fired by two Ruler replicas
SHALL yield one fingerprint; with neither, the documentation SHALL state that the replicas yield two.

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
