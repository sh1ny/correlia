# output-delivery Specification

## Purpose

Deliver committed canonical events independently to configured outputs with immutable identity, bounded retries and visible durable outcomes despite crashes or ambiguous network results.

## Requirements

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

Relays SHALL acquire only webhook intents whose signing reference is loaded and matches its commitment. A newly activated reference missing from a running worker SHALL leave its webhook intents queued without consuming attempts and emit a fixed sanitized availability diagnostic. Dead intents SHALL retain their key commitment but SHALL not require signing material until explicit future replay. Plugin intents carry no signing reference; their secret availability is governed by plugin supervision.

#### Scenario: Loaded historical signing reference
- **WHEN** an intent retains an older output definition whose committed signing key is still loaded
- **THEN** it is delivered under that original key even though the active configuration uses a newer reference

#### Scenario: Unloaded live signing reference
- **WHEN** another process activates an output reference absent from a running relay's loaded secret set
- **THEN** its intents remain queued, no attempt is started, the missing-reference diagnostic appears and unrelated loaded-key outputs continue delivering

#### Scenario: Plugin intents need no signing reference
- **WHEN** a relay discovers queued plugin intents, which have no signing reference
- **THEN** signing-key availability neither blocks nor admits them, and their acquisition follows plugin readiness

### Requirement: Kind-aware startup validation
Startup SHALL require loaded matching signing material only for live webhook intents. Live plugin intents SHALL NOT block startup: their secrets are checked when their plugin is launched. Publication SHALL record commitments for webhook signing references and plugin secret references alike, and SHALL reject a reference rebound to different material.

#### Scenario: Restart with pending unauthenticated plugin work
- **WHEN** a worker restarts while queued and delivering intents exist for a NATS output that uses no secrets
- **THEN** startup succeeds, expired claims are recovered and the intents are delivered

#### Scenario: Mixed live work with a missing plugin secret
- **WHEN** live webhook intents have their signing keys loaded, and live intents of an older plugin definition reference a secret that is no longer in the secret file
- **THEN** the worker starts, the webhook intents are delivered, and the plugin intents stay queued with zero new attempts and status `plugin_secret_unavailable`

#### Scenario: Missing webhook key still fails startup
- **WHEN** a live webhook intent's signing reference is not loaded
- **THEN** startup fails with `historical_key_unavailable`, as before

#### Scenario: Plugin secret reference rebound
- **WHEN** a new snapshot binds an existing plugin secret reference to different bytes
- **THEN** activation fails with `reference_rebound` and the active snapshot stays unchanged

### Requirement: Validated plugin output definitions
Bootstrap SHALL accept outputs of kind `webhook` or `plugin`. A plugin output SHALL name:
- an executable in the plugin directory and its SHA-256;
- a bounded JSON config object;
- secret references that resolve in the secret file, stored only as commitments.

An invalid definition SHALL fail activation with a field error and leave the active snapshot unchanged.

#### Scenario: Plugin output activates
- **WHEN** bootstrap defines a plugin output with a valid name, digest, config and resolvable secret reference, and a source routes to it
- **THEN** the snapshot activates, its stored definition holds the secret commitment but no secret value, and new intents for that output pin the definition

#### Scenario: Invalid plugin output
- **WHEN** a plugin output has an unknown kind, a path outside the plugin directory, a malformed digest, a config above its size bound or an unresolvable secret reference
- **THEN** activation fails with a field error naming that output field, and the previously active snapshot and routes stay unchanged

### Requirement: Plugin secret values
The secret file SHALL hold plugin secrets of 1 byte to 16 KiB within a bounded total, while source credentials and webhook signing keys stay exactly 32 bytes.

#### Scenario: Secret file sizes
- **WHEN** the secret file is loaded from disk holding valid plugin secrets of 300 KiB encoded, or one over the decoded total, or one over the encoded file limit
- **THEN** the first loads, and the other two fail with the sanitized `bound` error, while the config file limit stays unchanged

#### Scenario: Long plugin secret
- **WHEN** a plugin output's secret reference resolves to a 3 KiB NATS credentials document stored in the byte form of the secret file
- **THEN** the snapshot activates and the plugin receives exactly those bytes at configuration, while a source credential or webhook signing reference given in that form but not exactly 32 bytes long fails with its existing field error

### Requirement: Readiness-gated plugin acquisition
A relay SHALL claim a plugin output's intents only from definitions that have a ready plugin instance, oldest due intent first, and SHALL recheck that instance before starting attempts. Intents of other definitions SHALL stay queued, consume no attempt and show a sanitized availability state. Other outputs SHALL keep progressing.

#### Scenario: Plugin degraded while work is queued
- **WHEN** a plugin output's instance is `degraded` while 50 intents are queued and a webhook output also has queued work
- **THEN** no attempt is started for the 50 intents, their attempt counts stay unchanged, and the webhook intents are delivered

#### Scenario: Plugin becomes ready again
- **WHEN** the instance returns to `ready`
- **THEN** the queued intents are acquired and delivered without an operator action

#### Scenario: Older unavailable definition beside a ready one
- **WHEN** one output has older due intents pinned to definition A, whose plugin cannot launch, and newer due intents pinned to definition B, whose instance is ready
- **THEN** B's intents are claimed and delivered, and A's intents keep zero new attempts

#### Scenario: Instance leaves ready between selection and claim
- **WHEN** the selected instance stops being ready after the relay selected its definition and before it takes a delivery permit
- **THEN** no attempt is started and the intents stay queued

#### Scenario: Plugin exit observed while the claim is still open
- **WHEN** the relay holds a delivery permit, its claim transaction is held by a barrier before commit, and the supervisor observes the plugin's exit before the barrier is released
- **THEN** the claim rolls back, the intents stay queued with unchanged attempt counts, and a plugin exit observed after the claim committed yields one `plugin_connection_lost` attempt per intent instead

### Requirement: Pinned plugin definition delivery
An intent SHALL be delivered only by a plugin instance configured with its own pinned output definition. After a configuration change, older pending intents SHALL drain through an instance of their pinned definition, while new intents use the new one.

#### Scenario: NATS stream changed with work pending
- **WHEN** intents are pinned to a definition publishing through server A and a new snapshot points the output at server B before they are delivered
- **THEN** the old intents are published through A and new intents through B, and the instance for the old definition stops once its intents are terminal

#### Scenario: Pinned definition cannot run
- **WHEN** an old definition's plugin executable no longer matches its pinned digest
- **THEN** its intents stay queued with the `plugin_executable_rejected` state visible, and intents of the active definition keep delivering

### Requirement: Plugin intent byte-limit admission
The relay SHALL retain an individually oversized plugin intent as `dead` with `payload_too_large`, unchanged bytes and attempt count, and no transport attempt or attempt record. Rejections SHALL commit under the claim transaction's readiness and deadline fence, even without a remaining batch, and SHALL NOT block fitting work. Aggregate-only overflow SHALL defer fitting intents.

#### Scenario: Intent larger than the negotiated batch limit
- **WHEN** the oldest due intent of a selected ready definition alone exceeds its negotiated batch byte limit and a later intent fits
- **THEN** the oversized intent is retained dead with `payload_too_large`, unchanged bytes and attempt count, and no attempt record, while the fitting intent can be claimed within the limit

#### Scenario: Only oversized intents are eligible
- **WHEN** every selected due intent exceeds the negotiated batch byte limit
- **THEN** their terminal rejections commit even though no transport batch is returned, without starting attempts

#### Scenario: Readiness loss before oversized rejection commits
- **WHEN** the host has marked oversized intents dead in the open claim transaction and its delivery permit becomes invalid before commit
- **THEN** those rejections roll back and the intents remain queued with unchanged payloads and attempt counts and no attempt records

#### Scenario: Aggregate budget full for a fitting event
- **WHEN** an intent fits the negotiated limit individually but would exceed the current batch's remaining aggregate byte budget
- **THEN** it stays queued for a later batch without an attempt or a dead-letter classification

### Requirement: Batched plugin delivery with per-event completion
A relay SHALL claim a bounded batch of one ready definition's due intents and finish claiming, delivering and completing it within one deadline that ends before the lease. It SHALL persist all outcomes of the batch in one transaction fenced against the current time, or none. Each event's own outcome decides its state, and a lost plugin connection makes unanswered intents retryable with `plugin_connection_lost`.

#### Scenario: Batch with one bad event
- **WHEN** a batch of 10 intents is answered with 9 acknowledged and 1 rejected `payload_too_large`
- **THEN** 9 intents are delivered, 1 is dead with reason `payload_too_large` and its payload retained, and each has its own attempt record

#### Scenario: Plugin dies with the batch unanswered
- **WHEN** the plugin process dies after receiving a batch and before answering it
- **THEN** each intent of the batch gets a finished attempt with error class `plugin_connection_lost`, is queued for retry with unchanged payload, and is delivered once the plugin is ready again

#### Scenario: Full batch completed within its budget
- **WHEN** a 64-intent batch is answered near the delivery deadline and the completion is slow but finishes within the batch deadline
- **THEN** all 64 outcomes commit together before the lease ends, and no acknowledged intent is later recovered as interrupted

#### Scenario: Batch over its deadline
- **WHEN** the claim persistence and both completion updates are each delayed below their own timeouts, so that together they pass the batch deadline
- **THEN** the completion rolls back before the lease ends and writes no outcome, lease recovery marks every intent of the batch interrupted, the redelivery is acknowledged as a JetStream duplicate, and the stream holds exactly one message per event

#### Scenario: Stale batch completion
- **WHEN** a batch's lease expires, another worker reclaims its intents, and the first worker's plugin answers late
- **THEN** the late answer changes neither the new claim nor its attempt records

### Requirement: No loss across worker death
After a worker is killed and replaced, every accepted routed event for a plugin output SHALL end up either delivered or dead with a reason. Delivered means confirmed by the destination. No intent SHALL remain delivering beyond its lease, and none SHALL be lost or delivered with changed bytes.

#### Scenario: Kill -9 during a 1,000-alert burst
- **WHEN** 1,000 alerts are accepted, the worker is killed with SIGKILL while NATS deliveries are in flight, and a replacement worker starts
- **THEN** the set of accepted alert event ids equals the event ids in the JetStream stream plus the dead intents with reasons, the stream has no two messages with one `Nats-Msg-Id`, and no intent is still queued or delivering

#### Scenario: Worker killed before any delivery
- **WHEN** the worker is killed after the events committed and before its plugin became ready
- **THEN** the replacement worker's plugin delivers every pending intent, without a new ingest request
