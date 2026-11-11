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

The same commands generate the **experimental** `correlia.plugin.spike.v1`
output probe separately from event inputs:

- Dart protobuf/gRPC under `correlia_server/lib/src/plugin_generated/`;
- Go protobuf/gRPC under `correlia_server/test/plugin/fixtures/go/gen/`.

Plugin generation pins protoc_plugin 25.1.0, protoc-gen-go v1.36.11 and
protoc-gen-go-grpc v1.6.0. Only the plugin stage requests gRPC generation.
The event schema generator receives only `proto/correlia/event/v1`, and the
frozen event baseline is never regenerated. Plugin drift checks compare
changed, missing and obsolete files in both output roots. No upstream
go-plugin schemas enter Buf: compatibility RPC descriptors are handwritten
Dart, outside the Correlia-owned proto module. The probe is not a stable SDK
(ADR 0022).

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

Resolve workspace dependencies once with `mise exec -- flutter pub get`, and repeat that explicit
step after dependency changes. The analysis and check tasks use Flutter's `--no-pub` flag: they consume
that resolved workspace instead of refreshing pub dependencies or advisories during verification.
`doctor` inspects the resolved Serverpod CLI entry point with its machine-oriented `--version` flag,
without a package refresh or CLI update check.
The Serverpod generated-code check resolves its isolated workspace with offline pub, verifies the
lockfile versions, then executes that resolved CLI entry point directly. Pure code generation needs
no native assets; invoking `dart run` there would otherwise download unrelated transitive CLI native
libraries into every disposable workspace. No generator, comparison, or drift check is skipped.

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

For a deliberately disconnected Linux check, use Go's documented
[filesystem module proxy](https://go.dev/ref/mod#environment-variables) over the warmed download cache:

```sh
GOPROXY="file://$(mise exec -- go env GOMODCACHE)/cache/download" \
  mise exec -- unshare --user --map-current-user --keep-caps --net -- \
  sh -c 'ip link set lo up && exec mise run check'
```

Unlike `GOPROXY=off`, this supplies cached version/deprecation metadata required by versioned `go run`.
Checksum verification remains enabled. Missing cached dependencies fail rather than reaching a network
fallback. The private network namespace has only loopback enabled for the Flutter test harness's
local WebSocket IPC; it has no external interface or route. External network access is disabled for
the complete gate, not just the generators.

A checkout can invalidate generated pub resolution metadata without changing lockfile bytes. If SDK
bootstrap still attempts an advisory refresh, remove only the generated `.dart_tool/package_config.json`,
then run `mise exec -- dart pub get --offline` from the workspace root. Rebuilding this cache resolved
the pinned SDK's bootstrap failure during the clean-workspace proof; it did not change package mappings
or dependency versions. Do not alter the committed lockfile or bypass test execution to obtain a pass.
