# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Signing key availability before acquisition

Relays SHALL acquire only webhook intents whose signing reference is loaded and matches its stored commitment. A newly activated reference missing from a running worker SHALL leave its webhook intents queued without consuming attempts and emit a fixed sanitized availability diagnostic. Dead intents SHALL retain their key commitment but SHALL not require signing material until an explicit future replay operation. Plugin intents carry no signing reference; their secret availability is governed by plugin supervision.

#### Scenario: Loaded historical signing reference
- **WHEN** an intent retains an older output definition whose committed signing key is still loaded
- **THEN** it is delivered under that original key even though the active configuration uses a newer reference

#### Scenario: Unloaded live signing reference
- **WHEN** another process activates an output reference absent from a running relay's loaded secret set
- **THEN** its intents remain queued, no attempt is started, the missing-reference diagnostic appears and unrelated loaded-key outputs continue delivering

#### Scenario: Plugin intents need no signing reference
- **WHEN** a relay discovers queued plugin intents, which have no signing reference
- **THEN** signing-key availability neither blocks nor admits them, and their acquisition follows plugin readiness
