# Spec Delta

## MODIFIED Requirements

### Requirement: Icinga2 webhook document

`/hooks/icinga2/<source>` of a source in mode `webhook` SHALL accept one JSON object per delivery in Correlia's Icinga2 webhook format,
`format: "correlia.icinga2.v1"`: required object type, host, state, state type, notification type and
time, `service` for a service object; optional `output`, author and comment. A missing required field (`missing_field`), a wrong type (`invalid_type`) or an unknown
field (`unknown_field`) SHALL fail decoding with a bounded field path.

#### Scenario: Service problem notification
- **WHEN** an `icinga2` source receives a delivery for service `disk` on host `db1` with state `CRITICAL`, state type `HARD` and notification type `PROBLEM`
- **THEN** one canonical event of kind `alert`, status `firing` and severity `critical` is produced, with `observer.source_kind` `icinga2`

#### Scenario: Wrong type on a known field
- **WHEN** a delivery's `state` is the number 2 instead of a state name
- **THEN** the raw row fails with error code `invalid_type`, its stored failure path is `state`, and no event, observation key or alert change commits

#### Scenario: Unknown field name is not reflected
- **WHEN** a delivery carries an unknown field named `secret_token_abc`
- **THEN** the raw row fails with error code `unknown_field`, its stored failure path is `*`, and neither the stored failure nor the log contains `secret_token_abc`

#### Scenario: Dotted unknown field name
- **WHEN** a delivery carries an unknown field named `state.state_type`, both of whose segments are documented field names
- **THEN** the persisted failure path is a single `*` and contains neither `state` nor `state_type` from that name

#### Scenario: Unsupported format version
- **WHEN** a delivery declares `format: "correlia.icinga2.v2"`
- **THEN** the raw row fails with error code `unsupported_version` and stored failure path `format`

#### Scenario: Delivery to a stream source
- **WHEN** a delivery reaches `/hooks/icinga2/<source>` for a source in mode `event_streams`
- **THEN** it is refused as for an unknown source, and no raw row is written
