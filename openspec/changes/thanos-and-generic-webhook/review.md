# Review

## Metadata

- **Round:** 1
- **Prior round:** none
- **Reviewer:** cross-model CLI (OMP)
- **Reviewed:** Proposal, FULL design, four spec deltas, the main Alertmanager, source-ingress, durable-pipeline and canonical-event specs, architecture, ADRs 0008/0016/0019/0024/0029, and the supplied project rules. Checked cited ranges in `bootstrap.dart`, `source_config.dart`, `config_repository.dart`, `ingress.dart`, `pipeline.dart`, `source_decoder.dart`, `body_depth.dart`, `identity.dart`, `event_bounds.dart`, `ingest_source.spy.yaml`, `console_access_policy.dart`, `alert_console_endpoint.dart`, development/test configuration, `tool/alertmanager_capture.sh`, and the v0.16.2 firing fixture. Followed the relevant paths into admission, raw-row insertion, canonical event validation, and the storage schema.
- **Verification limits:** No referenced store was declared. The review context exposed local read/search tools but not `git ls-files`; Git index membership was not independently verified. No `tasks.md` or scenario-to-task map was present to review.

## Findings

### Critical (blocking)

1. **The admission and first-claim contracts demand different mappings for the same row.** The generic mapping spec says a row admitted under `checks` is pinned to the snapshot holding it; the durable-pipeline delta explicitly expects A when B activates before the first claim. Existing admission inserts no pin (`ingest_records.dart:150–169`), and `Pipeline.pinOne` persists the snapshot active at first claim (`pipeline.dart:287–319`), as required by ADR 0016 and the main durable-pipeline spec. Under the proposed reuse of that flow, the scenario decodes with B, not A. Keep first-claim pinning and distinguish activation **before** the first pin from activation **after** it, including retry after the latter. If generic admission-time pinning is intentional, it is a contract change, not existing behavior.

2. **The two permitted forms of observation evidence do not both reach durable processing.** An observation-ID-only mapping can activate, but the worker dereferences `event.sourceTime!` for classification, observation-key insertion, and ordering (`pipeline.dart:445,539,613`), and `events.source_time` is `NOT NULL` (`schema/0001_ingest.sql:25`). An epoch-only mapping hits a separate incompatibility: `ObservationKey.fallback` parses its reported evidence as RFC 3339 (`identity.dart:371–382`), and event construction and JSON reading parse the reported text again (`canonical_event.dart:380–389,1221–1231`). Converting epoch evidence to RFC 3339 defeats the specified retention of the original evidence. Specify the end-to-end representation and behavior for both cases, including ordering and deduplication after key expiry without source time. Add durable tests for native-ID-only delivery and exact epoch evidence round-tripping through the published event and fallback key. D14's claim that this needs no new format or policy is not supported.

3. **D17's request limit cannot carry all samples promised by D8.** The sample and optional draft are JSON *strings* in the RPC request. A valid 1 MiB sample with enough backslashes can approach 2 MiB after outer JSON escaping, before adding the draft or envelope. A 1.25 MiB transport cap therefore rejects valid in-budget samples before the endpoint can return its typed result. Establish a wire budget against the actual serializer and enforce the separate decoded budgets. Verify through a real client request with an escape-heavy maximum-size valid sample and a draft, not just a direct endpoint call. The console policy runs inside the endpoint; it does not make the global RPC limit loopback-only.

4. **D15's configuration budget cannot be published through the planned bootstrap reader.** The cited `_readFile` implementation caps ordinary configuration input at 64 KiB (`bootstrap.dart:620–629`); the stat check and streamed read both enforce it (`bootstrap.dart:571–619`). D15 and the resource table budget up to 64 × 32 KiB of mappings before ordinary configuration overhead. The design does not change the file cap or name it as a tighter aggregate bound. Pick one enforceable aggregate budget, document its relationship to per-document limits, and test it through file-backed activation with the prior snapshot preserved on rejection.

### Moderate

1. **Preview has incompatible diagnostic and result contracts.** The proposal and generic spec promise *every* invalid or unmapped field; the resource table gives only 100 unmapped paths plus a count. The shared decoder contract (`source_decoder.dart:79`, D10 and the sequence diagram) returns a batch or throws a single field error, with no way to return all diagnostics. A path-count cap also does not bound response bytes: many reported leaves can repeat one long sender-chosen ancestor. Define diagnostic collection, deterministic truncation by bytes as well as count, and what `events` contains when production would reject the entire row. Test a sample with a valid alert followed by several independent errors and oversized diagnostic paths.

2. **Generic failure paths do not have a single safe contract.** D12 permits any mapping-named segment and four-digit indexes; the durable requirement only prohibits payload *values*, while C3 promises that sender-supplied keys will not enter stored diagnostics either. A numeric-looking JSON object key is not an array index, and a segment mapped under one parent is not necessarily mapped under another. Define structural matching against the configured path at that position, permit indexes only for actual array traversal, and specify bounded RFC 6901 rendering. Also define a safe pointer for downstream validation errors: both worker catches currently receive `error.path`, which can be a canonical field path rather than a sender pointer (`pipeline.dart:457–465,733–743`). Carry the resulting key-redaction rule explicitly in C3's destination and test both catches. The failure table also promises a pipeline log line, but the existing `_fail` path persists failure evidence without that log; either specify the sanitized logging behavior or remove the promise.

3. **Mapping shape and canonical event bounds disagree.** D15 allows 32 links; `proto/correlia/event/v1/event.proto:275–279` allows 16. D7/D13 also leave out what happens when a mapping omits `summary` or `severity`, though both are required by canonical construction (`canonical_event.dart:267–301`). An activated mapping can thus be unusable on every valid delivery. Specify required declarations versus deterministic defaults, align collection limits at activation, and distinguish display text truncation from URL validation: `EventLink` requires a bounded valid HTTP(S) target (`canonical_event.dart:110–127`).

4. **D13 can collapse distinct sender identities.** JSON number `1` and JSON string `"1"` both become the same text under the stated conversion. The canonical tuple encoding is unambiguous only *after* conversion, so this can make one object's recovery resolve another object's alert within the same scope. Specify whether cross-type equality is intentional; otherwise preserve the type in identity evidence or constrain each selector to a declared type. Add a mixed-type identity vector.

5. **D16 removes parsing, not the snapshot transfer used to justify it.** The cited ingress query selects `publicJson` alongside up to four credential rows (`ingress.dart:294–312`) and returns it even when the source join misses. Adding an ID-keyed parsed cache alone still transfers the enlarged snapshot on cache hits, potentially repeated alongside credentials. Keep the source, credentials and active revision coherent, but make the bounded hot-path projection or cache-miss fetch explicit. A test should show the full mapping documents are not fetched on a warm hit.

6. **The Thanos capture plan does not establish the evidence the HA requirement relies on.** The existing script drives resolution by posting an explicit `endsAt`; D18 substitutes a static Ruler rule but does not say how it transitions or how both replicas are observed (`tool/alertmanager_capture.sh:67–119`). The receiver overwrites one file per notification status, so checking filenames against a manifest cannot show which replica contributed or whether an earlier notification was overwritten. Specify how Ruler drives both transitions, what evidence distinguishes the replicas, and which fixtures prove label removal versus Correlia-side exclusion. Limit deduplication claims to equal observation evidence: equal labels prove one fingerprint, not equal `startsAt`/`endsAt` across independent Rulers.

7. **The carried-constraint ledger loses two deliberate scope boundaries.** S3's exclusion of database editing and S5's deferral of operator replay are in the mechanism ledger but absent from `## Carried constraints`. Record bootstrap-only authoring and replay deferral, each with one durable destination. Otherwise later work can introduce a second activation writer or mistake automatic retries for replay under the repaired mapping.

8. **Several source citations do not support the full claims as written.** `config_repository.dart:505–517` stops before the JSON decode and shows the repository helper, not the worker's actual loader (`pipeline.dart:363–373`). `pipeline.dart:856–869` shows kind resolution and dispatch, not an invocation under a retry budget. `identity.dart:275–299` stops before the source-kind and identity tuple components at lines 300–305. `tool/alertmanager_capture.sh:16` is cleanup, and `:25` is port selection, not container launch and receiver startup. The development YAML cannot establish staging/production settings, even though both files corroborate the value. Correct the ranges so readers can verify each claim directly.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

## RebuttalsAuthor, round 1 (all fixed, for the reviewer to re-check):
- Critical 1 fixed: rows pin at first claim; generic spec scenario reworded; durable-pipeline scenarios split into before/after first claim; Flow & State Gaps and C7.
- Critical 2 fixed: D19 (owner G1a) requires `source_time` in every mapping; D14 renders epoch evidence as exact RFC 3339, citing the Icinga2 precedent; time-format requirement and scenario updated.
- Critical 3 fixed: D17 sets 2.5 MiB in dev/test for escaping, endpoint enforces decoded budgets, real-client escape-heavy test.
- Critical 4 fixed: D15 makes the 64 KiB file cap the aggregate bound; per-mapping 32 KiB.
- Moderate 1 fixed: D8/D10 collecting preview mode, 100 entries and 64 KiB, `wouldFail`; spec requirement and scenario.
- Moderate 2 fixed: D12 structural RFC 6901 rule, array-index rule, canonical paths keep the existing allow-list, no log line; durable spec requirement and numeric-key scenario.
- Moderate 3 fixed: 16 links, http(s) links, required summary/status/severity (constant severity allowed); spec scenarios.
- Moderate 4 fixed: D20 (owner G2a) identity values are strings only; `identity_type` scenario.
- Moderate 5 fixed: D16 drops the cache; growth bounded by the 64 KiB file cap.
- Moderate 6 fixed: D18 specifies two Rulers, rule reload for resolution, sequence-numbered capture, two runs, manifest fields; HA spec claims only one fingerprint.
- Moderate 7 fixed: C6 (bootstrap-only authoring, ADR 0031) and C7 (replay deferral).
- Moderate 8 fixed: citations corrected (pipeline.dart:363-373, 287-319, 1005-1018; identity.dart:275-305; capture script 36-61, 82, 93-98; staging/production yaml lines).
