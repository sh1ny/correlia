# 0011. The NATS output is the first external plugin, written in Go

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: none

## Context

The owner wants canonical events published to NATS. The Dart client `dart_nats` 1.7.0 is maintained, but
it marks JetStream as experimental. `nats.go` is the reference JetStream client. The plugin system
(ADR 0006) needs a real external plugin to prove it.

## Decision

The NATS/JetStream output is an external Go plugin (`plugins/output-nats`), built on stock go-plugin and
nats.go.

- **Subjects:** low-cardinality tokens only, with the version right after the prefix:
  - events: `correlia.v1.ev.<tenant>.<kind>.<source_kind>.<severity>`;
  - incidents: `correlia.v1.incident.<tenant>.<status>`.
- **Body:** structured-mode CloudEvents JSON.
- **Headers:** `Nats-Msg-Id` set to the event id, plus `ce-*` and `traceparent`.

Rejected: a built-in Dart NATS output, because JetStream is experimental in `dart_nats`. Reversal cost: low,
since a built-in output can be added behind the same interface later.

## Consequences

- The build needs a Go toolchain, managed by mise.
- The NATS output doubles as the reference implementation for third-party plugin authors.
