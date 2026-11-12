# Spec Delta

## ADDED Requirements

### Requirement: Reproducible plugin protocol generation
`mise run proto` SHALL generate the Dart and Go code of `correlia.plugin.v1` from its protobuf with pinned tools, producing identical bytes for identical inputs. `mise run check` SHALL lint the protocol and fail, naming the paths, when the committed generated code differs from the regenerated code. A protocol change SHALL leave the frozen event-v1.0 baseline untouched.

#### Scenario: Current protocol outputs
- **WHEN** the committed Dart and Go protocol code matches regeneration
- **THEN** the check passes without changing checkout files

#### Scenario: Stale protocol output
- **WHEN** the protocol protobuf changes without regeneration
- **THEN** `mise run check` fails naming each differing generated path and `mise run proto`

### Requirement: Pinned plugin and NATS tool builds
The first-party Go plugins and the NATS dev/test tool SHALL build through mise from modules pinned with checksums, using the pinned Go toolchain. A tier that needs them SHALL build them first. A failed build SHALL name the module and stop the tier before any test runs.

#### Scenario: Plugin tier on a clean clone
- **WHEN** `mise run test -- --tags plugin` runs on a clean clone with an empty build output folder
- **THEN** the NATS plugin and NATS tool are built from their pinned modules, and the NATS tests run against a JetStream server owned by the test

#### Scenario: Module checksum mismatch
- **WHEN** a dependency's downloaded content does not match its recorded checksum
- **THEN** the build fails naming the module, and no test of that tier runs

### Requirement: Tests use only their own NATS server
NATS-backed tests SHALL start their own embedded JetStream server on a free loopback port with private scratch storage. They SHALL stop it and remove that storage afterwards, and SHALL never connect to another NATS server.

#### Scenario: Test-owned server
- **WHEN** a NATS-backed test runs
- **THEN** it publishes only to a server it started on a loopback port, and after the run neither that server's process nor its storage remains

#### Scenario: Server fails to start
- **WHEN** the embedded server cannot start, for example because its storage folder is not writable
- **THEN** the test fails naming the NATS startup error rather than falling back to any other server
