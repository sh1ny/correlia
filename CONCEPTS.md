# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Incident Notification

### Incident
The canonical correlated record of a problem state, its decision context, and its lifecycle information.

### Output Plugin
An allowlisted application-owned delivery implementation that receives a notification envelope and either completes or raises.

### Notification Envelope
The bounded immutable value passed from Correlia to an Output Plugin; it contains notification-relevant incident data but excludes persistence objects, raw input, and plugin configuration.

### Notification Delivery Record
The current terminal delivery state for one Output Plugin on an Incident, replacing that plugin's prior terminal state rather than forming an attempt history.

### Notification Result
The safe bounded outcome of an attempted notification action, classified by a closed delivery category and success state.

### Task Acceptance
The immediate confirmation that notification work was submitted to the in-process runner; it is distinct from completed delivery and is not itself a delivery record.

## Relationships

An Incident owns its Notification Delivery Records. An Output Plugin receives a Notification Envelope; the dispatcher converts its completion or exception into the terminal Notification Result and current Notification Delivery Record. Task Acceptance precedes, but does not guarantee, that terminal result.

## Operational Visibility

### Operational Projection
A bounded serving-time representation of an outcome produced outside the long-lived service, published only after the source summary passes schema and safety validation.
