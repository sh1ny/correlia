---
phase: 01
slug: foundations-contracts-and-database-invariant
status: verified
threats_open: 0
asvs_level: 1
created: 2026-06-08
updated: 2026-06-08
---

# Phase 01 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| Environment -> Settings | Deployment environment supplies `DATABASE_URL` and config-path values that must validate before readiness. | Runtime configuration; database connection metadata. |
| Service -> PostgreSQL | Readiness and repository code open PostgreSQL connections and execute fixed framework-generated SQL. | Database session handles; incident records. |
| Package registry -> local environment | uv installs approved Python packages locked by project metadata. | Dependency names and lockfile artifacts. |
| Input plugin -> core domain | Future plugins will supply source-derived values to `NormalizedEvent`. | Alert identity, severity, timestamps, tags, message fields. |
| Core processing -> incident debug metadata | Decision facts may be persisted in `DecisionContext`. | Compact explainability envelope; no raw payloads/secrets. |
| Migration config -> PostgreSQL | Alembic receives database URLs from env/CLI without persisting secrets in config files. | Runtime database URL; migration metadata. |
| Application model -> database schema | SQLAlchemy metadata and Alembic migration must stay aligned. | Status/severity values, JSONB fields, partial-index predicate. |
| Test runner -> Docker/PostgreSQL | Testcontainers verifies PostgreSQL-specific invariants. | Disposable PostgreSQL containers and test records. |
| Domain model -> repository | Validated incident facts cross into persistence code. | Incident upsert input and bounded decision context. |
| Repository -> PostgreSQL | SQLAlchemy emits the single atomic write statement. | Operator/source-derived strings as bound values. |
| Internet/client -> `/health` and `/readyz` | Unauthenticated clients can call health endpoints. | Fixed status responses only. |
| API route -> Settings/readiness plumbing | Route dependencies read app state and call database readiness helper. | Settings object and async sessionmaker references. |

---

## Threat Register

| Threat Ref | Threat ID | Category | Component | Disposition | Mitigation | Status | Evidence |
|------------|-----------|----------|-----------|-------------|------------|--------|----------|
| 01-01:T-01-01 | T-01-01 | Tampering | `Settings` | mitigate | Strict pydantic-settings fields, PostgresDsn, literal environment/log-level values, and `extra="forbid"`. | closed | `app/config/settings.py:8-20`; `tests/test_settings.py:25-48`. |
| 01-01:T-01-02 | T-01-02 | Denial of service | `check_database_ready` | mitigate | Readiness executes only fixed `text("select 1")`; API shaping handled by health route. | closed | `app/persistence/database.py:20-24`; `tests/test_settings.py:65-73`; `app/api/routers/health.py:25-31`. |
| 01-01:T-01-03 | T-01-03 | SQL injection | `check_database_ready` | mitigate | No request/env interpolation reaches readiness SQL. | closed | `app/persistence/database.py:20-24`; `tests/test_settings.py:65-73`. |
| 01-01:T-01-04 | T-01-04 | Elevation of privilege | YAML handling | mitigate | No YAML loader exists in app, migration, or test code. | closed | `search yaml\.load\(` over `app`, `migrations`, `tests` returned no matches. |
| 01-01:T-01-SC | T-01-SC | Tampering | PyPI package installs | mitigate | Dependency identities were user-approved and locked by uv. | closed | `01-01-SUMMARY.md:45-57`, `01-01-SUMMARY.md:79-80`, `01-01-SUMMARY.md:115-117`. |
| 01-02:T-01-07 | T-01-07 | Tampering | `NormalizedEvent` | mitigate | Strict model, explicit enums, constrained tags, and timezone validator reject malformed/coerced values. | closed | `app/domain/events.py:10-59`; `tests/test_domain_events.py:24-34`, `tests/test_domain_events.py:67-91`, `tests/test_domain_events.py:103-108`. |
| 01-02:T-01-08 | T-01-08 | Information disclosure | `DecisionContext` | mitigate | Typed bounded envelope rejects raw payloads, secret-shaped keys/values, extra fields, and overlong note values. | closed | `app/domain/incidents.py:46-69`; `tests/test_domain_incidents.py:74-93`, `tests/test_domain_incidents.py:108-145`. |
| 01-02:T-01-09 | T-01-09 | Tampering | `IncidentStatus` | mitigate | Status enum is exactly `OPEN`, `RESOLVED`, `CLOSED`; acknowledgement remains metadata. | closed | `app/domain/incidents.py:12-15`, `app/domain/incidents.py:32-43`; `tests/test_domain_incidents.py:16-29`. |
| 01-02:T-01-10 | T-01-10 | Elevation of privilege | YAML parser safety | mitigate | Domain layer has no YAML parser and no `yaml.load(` matches. | closed | `app/domain/events.py:1-59`; `app/domain/incidents.py:1-80`; `search yaml\.load\(` returned no matches. |
| 01-02:T-01-11 | T-01-11 | SQL injection | Domain layer | accept | Domain code generates no SQL; SQLAlchemy-only persistence is isolated in later plans. | closed | Accepted risk AR-01; route/SQL surface search shows SQL imports only outside `app/domain`. |
| 01-02:T-01-12 | T-01-12 | API exposure | Domain layer | accept | Domain files create no routes or mutation surfaces. | closed | Accepted risk AR-02; route surface search shows `APIRouter` only in `app/api/routers/health.py:10-18`. |
| 01-03:T-01-13 | T-01-13 | Information disclosure | `alembic.ini`, `migrations/env.py` | mitigate | Alembic config stores no real URL; runtime URL comes from CLI `-x database_url=` or validated settings. | closed | `alembic.ini:1-42`; `migrations/env.py:20-29`, `migrations/env.py:52-60`. |
| 01-03:T-01-14 | T-01-14 | Tampering | Incident uniqueness | mitigate | Partial unique index enforces one open incident per `(rule_name, group_key)`. | closed | `migrations/versions/0001_create_incidents.py:80-86`; `tests/test_migrations.py:109-124`, `tests/test_migrations.py:129-180`. |
| 01-03:T-01-15 | T-01-15 | Tampering | Status modeling | mitigate | DB check constraint allows only `OPEN`, `RESOLVED`, `CLOSED`; no `ACKNOWLEDGED`. | closed | `migrations/versions/0001_create_incidents.py:67-70`; `tests/test_migrations.py:95-104`. |
| 01-03:T-01-16 | T-01-16 | Information disclosure | `decision_context` JSONB | mitigate | Schema has only incident-side JSONB `decision_context` with `{}` default; no raw events table. | closed | `migrations/versions/0001_create_incidents.py:43-48`; `app/persistence/models.py:37-39`; `01-03-SUMMARY.md:141-142`. |
| 01-03:T-01-17 | T-01-17 | SQL injection | Alembic/model DDL | mitigate | DDL uses fixed Alembic/SQLAlchemy table, column, constraint, and index names. | closed | `migrations/versions/0001_create_incidents.py:21-86`; `01-03-SUMMARY.md:141-144`. |
| 01-03:T-01-18 | T-01-18 | Elevation of privilege | YAML parser safety | accept | Migration/model/test files do not parse YAML. | closed | Accepted risk AR-03; `search yaml\.load\(` returned no matches. |
| 01-03:T-01-19 | T-01-19 | API exposure | Persistence schema | accept | Persistence schema files create no API endpoints. | closed | Accepted risk AR-04; route surface search shows API routes only in `app/api/routers/health.py:13-18`. |
| 01-04:T-01-20 | T-01-20 | Tampering | `upsert_open_incident` | mitigate | Repository uses PostgreSQL `insert(...).on_conflict_do_update` with OPEN partial-index predicate and no SELECT-then-INSERT path. | closed | `app/persistence/incidents.py:107-163`; `tests/test_incident_repository.py:81-113`, `tests/test_incident_repository.py:460-469`. |
| 01-04:T-01-21 | T-01-21 | SQL injection | Repository values | mitigate | Source-derived values are bound SQLAlchemy values; injection-shaped rule name persists literally and table remains queryable. | closed | `app/persistence/incidents.py:112-125`; `tests/test_incident_repository.py:627-648`. |
| 01-04:T-01-22 | T-01-22 | Information disclosure | `decision_context` persistence | mitigate | Upsert stores `DecisionContext.model_dump(mode="json")`; raw/secret metadata rejects before DB execution. | closed | `app/persistence/incidents.py:94-110`; `tests/test_incident_repository.py:401-410`, `tests/test_incident_repository.py:552-624`. |
| 01-04:T-01-23 | T-01-23 | Denial of service | JSONB affected sets | mitigate | Affected host/service arrays are sorted, deduped, and capped at 100. | closed | `app/persistence/incidents.py:18-19`, `app/persistence/incidents.py:75-89`, `app/persistence/incidents.py:138-148`; `tests/test_incident_repository.py:289-357`, `tests/test_incident_repository.py:360-398`. |
| 01-04:T-01-24 | T-01-24 | Tampering | Severity max | mitigate | Explicit rank CASE expression preserves max severity and prevents downgrade. | closed | `app/persistence/incidents.py:22-29`, `app/persistence/incidents.py:130-136`, `app/persistence/incidents.py:157`; `tests/test_incident_repository.py:209-286`. |
| 01-04:T-01-25 | T-01-25 | Elevation of privilege | YAML parser safety | accept | Repository layer does not parse YAML. | closed | Accepted risk AR-05; `search yaml\.load\(` returned no matches. |
| 01-04:T-01-26 | T-01-26 | API exposure | Repository | accept | Repository files create no auth-independent HTTP mutation endpoint. | closed | Accepted risk AR-06; route surface search shows API routes only in `app/api/routers/health.py:13-18`. |
| 01-05:T-01-05 | T-01-05 | Information disclosure | `/readyz` | mitigate | Readiness returns only `{"status":"ready"}` or `503 {"detail":"not ready"}` and tests exclude secret fragments. | closed | `app/api/routers/health.py:18-33`; `tests/test_health.py:78-92`. |
| 01-05:T-01-06 | T-01-06 | Denial of service | `/readyz` | mitigate | `/readyz` delegates to fixed readiness helper; `/health` remains independent of DB. | closed | `app/api/routers/health.py:13-31`; `tests/test_health.py:49-60`, `tests/test_health.py:63-75`. |
| 01-05:T-01-07 | T-01-07 | Tampering | route surface | mitigate | Phase 1 app registers only the health router; out-of-scope routes are absent. | closed | `app/main.py:31-43`; `app/api/routers/health.py:10-18`; `tests/test_health.py:95-107`. |
| 01-05:T-01-08 | T-01-08 | Elevation of privilege | YAML handling | mitigate | Health routes expose only status strings and do not load YAML. | closed | `app/api/routers/health.py:13-33`; `search yaml\.load\(` returned no matches. |
| 01-05:T-01-09 | T-01-09 | API exposure | incident/operator mutation | accept | Phase 1 creates no incident mutation, ingestion, acknowledgement, close, list, or detail API. | closed | Accepted risk AR-07; `app/main.py:42`; `tests/test_health.py:95-107`. |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-01 | 01-02:T-01-11 | Domain files do not generate SQL; persistence-specific SQLAlchemy code is verified separately in 01-03 and 01-04. | Plan disposition | 2026-06-08 |
| AR-02 | 01-02:T-01-12 | Domain layer exposes typed models only and creates no HTTP routes or auth-independent mutation surfaces. | Plan disposition | 2026-06-08 |
| AR-03 | 01-03:T-01-18 | Migration/model/test files do not parse YAML; no concrete parser surface exists in this plan. | Plan disposition | 2026-06-08 |
| AR-04 | 01-03:T-01-19 | Persistence schema files create no API endpoints. | Plan disposition | 2026-06-08 |
| AR-05 | 01-04:T-01-25 | Repository layer does not parse YAML; no YAML loader call exists. | Plan disposition | 2026-06-08 |
| AR-06 | 01-04:T-01-26 | Repository code creates no HTTP routes or auth-independent mutation endpoint. | Plan disposition | 2026-06-08 |
| AR-07 | 01-05:T-01-09 | Phase 1 intentionally excludes incident/operator mutation, ingestion, acknowledgement, close, list, and detail APIs. | Plan disposition | 2026-06-08 |

*Accepted risks do not resurface in future audit runs.*

---

## Summary Threat Flags

| Source | Finding | Disposition |
|--------|---------|-------------|
| `01-02-SUMMARY.md:98` | Threat surface scan passed: no new routes, auth paths, file access surfaces, schema changes, SQL generation, or YAML loading introduced. | closed |
| `01-03-SUMMARY.md:144` | Threat surface scan passed: no new routes, auth paths, or YAML loading introduced; migration DDL uses fixed names and no user input reaches DDL. | closed |
| `01-05-SUMMARY.md:77` | Fixed readiness error text only, satisfying information-disclosure mitigation. | closed |

---

## Security Audit 2026-06-08

| Metric | Count |
|--------|-------|
| Threats found | 30 |
| Closed | 30 |
| Open | 0 |

Audit note: `gsd-security-auditor` was requested first, but the subagent runtime returned `usage_limit_reached`. The orchestrator completed mitigation verification inline using the same plan-time register and recorded file/line evidence above.

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-06-08 | 30 | 30 | 0 | gsd-secure-phase inline auditor |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-06-08
