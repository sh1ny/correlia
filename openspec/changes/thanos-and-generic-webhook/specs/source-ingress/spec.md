# Spec Delta

## MODIFIED Requirements

### Requirement: Source configuration format

The bootstrap configuration SHALL accept format version 2, where each source declares `kind`, `credentials`, an optional `namespace`, `body_limit_bytes` and `rate_limit`, and the root may declare `namespaces` and `mappings`. Format version 1 SHALL still be accepted and read as one bearer credential from `token_ref`, kind `alertmanager` and the default rate limit. Unknown fields, kinds and modes SHALL fail with a bounded field error.

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
- **WHEN** a version 2 file declares one source each of kind `alertmanager`, `icinga2` and `generic`
- **THEN** activation succeeds and each source accepts deliveries only under its own kind's route

#### Scenario: Mappings in a version 1 file
- **WHEN** a format version 1 file declares a root `mappings` list
- **THEN** activation fails with a field error naming `mappings`, and the prior snapshot stays active

### Requirement: Path tokens stay Alertmanager-only

`path_token_enabled` SHALL be accepted only on `alertmanager` sources. A credential in the URL path of any other
kind's route SHALL be refused.

#### Scenario: Icinga2 source declares a path token
- **WHEN** an `icinga2` source declares `path_token_enabled: true`
- **THEN** activation fails with a field error naming `sources[i].path_token_enabled`

#### Scenario: Path-token request on the Icinga2 route
- **WHEN** a request is sent to `/hooks/icinga2/<id>/<credential>`
- **THEN** Correlia answers 401 and no raw row is inserted

#### Scenario: Generic source declares a path token
- **WHEN** a `generic` source declares `path_token_enabled: true`
- **THEN** activation fails with a field error naming `sources[i].path_token_enabled`

#### Scenario: Path-token request on the generic route
- **WHEN** a request is sent to `/hooks/generic/<id>/<credential>`
- **THEN** Correlia answers 401 and no raw row is inserted

### Requirement: Identity label exclusion stays Alertmanager-only

`excluded_identity_labels` SHALL be accepted only on `alertmanager` sources, because an Icinga2 fingerprint is
built from host and service, and a generic fingerprint from its mapping's identity fields, not labels.

#### Scenario: Icinga2 source declares excluded identity labels
- **WHEN** an `icinga2` source declares `excluded_identity_labels: ["service"]`
- **THEN** activation fails with a field error naming `sources[i].excluded_identity_labels`, and the prior snapshot stays active

#### Scenario: Generic source declares excluded identity labels
- **WHEN** a `generic` source declares `excluded_identity_labels: ["host"]`
- **THEN** activation fails with a field error naming `sources[i].excluded_identity_labels`, and the prior snapshot stays active

## ADDED Requirements

### Requirement: Generic sources name one mapping

A `generic` source SHALL declare `mapping`, naming a mapping in the same configuration file. A missing or unknown
name SHALL fail activation. `mapping` SHALL be refused on every other kind. A generic source SHALL authenticate
with its bearer or HMAC credentials, with the same rotation overlap as other kinds.

#### Scenario: Generic source with a known mapping
- **WHEN** a `generic` source declares `mapping: checks`, mapping `checks` exists, and a delivery carries a valid HMAC signature
- **THEN** activation succeeds and the delivery is admitted as a raw row pinned to the new snapshot

#### Scenario: Unknown mapping name
- **WHEN** a `generic` source declares `mapping: missing` and no mapping has that name
- **THEN** activation fails with a field error naming `sources[i].mapping`, and the prior snapshot stays active

#### Scenario: Mapping on an Alertmanager source
- **WHEN** an `alertmanager` source declares `mapping: checks`
- **THEN** activation fails with a field error naming `sources[i].mapping`

#### Scenario: Wrong credential on the generic route
- **WHEN** a request to `/hooks/generic/<id>` carries a bearer token that is not one of the source's credentials
- **THEN** Correlia answers 401 and no raw row is inserted

### Requirement: Generic deliveries are admitted before mapping

The generic route SHALL admit a delivery exactly as other webhook kinds do: content type, body limit, rate limit,
transport deduplication and durable commit before 202. Ingress SHALL NOT parse or map the body; a body that is
not valid JSON, or that its mapping rejects, SHALL fail its raw row in the pipeline.

#### Scenario: Body the mapping rejects
- **WHEN** a JSON object that its mapping will reject is posted with a valid credential and content type `application/json`
- **THEN** Correlia answers 202, the raw row is admitted, and the mapping failure is recorded on that row

#### Scenario: Wrong content type on the generic route
- **WHEN** a body is posted to the generic route with content type `application/x-www-form-urlencoded`
- **THEN** Correlia answers 415 and no raw row is inserted
