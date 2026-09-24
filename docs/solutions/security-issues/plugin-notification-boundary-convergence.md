---
module: output plugin and notification dispatch boundaries
date: "2026-07-10"
problem_type: security_issue
component: background_job
severity: high
symptoms:
  - "Plugin construction errors could expose option or credential-bearing exception text."
  - "Delivery outcomes were not a bounded, per-plugin, durable incident contract."
  - "Ingress needed proof that slow delivery does not delay accepted events."
root_cause: missing_validation
resolution_type: code_fix
related_components:
  - service_object
  - database
  - tooling
tags:
  - plugin-loading
  - notification-dispatch
  - secret-safety
  - immutable-envelope
  - delivery-results
  - non-blocking-ingress
---

## Problem

Output-plugin construction and notification delivery crossed several trust and lifecycle boundaries without one complete contract. Constructor failures could expose raw details; the notification value was mutable; delivery facts were flattened into general notes; and a later aggregation update or process restart could hide an operator-visible terminal outcome.

The implementation is in [PR #4](https://github.com/sh1ny/correlia/pull/4), which was open when this learning was written. Treat its verification as pending merge verification.

## Symptoms

- Plugin constructors receive validated options directly, so a raw exception can contain sensitive data.
- A plugin could mutate the envelope it received after validation.
- Numbered notification notes did not encode “latest terminal outcome for this plugin” and competed with unrelated note capacity.
- Ingress needed an explicit distinction between task acceptance and completed delivery.

## What Didn't Work

### Passing constructor failures through unchanged

```python
# Unsafe boundary
instance = cls(**entry.options)
```

Configuration validation cannot make arbitrary constructor exception text safe. Do not report the exception, traceback, plugin name, or option values through the loader boundary.

### Treating delivery state as generic notes

Appending `notification.<index>.*` facts to the general note collection cannot express keyed replacement, and trimming generic notes can evict unrelated operator context. It also makes an attempt history and a current-state record indistinguishable.

### Awaiting delivery from ingress

Awaiting `plugin.send_notification()` on the request path ties accepted ingress latency and failure behavior to external delivery. Submission must be observable, but terminal delivery belongs to the background dispatcher.

## Solution

### Use safe, eager plugin construction

`PluginRegistry` eagerly constructs configured outputs and restricts class paths to `app.plugins.outputs.`. It keeps the constructor call but converts every constructor failure to a position-only error with suppressed chaining:

```python
try:
    instance = cls(**entry.options)
except Exception:
    raise ValueError(f"unable to construct output plugin #{position}") from None
```

See `app/plugins/loader.py`. The ordinal is safe diagnostic context; configured names and exception text are not.

### Pass only an immutable envelope

`NotificationEnvelope` is strict, extra-forbidden, frozen, and bounded. Its host/service collections are tuples capped at 100 entries. The output-plugin protocol accepts that envelope only; the dispatcher rebuilds it from persisted incident fields rather than passing ORM objects, raw payloads, config, or decision-context data.

```python
class NotificationEnvelope(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
```

See `app/plugins/interfaces.py` and `app/processing/notification_dispatcher.py`.

### Persist a bounded latest result per plugin

`NotificationResult` and `NotificationDeliveryRecord` are strict frozen domain values in `app/domain/notifications.py`. `DecisionContext.notification_delivery_results` accepts at most 20 unique plugin records. Rule configuration independently limits actions to 20 unique plugins.

Persistence locks the incident row, replaces only the named plugin record, sorts records deterministically, validates the resulting context, and stores a fixed redacted message unless a terminal result message is explicitly allowlisted. Success alone sets `notified_at`.

```python
records_by_plugin[plugin_name] = NotificationDeliveryRecord(
    plugin_name=plugin_name,
    result=_safe_delivery_result(result),
)
```

See `app/persistence/incidents.py`, `app/domain/incidents.py`, and `app/config/rules.py`.

### Preserve records through all incident writes

Aggregation and atomic upsert paths must retain the existing delivery tuple while applying updated incident context. JSONB arrays are normalized to tuples before strict model validation. The canonical incident API exposes the nested record collection after validation.

### Commit before task submission

Ingress commits incident and audit state first. It then submits one task for each unique action. Runner absence, missing pre-submit plugin, and submission exceptions are terminal ingress-owned failures and are persisted in a separate post-commit session. Accepted submission is not persisted as delivery.

The dispatcher validates task/config state, loads the incident, calls the plugin, and records a safe terminal success or failure. The dispatcher awaits the plugin; the **ingress-to-task-runner boundary** is what remains non-blocking.

## Why This Works

The fix makes ownership explicit at each boundary:

1. Constructor secrets cannot become public startup errors.
2. Plugins receive a finite read-only value instead of persistence/config objects.
3. Delivery state is a keyed current snapshot, not an unbounded note or attempt log.
4. Row locking and explicit aggregation preservation prevent lost concurrent or later updates.
5. Ingress returns after task acceptance and committed persistence, while the background dispatcher owns eventual delivery.

This design intentionally does not add retries, an outbox, a durable queue, delivery history, or a new endpoint. Those are different reliability contracts.

## Prevention

- Keep every new `NotificationEnvelope` field behind strict, frozen, bounded validation and add success, rejection, and mutation coverage.
- Never expose raw plugin constructor or execution exception text. Preserve fixed safe messages and test credential/hostile-name sentinels.
- Treat delivery results as one latest record per plugin: cap at 20, reject duplicate action references, replace repeated plugin outcomes, and redact unapproved messages.
- Audit every path that writes `decision_context`; it must retain `notification_delivery_results` and normalize JSONB lists before validation.
- Keep output-plugin I/O after the ingress commit. Use synchronization gates, not latency thresholds, to prove accepted ingress returns before slow delivery completes.
- Run the focused notification contract tests and `mise run ci` on Linux with Docker/Compose. `mise run check:portable` is a development subset, not PostgreSQL or delivery proof. PR #4's historical report of 636 passing tests does not verify the current revision.

## Related Work

- [Phase 9 notification-boundary plan](../../plans/2026-07-10-001-fix-plugin-notification-boundaries-plan.md)
- [PLG-03 structured notification outcomes explainer](../../explainers/PLG-03-explainer.html)
- [PR #4: retain terminal delivery outcomes](https://github.com/sh1ny/correlia/pull/4)
