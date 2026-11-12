# Spec Delta

## Purpose

Specifies the first-party NATS JetStream output plugin: how canonical events map to subjects, bodies and
headers, when a publish counts as delivered, and how it fails and exits.

## ADDED Requirements

### Requirement: Event subject scheme
The plugin SHALL publish each event on `correlia.v1.ev.<tenant>.<kind>.<source_kind>.<severity>`. Kind and severity SHALL be the canonical lowercase names, and tenant and source kind the event's own values. A token that is empty or contains anything other than ASCII letters, digits, `_` or `-` SHALL reject the event and leave the other events of the batch unaffected.

#### Scenario: Alert event subject
- **WHEN** an alert event for tenant `default`, source kind `alertmanager` and severity critical is delivered
- **THEN** it is published on `correlia.v1.ev.default.alert.alertmanager.critical`

#### Scenario: Unsafe subject token
- **WHEN** an event's tenant contains `.` or `*`
- **THEN** that event is rejected with error class `invalid_subject_token`, nothing is published for it, and the other events of the batch are published normally

### Requirement: Exact body and identifying headers
The message body SHALL be the exact stored structured CloudEvents JSON bytes. Headers SHALL include:
- `Nats-Msg-Id` equal to the event id;
- `Content-Type: application/cloudevents+json`;
- `ce-specversion`, `ce-id`, `ce-type`, `ce-source`, `ce-subject` and `ce-time` from the envelope;
- `traceparent` when the envelope has one.

#### Scenario: Subscriber parses the event
- **WHEN** a subscriber receives a published message
- **THEN** its body is byte-identical to the outbox payload, it parses as a canonical CloudEvent whose id equals `Nats-Msg-Id`, and the `ce-*` headers equal the envelope attributes

#### Scenario: Envelope without traceparent
- **WHEN** the stored envelope has no `traceparent`
- **THEN** the message carries no `traceparent` header and every other required header is present

### Requirement: Acknowledged and deduplicated publish
An event SHALL be acknowledged only after JetStream confirms storage, including a duplicate confirmation. The plugin SHALL bound each publish with a timeout. Timeouts, a lost connection and missing responders SHALL be retryable. A payload above the server limit SHALL be rejected.

#### Scenario: DUR-3 redelivery after the acknowledgement was lost
- **WHEN** an event was stored in JetStream, the worker died before marking it delivered, and the relay delivers it again within the stream's duplicate window
- **THEN** the plugin acknowledges it, the stream holds exactly one message with that `Nats-Msg-Id`, and the outbox row becomes delivered

#### Scenario: NATS unavailable
- **WHEN** the NATS server is unreachable or does not answer within the publish timeout
- **THEN** the event's outcome is retryable with error class `nats_unavailable` or `publish_timeout`, and it is not acknowledged

#### Scenario: Payload too large
- **WHEN** an event's bytes exceed the server's maximum payload
- **THEN** the event is rejected with error class `payload_too_large` and nothing is published for it

### Requirement: Operator-owned stream
The plugin SHALL never create, update or delete a stream. Configuration SHALL fail when no stream captures the configured subject prefix. The plugin SHALL report the capturing stream's duplicate window.

#### Scenario: Stream captures the subjects
- **WHEN** a stream capturing `correlia.v1.ev.>` exists at configuration
- **THEN** configuration succeeds and the plugin reports that stream's name and duplicate window

#### Scenario: No stream for the subjects
- **WHEN** no stream captures the configured subject prefix
- **THEN** configuration is rejected with field error `stream` and error class `stream_missing`, and no stream is created

### Requirement: Credentials only from secrets
NATS credentials SHALL come only from the configured secret references, supporting no auth, a token or a credentials file's contents. Credentials SHALL never appear in config, logs, status rows, error classes or published messages.

#### Scenario: Token authentication
- **WHEN** the NATS server requires a token and the output's secret reference resolves to that token
- **THEN** the plugin connects and publishes, and the token appears in no log line or status row

#### Scenario: Wrong credentials
- **WHEN** the resolved token is rejected by the server
- **THEN** configuration fails with error class `nats_auth_failed` and the diagnostic contains no part of the token

### Requirement: Exit when the host is gone
The plugin SHALL exit when its stdin reaches end of file, and SHALL write nothing to stdin's peer. A host killed with SIGKILL SHALL leave no NATS plugin process behind.

#### Scenario: Worker killed with SIGKILL
- **WHEN** a worker running a ready NATS plugin is killed with SIGKILL
- **THEN** an independent observer sees that exact plugin process exit by the deadline, with its stdin-close exit marker

#### Scenario: Stdin stays open
- **WHEN** the host stays alive and keeps stdin open without writing
- **THEN** the plugin keeps serving and does not exit
