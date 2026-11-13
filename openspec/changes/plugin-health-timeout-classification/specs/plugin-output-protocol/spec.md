# Spec Delta

## MODIFIED Requirements

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
