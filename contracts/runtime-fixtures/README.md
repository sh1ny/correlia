# Canonical payload wire fixtures

These exercise the public `package:correlia_server/event.dart` boundary. JSON files contain the payload
alone, not a CloudEvent. [Envelope fixtures](../envelope-fixtures/README.md) exercise envelope agreement;
[the contract](../event.md) documents the payload API and constraints.

## Accepted inputs

- `positive/complete.json` covers every payload field family, original offset timestamp evidence,
  nanosecond timestamps, identity evidence, raw reference, metadata, and pipeline context.
  `positive/complete.binpb` is its protobuf encoding.
- `positive/empty-optional-values.json` preserves explicitly present empty strings, an empty raw identity
  oneof, empty map values, and a zero raw size. Empty identity evidence is not an absent oneof.
- `positive/reprocessed.json` uses a positive pipeline generation and the required original event id.
  Its observation id differs from generation zero without changing the alert fingerprint.

The three current-minor JSON payloads pass the pinned strict JSON Schema validator as well as runtime
validation. Runtime validation additionally proves identities, timestamp agreement, decoded byte bounds,
and envelope-inclusive aggregate size; schema acceptance alone is insufficient.

## Synthetic newer minor

`newer/optional-additions.json` adds undeclared JSON fields at multiple nesting levels.
`newer/optional-addition.binpb` appends string field 100, `new`, to the complete binary message.
They are compatibility probes, not a publication of schema v1.1.

Read them with `sourceDataschema: 'urn:correlia:schema:event:1.1'`: known fields remain validated and
`validationScope` is `knownCoreOnly`. The JSON output drops unknown fields and publishes the current-minor
projection. Native protobuf unknown fields survive `toBuffer()`; an independent field-100 reader recovers
`new` after the round trip. Binary input without schema metadata reports `unknown`, even when no optional
addition appears. Explicit newer-minor metadata reports `knownCoreOnly` even when the addition is absent.

## Rejected inputs

Each JSON case is otherwise complete and fails at the indicated field path.

| JSON file under `negative/` | Error path |
|---|---|
| `missing-summary.json` | `summary` |
| `unknown-severity.json` | `severity` |
| `summary-overflow.json` | `summary` |
| `raw-size-overflow.json` | `raw.size` |
| `reported-time-mismatch.json` | `reported_source_time` |
| `known-alias.json` | `eventId` |
| `invalid-observation-bytes.json` | `observation_key` |
| `unknown-label-origin.json` | `labels_origin.missing` |
| `conflicting-component.json` | `identity_fields.alertname` |

The negative binary fixtures append a malformed known field to the complete valid message:

| Binary file under `negative/` | Violation | Error path |
|---|---|---|
| `unknown-status.binpb` | closed enum number 99 | `status` |
| `invalid-nanos.binpb` | timestamp nanoseconds 1000000000 | `observed_at` |
| `invalid-utf8.binpb` | invalid UTF-8 byte in summary | `event` |

The binary reader uses the standard protobuf decoder with strict string decoding, so malformed UTF-8 is
rejected rather than replaced. Enum and timestamp validation happens before protobuf JSON projection can
hide invalid known values. Parse-level failures name the `event` boundary; semantic failures name the
known field. Unit tests also cover truncation, alias rejection, container depth, aggregate byte limits,
Unicode scalar limits, immutable aliases, schema scope, and cross-representation identity agreement.
Binary overflow regressions also cover raw size, pipeline generation, every closed enum, and timestamp
nanos: full-width decoding rejects values that would otherwise truncate into the valid 32-bit domain.

These are pure contract fixtures. They prove no ingestion, storage, durable deduplication, correlation,
or transport effects.
