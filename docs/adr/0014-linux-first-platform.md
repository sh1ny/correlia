# 0014. Linux-first platform: develop and test in WSL, CI on Linux

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: [0013](0013-develop-and-test-in-wsl.md)

## Context

ADR 0013 moved the repository, the toolchain and every test run into WSL Ubuntu 24.04. It still named
Windows as a product target "where an ADR says so" (the plugin spike gate of ADR 0006), and it left CI for
later.

On 2026-11-03 the owner decided the platform question, in their own words: "We run it entirely on WSL, and
the supported platform is Linux first. If we want Windows, add it on CI. Linux should be CI first also."

The same WSL distro runs the owner's Hindsight memory server, whose PostgreSQL listens on
`127.0.0.1:5432` with a socket in `/tmp`.

## Decision

The owner's decisions (2026-11-03):
- **Supported platform: Linux first.** Correlia (the server, its roles and its external plugins) supports
  Linux. Windows is not a target.
- **Windows, if ever:** it is added as a CI job, by a new ADR, never as a development environment.
- **Development:** the repository, the toolchain (mise) and every test run live in WSL, on the Linux
  filesystem. There is no Windows development path, no Windows-specific tooling and no Windows scripts.
- **CI: Linux first.** Linux is the first, and for now the only, CI target. CI runs the same mise tasks as
  development.

Carried over unchanged from ADR 0013:
- **Native runs:** `mise run test` runs the tests natively on Linux. There is no sync runner.
- **Tiers** by tag: default (fast unit tests); `db`; `e2e`; `plugin`; `load` (manual, never in the default
  loop).
- **Embedded Postgres only, and never anyone else's:** tests use Serverpod's embedded Postgres in the
  package's own data directory. Nothing a test or a task does may connect to, stop, signal or reuse any other
  PostgreSQL server on the machine, in particular Hindsight's on port 5432. Cleanup of a leftover test
  cluster identifies it by its data directory, never by process name.
- **Regression scenarios:** every legacy defect in `docs/research/legacy-audit.md` section 6, and every
  acceptance example in its section 9, becomes a named regression scenario.

Rejected:
- Windows as a development or product platform now (the owner's choice). Supporting it would also mean
  Windows process handling in the plugin host (job objects instead of process groups) and Windows
  loopback TCP for go-plugin.
- Keeping the repository on Windows with a WSL sync runner (ADR 0010): an extra moving part whose only job
  was to bridge two filesystems.
- Docker/Testcontainers: not needed (see the research).

Reversal cost: low for development; medium for adding Windows as a product platform (a CI job plus the
plugin host's Windows process handling).

## Consequences

- WSL is where development happens, while the platform is Linux. Proposed by the agent: mise tasks and
  tests do not depend on WSL (no `/mnt/c` paths, no `wslpath`, no Windows interop), so a plain Ubuntu CI
  runner can run them unchanged.
- The plugin spike gate checks Linux only (ADR 0015 supersedes ADR 0006 for this).
- CI is added by the first change after the owner enables GitHub (D17). It runs `mise run check` and every
  test tier except `load` on Linux. M1 has no CI work.
