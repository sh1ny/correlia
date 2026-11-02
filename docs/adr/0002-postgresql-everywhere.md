# 0002. PostgreSQL in every run mode; embedded Postgres for development and tests

- Status: proposed
- Date: 2026-11-03
- Supersedes: none

## Context

The owner wanted Postgres in production and SQLite for local development. Serverpod's configuration docs
state: "All run modes must use the same database backend … `serverpod generate` fails otherwise."
Serverpod 4 ships embedded PostgreSQL binaries (`dataPath`) for Linux, macOS and Windows x64, so a developer
gets a real Postgres with no Docker. The legacy audit's most dangerous defects were concurrency and ordering
bugs that only a real Postgres reproduces.

## Decision

PostgreSQL 16+ is the only database. Development and tests use Serverpod's embedded Postgres; production
uses an operator-provided Postgres. Correctness may rely on Postgres features: partial unique indexes,
`FOR UPDATE SKIP LOCKED`, advisory locks, `LISTEN/NOTIFY`, JSONB with GIN indexes, declarative partitioning.
No Testcontainers (docs/research/testcontainers-dart.md).

Rejected: SQLite for local development. Not supported by Serverpod across run modes, and SQLite lacks row
locks and isolation levels, so every concurrency test would be meaningless there. Reversal cost: high, since
the claim-based pipeline depends on Postgres locking.

## Consequences

- Owner-confirmed on 2026-11-03 (replaces the original SQLite-for-dev wish).
- Hard-killed test runs can leave an embedded Postgres process running; the test runner must clean up.
- Postgres version floor: 16 (Serverpod 4).
