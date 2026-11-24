# Tasks

## Test map

No spec delta. The existing suites remain the product acceptance checks; the list below maps their timing evidence to each implementation group.

## 1. Real-child outcomes

- [ ] 1.1 Replace the consumer E2E aggregate poll with exact committed raw and event witnesses; journal status before activation and verify header/cutoff outcomes without child fault IPC.
- [ ] 1.2 Convert readiness, shutdown and redaction waits in the shared child harness, `shutdown_e2e_test.dart` and `icinga2_stream_secrets_e2e_test.dart` to events; verify all three E2E suites.

## 2. PostgreSQL ordering

- [ ] 2.1 Verify A1 using the embedded lock log and exact backend identities, including a pooled contender; distinguish log generation and fixture DB before relying on the witness.
- [ ] 2.2 Replace waits in admission (including concurrent cutoff), tombstone, lease expiry, sync progress, publisher version and secret reuse backfill DB suites; verify their real concurrency assertions.

## 3. Controlled deadlines and real peers

- [ ] 3.1 Convert live backpressure, live lease and shutdown-order DB suites to committed/socket events and fixture clocks; verify the same-batch second lock failure and relative outage deadline.
- [ ] 3.2 Convert `icinga2_stream_tls_e2e_test.dart` stalls to staged timer firing and observed EOF without step caps; verify all TLS cases.
- [ ] 3.3 Convert the supplementary plugin health busy-spin to matching Go RPC arrival and controlled watchdog/connection-loss precedence. Verify the plugin protocol suite; leave the unrelated plugin diagnostic case untouched.

## Workflow follow-up

Use Specwright ship and read-only PR watch plus normal feedback handling; stop before automatic archive-and-merge. Do not execute any merge or enable auto-merge. At the unchanged reviewed head require green required checks and report three to five independent first-attempt CI runs covering DB, E2E and plugin tiers without retries, including any failures. If the head changes, obtain new evidence. Leave merge to the owner.