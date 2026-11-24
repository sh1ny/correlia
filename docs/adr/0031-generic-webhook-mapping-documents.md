# 0031. Generic webhook mapping documents

- Status: accepted (2026-11-24)
- Date: 2026-11-24
- Supersedes: none (extends [0008](0008-rule-language.md), [0016](0016-durable-staged-pipeline.md) and [0029](0029-source-credentials-and-admission-limits.md))
- Chosen by: user (mapping format, placement and rollout).

## Context

Senders without a built-in decoder need a way to produce canonical events without adding code. The decoder must use the configuration pinned by the worker, not whatever mapping is active when a retry runs.

## Decision

A format-version-2 bootstrap file may declare a root `mappings` list. Every `generic` source names one document in that list; multiple sources may share a document. Publish the documents and sources atomically in the immutable configuration snapshot. Serialize the documents in name order and omit the list when empty so snapshots without mappings keep their existing bytes and IDs. Author mappings only in the bootstrap file until M4 adds console editing. Preview does not activate a mapping.

`mapping_format: 1` fixes flat keys and RFC 6901 JSON Pointer selection. An optional `items` pointer selects an array of alerts; all other pointers are relative to one alert. Identity comes from mapped string values, never batch position. A source time is required; an observation ID is optional. Status uses a value table, and severity uses a value table or a constant. Display fields copy a selected value or take a constant; templates are not supported. Changes to these format rules require a new `mapping_format`.

Upgrade every process role to this release before publishing a generic source. Schema step 10 takes the publication advisory lock before raising the minimum configuration publisher version to 2. The gate blocks new publishes by old versions; it does not detect older processes that are still running. An older worker cannot decode the new kind. Binary downgrade after step 10 is unsupported.

## Consequences

The webhook admits bytes under the existing source policy. The worker pins at first claim and reuses that snapshot for retries. A mapping fix affects new claims, not rows already pinned to an earlier snapshot. To remove a generic source, rotate to an unused credential and keep the source enabled until pending rows finish, then remove it.
