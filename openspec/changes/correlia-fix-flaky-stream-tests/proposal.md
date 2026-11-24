# Proposal

## Why

Correlia [#77](https://github.com/sh1ny/correlia/issues/77) blocks Main’s Linux verification. This change restores reliable regression checks for the M2 Icinga 2 Event Streams reconnect and shutdown scenarios. It does not advance the owner’s real-feed sign-off, which remains at milestone close.

## What Changes

- Replace test polling and short wall-clock race windows with explicit readiness, database-commit, and shutdown barriers.
- Eliminate the race between live loopback Icinga responses and consumer shutdown in the 64-source test without suppressing unrelated transport errors.
- Prove the fixed DB tier on independent CI runs, with no test retries.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. Test synchronization changes; Icinga 2’s external behavior, accepted scenarios and operational deadlines stay unchanged.

## Impact

Icinga 2 Event Streams DB tests and their test fixtures. No migration, dependency, config, or public API change.

## Decision Making

DECISION_MAKING: important
Source: setting

### S1: Keep real integration coverage

- **Choice:** Retain the real TLS sockets, embedded PostgreSQL and consumer supervision, and assert occurrences and ordering instead of elapsed wall time.
- **Rejected:** Increase the per-step budgets or retry a failed test; either retains a false failure mode on slow runners.
- **Reversal cost:** low.
- **Important:** no; no product behavior or boundary changes.
- **Chosen by:** user.
