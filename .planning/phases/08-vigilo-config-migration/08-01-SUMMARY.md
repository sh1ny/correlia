---
phase: 08-vigilo-config-migration
plan: "01"
subsystem: config
tags: [pydantic, topology, regex, capture-groups, enrichment]

requires:
  - phase: 07-incident-event-audit-trail
    provides: stable event processing and audit pipeline for enrichment to integrate with

provides:
  - HostnameTopologyRule.tag_capture_groups schema field with strict validation
  - CompiledHostnameRule.tag_capture_groups carry-through from YAML loader to enricher
  - load_topology_config validation of topology-prefixed capture keys and in-range group indexes
  - StaticTopologyEnricher application of derived hostname tags after literal tags
  - Bounded derived tag values (skip empty/None, reject >256 characters)
  - Subnet rules remain literal-only and reject tag_capture_groups

affects:
  - 08-vigilo-config-migration (Plan 08-02 — migration CLI emits tag_capture_groups)
  - Phase 9 — plugin boundaries consume topology-enriched events

tech-stack:
  added: []
  patterns:
    - Strict Pydantic schema extension with Field(default_factory=dict) for backward-compatible optional fields
    - Compiled config representation carries derived data from loader to runtime
    - Shared diagnostic accounting for literal and derived topology tags

key-files:
  created: []
  modified:
    - app/config/topology.py — schema, compiled rule, and loader validation
    - app/processing/enrichment.py — hostname regex match capture and derived tag application
    - tests/test_topology_enrichment.py — acceptance/rejection and enrichment regression tests

key-decisions:
  - "tag_capture_groups is a strict dict[str, int] with Field(default_factory=dict), so existing literal-only YAML remains valid."
  - "Derived capture-group tags are applied after literal tags; a derived value that overrides a literal value updates tags_added to the final captured value and records literal→derived in conflicts."
  - "Subnet topology rules intentionally reject tag_capture_groups via Pydantic extra=forbid, preserving D-11 literal-only semantics."

patterns-established:
  - "Config loader validates regex group indexes against compiled pattern.groups before constructing compiled rules."
  - "Enricher skips None and empty-string captures and bounds non-empty captures to the existing TagValue max length."

requirements-completed: [CFG-03, CFG-04]

duration: 30min
completed: 2026-06-19
status: complete
---

# Phase 8 Plan 1: Runtime Topology Regex Capture-Group Support Summary

**Hostname-derived topology tags now flow from strict YAML schema through compiled config into runtime enrichment, with literal tags applied first and capture-group substitutions bounded and diagnosed consistently.**

## Performance

- **Duration:** 30 min
- **Started:** 2026-06-19T00:00:00Z
- **Completed:** 2026-06-19T00:30:00Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments

- Extended `HostnameTopologyRule` and `CompiledHostnameRule` with `tag_capture_groups` while leaving `SubnetTopologyRule` unchanged.
- Added loader validation that capture-group keys start with `topology.` and indexes are `>= 1` and `<=` the compiled regex group count.
- Updated `StaticTopologyEnricher` to pass the hostname regex match into tag application and resolve derived tags after literal tags.
- Enforced the 256-character `TagValue` bound on derived captures and skipped `None`/empty captures before writing event tags.
- Added regression tests covering schema acceptance, invalid indexes, missing `topology.` prefix, subnet rejection, derived-tag addition, override diagnostics, empty/None capture skipping, and overlong capture rejection.

## Verification

- `uv run pytest tests/test_topology_enrichment.py -x` — 32 passed in 0.10s.
- `uv run pytest tests/test_topology_enrichment.py::test_load_topology_config_accepts_hostname_tag_capture_groups tests/test_topology_enrichment.py::test_load_topology_config_rejects_invalid_capture_group_index tests/test_topology_enrichment.py::test_load_topology_config_rejects_capture_group_key_without_topology_prefix tests/test_topology_enrichment.py::test_load_topology_config_rejects_subnet_tag_capture_groups -x` — 6 passed.
- `uv run pytest tests/test_topology_enrichment.py::test_hostname_capture_group_adds_derived_tag tests/test_topology_enrichment.py::test_hostname_capture_group_overrides_literal_or_event_tag tests/test_topology_enrichment.py::test_hostname_capture_group_skips_empty_capture tests/test_topology_enrichment.py::test_hostname_capture_group_rejects_overlong_capture -x` — 5 passed.
- `uv run python -m compileall app/config/topology.py app/processing/enrichment.py` — no output (success).

## Task Commits

Each task was committed atomically:

1. **Task 1: Test and implement topology schema/compiler support** — `faa7ccc` (feat)
2. **Task 2: Test and implement derived hostname tag enrichment** — `c29b394` (feat)
3. **Task 3: Run topology capture-group regression checks** — `7a5372a` (test)

**Plan metadata:** docs(08-01) commit captures this SUMMARY.md plus updated STATE.md and ROADMAP.md.

## Files Created/Modified

- `app/config/topology.py` — Added `tag_capture_groups` to `HostnameTopologyRule` and `CompiledHostnameRule`; added key-prefix and positive-index validation; added `<= pattern.groups` check in `load_topology_config`.
- `app/processing/enrichment.py` — Captured regex match in `enrich`, passed it to `_apply_rule`, applied derived tags after literal tags with skip/length checks and consistent diagnostics.
- `tests/test_topology_enrichment.py` — Added loader and enrichment regression tests for CFG-03/CFG-04 and D-07 through D-11.

## Decisions Made

- Followed the plan’s choice of `tag_capture_groups: dict[str, int] = Field(default_factory=dict)` so existing topology YAML without the field still validates.
- Reused the existing `tags_added` / `tags_overridden` / `conflicts` accounting for derived tags; when a derived value overrides a literal value on a newly added key, `tags_added` reflects the final captured value and `conflicts` records the literal→derived transition.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Plan 08-01 runtime capability is complete.
- Plan 08-02 (migration CLI) can now rely on `tag_capture_groups` being accepted and enriched by Correlia when emitting Vigilo hostname-derived tags.

---
*Phase: 08-vigilo-config-migration*
*Completed: 2026-06-19*

## EXECUTION COMPLETE
