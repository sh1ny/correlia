# Proposal

## Why

M1 (Walking skeleton) needs a stable event boundary before ingest and plugin work can share data. This change advances the canonical-contract risk, ID-4 and the identity portion of ID-6 and ID-7(b,c), plus the clean-clone gate; durable dedup and alert-state effects remain in subsequent M1 changes. The real Alertmanager/console/NATS user criterion is judged at milestone close, because this change adds no running ingest or output.

## What Changes

- Define `correlia.event.v1` protobuf messages, explicit snake_case JSON names, field bounds and an exact v1.0 JSON Schema export.
- Add a pure Dart canonical-event library in the existing server package: validated values, structured CloudEvents JSON, canonical tuple encoding, alert fingerprints, delivery keys and UUIDv5 observation ids.
- Supply source-independent identity primitives plus Alertmanager label selection and observation-key helpers, not a webhook decoder.
- Add pinned Dart protobuf and standard JSON Schema generation with `buf.validate` annotations, Buf lint/breaking checks and generated-output drift checks to the existing Linux toolchain.
- Document the contract with portable fixed identity vectors and positive/negative wire fixtures.

## Capabilities

### New Capabilities

- `canonical-event`: versioned payload, field bounds, validated structured CloudEvents serialization and identity semantics.

### Modified Capabilities

- `workspace-tooling`: protobuf generation, lint/breaking compatibility gates and generated-contract drift verification.

## Impact

New `proto/correlia/event/v1/`, generated Dart beneath `correlia_server/lib/src/`, a public `correlia_server/lib/event.dart` entry point, payload schemas and fixtures under `contracts/`, server unit tests and focused tool commands. Use standard `buf.validate` annotations and pinned `protoc-gen-jsonschema`, a narrow descriptor-to-Dart bounds extractor and map-cap schema patch, not a custom options language/schema compiler. Extend mise and `correlia_tool`; use Node/Ajv only for build-time draft-2020-12 fixture validation. Add pinned Dart protobuf, SHA-256 and UUID dependencies through the workspace lock. No database migration, runtime schema engine, generic CloudEvents SDK, transparent JSON forwarding, per-minor history manifest, UI, webhook, plugin protocol or NATS changes. ADRs 0004/0019 govern the contract; 0016/0017 govern future stateful consumers.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Implement the contract without runtime ingest

- **Choice:** Pure server-side library, protobuf/JSON schemas, identity helpers and tooling. Defer transport storage, dedup effects, state ordering and actual source decoding to their listed M1 changes.
- **Rejected:** Pulling the pipeline or NATS into this change; it would collapse the roadmap's independently verifiable boundaries.
- **Reversal cost:** low.
- **Important:** yes — binds future changes through the event contract.
- **Chosen by:** agent.

### S2: Keep one source of truth and one existing package

- **Choice:** Protobuf with standard `buf.validate` annotations generates the payload JSON Schema and Dart bound constants. Keep a small handwritten CloudEvents envelope codec and validated wrappers in the existing server package. Use one v1.0 descriptor baseline; require a new compatibility plan before publishing v1.1.
- **Rejected:** A custom constraint language/schema compiler, generated protobuf envelope, prematurely general history/forwarding machinery, independent handwritten bound tables and another workspace package. These add maintenance without an M1 consumer.
- **Reversal cost:** medium.
- **Important:** yes — contract and package boundary.
- **Chosen by:** agent.

### S3: Freeze identity bytes before consumers exist

- **Choice:** Specify exact canonical bytes, fixed UUIDv5 namespace `f36aac0f-16fa-46db-951b-bb578b323aed` and hashing representation; include vectors for delimiter collisions, map permutations, re-batching, severity-label exclusions, original timestamps and generation changes. The owner authorized replacing the draft's missing namespace and recomputing example ids on 2026-11-10; the concrete UUID is the agent's choice.
- **Rejected:** Delimiter joins, upstream fingerprints, body-based event ids and arrival-time fallback; these contradict ADR 0019.
- **Reversal cost:** high.
- **Important:** yes — data format with high reversal cost.
- **Chosen by:** agent.
