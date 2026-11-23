# Spec Delta

## MODIFIED Requirements

### Requirement: Source configuration format

The bootstrap configuration SHALL accept format version 2, where each source declares `kind`, `credentials`, an optional `namespace`, `body_limit_bytes` and `rate_limit`, and the root may declare `namespaces`. Format version 1 SHALL still be accepted and read as one bearer credential from `token_ref`, kind `alertmanager` and the default rate limit. Unknown fields and kinds SHALL fail with a bounded field error.

#### Scenario: Version 1 file still starts
- **GIVEN** an M1 database with a format version 1 configuration active at revision N
- **WHEN** the same file is published at revision N with a key file
- **THEN** activation fails with `activation_conflict` and the prior snapshot stays active
- **WHEN** it is published at revision N+1 with its existing secret file and the key file
- **THEN** activation succeeds, the source keeps its UUID and namespace, and its existing token is accepted

#### Scenario: Unsupported kind or field
- **WHEN** a version 2 source declares kind `zabbix`, which is not supported, or carries an undeclared field
- **THEN** activation fails with a field error naming `sources[i].kind` or the field path, and the prior snapshot stays active

#### Scenario: Supported kinds
- **WHEN** a version 2 file declares one source of kind `alertmanager` and one of kind `icinga2`
- **THEN** activation succeeds and each source accepts deliveries only under its own kind's route

### Requirement: Credential rotation with overlap

A source SHALL hold 1 to 4 credentials, each with a distinct secret reference and an optional `not_before` and `not_after` instant (`not_before` < `not_after`). A credential SHALL authenticate only within its window, evaluated at receipt time. At least one credential SHALL have no `not_after` or a `not_after` in the future at activation.

#### Scenario: Overlapping rotation
- **WHEN** revision B adds a new bearer credential beside the current one, then revision C removes the old one
- **THEN** under B both tokens are accepted, under C only the new token is accepted and the old one returns 401

#### Scenario: Expired and not yet valid credentials
- **WHEN** a request presents a credential whose `not_after` has passed or whose `not_before` is in the future
- **THEN** the response is 401 with no raw row, and the source's rejection count increases

#### Scenario: Rotation during a body read
- **WHEN** a request authenticates with a credential under revision B, and revision C removing that credential (or disabling the source or disabling path tokens) commits while the request body is still being read
- **THEN** the request receives 401 and no raw row or transport key is committed; a request whose credential is still valid at its receipt instant and still present at commit is admitted

#### Scenario: Activation without a usable credential
- **WHEN** a publication gives a source five credentials, two credentials with the same reference, or only credentials already expired
- **THEN** activation fails with a bounded field error and the prior snapshot stays active

## ADDED Requirements

### Requirement: A source's kind never changes

A source UUID SHALL keep the kind it was first published with. A configuration that gives an existing source
UUID another kind SHALL fail activation with `kind_changed`, so a raw row whose pinned snapshot configures its
source decodes with the kind it was admitted under, also on replay.

#### Scenario: Kind change refused
- **WHEN** a source published as `alertmanager` is republished with the same UUID and kind `icinga2`
- **THEN** activation fails with a field error naming `sources[i].kind` and code `kind_changed`, and the prior snapshot stays active

#### Scenario: Disabled source keeps its kind
- **WHEN** a source is removed from the configuration and later published again with the same UUID and another kind
- **THEN** activation fails with `kind_changed`

#### Scenario: Admitted row decodes with its kind
- **WHEN** an Alertmanager delivery is accepted with 202, then a configuration revision that keeps the source is published, and then the pipeline claims the row
- **THEN** the row decodes as Alertmanager

#### Scenario: Source disabled before the first claim
- **WHEN** a delivery is accepted with 202, then a revision that disables its source is published, and then the pipeline claims the row
- **THEN** the row fails with `source_not_configured`, as for every kind, and no decoder runs

### Requirement: Path tokens stay Alertmanager-only

`path_token_enabled` SHALL be accepted only on `alertmanager` sources. A credential in the URL path of any other
kind's route SHALL be refused.

#### Scenario: Icinga2 source declares a path token
- **WHEN** an `icinga2` source declares `path_token_enabled: true`
- **THEN** activation fails with a field error naming `sources[i].path_token_enabled`

#### Scenario: Path-token request on the Icinga2 route
- **WHEN** a request is sent to `/hooks/icinga2/<id>/<credential>`
- **THEN** Correlia answers 401 and no raw row is inserted

### Requirement: Identity label exclusion stays Alertmanager-only

`excluded_identity_labels` SHALL be accepted only on `alertmanager` sources, because an Icinga2 fingerprint is
built from host and service, not labels.

#### Scenario: Icinga2 source declares excluded identity labels
- **WHEN** an `icinga2` source declares `excluded_identity_labels: ["service"]`
- **THEN** activation fails with a field error naming `sources[i].excluded_identity_labels`, and the prior snapshot stays active
