# 0013. Develop and test inside WSL, with embedded Postgres, in tiers

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: [0010](0010-testing-strategy.md)

## Context

ADR 0010 kept the repository on Windows and ran the server tests in WSL through a runner that synced the
working tree into the WSL filesystem. The owner decided on 2026-11-03 to move the repository itself into
WSL Ubuntu 24.04 (`~/Development/dart/correlia`), with the coding agents (Claude Code, Codex, OMP) running
there too. The server is Linux-only in production, external plugins rely on Linux process semantics
(go-plugin, kill -9 cleanup), and a sync step brings line-ending, permission and copy-cleanup problems of
its own.

The same WSL distro runs the owner's Hindsight memory server, whose PostgreSQL listens on
`127.0.0.1:5432` with a socket in `/tmp`.

## Decision

- **Where:** the repository, the toolchain (mise) and every test run live in WSL, on the Linux filesystem.
  There is no Windows checkout to sync from and no sync runner: `mise run test` runs the tests natively on
  Linux.
- **Tiers** by tag: default (fast unit tests); `db`; `e2e`; `plugin`; `load` (manual, never in the default
  loop).
- **Embedded Postgres only, and never anyone else's:** tests use Serverpod's embedded Postgres in the
  package's own data directory. Nothing a test or a task does may connect to, stop, signal or reuse any other
  PostgreSQL server on the machine, in particular Hindsight's on port 5432; cleanup of a leftover test
  cluster identifies it by its data directory, never by process name.
- **Regression scenarios:** every legacy defect in `docs/research/legacy-audit.md` section 6, and every
  acceptance example in its section 9, becomes a named regression scenario.

Rejected:
- Keeping the repository on Windows with a WSL sync runner (ADR 0010): an extra moving part whose only job
  was to bridge two filesystems.
- Docker/Testcontainers: not needed (see the research).

Reversal cost: low.

## Consequences

- The first milestone proves the embedded Postgres test tiers and their cleanup on Linux; `test:wsl` and the
  sync runner are dropped from its scope.
- Windows remains a product target where an ADR says so (for example the plugin spike gate of ADR 0006); it
  is no longer the development platform.
- CI comes later, when the owner enables GitHub, and runs the same tasks on Linux.
