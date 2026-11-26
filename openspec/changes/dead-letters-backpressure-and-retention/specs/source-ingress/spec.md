# Source ingress delta

## ADDED Requirements

### Requirement: Shared inbox and storage pressure

New webhook and pull writes SHALL honor shared versioned bounds for pending inbox age and count, default 30 seconds and 50,000 rows, and a watermark of 85% of the configured database budget by default. Webhooks SHALL return 429 for inbox pressure and 503 for disk or blocking-output pressure, with whole-second `Retry-After`. Pull admission SHALL pause. A refusal SHALL NOT commit raw rows or dedup reservations.

#### Scenario: DUR-9 inbox limits and recovery
- **WHEN** workers stop and the inbox hits the age or count limit, then workers return and reduce it below that limit
- **THEN** new webhooks receive 429 with `Retry-After` while at capacity and 202 after recovery, pull admission pauses and resumes, and every earlier accepted row remains processable

#### Scenario: Concurrent admission at the last slot
- **WHEN** authenticated requests on separate API instances and a pull batch compete for the final available inbox row
- **THEN** transactions can commit only work that fits, and the rejected requests or batches leave no dedup reservations

#### Scenario: Pending work ages while admission waits for capacity
- **WHEN** the oldest pending row crosses the age limit while a new reservation waits for the counter lock
- **THEN** admission uses the time after acquiring that lock and refuses new work even if the count has room

#### Scenario: Sync admission contends with sync completion
- **WHEN** a pull transaction admits work for a sync run while another worker completes or fails an earlier row of the same sync run
- **THEN** both resolve without relying on a lock timeout, the run accounts for each row once, and pending capacity reflects only committed rows

#### Scenario: Database pressure degrades readiness
- **WHEN** a configured database crosses the disk watermark and later falls below it
- **THEN** new webhooks receive 503 with `Retry-After` and API readiness reports 503 while pressure holds, liveness stays healthy, and admission and readiness recover after the sampled condition clears

#### Scenario: Refused work keeps a refreshed disk sample
- **WHEN** new webhook or pull work finds a stale sample and measures a database over its configured watermark
- **THEN** the new measurement is available to other replicas and the refusal commits neither raw work nor a receipt

### Requirement: Pressure preserves known transport outcomes

Admission SHALL check a live transport or pull-batch receipt before rejecting new work for shared pressure. Exact committed retries SHALL keep their committed response and SHALL NOT consume capacity. A conflicting live webhook key SHALL return 409. Existing authorization, rate limits and pull fencing still apply.

#### Scenario: Retry while capacity is exhausted
- **WHEN** a sender retries a committed delivery within its transport window and a pull connection retries a committed batch while ingress is at capacity
- **THEN** both receive their committed results, neither commits a second raw row, and the original receipt windows do not move

#### Scenario: Conflicting key while capacity is exhausted
- **WHEN** an authenticated sender changes the bytes associated with a live `Idempotency-Key` while ingress is at capacity
- **THEN** it receives 409 rather than an acknowledgement, and the earlier reservation is unchanged

#### Scenario: Expired key disappears during admission
- **WHEN** an authenticated webhook meets an expired transport key that maintenance removes before admission's locked read
- **THEN** the request retries reservation and receives the ordinary accept or pressure result without leaving an extra raw row or a key for refused work

## MODIFIED Requirements

### Requirement: New raw admissions honor the reclamation cutoff

The durable admission cutoff SHALL advance monotonically with reclamation and fence all new raw inserts.
Receipts below it SHALL roll back admission. Consumer rows SHALL use their earliest item receipt. Exact
webhook retries within their transport window and retained batch receipts SHALL return the committed
result without inserting. A live explicit key with a different body SHALL still return 409.
Terminal rows below the cutoff SHALL NOT be requeued except through authorized replay of an eligible
retained raw failure. Such replay SHALL keep the original receipt and SHALL NOT insert a new raw row
or transport reservation. The dead-letter replay eligibility, capacity and ordering rules still apply.

#### Scenario: Webhook reaches admission after its receipt falls behind the cutoff
- **WHEN** a valid webhook read began before the cutoff and attempts a new admission after the cutoff advances past its receipt
- **THEN** it gets 503 and no raw row or transport reservation is committed; a fresh delivery can be admitted

#### Scenario: A buffered stream item falls behind the cutoff
- **WHEN** a new consumer batch contains an item received before the cutoff
- **THEN** no raw row, origin record or batch receipt commits, and the consumer closes, records a gap and resyncs on reconnect

#### Scenario: Committed batch receipt survives advancement of the cutoff
- **WHEN** a consumer retries a batch whose commit acknowledgement was lost and whose earliest receipt is older than the cutoff
- **THEN** while its batch receipt is retained, it gets the committed result without inserting another raw row

#### Scenario: Webhook reservation inside and outside the transport window
- **WHEN** retries of an already committed webhook reach admission with receipts behind the cutoff, one inside the original deduplication window and one after it
- **THEN** the first returns the committed duplicate result and the second returns 503; neither creates a raw row or changes the original reservation

#### Scenario: Conflicting live webhook key behind the cutoff
- **WHEN** a delivery behind the cutoff reuses a still-live explicit key with a different body
- **THEN** admission returns 409 without changing the reservation or inserting a raw row

#### Scenario: Operator replays a retained failure behind the cutoff
- **WHEN** an authorized operator replays an eligible retained raw failure whose original receipt is below the admission cutoff
- **THEN** the existing row is requeued with its original raw ID and receipt; neither a new raw row nor a transport reservation is inserted
