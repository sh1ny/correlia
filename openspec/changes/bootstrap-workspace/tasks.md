# Tasks

## Test map

Paths are relative to the repository root. `correlia_server/test/{unit,db,e2e}` carry the tags of their tier
(`db`, `e2e` through `@Tags`); `unit` tests are untagged (fast). `tool/test` tests are fast.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| process-roles → Role selection at startup | Role set explicitly | correlia_server/test/e2e/roles_e2e_test.dart | `worker role is logged as worker` | red |
| process-roles → Role selection at startup | No role set | correlia_server/test/e2e/roles_e2e_test.dart | `no role runs as all and logs all` | red |
| process-roles → Role selection at startup | Unknown role | correlia_server/test/e2e/roles_e2e_test.dart | `unknown role exits non-zero before any listener or cluster` | red |
| process-roles → Role selection keeps the other startup options | Production mode with a role | correlia_server/test/unit/process_options_test.dart | `production mode and api role both survive parsing` | red |
| process-roles → Role selection keeps the other startup options | Startup options rejected as a whole | correlia_server/test/e2e/roles_e2e_test.dart | `unrecognised option exits non-zero naming it` | red |
| process-roles → Subsystems per role | api role | correlia_server/test/e2e/roles_e2e_test.dart | `api role serves the console and starts no background subsystem` | red |
| process-roles → Subsystems per role | worker role | correlia_server/test/e2e/roles_e2e_test.dart | `worker role answers 404 for the console` | red |
| process-roles → Subsystems per role | Subsystem fails to start | correlia_server/test/unit/role_runtime_test.dart | `a failing start names the subsystem and maps to a non-zero exit` | red |
| process-roles → Health endpoints in every role | Healthy server | correlia_server/test/e2e/health_e2e_test.dart | `livez readyz startupz answer 200 in each role` | red |
| process-roles → Health endpoints in every role | Subsystem still starting | correlia_server/test/db/startup_gate_test.dart | `startupz stays 503 until the gated subsystem has started` | red |
| process-roles → Health endpoints in every role | Database unreachable | correlia_server/test/e2e/health_e2e_test.dart | `readyz 503 and livez 200 when the database stops` | red |
| process-roles → Graceful shutdown | SIGTERM | correlia_server/test/unit/role_runtime_test.dart; correlia_server/test/e2e/shutdown_e2e_test.dart | `stops subsystems one at a time in reverse start order`; `SIGTERM stops subsystems before the pool closes and exits 0` | red |
| process-roles → Graceful shutdown | Subsystem fails to stop | correlia_server/test/unit/role_runtime_test.dart; correlia_server/test/db/shutdown_order_test.dart | `a failing stop is logged, the rest still stop, a combined error is rethrown`; `a failing stop callback makes Serverpod report a failed shutdown` | red |
| workspace-tooling → Pinned Linux toolchain | Tools resolve on Linux | tool/test/doctor_test.dart | `reports a Linux path and the pinned version for every tool` | green |
| workspace-tooling → Pinned Linux toolchain | Wrong Serverpod CLI version | tool/test/doctor_test.dart | `a wrong serverpod_cli version fails naming tool, pinned and found` | green |
| workspace-tooling → Tasks run on plain Linux | Task definitions | tool/test/task_definitions_test.dart | `mise.toml and tool sources have no Windows or WSL references` | green |
| workspace-tooling → Tasks run on plain Linux | Windows tool on PATH | tool/test/doctor_test.dart | `a Windows dart earlier on PATH does not win over the pinned one` | green |
| workspace-tooling → Check gate | Clean workspace | n/a: the gate itself; `mise run check` on a clean clone, captured in task 9.2 | — | n/a |
| workspace-tooling → Check gate | Analysis issue | tool/test/check_test.dart | `an analysis warning fails the analyze step naming file and issue` | red |
| workspace-tooling → Test tier selection | Default run | tool/test/test_command_test.dart | `no arguments runs only fast tests` | red |
| workspace-tooling → Test tier selection | Select the db tier | tool/test/test_command_test.dart | `--tags db runs every db test and nothing untagged` | red |
| workspace-tooling → Test tier selection | Reporting arguments only | tool/test/test_command_test.dart | `--reporter expanded runs only fast tests` | red |
| workspace-tooling → Test tier selection | Load asked for by name | tool/test/test_command_test.dart | `--tags load runs only load tests` | red |
| workspace-tooling → Test tier selection | All tiers except load | tool/test/test_command_test.dart | `test:all runs fast db e2e plugin and no load` | red |
| workspace-tooling → Test tier selection | Unknown tag | tool/test/test_command_test.dart | `--tags dbb exits non-zero` | red |
| workspace-tooling → Tests use only their own PostgreSQL | Another PostgreSQL-like listener is present | correlia_server/test/db/postgres_isolation_test.dart | `a decoy listener and socket get no connection and keep running` | red |
| workspace-tooling → Tests use only their own PostgreSQL | Database identity | correlia_server/test/db/postgres_isolation_test.dart | `data_directory and unix_socket_directories lie inside the cluster root` | red |
| workspace-tooling → Tests use only their own PostgreSQL | Clusters started side by side | correlia_server/test/e2e/cluster_roots_e2e_test.dart | `each cluster has its own stable root, deleted after its server stopped` | red |
| workspace-tooling → Tests use only their own PostgreSQL | Interrupted end-to-end run | correlia_server/test/e2e/interrupted_run_e2e_test.dart | `killing only the harness twice leaves no child, no cluster process, no extra root` | red |
| workspace-tooling → Tests use only their own PostgreSQL | Re-run while the previous server is still stopping | correlia_server/test/e2e/root_handoff_e2e_test.dart | `a replacement waits for the root lock, then starts; at its deadline fails naming the root` | red |
| workspace-tooling → Recovery after a killed test run | Test server killed | correlia_server/test/db/kill_recovery_test.dart | `after SIGKILL the next run in the same root passes and leaves no postmaster` | red |
| workspace-tooling → Local passwords on a fresh clone | Fresh clone | tool/test/setup_test.dart (unit); fresh clone in task 9.3 | `creates development and test sections when the file is missing` | green |
| workspace-tooling → Local passwords on a fresh clone | Existing file without a test section | tool/test/setup_test.dart | `a file without a test section fails naming file and section, unchanged` | green |
| workspace-tooling → Code generation is current | Stale generated code | tool/test/generated_test.dart | `a stale generated file fails naming it` | red |
| workspace-tooling → Code generation is current | Current generated code on a clean clone | tool/test/generated_test.dart; fresh clone in task 9.3 | `current code passes and the checkout is unchanged` | red |

## 1. Workspace scaffold and pinned toolchain

- [x] 1.1 Generate the Serverpod 4.1.0 fullstack template (database and webapp; no auth, Redis or website) in
  the scratchpad with the pinned CLI, and bring it into the repository root trimmed per S1/S2: no greeting
  example, Serverpod Cloud storage, `docker-compose.yaml`, `.github/workflows` or Dockerfile, and none of the
  template root `.gitignore` rules that hide `.claude/`, `.agents/`, `.codex/` or `.mcp.json`. Verify:
  `git status` lists only the new packages, the root `pubspec.yaml` and the intended `.gitignore` additions;
  `git check-ignore .mcp.json .codex/config.toml .claude/skills` prints nothing.
- [x] 1.2 Root pub workspace with `correlia_server`, `correlia_client`, `correlia_flutter` and a new `tool`
  package (`correlia_tool`, depends on `args`); `serverpod_cli: 4.1.0` as a dev dependency of `correlia_server`
  (D2); the shared root `analysis_options.yaml` of D12, included by every package, excluding generated code.
  Verify: `mise exec -- dart pub get` resolves; `mise exec -- dart run serverpod_cli version` (in
  `correlia_server`) prints 4.1.0; `mise exec -- dart analyze --fatal-infos` is clean.
- [x] 1.3 Pin `go = "1.27.3"` and `buf = "1.75.0"` in `mise.toml` (D14); `.gitignore` covers
  `correlia_server/web/app/`, `**/.serverpod/` and `**/config/passwords.yaml`; update the `mise.toml` header
  comment. Verify: `mise install` succeeds and `mise exec -- which dart flutter go buf openspec` prints only
  paths under `~/.local/share/mise` (none under `/mnt/`).

## 2. Tool package: doctor, setup and tasks

- [x] 2.1 Write failing tests `tool/test/doctor_test.dart` (tool resolver injected; Linux paths and pinned
  versions; wrong `serverpod_cli` version names tool, pinned and found; a fake Windows `dart` placed earlier
  on PATH loses to the pinned one, run through `mise exec`) and `tool/test/task_definitions_test.dart` (scans
  `mise.toml` and `tool/` for `/mnt/`, `wslpath`, `.exe`, `cmd.exe`). Verify they fail because `doctor` does
  not exist yet.
- [x] 2.2 Implement `tool doctor`; verify the 2.1 tests pass and flip their four rows green.
- [x] 2.3 Write failing `tool/test/setup_test.dart` (missing file → random `development` and `test` passwords
  written; existing file never overwritten; a file without `test` → non-zero exit naming file and section,
  bytes unchanged). Implement `tool setup` (D13); verify the tests pass and flip the two setup rows green
  (the fresh-clone half of "Fresh clone" is task 9.3).
- [x] 2.4 mise tasks `doctor`, `setup`, `analyze` (`dart analyze --fatal-infos` over the workspace and
  `flutter analyze` for the console), `format` and `generate` (`dart run serverpod_cli generate` in
  `correlia_server`), each `run` one line; `test`, `test:all`, `check` and `run` depend on `setup`. Verify:
  `mise tasks` lists them; the task-definitions test still passes.

## 3. Test tier selection

- [ ] 3.1 Write failing `tool/test/test_command_test.dart`: unit tests of argument building (no arguments →
  `-P fast`; arguments selecting no tag → `-P fast -x load` plus them; `--tags db`/`-t db` → `-x load` plus
  them; `--tags load` → them only; `all` → `-x load`) and real runs of `dart test --reporter json` over a
  fixture package `tool/test/fixtures/tiers/` with one test per tier, asserting which ran, plus `--tags dbb`
  exiting non-zero. Verify they fail because the `test` command does not exist.
- [ ] 3.2 `correlia_server/dart_test.yaml` declares tags `db`, `e2e`, `plugin`, `load` and the `fast` preset
  (D4); implement `tool test` and the mise tasks `test` and `test:all`. Add a minimal db smoke test
  `correlia_server/test/db/database_smoke_test.dart` (tag `db`, `withServerpod`, runs `SELECT 1`), because the
  template's only db test went with the greeting example (owner, 2026-11-03). Verify the 3.1 tests pass, flip
  the six tier rows green, and check by hand that `mise run test -- --tags db` runs the smoke test (output
  shows it). Amended during apply (owner, 2026-11-03; D4): `dart_test.yaml` also declares `integration` and
  the `fast` preset excludes it; a fast tool test asserts every `withServerpod` call under
  `correlia_server/test/` passes a tier tag; after the run `tool test` stops the shared cluster
  `.serverpod/test/` by data directory when its `postmaster.pid` exists (unit test with a fake stopper, and
  by hand: no postmaster of that root after `mise run test -- --tags db`). Group 5 is applied before group 4,
  so fast server tests exist before `check` runs them.

## 4. Generated-code check

- [ ] 4.1 Write failing `tool/test/generated_test.dart` against a temporary copy of the repository: current
  code passes and the copy's `git status` is unchanged; a deliberately edited generated file fails naming it.
  Verify they fail because `generated` does not exist.
- [ ] 4.2 Implement `tool generated` per D5 (self-contained temporary workspace: own root manifest listing
  server and client, copied `pubspec.lock`, generator inputs without `.dart_tool`, `build` or package config,
  `dart pub get --offline`, pinned generator, diff). Verify the 4.1 tests pass and flip the two generation
  rows green (the clean-clone half is task 9.3).
- [ ] 4.3 Write failing `tool/test/check_test.dart` (a fixture package with an unused local fails the analyze
  step naming file and lint), then set `check` per D6 in order: `openspec validate --all --strict`, `doctor`,
  `analyze`, `dart format --output=none --set-exit-if-changed .`, `generated`, fast tests of server and tool,
  `flutter test` for the console. Verify the test passes, its row is green, and `mise run check` exits 0.

## 5. Process roles (fast tier)

- [ ] 5.1 Write failing `correlia_server/test/unit/process_options_test.dart`: `--process-role` values and the
  default `all`; an unknown role and an unknown option are errors naming the value and valid roles; Serverpod
  `--role` other than `monolith` is rejected; Serverpod's own options pass through unchanged (production mode
  with role `api`); the option list equals the names in Serverpod's `CommandLineArgs` (D1 risk). Verify they
  fail because `ProcessOptions` does not exist.
- [ ] 5.2 Implement `ProcessOptions` (sealed result, exit 2 on error, `--process-role` removed before
  Serverpod); verify 5.1 passes and flip "Production mode with a role" green.
- [ ] 5.3 Write failing `correlia_server/test/unit/role_runtime_test.dart` with fake subsystems: only the
  role's subsystems start; a failing start names the subsystem; one shutdown callback registered before the
  first start stops started subsystems one at a time in reverse order; a failing stop is logged with its name,
  the others still stop, and a combined error naming every failure is rethrown (D7). Also
  `startup_state_test.dart`: the startup indicator is unhealthy until all role subsystems started and the
  callback is registered (D17); and `test_mode_switches_test.dart`: `CORRELIA_TEST_CONSOLE_DIR`,
  `CORRELIA_EXIT_ON_STDIN_CLOSE` and `CORRELIA_TEST_ROOT_LOCK` are ignored outside run mode `test`.
- [ ] 5.4 Implement `Subsystem`, the role registry, `RoleRuntime` (single `experimental.shutdownTasks`
  callback), the Correlia startup indicator through `HealthConfig.additionalStartupIndicators`, and the
  test-mode stdin-EOF watch and root lock (D16). Wire `bin/main.dart`. Verify 5.3 passes and flip "Subsystem
  fails to start" green.

## 6. Console subsystem and placeholder console

- [ ] 6.1 Placeholder Flutter web page in `correlia_flutter` with a failing widget test
  `correlia_flutter/test/placeholder_page_test.dart` (renders the product name and "console coming in M2" or
  similar), then the page; verify `mise exec -- flutter test` in `correlia_flutter` passes.
- [ ] 6.2 `ConsoleSubsystem` (roles `api`, `all`) serving `web/app`, or `CORRELIA_TEST_CONSOLE_DIR` in test
  mode (D10); 503 page naming `mise run build:web` plus a startup warning when `index.html` is missing (D15);
  mise task `build:web`. Fast test `correlia_server/test/unit/console_subsystem_test.dart` for the 503 page and
  the test-mode directory. Verify it passes and `mise run build:web` produces `correlia_server/web/app/index.html`.

## 7. Database tier

- [ ] 7.1 Write failing `correlia_server/test/db/postgres_isolation_test.dart` (decoy: a Dart `ServerSocket` on a
  loopback port and a Unix socket `.s.PGSQL.<port>` in a temp dir outside the root, both recording accepts;
  `SHOW data_directory` and `SHOW unix_socket_directories` inside `.serverpod/test/`), `startup_gate_test.dart`
  (in-process Serverpod with a gated fake subsystem: `/startupz` 503 until released, then 200),
  `shutdown_order_test.dart` (stop callback runs before the pool closes; a failing stop reports a failed
  shutdown, run with `exitProcess: false`) and `kill_recovery_test.dart` (child server in
  `.serverpod/test-kill/` killed with SIGKILL, rerun passes, no process whose command line names that data
  directory remains). Verify they fail for the right reason.
- [ ] 7.2 Make them pass (fixture setup, test config for the cluster roots of D8); flip their four rows green.
  Verify with `mise run test -- --tags db`, which must report these tests and no untagged one.

## 8. End-to-end tier

- [ ] 8.1 Harness in `correlia_server/test/support/`: spawn the real entry point with `SERVERPOD_*` ports and
  `<root>/pgdata`, `CORRELIA_EXIT_ON_STDIN_CLOSE=1`, `CORRELIA_TEST_ROOT_LOCK=<root>/owner.lock`; keep its
  stdin open; capture the last 200 output lines; poll `/startupz` against an injected deadline (60 s default);
  stop with SIGTERM and an injected 30 s deadline, then SIGKILL; delete the root only after exit with no
  `postmaster.pid`. Settle the open question on port discovery here and note it in design.md Open Questions.
- [ ] 8.2 Write failing `roles_e2e_test.dart`, `health_e2e_test.dart`, `shutdown_e2e_test.dart`,
  `cluster_roots_e2e_test.dart`, `interrupted_run_e2e_test.dart` (kill only the harness process, run as its own
  subprocess, twice, then complete) and `root_handoff_e2e_test.dart` (previous child held in shutdown by a
  test-mode gate, replacement started at once; waits, then starts; with a short deadline, fails naming the
  root). Verify they fail for the right reason.
- [ ] 8.3 Make them pass; flip the remaining e2e rows green. Verify with `mise run test -- --tags e2e`.

## 9. Agent configs, docs and integration checks

- [ ] 9.1 Add the Serverpod MCP (`mise exec -- dart run serverpod_cli mcp-server` from `correlia_server`) to
  `.mcp.json` and `.codex/config.toml`; check OMP lists it from `.mcp.json` and write `.omp/mcp.json` only if
  it does not (D9). Update AGENTS.md's Testing section (tasks now exist: `mise run test`, `test:all`, tiers,
  cluster roots) and the `.codex/config.toml` comment. Verify: Claude's `/mcp` and OMP both show `serverpod`.
- [ ] 9.2 [evidence] `mise run check` and `mise run test:all` pass in this checkout, with the db and e2e tests
  reported by name → evidence/check-and-test-all.txt
- [ ] 9.3 [evidence] Fresh-clone check: `git clone` this branch into the scratchpad, then `mise install`,
  `mise run test -- --tags db` (passwords file created, not in `git status`), `mise run check`, `mise run
  test:all`, and `git status --porcelain` empty at the end → evidence/fresh-clone.txt
- [ ] 9.4 [evidence] Linux-only and Postgres-safety checks: `mise exec -- which dart flutter go buf openspec`
  output; processes whose command line names this repository's `.serverpod/` roots, listed before and after
  `test:all` (selected by data-directory path, never by process name; none left after); and `ss -ltn` showing
  `127.0.0.1:5432` still listening after the run (no connection made to it, no signal sent) →
  evidence/linux-and-postgres.txt

## Workflow follow-up

- Pre-ship review (specwright-review), verify, archive, then specwright-finish (`finish: local`, `--no-ff`
  merge, no push).
- Status message to Mastermind, then stop and ask the owner before the next M1 change.
