# output-delivery Specification

## Purpose

Deliver committed canonical events independently to configured outputs with immutable identity, bounded retries and visible durable outcomes despite crashes or ambiguous network results.

## Requirements

### Requirement: Immutable routed delivery intent

Each newly accepted eligible observation SHALL create one delivery intent per distinct routed output in its processing transaction, subject to the output storage policy. An intent SHALL retain immutable structured-CloudEvents bytes, event id and the pinned output definition/secret reference. A configuration change SHALL NOT redirect or re-encode pending work. An explicitly empty route SHALL be unrouted; a missing output or policy discard SHALL NOT be counted as unrouted.

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

A relay SHALL acquire a webhook intent only if its stored signing key matches the pinned commitment. An unavailable key leaves work queued with no attempt and a fixed, sanitized diagnostic. Dead intents retain their commitments and need keys only for future explicit replay. Plugin intents have no signing reference; plugin supervision governs their availability.

#### Scenario: Loaded historical signing reference
- **WHEN** an intent retains an older output definition whose committed signing key is in the store
- **THEN** it is delivered under that original key even though the active configuration uses a newer reference

#### Scenario: Unloaded live signing reference
- **WHEN** a running relay encounters queued work whose pinned signing reference cannot be resolved from the store
- **THEN** its intents remain queued, no attempt is started, the sanitized availability diagnostic appears and unrelated outputs continue delivering

#### Scenario: Plugin intents need no signing reference
- **WHEN** a relay discovers queued plugin intents, which have no signing reference
- **THEN** signing-key availability neither blocks nor admits them, and their acquisition follows plugin readiness

### Requirement: Kind-aware startup validation

Startup SHALL require matching stored signing material only for live webhook intents; publication may import it in the same transaction. Publication SHALL import supplied historical plugin secrets that match live pins without changing those pins. Missing historical plugin secrets SHALL NOT block startup; they are checked at plugin launch. Publication SHALL record webhook and plugin secret commitments and reject reference rebinding.

#### Scenario: Restart with pending unauthenticated plugin work
- **WHEN** a worker restarts while queued and delivering intents exist for a NATS output that uses no secrets
- **THEN** startup succeeds, expired claims are recovered and the intents are delivered

#### Scenario: Mixed live work with a missing plugin secret
- **WHEN** live webhook intents have matching signing keys in the store, and live intents of an older plugin definition reference a secret absent from both the store and the import file
- **THEN** the worker starts, the webhook intents are delivered, and the plugin intents stay queued with zero new attempts and status `plugin_secret_unavailable`

#### Scenario: Missing webhook key still fails startup
- **WHEN** a live webhook intent's signing reference is absent from the store and the import file
- **THEN** startup fails with `historical_key_unavailable`

#### Scenario: Plugin secret reference rebound
- **WHEN** a new snapshot binds an existing plugin secret reference to different bytes
- **THEN** activation fails with `reference_rebound` and the active snapshot stays unchanged

#### Scenario: M1 work with historical secret references drains after upgrade
- **GIVEN** live M1 webhook and plugin intents whose pinned secret references are absent from the upgraded configuration but present in the M1 secret file
- **WHEN** the upgraded process publishes with that file and a valid key, then restarts at a higher revision without the file
- **THEN** the historical references are imported and both intents deliver using the original bytes and unchanged pinned commitments

### Requirement: Validated plugin output definitions

Bootstrap SHALL accept outputs of kind `webhook` or `plugin`. A plugin output SHALL name:
- an executable in the plugin directory and its SHA-256;
- a bounded JSON config object;
- secret references resolvable from the secret store or the import file, stored in the public definition only as commitments.

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

After worker replacement, pending plugin deliveries SHALL remain eligible until delivered or dead with a reason. Delivered means confirmed by the destination. No intent SHALL remain delivering beyond its lease, disappear without a recorded retention outcome, or be delivered with changed bytes. An event already recorded as an overflow discard is not a pending delivery.

#### Scenario: Kill -9 during a 1,000-alert burst
- **WHEN** 1,000 alerts are accepted within budget, the worker is killed with SIGKILL while NATS deliveries are in flight, and a replacement worker starts
- **THEN** the set of accepted alert event ids equals the event ids in the JetStream stream plus the dead intents with reasons, the stream has no two messages with one `Nats-Msg-Id`, and no intent is still queued or delivering

#### Scenario: Worker killed before any delivery
- **WHEN** the worker is killed after the events committed and before its plugin became ready
- **THEN** the replacement worker's plugin delivers every pending intent, without a new ingest request

### Requirement: Historical secret lookup does not scan delivery payloads

Publication and worker startup SHALL check historical delivery commitments through bounded metadata lookups. They SHALL preserve commitment visibility across the raw pin-to-intent transition. Missing live webhook signing material SHALL still block startup; plugin secret availability SHALL remain a per-definition check.

#### Scenario: Historical import and startup ignore backlog size
- **WHEN** many more live intents reuse the same pinned webhook and plugin commitments and the operator supplies historical imports
- **THEN** publication and startup inspect the same distinct commitment metadata, validate the imports without scanning delivery payloads, and leave the original pins intact

#### Scenario: Missing live signing material cannot be hidden
- **WHEN** a formerly pinned route becomes a live webhook intent and its signing material is unavailable at worker startup
- **THEN** the new live reference remains visible, startup fails with `historical_key_unavailable`, and neither configuration nor the intent is changed

### Requirement: Per-output storage budget and default policy

Each output SHALL have one count and payload-byte budget for queued, delivering and dead intents combined, default 500,000 intents and 1 GiB. Workers SHALL enforce the budget across instances. Under the default `discard_new` policy, an intent that does not fit SHALL be counted and ledgered without storing its payload or delaying other outputs. Older retained work SHALL NOT be discarded to fit new work.

#### Scenario: DUR-11 discard policy isolates a failing output
- **WHEN** one output reaches its combined budget while another continues acknowledging deliveries
- **THEN** the failing output's new over-budget intents add to its durable discard count, its existing bytes and intents are unchanged, and the healthy output and ingress continue

#### Scenario: Count or bytes bind across workers
- **WHEN** two workers route work concurrently that would jointly exceed either an output's count or byte cap
- **THEN** committed work stays within both caps and the committed discard count includes only the intent or intents that do not fit

#### Scenario: Completion and expired-lease recovery race
- **WHEN** relay completion and lease recovery contend on an output intent in both lock acquisition orders
- **THEN** only the winning claim changes the attempt and status, a stale completion changes neither, and capacity is released only if the winning transition makes the intent no longer count

#### Scenario: Lower limit does not purge existing work
- **WHEN** an operator activates a lower budget than the current usage of a retained output
- **THEN** the output stores no new over-budget work, existing intents remain recoverable, and the reported usage reflects the real backlog until delivery or expiry frees capacity

### Requirement: Blocking-output policy protects accepted work

`block_ingest` SHALL reject new ingress under output pressure. If already accepted work cannot fit, its raw transaction SHALL defer without consuming its failure budget or committing partial effects. Other eligible work SHALL progress. A blocking budget SHALL fit one maximum valid raw transaction into an otherwise empty output.

#### Scenario: DUR-11 blocking policy preserves backlog
- **WHEN** accepted work reaches a blocking output whose remaining capacity cannot hold that work
- **THEN** new ingress is pushed back, the raw row stays retryable with its original pin and no partial effects, and it completes after capacity is available

#### Scenario: Blocking budget cannot fit a legal raw row
- **WHEN** a publication sets a blocking count or byte cap too low for one maximum legal raw row
- **THEN** publication refuses the setting without changing the active configuration

#### Scenario: Discard-only demand does not block after a policy change
- **WHEN** an output has free capacity, has discarded work under `discard_new`, and switches to `block_ingest`
- **THEN** the discarded work cannot block new ingress, and existing usage and discard counts stay unchanged

### Requirement: Output overflow notice does not recurse

Each overflow episode SHALL record one durable Correlia alert and attempt to route one sanitized canonical Correlia-origin event to other active outputs with room and lockable capacity. Routing SHALL skip locked destinations without retrying them after commit and SHALL NOT create sender work, mutate alert state, bypass limits, or raise another overflow alert. The operator RPC and activity ledger SHALL remain authoritative if no destination can accept the notice.

#### Scenario: Alert reaches a healthy output
- **WHEN** one output enters overflow while another active output has capacity
- **THEN** the healthy output receives one canonical alert with no sender raw key and with a reference, digest and size that match its sanitized ledger evidence; the overflowing output receives no notice for itself

#### Scenario: A lower cap opens an episode with no raw work
- **WHEN** publication lowers a blocking output's budget to its retained usage or below while the inbox is empty
- **THEN** the new policy, overflow ledger entry and pending notice commit together, and repeating the publication does not open another episode

#### Scenario: Oversized discard does not keep an episode open
- **WHEN** `discard_new` rejects a payload larger than an empty queue can hold and a later fitting delivery completes
- **THEN** queuing that delivery does not end the episode; completion closes it if the released capacity leaves usage below both limits, and a later refusal can open a new episode

#### Scenario: All other outputs are full
- **WHEN** no other active output has room for an overflow notice
- **THEN** the episode remains visible in operator status and the ledger, no extra intents are enqueued, and no recursive overflow notices appear

#### Scenario: A contended destination does not stop overflow fanout
- **WHEN** an overflow notice can fit on two other active outputs but one has its capacity row locked
- **THEN** the routing transaction commits one event and one intent for the available output, marks the occurrence handled, and creates no intent for the contended output even after its lock releases; the episode remains visible in operator status and in the ledger

#### Scenario: Notice uses a blocking output's last slot
- **WHEN** an overflow notice fits exactly into the last available capacity of a different output configured to block ingest
- **THEN** usage includes that notice and new ingress receives output pressure, but the notice does not start another overflow alert

#### Scenario: Notice selection races registry publication
- **WHEN** overflow fanout and publication of a disjoint 64-output registry contend on the active registry
- **THEN** publication checks an intent already committed to the old registry or the notice selects only new-registry destinations; the combined live inventory never exceeds 64

#### Scenario: Live lane lookup ignores backlog size
- **WHEN** the same live-output IDs have many more queued intents and several pending raw pins become new live intents
- **THEN** publication and replay check the same bounded set of IDs without inspecting the intent backlog, and the raw transitions never hide a retained lane

### Requirement: Retention of terminal delivery evidence

Delivered and discarded intents SHALL become age-eligible after their configured terminal retention, default seven days from delivery or discard. Live and active dead intents SHALL NOT be reclaimed. Reclamation SHALL remove a retired intent's matching attempt records in bounded batches and keep every attempt for work still retained.

#### Scenario: Retention reclaims delivered intents and attempts
- **WHEN** an old delivered intent passes its retention cutoff
- **THEN** maintenance removes that intent and its attempts, and an unrelated active intent and all its attempts remain

#### Scenario: Old creation time with recent completion
- **WHEN** an intent was created before the retention cutoff but just completed, or was still queued, delivering or dead
- **THEN** its old creation date alone is not sufficient to remove it or its attempt history

#### Scenario: Discard starts a new retention window after expiry
- **WHEN** an active dead delivery expires and becomes `discarded`
- **THEN** its terminal retention starts at discard, and the intent and its attempts remain until that window passes

#### Scenario: A discarded intent has more attempts than one batch
- **WHEN** a repeatedly replayed dead intent expires and its terminal retention passes with more attempt rows than one cleanup batch
- **THEN** maintenance removes the intent, its unprotected aged event and its attempts across bounded batches, leaves no reclamation entry, and preserves an unrelated live intent and its attempts
