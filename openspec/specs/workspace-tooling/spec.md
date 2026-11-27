# workspace-tooling Specification

## Purpose

Defines the pinned Linux toolchain and the tasks that developers and CI run on the Correlia workspace:
checking, code generation, analysis and tiered tests, with each test run confined to its own embedded
PostgreSQL.

## Requirements

### Requirement: Pinned Linux toolchain
Every tool a task runs (Dart, Flutter, the Serverpod CLI, Go, buf, OpenSpec) SHALL come from the versions
pinned in the repository and resolve to a Linux executable, never to one reached through the Windows PATH.
A task SHALL fail, naming the tool, when a pinned tool is missing or has another version.

#### Scenario: Tools resolve on Linux
- **WHEN** a developer in WSL asks the toolchain where each pinned tool lives
- **THEN** every path is a Linux path, not one under `/mnt/`, and each tool reports its pinned version

#### Scenario: Wrong Serverpod CLI version
- **WHEN** a task needs the Serverpod CLI and the installed one is not the pinned version
- **THEN** the task fails before doing any work, naming the Serverpod CLI, the pinned version and the found
  version

### Requirement: Tasks run on plain Linux
The tasks SHALL NOT depend on WSL: no Windows paths, no Windows interop and no WSL-only commands, so a Linux
CI runner can run them unchanged.

#### Scenario: Task definitions
- **WHEN** the task definitions and the scripts they call are searched for `/mnt/`, `wslpath`, `.exe` and
  `cmd.exe`
- **THEN** no match is found

#### Scenario: Windows tool on PATH
- **WHEN** the PATH also contains a Windows copy of a pinned tool
- **THEN** the tasks still run the pinned Linux copy

### Requirement: Check gate
`mise run check` SHALL be the gate run before every push and by CI on every pull request, and SHALL fail when
any of its steps fails. Its steps SHALL cover OpenSpec validation, static analysis of every package with no
issues, formatting, and the fast tests.

#### Scenario: Clean workspace
- **WHEN** `mise run check` runs on a workspace with no analysis issues, formatted code and passing fast tests
- **THEN** it exits 0

#### Scenario: Analysis issue
- **WHEN** a package has an analysis warning
- **THEN** `mise run check` exits non-zero and its output names the file and the issue

### Requirement: Test tier selection
Tests SHALL be grouped in tiers by tag: untagged fast tests, `db`, `e2e`, `plugin` and `load`.
`mise run test` with no arguments SHALL run only the fast tests. Arguments given to it SHALL be passed to the
test runner, so a tag selection runs exactly the tests with that tag; arguments that select no tag SHALL still
run only the fast tests. `load` tests SHALL run only when asked for by name.

#### Scenario: Default run
- **WHEN** `mise run test` runs with no arguments
- **THEN** the fast tests run and no `db`, `e2e`, `plugin` or `load` test runs

#### Scenario: Select the db tier
- **WHEN** `mise run test -- --tags db` runs
- **THEN** every `db` test runs, at least one test runs, and no untagged test runs

#### Scenario: Reporting arguments only
- **WHEN** `mise run test -- --reporter expanded` runs
- **THEN** the fast tests run with that reporter and no `db`, `e2e`, `plugin` or `load` test runs

#### Scenario: Load asked for by name
- **WHEN** `mise run test -- --tags load` runs
- **THEN** the `load` tests run and no other test runs

#### Scenario: All tiers except load
- **WHEN** the task for every tier except `load` runs
- **THEN** fast, `db`, `e2e` and `plugin` tests run and no `load` test runs

#### Scenario: Unknown tag
- **WHEN** `mise run test -- --tags dbb` runs
- **THEN** the run exits non-zero rather than passing with zero tests

### Requirement: Tests use only their own PostgreSQL
Database tests SHALL use an embedded PostgreSQL whose data directory and socket directory both lie inside a
cluster root that the test package owns, one root per cluster. No test or task SHALL connect to, stop, signal
or reuse any other PostgreSQL server on the machine.

#### Scenario: Another PostgreSQL-like listener is present
- **WHEN** a decoy that is not the tests' own cluster listens on a loopback TCP port and on a
  `.s.PGSQL.<port>` socket outside the test's cluster root, and the `db` tests run
- **THEN** the tests pass against their own cluster, the decoy receives no connection, and the decoy process
  is still running

#### Scenario: Database identity
- **WHEN** a `db` test asks its database for its data directory and its socket directories
- **THEN** both lie inside the test's own cluster root

#### Scenario: Clusters started side by side
- **WHEN** a test run starts more than one cluster (the shared test cluster and a child server's)
- **THEN** each has its own cluster root, the same root on every run of the same test, and each root used by a
  single test is deleted once its server and its PostgreSQL have stopped

#### Scenario: Interrupted end-to-end run
- **WHEN** only the process running an `e2e` test is killed with SIGKILL while its child server is running,
  this is repeated once more, and the same test is then run to completion
- **THEN** the final run passes; afterwards no child server of the earlier runs and no PostgreSQL process of
  that test's cluster root remains; the number of cluster roots under the test package is the same as after
  the first run; and a decoy listener outside the test's roots received no connection and is still running

#### Scenario: Re-run while the previous server is still stopping
- **WHEN** a test's previous child server is held in its graceful shutdown and a replacement child for the same
  cluster root is started immediately
- **THEN** the replacement does not start or attach to the cluster while the previous child runs, starts and
  passes once the previous child has exited, and, if the previous child is still running at the replacement's
  deadline, exits non-zero naming the cluster root, with the previous child's cluster untouched

### Requirement: Recovery after a killed test run
A test run whose process was killed with SIGKILL SHALL NOT stop the next run: the next run SHALL recover the
leftover cluster, identified by its data directory and never by process name, and its tests SHALL pass.

#### Scenario: Test server killed
- **WHEN** a process that started the tests' embedded PostgreSQL is killed with SIGKILL, and the `db` tests
  are run again
- **THEN** the second run passes, and afterwards no PostgreSQL process of that data directory remains

### Requirement: Local passwords on a fresh clone
The development and test database passwords SHALL be created per clone and never committed. A task that
needs them SHALL create them when the passwords file is missing, SHALL never overwrite an existing file, and
SHALL fail with a message naming the file and the missing section when the file lacks a needed section.

#### Scenario: Fresh clone
- **WHEN** `mise run test -- --tags db` runs in a fresh clone with no passwords file
- **THEN** a passwords file with development and test sections is created, the db tests pass, and
  `git status` does not list the passwords file

#### Scenario: Existing file without a test section
- **WHEN** the passwords file exists with no `test` section and a db test run starts
- **THEN** the task exits non-zero with a message naming the passwords file and the `test` section, and the
  file is unchanged

### Requirement: Code generation is current
The generated server and client code committed in the repository SHALL match what the pinned Serverpod
generator produces from the models and endpoints.

#### Scenario: Stale generated code
- **WHEN** an endpoint or model is changed without regenerating
- **THEN** `mise run check` fails, naming the generated files that differ

#### Scenario: Current generated code on a clean clone
- **WHEN** `mise run check` runs on a clean clone whose generated code is current
- **THEN** the generation check passes, and `git status` of the clone is unchanged afterwards

### Requirement: Reproducible event contract generation
`mise run proto` SHALL generate Dart event types, a payload JSON Schema and Dart bound constants from protobuf with standard annotations and pinned Linux tools, without global plugins. Identical inputs SHALL produce identical bytes. Generation failure SHALL name the stage and exit non-zero. The check/proto task chains SHALL prepare pinned validator dependencies automatically, with network needed only to fill missing first-run caches.

#### Scenario: Generate in a fresh clone
- **WHEN** pinned mise tools and Dart dependencies are installed in a clean clone with no Node validator modules and `mise run proto` runs twice
- **THEN** its task chain installs the pinned validator dependencies without a manual step and both runs produce byte-identical Dart, payload schema and bound constants

#### Scenario: Generator cannot run
- **WHEN** a required pinned plugin cannot run or protobuf input is invalid
- **THEN** generation exits non-zero naming the tool or input error instead of reporting current outputs

### Requirement: Event compatibility gate
`mise run check` SHALL lint protobuf and run Buf FILE breaking checks against the committed v1.0 descriptor baseline. Existing v1.0 field rules and enum domains SHALL remain unchanged, including scalar, collection and numeric bounds. Optional additions SHALL pass without editing the baseline; deleting or renaming fields, reusing numbers or adding required fields SHALL fail. The gate SHALL fail if its baseline is missing.

#### Scenario: Add optional bounded field
- **WHEN** a candidate minor contract adds an optional bounded field without altering existing fields
- **THEN** compatibility checks pass against the initial baseline without changing its bytes

#### Scenario: Existing value domains cannot widen in a minor
- **WHEN** a v1.1 candidate increases summary maxLength from 256 to 512 or widens an existing collection limit or numeric range
- **THEN** compatibility fails naming the changed constraint; a new optional field or major is required because older readers retain the original limits

#### Scenario: Break existing consumers
- **WHEN** a candidate removes a v1.0 field, changes its JSON name, reuses its number, changes its validation rules or adds a required field
- **THEN** compatibility checks exit non-zero naming the incompatible change

#### Scenario: Missing compatibility baseline
- **WHEN** the committed v1.0 descriptor baseline is missing
- **THEN** the compatibility gate fails rather than skipping or silently rebuilding it

### Requirement: Generated event outputs are current
`mise run check` SHALL regenerate event outputs in disposable scratch space and compare every generated file in both directions. Missing, extra or changed outputs SHALL fail with paths and the regeneration command. The check SHALL NOT modify the checkout and SHALL remove its scratch files on success or failure. Existing Serverpod generation verification SHALL remain enabled.

#### Scenario: Current contract outputs
- **WHEN** the committed Dart event code, payload JSON Schema and bound constants match regeneration
- **THEN** the check exits successfully without changing checkout files

#### Scenario: Deleted or obsolete output
- **WHEN** a generated schema is missing or an obsolete generated Dart file remains
- **THEN** the check fails naming each differing path and `mise run proto`, leaves checkout bytes unchanged and removes scratch files

### Requirement: Payload schemas have executable fixture validation
Generated payload schemas SHALL be checked with a pinned validator supporting their schema draft. Validation SHALL cover the canonical JSON representation, required presence, scalar limits, map entry/key/value limits and timestamp formats. This is a build-time check; runtime readers SHALL additionally enforce identity consistency, decoded byte limits and aggregate wire bounds.

#### Scenario: Canonical payload is schema valid
- **WHEN** a positive payload fixture contains snake_case fields, numeric bounded raw size, a nanosecond timestamp and base64 byte data
- **THEN** the generated payload schema accepts it with the pinned draft-2020-12 validator

#### Scenario: Payload constraints reject invalid values
- **WHEN** payload fixtures omit a required field, use an undeclared alias, exceed a string or map-entry bound, or contain an invalid timestamp
- **THEN** the generated schema validator rejects each fixture at its offending field

### Requirement: Shared patterns match complete field values
Contract string patterns SHALL be anchored whole-value patterns using syntax shared by RE2, ECMA-262 and Dart. Generated-schema and runtime validation SHALL reject strings containing only a valid substring rather than a valid complete value.

#### Scenario: Valid source-kind token
- **WHEN** schema and runtime validators receive source kind `alertmanager`
- **THEN** both accept it as a complete valid token

#### Scenario: Valid substring does not validate the whole token
- **WHEN** schema and runtime validators receive source kind `Bad-Kind!alertmanager`
- **THEN** both reject it despite its valid `alertmanager` substring

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

### Requirement: Child server tests budget their own deadlines
Every test that starts server child processes SHALL have its own test timeout, at least the sum of the
readiness and shutdown deadlines the harness allows each child the test starts in sequence, so a harness
deadline always fails before the runner's timeout. No such test SHALL run on the runner's default timeout. A
check in `mise run check` SHALL fail, naming the file and line, when a test that starts a child server has no
timeout of its own.

#### Scenario: Slow but healthy child under full-suite load
- **WHEN** the full suite runs at the default concurrency and a child server takes longer than the runner's
  default timeout to become ready, but less than the harness's readiness deadline
- **THEN** the test does not time out, and its own assertions decide whether it passes

#### Scenario: Child never becomes ready
- **WHEN** a child server is not ready within the harness's readiness deadline, in a test that starts one or
  several children in sequence
- **THEN** the test fails with the harness's readiness error and the child's output, not with a test-runner
  timeout

#### Scenario: New child server test without a timeout
- **WHEN** a test file that starts a child server declares a test with no timeout of its own
- **THEN** `mise run check` fails and names that file and line

### Requirement: Child server startup survives a lost port
When a child exits during startup because a port the harness picked for it is already in use, the harness
SHALL start it again on freshly picked ports, at most a fixed small number of attempts, within the one readiness
deadline. Any other startup failure SHALL fail at once with the child's output. A retry SHALL keep the same
database, cluster root and environment.

#### Scenario: Port taken between pick and bind
- **WHEN** another process binds a child's pre-picked API or web port before the child does
- **THEN** the child is started again on fresh ports and the test proceeds against the new ports

#### Scenario: Port lost on every attempt
- **WHEN** every attempt fails because a port is already in use
- **THEN** the test fails after the last attempt with an error naming the attempts and the last child's output

#### Scenario: Startup fails for another reason
- **WHEN** a child exits during startup for any reason other than a port already in use, such as a migration or
  configuration error
- **THEN** the test fails on the first attempt with the child's output, and no second child is started

### Requirement: A child's exit and readiness describe the child the test owns
A child's reported exit SHALL be the exit of its final attempt: an attempt that failed on a lost port and is
being retried SHALL NOT complete it. The harness SHALL declare a child ready only when its readiness endpoint
answers and the listener on the child's API port belongs to the child's own current process. Stopping or
killing a child SHALL stop further retries and act on its current attempt.

#### Scenario: Caller waits on exit and readiness together
- **WHEN** a test waits for whichever comes first of the child's exit and its readiness, and the first attempt
  fails on a lost port
- **THEN** the test sees neither that attempt's exit nor a failure; it sees the outcome of the retried attempt

#### Scenario: Another server answers on the stolen API port
- **WHEN** the process that took a child's API port answers the readiness endpoint with success
- **THEN** the harness does not declare the child ready on that port, retries the child on fresh ports, and the
  child's reported API port is not the stolen one

#### Scenario: Teardown while a retry is pending
- **WHEN** a test stops or kills a child while a lost-port retry is being started
- **THEN** no further attempt starts, the attempt that was being started is stopped, and the child's exit
  completes once

### Requirement: Linux CI verification
Every pull request to `main`, and every push to `main`, SHALL run one CI job named `Linux verification` on a
fresh Linux runner. It installs the pinned toolchain from the repository, then runs `mise run check` and
`mise run test:all`. The job SHALL fail when either command fails, and it SHALL never run the `load` tier.

#### Scenario: Passing pull request
- **WHEN** a pull request to `main` has a head on which `mise run check` and `mise run test:all` pass
- **THEN** the `Linux verification` check of that head concludes `success`

#### Scenario: Failing gate
- **WHEN** a pull request's head fails `mise run check` (for example, an unformatted file)
- **THEN** the `Linux verification` check concludes `failure`, `mise run test:all` is not run, and the job log
  names the failing step

#### Scenario: Failing test tier
- **WHEN** `mise run check` passes and a `db`, `e2e` or `plugin` test fails
- **THEN** the `Linux verification` check concludes `failure` and the job log names the failing test

#### Scenario: Pinned tools only
- **WHEN** the job installs its toolchain
- **THEN** every tool it runs is the version pinned in `mise.toml`, and `mise run check`'s doctor step passes
  on the runner

#### Scenario: Superseded run
- **WHEN** a new commit is pushed to a pull request while its previous `Linux verification` run is still
  running
- **THEN** the previous run is cancelled and only the new head's run reports the check

#### Scenario: Successive pushes to main
- **WHEN** three commits are pushed to `main` one after another while the first push's `Linux verification`
  run is still running
- **THEN** none of the three runs is cancelled or replaced by concurrency grouping, and each runs
  `mise run check` and `mise run test:all` for its own commit

### Requirement: Simulator command line

A command-line tool SHALL call the rule simulator for a pasted event file or a stored event key (ID, `observed_at`, optional disposition), optionally with a draft matcher file, and print the trace in a readable form or as JSON.

#### Scenario: Trace a stored event
- **WHEN** the owner runs the tool with the ID and `observed_at` of a stored alert
- **THEN** it prints each rule, each condition leaf with its reason, each action's effect and the final labels

#### Scenario: Malformed timestamp
- **WHEN** the owner passes an `observed_at` with no offset or an invalid calendar date
- **THEN** the tool prints the simulator's `invalid_input` error for `observedAt` and exits non-zero

#### Scenario: Simulator error
- **WHEN** the tool gets an `event_not_found`, `raw_unavailable`, `ambiguous_member`, `invalid_input` or validation error from the simulator
- **THEN** it prints the error code and field and exits with a non-zero status
