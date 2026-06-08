---
phase: 02-icinga2-ingress-topology-and-rule-decisions
plan: 2
subsystem: api
 tags: [fastapi, pydantic, yaml, topology, enrichment, protocol, icinga2, ingress]

# Dependency graph
requires:
  - phase: 01-foundations-contracts-and-database-invariant
    provides: NormalizedEvent, Severity, EventType, DecisionContext, Settings, create_app pattern
  - phase: 02-icinga2-ingress-topology-and-rule-decisions plan 1
    provides: Icinga2DecisionProcessor, build_icinga2_processor, IngressDecisionEnvelope
provides:
  - Topology YAML loader with strict Pydantic validation and load-time regex/CIDR compilation
  - StaticTopologyEnricher with hostname precedence and subnet fallback
  - TopologyEnricher plugin protocol for structural typing
  - Topology tag conflict resolution (topology wins) with bounded diagnostics
  - Ingress processor wired to optional topology enrichment
affects:
  - phase 02 plan 3 (rule engine will consume enriched events with topology tags)
  - phase 03 (incident upsert will use topology-aware group keys)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "typing.Protocol for plugin boundaries with structural typing"
    - "Load-time compilation of regex and CIDR in config loaders"
    - "Frozen dataclasses (slots=True) for pure transformation outputs"
    - "Reserved namespace (topology.*) with deterministic conflict resolution"
    - "Bounded diagnostics: only matched rule facts, not full config traces"

key-files:
  created:
    - app/config/topology.py
    - app/plugins/interfaces.py
    - app/processing/enrichment.py
    - tests/test_topology_enrichment.py
  modified:
    - app/processing/ingress.py
    - app/main.py
    - tests/test_ingress_router.py

key-decisions:
  - "Topology YAML tags must start with 'topology.'; Pydantic field_validator rejects anything else"
  - "Overlapping CIDRs with different tag values are rejected at load time; same tags are allowed"
  - "Hostname rules prevent subnet fallback for the same event (D-09 precedence)"
  - "Topology wins on conflicting source tags; diagnostics record (key, old, new) triples"
  - "Enrichment diagnostics are bounded to the single matched rule; no every-rule trace in responses"
  - "build_icinga2_processor accepts optional topology_path and constructs StaticTopologyEnricher internally"

patterns-established:
  - "Plugin protocol boundary: TopologyEnricher is a typing.Protocol, not an ABC"
  - "Config loader returns compiled immutable structures (CompiledTopologyConfig with tuple fields)"
  - "Pure enrichment: no persistence, AsyncSession, or rule-engine imports in enrichment.py"

requirements-completed:
  - ING-05
  - TOP-01
  - TOP-02
  - TOP-03
  - TOP-04
  - TOP-05
  - TOP-06

# Metrics
duration: 18min
completed: 2026-06-08
---

# Phase 2 Plan 2: Topology YAML Loading and Pure Enrichment Summary

**Static YAML topology enrichment with strict validation, hostname/IP subnet matching, reserved-namespace conflict resolution, and plugin-protocol isolation behind the Icinga2 ingress pipeline.**

## Performance

- **Duration:** 18 min
- **Started:** 2026-06-08T18:00:25Z
- **Completed:** 2026-06-08T18:18:00Z
- **Tasks:** 3
- **Files modified:** 7

## Accomplishments
- `load_topology_config` accepts valid hostname and subnet YAML with strict Pydantic v2 validation
- Hostname patterns compiled to `re.Pattern` and CIDRs parsed to `ipaddress` networks at load time
- Overlapping subnets with conflicting tag values are rejected at config load (T-02-02-T mitigation)
- `StaticTopologyEnricher` applies hostname rules before subnet fallback, preserving non-topology source tags
- Reserved `topology.*` conflicts resolve with topology winning; diagnostics preserve source value and override
- Enrichment diagnostics are bounded to the matched rule only (no full config trace in HTTP responses)
- Ingress processor accepts an optional `TopologyEnricher` protocol; main app wires `settings.topology_path`
- 43 topology-specific tests cover loader validation, precedence, conflict, diagnostics, and HTTP integration

## Task Commits

Each task was committed atomically:

1. **Task 1: Add failing topology-enriched ingress tests** - `28c3662` (test)
2. **Task 2: Implement strict topology config and pure enrichment** - `d3f634e` (feat)
3. **Task 3: Harden topology diagnostics and boundary assertions** - `f60aefd` (test)

## Files Created/Modified
- `app/config/topology.py` - HostnameTopologyRule, SubnetTopologyRule, TopologyConfig, CompiledTopologyConfig, load_topology_config with regex/CIDR compilation and overlapping-CIDR rejection
- `app/plugins/interfaces.py` - InputPlugin and TopologyEnricher typing.Protocol definitions
- `app/processing/enrichment.py` - EnrichmentDiagnostic, EnrichmentResult, StaticTopologyEnricher with hostname precedence and conflict resolution
- `app/processing/ingress.py` - Icinga2DecisionProcessor now accepts optional TopologyEnricher; build_icinga2_processor constructs enricher from topology_path
- `app/main.py` - lifespan passes settings.topology_path to build_icinga2_processor
- `tests/test_topology_enrichment.py` - 19 tests for YAML loading, validation, precedence, conflict, diagnostics, and plugin boundary isolation
- `tests/test_ingress_router.py` - 3 additional ingress HTTP tests for no-match, subnet fallback, and conflict diagnostic shape

## Decisions Made
- Reserved `topology.*` namespace enforced at config load time via field_validator, not just at runtime
- Overlapping CIDRs allowed when tag dicts are identical; rejected only when they would produce different enrichment results
- `build_icinga2_processor` uses local imports for topology modules to keep startup dependency graph lazy
- Diagnostics use list-of-tuples for overridden tags instead of nested dicts to preserve order and make conflicts explicit

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Topology enrichment pipeline is complete and testable
- Rule engine (Phase 2 Plan 3) can now consume enriched events with `topology.*` tags for matching and group-key generation
- Phase 3 incident upsert can use topology-aware group keys from the ingress pipeline

## Self-Check: PASSED
- [x] `tests/test_topology_enrichment.py` exists and passes (19 tests)
- [x] `tests/test_ingress_router.py` passes including 3 new topology integration tests
- [x] `app/processing/enrichment.py` does not import `app.persistence`, `AsyncSession`, or `RuleEngine`
- [x] `app/processing/ingress.py` does not import `app.persistence` or `AsyncSession`
- [x] `app/config/topology.py` validates reserved `topology.*` tags and rejects overlapping conflicting CIDRs
- [x] All 157 project tests pass

---
*Phase: 02-icinga2-ingress-topology-and-rule-decisions*
*Completed: 2026-06-08*
