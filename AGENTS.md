# Repository Guidelines

## Project Overview

Correlia is an API-first infrastructure-alert aggregator: Icinga2 webhooks become topology-enriched incidents in PostgreSQL, with SMTP notifications. REST APIs are the product surface; there is no built-in frontend. Preserve the input, enrichment, output, and task-runner boundaries without adding speculative plugin frameworks or brokers.

## Architecture & Data Flow

- `app/main.py:create_app` is the FastAPI factory. Its lifespan wires settings, compiled configuration, plugin registry, async sessionmaker, processor, task runner, and expiration worker into `app.state`. `app/api/deps.py` exposes typed request dependencies.
- `POST /v1/icinga2/events` authenticates and validates input, then `app/processing/ingress.py` orchestrates Icinga2 normalization, optional topology enrichment, and rule evaluation. Hostname topology matches precede IP-subnet fallback; rules select the first priority-ordered match.
- Ingress owns the transaction covering incident/lifecycle mutation and audit insertion. PostgreSQL enforces one OPEN incident per `(rule_name, group_key)` through a partial unique index. The active `record_problem_incident` path inserts with `ON CONFLICT DO NOTHING`, then locks and merges an existing row on conflict; do not mistake the alternate upsert builder for the application path.
- Eligible notifications are submitted through `TaskRunner` after commit. The dispatcher closes its read session before SMTP and records delivery results in a separate transaction. Recovery updates existing membership; a periodic worker expires stale incidents.
- **Current limitations:** `RuleEngine` still keeps process-local threshold history alongside persisted window state. `AsyncIOTaskRunner` holds tasks in memory: submission is not delivery confirmation, and pending work can be lost on process exit. Do not claim database-only threshold evaluation or durable notification queuing.

## Key Directories

- `app/api/`, `app/middleware/`: HTTP contracts, authentication, dependency access, request limits.
- `app/domain/`, `app/config/`: Pydantic event/incident/decision contracts, settings, YAML validation and compilation.
- `app/processing/`: ingestion orchestration, rule evaluation, lifecycle, notification dispatch, metrics and task execution.
- `app/persistence/`, `migrations/`: SQLAlchemy models, PostgreSQL repositories, audit handling and Alembic schema changes.
- `app/plugins/`: input, topology and output interfaces/implementations; output registry loading is namespace-allowlisted.
- `config/`: sample runtime YAML. `tests/`: unit, API, database, SMTP and deployment checks. `scripts/`: container startup and offline Vigilo conversion.

## Development Commands

Run from the repository root. `mise.toml` owns the shared task interface and pins Python 3.14.7 and uv 0.11.7; `uv.lock` owns Python dependencies:

```sh
mise trust
mise install
mise run setup
mise run ci                 # Linux with Docker/Compose; full suite and smoke once
mise run check:portable     # Windows-compatible development subset only
mise run test:deployment    # Focused smoke; do not add it after ci
mise run format:check
mise run lint
mise run typecheck
mise run audit
mise run run
```

See `CONFIGURATION.md#contributor-verification` for prerequisites, advisory policy, scoped cleanup and the administrator-owned `Linux verification` protection requirement. Verification never updates the lock; intentional dependency changes require a reviewed lock update.

For Compose, copy `.env.example` to `.env` and replace credential placeholders with distinct secrets. For host-side Uvicorn/Alembic, export the settings explicitly: `Settings` does not automatically load `.env`. The sample database hostname `postgres` is Compose-internal, and Compose does not publish a PostgreSQL host port.

## Code Conventions & Common Patterns

- Use typed Python, `snake_case` functions/modules, `PascalCase` classes, and strict mypy-compatible signatures. Ruff targets `py314`; follow surrounding formatting rather than reformatting unrelated files.
- Use Pydantic v2 (`model_validate`, `model_dump`), bounded fields, and strict/extra-forbidden configuration models. Parse YAML with `yaml.safe_load`, validate, then compile; keep evaluation logic in Python.
- Keep routers thin and inject services through FastAPI dependencies. Extend factory injection points for tests instead of introducing global service state.
- Use SQLAlchemy async sessions with explicit transaction ownership. Repositories participating in ingress must not commit independently of the incident-plus-audit transaction. Keep network I/O outside database transactions.
- Submit notification work through `TaskRunner`, not FastAPI `BackgroundTasks` or ad hoc route-level tasks. Keep payloads serializable; never pass ORM objects or sessions across that boundary.
- Preserve sanitized validation errors and generic processing-error responses. Do not expose credentials, raw plugin exceptions, or sender-controlled payloads in logs. Use bounded metric labels, never incident/host/operator identifiers.
- Keep PostgreSQL constraints and Alembic migrations aligned with repository writes. Public API, schema, configuration and lifecycle changes need coordinated caller/documentation updates, not compatibility shims by default.

## Important Files

- `pyproject.toml`, `uv.lock`, `mise.toml`: dependencies, tool settings and shared verification tasks.
- `app/config/settings.py`, `.env.example`, `config/{rules,topology,plugins}.yaml`: environment and YAML contracts. Settings generally use `CORRELIA_`; the database alias is `DATABASE_URL`.
- `app/processing/ingress.py`, `app/persistence/incidents.py`, `app/persistence/audit.py`: transaction and state-ownership boundaries.
- `Dockerfile`, `compose.yaml`, `scripts/container-entrypoint.sh`: non-root container execution, migration-before-serve and one Uvicorn worker.
- `CONFIGURATION.md`: operator setup and converter usage; cross-check commands against live manifests. `CONCEPTS.md` is a glossary, not a specification. `.planning/` and `docs/plans/` contain historical intent; current source establishes implemented behavior. Consult `docs/solutions/` for prior design lessons.
- `scripts/migrate_vigilo_config.py`: offline converter accepting `--rules`, `--topology`, `--plugins`, `--out-dir`, and optional `--report-path`. Use a dedicated output directory; successful conversion replaces generated YAML files. Do not describe per-file promotion as crash-atomic publication.

## Runtime/Tooling Preferences

Use the pinned Python 3.14.7, uv 0.11.7 and single `uv.lock`; no Node/Bun toolchain or second Python dependency lockfile is needed. The container uses the same Python and uv versions. Core dependencies are FastAPI, Pydantic v2, SQLAlchemy 2.x, asyncpg, Alembic and PyYAML.

PostgreSQL is required; never substitute SQLite for persistence correctness tests. `compose.yaml` owns the supported PostgreSQL 16 image; all correctness fixtures consume that image through `postgres_image` while retaining their module-local lifetimes.

Do not commit local secrets: `.env` variants are not currently excluded by `.gitignore`, even though the Docker context excludes them. Authenticated operation requires distinct operator/ingress tokens and a separate audit HMAC key.

## Testing & QA

- Pytest uses `asyncio_mode = "auto"`; API tests use HTTPX `ASGITransport`. Follow the touched module's async convention rather than adding another event-loop owner. `tests/conftest.py` isolates selected environment variables.
- Focused examples: `uv run --locked pytest tests/test_icinga2_input.py` and `uv run --locked pytest tests/test_smtp_output.py`. SMTP tests use a local capture server.
- Database and migration modules use Testcontainers with real PostgreSQL and require Docker. Exercise changed uniqueness, replay, transaction and concurrency behavior against PostgreSQL, not mocks.
- Use `mise run ci` on Linux with Docker/Compose for full verification. Required modes reject missing prerequisites, narrowed selection, skips, xfails and incomplete results. `mise run check:portable` excludes PostgreSQL, deployment and POSIX cases before fixture setup; it is not deployment or release evidence. Report skipped/unexecuted paths explicitly.
- Prefer consumer-visible regression checks over source-string assertions. No numeric coverage threshold is configured; test counts and historical plan results are not proof for the current revision.
