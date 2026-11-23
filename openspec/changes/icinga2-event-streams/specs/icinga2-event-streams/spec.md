# Spec Delta

## Purpose

Brings Icinga 2 state into Correlia through the Icinga 2 Event Streams API and a state sync, so missed or
suppressed changes are repaired, and does so with bounded resources, one durable writer per source and visible
gaps.

## ADDED Requirements

### Requirement: Stream source configuration

An `icinga2` source with `mode: event_streams` SHALL declare `api` with `url` (https, host and port only),
`username`, `password_ref`, `ca_ref` and optional `sync_interval_seconds` (300 to 86400, default 3600), plus
optional `state_type_policy` and `max_pending_rows` (100 to 10000, default 1000). It SHALL NOT declare
`credentials`, `body_limit_bytes` or `rate_limit`. Violations SHALL fail activation with a field error.

#### Scenario: Valid stream source
- **WHEN** a version 2 file declares an `icinga2` source with `mode: event_streams` and a complete `api` block
- **THEN** activation succeeds and a worker starts that source's consumer

#### Scenario: Webhook-only field on a stream source
- **WHEN** a stream source declares `credentials`
- **THEN** activation fails with a field error naming `sources[i].credentials` and code `webhook_only`, and the prior snapshot stays active

#### Scenario: URL with a path or plain http
- **WHEN** `api.url` is `http://icinga:5665` or `https://icinga:5665/v1` or carries userinfo or a query
- **THEN** activation fails with a field error naming `sources[i].api.url` and code `invalid_url`

#### Scenario: Sync interval out of range
- **WHEN** `api.sync_interval_seconds` is 60
- **THEN** activation fails with a field error naming that field and code `out_of_range`

### Requirement: Exclusive TLS trust for the Icinga 2 API

The consumer SHALL connect only over TLS 1.2 or newer, trusting only the certificates in the source's CA
secret and requiring the certificate to match the configured host, with no system roots, no proxy and no
redirects. It SHALL send the password only as HTTP basic authentication after that check. No environment
variable SHALL change trust, proxy or key logging.

#### Scenario: Server signed by the configured CA
- **WHEN** Icinga 2 presents a certificate for the configured host signed by the CA in `ca_ref`
- **THEN** the consumer subscribes and its status becomes `connected` after the first sync

#### Scenario: Server signed by a public CA only
- **WHEN** the server's certificate chains to a system root but not to the configured CA, with `SSL_CERT_FILE` and `https_proxy` set to hostile values
- **THEN** the connection fails with error class `tls`, no request carrying the password is sent, and the status records `tls`

#### Scenario: Certificate for another host
- **WHEN** the server presents a certificate signed by the configured CA for a host name other than the one in `api.url`
- **THEN** the connection fails with error class `tls` and no request carrying the password is sent

#### Scenario: Redirect answer
- **WHEN** the subscription is answered with a 307 redirect to another host
- **THEN** the redirect is not followed, the attempt fails with error class `http_status`, and the consumer backs off

#### Scenario: Wrong password
- **WHEN** Icinga 2 answers the subscription with 401
- **THEN** the status records error class `unauthorized`, the consumer backs off, and the password appears in no log, status or row

### Requirement: Fixed state-bearing subscription

The consumer SHALL subscribe with `POST /v1/events`, a `queue` named for the source, no filter, and exactly
the types `StateChange`, `AcknowledgementSet`, `AcknowledgementCleared`, `DowntimeStarted`,
`DowntimeRemoved` and `Flapping`. Response headers SHALL arrive within 10 seconds and the TCP connect within
10 seconds, or the attempt fails.

#### Scenario: Subscription accepted
- **WHEN** Icinga 2 answers the subscription with 200 within the deadline
- **THEN** the consumer reads newline-delimited JSON events from the body, on both close-delimited (2.13 to 2.15) and chunked (2.16) responses

#### Scenario: Headers never arrive
- **WHEN** the server accepts the TCP connection but sends no response headers for 10 seconds
- **THEN** the attempt fails with error class `timeout`, the socket is closed, and the consumer backs off

#### Scenario: Permission missing
- **WHEN** the API user lacks `events/StateChange` and Icinga 2 answers 403
- **THEN** the status records error class `forbidden` and the consumer backs off without syncing

### Requirement: One durable writer per stream source

At most one process SHALL hold write authority for a source: its lease, renewed every 10 seconds and expiring
30 seconds after the last renewal by the database clock. An expired lease SHALL NOT be renewed; it can only be
acquired again, and each acquisition SHALL increment the lease generation. A write whose transaction passed the
lease check before expiry MAY commit after it, but no write SHALL commit after a newer generation was granted.

#### Scenario: Two workers start
- **WHEN** two worker processes start with the same stream source
- **THEN** exactly one holds its lease and connects to Icinga 2; the other connects only after the holder stops or its lease expires

#### Scenario: First start of a new source
- **WHEN** a stream source is published for the first time and a worker starts
- **THEN** the worker creates the source's lease row at generation 1 and connects

#### Scenario: Expiry between the lease check and the commit
- **WHEN** an admission passes its lease check at second 29 after the last renewal, another worker tries to acquire at second 30, and the admission commits at second 31
- **THEN** the acquisition waits for the admission's lock, the admission's rows commit under the old generation, and the new holder's generation is granted only after that commit

#### Scenario: Holder renews after expiry
- **WHEN** a holder's renewal is delayed until 35 seconds after the previous one, and no other worker took the lease
- **THEN** the renewal is refused, the holder closes its connection and acquires the lease again with a higher generation, and records the ended connection's gap before connecting again

### Requirement: A holder closes its connection before its lease can expire

A running holder SHALL close its Icinga 2 connections 20 seconds, by its own monotonic clock, after it sent the
acquisition or renewal whose success it last received. A success received after that deadline SHALL NOT reopen
a connection: the holder acquires the lease again first. A frozen process can keep its socket open until it
resumes; it SHALL then close it without writing.

#### Scenario: Holder frozen past expiry
- **WHEN** the holder's process is frozen for longer than 30 seconds and another worker takes the lease
- **THEN** the new holder's generation is higher, and when the old holder resumes it closes its connection and writes nothing

#### Scenario: Database lost before the first renewal
- **WHEN** a holder acquires the lease, subscribes, and loses the database before its first renewal
- **THEN** it closes its Icinga 2 connection 20 seconds after it sent the acquisition

#### Scenario: Renewal acknowledged after the deadline
- **WHEN** a renewal sent at second 0 succeeds, the renewal sent at second 10 succeeds at the database but its success reaches the holder at second 22
- **THEN** the holder closes its connection at second 20, does not reopen it on the late success, and connects again only after acquiring the lease with a higher generation

#### Scenario: Database unreachable for the holder
- **WHEN** the holder cannot reach the database for 20 seconds while connected
- **THEN** it closes its Icinga 2 connection without waiting for the lease to expire

### Requirement: Fenced consumer admission

Every raw row a consumer writes SHALL commit only if, in the same transaction, the source is enabled with mode
`event_streams` under a shared row lock, the active configuration revision is the one the consumer runs, and
the consumer holds the lease generation with an unexpired lease.

#### Scenario: Paused old holder after takeover
- **WHEN** a holder is paused after reading events and before its insert commits, another worker takes over and syncs, and the old holder then resumes its insert
- **THEN** the insert is refused with `lease_lost`, no raw row or status from the old holder commits, and the new holder's status is unchanged

#### Scenario: Publication between the check and the commit
- **WHEN** a configuration revision that changes the source's `api.url` is published while a consumer's insert is in flight
- **THEN** either the insert commits before the publication under the old revision, or it is refused with `config_changed`; no row admitted under the old endpoint commits after the new revision is active

### Requirement: Admission is idempotent by batch id

Each consumer batch SHALL carry a consumer-generated batch id, unique per source; an admission whose batch id
has already committed SHALL insert nothing and report the batch as committed, by a lookup made before the cap,
revision and lease checks of new inserts. Batch ids SHALL be removed one hour after admission.

#### Scenario: Lost acknowledgement of a stream batch
- **WHEN** a stream batch holding one invalid line commits, its acknowledgement is lost, and the consumer retries it
- **THEN** the retry inserts no row, one failed raw row exists for the line, and the resync request number rose once

#### Scenario: Lost acknowledgement of a sync batch
- **WHEN** a sync batch commits, its acknowledgement is lost, and the consumer retries it
- **THEN** the retry inserts no row, and the sync's `rowsAdmitted` rose by the batch's row count once

#### Scenario: Lost acknowledgement of the batch that filled the cap
- **WHEN** a batch takes the last retained-work slot, commits, and its acknowledgement is lost
- **THEN** the retry's lookup reports it committed, and the consumer neither pauses for it nor inserts it again

#### Scenario: Lost acknowledgement before a settings change
- **WHEN** a batch commits, its acknowledgement is lost, and a revision changing the source's `api.url` is published before the retry
- **THEN** the retry's lookup reports it committed, and nothing is inserted under the old revision

#### Scenario: Batch ids of a removed source
- **WHEN** a source is removed and no holder runs for it
- **THEN** its batch ids are gone one hour after their admission

### Requirement: Failed consumer rows find their admission record

Consumer admission SHALL record each raw row's origin and sync id by raw row id in the insert transaction.
Failing a consumer row on any path, refusal before decoding and retry exhaustion included, SHALL read that
record, never the body or the pinned source: a failed sync row SHALL count on its sync and raise no sync
request; a failed stream row SHALL raise the sync request.

#### Scenario: Sync row whose source was removed
- **WHEN** a sync row is admitted and a revision removing its source is active at first claim
- **THEN** the row fails `source_not_configured`, its sync's `rowsFailed` rises by one in that transaction, the sync can end `failed`, and the sync request number is unchanged

#### Scenario: Stream row refused before decoding
- **WHEN** a stream row fails `source_not_configured` at first claim
- **THEN** the sync request number rises by one in the failing transaction

#### Scenario: Sync row exhausts its retries
- **WHEN** a sync row hits an internal error on every attempt until it fails `processing_exhausted`
- **THEN** its sync's `rowsFailed` rises by one in the failing transaction, and the sync request number is unchanged

### Requirement: Fenced status writes

Every status write SHALL commit only if the consumer holds the lease generation with an unexpired lease, so a
holder whose source was removed or disabled can still record its final `stopped` status.

#### Scenario: Source removed while quiet
- **WHEN** the source is removed from the configuration while no event arrives
- **THEN** within 30 seconds the consumer notices the revision, closes its connection, records its gap and status `stopped`, and releases the lease

#### Scenario: Rotation between batches
- **WHEN** a revision changes the source's password while the consumer holds no batch
- **THEN** the consumer closes its connection, records one gap and reconnects with the new password before admitting another row

### Requirement: Consumers follow the active configuration

Each worker process SHALL check the active revision at least every 30 seconds and start a consumer for each
enabled stream source it does not run, and stop the consumer of each source that is no longer an enabled stream
source.

#### Scenario: First stream source on a running worker
- **WHEN** a worker runs with no stream source and a revision adding one is published
- **THEN** within 30 seconds a worker acquires its lease and connects

#### Scenario: Source disabled on a running worker
- **WHEN** a revision disables a stream source
- **THEN** within 30 seconds its consumer records `stopped`, releases its lease and closes its connection

### Requirement: Configuration changes

When a new revision is active, a consumer whose source keeps the same `api` settings, password and CA
commitments and policy SHALL adopt the revision without reconnecting and retry a refused batch under it. A
consumer whose settings changed SHALL close its connection, record a gap and connect with the new settings. The
consumer SHALL check the active revision at least every 30 seconds, as well as on every refused batch.

#### Scenario: Unrelated revision
- **WHEN** a revision changes only another source and a batch was refused with `config_changed`
- **THEN** the consumer keeps its connection and the batch commits under the new revision

#### Scenario: Endpoint changed
- **WHEN** a revision changes the source's `api.url`
- **THEN** the consumer closes the old connection, records one gap, connects to the new URL and syncs

### Requirement: Lines are validated before batching

The consumer SHALL check each line with the same parser and mapper the pipeline uses, which refuse duplicate
object members at every depth and unknown members at every depth. Valid items SHALL be batched; an item that fails validation SHALL be admitted alone in its own
raw row, so it fails visibly with its field error without failing valid lines read beside it.

#### Scenario: Bad line beside a valid recovery
- **WHEN** one flush window holds a valid `StateChange` recovery and a line with an unknown field
- **THEN** the recovery commits and resolves its alert, the bad line's row fails with its field error, and the connection stays `connected`

### Requirement: Lines are stored as read

Each line SHALL be stored as an item holding its text as read (base64 when it is not valid UTF-8) and its own
receipt time, except that an echoed API password is redacted first, as "An echoed password is redacted before
admission" states.

#### Scenario: Malformed JSON and invalid UTF-8
- **WHEN** a line is not valid JSON, another holds a duplicate member inside `check_result.vars_after`, and another is not valid UTF-8
- **THEN** each is admitted alone with its bytes recoverable from the row, and the rows fail with `invalid_json`, `duplicate_field` on `check_result.vars_after.state`, and `invalid_json`

### Requirement: An echoed password is redacted before admission

Before semantic parsing or emitting any evidence, the consumer SHALL redact API password and base64/base64url
echoes in decoded JSON strings or malformed input bytes. The replacement SHALL NOT reproduce an echo.
Unrelated content SHALL stay intact and changed items SHALL be marked `redacted`.

#### Scenario: Password echoed after a successful subscription
- **WHEN** an authenticated subscription returns a malformed line containing the password and a well-formed acknowledgement whose comment contains it
- **THEN** the admitted items are flagged `redacted`, the malformed bytes and decoded comment omit the echo, and no derived output, status or diagnostic copies it

#### Scenario: Password echoed in a sync object
- **WHEN** a sync object whose check output contains the password produces a retained repair
- **THEN** the admitted item is sanitized, and the retained raw row and the repair's decoded fields do not carry the echo

#### Scenario: Password echoed through JSON string escaping
- **WHEN** an authenticated subscription and a sync repair echo a password through quote, backslash or Unicode escapes
- **THEN** both retained raw items and decoded event fields are sanitized and no derived diagnostic copies the echo

#### Scenario: Escaped sync echo on confirmation or rejected object
- **WHEN** one sync object with an escaped echo confirms an existing alert and another with an escaped echo fails validation
- **THEN** the admitted confirmation is sanitized and deleted after processing, the rejected object is never admitted, and diagnostics copy neither echo

#### Scenario: Replacement cannot contain a short password
- **WHEN** a valid password matches part of a conventional redaction marker and is echoed in a comment
- **THEN** the replacement cannot contain or recreate the echo inside or across its boundaries

#### Scenario: Literal match inside unrelated escape
- **WHEN** a valid JSON string contains the wire spelling `\u0041` and the password is `u0041`
- **THEN** the valid event keeps the decoded `A` and does not gain a redaction marker or fail validation

#### Scenario: Redaction does not make an originally malformed line eligible
- **WHEN** a raw tab matching the password makes a stream comment invalid JSON, and sanitizing the tab makes the retained line parseable
- **THEN** the sanitized item is admitted alone with its original `invalid_json` verdict, the raw row fails with that code, and no event is emitted

### Requirement: Failure paths name only known members

A failure's field path SHALL be built from member segments, never by splitting text on dots. A segment SHALL be
written by name only when it is a member this capability defines at that position, and as `*` otherwise.

#### Scenario: Unknown member whose name looks like a path
- **WHEN** a line's top level holds an unknown member named `check_result.vars_after.state`
- **THEN** it fails with `unknown_field` on path `*`, and the name does not appear in the stored failure

#### Scenario: Unknown nested member
- **WHEN** `check_result.vars_after` holds an unknown member `secret_hint`
- **THEN** it fails with `unknown_field` on path `check_result.vars_after.*`

### Requirement: Oversize lines are skipped

A line over 1 MiB SHALL be skipped without buffering, counted as an oversize line, and SHALL request a sync.

#### Scenario: Oversize line
- **WHEN** Icinga 2 sends a 2 MiB line
- **THEN** the line is skipped, the source's oversize-line count increases by one, a sync is requested, and the following lines are read normally

### Requirement: Bounded batches

A raw row SHALL hold at most 100 items and at most 256 KiB of encoded body, except that one item alone MAY
fill a row up to the 1 MiB line limit plus its encoding. A batch SHALL be flushed at most 1 second after its first item was read, and only one batch per consumer
SHALL be in flight at a time.

#### Scenario: Burst of events
- **WHEN** Icinga 2 sends 250 small events at once
- **THEN** they are admitted as three raw rows of at most 100 items each, in read order

#### Scenario: Large valid line
- **WHEN** a valid 300 KiB line is read beside small ones
- **THEN** it is admitted alone in its own row, and the small lines go into other rows

#### Scenario: Single slow event
- **WHEN** one event arrives and no other follows
- **THEN** it is admitted within 1 second of being read

### Requirement: Batches fit the pipeline's fanout limit

The consumer SHALL cut a batch before the sum of its items' canonical event bytes times nine (one payload plus
one per output, for the 8-route maximum) exceeds 8 MiB, half the pipeline's fanout limit, whatever routes are
active.

#### Scenario: Fanout cut before the encoded cut
- **WHEN** in a test whose encoded-size limit is raised to 16 MiB, valid items whose canonical events total more than 8 MiB ÷ 9 arrive in one flush window
- **THEN** the batch is cut by the fanout limit, and a run with the fanout check removed fails this test

#### Scenario: Worst-case fanout
- **WHEN** a source receives 100 valid items whose canonical events are each at the maximum size, and a revision raising its routes from 1 to 8 is active when the rows are first claimed
- **THEN** the batches were cut so no row's fanout exceeds 8 MiB under 8 routes, and every row commits within the pipeline's row deadline

### Requirement: Retained work is bounded

Before each flush, the consumer SHALL pause reading while the source's pending and failed raw rows together
number `max_pending_rows` or more. If the reader is kept from reading for 30 seconds (paused at the cap, or
waiting for an insert or the in-flight slot), the consumer SHALL close the connection with error class
`backpressure`, record a gap and reconnect after backoff, so Icinga 2 drops its queue. Waiting for data on a
quiet connection SHALL NOT count.

#### Scenario: Pipeline briefly behind
- **WHEN** the source's pending rows reach the cap and drop below it 5 seconds later
- **THEN** the consumer pauses, resumes reading the same connection, and no gap is recorded

#### Scenario: Pipeline stopped
- **WHEN** the pipeline stops claiming rows and the pending count stays at the cap
- **THEN** after 30 seconds the connection is closed with `backpressure`, one gap is recorded, and no more than `max_pending_rows` plus one batch of rows is pending for the source

#### Scenario: Failures accumulate
- **WHEN** every row of the source fails, so none stays pending
- **THEN** once the source's failed rows reach `max_pending_rows` the consumer pauses and then disconnects with `backpressure`, and its failed rows stay at most `max_pending_rows` plus one batch

#### Scenario: Quiet connection
- **WHEN** Icinga 2 sends no event for 10 minutes on a healthy connection
- **THEN** the connection stays open and no gap is recorded

#### Scenario: Insert blocked below the cap
- **WHEN** another transaction holds a lock the admission needs for 40 seconds, so every admission attempt of one batch fails its 2-second lock timeout while the source is below the cap
- **THEN** 30 seconds after the reader was first blocked the connection is closed with `backpressure`, one gap is recorded, and the batch's rows are committed at most once

### Requirement: Sync rows that changed nothing are removed

A sync row whose items stored no event SHALL be deleted in the transaction that processes it, after its counts
are added to its sync. Stream rows, sync rows that stored an event and failed rows SHALL be kept like webhook
rows, with no limit of their own until the database-size watermark arrives; the documentation SHALL state this.

#### Scenario: Steady installation
- **WHEN** a sync of 10,000 objects that only confirm or tombstone is processed
- **THEN** none of its raw rows remain, and its counts are on the sync

#### Scenario: Kept rows follow stored events
- **WHEN** a sync of 10,000 objects whose 3 repairs fall in 3 different rows is processed, and 50 stream rows are processed
- **THEN** exactly those 3 sync rows and the 50 stream rows remain

### Requirement: Sustained read lag closes the connection

The consumer SHALL measure each event's lag as its receipt time minus its Icinga `timestamp`, relative to the
smallest lag seen on the connection. Excess lag above 60 seconds for 120 seconds SHALL close the connection
with `lag`, record a gap and reconnect, even if no single pause reached 30 seconds. Below that excess, a consumer
MAY stay behind while input matches drain; the documentation SHALL state it.

#### Scenario: Repeated short pauses
- **WHEN** Icinga 2 produces events faster than flushes drain them, so the consumer pauses many times for under 30 seconds each and the excess lag grows past 60 seconds for 120 seconds
- **THEN** the connection is closed with `lag` and one gap is recorded

#### Scenario: Initial backlog with constant excess lag
- **WHEN** Icinga 2 holds 100,000 queued events when a subscription starts, and new events then arrive as fast as the consumer drains, so the excess lag over the connection's smallest lag stays below 60 seconds
- **THEN** no lag disconnect happens, the consumer pauses only at the retained-work cap, for an insert or for the in-flight slot, and it closes with `backpressure` only if the reader is blocked for 30 seconds

#### Scenario: Initial backlog with growing excess lag
- **WHEN** Icinga 2 holds 100,000 queued events when a subscription starts, and new events then arrive faster than the consumer drains, so the excess lag grows past 60 seconds and stays there for 120 seconds
- **THEN** the connection is closed with `lag` and one gap is recorded

#### Scenario: Constant clock offset
- **WHEN** Icinga 2's clock is 10 minutes behind Correlia's and the consumer keeps up
- **THEN** no lag disconnect happens

### Requirement: Icinga 2's own queue is not bounded by Correlia

The stall and lag rules SHALL close a consumer only once a 30-second reader stall or 120 seconds of excess lag
persists; a consumer that falls behind below those triggers stays connected, and the rules do not bound the
memory Icinga 2 uses for its queue. The documentation SHALL state this residual risk and the drain rate the
load test measured over a sustained run.

#### Scenario: Residual risk documented
- **WHEN** a test reads the limits documentation
- **THEN** it finds the queue-memory risk, that a consumer can stay behind while input matches drain, and the drain rate in events per second measured over the sustained run's measurement interval

### Requirement: State sync on connect and periodically

After each successful subscription, and every `sync_interval_seconds` while connected, the consumer SHALL read
every host and service with separate host and service attribute sets and admit each object that has a check
result as a reconcile observation, while it keeps reading the stream. The stream SHALL already be subscribed
before the sync query is sent.

#### Scenario: Recovery missed while disconnected
- **WHEN** a service's alert is firing, the connection is down while the service recovers, and the consumer reconnects
- **THEN** the sync resolves the alert and publishes one resolved event

#### Scenario: Recovery missed nine days ago, checked since
- **WHEN** a service recovered nine days ago during a disconnect and has been checked OK since
- **THEN** the sync on reconnect resolves its alert, because its last check result is recent

#### Scenario: Passive service not reported for nine days
- **WHEN** a passive service's last result, an OK nine days old, was missed, and no result was submitted since
- **THEN** the sync counts it `late` and `diverged`, the alert stays firing, and the sync counts show it

#### Scenario: Sync on a large installation
- **WHEN** Icinga 2 has hosts and services together producing a sync response of 200 MiB
- **THEN** the sync completes with each object parsed on its own and the consumer's memory bounded by one object and one batch

#### Scenario: Object without a check result
- **WHEN** a service has never been checked
- **THEN** no observation is admitted for it and it is counted as `no_result` on the sync

#### Scenario: Sync request fails
- **WHEN** the host query answers 500, or the sync does not finish within 15 minutes
- **THEN** the sync outcome is `failed` with its error class, the connection is closed, one gap is recorded, and the consumer reconnects after backoff

### Requirement: Sync objects share the stream's identity

A service's identity SHALL come from its `host_name` and its short `name`, the same values a `StateChange`
carries as `host` and `service`, so stream and sync observations of one source share an event ID. A webhook
source in the same namespace shares only the fingerprint.

#### Scenario: Same service through stream and sync
- **WHEN** one real service's result is received as a `StateChange` and later reported by a sync, in a capture
- **THEN** both observations have the same fingerprint and event id

### Requirement: A bad sync object does not hide the objects after it

A sync object that fails validation, that the response reports as an error, or that is over 1 MiB SHALL NOT be
admitted. It SHALL be counted on the sync (`invalid_object`, `object_error`, `object_too_large`), with the
names and error codes of the first 20 such objects, and logged; the sync SHALL go on reading and end `failed`.
A bad object SHALL NOT request a sync.

#### Scenario: Persistent bad object before a missed recovery
- **WHEN** every sync's response holds an invalid object followed by a service whose missed recovery is eligible, and three syncs run
- **THEN** the first sync resolves the alert and publishes one event, the later syncs publish nothing for it, each sync ends `failed` with `invalid_object` 1 and the object's name, and no raw row is written for the bad object

#### Scenario: Bad object fixed in Icinga 2
- **WHEN** the bad object is corrected in Icinga 2 and the next sync runs
- **THEN** that sync ends `complete`, and the source's retained raw rows did not grow from the bad object

#### Scenario: Per-object error in a 2.16 response
- **WHEN** a 2.16 objects response is 200 and one element of `results` carries an error code
- **THEN** the other objects are applied, and the sync ends `failed` with `object_error` 1

### Requirement: Bad-object diagnostics are bounded and safe

A bad object SHALL be identified in the sync's sample and log only by its host and service names when both
were read as valid names of at most 255 bytes without control characters, and otherwise by its position in the
response. The sample SHALL hold at most 20 entries of at most 600 bytes each, and a sync SHALL log at most those
20 entries and one summary with its counts.

#### Scenario: Unreadable name
- **WHEN** a bad object's `name` holds control characters, or an object over 1 MiB is skipped before its name is read
- **THEN** the stored sample and the captured log output identify it as `results[<index>]`, and neither holds the raw name

#### Scenario: Every object bad
- **WHEN** a sync reads 100,000 objects that all fail validation
- **THEN** the sync logs at most 21 records for them, 20 entries and one summary counting 100,000

### Requirement: Broken sync framing ends the reading

An element whose JSON framing cannot be followed (an unterminated string or an unmatched bracket), a truncated
response, an HTTP error or the sync deadline SHALL end the reading and the sync `failed` (`invalid_framing`,
`truncated`, `http_status`, `timeout`), keeping the rows already admitted, and close the connection.

#### Scenario: Truncated response after a valid prefix
- **WHEN** the service response ends mid-object after 500 valid objects were admitted
- **THEN** the admitted rows still apply, the sync ends `failed` with `truncated`, and a new sync starts after reconnecting

#### Scenario: Unterminated string
- **WHEN** an element of `results` opens a string that never closes before the response ends
- **THEN** the sync ends `failed` with `invalid_framing`, and objects admitted before it still apply

#### Scenario: Syncs that never finish
- **WHEN** three syncs in a row end at the 15-minute deadline
- **THEN** the status shows 3 consecutive sync timeouts and the last object each one read

### Requirement: Sync completion means applied

A sync SHALL be `reading` until its reading ends, then `applying`. One guarded step, run under a lock on the
sync's record when reading ends and in each of its rows' processing transactions, SHALL set `failed` once a row
failed or reading met a problem, else `complete` once reading ended and every admitted row is done. A sync still
applying 15 minutes after its reading ended SHALL be `stalled`, until that step sets `complete` or `failed`.

#### Scenario: All rows applied
- **WHEN** every row of a sync is processed
- **THEN** the sync ends `complete` with the counts of objects, repairs, confirmations, tombstones, `no_result`, `late` and `diverged`

#### Scenario: Last row done before reading ends
- **WHEN** the pipeline processes a sync's last admitted row before the consumer records the end of its reading
- **THEN** recording the end of reading sets the sync `complete`

#### Scenario: Sync with no object
- **WHEN** a sync reads no object with a check result
- **THEN** it ends `complete` when its reading ends

#### Scenario: Failed row while reading
- **WHEN** a sync row fails while that sync is still reading
- **THEN** the sync goes on reading and ends `failed`, never `complete`, whatever its later rows do

#### Scenario: Still applying
- **WHEN** reading ends and some of the sync's rows are still pending
- **THEN** the sync is `applying`, not `complete`

#### Scenario: Application blocked on a reachable database
- **WHEN** one of the sync's rows keeps failing transiently without using its attempt budget for 15 minutes after reading ended, and is then processed
- **THEN** the sync is `stalled` at 15 minutes, the next sync can start, and the sync ends `complete` when the row is done

#### Scenario: Takeover during a sync
- **WHEN** the holder dies while a sync is reading objects and another worker takes over
- **THEN** the old sync ends `failed` with `holder_lost`, and the new holder runs a new sync

### Requirement: An interrupted sync is closed before the next one

When a sync's reading is cancelled (reconnect, lag, backpressure, stop, lease loss), the consumer SHALL record
the end of its reading with problem `interrupted`, fenced and only if its reading has not ended. Before starting
a sync, a holder SHALL first close this way every sync of the source whose reading has not ended, whatever its
phase.

#### Scenario: Reconnect during a sync, same generation
- **WHEN** the connection closes with `lag` while a sync is reading, and the same holder reconnects
- **THEN** the old sync's reading ended with `interrupted`, it ends `failed` once its admitted rows are counted, and the new sync starts

#### Scenario: Close not recorded before the reconnect
- **WHEN** the database is unreachable as the reading is cancelled, and becomes reachable before the next sync
- **THEN** the holder closes the old sync before starting the new one, and no sync stays `reading`

#### Scenario: Takeover after a row failed during reading
- **WHEN** a sync row failed, setting the sync `failed` while its reading was still open, and the holder dies
- **THEN** the new holder records the end of that sync's reading with `holder_lost` before its own sync

### Requirement: Syncs of a retired source are closed

When a source is absent from the active configuration or disabled and its lease has expired, the supervisor
SHALL, in one transaction holding the source and lease row locks and only while both conditions still hold, end
the reading of its open syncs with problem `source_retired`, record its pending gap and set its status `retired`.

#### Scenario: Source removed during a database outage
- **WHEN** the database drops while a sync is reading, a publication removes the source before it returns, and no holder reconnects
- **THEN** once the lease has expired the supervisor ends that sync's reading with `source_retired`, the sync ends `failed`, the status reads `retired` with the gap counted, and the sync's record is pruned only after its rows are done or failed and 30 days have passed

#### Scenario: Disabled source's progress pruned
- **WHEN** a source stays listed but disabled for 31 days after its last sync ended with every row done
- **THEN** its progress rows are pruned like those of a removed source

#### Scenario: Source re-added after a long absence
- **WHEN** a source is removed, 40 days pass, and the same source id is published again
- **THEN** its new holder's lease generation, connection sequence and sync request number continue from their values before the removal

#### Scenario: Source re-enabled during the retirement sweep
- **WHEN** a publication re-enables the source and a holder acquires its lease while the supervisor's sweep runs
- **THEN** either the sweep commits first and the new holder starts after it, or the sweep changes nothing; the new holder's sync, lease and status are never closed or removed by it

### Requirement: Sync counts survive late rows

A row processed after its sync ended SHALL still add its counts to the sync. A sync's record SHALL be kept while
any of its rows is pending, and for 30 days after it ended.

#### Scenario: Rows removed before the outcome is read
- **WHEN** the sync's done rows are deleted before the holder reads its outcome
- **THEN** the outcome and counts are unchanged, because they come from the sync's own counters

#### Scenario: Row done after a takeover
- **WHEN** a sync ended `holder_lost` and one of its admitted rows is processed later
- **THEN** the row's counts are added to that sync and its outcome stays `failed`

#### Scenario: Row pending past 30 days
- **WHEN** a sync ended 31 days ago and one of its rows is still pending
- **THEN** the sync's record is kept until that row is done or failed

### Requirement: One sync at a time

A source SHALL read at most one sync at a time. A sync request SHALL be a durable request number that only grows;
a sync SHALL serve every request numbered up to the one it read when it started. While a holder is connected and
not paused, a sync SHALL start within 5 minutes of an unserved request or of the end of the running sync's
reading, whichever is later; otherwise the request SHALL stay unserved and shown in the status.

#### Scenario: Request during a sync
- **WHEN** a stream row fails while a sync is reading objects
- **THEN** a second sync starts within 5 minutes after the first one's reading ends, and both outcomes are recorded

#### Scenario: Request and start at the same moment
- **WHEN** a row failure raises the request number just after a sync started and read the previous number
- **THEN** the later request is still unserved, and another sync starts within 5 minutes after the running one's reading ends

#### Scenario: Request while paused
- **WHEN** a stream row fails while the consumer is paused at the retained-work cap
- **THEN** the status shows the request unserved, and the sync after the next subscription serves it

### Requirement: Syncs are spaced

A sync SHALL start at least 60 seconds after the previous sync of the source started, by any holder or
generation, whatever triggered it. A sync due within that time SHALL start once it has passed, if the connection
is still open; if it closes first, the next subscription's sync replaces it.

#### Scenario: Connection flapping
- **WHEN** the connection to Icinga 2 drops and reconnects every 5 seconds for 10 minutes
- **THEN** at most 10 syncs start, and the status shows the reconnects

#### Scenario: Takeover inside the spacing window
- **WHEN** holder A starts a sync and dies 1 second later, and holder B acquires the lease 30 seconds later and subscribes
- **THEN** B's first sync starts 60 seconds after A's sync started, not before, provided B's connection is still open then

### Requirement: Stream and sync observation evidence

A state observation from a `StateChange` event or a sync object SHALL take its state and state type from its
check result's `vars_after` and its source time from `execution_start`. Its observation key SHALL be the
canonical JSON array of `icinga2.check.v1`, state, state type, `execution_start` and `execution_end`, so a
stream event and a sync of the same check result share one event id.

#### Scenario: Sync of an already streamed change
- **WHEN** a `StateChange` for a result is processed and a later sync reports the same result as the object's last check result
- **THEN** the sync observation has the same event id and is a `duplicate_observation` with no published event

#### Scenario: Regressing execution end
- **WHEN** Icinga 2 accepts a CRITICAL result with start 10:00 and end 10:04, then an OK result with start 10:01 and end 10:02, and Correlia sees only the CRITICAL on the stream before a sync
- **THEN** the sync's OK observation is newer by `execution_start`, and the alert ends resolved

#### Scenario: Three observations in every order
- **WHEN** a CRITICAL (start 10:00), a sync OK (start 10:01) and a WARNING (start 10:02) of one service are processed in each of the six orders
- **THEN** the alert ends firing with severity `warning` in every order

#### Scenario: Recovery by sync before an older stream problem, on an empty database
- **WHEN** on a database with no alert for a service, a sync OK (start 10:02) and a stream CRITICAL (start 10:01) are processed in both orders
- **THEN** in both orders the alert ends resolved; when the OK is processed first, the CRITICAL is stored as `stale` and the committed outbox holds no intent for it

### Requirement: Key time text and ordering time

Each time in an Icinga2 stream or sync observation key SHALL be written as Dart's `double.toString` text of the
parsed double: the shortest round-trip digits, with `.0` for a whole number and never an exponent in the
accepted range. The ordering source time SHALL be the exact floor, in whole microseconds, of the double's value.
A time SHALL be accepted only for 1 ≤ t < 2^33 seconds.

#### Scenario: Key times
- **WHEN** events carry `execution_start` `1763571234.123456`, `4294967296.000011`, `8589934591.999999`, `4294967296.000001` and `1763571234` as JSON numbers
- **THEN** each key holds the `double.toString` text (`1763571234.0` for the whole number), committed vectors pin the key strings, bytes and event ids, and the source times are the exact floors, `4294967296.000001` giving `4294967296000000` µs

#### Scenario: Invalid time
- **WHEN** `execution_start` is missing, not a number, below 1 or at or above 2^33
- **THEN** the item fails with `missing_field`, `invalid_type` or `out_of_range` on that field's path

### Requirement: Ordering holds within the clock and lateness limits

When only this source writes an object's alert, its observations SHALL converge on the result with the latest
`execution_start` among results delivered and applicable under the policy, if Icinga 2's clock is within the
accepted skew, that result is within the lateness horizon, and its start is at least 1 µs later than the
others'. Otherwise the clamp and lateness rules apply, and a disagreeing sync object SHALL count `diverged`.

#### Scenario: Icinga 2 clock ahead beyond the skew
- **WHEN** Icinga 2's clock is 30 minutes ahead, and a CRITICAL received at 10:02 and an OK received at 10:01 carry starts 10:30 and 10:31
- **THEN** both are clamped to their receipt time plus the skew, the alert ends as that ordering decides, and the next sync counts it `diverged` if it disagrees

#### Scenario: Later SOFT result under hard_only
- **WHEN** under `hard_only` a HARD OK (start 10:00) resolves a service, a SOFT CRITICAL (start 10:01) follows, and a sync then reports that SOFT CRITICAL
- **THEN** the alert stays resolved, and the sync counts the object `soft_info`, not `diverged`

#### Scenario: Another source writes the same alert
- **WHEN** a webhook source sharing the namespace reports the same object with a later source time
- **THEN** the alert follows the fence across both sources, and this requirement's convergence promise does not apply

### Requirement: Starts within one microsecond are equal starts

Two results of one object whose starts fall in the same microsecond SHALL be ordered as equal starts: by receipt
time, then event id. Distinct results with equal starts are outside the convergence promise: when copies arrive
through both stream and sync, the final state MAY depend on processing order, a disagreeing sync SHALL count the
object `diverged`, and the documentation SHALL state it.

#### Scenario: Equal start times
- **WHEN** two results of one object carry the same `execution_start`, or starts 238 ns apart in the same microsecond, and different states
- **THEN** they are ordered by receipt time then event id, as for every source, also after the alert's fence is reloaded, and the documentation states it

#### Scenario: Sync copy among equal starts
- **WHEN** a stream OK, a stream CRITICAL with the same start and a sync copy of the OK are processed in an order that leaves the alert disagreeing with Icinga 2
- **THEN** the next sync that disagrees counts the object `diverged`, and the limits documentation lists equal starts as outside the promise

### Requirement: Every disagreeing sync item counts diverged

A sync item whose status or severity differs from its alert's once the item is processed SHALL count `diverged`
on its sync, whether it was stale, late, future-dated or a duplicate, and SHALL change nothing beyond the effects
of that outcome. An item counted `soft_info` is not counted `diverged`.

#### Scenario: Keyed sync copy of the losing result
- **WHEN** a stream OK applies, a stream CRITICAL with the same start and a later receipt time wins the fence, and a sync then reports the already-keyed OK as the object's last result
- **THEN** the sync item is a `duplicate_observation`, the alert stays firing with its version unchanged, no event or output intent is written, and the sync counts the object `diverged`

### Requirement: Host state from the check result

For a host, the raw `vars_after.state` SHALL be normalised as Icinga 2 does: OK and WARNING to UP, CRITICAL
and UNKNOWN to DOWN. A DOWN host whose `vars_after.reachable` is false SHALL be reported as UNREACHABLE. The
mapping to status and severity SHALL be the webhook's.

#### Scenario: Host raw WARNING
- **WHEN** a host `StateChange` carries `vars_after.state` 1 (WARNING) and HARD
- **THEN** the observation reports UP and resolves the host's alert

#### Scenario: Unreachable host
- **WHEN** a host result carries raw state 2 and `reachable` false, HARD
- **THEN** the observation is `firing`, severity `critical`, `severity_original` `UNREACHABLE`

#### Scenario: Unknown raw state
- **WHEN** `vars_after.state` is 99 or 7
- **THEN** the item fails with `invalid_state` on `check_result.vars_after.state`

### Requirement: Soft and hard state policy

Under `soft_and_hard`, a SOFT non-OK observation SHALL fire like a HARD one. Under `hard_only` (default), a
SOFT non-OK observation SHALL store no event and no observation key and change no alert; it SHALL be counted
`soft_info` on its row. An OK or UP observation SHALL resolve under both. The policy of the row's pinned
configuration snapshot SHALL apply, so the first revision that applies an observation decides its effect.

#### Scenario: Missed recovery superseded by a SOFT result
- **WHEN** under `hard_only` a HARD CRITICAL alert is firing, its OK result is missed during a gap, and on reconnect the object's last result is a newer SOFT CRITICAL
- **THEN** the sync counts the object `soft_info`, the alert stays firing, and the limits documentation states that a sync cannot recover a transition superseded by a skipped result

#### Scenario: Soft problem under hard_only
- **WHEN** a service goes SOFT CRITICAL and recovers before becoming HARD, under `hard_only`
- **THEN** no alert is created, no event is stored for the SOFT result, and the row counts it `soft_info`

#### Scenario: Soft problem under soft_and_hard
- **WHEN** the same sequence occurs under `soft_and_hard`
- **THEN** an alert fires on the SOFT CRITICAL and resolves on the OK

#### Scenario: Policy changed between admission and claim
- **WHEN** a SOFT CRITICAL row is admitted under `hard_only`, and a revision switching to `soft_and_hard` is active when the row is first claimed
- **THEN** the row is processed under `soft_and_hard`, its pinned snapshot's policy

#### Scenario: Copies of one result under two policies
- **WHEN** one SOFT CRITICAL result is admitted twice, and the copies are pinned to a `hard_only` and a `soft_and_hard` revision, processed in both orders
- **THEN** in both orders the `soft_and_hard` copy fires the alert with the result's event id, and the `hard_only` copy stores nothing

### Requirement: Late and future stream items are counted, not stored

An item of a stream or sync row whose source time is beyond the lateness horizon or the future limit SHALL be
counted on its row and SHALL store no event and no observation key, so a late copy never takes the event id of a
prompt copy of the same result.

#### Scenario: Late copy processed before the prompt copy
- **WHEN** a firing alert's recovery is admitted promptly, a copy of the same result received more than 7 days after its start is processed first, and then the prompt copy is processed
- **THEN** the late copy is counted `late` with no key, the prompt copy resolves the alert and publishes one event, and the next sync confirms

#### Scenario: Prompt copy processed first
- **WHEN** the same two copies are processed in the opposite order
- **THEN** the prompt copy resolves the alert and publishes one event, and the late copy is counted `late` with no key

### Requirement: Acknowledgement, downtime and flapping from the stream

`AcknowledgementSet` and `AcknowledgementCleared` SHALL become `ack` events, `DowntimeStarted` and
`DowntimeRemoved` `downtime` events, and `Flapping` a `state` event, each with status `info`, the object's
fingerprint and the event `timestamp` as source time, and no alert-state effect. Their observation key SHALL
hold the type, the `timestamp`, and the author, downtime name or flapping flag.

#### Scenario: Acknowledgement set
- **WHEN** an operator acknowledges a firing service in Icinga 2
- **THEN** one `ack` event with status `info` is published, and the alert's status, severity and version are unchanged

#### Scenario: Two acknowledgements by different authors at one instant
- **WHEN** two `AcknowledgementSet` events of one service carry the same `timestamp` and different authors
- **THEN** they have different event ids, each key holding `icinga2.stream.acknowledgementset.v1`, the type, the timestamp text and the author

### Requirement: Unsupported event types fail

A line whose type is not in the subscribed set SHALL be admitted alone and fail.

#### Scenario: Event type not subscribed
- **WHEN** a line carries type `CheckResult`
- **THEN** it is admitted alone and fails with `unsupported_type` on `type`

### Requirement: Reconnect with backoff

After a connection ends, the consumer SHALL reconnect after a delay starting at 1 second, doubling to at
most 60 seconds, with 20% jitter, and reset after 5 minutes connected. Every reconnect SHALL be followed by a
sync before the status returns to `connected`.

#### Scenario: Icinga 2 restarts
- **WHEN** Icinga 2 restarts and is back after 20 seconds
- **THEN** the consumer reconnects within the backoff schedule, syncs, and its status is `connected` with one more gap

#### Scenario: Icinga 2 down for an hour
- **WHEN** every attempt fails for an hour
- **THEN** attempts are at most 60 seconds plus jitter apart and the status shows `backoff` with the last error class

### Requirement: Consumer status

Each stream source SHALL have a durable status without secrets: state, connection id, connected and last event
times, current and last sync with outcome and counts, unserved sync requests, consecutive sync timeouts, gap
count, oversize-line count, current lag and last error class. It SHALL be readable through a read-only API method under the console access policy, and every state
change SHALL be logged.

#### Scenario: Status read locally
- **WHEN** the status method is called in development mode from loopback while a consumer is `connected`
- **THEN** it returns that source's status with no password, CA bytes or commitment

#### Scenario: Holder died with no replacement
- **WHEN** the only worker dies while its consumer is `connected`, and the `api` process keeps serving the status method
- **THEN** once the lease has expired by database time, the method and the documented status query report the source `stale`, not `connected`, without writing the status row

#### Scenario: Status method in production
- **WHEN** the status method is called in production mode
- **THEN** it is refused as the console access policy refuses it, and the consumer's state changes are in the log

### Requirement: Gaps counted once per connection

Each connection SHALL get the next number of the source's connection sequence, recorded before its subscription
is sent. The gap of a connection SHALL be counted only if its number is higher than the last one counted, and a
holder SHALL count the gap of its previous connection, or its predecessor's last one, before it numbers a new
connection.

#### Scenario: Gap recorded by the next holder
- **WHEN** a holder dies while `connected`, and another worker takes over
- **THEN** the gap count increases by exactly one for the dead connection

#### Scenario: Gap already recorded
- **WHEN** a holder records the gap for its closed connection and dies before reconnecting, and another worker takes over
- **THEN** the gap count does not increase again for that connection

#### Scenario: Death between recording a connection and subscribing
- **WHEN** a holder records a new connection number and dies before its subscription is sent
- **THEN** the next holder records one gap for that connection

#### Scenario: Late retry of an older gap
- **WHEN** a holder retries counting the gap of connection 4 after the gap of connection 5 was counted
- **THEN** the gap count does not change

#### Scenario: Status write during a database outage
- **WHEN** the database is unreachable while the connection ends, then recovers
- **THEN** the holder records the gap once the database is back, and the gap count increases by exactly one

#### Scenario: Two oversize lines on one connection
- **WHEN** two lines over 1 MiB arrive on one connection
- **THEN** the oversize-line count increases by two and the gap count does not change

### Requirement: A failed stream row requests a sync

When a stream row of a stream source fails in the pipeline, the pipeline SHALL raise the source's sync request
number in the same transaction, creating the request record if none exists, without a lease. A failed sync row
SHALL fail its sync and leave the repair to the next periodic sync, so a repeating failure cannot start syncs
in a loop. The consumer SHALL start a sync as "One sync at a time" states.

#### Scenario: Stream row exhausts its retries
- **WHEN** a valid stream row fails after its internal retry budget while the connection stays healthy
- **THEN** a sync starts within 5 minutes and repairs the affected alerts

#### Scenario: Failure before any status exists
- **WHEN** the first row of a new stream source fails before its consumer wrote any status
- **THEN** the request record is created with number 1, and the consumer's first sync serves it

#### Scenario: Sync row fails
- **WHEN** a valid sync row fails after its internal retry budget
- **THEN** its sync ends `failed`, the request number is unchanged, and the next periodic sync runs as scheduled

#### Scenario: No failure
- **WHEN** every row is processed
- **THEN** only the periodic sync runs

### Requirement: Consumer database sessions end their own work

Each consumer SHALL admit rows over its own database connection, outside the shared pool, opened with Serverpod's
database settings (a Unix socket for the embedded database, TCP with the configured TLS otherwise). Its session
SHALL check the client connection every second and end a transaction idle for 5 seconds; over TCP it SHALL also
set keepalives and a 10-second TCP user timeout.

#### Scenario: Stop during a stalled insert
- **WHEN** the worker is stopped while an insert transaction holds its locks and is idle between statements, over the embedded database's Unix socket
- **THEN** within 5 seconds an independent connection sees the locks released and none of the insert's rows, and stop returns within 10 seconds

#### Scenario: Stop during a running statement
- **WHEN** the worker is stopped while the insert transaction runs an interruptible statement that a test hook makes last 30 seconds with its statement timeout lifted
- **THEN** within 5 seconds of the stop an independent connection sees the session gone and its locks released

#### Scenario: Insert finishing as stop begins
- **WHEN** an insert's commit and the stop happen at the same moment
- **THEN** the insert either committed wholly or left no row, and no other session's work is affected

### Requirement: Consumer stops within the shutdown deadline

On stop or lease loss, the consumer SHALL close its HTTP connections, and its database connection no later than
4 seconds after stop began, so the worker's stop returns within 10 seconds for all its consumers together.
PostgreSQL then ends the session and releases its locks once its backend can process the closed connection; no
release time is promised for every backend state or topology, and the documentation SHALL state this.

#### Scenario: Many sources
- **WHEN** a worker running 64 stream consumers is stopped, each with an insert in flight
- **THEN** stop returns within 10 seconds

#### Scenario: Stop while reading
- **WHEN** the worker is stopped while the consumer waits for the next line
- **THEN** the socket is closed, stop returns within 10 seconds, and the lease is released if the final write commits within its 1-second timeout, or else left to expire

#### Scenario: Lease row still locked at stop
- **WHEN** the worker is stopped while a closing admission's backend still holds the lease row lock on a reachable database
- **THEN** the final write times out after 1 second, stop returns within 10 seconds, the lease expires by itself, and the status records the stop or expiry, never a release that did not commit

#### Scenario: Two workers, 64 sources
- **WHEN** two workers run with 64 enabled stream sources
- **THEN** at most 64 client-owned dedicated consumer sessions exist across both, one per lease holder, and a worker holding no lease has none

#### Scenario: Session settings of the dedicated connection
- **WHEN** a consumer opens its database connection, over the embedded database's Unix socket and over TCP
- **THEN** the session reports a 1-second client connection check and a 5-second idle-in-transaction timeout, and over TCP its keepalive and TCP user timeout settings

#### Scenario: Database unreachable at stop
- **WHEN** the worker is stopped while the database is unreachable
- **THEN** stop returns within 10 seconds and the lease expires by itself

### Requirement: Supported Icinga 2 releases for Event Streams

Event Streams support SHALL be claimed only for releases whose subscription, every consumed event type and both
sync responses are captured from the official Icinga 2 image by the committed capture tool, decode in the
version-matrix test, and pass a run of the real consumer against that image. The change SHALL NOT ship unless
at least one release qualifies.

#### Scenario: Version matrix
- **WHEN** the matrix test runs over the committed captures of every release listed as supported
- **THEN** every captured line and sync object decodes, each capture's expected events match, and every captured time's key text matches its vector

#### Scenario: Listed release that fails
- **WHEN** a release is listed as supported and its capture no longer decodes
- **THEN** the matrix test fails

#### Scenario: Release whose capture fails
- **WHEN** a release's capture does not produce a decodable `StateChange` with `vars_after`
- **THEN** that release is not listed as supported

#### Scenario: Real consumer against a release
- **WHEN** the capture tool runs the consumer against a supported release's image with the documented `ApiUser` permissions
- **THEN** the consumer subscribes, its first sync completes, its status is `connected`, and a forced recovery resolves its alert

#### Scenario: Missing permission in the documented list
- **WHEN** the documented permission list minus one entry is applied to the capture rig's `ApiUser`
- **THEN** the consumer's subscription or sync fails with `forbidden`

### Requirement: Event Streams setup documentation

The documentation SHALL state the `ApiUser` permissions, the CA setup, that one Icinga 2 instance feeds one
stream source, that every process of every role is upgraded before a stream source is published, that no
process of an older release may run against the database once a stream source is published, and that the status
method is limited to local development and test.

#### Scenario: Setup items present
- **WHEN** a test reads the setup section
- **THEN** it finds the permission list used by the capture rig, the CA setup, the one-instance rule, the all-role upgrade order, the no-older-release rollback boundary and the status access note

### Requirement: Event Streams limits documentation

The documentation SHALL state every limit in this capability, the clock and lateness limits of ordering, that a
gap can lose acknowledgement, downtime and flapping events and intermediate states while sync repairs only
current state, and that an object removed from Icinga 2 keeps its alert.

#### Scenario: Limits match the code
- **WHEN** a test reads the limits table of the setup section
- **THEN** each limit equals the constant the code uses, each limit's behaviour is exercised by a scenario of this capability, and the gap, removed-object and kept-row growth notes are present
