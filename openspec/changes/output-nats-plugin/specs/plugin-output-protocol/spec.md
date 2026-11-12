# Spec Delta

## Purpose

Defines the `correlia.plugin.v1` contract an external output plugin implements: identification,
configuration with secrets, health, and credit-controlled batched delivery with a per-event outcome.

## ADDED Requirements

### Requirement: Versioned plugin identification
A plugin SHALL serve `correlia.plugin.v1` over the go-plugin-compatible handshake with Correlia's production cookie and application protocol version 1. Metadata SHALL report name, version, kinds and a JSON Schema of its config. The host SHALL refuse a plugin whose metadata omits kind `output` or exceeds the metadata size bound.

#### Scenario: Output plugin identifies itself
- **WHEN** the host starts a plugin that negotiates protocol version 1 and returns metadata with kind `output`
- **THEN** the host records the plugin's reported name and version and proceeds to configuration

#### Scenario: Plugin without the output kind
- **WHEN** a plugin's metadata lists only kind `source`, or its metadata exceeds the size bound
- **THEN** startup fails with error class `plugin_metadata_invalid`, no configuration or event is sent and the attempt's child is stopped

#### Scenario: Spike probe cookie
- **WHEN** an executable that serves only the experimental `correlia.plugin.spike.v1` probe with the spike cookie is configured as an output plugin
- **THEN** the handshake fails with a cookie or version error and no delivery stream opens

### Requirement: Configuration with separated secrets
The host SHALL send each plugin its non-secret config and its resolved secrets as separate fields before any delivery. The plugin SHALL accept or reject the whole configuration. A rejection SHALL return field errors that name config or secret keys, never secret values, and SHALL leave the plugin unable to deliver.

#### Scenario: Accepted configuration
- **WHEN** a plugin receives a valid config and the secrets it requires
- **THEN** it reports acceptance with its delivery limits and the host may open a delivery stream

#### Scenario: Rejected configuration
- **WHEN** a plugin receives a config with an unknown field or a missing required secret
- **THEN** it returns field errors naming those keys without any secret value, the host records error class `plugin_config_rejected`, and no delivery stream opens

### Requirement: Credit-controlled batched delivery
Delivery SHALL use one bidirectional stream per plugin connection. The host SHALL send batches with increasing sequence numbers. Each event SHALL carry its event id and its exact stored bytes. The host SHALL keep the outstanding batches and their events and bytes within the smaller of its own bounds and the limits the plugin accepted at configuration.

#### Scenario: Batches within limits
- **WHEN** the host delivers queued events to a plugin that accepted at most 2 outstanding batches of 64 events
- **THEN** no batch exceeds 64 events or the byte bound, and at most 2 batches are unanswered at any time

#### Scenario: Plugin advertises limits above the host bounds
- **WHEN** a plugin accepts configuration advertising a 10,000-event batch limit
- **THEN** the host uses its own lower batch bound and never sends a batch larger than that bound

### Requirement: Per-event delivery outcome
The plugin SHALL answer every batch with exactly one outcome per event: acknowledged, retryable or rejected. Each non-acknowledged outcome SHALL carry a bounded error class. The host SHALL treat an answer with a missing, unknown, duplicated or extra event, or an unknown or repeated sequence, as a protocol error: it fails the connection and completes no event of that batch.

#### Scenario: Mixed outcomes in one batch
- **WHEN** a plugin answers a 3-event batch with acknowledged, retryable `publish_timeout` and rejected `payload_too_large`
- **THEN** the host reports each event's own outcome and error class to its caller

#### Scenario: Malformed batch answer
- **WHEN** a plugin answers a batch omitting one event id, naming an id not in the batch, or repeating a sequence already answered
- **THEN** the host fails the connection with error class `plugin_protocol_error` and reports none of that batch's events as acknowledged

### Requirement: Plugin health reporting
The plugin SHALL answer health checks with serving or not serving and a bounded reason. A plugin that is not serving SHALL still answer delivery batches with outcomes rather than hang. The host SHALL bound each health call with a deadline.

#### Scenario: Plugin reports serving
- **WHEN** the host checks the health of a configured plugin whose dependencies are reachable
- **THEN** the plugin answers serving within the deadline

#### Scenario: Health call stalls
- **WHEN** a plugin does not answer a health call before its deadline
- **THEN** the host counts a failed health check with error class `plugin_health_timeout` rather than waiting indefinitely
