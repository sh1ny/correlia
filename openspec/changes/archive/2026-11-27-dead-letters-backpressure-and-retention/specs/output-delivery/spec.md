# Output delivery delta

## MODIFIED Requirements

### Requirement: Immutable routed delivery intent

Each newly accepted eligible observation SHALL create one delivery intent per distinct routed output in its processing transaction, subject to the output storage policy. An intent SHALL retain immutable structured-CloudEvents bytes, event id and the pinned output definition/secret reference. A configuration change SHALL NOT redirect or re-encode pending work. An explicitly empty route SHALL be unrouted; a missing output or policy discard SHALL NOT be counted as unrouted.

#### Scenario: Fanout with configuration change
- **WHEN** one observation routes to two outputs and their endpoints/configuration change before relay pickup
- **THEN** one intent exists per original output and each delivers its original bytes to its original configured destination

#### Scenario: Explicitly unrouted event
- **WHEN** a source's valid pinned snapshot explicitly selects no outputs
- **THEN** the canonical event commits with an unrouted outcome and no intent, while a missing output reference cannot activate as that configuration

### Requirement: No loss across worker death

After worker replacement, pending plugin deliveries SHALL remain eligible until delivered or dead with a reason. Delivered means confirmed by the destination. No intent SHALL remain delivering beyond its lease, disappear without a recorded retention outcome, or be delivered with changed bytes. An event already recorded as an overflow discard is not a pending delivery.

#### Scenario: Kill -9 during a 1,000-alert burst
- **WHEN** 1,000 alerts are accepted within budget, the worker is killed with SIGKILL while NATS deliveries are in flight, and a replacement worker starts
- **THEN** the set of accepted alert event ids equals the event ids in the JetStream stream plus the dead intents with reasons, the stream has no two messages with one `Nats-Msg-Id`, and no intent is still queued or delivering

#### Scenario: Worker killed before any delivery
- **WHEN** the worker is killed after the events committed and before its plugin became ready
- **THEN** the replacement worker's plugin delivers every pending intent, without a new ingest request

## ADDED Requirements

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
