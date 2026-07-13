---
title: Bounded Operational Visibility Across Runtime Boundaries
date: 2026-07-11
category: architecture-patterns
module: operational-visibility
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - A system exposes metrics, readiness, and structured logs for the same runtime behavior
  - Short-lived or fail-fast processes must report outcomes through a long-lived service
  - Asynchronous work has distinct submission and completion boundaries
tags: [operational-visibility, metrics, readiness, structured-logging, cardinality, async-boundaries]
---

# Bounded Operational Visibility Across Runtime Boundaries

## Context

Correlia needed an operational surface for deployment startup, configuration migration, plugin loading, readiness, audit writes, and asynchronous notification work. Treating observability as a collection of independent counters and log statements would have produced misleading timing semantics, unbounded metric labels, and signals that disappear with short-lived or failed processes.

The durable pattern is to model each runtime boundary explicitly, choose the signal that can truthfully survive that boundary, and publish only closed operational vocabulary.

## Guidance

### Define one finite vocabulary before adding collectors

Declare every label domain centrally and validate collectors and producers against it. Correlia's collector inventory is also its finite producer vocabulary: new collectors declare allowed label names and values in `COLLECTOR_LABEL_DOMAINS` (`app/processing/metrics.py:161-186`). Notification submission outcomes and terminal delivery outcomes are separate closed domains (`app/processing/metrics.py:47-53`).

Do not use source-derived values such as plugin names, rule names, task names, incident identifiers, paths, exception messages, or arbitrary rejection reasons as metric labels. Convert them to a small operational category or omit them.

### Preserve the boundary between acceptance and completion

For asynchronous work, record submission when the runner accepts or rejects the task, then record delivery only when the dispatcher reaches a terminal result. The dispatcher derives a bounded `success` or `failure` outcome from the terminal `NotificationResult` and records its closed category (`app/processing/notification_dispatcher.py:105-117`).

This prevents accepted work from being counted as successful delivery and lets operators distinguish scheduling failures from plugin execution failures.

### Project short-lived outcomes through a long-lived process

A short-lived migration command cannot expose a reliable pull-based Prometheus metric after it exits. Instead, write a bounded, versioned summary and let the serving process validate and project it.

Correlia's projection rejects non-regular files, reports larger than 65,536 bytes, malformed JSON, unknown document shapes, unsupported versions, invalid outcome/failure-code combinations, and timestamps outside the accepted range before publishing a snapshot (`app/processing/metrics.py:363-394`, `app/processing/metrics.py:397-473`). The projection exports only the validated status, outcome, failure code, and completion timestamp; raw issue messages and paths never become metric data (`app/processing/metrics.py:168-172`).

### Let fail-fast startup failure remain a startup signal

If startup fails before the service can serve metrics or readiness, do not invent a scrapeable success path. Emit a bounded, secret-safe startup event and exit non-zero. Successful startup and serving-time state can be represented by metrics and readiness; pre-serve failure is truthfully represented by process exit plus its safe event.

### Keep readiness categorical and identity-free

Readiness should expose stable dependency and plugin-category keys rather than configured instance names or options. Correlia limits readiness states to `ready`, `not_ready`, and `not_configured`, with fixed dependency and output-plugin category domains (`app/processing/metrics.py:54-73`). This gives operators actionable state without revealing credentials, endpoint details, or configuration identity.

## Why This Matters

Observability is part of the runtime contract. A metric emitted at the wrong phase can claim that work completed when it was only queued. A label copied from configuration can create unbounded series or leak sensitive topology. A short-lived process can write a metric that no scraper ever sees. A readiness response can expose operational identity even when its boolean result is correct.

Boundary-first instrumentation avoids those failures because each signal answers a precise question:

- submission metrics answer whether work entered the runner;
- delivery metrics answer how plugin execution terminated;
- readiness answers whether fixed service categories can operate now;
- structured events explain bounded transitions and failures;
- validated projections carry durable summaries from short-lived tools into the serving process;
- process exit remains the authoritative signal when startup never reaches a scrapeable state.

## When to Apply

- Adding metrics and logs around asynchronous or post-commit work.
- Exposing readiness for configurable plugins or dependencies.
- Reporting outcomes from migrations, importers, or other short-lived commands to a pull-based monitoring system.
- Instrumenting startup paths that intentionally fail closed.
- Reviewing an existing metric family for cardinality or secret-leak risk.

## Examples

### Avoid identity-bearing labels

```python
# Avoid: cardinality and topology grow with configuration.
plugin_loads.labels(plugin_name=configured_name, outcome="success").inc()

# Prefer: a closed operational category.
plugin_loads.labels(category="email", outcome="success").inc()
```

### Separate task acceptance from terminal delivery

```python
# Submission boundary
record_notification_submission("accepted")

# Later, at the dispatcher completion boundary
outcome = "success" if result.success else "failure"
record_notification_delivery(outcome, result.category)
```

### Project a short-lived result safely

```python
# Short-lived command: write a bounded schema, not arbitrary diagnostics.
summary = {
    "version": 1,
    "outcome": "failure",
    "failure_code": "source_validation",
    "issue_count": 3,
    "issues_truncated": False,
    "completed_at": completed_at,
}

# Long-lived service: validate shape, domains, size, and time before export.
status, snapshot = validate_report(report)
if status == "valid":
    publish_bounded_snapshot(snapshot)
```

## Related

- `docs/solutions/security-issues/plugin-notification-boundary-convergence.md` documents the notification-specific persistence and exception-safety boundary.
- `CONCEPTS.md` defines Task Acceptance, Notification Result, and Notification Delivery Record.
