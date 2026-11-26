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
