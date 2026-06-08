# Phase 2: Icinga2 Ingress, Topology, and Rule Decisions - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-08
**Phase:** 2-Icinga2 Ingress, Topology, and Rule Decisions
**Areas discussed:** Icinga2 state semantics, Topology tag conflicts, Rule multi-match behavior, Threshold/window decisions

---

## Icinga2 State Semantics

### SOFT/HARD handling

| Option | Description | Selected |
|--------|-------------|----------|
| HARD only | Only HARD problem/recovery states affect normalized processing; SOFT states are rejected or reported as non-actionable diagnostics. | ✓ |
| Accept both, tag attempt state | Normalize both SOFT and HARD, but include attempt state tags so rules can choose. | |
| You decide | Use the simplest behavior consistent with deterministic alert aggregation and explicit diagnostics. | |

**User's choice:** HARD only

### State mapping

| Option | Description | Selected |
|--------|-------------|----------|
| OK/UP recover, non-OK problem | Host UP/service OK become RECOVERY with severity OK; DOWN/UNREACHABLE and WARNING/CRITICAL/UNKNOWN become PROBLEM. | ✓ |
| Recoveries preserve prior severity hint | Recovery events include severity OK plus a hint for the previous problem state if present. | |
| You decide | Keep mapping strict and predictable using Icinga2's standard state vocabulary. | |

**User's choice:** OK/UP recover, non-OK problem

### Fingerprint scope

| Option | Description | Selected |
|--------|-------------|----------|
| Source object identity + event type | Use source_id, host, optional service, and PROBLEM/RECOVERY type. | |
| Source object identity + normalized state | Use source_id, host, optional service, event type, and normalized severity/state. | ✓ |
| Include Icinga event id if available | Prefer Icinga's event/check id when present, fallback to source object identity. | |

**User's choice:** Source object identity + normalized state

### Ingest response detail

| Option | Description | Selected |
|--------|-------------|----------|
| Full decision envelope | Return accepted event identity, enrichment tags/provenance, matched rules, group keys, threshold/window decisions, closures, and notification count placeholders. | ✓ |
| Minimal accept response | Return only accepted fingerprint/type and maybe matched rule names. | |
| Debug only when requested | Default minimal response, full decision envelope behind a query/header flag. | |

**User's choice:** Full decision envelope

---

## Topology Tag Conflicts

### Tag precedence

| Option | Description | Selected |
|--------|-------------|----------|
| Topology overrides source | YAML topology is the operator-owned correlation truth; diagnostics record the overridden source value. | ✓ |
| Source wins, topology annotates conflict | Preserve source payload values; topology emits diagnostics and maybe `topology.*` tags. | |
| Reject conflicting enrichment | Treat conflict as validation/enrichment failure. | |

**User's choice:** Topology overrides source
**Notes:** Topology override requires explicit diagnostics so source data is not silently lost.

### Tag namespace

| Option | Description | Selected |
|--------|-------------|----------|
| Reserved topology namespace | Topology writes `topology.site`, `topology.role`, etc.; rule matching references them explicitly. | ✓ |
| Ordinary tags with provenance | Topology writes normal tags like `site` or `role`, overriding source on conflict. | |
| Both canonical and namespaced | Write canonical simple keys plus provenance/namespaced copies. | |

**User's choice:** Reserved topology namespace

### Enrichment diagnostics

| Option | Description | Selected |
|--------|-------------|----------|
| Rule id + match source + changed tags | Expose matched topology rule id/name, hostname vs subnet path, tags added/overridden, and conflict list. | ✓ |
| Full rule evaluation trace | Expose every topology rule considered and why it did/did not match. | |
| Summary only | Expose only whether enrichment happened and final tags. | |

**User's choice:** Rule id + match source + changed tags

### Hostname/IP fallback

| Option | Description | Selected |
|--------|-------------|----------|
| Hostname match stops fallback | Once hostname matches, do not apply subnet rules. | ✓ |
| Fallback fills missing topology keys | Hostname rules run first, subnet rules may add only keys not already set. | |
| All matching rules merge by priority | Hostname and subnet rules all participate in a priority merge. | |

**User's choice:** Hostname match stops fallback

---

## Rule Multi-Match Behavior

### Multiple matching rules

| Option | Description | Selected |
|--------|-------------|----------|
| First match wins | Evaluate by priority and stop at the first match. | ✓ |
| All matches apply | Collect every matching rule and generate decisions/group keys for all. | |
| Explicit stop flag | Rules can set `stop_processing`. | |

**User's choice:** First match wins

### Priority ties

| Option | Description | Selected |
|--------|-------------|----------|
| Reject duplicate priorities | Strict YAML validation fails if two enabled rules share a priority. | ✓ |
| Tie-break by rule name | Allow duplicate priorities and sort by rule name. | |
| File order tie-break | Allow duplicate priorities and preserve YAML order. | |

**User's choice:** Reject duplicate priorities

### Group key format

| Option | Description | Selected |
|--------|-------------|----------|
| Ordered key=value parts | Use rule-configured order, e.g. `topology.site=dc1|service=cpu`. | ✓ |
| Canonical JSON string | Serialize selected fields as sorted compact JSON. | |
| Hash with debug context | Use a short hash and expose original fields in decision context. | |

**User's choice:** Ordered key=value parts

### No-match behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Accepted with no-op decision | Return accepted event plus `matched_rules: []` and no incident effects. | ✓ |
| Reject as unprocessable | Return an error because no rule knows what to do. | |
| Default catch-all rule required | Config must include an explicit catch-all rule. | |

**User's choice:** Accepted with no-op decision

---

## Threshold/Window Decisions

### Threshold count scope

| Option | Description | Selected |
|--------|-------------|----------|
| Per rule + group key | Count events within the matched rule's group key/window. | ✓ |
| Per fingerprint | Count repeated deliveries of the same normalized fingerprint. | |
| Per host/service object | Count source object occurrences regardless of rule grouping. | |

**User's choice:** Per rule + group key

### Replay counting

| Option | Description | Selected |
|--------|-------------|----------|
| Do not double-count active fingerprint | Same fingerprint contributes once until it changes state or falls out of window. | ✓ |
| Count every accepted delivery | Every webhook POST increments the threshold count. | |
| Count with source sequence only | Count repeats only if Icinga supplies a distinct check/event sequence. | |

**User's choice:** Do not double-count active fingerprint

### Window semantics

| Option | Description | Selected |
|--------|-------------|----------|
| Sliding event-time window | Count unique fingerprints whose source timestamps fall within `event.timestamp - window`. | ✓ |
| Sliding processing-time window | Count arrivals by server receive time. | |
| Fixed tumbling windows | Bucket counts into fixed intervals. | |

**User's choice:** Sliding event-time window

### Phase 2 threshold storage

| Option | Description | Selected |
|--------|-------------|----------|
| Inspectable in-memory/testable decision object | Rule evaluation returns a typed decision object with threshold state and inputs; persistence waits for Phase 3. | ✓ |
| Persist threshold state immediately | Add durable threshold/event-window storage in Phase 2. | |
| Compute only boolean crossed/not crossed | Return a simple boolean and defer detailed state. | |

**User's choice:** Inspectable in-memory/testable decision object

---

## Claude's Discretion

None. The user selected concrete decisions for every discussed area.

## Deferred Ideas

None. Discussion stayed within phase scope.
