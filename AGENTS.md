# Correlia: agent instructions

Correlia is an event/alert aggregator and correlator. It ingests alerts from monitoring systems
(Icinga2, Prometheus Alertmanager/Thanos first, many more later), normalizes and enriches them into one
canonical versioned event, publishes that event to outputs (NATS first), and correlates events into
incidents that operators work in a Flutter web console.

This is a **from-scratch rebuild** (started 2026-11-03). The earlier Python implementation is on the local
branch `legacy/python` and is a read-only reference.

These instructions are shared by every harness (Claude Code, Codex, OMP). Keep them harness-neutral.

## Where things are

| What | Where |
|---|---|
| Strategy, architecture, roadmap | `openspec/strategy.md`, `openspec/architecture.md`, `openspec/roadmap.md` |
| Detailed 1.0 plan (features per milestone, integration catalog) | `docs/plan/` |
| Architecture decisions | `docs/adr/` (in-force index in `openspec/architecture.md`) |
| Research behind the plan | `docs/research/` (legacy audit, stack, plugins, Testcontainers) |
| Specs and changes | `openspec/specs/`, `openspec/changes/` (OpenSpec, `specwright` schema) |
| Toolchain and tasks | `mise.toml` |

## Stack (decided 2026-11-03)

- Dart, **Serverpod 4.1** (`correlia_server`, `correlia_client`), **Flutter web** console (`correlia_flutter`).
- **PostgreSQL in every run mode.** Local dev and tests use Serverpod's embedded Postgres (`dataPath`).
  There is **no SQLite**: Serverpod requires the same database backend in all run modes.
- Plugins: built-in plugins run in process behind the same interface that external plugins use. External
  plugins are standalone executables in any language, launched by Correlia and spoken to over gRPC (a
  go-plugin-style handshake). See ADRs.
- No Testcontainers: tests use the embedded Postgres.
- **Platform: Linux first** (owner, 2026-11-03; ADR 0014). Windows is not a target: no Windows development
  path, tooling or scripts. CI runs on Linux (`.github/workflows/ci.yml`, job `Linux verification`). Tasks
  must not assume WSL.

## Rules

- **Every change reaches `main` through a pull request** (owner, 2026-11-15). Push only the change branch;
  never push to `main` and never force-push. The `Linux verification` CI check and the required Codex review
  (`@codex review`, requested as `sh1ny`) gate the merge, and the agent merges a ready PR
  (`pr.merge: agent` in `openspec/specwright.yaml`).
- **Legacy is reference, not source.** Read `legacy/python` with `git show legacy/python:<path>` or
  `git log legacy/python`. Never merge, cherry-pick or check it out over `main`. Port invariants, not code.
  Every defect listed in `docs/research/legacy-audit.md` section 6 needs an acceptance scenario showing
  the rebuild does not repeat it.
- **Research about other projects never enters this repo.** Studies of third-party products live in the
  owner's local Mastermind workspace, or in files excluded locally through `.git/info/exclude`. Never commit, push or
  publish them. Never copy third-party code, schemas, templates or provider configs; specs and ADRs state
  Correlia's own decisions in their own words.
- **Decision mode.** `decision_making: autonomous` is set (owner, 2026-11-04; it was `all`): agents take
  scope and design decisions without asking and record them `Chosen by: agent`. A `Chosen by: user`
  decision still goes to the owner before it changes. Never record an agent choice as the owner's.
- Commits: author and committer `Nikolay Bochev <309868+sh1ny@users.noreply.github.com>`, message ends with
  one `Co-authored-by: KintsugiBot <296966193+KintsugiBot@users.noreply.github.com>` trailer.
- Always use the toolchain through mise (`mise run <task>`, `mise exec -- <cmd>`), never a bare
  `dart`/`flutter`/`serverpod` from PATH.

## Testing

- The repository, the toolchain and every test live in **WSL Ubuntu 24.04**, on the Linux filesystem
  (`~/Development/dart/correlia`, ADR 0014). Tests run natively; there is no sync runner.
- Tasks: `mise run test` runs the fast tier only; `mise run test -- --tags db` (or `e2e`, `plugin`, `load`)
  selects a tier; `mise run test:all` runs every tier except `load`; `mise run check` is the gate (validate,
  doctor, analyze, format, generated code, fast and widget tests). `mise run setup` writes the local
  passwords file; `test`, `test:all` and `check` run it first.
- Cluster roots (all under `correlia_server/.serverpod/`, gitignored):
  - `test/`: the shared cluster of the `db` tests, started by `serverpod_test`. It keeps running after a
    run and the next run reuses it. Leave it running; Serverpod repairs it.
  - `test-kill/`: the SIGKILL recovery test's own root.
  - `test-e2e/<test-id>/`: one stable root per e2e test.

  Teardown deletes the `test-kill/` and `test-e2e/` roots once their server has exited.
- e2e children are the real entry point (`bin/main.dart --mode test`), stopped by closing their stdin. On
  SIGTERM, a server whose Postgres is the Serverpod-managed embedded one exits 143: the embedded supervisor
  exits first. Only a server without a data path exits 0 on SIGTERM, as the shutdown e2e test shows.
- Child output goes to a log file, never a pipe. With a pipe, a killed harness kills its child mid-shutdown
  and leaves the child's postmaster running.
- Every `withServerpod` call names its tier tag (`testGroupTagsOverride`), or the fast loop picks it up; a
  `tool` test checks this.
- **Never touch another Postgres.** The owner's Hindsight server runs PostgreSQL in this distro on
  `127.0.0.1:5432` (socket in `/tmp`). Tests and tasks use only their own embedded Postgres; never connect
  to, stop, signal or kill any other, and never match Postgres processes by name.
- Tiers (tags): fast unit tests (no database, the default loop); `db` tests (embedded Postgres through
  `withServerpod`); `e2e` tests (HTTP ingress through to outputs); `plugin` tests (spawn real plugin
  processes); `load` tests (manual, never in the default loop).
- Prove each invariant at the cheapest layer that proves it completely. Correlation and lifecycle state
  machines are tested as pure Dart over in-memory state; the database tests prove concurrency, uniqueness
  and transactional behaviour, which only a real Postgres can show.
- Never wait with arbitrary sleeps. Use completers, injected clocks and short injected durations.
- Hand-written fakes injected through constructors; no mocking package.

## Dart and Flutter code

These rules apply to every agent that writes or changes Dart, including subagents that cannot load skills.
An agent with a Skill tool loads the skills named here; an agent without one reads the skill's `SKILL.md`
directly from `.claude/skills/<name>/SKILL.md`.

- Before writing Dart, read the skills that match the work:
  - Always: `dart-use-pattern-matching`, `dart-write-documentation`, `dart-run-static-analysis`.
  - Tests: `dart-add-unit-test`, `serverpod-testing`; widget tests `flutter-add-widget-test`.
  - Server: `serverpod-overview`, then `serverpod-models`, `serverpod-database`, `serverpod-migrations`,
    `serverpod-endpoints`, `serverpod-webserver` (webhook routes), `serverpod-streams` (live console),
    `serverpod-scheduling` (future calls), `serverpod-auth`, `serverpod-configuration` as the work needs.
  - Console: `serverpod-flutter-frontend`, `flutter-apply-architecture-best-practices`,
    `flutter-build-responsive-layout`, `flutter-setup-declarative-routing`.
  - Plugin SDK / CLIs: `dart-build-cli-app`.
- Prefer the Dart MCP tools (`mcp__dart__*`: analyze, format, run tests, pub) when available; otherwise the
  mise tasks.
- Sealed classes and exhaustive switches for domain states (event status, incident lifecycle, delivery state).
- No `dynamic` in domain code. Raw payloads are `Map<String, Object?>` at the edge only; normalizers turn
  them into typed values and reject unmapped fields loudly. Exception: unknown Alertmanager top-level
  fields are processed and flagged on the raw outcome with a count/hash-only warning; unknown per-alert
  fields and wrong-typed recognised fields remain fatal.

## Specwright notes

- Installed: Specwright 0.39.1 (`openspec/.specwright/VERSION`), which provides the
  `decision_making` setting.
- OpenSpec 1.16.0 (Specwright's pin) is pinned in `mise.toml`; run it only as `mise exec -- openspec`
  (a Linux path under `~/.local/share/mise`), never a Windows `openspec` reached through WSL interop.
- tasks.md markers (0.18.0): `[user]` is a check only the owner makes and ticks; agents never tick or
  delegate it, and verify, archive and merge wait for that tick. `[evidence] … → evidence/<file>` is
  ticked only once that file is present, non-empty and committed with the task.
- **specwright#140 workaround:** `.claude/agents/specwright-implementer*.md` add `ToolSearch, mcp__dart__*`
  to `tools:` so implementers can use the Dart MCP. **Every Specwright update overwrites this; re-apply it
  after each update.** OMP implementers fall back to the mise tasks.
- `finish: pr` since the owner enabled GitHub (2026-11-15): archive on the change branch, then the PR merges.
- Vendored Dart/Flutter/Serverpod skills: provenance in `.claude/skills/UPSTREAM.json`. Same copies in
  `.agents/skills/` for Codex.
