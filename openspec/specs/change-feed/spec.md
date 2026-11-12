# change-feed Specification

## Purpose

Record every visible state change in an append-only activity ledger, and let clients follow it through a cursor feed that never skips a committed change, whatever order concurrent transactions commit in.

## Requirements

### Requirement: Append-only activity ledger

Every visible alert state change SHALL write one activity entry, in the transaction that makes the change. A visible change is creation, a status change, a severity change or a display-field change. An entry SHALL hold:
- a feed position of (transaction id, sequence id);
- the change time;
- the entity kind, entity id and entity version after the change;
- the change kind;
- the actor (the pipeline, with the raw delivery and event that caused it).

Entries SHALL never be updated or deleted.

#### Scenario: Firing then resolved writes two entries
- **WHEN** an alert is created firing and later resolved by a newer observation
- **THEN** two activity entries exist for it, with versions 1 and 2, kinds created and resolved, and each names its causing event id

#### Scenario: Rolled-back change leaves no entry
- **WHEN** a raw row's transaction applies a state change and then rolls back
- **THEN** no activity entry from that transaction exists, and the retry that commits writes exactly one entry per visible change

### Requirement: Feed reads only below the watermark

A feed read SHALL return entries after the client's cursor, in (transaction id, sequence id) order. It SHALL include only entries whose transaction id is below the watermark: the oldest transaction still running when the read starts. A page SHALL hold at most the page limit and report whether more entries follow, and SHALL report `held_back` when entries exist at or above the watermark.

#### Scenario: UI-3a a late-committing transaction is never skipped
- **WHEN** transaction A writes an activity entry, transaction B starts after A, writes an entry and commits, a reader pulls the feed, and then A commits
- **THEN** the first pull returns neither entry (A holds the watermark), and after A commits the reader's pulls from its cursor return A's entry and B's entry each exactly once

#### Scenario: Page limit
- **WHEN** more entries are readable than the page limit
- **THEN** the page holds exactly the limit, reports more entries, and its next cursor continues without gaps or repeats

### Requirement: Opaque feed cursors

Cursors SHALL be opaque strings. A cursor whose transaction id is at or below the current watermark, including a snapshot cursor, SHALL be accepted. A cursor that does not parse, or whose transaction id is above the current watermark, SHALL be rejected with an invalid-cursor error.

#### Scenario: Malformed cursor
- **WHEN** a client sends a cursor that does not parse, or whose transaction id is above the current watermark
- **THEN** the read fails with an invalid-cursor error and returns no entries

#### Scenario: Snapshot cursor on an empty ledger
- **WHEN** a client takes a snapshot while no activity exists, unrelated transactions that write no activity then commit, and the client reads the feed from the snapshot cursor
- **THEN** the read returns an empty page with no error and a cursor that later reads accept

### Requirement: Snapshot and feed handover

A snapshot read SHALL return the current alerts and a cursor at the watermark, both taken in one repeatable-read transaction. Feed reads from that cursor SHALL return every change committed after the snapshot; a change already in the snapshot can be returned again. Each returned alert SHALL carry its version, so that a client applying by version is unaffected by repeats.

#### Scenario: Change committed during the snapshot
- **WHEN** a transaction that changes an alert is running while a client takes a snapshot, and commits afterwards
- **THEN** the client's feed reads from the snapshot cursor return that change

#### Scenario: Repeated change in snapshot and feed
- **WHEN** an unrelated transaction holds the watermark, alert X's creation commits and is in a snapshot at version 1, X then resolves at version 2, and the blocker ends
- **THEN** the first feed read from the snapshot cursor returns X's creation entry again together with X's current row at version 2 (resolved), every returned alert version is equal to or newer than the snapshot's, and a client applying by version ends with X resolved

### Requirement: Wake-up stream liveness

The api role SHALL offer a stream that carries only wake-ups, never entries. Each api instance SHALL check the watermark at least every 500 ms. It SHALL push a wake-up to its connected streams when the watermark passes entries the stream's clients may not have read. This includes a watermark released by a transaction that wrote no activity. A client SHALL be able to reconnect and resume from its cursor.

#### Scenario: UI-3b blocker without activity
- **WHEN** a transaction that writes no activity holds the watermark while transaction B commits an activity entry, and the blocker then ends
- **THEN** a connected client receives a wake-up within one watermark poll after the blocker ends, and its next feed read returns B's entry, without any further activity write

#### Scenario: Stream dropped and resumed
- **WHEN** a client's stream disconnects, two changes commit, and the client reconnects and pulls from its last cursor
- **THEN** it receives both changes exactly once from the feed
