All five Round 2 Required Changes are in place in the current design.md and the three specs, so the verdict stays APPROVE_WITH_CHANGES and I set CHANGES_APPLIED to yes. I only read files: nothing was edited or run, and review.md was not written. The full review text for the wrapper is below.

---

# Review

## Metadata

- **Round:** 3
- **Prior round:** Round 2 returned VERDICT: APPROVE_WITH_CHANGES with 0 Critical, 5 Moderate (M1–M5) and 5 Suggestion findings, CHANGES_APPLIED: no. The Moderate findings were: M1 config revert impossible under content-addressed snapshot ids; M2 a worker without config idle after the queue drains; M3 pipeline retry budget contradicting the spec; M4 rejecting annotation values; M5 unsanitized startup errors. This round is the required localized recheck of those five Required Changes only. It is not a new full architecture review.
- **Reviewer:** cross-model CLI (claude, claude-opus-5-5)
- **Reviewed:**
  - **Change artifacts:** `openspec/changes/alertmanager-ingest-pipeline/`
    - review.md (round 2)
    - design.md
    - `specs/source-ingress/spec.md`
    - `specs/durable-pipeline/spec.md`
    - `specs/integration-alertmanager/spec.md`
  - **Review template:** `openspec/schemas/specwright/templates/review.md`
  - **Not re-inspected (taken as given):**
    - proposal.md and `specs/output-delivery/spec.md`. The author states they are unchanged since Round 2.
    - Server source, ADRs and planning documents. They were already covered in Round 2, and this recheck is limited to the five edits.
    - The project `SKILL.md` files and `AGENTS.md`. They remain constraints on the future implementation and produced no finding.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

None.

### Moderate

None open. Each Round 2 Moderate finding was checked on its own against its Required Change:

**M1 (config revert): resolved.**
- **Format and preimage:** design.md:33 adds a required integer `revision` from 1 to 2147483647 to `format_version: 1`. design.md:34 includes the revision in the snapshot-id preimage.
- **Activation rule (design.md:34):**
  - An input id equal to the active id is a no-op.
  - An unseen snapshot activates only when its revision is greater than the active revision, or when no snapshot is active.
  - Every other input fails startup, naming only the input and active ids and revisions, without changing source admission or the active pointer.
- **Revert procedure:** design.md:34 says a revert republishes earlier content with a higher revision, which creates a new snapshot.
- **Tables:**
  - The D1 summary row is updated (design.md:103).
  - The Failure & Visibility row covers stale and equal-conflicting revisions (design.md:201).
  - The bootstrap bounds row includes the revision range (design.md:217).
- **Spec:**
  - The source-ingress requirement now states increasing revisions and the stale/equal-conflict failure (source-ingress spec:67).
  - Scenarios: "Stale bootstrap cannot revoke the rotation" now uses lower-revision version A (:77-79); "Revert by higher revision" (:89-91); "Conflicting equal revision" (:93-95).
- **Older snapshots:** activation is strictly monotonic, so every stored inactive snapshot has a lower revision than the active one. A stale process cannot reactivate it.

**M2 (worker without config): resolved.**
- design.md:33 now requires worker/all to fail startup with sanitized active-config and unfinished-work counts whenever an active ingest snapshot exists **or** pending raw or queued/delivering work exists.
- The Failure & Visibility row at design.md:201 matches.
- The source-ingress requirement at spec:67 says the same.
- The new scenario "Missing worker config after drained queue" (source-ingress spec:97-99) asserts the startup failure and that readiness never becomes ready.

**M3 (pipeline retry budget): resolved.**
- **Design:**
  - design.md:63 says serialization failures, deadlocks, lock timeouts and connection-unavailable errors retry indefinitely under capped backoff without consuming the budget.
  - Only other internal errors (statement or transaction deadline exceeded, unexpected SQL or programming errors) consume the five-attempt budget.
  - On exhaustion, the raw row is `failed` with `processing_exhausted` and a `pipeline_failures` row, keeping its pin and bytes, with no partial effects.
  - The resource bounds row (design.md:222) states the 1..30 s capped backoff, that transient errors never consume the budget, and that "transient outage cannot exhaust accepted work".
- **Spec:**
  - durable-pipeline spec:35 is reworded to match.
  - DUR-1 (:37-39) now asserts that repeated transient failures beyond five leave the internal-error budget unchanged and the pin intact.
  - The new scenario "Processing budget exhaustion" (:45-47) is present.

**M4 (annotation values): resolved.**
- **Design:**
  - The `alerts[].annotations` Field Mapping row (design.md:240) keeps the map count and keys within bounds, truncates long display values with the canonical marker, and keeps full originals only in the raw bytes.
  - Summary and description are projected from those bounded values, so overflow is visibly marked in both.
  - design.md:248 limits rejection to map counts/keys, annotation count/key and original-input bounds.
- **Spec:**
  - integration-alertmanager spec:55 contains the exact required sentence: "Display text, annotation values and label projections SHALL truncate with a marker".
  - spec:62 now says "annotation count/key bound".
  - The new scenario "Oversize annotation value" (:69-71) asserts that the delivery completes, the projections are visibly truncated, the full original stays in the raw bytes, and the fingerprint and event id are unchanged.

**M5 (sanitized startup errors): resolved.**
- **Design (design.md:33):**
  - Bootstrap and secret parsing and validation catch every parser, URI and IO exception.
  - They expose only an allowlisted error type containing file kind, a bounded field path and an error code.
  - Neither `toString` nor stack-associated messages may include input excerpts, secret values or URLs, explicitly because server.dart prints startup errors verbatim.
- **Spec:** the new source-ingress scenario "Malformed secret or credential-bearing input is not echoed" (spec:101-103) asserts this against captured stderr and logs.

### Suggestions

Round 2 Suggestions S1–S5 are carried forward unchanged. They are still open and nonblocking.

**S1. The api role must hold webhook signing keys it never uses.** Publication computes signing-key commitments (design.md:35) and fails on unavailable secrets (source-ingress spec:73-75), so the internet-facing api needs the HMAC keys.

A compromised api can already forge deliveries by writing outbox rows, so the extra exposure is limited. Still, an exfiltrated key allows offline forgery that lasts until the key is rotated. Consider carrying a public `sha256` commitment in the output config, so that only worker/all load signing bytes. At minimum, record the exposure under Risks.

**S2. Token rotation always has a rejection window.** Each source has exactly one current token, so senders get 401 between publication and their own config update. As far as I know, Alertmanager retries only 5xx and transport errors, not 4xx. The group is then sent again at its next flush, which delays it rather than losing it. A bounded previous-token overlap would be cheap to add now, while the stored config format is still new. Otherwise, document the rotation order in the setup guide.

**S3. Bound the pre-authentication lookup.** Authentication queries the database before the 16-read admission bound applies (design.md:45, :218). An unauthenticated flood can therefore take connections from the pool that the `all` role shares with the pipeline and relays. Take the admission slot, or a separate small bound, before the lookup, and return 503 at the bound.

**S4. Add a batch-bound scenario, and consider referencing event bytes instead of copying them.** With 1000 alerts of about 2 KiB and 8 outputs, a delivery exceeds the 16 MiB aggregate that counts fanout copies (design.md:221). It then fails deterministically, but no spec scenario covers `batch_bound`. Separately, architecture.md:97 already keeps events alive "while referenced by a pending or dead-lettered outbox row". If intents referenced the immutable event row, fanout would no longer multiply stored bytes.

**S5. Two wording cleanups.**
- The Field Mapping row for `truncatedAlerts` still says "committed source counter" (design.md:245). This contradicts D7, which uses durable raw-result counts and never touches source rows. Say "raw-result count".
- D7 prunes the counter map "on config publication" (design.md:90, :193). That never happens for sources that another process activates. Add buckets lazily, up to the 64+1 bound, for sources authenticated from the database.

## Verdict

There are no Critical findings. All five Round 2 Required Changes were applied as specified and each was confirmed independently. None of them reverses a `Chosen by: user` decision. The Suggestions remain open and nonblocking.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

All five were applied and re-checked by the reviewer in Round 3.

1. **M1: monotonic config revision in D1.**
   - Required integer `revision` from 1 to 2147483647, included in the snapshot-id preimage.
   - Activation rule: same id is a no-op. An unseen id activates when its revision is greater than the active revision, or when no snapshot is active. Anything else fails startup naming only ids and revisions, with no change to state.
   - A revert republishes earlier content with a higher revision.
   - Updated: the D1 summary row, the Failure & Visibility row and the bootstrap bounds row.
   - source-ingress scenarios: lower-revision stale restart, "Revert by higher revision" and "Conflicting equal revision".
   - *Verified:* design.md:33-34, :103, :201, :217; source-ingress spec:67, :77-79, :89-95.
2. **M2: fail a worker without config whenever ingest is configured.**
   - worker/all without config fails startup with sanitized counts when an active snapshot exists or pending raw or queued/delivering work exists.
   - Added the scenario "Missing worker config after drained queue".
   - *Verified:* design.md:33, :201; source-ingress spec:67, :97-99.
3. **M3: align the pipeline retry policy.**
   - Serialization, deadlock, lock-timeout and connection-unavailable errors retry indefinitely with capped 1..30 s backoff and never consume the budget.
   - Other internal errors consume five attempts, then the row becomes `processing_exhausted` with its pin and raw bytes retained and no partial effects.
   - The spec is reworded, DUR-1 is extended and "Processing budget exhaustion" is added.
   - *Verified:* design.md:63, :222; durable-pipeline spec:35-39, :45-47.
4. **M4: truncate long annotation values instead of rejecting them.**
   - Values over the bound truncate with the canonical marker, and the original stays in the raw bytes.
   - Count and key bounds still reject.
   - The spec sentence and bound wording are updated, and "Oversize annotation value" is added.
   - *Verified:* design.md:240, :248; integration-alertmanager spec:55, :61-63, :69-71.
5. **M5: sanitized startup errors.**
   - Parser, URI and IO exceptions are caught, and only an allowlisted error with file kind, field path and code is exposed.
   - Added the scenario "Malformed secret or credential-bearing input is not echoed".
   - *Verified:* design.md:33; source-ingress spec:101-103.

CHANGES_APPLIED: yes

## Rebuttals

- **Round 1 M1 (strict unknown fields), rebutted by author: accepted by reviewer.**
  - `AGENTS.md:108-109` is an explicit, in-force project rule: normalizers "reject unmapped fields loudly".
  - ADR 0021's tolerant reading (0021:93-97) applies to readers of canonical events with a newer v1 minor. It does not apply to upstream Alertmanager v4 payloads.
  - design.md:248 documents the upgrade and replay risk and keeps failed raw bytes for M2 replay.
  - Relaxing this would be an **owner policy decision** that changes `AGENTS.md`, not a design fix this change can make on its own.
- **Round 1 S3 (timestamp in the signature), not built:** acknowledged. design.md:283 records that the HMAC covers authenticity only and that receivers must deduplicate by event id. It was a Suggestion, so it needs no acceptance.
- **Round 1 M2–M8 and S1, S2, S4–S7:** verified as fixed in Round 2. Not re-reviewed in this round.
- **Round 2 M1–M5:** fixed by the author and verified by the reviewer in Round 3.
  - **M1:** design.md:33-34, :103, :201, :217; source-ingress spec:67, :77-79, :89-95.
  - **M2:** design.md:33, :201; source-ingress spec:67, :97-99.
  - **M3:** design.md:63, :222; durable-pipeline spec:35-39, :45-47.
  - **M4:** design.md:240, :248; integration-alertmanager spec:55, :61-63, :69-71.
  - **M5:** design.md:33; source-ingress spec:101-103.
- **Round 2 S1–S5:** not addressed. They remain open Suggestions and need no rebuttal.