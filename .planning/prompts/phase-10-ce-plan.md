# Invocation

`ce-plan output:md .planning/prompts/phase-10-ce-plan.md`

Plan Phase 10 only; do not implement it. Invoke this prompt only after the Phase 9 Compound Engineering plan has been implemented and verified on the current branch. Produce the normal implementation-ready Compound Engineering markdown artifact under `docs/plans/`, using the current `ce-plan` destination convention if that convention has changed. Preserve the skill's normal interactive scoping, review, and handoff checkpoints.

# Prerequisite gate

Before planning, inspect the current branch's source and tests for the completed Phase 9 contracts: strict allowlisted output-plugin loading, bounded notification envelopes, structured dispatch results, and non-blocking post-commit submission. Also verify the completed Phase 9 plan's documented disposition of plugin-construction, partial-load, and lifecycle behavior where applicable. Phases 5–8 are complete according to `.planning/ROADMAP.md` and `.planning/STATE.md`, but those documents do not prove Phase 9 implementation.

If the current branch does not contain verified Phase 9 behavior and tests, stop and report the unmet prerequisite. Do not speculate about the missing implementation, fold Phase 9 work into the Phase 10 plan, or plan the phases concurrently. If the prerequisite is satisfied, cite the source and test evidence used to pass this gate before continuing.

# Planning objective

Create an implementation-ready plan for **Phase 10: Deployment and Operational Visibility**.

**Goal**: Maintainers can run the compatibility-ready service in containers and operators can observe the new surface safely.

Research the current repository before structuring the plan. Treat this as convergence from a partially implemented operational surface: preserve working settings, health, metrics, logging, and migration behavior; plan the missing deployment artifacts and telemetry gaps rather than replacing established architecture.

# Source hierarchy

Use these sources in this order:

1. `.planning/PROJECT.md` defines durable product decisions, `.planning/REQUIREMENTS.md` defines in-scope contracts, and `.planning/ROADMAP.md` defines phase sequencing, dependencies, and success criteria.
2. Current application source, tests, migration setup, and deployment files are authoritative for implemented behavior and remaining gaps.
3. `.planning/STATE.md` and completed phase summaries or verifications are continuity evidence only. They may establish sequencing history but are not authoritative for current behavior.

If these product sources conflict with one another, surface the discrepancy for clarification rather than silently choosing one. If legacy planning intent conflicts with current code or tests, preserve the requirements and roadmap as product intent, describe the discrepancy, and plan only the implementation or proof still needed to make the tree converge.

# Required coverage

Carry these requirements into the plan without weakening or broadening them:

- **DEP-01**: Maintainers can run Correlia from a Docker image that starts with Alembic migrations and then launches the FastAPI app factory.
- **DEP-02**: Maintainers can run Correlia locally with docker compose using PostgreSQL, Correlia, SMTP capture, environment variables, and read-only config mounts.
- **DEP-03**: The default container runtime uses one Uvicorn worker unless a future durable queue or leader-election design exists.
- **DEP-04**: Maintainers receive `.env.example` and sample `config/rules.yaml`, `config/topology.yaml`, and `config/plugins.yaml` files aligned with Correlia settings.
- **OPS-01**: Operators can observe incident API compatibility requests, config migration failures, incident audit writes, plugin load results, and plugin dispatch results through low-cardinality Prometheus metrics.
- **OPS-02**: Operators can inspect readiness for configured dependencies and plugin categories without exposing secrets or raw payloads.
- **OPS-03**: Operators receive safe structured logs for compatibility mutations, migration failures, audit writes, and plugin behavior without credentials, raw payloads, or unbounded labels.

The plan is complete only when it demonstrates all of these roadmap success criteria:

1. Maintainers can run Correlia from a Docker image that applies Alembic migrations and then launches the FastAPI app factory with one Uvicorn worker by default.
2. Maintainers can run Correlia locally with docker compose using PostgreSQL, Correlia, SMTP capture, environment variables, and read-only config mounts.
3. Maintainers receive `.env.example` and sample `config/rules.yaml`, `config/topology.yaml`, and `config/plugins.yaml` aligned with Correlia settings.
4. Operators can observe incident API compatibility requests, config migration failures, audit writes, plugin load results, plugin dispatch results, dependencies, and plugin categories through low-cardinality metrics and readiness responses.
5. Operators receive safe structured logs for compatibility mutations, migration failures, audit writes, and plugin behavior without credentials, raw payloads, or unbounded labels.

# Confirmed starting state and research anchors

At the time this prompt was authored, the repository had no `Dockerfile`, compose file, `.env.example`, or checked-in `config/` samples. Verify that state rather than assuming it remains true. If artifacts now exist, inspect and plan convergence instead of recreating them.

Start research from these existing runtime and operational boundaries, then follow definitions, references, and call chains into tests:

- `app/main.py` — app factory/lifespan startup and runtime dependency construction.
- `app/config/settings.py` — environment-backed settings, secrets, and config paths.
- `migrations/env.py` — Alembic runtime configuration and database URL handling.
- `app/processing/metrics.py` — Prometheus metric definitions and label choices.
- `app/api/routers/health.py` — liveness/readiness response categories and dependency checks.
- `app/processing/logging.py` — structured logging schema, safe keys, and redaction behavior.

Also inspect compatibility API mutation paths, `scripts/migrate_vigilo_config.py`, incident audit persistence, plugin loading, notification dispatch, and their callers so observability is planned at the actual event boundaries rather than as disconnected counters or logs.

# Required deployment design

The plan must produce a coherent runtime path with:

- A container image whose startup applies Alembic migrations before launching the FastAPI app factory.
- Exactly one Uvicorn worker by default. Do not hide worker multiplication in shell expansion or environment defaults.
- A local compose stack containing PostgreSQL, Correlia, and an SMTP-capture service, with dependency health/order sufficient for a deterministic smoke test.
- Environment-driven secrets. Samples may name secret environment variables but must not contain operational credentials.
- Read-only mounts for operator configuration.
- `.env.example` plus sample rule, topology, and plugin configuration that pass the repository's current strict loaders and align with actual settings names and plugin schemas.
- Explicit migration and app-start failure behavior: migration failure must prevent the app from launching, and readiness must remain false for unavailable required dependencies.

Choose boring, inspectable container startup over a process supervisor or implicit multi-process entrypoint. Plan a runtime smoke scenario that builds the image, starts the stack, observes migration completion, verifies health/readiness and the canonical API surface, exercises SMTP capture where practical, and proves configuration is mounted read-only.

# Required observability and safety analysis

Map low-cardinality metrics, readiness categories, and safe structured logs across these event classes:

- Compatibility mutations on the canonical incident API.
- Config migration failures.
- Incident audit writes.
- Plugin load outcomes.
- Plugin dispatch submission and delivery outcomes, preserving their distinct timing and meaning.
- Required dependency state and configured plugin-category readiness.

Perform an explicit cardinality audit of every existing metric label and every proposed label. In particular, inspect existing `rule_name` and `plugin_name` labels: named labels are not automatically low-cardinality. Determine their bounded domains from real configuration behavior, replace or remove them when they can grow without a small fixed bound, and add tests that prevent regressions. Host, service, incident ID, fingerprint, raw route, exception message, payload-derived values, and other unbounded identifiers must not become metric labels.

For readiness, define stable, bounded categories that reveal whether required dependencies and configured plugin categories are usable without exposing endpoints, credentials, raw config, exception details, or payload data. Preserve the public liveness versus protected readiness contract already established by the application.

For structured logs, use bounded event names and allowlisted fields. Plan proofs that credentials, authorization values, SMTP secrets, database URLs, raw payloads, config bodies, exception strings containing sensitive input, and unbounded labels are absent across success and failure paths.

# Required test and verification planning

Inspect and extend the existing tests at these paths where they are the correct seam:

- `tests/test_migrations.py`
- `tests/test_metrics_api.py`
- `tests/test_health.py`
- `tests/test_structured_logging.py`

Choose any new test path from repository conventions after test discovery; do not invent a parallel test organization. The generated plan must include specific happy-path, boundary, failure-path, and integration scenarios for each feature-bearing unit, including:

- Migration-before-app ordering and app non-start on migration failure.
- One-worker default enforcement.
- Compose startup and dependency readiness.
- Strict-loader validation of every checked-in sample config.
- Environment and mount behavior without secret leakage.
- Each required metric event, stable result categories, and forbidden high-cardinality labels.
- Readiness behavior for healthy, unavailable, misconfigured, and partially failed dependencies or plugin categories.
- Structured-log safety for compatibility mutation, migration, audit, plugin-load, and dispatch success/failure paths.
- An end-to-end deployment/runtime smoke scenario using the real built container and compose stack where the environment permits it, with a deterministic fallback verification clearly identified for constrained CI.

Define verification outcomes and reference the repository's focused-test and quality-gate conventions discovered from the tree; do not include exact shell command recipes in the plan. Separate test-only proof gaps from production behavior gaps, and do not duplicate coverage already present.

# Scope boundaries

Do not introduce a multi-worker default, durable broker or queue, outbox, leader election, long-term raw-event warehouse, LLM core dependency or hot-path processing, webhook-path compatibility facade, or `/api/v1` compatibility facade. Do not broaden plugin namespaces or add notification transports. Deployment and observability must fit the existing single-process, output-plugin-only architecture established by the prerequisite phase.

Write only the CE-native plan artifact. Do not create or continue `.planning/phases/10-*` legacy `CONTEXT`, `RESEARCH`, `PLAN`, `SUMMARY`, or `VERIFICATION` artifacts. Do not run any `gsd-` command, update `.planning/STATE.md`, modify `.planning/ROADMAP.md`, or mark legacy requirement checkboxes. Those tracking changes occur only after the Compound Engineering implementation is complete and verified.
