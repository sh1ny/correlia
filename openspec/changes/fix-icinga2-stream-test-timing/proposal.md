# Proposal

## Why

M2 requires the named ingest and Icinga 2 acceptance paths to pass reliably. In CI run [45367825034](https://github.com/sh1ny/correlia/actions/runs/45367825034), the combined webhook/Event Streams E2E test failed at a 45-second polling deadline; #80 tracks that case and the remaining #74 tests that use runner speed as evidence.

## What Changes

- Begin with the combined-source E2E test: observe committed admission and terminal processing for the specific webhook and stream deliveries, then verify their events. Diagnose a missing or failed delivery instead of giving an event-count poll more time.
- Replace test-side per-step deadlines, SQL polling, and sleeps used as synchronization across the thirteen suites and shared fixture in [#80](https://github.com/sh1ny/correlia/issues/80). Keep the real database, process, TLS, and shutdown boundaries under test; measure timeout scheduling with controlled time and keep only generous whole-test hang guards.
- Replace the plugin health stress case's real busy-wait around a short RPC timeout; retain the deadline-versus-disconnect distinction. Do not change the separate plugin diagnostic host-death proof, whose CI receipt showed terminal process state `X` despite a readable pidfd and an EOF marker.
- Run the affected DB, E2E and plugin tiers three to five times on the PR without retries; report every run and leave the merge to the owner.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. This changes test evidence only, not production behavior, deadlines, or scenario outcomes.

## Impact

The audited Dart suites, shared test harnesses, and narrowly scoped instrumentation where an existing seam cannot witness an operation. No production settings, migrations, dependencies or APIs change.

## Decision Making

DECISION_MAKING: important
Source: setting

### S1 — Scope and evidence standard

- Choice: fix all thirteen audited suites and their shared fixture, plus the plugin health case with the same timing-as-synchronization pattern; preserve production contracts, use events and injected time, and leave the unrelated plugin diagnostic case alone.
- Rejected: lengthen budgets, rerun failures, or swap real DB/process/socket assertions for mock-only tests. Those changes either leave the failure mode in place or remove what these tiers prove.
- Reversal cost: low; test-only and scoped to the affected fixtures and seams.
- Important: no; follows the owner-approved scope and fixes no user-facing contract.
- Chosen by: user (approved scope and acceptance constraints; conditional plugin inclusion determined from CI and source).