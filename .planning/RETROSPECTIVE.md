# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — MVP

**Shipped:** 2026-06-09
**Phases:** 4 | **Plans:** 16 | **Tasks:** 34

### What Was Built

- Python 3.14+ uv/FastAPI backend with strict settings, domain contracts, Alembic migrations, PostgreSQL partial-index incident invariant, and Testcontainers verification.
- Icinga2 webhook ingestion with strict normalization, replay-tolerant fingerprints, static YAML topology enrichment, and deterministic YAML rule evaluation.
- Durable PostgreSQL incident aggregation with bounded threshold/window state, first-transition notification dispatch through `TaskRunner`, and trusted SMTP output plugin support.
- Recovery, stale expiration, acknowledgement, manual close, trusted internal `/v1` operator APIs, Prometheus metrics, JSON structured logs, and expanded readiness checks.

### What Worked

- Coarse vertical phases kept the milestone tied to user-visible backend capabilities instead of disconnected horizontal layers.
- PostgreSQL-owned invariants and Testcontainers coverage caught correctness issues that SQLite or unit-only tests would not validate.
- Plugin seams for input, topology, task execution, and output made future integrations possible without generalizing before one concrete implementation existed.
- Safe summary/status surfaces avoided leaking raw YAML, plugin options, recipients, credentials, or exception text.

### What Was Inefficient

- Several planning artifacts evolved independently, so STATE.md accumulated duplicate and stale performance rows before milestone close.
- Milestone audit was not present at close; the artifact audit was clear, but future closes should run `/gsd-audit-milestone` before archive.
- ROADMAP.md started as a free-form milestone instead of versioned milestone headings, which triggered a deprecation warning in the archive CLI.

### Patterns Established

- Keep incident identity as `rule_name + group_key`; object fingerprints and source data are incident content, not uniqueness keys.
- Treat RECOVERY separately from problem aggregation; lifecycle mutations should not trigger threshold notification dispatch.
- Use low-cardinality metrics and allowlisted JSON log keys only.
- Keep trusted operator status APIs compact and secret-free.

### Key Lessons

1. Database invariants should be introduced before aggregation code grows around them.
2. One concrete plugin implementation is enough to prove a seam; broader plugin catalogs can wait.
3. Lifecycle, notification, and observability contracts need explicit failure categories so agents can debug unattended runs.
4. Milestone close should include a real audit artifact before archive to avoid relying only on phase-level verification.

### Cost Observations

- Model mix: not measured in repository artifacts.
- Sessions: multiple GSD phase sessions across 2026-06-08 and 2026-06-09.
- Notable: 16 plans shipped across 4 phases while preserving strict test/type/lint gates and PostgreSQL integration coverage.

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Sessions | Phases | Key Change |
|-----------|----------|--------|------------|
| v1.0 | multiple | 4 | Established coarse vertical MVP phases with phase-local summaries and verification. |

### Cumulative Quality

| Milestone | Tests | Coverage | Zero-Dep Additions |
|-----------|-------|----------|-------------------|
| v1.0 | 250 final gate reported in phase memory | Not measured | Not measured |

### Top Lessons (Verified Across Milestones)

1. PostgreSQL-specific correctness needs Testcontainers-backed integration tests, not SQLite substitutes.
2. Keep ROADMAP.md constant-size after milestone close; archive detailed phase history under `.planning/milestones/`.
