# 0021. Canonical event v1 bytes, validation and compatibility

- Status: accepted (2026-11-10)
- Date: 2026-11-10
- Supersedes: none; adds precision to [0004](0004-canonical-event-format.md) and [0019](0019-identities.md)
- Chosen by: agent; the owner authorized replacing the draft's missing UUID namespace before publication.

## Context

The first event contract needs reproducible identities and executable bounds before ingest and output
consumers exist. ADRs 0004 and 0019 establish semantics but do not specify identity bytes or the fixed
UUID namespace. This change supplies those details without implementing storage, dedup windows, state
transitions, ingest, plugins or output delivery.

## Decision

### Exact identity bytes

Use the fixed observation UUIDv5 namespace `f36aac0f-16fa-46db-951b-bb578b323aed`, whose 16 network-order
bytes are `f36aac0f16fa46db951bbb578b323aed`. This constant is distinct from an operator's alert namespace.
Freeze these identity semantics within v1.

`E(pairs)` starts with an unsigned 32-bit big-endian pair count. Each ordered pair then contains the
unsigned 32-bit big-endian UTF-8 name byte length, name bytes, unsigned 32-bit big-endian value byte
length, and opaque value bytes. Nested tuples contain their complete E bytes. Duplicate names and
malformed Unicode fail. Map names sort by unsigned UTF-8 byte lexical order; no normalization or case
folding applies. All domain and scalar text below is UTF-8.

An identity component is `00 || UTF8(original)` up to 1024 original UTF-8 bytes, otherwise
`01 || SHA256(UTF8(original))`. Names are never hashed or truncated. Reject more than 1 MiB of original
identity inputs before encoding/hashing; accept 1..128 fields with names at most 128 Unicode scalars.

| Result | Ordered E pairs |
|---|---|
| Fingerprint | domain=correlia.alert.v1, tenant, namespace, source_kind, identity_fields=E(sorted tagged components) |
| Native observation key | domain=correlia.native.v1, key=tagged component |
| Alertmanager observation key | domain=correlia.alertmanager.v1, status, starts_at, ends_at |
| Fallback observation key | domain=correlia.fallback.v1, status, severity, reported_source_time |
| Observation UUID name | domain=correlia.observation.v1, source_instance, fingerprint, observation_key=complete key bytes, generation |
| Header transport preimage | domain=correlia.transport.header.v1, source_instance, key=header text |
| Body transport preimage | domain=correlia.transport.body.v1, source_instance, body_sha256=32 raw digest bytes |

Fingerprint and transport results are lowercase hexadecimal SHA-256. Observation ids are UUIDv5 over
namespace bytes followed by the observation name, using the standard version/variant bits and lowercase
canonical UUID text. Source instance is canonical UUID text, fingerprint is lowercase hex, generation
is minimal unsigned decimal text in the uint32 domain. Positive generation requires original-event
lineage; generation zero omits it.

Alertmanager timestamp presence is byte `00` for absent or `01 || UTF8(original timestamp text)` for
present. At least one timestamp is required. Preserve offsets and fractional spelling independently of
normalized UTC seconds/nanos. Fallback requires original reported source time; arrival/clamped time is
never identity evidence. Alertmanager labels include severity unless explicitly excluded. Validate the
full bounded labels and exclusion list before selection; reject duplicates and an empty selection.
Namespaces default to source instance only during source-context construction. Explicit namespace
sharing never removes source instance from observation/transport identity.

Use pinned crypto 3.0.8 and uuid 4.6.0 `v5FromBytes`, not a new hash or UUID implementation. The reviewed
example fingerprint is `09fc69bd0646d8e356c57b6c9b46256eda741ef8924425df1c9cce8ce2137b7f` and its
observation id is `86fe3b73-ec2d-5dd3-b104-11f2ec79469c`. Publish independent vectors with the contract.

### Source of truth and strict wire profile

Payload protobufs under `proto/correlia/event/v1/` use explicit snake_case `json_name` and standard
`buf.validate` annotations. Pin protoc_plugin 25.1.0, protobuf 6.1.0 and protoschema-plugins v0.6.0.
Generate the strict bundled payload JSON Schema and Dart messages/bound constants. Extract only used
standard rules and patch missing map min/maxProperties; reject unsupported annotations. Do not create
private options, a generic schema compiler or a protobuf envelope. Keep validated immutable values in
the server package behind `lib/event.dart`; mutable generated messages stay internal.

The small handwritten CloudEvents 1.0.2 structured-JSON codec derives/checks envelope identity and
version attributes. Payload extensions exist only in data.extensions. Validate then ignore valid
unknown envelope extensions. The payload follows strict ProtoJSON: snake_case keys, enum-name strings,
explicit required presence, numeric uint32 generation/raw.size, UTC timestamp output with nanoseconds,
and base64 bytes. Before protobuf JSON parsing reject aliases, numeric/unknown enums, invalid nulls,
malformed known types and invalid calendar/offset timestamps; do not rely on permissive runtime parsing.

Raw size is referenced-body metadata in 0..4294967295, not embedded bytes or a source acceptance limit.
The default source webhook limit remains 1 MiB. Configured ingress limits must fit uint32 and are still
enforced separately. Display-only normalization may truncate visibly; wire readers reject overflow.

### Full boundary validation, not schema-only acceptance

An event is accepted only after field, required-presence, Unicode-scalar, collection, decoded-byte,
identity-consistency, timestamp, depth and aggregate wire-size checks. JSON Schema alone cannot prove
these cross-field/aggregate constraints. Structured UTF-8 JSON and protobuf input are each capped at
262144 bytes; JSON depth is at most 16. Return the first field-path/code error without a usable event.
Check aggregate structured size before returning a validated value, not only during later publishing.
Accepted values must not fail downstream merely because another component has a different field cap.

Events above CloudEvents' 64 KiB forwarding guarantee need explicit transport-specific size support.
The 256 KiB contract cap does not promise universal intermediary forwarding.

### Parse-only future-minor handling

Exact v1.0 JSON rejects undeclared fields. Newer v1 minor input validates the known core, ignores unknown
JSON fields at any nesting level and reports known_core_only. Current JSON output is a v1.0 projection,
not transparent forwarding. Reject malformed known fields and unsupported majors in every path.

Binary input accepts optional sourceDataschema: missing metadata gives unknown scope, future v1 metadata
gives known_core_only, and malformed/other-major metadata fails. Never infer a minor from absent fields.
Keep a frozen generated backing message so public protobuf output retains unknown field numbers/wire
values for a newer parser; JSON omits them. No private opaque JSON tree or forwarding framework.

### Generation and compatibility gate

Generate in bounded disposable scratch and format generated Dart with the workspace's formatter options,
SDK constraints and resolved language version before writing/comparing. Exclude generated event Dart from
analysis, not handwritten code. Compare generated files in both directions without mutating the checkout;
keep Serverpod generated verification enabled. Bound subprocess time/output and remove owned scratch.

Pin Ajv 8.17.1 and ajv-formats 3.0.1 with an npm lock for build-time draft-2020-12 payload fixture checks.
The check/proto task chains automatically prepare dependencies with locked npm ci, prefer-offline,
ignore-scripts, no-audit and no-fund. Initial caches may need npm, Go proxy/checksum services, BSR and pub;
warm-cache checks need no network. No runtime JSON Schema engine.

Commit one final `contracts/baselines/event-v1.0.binpb`. Buf FILE plus exact existing standard field/oneof
rule, explicit JSON-name/presence and enum-domain comparisons reject removals, incompatible structural
changes, widening or narrowing existing domains, and newly required fields/oneofs. Optional bounded
additions may pass without changing that baseline. Missing baseline fails; never refresh automatically.

Before publishing v1.1, its change must extend compatibility coverage to its actual published contract
and retain existing schemas. The initial baseline does not protect fields introduced only in future
minors. Do not build a speculative per-minor manifest/publication framework now.

## Consequences

- Identity vectors and actual generation/Ajv/Buf boundaries provide portable, consumer-visible evidence.
- Exact rule comparisons intentionally reject harmless rewrites rather than implementing semantic diffs.
- Future-minor JSON parsing discards unknown data deliberately; no lossless JSON intermediary claim.
- Durable dedup, replay effects, state ordering and real Alertmanager/console/NATS proof remain later work.
- Accepted ADRs remain unchanged. This additive decision records the reviewed contract details.
