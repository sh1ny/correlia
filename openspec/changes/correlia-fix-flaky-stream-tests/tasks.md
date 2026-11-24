# Tasks

## Test map

No delta scenarios; strengthen the existing Icinga 2 Event Streams regression tests.

## 1. Make stream regression tests event-driven

- [x] 1.1 Replace the live resync waits and gate each flap before changing spacing. Verify both DB `connection_flapping` cases and remaining tests in `icinga2_stream_resync_test.dart` with C1–C2 in place.
- [x] 1.2 Order the two-worker shutdown after all fixture writes and expanded scans; enforce exact lease/session ownership and C3. Verify `two_workers_64_sources` and the other tests in `icinga2_stream_stop_test.dart`, including the stalled and running statement cases without per-step deadlines.

## Workflow follow-up

- Run Linux verification at least three times on the same PR head with no test retries; report each independent run ID and outcome.
- Leave the reviewed, green PR unmerged for the owner.
