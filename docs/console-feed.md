# Console change feed

The console read API is a development-only, unauthenticated interface. It is **not
for production use**; authentication and production exposure belong to M4. In
`development` or `test` mode, only the `api` and `all` roles accept requests.
Every snapshot, feed and wake-up request must come from a loopback TCP peer,
including IPv4-mapped IPv6 loopback peers; forwarded-address headers are never trusted. The Host must name `localhost`,
`127.0.0.1` or `[::1]`. If present, Origin must be an HTTP origin with one of
those hosts. These checks also apply to WebSocket streams. Worker processes and
all other modes refuse console access; webhook ingress is unaffected.

`snapshot()` returns up to 500 firing alerts, ordered by severity and newest
firing time, with an `omittedCount` and an opaque cursor. Snapshot rows and the
cursor come from the same repeatable-read database snapshot. `feed(cursor,
limit)` returns activity summaries in transaction-ID and sequence-ID order,
alongside current views of the affected alerts. The server clamps the page limit
to 1–1000; follow `nextCursor` while `more` is true. Apply alert views by version:
the current view can be newer than its activity entry, and an entry already
reflected in the snapshot can appear again.

A cursor encodes its transaction and sequence IDs as decimal text. Do not parse
or manufacture cursors: retain the returned string and send it back unchanged.
Invalid cursors are rejected; obtain a fresh snapshot. Activity is retained
indefinitely in M1, so there is no cursor-expiry response.

The watermark is the oldest transaction active when the read's database snapshot
begins. Only activity strictly below it is returned, so a transaction committing
late cannot be skipped. `heldBack` indicates that committed activity exists at
or above the watermark. A long-held watermark is logged after 30 seconds.

`wakeUps()` is a notification stream, not a source of entries. While clients
are subscribed, each API instance polls the watermark at least every 500 ms and
coalesces wake-ups; a transaction that wrote no activity can release held-back
entries. Pull the feed on a wake-up and periodically even while the stream is
connected. After a dropped stream, reconnect and resume from the last cursor.

Streams opened while the API is still starting are retained: starting the
watermark subsystem schedules polling for those existing subscribers too.
