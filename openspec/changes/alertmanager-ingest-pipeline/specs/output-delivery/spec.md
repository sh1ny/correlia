# Spec Delta

## Purpose

Deliver committed canonical events independently to configured outputs with immutable identity, bounded retries and visible durable outcomes despite crashes or ambiguous network results.

## ADDED Requirements

### Requirement: Immutable routed delivery intent

Each newly accepted eligible observation SHALL create one delivery intent per distinct routed output, in its processing transaction. An intent SHALL retain immutable structured-CloudEvents bytes, event id and the pinned output definition/secret reference. Later configuration changes SHALL not redirect or re-encode pending work. Explicitly empty routes SHALL record a completed unrouted event; missing referenced outputs SHALL not be treated as empty routes.

#### Scenario: Fanout with configuration change
- **WHEN** one observation routes to two outputs and their endpoints/configuration change before relay pickup
- **THEN** one intent exists per original output and each delivers its original bytes to its original configured destination

#### Scenario: Explicitly unrouted event
- **WHEN** a source's valid pinned snapshot explicitly selects no outputs
- **THEN** the canonical event commits with an unrouted outcome and no intent, while a missing output reference cannot activate as that configuration

### Requirement: Fenced at least once delivery

Relays SHALL acquire eligible work by status, not an id cursor, with expiring ownership fenced against stale completions. External delivery SHALL occur outside database transactions. Success SHALL require a confirmed destination acknowledgement; ambiguous or interrupted delivery SHALL remain retryable with identical event id and payload. No per-alert delivery order or exactly-once remote effect SHALL be promised.

#### Scenario: DUR-2 restart after processing commit
- **WHEN** a worker dies after event/outbox commit but before delivery
- **THEN** a replacement worker finds the pending intent and delivers the original event without requiring a new ingest request

#### Scenario: DUR-3 acknowledgement lost before local commit
- **WHEN** a receiver accepts a payload and the worker dies before persisting delivered
- **THEN** the intent is redelivered with byte-identical payload and the same message id, and the destination may observe a duplicate

#### Scenario: Expired owner completion
- **WHEN** an expired claim has been reacquired and its old owner later reports success or failure
- **THEN** the old completion changes neither the new claim nor its attempt/outcome records

### Requirement: Isolated attempts retry and dead letters

Each output SHALL have independent bounded in-flight work and durable attempt records including start/outcome, attempt number and sanitized error class. Transient errors SHALL retry with capped backoff; permanent errors or retry exhaustion SHALL durably dead-letter the intent with its reason. A failing output SHALL not hold a database transaction across network I/O or prevent another output's eligible work from progressing.

#### Scenario: One output fails while another succeeds
- **WHEN** two outputs receive routed work and one repeatedly fails while the other acknowledges
- **THEN** the healthy output reaches delivered, failed attempts/backoff are visible and the failing output eventually reaches dead with a reason and its original payload retained

#### Scenario: Interrupted attempt exhausts budget
- **WHEN** workers repeatedly die after recording a started attempt without recording a network result
- **THEN** recovery marks those attempts interrupted, counts them toward the retry budget and eventually dead-letters rather than retrying forever

### Requirement: Signed structured webhook output

Webhook-out SHALL POST exact stored structured-CloudEvents bytes with `Content-Type: application/cloudevents+json`, `Idempotency-Key` equal to event id and `X-Correlia-Signature: sha256=<lowercase hex HMAC-SHA256 of body>`. Only 2xx SHALL acknowledge delivery. Redirects SHALL not be followed. URLs SHALL contain no embedded credentials or query secrets; HMAC keys SHALL never appear in payloads, stored config or diagnostics.

#### Scenario: Receiver verifies signed event
- **WHEN** webhook-out delivers an intent to a receiver with the configured signing key
- **THEN** the receiver verifies the signature over the exact received bytes, parses a canonical CloudEvent with the same event id and its 2xx response moves the intent to delivered

#### Scenario: Redirect timeout and rejection
- **WHEN** a destination redirects, times out, returns 429/5xx, or returns a permanent 4xx rejection
- **THEN** no redirect target is called, timeout/429/5xx are retryable, redirects and non-408/non-429 4xx become dead letters, and bounded attempt diagnostics contain neither response-body secrets nor HMAC keys

### Requirement: Signing key availability before acquisition

Relays SHALL acquire only intents whose signing reference is loaded and matches its stored commitment. A newly activated reference missing from a running worker SHALL leave its intents queued without consuming attempts and emit a fixed sanitized availability diagnostic. Dead intents SHALL retain their key commitment but SHALL not require signing material until an explicit future replay operation.

#### Scenario: Loaded historical signing reference
- **WHEN** an intent retains an older output definition whose committed signing key is still loaded
- **THEN** it is delivered under that original key even though the active configuration uses a newer reference

#### Scenario: Unloaded live signing reference
- **WHEN** another process activates an output reference absent from a running relay's loaded secret set
- **THEN** its intents remain queued, no attempt is started, the missing-reference diagnostic appears and unrelated loaded-key outputs continue delivering
