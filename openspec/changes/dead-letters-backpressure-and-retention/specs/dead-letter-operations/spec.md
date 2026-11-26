# Dead-letter operations

## Purpose

Let an authorized machine inspect and replay retained pipeline failures and delivery dead letters without reading their payloads or changing delivery identity. Expose pressure and maintenance state to operators and the M2 demo.

## ADDED Requirements

### Requirement: Dedicated operator authorization

Listing, replay and status SHALL be typed Serverpod RPCs in the `api` and `all` roles. They SHALL be off by default and require a dedicated machine credential. The server SHALL derive the actor from the verified credential. Responses and diagnostics SHALL NOT expose credential material, raw bodies, delivery payloads, destinations or signing references.

#### Scenario: Configured machine can operate
- **WHEN** a machine presents a configured 256-bit bearer token and lists or replays failures on a ready API or all process with diagnostic logging enabled
- **THEN** only sanitized metadata is returned, successful replay is attributed to the configured machine ID, and no credential, payload, destination or signing reference appears in responses or logs

#### Scenario: Missing or wrong scope
- **WHEN** operator access is off, the caller presents a missing, invalid or ingest token, or the request reaches a worker-only process
- **THEN** the RPC denies access without reading protected rows or changing queue state, and credential bytes do not appear in logs or the response

#### Scenario: Invalid credential file is not echoed
- **WHEN** an API process starts with a malformed configured credential file
- **THEN** it fails before serving operator requests and reports a bounded failure without echoing the file contents

### Requirement: Bounded dead-letter listing

An authorized caller SHALL be able to page pipeline failures and delivery dead letters, with filters for the source or output, error class and failure-time range. Pages SHALL have a bounded size and a deterministic continuation. Listed metadata SHALL include the failure identity, age and sanitized error class; raw failures SHALL include the pinned snapshot and the safe field path when present.

#### Scenario: DUR-4 a failed output is visible to an operator
- **WHEN** an output runs past its automatic retry budget and an authorized machine lists that output's delivery dead letters
- **THEN** it finds the dead intent with an error class and can identify the exact failure occurrence without receiving the stored delivery bytes

#### Scenario: Equal failure times and invalid filters
- **WHEN** several failures with the same timestamp span pages, and a separate request supplies an invalid filter or a continuation for a different filter
- **THEN** the unchanged set is listed once in a deterministic order, and the invalid request returns a bounded error with no failure data

#### Scenario: Filter remains pageable among unrelated failures
- **WHEN** matching failures are sparse among many failures with a different scope or error class
- **THEN** successive pages return matching occurrences in order without traversing the unrelated backlog

### Requirement: Bounded replay selection and audit

An authorized caller SHALL replay one named occurrence or one bounded batch by explicit filter. Replay SHALL recheck status and expiry and take a shared pending slot for each raw row it requeues. It SHALL report queued, refused and continuation results. The count queued and verified actor SHALL commit with the successful changes.

#### Scenario: Bulk replay by filter
- **WHEN** a machine replays a filter matching more than one batch of pipeline failures or dead deliveries
- **THEN** only matching occurrences are considered in each batch, the reply identifies how many were queued and refused, and the machine can use the continuation without repeating prior occurrences

#### Scenario: Replay races replay or expiry
- **WHEN** two requests target the same failed occurrence, or replay and expiry race for it
- **THEN** at most one request can requeue that occurrence, expiry cannot discard a requeued row, and an occurrence already expired or changed is not replayed or audited as a success

#### Scenario: Replay uses a concurrently published retention window
- **WHEN** a replay locks a failed row and a publication shortens its retention before replay takes the active configuration lock
- **THEN** replay checks the new window and leaves the expired occurrence unchanged without auditing it as queued

#### Scenario: Replay competes for the last pending slot
- **WHEN** a raw replay and a new admission race for the last pending slot
- **THEN** only one uses the slot, the count stays at the cap, and a replay refused for capacity retains the original failure without recording a successful replay

### Requirement: Current configuration for pipeline replay

Replay SHALL clear the active failure and requeue eligible raw work under the snapshot active at replay commit. Automatic retries SHALL keep that pin. Replay SHALL preserve bytes, receipt, generation 0, origin and ordinary ordering, and require an enabled source with the original admission mode. It SHALL leave original sync progress unchanged and ledger any reconcile outcome that removes raw without storing an event. Errors from before replay SHALL NOT alter the replay's allowance or schedule.

#### Scenario: DUR-13 a fixed mapping reaches its backlog
- **WHEN** a broken generic mapping fails a row under snapshot A, snapshot B fixes the mapping, a replay commits, and snapshot C activates before a worker claims the row
- **THEN** the same raw row produces generation 0 events under B with its original receipt and normal ordering and output behavior; a subsequent automatic retry keeps B

#### Scenario: Replaying a row from a finished or absent sync run
- **WHEN** a failed Icinga2 reconcile row is replayed after its sync run finished or was pruned
- **THEN** it retains reconcile semantics and leaves the original sync run unchanged or absent; if it confirms without storing an event, the raw row is removed and the ledger records the outcome

#### Scenario: Replay source missing or disabled
- **WHEN** the active snapshot has no compatible enabled binding for a failed row and an operator asks to replay it
- **THEN** the API returns `source_unavailable`, the original failure and expiry remain unchanged, and no new attempt is queued

#### Scenario: Restoring the same source makes the original occurrence replayable
- **WHEN** a disabled Icinga2 source is restored with its original UUID and mode before its retained failure expires
- **THEN** the same failure can replay under the restored snapshot while using its original stream or reconcile origin and admission-time policy

#### Scenario: Earlier error cannot spend replay allowance
- **WHEN** a worker pauses after rolling back an error, another attempt fails the same row, and an operator replays it under that same snapshot before the first worker records its error
- **THEN** the older worker cannot change the replayed row's attempt count, retry time or failure occurrence, and its canonical generation remains 0

### Requirement: Immutable delivery replay

Delivery replay SHALL requeue the same intent with its original bytes, event and delivery IDs, pinned destination and signing commitment. It SHALL give it a fresh retry allowance without resetting attempt numbering or deleting attempt history. It SHALL NOT rerun the pipeline or change alert or incident state.

#### Scenario: DUR-4 delivery replay succeeds after recovery
- **WHEN** the original destination recovers and an authorized machine replays its unexpired dead delivery
- **THEN** the relay sends byte-identical data with the original event and delivery identity and obtains an acknowledgement, even if the active output definition changed in the meantime

#### Scenario: Unavailable key or output lane
- **WHEN** replay would need an unavailable original webhook signing key or exceed the live-output limit
- **THEN** the intent remains dead, no retry allowance is spent, and the response gives a bounded refusal reason

#### Scenario: New retry allowance survives completion and recovery
- **WHEN** a delivery exhausted at attempt 20 is replayed and then sees a retryable result and an interrupted lease
- **THEN** both use the fresh allowance and backoff schedule, attempt numbering continues at 21 and increases, and exhaustion cannot occur until the new allowance is consumed

### Requirement: Protected operational status

The operator RPC SHALL report inbox depth and oldest pending age, database pressure, bounded per-output usage and discard counts, and the last maintenance outcome. It SHALL expose why admission is blocked without including sender data or secrets.

#### Scenario: Pressure and recovery visible to the demo
- **WHEN** inbox or output pressure arises and later clears
- **THEN** authenticated reads show the blocking reason, committed limits and usage, and that the condition cleared without a restart

#### Scenario: Maintenance fails after a previous success
- **WHEN** a maintenance batch rolls back after an earlier batch committed
- **THEN** status reports the failure without claiming that the failed batch expired or removed any rows
