# Review

## Metadata

- **Round:** 4
- **Prior round:** Rounds 1–3 returned REVISE. The owner chose to fix every finding after each escalation. Round 3 left four Critical and five Moderate findings; this round re-checks all nine.
- **Reviewer:** cross-model CLI (OMP)
- **Reviewed:** Proposal, FULL design, four spec deltas, round-3 review and its round-2 re-check, main Alertmanager/source-ingress/durable-pipeline/canonical-event specs, architecture, project rules, roadmap and RUL-8, ADRs 0008/0016/0019/0024/0029/0030, the design’s cited source ranges, and the relevant admission, schema, event serialization, and capture code.
- **Verification limits:** No external context store or scenario-to-task map was declared. The read-only tool interface did not expose `git ls-files`; index membership could not be independently checked. No runtime or capture was exercised.

## Findings

### Critical (blocking)

1. **D8 still promises production budget results that preview cannot derive from its inputs.** D8 calls decode failures and `decode_bound` exact and labels `mayExceedRowBudget` an upper bound. The new all-inserted/all-routed assumption bounds the number of charges, not the bytes per charge. The worker builds the `DecodeRequest` with the actual raw UUID and receipt timestamp in `rawRef`, plus the actual observed and processed timestamps (`pipeline.dart:419–436`). Those fields are serialized into the same bytes used for the per-event limit, D21, and the worker row budget (`canonical_event.dart:412–464,546–559`; `cloud_event.dart:158–169`; `pipeline.dart:661–670`). For example, a whole-millisecond receipt and a receipt with nonzero microseconds produce different raw-reference lengths for otherwise identical deliveries. A sample at a byte boundary can therefore pass preview’s per-event or cumulative limit and fail in production; an estimate using smaller synthetic metadata can also be false below the threshold when production exceeds it. Use the owner’s stated fallback and drop the row-budget flag. Separately, qualify the decode result as a result under specified preview metadata, or define and prove a production bound without calling it exact. Exercise the same sample with two production metadata lengths on opposite sides of a boundary.

### Moderate

1. **The preview caps its response, not its diagnostic working set.** D8 requires sorted diagnostics and an exact overflow count, but the Resource Bounds table calls the buffer constant without saying the cap applies during collection. A sample under 1 MiB can contain hundreds of thousands of unmapped scalar leaves in one alert; collecting their full paths and sorting them before truncation takes memory proportional to the number and length of the paths, not the 64 KiB response cap. Specify bounded retention during traversal, including how diagnostics beside a nested `items` array are ordered when they have no alert index. Exercise a dense unmapped subtree and assert the retained working set as well as the returned prefix and overflow count.

2. **Mapping format 1 still admits conflicting interpretations of the same payload.** D11 marks descendants of a selected ancestor as read, then rejects that rule; the delta marks only selected leaves as read. In preview, an object at a scalar pointer can consequently hide its children from unmapped diagnostics or report them, depending on which text is followed. D13 and the display requirement also say copied strings are used as “JSON text,” while the display scenario expects verbatim text, not a quoted JSON string. Define what counts as a read leaf even when its field fails validation, and distinguish verbatim strings from number and boolean conversion. Specify rejection of duplicate object member names before pointer evaluation in both delivery and preview: `jsonDecode` otherwise keeps the last value, as the Icinga2 parser documents and guards against (`webhook_parser.dart:35–55`). An ambiguous identity pointer must not silently select a different alert. Test duplicate mapped keys, a wrong-typed object with children, and both seconds endpoints alongside the existing millisecond and exponent cases.

3. **The failure-path contract does not say what to store when no segment fits.** D15 accepts 512-byte mapping pointers; D12 cuts stored paths at segment boundaries within 256 bytes. A valid pointer with a single 300-byte token can select a wrong-typed field. There is then no nonempty prefix that fits, yet the field requirements promise an error naming that pointer. The empty RFC 6901 pointer means the document root, not truncation. Specify an unambiguous stored result for this case, distinguish it from a root failure, and test an overlong first segment and a multibyte or escaped segment at the boundary.

4. **The Thanos fallback still conflicts with the mandatory scenario, and the fixture check can pass with missing evidence.** A1 says to replace the Ruler-drop scenario if the upstream flag is unavailable; the Alertmanager delta still requires it without qualification. Also, a fixture-to-manifest bijection passes when both a fixture and its manifest entry are missing. It does not prove four releases were covered, that each captured firing and resolution, or that both replicas sent in the drop run. Define the fallback as a gated, explicit outcome before claiming support, without silently changing S1. Require the fixture test to check the pinned release/run/status matrix and its per-replica evidence. Include the pinned query image in the manifest. Capture with valid HTTP(S) link settings rather than relying on the existing receiver’s `externalURL` rewrite: the decoder validates nonempty external and generator URLs (`alertmanager_decoder.dart:245–251`; `canonical_event.dart:110–127`).

5. **Step 10 does not specify the publication lock needed for the stated cutover.** An old publisher can pass the old insert trigger and remain in its transaction while an independently applied step 10 records the new gate. That transaction can then commit after the gate is marked applied. Step 5 takes the publication advisory lock before installing the trigger, and `ConfigRepository` holds the same lock across publication (`0005_secret_reuse.sql:1`; `config_repository.dart:136–152`; `schema_steps.dart:124–153`). Specify the same lock order for step 10 and test an in-flight old publication, not just an insert started after the step. Describe the fence as preventing new publication: an equal-snapshot startup can take the no-op path without executing either trigger (`config_repository.dart:202–225`), so the gate is not proof that old processes stopped.

6. **Two future-facing rollout and identity constraints are not carried.** D22 makes binary downgrade unsupported after step 10 and requires keeping the source enabled through the drain; C9 carries only the upgrade order and publisher version. D14 prohibits using a stable alert-object ID as the native observation ID, but no carried entry preserves that requirement. Reusing the firing ID for its resolution silently turns the resolve into a duplicate. Add one entry targeting the source-ingress drain requirement and one targeting the generic identity contract or its runbook, with one destination apiece. Also correct the component diagram’s `raw_inbox, pinned` admission label and the sequence diagram’s `EventFieldError` sender-pointer branch; they conflict with the first-claim pin and the `EventPointerError` decision.

### Suggestions

None.

## Verdict

VERDICT: REVISE

D8 still overstates what the read-only preview can guarantee at production byte boundaries. This is round 4, the owner’s cap. Stop and escalate the open findings to the owner; do not start a fifth round or treat the change as approved.

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

Round-3 re-check:

- **Critical 1 — fixed.** D22 and the source-ingress drain requirement preserve the enabled source until pending raw work finishes and rule out binary downgrade. Publication replaces the old credential rows under exclusive source locks; admission rechecks the credential under a shared source lock (`config_repository.dart:229–255`; `admission.dart:66–99`). The supported procedure should explicitly remove all sender-held credentials rather than stop at the overlap phase. Finding 5 concerns the separate step-10 cutover.
- **Critical 2 — partly fixed; still blocking.** The owner’s new all-inserted/all-routed assumption addresses duplicates and quarantine. It does not bound provenance-dependent size, and the scenario does not test an estimate against actual worker charging. See Critical 1.
- **Critical 3 — fixed for production.** D21 charges the retained structured bytes after each event and before building the next. The NUL-expansion scenario exercises the original miss; an accepted event is at most 256 KiB. Preview’s claim of exact parity remains open under Critical 1. Rename the Resource Bounds row from “Decoded text” to “Serialized events” to match D21.
- **Critical 4 — fixed.** D9 still preserves mapping-free snapshot bytes; D15 caps only serialized mappings, not historical or whole snapshots. The existing equal-revision republish scenario remains applicable to a populated mapping-free upgrade.
- **Moderate 1 — partly fixed.** Serialized diagnostics are named, control-character expansion makes the byte-cap case reachable, S4 acknowledges the bounds, and the one-alert/multiple-error case is present. Add the design’s code tie-break to the requirement and cover body-level ordering and bounded collection as in Finding 1.
- **Moderate 2 — fixed on the original points.** The new subtype lives beside the sealed base. Decode-stage `event_too_large` uses `event`; commit-stage `batch_bound` uses no path. Mapping-named sender keys are explicitly allowed. The overlong-first-segment case is still undefined; see Finding 3.
- **Moderate 3 — partly fixed.** Optional null/absent, nested metadata, the 1,001-item limit, exponent rejection, and exact epoch maxima are now covered in the design or scenarios. The read-leaf and string-rendering contradictions remain, and the seconds boundary lacks a paired acceptance case. See Finding 2.
- **Moderate 4 — partly fixed.** D18 names the evaluator, readiness checks, same-rule expression change, bounded waits, and per-replica counter evidence. The spec still makes the drop case mandatory where A1 permits replacing it, and the automated manifest check does not enforce the evidence matrix. See Finding 4.
- **Moderate 5 — fixed on the cited points.** The outcome column is correctly described as text containing JSON; the worker charge includes insertion and route eligibility; D1 no longer attributes indexing to ADR 0008; C5 and C10 have distinct destinations; preview is explicitly read-only; and the cache rationale uses the serialized mappings cap. Finding 6 lists separate omitted constraints and diagram contradictions.