# Tasks

## Test map

All rows are planned red: implementation tests have not been run. Apply demonstrates the missing behavior first and marks rows green only from actual passing results. Use real schema/Buf boundaries, no source-text snapshots or copied-metadata tests. Server tests are untagged fast tests.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| canonical-event → Versioned canonical payload | Complete event survives both representations | `correlia_server/test/unit/event/canonical_event_test.dart` | `Complete event survives both representations` | red |
| canonical-event → Versioned canonical payload | Invalid enum or absent required metadata | `correlia_server/test/unit/event/canonical_event_test.dart` | `Invalid enum or absent required metadata` | red |
| canonical-event → Structured CloudEvents envelope | Publish a canonical alert | `correlia_server/test/unit/event/cloud_event_test.dart` | `Publish a canonical alert` | red |
| canonical-event → Structured CloudEvents envelope | Conflicting or unsupported envelope | `correlia_server/test/unit/event/cloud_event_test.dart` | `Conflicting or unsupported envelope` | red |
| canonical-event → Structured CloudEvents envelope | Intermediary adds a valid extension | `correlia_server/test/unit/event/cloud_event_test.dart` | `Intermediary adds a valid extension` | red |
| canonical-event → Structured CloudEvents envelope | Invalid extension attribute | `correlia_server/test/unit/event/cloud_event_test.dart` | `Invalid extension attribute` | red |
| canonical-event → Stable time evidence | Redelivery after clock clamping changes | `correlia_server/test/unit/event/identity_test.dart` | `Redelivery after clock clamping changes` | red |
| canonical-event → Stable time evidence | Missing fallback evidence | `correlia_server/test/unit/event/identity_test.dart` | `Missing fallback evidence` | red |
| canonical-event → Bounded event fields | Display truncation and long identity | `correlia_server/test/unit/event/canonical_event_test.dart` | `Display truncation and long identity` | red |
| canonical-event → Bounded event fields | Collection or encoded size overflow | `correlia_server/test/unit/event/canonical_event_test.dart` | `Collection or encoded size overflow` | red |
| canonical-event → Bounded event fields | Raw metadata is independent of the default ingress limit | `correlia_server/test/unit/event/canonical_event_test.dart` | `Raw metadata is independent of the default ingress limit` | red |
| canonical-event → Unambiguous canonical tuple encoding | ID-4 delimiter collision | `correlia_server/test/unit/event/identity_test.dart` | `ID-4 delimiter collision` | red |
| canonical-event → Unambiguous canonical tuple encoding | Map order and Unicode length | `correlia_server/test/unit/event/identity_test.dart` | `Map order and Unicode length` | red |
| canonical-event → Namespace scoped alert identity | ID-7b severity is identity by default | `correlia_server/test/unit/event/identity_test.dart` | `ID-7b severity is identity by default` | red |
| canonical-event → Namespace scoped alert identity | ID-7c explicit severity exclusion | `correlia_server/test/unit/event/identity_test.dart` | `ID-7c explicit severity exclusion` | red |
| canonical-event → Namespace scoped alert identity | Separate and explicitly shared namespaces | `correlia_server/test/unit/event/identity_test.dart` | `Separate and explicitly shared namespaces` | red |
| canonical-event → Delivery independent observation identity | ID-6 reordered and re-batched observations | `correlia_server/test/unit/event/identity_test.dart` | `ID-6 reordered and re-batched observations` | red |
| canonical-event → Delivery independent observation identity | Different observation or generation | `correlia_server/test/unit/event/identity_test.dart` | `Different observation or generation` | red |
| canonical-event → Transport identity is distinct from observation identity | Exact transport retry | `correlia_server/test/unit/event/identity_test.dart` | `Exact transport retry` | red |
| canonical-event → Transport identity is distinct from observation identity | Distinct delivery evidence | `correlia_server/test/unit/event/identity_test.dart` | `Distinct delivery evidence` | red |
| canonical-event → Version aware validation and forward parsing | Namespaced extension retained | `correlia_server/test/unit/event/cloud_event_test.dart` | `Namespaced extension retained` | red |
| canonical-event → Version aware validation and forward parsing | Unsupported field or major version | `correlia_server/test/unit/event/cloud_event_test.dart` | `Unsupported field or major version` | red |
| canonical-event → Version aware validation and forward parsing | UPG-3 older consumers parse a newer minor | `correlia_server/test/unit/event/cloud_event_test.dart` | `UPG-3 older consumers parse a newer minor` | red |
| canonical-event → Version aware validation and forward parsing | Extensions have one location | `correlia_server/test/unit/event/cloud_event_test.dart` | `Extensions have one location` | red |
| canonical-event → Binary validation scope | Newer binary minor omits its optional addition | `correlia_server/test/unit/event/canonical_event_test.dart` | `Newer binary minor omits its optional addition` | red |
| canonical-event → Binary validation scope | Binary input has no provenance | `correlia_server/test/unit/event/canonical_event_test.dart` | `Binary input has no provenance` | red |
| canonical-event → Binary validation scope | Supplied binary provenance is invalid | `correlia_server/test/unit/event/canonical_event_test.dart` | `Supplied binary provenance is invalid` | red |
| workspace-tooling → Reproducible event contract generation | Generate in a fresh clone | `tool/test/proto_command_test.dart` | `Generate in a fresh clone` | red |
| workspace-tooling → Reproducible event contract generation | Generator cannot run | `tool/test/proto_command_test.dart` | `Generator cannot run` | red |
| workspace-tooling → Event compatibility gate | Add optional bounded field | `tool/test/proto_compatibility_test.dart` | `Add optional bounded field` | red |
| workspace-tooling → Event compatibility gate | Existing value domains cannot widen in a minor | `tool/test/proto_compatibility_test.dart` | `Existing value domains cannot widen in a minor` | red |
| workspace-tooling → Event compatibility gate | Break existing consumers | `tool/test/proto_compatibility_test.dart` | `Break existing consumers` | red |
| workspace-tooling → Event compatibility gate | Missing compatibility baseline | `tool/test/proto_compatibility_test.dart` | `Missing compatibility baseline` | red |
| workspace-tooling → Generated event outputs are current | Current contract outputs | `tool/test/proto_command_test.dart` | `Current contract outputs` | red |
| workspace-tooling → Generated event outputs are current | Deleted or obsolete output | `tool/test/proto_command_test.dart` | `Deleted or obsolete output` | red |
| workspace-tooling → Payload schemas have executable fixture validation | Canonical payload is schema valid | `tool/test/proto_command_test.dart` | `Canonical payload is schema valid` | red |
| workspace-tooling → Payload schemas have executable fixture validation | Payload constraints reject invalid values | `tool/test/proto_command_test.dart` | `Payload constraints reject invalid values` | red |
| workspace-tooling → Shared patterns match complete field values | Valid source-kind token | `tool/test/proto_command_test.dart; correlia_server/test/unit/event/canonical_event_test.dart` | `Valid source-kind token` | red |
| workspace-tooling → Shared patterns match complete field values | Valid substring does not validate the whole token | `tool/test/proto_command_test.dart; correlia_server/test/unit/event/canonical_event_test.dart` | `Valid substring does not validate the whole token` | red |

## 1. Record the simplified contract decisions

- [ ] 1.1 Write the next additive ADR for exact identity bytes/namespace, standard annotation/schema tools, strict ProtoJSON, parse-only future-minor handling, optional binary metadata and the single-baseline policy. Clarify full boundary validation before acceptance, transport-specific support above 64 KiB and re-planning before v1.1 publication. Update architecture index and contract summary without editing accepted ADRs. Verify alignment with design S1–S3/D1–D8 and that the index resolves to the new ADR.

## 2. Generate and gate the annotated payload contract

Skills: dart-use-pattern-matching, dart-write-documentation, dart-run-static-analysis, dart-add-unit-test, dart-build-cli-app; follow AGENTS.md's Dart and Flutter code section.

- [ ] 2.1 Add failing real-boundary tests for every workspace-tooling row in proto_command_test.dart and proto_compatibility_test.dart. Exercise actual pinned generation/Ajv, malformed input, optional addition, existing field/rule changes (including 256→512 cap widening), a newly required field, missing baseline and missing/extra/stale outputs. Verify failures identify missing behavior and use disposable owned inputs, not source-text snapshots or mock command echoes.
- [ ] 2.2 Define payload messages with explicit json_name and standard buf.validate rules, Buf v2 module/lock and pinned local Dart/JSON Schema generators. Add protoc_plugin 25.1.0, protobuf 6.1.0 and needed descriptor dependencies through the Dart workspace; pin Ajv 8.17.1/ajv-formats 3.0.1 and npm lock under tool/schema_validation, and add /tool/schema_validation/node_modules/ to .gitignore. Use full-range uint32 raw.size for referenced-body metadata, not a raised default ingress limit; place bound constants with messages in event_generated and add its root analyzer exclusion while handwritten event code remains analyzed. Verify actual dependency resolution and Buf acceptance before proceeding; no envelope proto or private options.proto.
- [ ] 2.3 Implement tool proto plus the small standard-rule-to-Dart-bound extractor and map min/maxProperties patch, selecting the strict bundled payload schema. Implement build-time Ajv2020 fixture validation and automatic task-chain npm-ci setup, bounded subprocess execution and scratch cleanup. Copy workspace formatter options into a scratch package with matching pubspec SDK constraints and resolved Dart language version, and format all generated messages/constants there before write/compare; verify workspace formatting agrees with both write and drift-check paths. Verify snake_case/required fields, map entry/key/value caps, nanosecond dates, full-range uint32 raw metadata, base64 data and anchored token patterns (including invalid whole values containing valid substrings) with positive/negative fixtures; make the generation/schema rows green from passing 2.1 tests. No generic schema compiler, CEL engine or runtime JSON Schema library.
- [ ] 2.4 Commit the final v1.0 descriptor baseline. Implement proto-check with Buf FILE, exact comparison of existing standard field/oneof rules and enum domains, newly-required-field rejection and two-way generated drift comparison. Fail on a missing baseline; never auto-refresh it. Verify compatibility/drift cases from 2.1 pass, valid optional additions pass, invalid cases name their changes, checkout bytes stay unchanged and scratch is deleted; turn those rows green. Do not add a per-minor manifest, history-subset check or publication framework.
- [ ] 2.5 Expose proto/proto:check and make automatic validator setup a dependency of check and both proto tasks, retaining Serverpod generated verification. Use locked npm-ci cache-first/no-script/no-audit flags; document npm registry, Go module proxy/checksum database and BSR first-run access, with warm-cache runs requiring no network. Document generation, schema/runtime validation distinction, the one-baseline policy and future-minor prerequisite, and update the tool changelog. Verify actual mise commands and the existing Serverpod generation check with a throwaway wiring smoke, not a permanent source/wiring test.

## 3. Implement deterministic identity and source evidence

Skills: dart-use-pattern-matching, dart-write-documentation, dart-run-static-analysis, dart-add-unit-test; follow AGENTS.md's Dart and Flutter code section.

- [ ] 3.1 Write failing identity_test.dart cases for the map's identity/time/transport scenarios: ID-4, UTF-8 sorting, namespace scoping, ID-7b/c, ID-6, original timestamp evidence, missing fallback evidence, generation and transport domains. Include independently derived vectors for native, fallback, Alertmanager, header/body transport, raw/hash component tags, absent/present markers, Unicode, invalid evidence and generation bounds. Verify failures expose missing identity behavior rather than unrelated setup.
- [ ] 3.2 Implement canonical encoding, bounded identity components and source context, label/exclusion selection, observation and transport keys, SHA-256 fingerprints and UUIDv5 ids using crypto 3.0.8 and uuid 4.6.0 v5FromBytes. Preserve reported timestamp text; add no arrival fallback, UUID implementation, durable dedup or state effects. Verify all 3.1 assertions against independent vectors, including the reviewed event fixture, and turn those rows green.
- [ ] 3.3 Publish vectors and the exact encoding/namespace reference under contracts and update the server changelog. Verify documented bytes/digests/UUIDs equal independently checked vectors and distinguish identity-only evidence from future dedup/state behavior.

## 4. Implement the typed payload and small envelope codec

Skills: dart-use-pattern-matching, dart-write-documentation, dart-run-static-analysis, dart-add-unit-test; follow AGENTS.md's Dart and Flutter code section.

- [ ] 4.1 Add failing canonical_event_test.dart/cloud_event_test.dart tests for the remaining canonical-event rows: both representations, required/enumerated fields, strict known keys/timestamps, immutable aliases, field/aggregate bounds, extensions, UPG-3 and binary scope. Include valid intermediary extensions, invalid extension names/scalar types, unknown newer JSON fields ignored at nested levels, v1.1 optional additions absent, omitted binary metadata and supplied invalid metadata. Include public-wrapper protobuf re-encoding recoverable by a newer parser, raw metadata above the default ingress limit and at/above the uint32 maximum, non-BMP scalar bounds and anchored token patterns shared with Ajv fixtures. Verify failures cover consumer-visible behavior; no opaque-forwarding/transcoding test contract.
- [ ] 4.2 Implement public lib/event.dart and immutable validated values, sealed errors, generated-bound checks, identity agreement and display-only truncation. Keep a frozen generated message backing internally, retaining native unknown field data for public protobuf re-encoding; never leak mutable aliases. Keep mutable generated messages internal and validate full input size/depth at the boundary. Verify factory/bounds/identity assertions from 4.1 pass with field-path errors and no mutable alias escape; turn their map rows green.
- [ ] 4.3 Implement the small handwritten CloudEvents JSON codec and binary reader. Derive/check known envelope attributes, validate then ignore valid unknown extensions, keep payload extensions inside data.extensions and run the strict known-field pre-pass before protobuf parsing. Parse newer-minor JSON with ignoreUnknownFields and explicit known-core scope; make binary sourceDataschema optional with unknown scope when absent and re-emit native protobuf unknown field data from the public wrapper while JSON output remains a known-field projection. Verify all wire/version/extension rows from 4.1 pass and turn them green. No protobuf envelope, envelope schema generator, mandatory binary provenance, private opaque JSON tree or transparent forwarding API.
- [ ] 4.4 Commit complete positive/negative wire and synthetic newer-minor fixtures. Document field bounds, numeric raw.size, nanosecond/original-time evidence, ignored unknown data and current-version projection, plus the distinction between full boundary validation and payload JSON Schema alone. Update server changelog. Verify exact payload fixtures with pinned Ajv and runtime validators and malformed known fields with their intended field errors; do not validate a whole CloudEvent against the payload-only schema.

## 5. Prove the integrated contract

- [ ] 5.1 In an owned clean Linux workspace, resolve pinned dependencies/setup, generate twice, run proto-check, focused event/tool tests and mise run check. Use a throwaway public-API smoke for typed Alertmanager identity → CloudEvent, payload-only Ajv validation, binary parsing with and without metadata and known-core parsing of a synthetic newer minor. Repeat the warmed-cache check with network access disabled. Verify fixed identities, no drift, workspace-generated formatter stability, analyzed handwritten code and all mapped cases green from actual results; remove only the clone/smoke artifacts created here. No database/plugin/live-source tiers are required for this pure contract change.

## Workflow follow-up

- Real Alertmanager → console → NATS owner verification remains at M1 close; identity-only ID-6/ID-7 proofs here do not claim durable dedup/state effects.
- Before publishing v1.1, extend compatibility coverage to that actual published contract. Do not claim the initial baseline protects fields introduced only in a future minor.
- Lossless JSON forwarding, a binary envelope and multi-minor manifest are not M1 requirements; add them only for a demonstrated consumer.
- Implementation, archive and local finish are separate subsequent workflows.
