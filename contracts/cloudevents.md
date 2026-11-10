# Canonical CloudEvents envelope v1

The executable boundary lives in `correlia_server/lib/src/event/cloud_event.dart`; the public event entry
point exports it. [ADR 0021](../docs/adr/0021-canonical-event-v1-contract.md) freezes its semantics. The
envelope is a small handwritten codec around a validated canonical payload. There is no envelope protobuf
message, no generated envelope schema and no envelope type registry.

## Envelope

Structured CloudEvents JSON 1.0.2 only. The media type is `application/cloudevents+json` and the payload
inside `data` uses the `application/json` content type. Every standard attribute is derived from the
validated payload; the codec never invents an attribute the payload does not support.

| Attribute | Value |
|---|---|
| `specversion` | `1.0` |
| `id` | the payload's observation id |
| `source` | `urn:correlia:source:<lowercase source instance UUID>` |
| `type` | `io.correlia.<lowercase kind>.v1` |
| `datacontenttype` | `application/json` |
| `dataschema` | `urn:correlia:schema:event:1.0` |
| `subject` | the payload's fingerprint |
| `partitionkey` | the payload's fingerprint |
| `correliatenant` | the payload's tenant |
| `time` | the normalized UTC source time, omitted without a source time |
| `traceparent` | the optional validated W3C trace context |
| `data` | the payload's current-v1.0 known-field JSON projection |

The emitted `dataschema` is always the current schema. A payload read from a newer v1 minor is published as
a current-v1.0 projection, never as its original wire form. The encoded document always carries
`subject`, `partitionkey` and `correliatenant`; a decoded envelope may omit them.

## Reading an envelope

`specversion`, `id`, `source`, `type`, `datacontenttype`, `dataschema` and `data` are required. `subject`,
`partitionkey`, `correliatenant`, `time` and `traceparent` are optional on input; when present they must
agree with the payload. `data` must be a JSON object. `data_base64` is refused: a canonical event is always
carried as JSON.

The reader checks, before the payload becomes usable:

- `specversion` is exactly `1.0` and `datacontenttype` is exactly `application/json`.
- `dataschema` names a supported Correlia event schema; a malformed value or another major version fails.
- `id` equals the payload's observation id, `source` equals the payload's source instance URI and `type`
  equals the payload's kind.
- `subject` and `partitionkey` equal the payload's fingerprint, `correliatenant` equals the payload's tenant.
- `time` is an RFC3339 instant with an explicit offset and denotes the payload's normalized source time. A
  `time` without a payload source time fails.
- `traceparent` is version `00` with lowercase hexadecimal, a nonzero 32-digit trace id, a nonzero 16-digit
  span id and two hexadecimal flag digits.

An absent optional attribute is not a disagreement; a present but contradicting one is.

Every rejection is an `EventFieldError` with the offending attribute's path and a stable code.

| Code | Meaning |
|---|---|
| `event_too_large` | the encoded document exceeds 262144 bytes |
| `too_deep` | the document nests deeper than 16 containers |
| `invalid_utf8`, `invalid_json`, `invalid_envelope` | the bytes are not a UTF-8 JSON object |
| `required`, `invalid_type` | a known attribute is missing or has the wrong JSON type |
| `unsupported_specversion`, `unsupported_content_type` | the CloudEvents version or the data content type is not supported |
| `unsupported_major`, `invalid_format` | the `dataschema` names another major version or is malformed |
| `unsupported_attribute` | the attribute is a CloudEvents member this codec refuses, such as `data_base64` |
| `identity_mismatch` | the envelope contradicts the payload it carries |
| `invalid_format`, `invalid_trace_id` | the trace context is malformed or carries a zero identifier |
| `invalid_count` | more than 32 unknown attributes |
| `too_long`, `invalid_character`, `invalid_unicode` | an unknown attribute's name or value breaks its bound |
| `invalid_number`, `out_of_range` | an unknown attribute's number is fractional or outside the signed 32-bit range |

Payload rejections keep the payload's own paths and codes, for example `producer_note` for an undeclared
field in an exact-minor document.

## Unknown attributes

An unknown top-level attribute is a CloudEvents extension attribute. Its name must match `[a-z0-9]+` and
carry at most 128 ASCII characters. Its value must be a string, a boolean or a signed 32-bit integer; a
string carries at most 1024 Unicode scalars, valid Unicode only, without control characters or
noncharacters. An explicit `null` means omitted. Objects, arrays, fractional numbers, out-of-range numbers
and malformed strings fail.

Valid unknown attributes are then ignored. They never reach the payload, never change the payload's
validation scope and are never re-emitted, so a broker's extension is tolerated without a lossless
forwarding promise. Payload namespaced keys such as `example.org/context` live exclusively in
`data.extensions`; their punctuation is invalid in an envelope attribute name.

## Bounds

| Family | Bound | At overflow |
|---|---|---|
| serialized structured envelope | 262144 UTF-8 bytes | Reject before parsing input or accepting a constructed event, `event_too_large` |
| JSON nesting | 16 containers | Reject before conversion, `too_deep` |
| unknown envelope attributes | 32 | Reject, `invalid_count` |
| unknown attribute name | 128 ASCII characters | Reject, `too_long` |
| unknown attribute string value | 1024 Unicode scalars | Reject, `too_long` |

The size and depth bounds apply to the whole document, including attributes the payload ignores, so a
known-core-only payload cannot smuggle unbounded structure past the boundary. The payload's own field
bounds, identity agreement and JSON Schema constraints are separate; see
[ADR 0021](../docs/adr/0021-canonical-event-v1-contract.md).

The 256 KiB contract cap is not a promise that a generic CloudEvents intermediary forwards an event above
the specification's 64 KiB forwarding guarantee. Transport-specific size support is required above that
size.

Boundary validation is stricter than the payload JSON Schema. The schema describes the shape of `data`
alone, while the runtime boundary also enforces decoded byte lengths, identity agreement, envelope
agreement and aggregate size. A document that satisfies the payload schema can still be rejected at the
boundary; an accepted event never fails later merely because a downstream component applies a different
field-length limit.

Payload construction includes the default structured-envelope overhead in its size check. Constructing a
`CloudEvent` checks the complete representation again when trace context adds bytes. The accepted default
representation is cached once and shared as immutable bytes; callers cannot mutate it through
`toJsonBytes()`.

## Payload scope

The envelope's `dataschema` selects the payload's validation scope: the exact current minor validates every
known field and rejects undeclared ones, a newer v1 minor validates the known core and ignores unknown
fields at every nesting level, and an unsupported major fails. The scope belongs to the payload, not to the
envelope; the envelope only carries the schema that selected it. The envelope's JSON output is always the
current-v1.0 known-field projection, so an ignored unknown field is dropped from the published document.

## Complete positive fixture

The complete reviewed alert envelope is
[cloud_event.valid.json](envelope-fixtures/cloud_event.valid.json). Its fingerprint and observation id are
the independently recomputed values published in [identity.md](identity.md). The synthetic newer-minor
document is [cloud_event.newer_minor.json](envelope-fixtures/cloud_event.newer_minor.json). The rejected
documents and every other rejected condition are listed in the
[fixture readme](envelope-fixtures/README.md).

## Scope of proof

The envelope codec is a pure codec over bytes and an already validated payload. It proves attribute
derivation, envelope-to-payload agreement, the unknown-attribute profile and the size and depth bounds. It
does not prove ingestion, transport, storage, deduplication or state effects; those belong to subsequent
changes.

Two limitations are deliberate. A whole CloudEvent is never validated against the payload-only JSON Schema,
because the schema describes `data` alone. Unknown envelope attributes are validated and dropped, so the
codec promises interoperability with a broker's extensions but not lossless forwarding of them.
