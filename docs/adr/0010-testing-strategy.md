# 0010. Testing on Linux through WSL with embedded Postgres, in tiers

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: none

## Context

The repository stays on Windows, and the owner wants tests launched from WSL. Serverpod 4 tests run with
`dart test` and `withServerpod`, which gives each test group its own throwaway database with rollback on
the embedded Postgres. Embedded Postgres binaries exist for Linux x64. Running `pub get` and tests
directly on `/mnt/f` is slow on WSL2.

## Decision

- **WSL runner:** a `mise run test:wsl` task runs the server test suite inside the WSL Ubuntu distro and
  reports the results back. It uses:
  - a Linux toolchain installed by mise;
  - a synced copy of the working tree in the WSL filesystem, so Linux tools never write to the Windows
    checkout.
- **Native runs:** pure-Dart unit tests also run on Windows.
- **Tiers** by tag: default (fast unit tests); `db`; `e2e`; `plugin`; `load` (manual).
- **Regression scenarios:** every legacy defect in `docs/research/legacy-audit.md` section 6, and every
  acceptance example in its section 9, becomes a named regression scenario.

Rejected:
- Docker/Testcontainers: not needed (see the research).
- Running tests on `/mnt/f` directly: slow, and it risks line-ending and permission churn.

Reversal cost: low.

## Consequences

- The first milestone must prove the WSL runner end to end, including embedded Postgres cleanup.
- CI comes later, when the owner enables GitHub, and runs the same tasks on Linux.
