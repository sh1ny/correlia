# Review

## Metadata

- **Round:** 7
- **Prior round:** 6, APPROVE_WITH_CHANGES (M1–M4). This round only rechecks those Required Changes.
- **Reviewer:** Claude (Opus 5.5), fresh-context independent reviewer.
- **Reviewed:** `review.md`, `design.md`, `specs/plugin-output-protocol/spec.md`, `tasks.md`, `proposal.md`, `AGENTS.md`, plus the `openspec/architecture.md` in-force index and ADR 0023:21 for the immutability rule.
- **Tier:** FULL (scoped recheck).
- **Method:** I only read artifacts. I changed no files and ran no builds or tests. I did not count the implementation predating the diagnostic amendment as a finding, as instructed.

## Findings

### Critical (blocking)

None.

### Moderate

None. All four round-6 Required Changes are resolved (see Rebuttals).

### Suggestions

- **S1:** `AGENTS.md` has no ADR immutability rule. The rule is in ADR 0023:21 ("Accepted ADRs are immutable") and in the convention the index follows (`architecture.md:230-265`). When task 4.4 writes ADR 0026, it could cite 0023:21 as the authority. There is also precedent for listing a partial supersession in the index's Supersedes column (0021's "none (clarifies 0004/0019)", `architecture.md:248`). Following it, 0026's row would read "0025 D1 Configure response (partial)", and 0025 would stay in the in-force table and out of Superseded ADRs. Not required: task 4.4 already says 0025's other decisions stay in force.
- Round-6 S1 (`nats_unavailable`) and S2 (duplicate-window check) remain optional. I don't repeat them as findings.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

Each round-6 Required Change has a matching edit, and the documents agree with each other. The precedence, exclusivity, scrubbing and separate classification rules now read the same in D1, D11, D19, the Failure and Resource Bounds tables, the spec requirement and both scenarios. The ADR substitution satisfies M3 without editing an accepted record. Tasks 4.1 and 5.1 can be verified honestly. Nothing from round 5 was reopened.

## Required Changes

None remaining. All round-6 items have been applied and verified.

CHANGES_APPLIED: yes

## Rebuttals

- **M1: resolved.**
  - D1 (`design.md:85-89`) runs the 64 KiB response and frame checks first (`plugin_metadata_invalid`). It then checks information bounds, the class, and accepted/rejected exclusivity (`plugin_protocol_error`) before classifying acceptance or rejection, and it states the exclusivity rule.
  - The Resource Bounds row (`design.md:659`) states the same order and the same two classes.
  - Spec requirement :26 states exclusivity and `plugin_protocol_error`.
  - The Accepted scenario (:30) states the 64 KiB-first precedence, the entry/key/value bounds, and that error fields on an accepted response fail.
  - The Rejected scenario (:34) states the within-bounds precedence and that configuration information or an invalid class on a rejected response fails with `plugin_protocol_error`.
  - Both round-6 ambiguous cases now have exactly one outcome.
- **M2: resolved, option (a).**
  - D11 (`design.md:344-346`) adds nullable `lastPluginErrorClass`, and `lastErrorClass` stays `plugin_config_rejected`.
  - D1:90-91 silently drops the plugin class if its ASCII bytes contain any non-empty resolved secret's exact bytes. The Rejected scenario (:34) states this.
  - D19 (:508-509) keeps only the host class and mirrors plugin classes in status only, so admission and backoff policy are unaffected.
  - Failure table :641 reads "Status `plugin_config_rejected` with separate scrubbed plugin class `stream_missing`".
  - The secret leak path from round 6 is closed.
- **M3: resolved by the repository-required substitution, which I explicitly accept.**
  - Task 4.4 (`tasks.md:121`) writes accepted ADR 0026. It supersedes only ADR 0025 D1's Configure response and does not edit 0025.
  - The same task updates the architecture protocol boundary and the in-force index. It covers diagnostic fields, bounds, exclusivity, secret scrubbing and separate host/plugin classification, verified by `mise run spec:validate` and a read-back against D1.
  - The amendment note (`tasks.md:111-116`) and design's ADR section (`design.md:738-741`) list it.
  - This covers my finding: third-party authors get an in-force record of the shipped Configure contract, and accepted ADRs stay immutable (ADR 0023:21). My round-6 wording ("update ADR 0025 D1") is withdrawn.
  - The rejected free-text alternative is in D1:97-99, so 0026's read-back against D1 will carry it.
- **M4: resolved.** Tasks 4.1 (:118) and 5.1 (:125) now require "each scenario's assertions run against the real API, with no placeholder or skipped case, under the 2026-11-12 sequencing exception". The remaining "verify they fail" wording is only in tasks outside the exception: 2.x and 3.x (already done) and 7.1 (`tasks.md:137`), which is correct.
- **Round 5:** I reopened nothing and found no new evidence against those choices.