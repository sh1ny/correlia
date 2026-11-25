# Spec Delta

## ADDED Requirements

### Requirement: Simulator command line

A command-line tool SHALL call the rule simulator for a pasted event file or a stored event key (ID, `observed_at`, optional disposition), optionally with a draft matcher file, and print the trace in a readable form or as JSON.

#### Scenario: Trace a stored event
- **WHEN** the owner runs the tool with the ID and `observed_at` of a stored alert
- **THEN** it prints each rule, each condition leaf with its reason, each action's effect and the final labels

#### Scenario: Malformed timestamp
- **WHEN** the owner passes an `observed_at` with no offset or an invalid calendar date
- **THEN** the tool prints the simulator's `invalid_input` error for `observedAt` and exits non-zero

#### Scenario: Simulator error
- **WHEN** the tool gets an `event_not_found`, `raw_unavailable`, `ambiguous_member`, `invalid_input` or validation error from the simulator
- **THEN** it prints the error code and field and exits with a non-zero status
