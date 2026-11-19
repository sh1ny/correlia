I've finished rechecking the required edits against `tasks.md` and `design.md`. All five are in place.

# Recheck: source-model-and-secrets, findings C1–C4

- **Scope:** I checked only findings C1–C4 and required changes 1–5 from `review.md` against the amended `tasks.md:165-213` and `design.md:242-260`. I did not reopen closed findings or the optional notes.
- **How:** I only read files; I ran no builds or tests. I also read `_publish` in `correlia_server/lib/src/ingest/config_repository.dart:109-153` to confirm what runs before secret validation.

## Required changes

| # | Finding | Required change | Amended text | Status |
|---|---|---|---|---|
| 1 | C1 | One shared publication gate in `_publish`, after parsing and before any write, with a distinct code under `format_version` | `tasks.md:177-179`: "In the common `_publish` path, after parsing and before any writes, reject v2 at `format_version` with a distinct `not_enabled` code." Because `publishConfig` and `publish(IngestBootstrap)` both reach `_publish`, one gate there covers both. | Resolved |
| 2 | C4 | A named DB test that blocks writes and still proves v1 works over HTTP | `tasks.md:179-182`: `v2_publication_cutover` in `test/db/ingest_config_test.dart`. Both publication paths reject v2, including a fileless input using stored references. The active snapshot is kept, and no snapshot, secret or credential rows are added. A higher v1 revision still publishes, and its bearer token is still accepted over HTTP. | Resolved |
| 3 | C2 | Full group 5 regression gates, and existing snapshot keys kept | `tasks.md:176`: "retain the existing routing and identity fields so M1 and v2 pins both work". `tasks.md:187-188`: `mise run check`, the DB and plugin tiers, and the `authenticated_source_delivery` and `sec_1_another_source_token` end-to-end cases. | Resolved |
| 4 | C3 | Stored-reference lookup covers v2 references; group 6 tests a fileless v2 publication | `tasks.md:176-177`: "Share reference parsing with stored-material lookup (`token_ref` and `credentials[].ref`)." `tasks.md:210-211`: fileless v2 publication using stored credentials. | Resolved |
| 5 | C4 | Group 6 replaces the gate assertion | `tasks.md:210-211`: "Remove the temporary publication gate. Replace the rejection in `v2_publication_cutover` with a fileless v2 publication using stored credentials and a 202 bearer admission." | Resolved |

`design.md:251-254` (the "V2 activation cutover" paragraph in D11) matches this split: group 5 rejects v2 publication, and group 6 enables it.

## Remaining wording (non-blocking)

- **Gate position:** Required change 1 asked for the gate before secret validation; the task says "before any writes". In `_publish`, the revision-conflict check (`config_repository.dart:132-146`) and `_validateCommitments` (`:148`) are both read-only and run before the first write. So the no-write guarantee holds either way. But a v2 input at an equal revision could fail with an activation conflict instead of `not_enabled`. Saying "immediately after `prepare`" in the task, or using a higher revision in the test, would rule that out.
- **Asserted code:** The test text says "reject v2" but doesn't explicitly say to assert `not_enabled` at `format_version`. The sentence just before it defines that code, so this is only a clarity gap.

Prior verdict: approve with changes; changes applied.

## ID-3 amendment re-review

Independent review: Claude Code, Opus 5.5. The first pass found that the existing decoder
derives the display description from a 1024-scalar projection. The owner approved deriving
the display description from the original annotation without changing identity or deduplication.

The re-review confirmed the existing independent 4096/1024 canonical bounds and checked that
the amended proposal, spec, and task require two exact raw deliveries, one event, and one duplicate
observation. Required edits before apply: align the oversize annotation scenario with the
independent bounds, extend its regression with an intermediate-length input, track it under
7.1 rather than 7.3, and use “scalar” in the proposal. All were applied.

VERDICT: APPROVE_WITH_CHANGES

CHANGES_APPLIED: yes