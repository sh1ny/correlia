# Canonical event v1

`correlia_server/lib/event.dart` is the public entry point. Payload protobuf and standard validation
annotations in `proto/correlia/event/v1/event.proto` are authoritative; generated Dart bounds and the
strict bundled payload schema come from `mise run proto`. [ADR 0021](../docs/adr/0021-canonical-event-v1-contract.md)
records the frozen identity and validation decisions. [Identity bytes and vectors](identity.md) and the
[CloudEvents profile](cloudevents.md) describe their respective boundaries.

## Typed values

- `CanonicalEvent.create` accepts typed source scope, enums, identity components, observation evidence,
  timestamps, raw reference and processing provenance. It computes the fingerprint and observation id;
  a source dedup hint cannot override either. Constituent metadata and collection bounds are checked
  before copying. All accepted values and their nested collections are immutable.
- `EventObserver`, `EventRawReference`, `EventPipeline`, `EventLink` and `EventEnrichmentError` validate
  their own bounded metadata. Positive reprocess generations require an original UUIDv5; generation
  zero omits lineage. Generation allocation and state effects are outside this library.
- `EventTimestamp` stores UTC seconds/nanoseconds. Original reported source text is separate and must
  represent the same instant as `source_time`. Offsets and fractional spelling survive unchanged as
  evidence. No arrival fallback, skew clamp or end-before-start rejection is applied here: a firing
  Alertmanager observation may carry its zero-time end sentinel.
- `normalizeDisplayText` counts Unicode scalars, includes the final ellipsis in the requested cap and
  optionally folds CR and LF to spaces. Wire readers reject overflow instead of truncating it.
- Factories reject with a sealed `EventValidationError` (`EventFieldError`) carrying a field path and
  stable code. They do not return a partially usable event.

## Wire behavior

`CanonicalEvent.fromJson` reads a payload object, not a whole CloudEvent. Its default dataschema is
`urn:correlia:schema:event:1.0`; a newer v1 minor selects `ValidationScope.knownCoreOnly`. Current-minor
JSON rejects undeclared keys. Both paths reject known-field aliases, numeric/unknown enum values,
explicit known-field nulls, invalid dates/offsets, malformed Unicode and over-bound values before the
protobuf runtime can silently normalize them. Newer unknown fields are ignored at every nesting level.

`toJson` emits standard protobuf enum-name strings, explicit snake_case names, numeric uint32 raw size
and generation, base64 bytes and UTC timestamps with up to nine fractional digits. Optional scalar
presence is preserved, including present empty strings and an empty raw identity component. Collections
may be empty; required textual metadata may not. Raw size and generation use protobuf's zero default.

`CanonicalEvent.fromBuffer` accepts optional `sourceDataschema`. Missing metadata produces
`ValidationScope.unknown`, not an inferred minor. Current metadata produces `exact`, future v1 metadata
produces `knownCoreOnly`, and malformed or other-major metadata fails at `source_dataschema`. Scope is
not a claim that binary input passed JSON Schema. Known fields are always validated, including timestamp
seconds/nanos and unknown enum numbers retained by protobuf as native unknown fields.
Binary int32/uint32 values are decoded at full wire width and range-checked before narrowing, so
overflow cannot turn a malformed raw size, generation, enum, or timestamp nanos into a valid value.
The reader checks original varint bytes before Int64 conversion as well: a tenth byte may carry only
bit zero. This prevents values wider than 64 bits from wrapping before the 32-bit range checks.
The adapter tracks consumption across all wire types while the standard runtime still decodes
messages and retains unknown fields.

The wrapper owns a frozen generated message; no mutable generated API escapes. `toBuffer` preserves
native unknown field numbers/wire values for a newer parser, without promising byte-for-byte field
ordering. JSON output is only a current-v1.0 known-field projection: unknown future JSON fields and
binary-only fields are not transparently forwarded. Namespaced payload extensions stay in
`data.extensions`, not at the envelope top level.

## Bounds

Lengths below mean Unicode scalars unless bytes are explicit. The generated constants, not a second
handwritten runtime table, enforce these fields. Optional strings and map values may be empty.

| Family | Maximum |
|---|---|
| summary / description / link text | 256 / 4096 / 256 scalars |
| tenant / namespace / source kind | literal `default` / 256 / 64 scalars |
| severity original / dedup hint / observer name or version | 128 / 1024 / 256 scalars |
| resource, labels, label origins, annotations | 128 entries each; keys 128, values 1024 scalars |
| identity fields | 1..128 entries; names 128 scalars; raw inline components 1024 UTF-8 bytes |
| links | 16; HTTP(S) href 2048, relation 64 scalars |
| raw reference / pipeline version | 256 / 128 scalars |
| applied stages / enrichment errors | 32 each; stage/code 64, error message 256 scalars |
| namespaced extensions | 32; keys 128, values 1024 scalars |
| original timestamp strings | 64 ASCII characters |
| observation key | 8192 decoded bytes; valid canonical domain/shape required |
| raw size / generation | uint32: 0..4294967295 |
| protobuf input / structured UTF-8 JSON | 262144 bytes each |
| JSON nesting | 16 containers |

Identity helpers additionally bound original input work to 1 MiB before canonical encoding/hashing;
long components are tagged hashes, never truncated. Label-origin keys must name existing labels.
Fingerprints and event ids are recomputed from the declared evidence before acceptance. Strings use
whole-value patterns common to RE2, ECMA-262 and Dart; malformed Unicode is never replacement-normalized.

`raw.size` counts a referenced body, not bytes embedded in this event. A source may accept a raw body
larger than the unchanged 1 MiB default ingress limit, provided its configured limit fits uint32. The
actual ingress limit remains independently enforced by the later ingress implementation.

## Complete acceptance versus JSON Schema

Pinned Ajv2020 validates the payload schema at build time, not in the Dart runtime. JSON Schema alone
does not prove exact decoded/UTF-8 byte lengths, identity agreement, source-time agreement, whole-input
depth or aggregate structured size. Passing that schema does not yet mean an event is accepted.

Factories check the full boundary, including the derived default CloudEvent's UTF-8 size, before
returning a usable value. Adding trace context creates another checked envelope boundary; an overflow
fails during envelope construction, not during some later publishing step. The default envelope bytes
are immutable and shared with the codec, so acceptance and encoding use one projection.

The 256 KiB cap is not a universal forwarding promise. Events above CloudEvents' 64 KiB guarantee need
explicit support from the selected transport and intermediary chain.

## Executable fixtures

[Runtime fixtures](runtime-fixtures/README.md) include a full current payload, reprocess lineage,
present empty optional values, exact negative field errors, and synthetic future-minor JSON/protobuf.
The full positive event exercises nanoseconds, original offset spelling, every optional field family,
the firing end sentinel and maximum uint32 raw metadata. Current payload fixtures are checked with both
runtime readers and pinned Ajv. A whole CloudEvent is never submitted to the payload-only schema.

The synthetic v1.1 cases do not publish v1.1. There is one committed v1.0 descriptor baseline; before any
later minor is actually published, its change must extend compatibility coverage to its real contract
and retain existing schemas. See [tooling](../docs/event-contract-tooling.md).
