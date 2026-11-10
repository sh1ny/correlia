# Canonical event contract tooling

The canonical event payload is defined by `proto/correlia/event/v1/event.proto`.
Standard `buf.validate` annotations are the source of truth for field
requirements, scalar and collection bounds, numeric domains and whole-value
patterns.

## Generate and check

Run the pinned Linux tools through mise:

```sh
mise run proto
mise run proto:check
```

`proto` generates three owned output sets:

- Dart messages under `correlia_server/lib/src/event_generated/`;
- the strict bundled payload schema under `contracts/schemas/`; and
- Dart bound constants in
  `correlia_server/lib/src/event_generated/correlia/event/v1/event_bounds.dart`.

Generation writes into disposable scratch first, formats generated Dart with
the workspace formatter settings in a scratch package, validates the generated
schema with the pinned Ajv validator and only then replaces owned outputs.
`proto:check` repeats that work in scratch and compares every output in both
directions. It never writes the checkout and removes its scratch directory on
success or failure.

The Buf workspace uses STANDARD lint rules and FILE breaking rules. The
committed `contracts/baselines/event-v1.0.binpb` is the one v1.0 descriptor
baseline. `proto:check` fails when it is missing and never rebuilds it
automatically. In addition to Buf's structural checks, the command compares
existing standard validation-rule objects, explicit JSON names, presence and
enum domains exactly. Optional additions pass; changing or widening an
existing domain and adding a required field or oneof fail and name the change.

Before publishing any v1.1 contract, that change must extend compatibility
coverage to the newly published contract while retaining the existing schemas.
The initial baseline does not protect fields that exist only in a future
minor.

## Schema validation and runtime validation

The generated payload schema is a build-time contract check. Ajv 8.17.1 with
`ajv-formats` 3.0.1 validates the committed positive and negative payload
fixtures using JSON Schema draft 2020-12. It covers required presence, scalar
and map bounds, timestamp formats, base64 bytes, numeric raw sizes and anchored
whole-value patterns.

Schema validity is necessary but not sufficient for accepting an event. The
runtime boundary must additionally enforce identity consistency, exact decoded
byte limits, aggregate serialized-size limits and JSON depth. Do not add a
runtime JSON Schema engine.

## First-run dependencies and offline reuse

`mise run proto`, `mise run proto:check` and `mise run check` depend on
`proto:setup`. It runs the locked npm installation with the prefer-offline,
no-script, no-audit and no-fund flags:

```sh
npm ci --prefix tool/schema_validation --prefer-offline --ignore-scripts --no-audit --no-fund
```

The first run may contact the npm registry, the Go module proxy and checksum
database for the pinned JSON Schema generator, the Buf Schema Registry for the
locked standard annotations, and pub for Dart dependencies. After those caches
are warm, generation and checking require no network access. The Node modules
are build-time only and live in the ignored
`tool/schema_validation/node_modules/` directory.
