## Unreleased

- Add deterministic v1 alert fingerprints, observation UUIDv5 and source-scoped transport keys.
  Preserve original nanosecond timestamp evidence, bound identity work, and publish independent
  vectors in `contracts/identity-vectors.json`. These pure helpers apply no durable dedup/state effects.
- Add immutable canonical payload values and strict protobuf/JSON codecs through `package:correlia_server/event.dart`.
  Validate CloudEvents agreement, nanosecond timestamps, identity evidence, aggregate size, and Unicode
  before acceptance. Preserve native unknown protobuf fields while reporting exact, known-core-only,
  or unknown validation scope; JSON output is the current-minor known-field projection.
- Publish complete positive, negative, and synthetic newer-minor wire fixtures with payload-only
  JSON Schema cross-checks in `contracts/runtime-fixtures/` and `contracts/envelope-fixtures/`.
- Reject overflowing binary int32/uint32 wire values before protobuf narrowing can turn them into
  valid raw metadata, generations, enums, or timestamp nanos.
- Count only non-null CloudEvents extension attributes against the 32-attribute allowance.

## 1.0.0

- Initial version, created by Stagehand
