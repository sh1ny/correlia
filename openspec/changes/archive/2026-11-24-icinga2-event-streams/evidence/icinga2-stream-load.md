# Icinga2 Event Streams load evidence

Command: `mise run test -- --tags load`. Both cases passed on Linux x86_64 with six logical CPUs, Dart 3.13.7, Serverpod 4.1.0 and embedded PostgreSQL. Run time: 632.29 s including setup and cleanup.

## Maximum-description fanout

The production reader admitted 100 valid observations with 4,096 four-byte scalars per description while the source routed to one output. A revision enabling eight outputs was published before the pipeline first claimed those rows. All rows committed with no pipeline failures.

| Measurement | Observed |
|---|---:|
| Raw rows | 7 |
| Canonical events | 100 |
| Committed outbox deliveries | 800 |
| Largest row's nine-copy fanout | 2,454,975 bytes (budget 8 MiB) |
| Slowest claimed row | 384,886 µs (deadline 10 s) |

## Saturated input for 10 minutes

One production child worker consumed an unpaced loopback TLS producer. The regular pipeline committed events to an isolated PostgreSQL test database. There were no output routes. The producer continuously offered new batches under socket backpressure; the rate counts durable event commits, not received or queued lines.

| Measurement | Observed |
|---|---:|
| Lines offered by the end sample | 214,300 |
| Durable events at midpoint | 97,700 |
| Durable events at end | 198,400 |
| Final measurement interval | 300.013501 s |
| Durable drain rate | 335.651561 events/s |
| Connection gaps | 0 |

The final sample landed during a retained-work pause on the original connection. No pipeline failures were recorded. `docs/ingest-pipeline.md` reports the measured rate rounded to 335.65 events/s; this run is not a production capacity guarantee.
