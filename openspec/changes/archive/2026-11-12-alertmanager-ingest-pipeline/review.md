# Review

## Metadata

- **Round:** 5
- **Prior round:** Round 4 was a localized recheck of the user-approved D3 amendment. It returned VERDICT: APPROVE_WITH_CHANGES with CHANGES_APPLIED: no and two Required Changes: M1 (an events primary-key conflict on a `future_dated` redelivery would use up the internal-error budget) and M2 (tasks.md did not reflect the SQL-owned/managed split). Suggestions A1–A3 and S1–S5 were open and nonblocking.
- **Reviewer:** cross-model CLI (claude, claude-opus-5-5)
- **Reviewed:**
  - **Change artifacts:** `openspec/changes/alertmanager-ingest-pipeline/`
    - review.md (Round 4 findings and Required Changes, :33-101)
    - design.md D3 (:51-59), D4 (:61-70) and the decision summary row for D3 (:107)
    - tasks.md :3 and group 1 (:66-70)
    - `specs/durable-pipeline/spec.md` :51-59, checked only to confirm the optional THEN clause
  - **Review template:** `openspec/schemas/specwright/templates/review.md`
  - **Skills and rules:** `.claude/skills/serverpod-{models,database,migrations,testing}/SKILL.md`, `serverpod-overview/SKILL.md` and the project AGENTS.md. These were used only as the frame for the Round 4 checks; no unchanged decision was reopened.
  - **Not re-inspected:**
    - D1, D2 and D5–D7; Round 3's approval covers them, and Round 4 covers D3.
    - The other spec deltas.
    - The implementation drafts in `lib/src/ingest/` and `test/unit/ingest/`, as instructed.
  - **Not done:** this was a read-only review. No tests were run and no files were written.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

None.

### Moderate

None. Round 4's M1 and M2 are both fixed. The checks below follow the order of Round 4's Required Changes.

**Round 4 M1: events-key conflicts. Fixed.**
- **D3 (design.md:54):**
  - D3 now says: "The events key is not a dedup authority: the observation key deduplicates eligible evidence, while identical quarantined evidence at the same observed time collapses on the events primary key." This matches the required text.
  - The PK list at :53 is still exactly `(observed_at, raw_id)`, `(observed_at, event_id, disposition)` and `(created_at, delivery_id)`. No columns changed.
- **D4 (design.md:66):**
  - Quarantined (`future_dated`) event inserts use `ON CONFLICT` on the events PK `DO NOTHING`.
  - An existing row is recorded as a duplicate quarantine in the raw outcome.
  - D4 says explicitly that this expected conflict "never consumes the internal-error budget".
  - It adds that a redelivery at the same observed time still completes and cannot prevent later eligible evidence from getting its first observation key.
  - This closes the `processing_exhausted` path described in Round 4 and keeps D4's "unexpected SQL" classification at :64 consistent. A PK conflict is now an expected outcome, not an unexpected one.
- **Cross-disposition safety:** `disposition` is a PK column, so a `future_dated` row can never collide with a later `late` or ready row for the same `event_id`/`observed_at`. That keeps the guarantee in "Future quarantine does not poison dedup" (spec:57-59).
- **Same-batch duplicates:** two members of one raw batch that share an id are also covered, because they share one `observed_at` and the insert now does nothing on conflict.
- **Spec THEN clause:** not added. Round 4 marked it as optional, so this is not a gap.

**Round 4 M2: tasks.md alignment. Fixed.**
- **tasks.md:3:** now cites "localized review round 4". It needs no further correctness change; the orchestrator updates this prose after receipt, as instructed.
- **Task 1.2 (tasks.md:69):**
  - Managed model definitions and generated outputs are limited to exactly source/config/active pointer, secret commitments, transport_keys, observation_keys, pipeline_failures and delivery_attempts.
  - It states that raw_inbox, events and outbox have **no** `.spy.yaml` table model. They are created only in `schema/*.sql` with their exact composite PKs and accessed through typed handwritten immutable records and parameterized `unsafeQuery`/`unsafeExecute` repositories.
  - "Never hand-edit generated definitions" is kept.
  - T21 now checks, from the catalog, each SQL-owned table's exact PK columns and its time-qualified reference columns on both the fresh and the upgraded path. It also checks that the generated `definition*.json` files do not contain those tables.
  - Together these cover ORM reintroduction, PK drift and drift between the two ownership paths.
  - The text matches the user-approved D3 and the decision summary row (:107).
- **Task 1.3 (tasks.md:70):**
  - The docs item now includes "the repair-migration review procedure for SQL-owned tables".
  - It still runs schema initialization after Serverpod managed migrations and before ingest work, on both the startup path and the non-rollback test-helper path. Generated tools stay untouched.

### Suggestions

**Amendment-related, nonblocking (carried from Round 4):**

- **A1. Make the repair guidance concrete.** Task 1.3 now names the procedure.
  - **Content:** the doc should tell operators to remove any generated statement that touches `schema_versions`, raw_inbox, events or outbox before applying a repair `migration.sql`.
  - **Check:** if feasible, cite the pinned CLI's actual behavior for tables that exist in the live database but not in the definition.
- **A2. State the foreign-key policy in both directions,** i.e. whether SQL-owned tables may hold foreign keys to managed tables.
- **A3. Pin down `outbox.created_at`.** State that it is set once inside the effect transaction and never updated, and that references always carry `(created_at, delivery_id)` and `(observed_at, raw_id)` together.
- **A4 (new, minor). Make the duplicate-quarantine outcome observable.**
  - **Scope:** D4:66 says "record an existing row as a duplicate quarantine in the raw outcome". D7's list of durable raw-result counts (design.md:92) names only `upstream_omitted`/`committed`/`duplicate_observation`.
  - **Suggestion:** when implementing T28, either add a `duplicate_quarantine` count next to them or state that it is folded into `duplicate_observation`. Also consider adding a parameterized T28 case for a concurrent identical `future_dated` redelivery at an equal `observed_at`.

**Carried forward from Round 2/3, unchanged and still nonblocking:**

- **S1.** The api role holds webhook signing keys it never uses; consider a public commitment in config or record the exposure under Risks.
- **S2.** Token rotation always has a rejection window; consider a bounded previous-token overlap or document the rotation order.
- **S3.** Bound the pre-authentication database lookup in the design text (:45, :218).
- **S4.** Add a `batch_bound` scenario, and consider referencing event bytes from the outbox instead of copying them for each output.
- **S5.** Change the `truncatedAlerts` row wording from "committed source counter" to "raw-result count", and add D7 counter buckets lazily for sources activated by another process.

## Verdict

There are no Critical or Moderate findings.

- **Round 4 required changes:**
  - **M1:** applied in D3 (:54) and D4 (:66) as specified, with the PK columns unchanged.
  - **M2:** applied at tasks.md:3, task 1.2 (:69) and task 1.3 (:70) as specified.
- **User decision:** both edits keep the user-approved D3 exactly: SQL-owned composite-key tables, exact keys, typed handwritten records, parameterized SQL and no surrogate `id`.
- **Not reopened:** D1, D2 and D5–D7, the other spec deltas and the implementation drafts. Round 3 and Round 4 still cover them.
- **Open suggestions:** A1–A4 and S1–S5 are all nonblocking.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

The two Round 4 Required Changes, both now applied and rechecked:

1. **M1: handle event-key conflicts in design.md.**
   - Applied at design.md:54 (D3, events key is not a dedup authority) and design.md:66 (D4, `future_dated` inserts use `ON CONFLICT DO NOTHING` on the events PK, the result counts as a duplicate quarantine, and no internal-error budget is used).
   - The PK columns are unchanged.
2. **M2: align tasks.md with the amended D3.**
   - Applied at tasks.md:3 (round 4 reference) and tasks.md:69 (task 1.2: SQL-owned tables are excluded from `.spy.yaml` table models, plus typed records and parameterized SQL; T21 checks exact PKs and time-qualified reference columns from the catalog on the fresh and upgraded paths, and that the tables are absent from `definition*.json`).
   - Also applied at tasks.md:70 (task 1.3: repair-migration review procedure).

CHANGES_APPLIED: yes

## Rebuttals

- **Round 1 M1 (strict unknown fields):** rebutted by the author and accepted by the reviewer in Round 3. No change.
- **Round 1 S3 (timestamp in the signature), not built:** acknowledged. No change.
- **Round 1 M2–M8, Round 2 M1–M5:** fixed and verified, as recorded in Round 3.
- **Round 4 M1:** fixed (design.md:54, :66); verified in Round 5.
- **Round 4 M2:** fixed (tasks.md:3, :69, :70); verified in Round 5.
- **Round 4 A1–A3, Round 5 A4, Round 2/3 S1–S5:** not addressed. They remain open Suggestions and need no rebuttal.