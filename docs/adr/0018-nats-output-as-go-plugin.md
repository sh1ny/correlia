# 0018. The NATS output is the first external plugin, written in Go

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: [0011](0011-nats-output-as-go-plugin.md)

## Context

This ADR restates ADR 0011 with two additions from the 2026-11-03 design review: the plugin exits when its
stdin closes (the spike gate of ADR 0020 needs it), and consumers get no delivery order per alert.
Everything else is unchanged from ADR 0011.

The owner wants canonical events published to NATS. The Dart client `dart_nats` 1.7.0 is maintained, but
it marks JetStream as experimental. `nats.go` is the reference JetStream client. The plugin system
(ADR 0020) needs a real external plugin to prove it.

## Decision

The NATS/JetStream output is an external Go plugin (`plugins/output-nats`), built on stock go-plugin and
nats.go.

- **Subjects:** low-cardinality tokens only, with the version right after the prefix:
  - events: `correlia.v1.ev.<tenant>.<kind>.<source_kind>.<severity>`;
  - incidents: `correlia.v1.incident.<tenant>.<status>`.
- **Body:** structured-mode CloudEvents JSON.
- **Headers:** `Nats-Msg-Id` set to the event id, plus `ce-*` and `traceparent`.
- **Exit on stdin close:** the plugin wraps stock `plugin.Serve()` with a stdin watcher of a few lines that
  exits when the host's stdin pipe closes, so a host killed with kill -9 leaves no plugin behind (ADR 0020,
  criterion 4). This is not the plugin SDK of M8; stock go-plugin plugins do not watch stdin.
- **No delivery order per alert:** several relay instances claim outbox rows with `SKIP LOCKED` (ADR 0016),
  so two events of one fingerprint can be published in either order, and a redelivery can follow a newer
  event. Consumers order events by source time (the CloudEvents `time` attribute, the occurrence time),
  then `observed_at`, then event id, and dedupe by event id. This matches the ordering fence of ADR 0017
  except for an event whose source time was clamped to observed time + skew, since the event does not carry
  the clamped value.

Rejected: a built-in Dart NATS output, because JetStream is experimental in `dart_nats`. Reversal cost: low,
since a built-in output can be added behind the same interface later.

## Consequences

- The build needs a Go toolchain, managed by mise.
- The NATS output doubles as the reference implementation for third-party plugin authors.
