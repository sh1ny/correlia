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

## Rules

- **Nothing is pushed.** `origin`'s push URL is disabled on purpose. Never re-enable it, push, or open a PR
  unless the owner says so in this session.
- **Legacy is reference, not source.** Read `legacy/python` with `git show legacy/python:<path>` or
  `git log legacy/python`. Never merge, cherry-pick or check it out over `main`. Port invariants, not code.
  Every defect listed in `docs/research/legacy-audit.md` section 6 needs an acceptance scenario showing
  the rebuild does not repeat it.
- **Research about other projects never enters this repo.** Studies of third-party products live in the
  owner's local Mastermind workspace, or in files excluded locally through `.git/info/exclude`. Never commit, push or
  publish them. Never copy third-party code, schemas, templates or provider configs; specs and ADRs state
  Correlia's own decisions in their own words.
- **Decisions are the owner's.** `decision_making: all` is set: every change presents all scope and design
  decisions to the owner before writing them. Never record an agent choice as the owner's.
- Commits: author and committer `Nikolay Bochev <309868+sh1ny@users.noreply.github.com>`, message ends with
  one `Co-authored-by: KintsugiBot <296966193+KintsugiBot@users.noreply.github.com>` trailer.
- Always use the toolchain through mise (`mise run <task>`, `mise exec -- <cmd>`), never a bare
  `dart`/`flutter`/`serverpod` from PATH.

## Testing

- Server and integration tests run on **Linux through WSL** (Ubuntu 24.04); the repository stays on Windows.
  The M0 change `bootstrap-workspace` adds `mise run test:wsl` and documents the runner. Until then there
  are no tests.
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
  them into typed values and reject unmapped fields loudly.

## Specwright notes

- Installed: Specwright 0.16.0 (`openspec/.specwright/VERSION`); update to **0.17.0** (the
  `decision_making` setting) before the first `/specwright-roadmap next`.
- **specwright#140 workaround:** `.claude/agents/specwright-implementer*.md` add `ToolSearch, mcp__dart__*`
  to `tools:` so implementers can use the Dart MCP. **Every Specwright update overwrites this; re-apply it
  after each update.** OMP implementers fall back to the mise tasks.
- `finish: local` while nothing is pushed. Switch to `pr` when the owner enables GitHub.
- Vendored Dart/Flutter/Serverpod skills: provenance in `.claude/skills/UPSTREAM.json`. Same copies in
  `.agents/skills/` for Codex.
