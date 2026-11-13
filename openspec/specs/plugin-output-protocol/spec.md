# plugin-output-protocol Specification

## Purpose

Defines the `correlia.plugin.v1` contract an external output plugin implements: identification,
configuration with secrets, health, and credit-controlled batched delivery with a per-event outcome.

## Requirements

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
The host SHALL send config and secrets separately before delivery. Configure SHALL accept or reject the whole config with value-free field errors. Accepted answers SHALL have no error class or field errors; rejected answers SHALL have no configuration information. Bounded information and plugin classes SHALL be validated before rejection is classified as `plugin_config_rejected`, with a sanitized plugin class exposed separately. Invalid diagnostics SHALL fail as `plugin_protocol_error`.

#### Scenario: Accepted configuration
- **WHEN** a plugin receives a valid config and the secrets it requires
- **THEN** it reports acceptance with its delivery limits and immutable non-secret configuration information and the host may open a stream; a response or frame over 64 KiB first fails with `plugin_metadata_invalid`, otherwise information beyond its entry/key/value bounds, an invalid diagnostic class or accepted-response error fields fail with `plugin_protocol_error`

#### Scenario: Rejected configuration
- **WHEN** a plugin receives a config with an unknown field or a missing required secret
- **THEN** it returns field errors naming keys without secret values and the host records `plugin_config_rejected` with the validated plugin class separately; within the response/frame bounds, rejected answers with configuration information or an invalid class instead fail with `plugin_protocol_error`; any class containing non-empty resolved secret bytes is silently dropped, and no delivery stream opens

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
The plugin SHALL answer health checks with serving or not serving and a bounded reason. A plugin that is not serving SHALL still answer delivery batches with outcomes rather than hang. The host SHALL bound each health call with a deadline. A health call that ends at or after its deadline while the plugin connection is still up SHALL fail as `plugin_health_timeout`, whatever status ends it, and SHALL NOT be reported as `plugin_connection_lost`.

#### Scenario: Plugin reports serving
- **WHEN** the host checks the health of a configured plugin whose dependencies are reachable
- **THEN** the plugin answers serving within the deadline

#### Scenario: Health call stalls
- **WHEN** a plugin does not answer a health call before its deadline
- **THEN** the host counts a failed health check with error class `plugin_health_timeout` rather than waiting indefinitely

#### Scenario: Stalled plugin ends the call itself
- **WHEN** a plugin that received the host's deadline ends a stalled health call with its own non-success status at or after that deadline, while its connection stays up
- **THEN** the host counts a failed health check with error class `plugin_health_timeout`, not `plugin_connection_lost`

#### Scenario: Stall classification under load
- **WHEN** health calls to a stalled plugin run while the host is under heavy concurrent load
- **THEN** every such call fails with error class `plugin_health_timeout`, whichever deadline is observed first

#### Scenario: Connection lost during a health call
- **WHEN** the host has observed the plugin process exit or its connection break by the time a health call fails, whether the call fails before or after its deadline
- **THEN** the call fails with error class `plugin_connection_lost`, not `plugin_health_timeout`

#### Scenario: Request write races transport closure
- **WHEN** the plugin transport closes while a host request is still being written
- **THEN** that call fails as a transport failure through its RPC error path, without raising an uncaught error
