---
phase: 07-incident-event-audit-trail
reviewed: 2026-06-18T18:45:00Z
depth: standard
severity: warning
max_severity: warning
files_reviewed: 32
files_reviewed_list:
  - app/api/routers/audit.py
  - app/config/settings.py
  - app/domain/audit.py
  - app/main.py
  - app/middleware/classification.py
  - app/persistence/audit.py
  - app/persistence/models.py
  - app/processing/incident_manager.py
  - app/processing/ingress.py
  - app/processing/lifecycle.py
  - migrations/versions/0003_create_incident_events.py
  - tests/conftest.py
  - tests/test_audit_api.py
  - tests/test_audit_persistence.py
  - tests/test_audit_redaction.py
  - tests/test_config_status_api.py
  - tests/test_domain_audit.py
  - tests/test_exposure_config.py
  - tests/test_health.py
  - tests/test_incident_manager.py
  - tests/test_incidents_api.py
  - tests/test_ingress_router.py
  - tests/test_lifecycle_expiration.py
  - tests/test_lifecycle_repository.py
  - tests/test_lifecycle_worker.py
  - tests/test_metrics_api.py
  - tests/test_migrations.py
  - tests/test_plugins_router.py
  - tests/test_rate_limit.py
  - tests/test_security.py
  - tests/test_settings.py
  - tests/test_size_limit.py
findings:
  critical: 0
  warning: 2
  info: 2
  total: 4
status: issues_found
---

# Phase 7: Code Review Report

**Reviewed:** 2026-06-18T18:45:00Z
**Depth:** standard
**Files Reviewed:** 32
**Status:** issues_found

## Summary

Reviewed the full Phase 7 incident-event audit trail implementation across all three plans (07-01 schema/contracts, 07-02 ingress transaction refactor, 07-03 read-only operator API). The implementation is well-structured: the audit table uses server-generated UUIDs, the redactor is audit-owned, the ingress transaction is correctly single-session with post-commit notification submission, the operator API uses router-level auth with bounded projection and cursor pagination, and dependency-boundary tests enforce AUD-03 isolation.

No critical (blocker) issues found. Two warnings identified — one design safety gap in the insert API's type contract that permits unredacted payloads, and one boundary mismatch between unbounded ingress fields and bounded response contracts that can cause transaction-consistency bugs. Two informational findings on test coverage and filter design.

**Recommendation: APPROVE (no blocking issues) — fix warnings before next phase.**

## Warnings

### WR-01: `insert_incident_event` accepts raw `dict` — no type-level redaction enforcement

**File:** `app/persistence/audit.py:513-534`
**Issue:** `insert_incident_event` takes `raw_payload: dict[str, Any]` as a plain dict. The contract requires callers to have already called `redact_payload()` and to pass the redacted output, but the function signature does not enforce this. All six `raw_payload_*` metadata fields are also plain scalars that a caller could populate with fabricated values. Currently the only caller is `app/processing/ingress.py:232-251`, which correctly calls `redact_payload` first — but any future caller (or test helper) can silently skip redaction and persist unscrubbed secrets into `incident_events.raw_payload`.

The function's `None`-checks on metadata fields (lines 545-552) catch missing values but cannot detect a pre-redaction payload passed with hand-rolled metadata.

**Fix:** Change the `raw_payload` parameter (and the six metadata fields) to accept a single `RedactedPayload` dataclass, which is already `frozen=True` and carries the redacted dict plus validated metadata:

```python
# app/persistence/audit.py
async def insert_incident_event(
    session: AsyncSession,
    *,
    event_timestamp: datetime,
    source_id: str,
    fingerprint: str,
    event_type: str,
    severity: str,
    host: str,
    service: str | None,
    incident_ids: list[str],
    incident_effect: str,
    decision_summary: dict[str, Any],
    normalized_event: dict[str, Any],
    redacted: RedactedPayload,  # ← single param replaces 7
) -> IncidentEvent:
    event = IncidentEvent(
        ...
        raw_payload=redacted.payload,
        raw_payload_original_byte_length=redacted.original_byte_length,
        raw_payload_stored_byte_length=redacted.stored_byte_length,
        raw_payload_truncated=redacted.truncated,
        redaction_version=redacted.redaction_version,
        redacted_path_count=redacted.redacted_path_count,
        raw_payload_hmac=redacted.payload_hmac,
    )
```

Then update the ingress callsite (`app/processing/ingress.py:232-251`) to pass `redacted=redacted` instead of the seven unpacked fields. This makes it structurally impossible to insert an unredacted payload.

---

### WR-02: Unbounded `source_id`/`host`/`service` at ingress violates bounded response contracts — causes 500 with committed side effects

**Files:** `app/domain/events.py:42-45`, `app/domain/rules.py:131-136`, `app/domain/audit.py:128-136`, `app/processing/ingress.py:269-310`, `app/api/routers/audit.py:86-118`
**Issue:** `NormalizedEvent` constrains `source_id`, `host`, and `service` with `min_length=1` but no `max_length`:

```python
# app/domain/events.py:42-45
source_id: Annotated[str, Field(min_length=1)]
host: Annotated[str, Field(min_length=1)]
service: Annotated[str, Field(min_length=1)] | None = None
```

These unbounded values flow into two downstream contracts that both use `BoundedString` (max_length=256):

1. **Ingress response (transaction-consistency bug):** After the audit/incident transaction commits at `app/processing/ingress.py:253`, `process_payload` constructs an `IngressDecisionEnvelope` (`app/domain/rules.py:129-167`) with `source_id: BoundedString | None`, `host: BoundedString | None`, `service: BoundedString | None`. If any value exceeds 256 chars, Pydantic raises `ValidationError` — the client receives a 500 despite the incident and audit row having already been durably committed. There is no rollback mechanism.

2. **Audit read endpoint (500 on query):** `_audit_event_response` (`app/api/routers/audit.py:86-118`) constructs `AuditEventResponse` whose fields are typed as `BoundedString` (max 256). The `except ValueError` at line 123 only wraps `list_incident_events`, not the response mapping — a `PydanticValidationError` (a `ValueError` subclass) from the mapper escapes unhandled as 500.

The same boundary mismatch applies to `AuditDecisionSummary.rule_name` and `decision_reason` (typed as `BoundedString | None`, max 256), which are populated from `_safe_rule_name` (`app/processing/ingress.py:524`) reading directly from the rule-decision dict without length validation.

In practice, current Icinga2 payloads produce short composite identifiers (e.g., `icinga2:service:web-01:http`), so this is unlikely to trigger today. But a future input plugin or topology-enrichment tag injection could produce a long `source_id`, and the failure mode is a 500 response with committed side effects — the worst kind of client-facing inconsistency.

**Fix:** Align bounds at the write boundary. Add `max_length` to `NormalizedEvent` field annotations so accepted events are rejected before any durable side effects:

```python
# app/domain/events.py
source_id: Annotated[str, Field(min_length=1, max_length=256)]
host: Annotated[str, Field(min_length=1, max_length=256)]
service: Annotated[str, Field(min_length=1, max_length=256)] | None = None
```

This prevents unbounded data from entering the database and guarantees both the ingress response and audit read path will never fail on field-length validation. If longer source identifiers are needed in the future, increase the `NormalizedEvent` bound first, then propagate to `IngressDecisionEnvelope` and `AuditEventResponse` simultaneously.

---

## Info

### IN-01: Recovery ingress tests lack audit row assertions (D-14 / AUD-02 coverage gap)

**File:** `tests/test_ingress_router.py:449-526`
**Issue:** The 07-02 plan requires ingress tests to "assert audit row content and row counts for problem, below-threshold, replay, already-notified, recovery-with-incident, recovery-noop, and no-matching-rule accepted paths." The problem path (`test_icinga2_problem_webhook_aggregates_and_submits_notifications_once`, line 330) correctly asserts `incident_events` count == 4. The no-rule-engine noop path (`test_no_rule_engine_accepted_event_writes_noop_audit_row`, line 1314) asserts count, `incident_effect`, `incident_ids`, and `decision_summary`.

However, the two recovery tests (`test_recovery_routes_to_lifecycle_without_problem_upsert`, line 449; `test_recovery_response_contains_lifecycle_outcome_without_notification`, line 503) verify only the HTTP response body and the incident's `status == "RESOLVED"`. Neither queries `incident_events` to assert:
- Exactly one audit row was inserted for the recovery event
- `incident_effect` is `"resolved"` (not `"none"`)
- `incident_ids` contains the resolved incident's UUID
- `decision_summary.decision_kind` is `"recovery"`
- `decision_summary.recovery_resolution` matches the lifecycle effect

**Fix:** Add audit row assertions to both recovery tests:

```python
# After existing assertions in test_recovery_routes_to_lifecycle_without_problem_upsert
assert (await _count_audit_rows(session_factory)) == 1
async with session_factory() as session:
    row = (
        await session.execute(
            sa.text(
                "SELECT incident_effect, incident_ids, decision_summary "
                "FROM incident_events"
            )
        )
    ).mappings().one()
assert row["incident_effect"] == "resolved"
assert str(incident.id) in row["incident_ids"]
assert row["decision_summary"]["decision_kind"] == "recovery"
assert row["decision_summary"]["recovery_resolution"] == "resolved"
```

---

### IN-02: `AuditEventListFilters` uses `BoundedString` for filter values, not just response fields

**File:** `app/domain/audit.py:87-88`
**Issue:** `AuditEventListFilters` reuses `BoundedString` (max_length=256) for `fingerprint`, `source_id`, `host`, and `service` filter parameters. This is consistent with the response contract but means a filter query for a value longer than 256 chars returns a 422 rather than an empty result set. This is fine — it's a strict-by-design choice — but worth noting for future maintainers that the filter bounds mirror the response bounds, not the storage bounds.

**Fix:** No change needed. Documented for awareness.

---

## Structural Findings (fallow)

No structural findings were provided for this review.

## Verification Evidence

- **Transaction safety (D-01/D-02):** `IncidentManager.apply_problem` (`app/processing/incident_manager.py:78-183`) and `LifecycleManager.resolve_for_event` (`app/processing/lifecycle.py:71-100`) contain no `session.commit()` calls. Ingress owns the single commit at `app/processing/ingress.py:253`.
- **Post-commit notifications (D-03):** Notification submission at `app/processing/ingress.py:256-268` occurs after the `async with self._sessionmaker()` block closes (after commit).
- **Observational isolation (AUD-03):** `test_processing_ingress_dependency_boundaries_for_audit` (`tests/test_ingress_router.py:922-968`) inspects source code of `incident_manager`, `lifecycle`, `persistence.incidents`, and `lifecycle_worker` modules and asserts none contain `app.persistence.audit`, `app.domain.audit`, or `IncidentEvent`.
- **Operator mutation no-audit:** `tests/test_incidents_api.py` asserts `incident_events` row count remains zero after ACK/CLOSE paths.
- **Lifecycle sweep no-audit:** `tests/test_lifecycle_expiration.py` truncates `incident_events` and asserts zero count after expiration sweeps.
- **Auth/rate-limit inheritance (D-16):** Router uses `dependencies=[Security(require_operator_token)]` (`app/api/routers/audit.py:32-35`). `ROUTE_CLASS_PREFIXES` includes `("/v1/incident-events", "operator")` (`app/middleware/classification.py:8`). Rate-limit test at `tests/test_rate_limit.py::test_incident_events_inherit_operator_rate_limit`.
- **Server-generated UUID (D-13):** Migration uses `server_default=sa.text("gen_random_uuid()")` (`migrations/versions/0003_create_incident_events.py:28`). ORM model uses `server_default=func.gen_random_uuid()` (`app/persistence/models.py:64-67`). `insert_incident_event` never sets `id`.
- **Read-time redaction (D-08):** Both the repository (`_row_to_audit_event_list_row` at `app/persistence/audit.py:640`) and the router (`_audit_event_response` at `app/api/routers/audit.py:86`) apply `redact_normalized_event_message_tags` idempotently.
- **Bounded projection (D-15):** `_AUDIT_LIST_COLUMNS` (`app/persistence/audit.py:489-510`) selects only bounded message/tags from `normalized_event` via JSONB path extraction; `raw_payload` is never selected.
- **HMAC key isolation:** `Settings._require_audit_hmac_key` (`app/config/settings.py:96-108`) rejects blank keys and keys equal to `operator_api_token` or `ingress_api_token`.
- **Cursor pagination (D-10):** `decode_audit_cursor` (`app/persistence/audit.py:443-476`) catches `UnicodeDecodeError`, `binascii.Error`, `json.JSONDecodeError`, `KeyError`, `TypeError`, and naive-datetime `ValueError`.

---

_Reviewed: 2026-06-18T18:45:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
