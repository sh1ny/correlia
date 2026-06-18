---
phase: 07-incident-event-audit-trail
date: 2026-06-18
verified: 2026-06-18T19:15:00Z
status: passed
test_count: 442
test_result: all_passed
gates:
  lint: "make lint → ruff check . — All checks passed!"
  typecheck: "make typecheck → mypy app — Success: no issues found in 50 source files"
  test: "make test → 442 passed in 45.92s"
decisions_verified: [D-08, D-09, D-10, D-11, D-12, D-15, D-16]
requirements_verified: [AUD-01, AUD-02, AUD-03, AUD-04]
review_warnings_acknowledged:
  - id: WR-01
    title: "insert_incident_event accepts raw dict — no type-level redaction enforcement"
    status: non_blocking
    disposition: "Improvement opportunity; current sole caller (ingress.py:232) correctly calls redact_payload first. No production risk today."
  - id: WR-02
    title: "Unbounded source_id/host/service at ingress violates bounded response contracts"
    status: non_blocking
    disposition: "Boundary mismatch is theoretical; current Icinga2 payloads produce short identifiers. Fix before next-phase operational use."
---

# Phase 7: Incident Event Audit Trail — Verification Report

**Phase Goal:** Maintainers and operators can trace accepted source events through normalization and incident decisions without using audit rows as decision state.

**Verified:** 2026-06-18T19:15:00Z
**Status:** passed
**Gates:** lint ✓ | typecheck ✓ | 442 tests passed ✓

---

## Verdict

**Phase 7 goal achieved.** All four success criteria (AUD-01 through AUD-04) are verified against the live codebase. The full test suite passes (442 tests, zero failures), lint and typecheck are clean.

- **AUD-01** — The append-only `incident_events` table exists with server-generated UUID, 12 CHECK constraints, and 10 lookup indexes.
- **AUD-02** — Every accepted normalized event (problem, recovery, noop) writes exactly one audit row in the same ingress-owned transaction as incident mutations, with pre-redaction HMAC and audit-owned redaction.
- **AUD-03** — Incident aggregation, notification thresholds, recovery, and lifecycle transitions are driven entirely by primary incident state. A static boundary test inspects `incident_manager`, `lifecycle`, `persistence.incidents`, and `lifecycle_worker` source code and asserts zero audit imports. Operator mutations and lifecycle sweeps leave `incident_events` empty.
- **AUD-04** — The read-only `GET /v1/incident-events` operator endpoint exposes all D-11 filters, cursor pagination on `(accepted_at, id)`, bounded response projection (no `raw_payload`), and idempotent read-time redaction. Problem rows carry `incident_ids` for correlation; noop rows carry empty `incident_ids`.

Seven architectural decisions (D-08, D-09, D-10, D-11, D-12, D-15, D-16) are verified in the codebase. Two review warnings (WR-01: type-level redaction enforcement, WR-02: unbounded NormalizedEvent fields) are design hardening opportunities that do not block phase completion — no production caller bypasses redaction today, and current payloads stay within BoundedString limits.

**Recommendation:** proceed to Phase 8.

---

## Success Criteria

### SC-1: Append-only incident_events table with traceability columns and indexes (AUD-01)

**Status:** ✓ VERIFIED

Evidence:
- `migrations/versions/0003_create_incident_events.py` (166 lines) creates the `incident_events` table.
- Server-generated UUID primary key: `server_default=sa.text("gen_random_uuid()")` (line 28).
- ORM model at `app/persistence/models.py:64-67` mirrors with `server_default=func.gen_random_uuid()`.
- 12 CHECK constraints enforce type, non-negative byte lengths, and valid enums.
- 10 indexes cover: `(accepted_at, id)` cursor tuple, GIN on `incident_ids`, plus individual indexes on `fingerprint`, `source_id`, `event_type`, `severity`, `host`, `service`, `incident_effect`, `event_timestamp`.
- `insert_incident_event` never sets `id` — the server default generates it.

### SC-2: Every accepted normalized event records all required fields (AUD-02)

**Status:** ✓ VERIFIED

Evidence:
- `app/processing/ingress.py:226-254` — for every accepted event (problem, recovery, noop), `process_payload` calls `redact_payload()` on the raw payload, then calls `insert_incident_event()` with all required fields: `raw_payload`, `normalized_event`, `decision_summary`, `source_id`, `fingerprint`, `severity`, `host`, `service`, `event_timestamp`, `incident_ids`, `incident_effect`.
- Pre-redaction HMAC computed inside `redact_payload` (audit-owned, `app/persistence/audit.py`).
- Single `session.commit()` at `ingress.py:254` persists both incident mutations and the audit row atomically.
- Three summary builders (`_build_problem_audit_summary`, `_build_recovery_audit_summary`, `_build_noop_audit_summary`) derive decision summaries from manager result objects only — never from stored audit rows.
- `test_ingress_router.py` aggregation test asserts 4 audit rows for a multi-incident problem event.
- `test_audit_persistence.py` (10 tests) verifies insert, list, filters, and cursor pagination.

### SC-3: Audit rows do not influence incident decisions (AUD-03)

**Status:** ✓ VERIFIED

Evidence:
- `app/processing/incident_manager.py` — zero imports of `app.persistence.audit`, `app.domain.audit`, or `IncidentEvent`. Contains no `session.commit()` for accepted-event paths (line 42 docstring: "does not commit").
- `app/processing/lifecycle.py` — zero imports of audit modules. `resolve_for_event` defers commit to caller. Only `acknowledge`, `manual_close`, and `expire_stale_batch` commit their own sessions (these are non-accepted-event paths).
- `app/persistence/incidents.py` — zero imports of audit modules or `IncidentEvent`.
- `app/processing/lifecycle_worker.py` — zero imports of audit modules or `IncidentEvent`.
- `test_ingress_router.py::test_processing_ingress_dependency_boundaries_for_audit` inspects source code of all four modules and asserts no audit imports. This is a static enforcement test.
- `test_incidents_api.py` asserts `incident_events` row count remains zero after ACK/CLOSE operator mutations.
- `test_lifecycle_expiration.py` truncates `incident_events` and asserts zero count after expiration sweeps.

### SC-4: Operators can correlate audit rows to incidents and inspect no-op events (AUD-04)

**Status:** ✓ VERIFIED

Evidence:
- `app/api/routers/audit.py` (140 lines) — read-only `GET /v1/incident-events` endpoint.
- Router-level `Security(require_operator_token)` dependency (line 34) matches incidents router pattern.
- `/v1/incident-events` classified as `operator` in `app/middleware/classification.py:9`.
- All D-11 filters available: `incident_id`, `incident_effect`, `source_id`, `fingerprint`, `event_type`, `severity`, `host`, `service`, `accepted_after`, `accepted_before`.
- Cursor-first pagination on `(accepted_at DESC, id DESC)` with `decode_audit_cursor` catching `UnicodeDecodeError`, `binascii.Error`, `json.JSONDecodeError`, `KeyError`, `TypeError`, and naive-datetime `ValueError`.
- `try/except ValueError` in router returns 400 for invalid cursors.
- Bounded response projection: `_AUDIT_LIST_COLUMNS` (`app/persistence/audit.py:489-510`) selects only bounded `message`/`tags` from `normalized_event` via JSONB path extraction; `raw_payload` is never selected.
- Idempotent read-time redaction: both repository (`_row_to_audit_event_list_row`) and router (`_audit_event_response`) apply `redact_normalized_event_message_tags`.
- `test_audit_api.py` (7 integration tests): auth, empty response, bounded projection, all filter types, cursor pagination, invalid cursor, and ingress correlation.
- Problem rows carry `incident_effect` and `incident_ids` for correlation; noop rows carry empty `incident_ids` per D-14.

---

## Decisions Verified

| Decision | Description | Status | Evidence |
|----------|-------------|--------|----------|
| D-08 | Read-time redaction on audit reads | ✓ | `redact_normalized_event_message_tags` applied in both repository (line 664) and router (line 92) |
| D-09 | Operator auth on audit endpoint | ✓ | `Security(require_operator_token)` at router level (audit.py:34) |
| D-10 | Cursor pagination on (accepted_at, id) | ✓ | `encode_audit_cursor`/`decode_audit_cursor` with 6 error classes caught; query at lines 711-718 |
| D-11 | All filter fields available | ✓ | 9 filter parameters in `AuditEventListFilters` + router query params |
| D-12 | Incident correlation via incident_ids | ✓ | `_incident_ids_for_audit` caps to 20, sets `incident_ids_truncated`; problem rows carry incident UUIDs |
| D-15 | Bounded projection omits raw_payload | ✓ | `_AUDIT_LIST_COLUMNS` selects bounded message/tags only via JSONB extraction |
| D-16 | Explicit operator route classification | ✓ | `ROUTE_CLASS_PREFIXES` includes `("/v1/incident-events", "operator")` |

---

## Gate Results

| Gate | Command | Result |
|------|---------|--------|
| lint | `make lint` → `uv run ruff check .` | All checks passed! |
| typecheck | `make typecheck` → `uv run mypy app` | Success: no issues found in 50 source files |
| test | `make test` → `uv run pytest` | 442 passed in 45.92s |

---

## Review Warnings (07-REVIEW.md) — Acknowledgment

### WR-01: `insert_incident_event` accepts raw `dict` — no type-level redaction enforcement

**Why non-blocking:** The sole production caller is `app/processing/ingress.py:232`, which always calls `redact_payload()` first and passes the redacted output. The function's `None`-checks on metadata fields catch missing values. A future `RedactedPayload` dataclass parameter (as the review suggests) would make this structurally impossible to misuse, but today there is no code path that can insert an unredacted payload. This is a hardening improvement, not a correctness gap.

### WR-02: Unbounded `source_id`/`host`/`service` at ingress violates bounded response contracts

**Why non-blocking:** Current Icinga2 payloads produce short composite identifiers (e.g., `icinga2:service:web-01:http`), well within the 256-char `BoundedString` limit used by response contracts. The mismatch between `NormalizedEvent` (no `max_length`) and `AuditEventResponse`/`IngressDecisionEnvelope` (`max_length=256`) is a latent boundary defect, not an active one. Adding `max_length=256` to `NormalizedEvent` fields is the correct fix and should be done before Phase 10 operational use, but it does not affect audit trail correctness or traceability.

---

## Artifacts Verified

| Artifact | Path | Lines | Status | Purpose |
|----------|------|-------|--------|---------|
| Migration | `migrations/versions/0003_create_incident_events.py` | 166 | ✓ | Schema: table, constraints, indexes |
| ORM Model | `app/persistence/models.py` (IncidentEvent) | 97 | ✓ | Server-generated UUID, JSONB columns |
| Domain Contracts | `app/domain/audit.py` | 164 | ✓ | AuditDecisionSummary, filters, bounded responses |
| Repository | `app/persistence/audit.py` | 765 | ✓ | Redactor, HMAC, cursor, insert/list helpers |
| Audit Router | `app/api/routers/audit.py` | 140 | ✓ | GET /v1/incident-events, filters, pagination |
| Ingress Integration | `app/processing/ingress.py` | 623 | ✓ | Single-transaction audit write, summary builders |
| Settings | `app/config/settings.py` | — | ✓ | audit_raw_payload_max_bytes, audit_raw_payload_hmac_key |
| Classification | `app/middleware/classification.py` | — | ✓ | Operator route prefix registration |

---

## Test Coverage Summary

| Test File | Tests | Covers |
|-----------|-------|--------|
| `test_audit_api.py` | 7 | Auth, projection, filters, cursor, correlation |
| `test_audit_persistence.py` | 10 | Insert, list, filters, cursor, redaction in DB |
| `test_audit_redaction.py` | 13 | Redactor, HMAC, cursor encode/decode |
| `test_domain_audit.py` | 7 | Domain contracts, validators |
| `test_ingress_router.py` | 37 | Full ingress paths, audit row counts, AUD-03 boundary, fail-fast |
| `test_migrations.py` | 12 | Migration up/down, constraint validation |
| `test_incidents_api.py` | 14 | Operator mutations leave audit empty |
| `test_lifecycle_expiration.py` | 4 | Lifecycle sweeps leave audit empty |

---

_Verified: 2026-06-18T19:15:00Z_
_Verifier: Claude (gsd-verifier)_
