---
status: advisory
phase: 03-problem-aggregation-and-notification-dispatch
reviewed: 2026-06-09
reviewers: 4
---

# Phase 03 Code Review

## Verdict

Advisory review completed. Accepted high-risk defects were fixed before phase verification. One durable-outbox recommendation was not applied because it conflicts with locked Phase 03 decisions D-04/D-05: v1 intentionally uses an in-process `TaskRunner` after durable incident state, with Celery/Redis/outbox deferred.

## Fixed Before Verification

- Removed secret-derived `config_hash` from public `/plugins` listing.
- Rejected authenticated SMTP configs unless explicit TLS/STARTTLS and certificate validation are enabled.
- Validated notification notes through `DecisionContext` before persistence and redacted unsafe plugin messages.
- Set `incidents.notified_at` on successful notification dispatch records.
- Rejected stale notification tasks when payload `config_hash` differs from the loaded plugin registry hash.
- Preserved rule action order while deduplicating duplicate notification targets.
- Fixed the recovery response test to exercise an actual Icinga2 `UP` payload.

## Remaining Advisory Items

- Durable outbox/retry table: deferred by Phase 03 scope and locked decisions. Future TaskRunner replacement should use a durable queue boundary.
- Plugin loader still uses trusted class paths under `app.plugins.outputs.*`; acceptable for v1 trusted YAML but should become an explicit allow-list before third-party plugin loading.
- SMTP address validation can be tightened beyond bounded non-empty strings in a future hardening pass.

## Verification

- `uv run pytest tests/test_plugin_registry.py tests/test_smtp_output.py tests/test_notification_dispatch.py tests/test_plugins_router.py tests/test_ingress_router.py -q` → 49 passed.
