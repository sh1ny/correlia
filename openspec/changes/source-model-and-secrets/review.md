# Review

## Metadata

- **Round:** 2 (second recheck of required changes)
- **Prior round:** The Round 2 recheck returned APPROVE_WITH_CHANGES with required changes N1 and N2. This recheck covers only whether N1 and N2 were resolved and any defects those amendments introduced. Earlier findings (M1–M4, S7, D8 sharing) are not reopened.
- **Reviewer:** fresh-context subagent (Claude Agent SDK, claude-opus-5-5)
- **Reviewed:**
  - `openspec/changes/source-model-and-secrets/{review.md,proposal.md,design.md,tasks.md}`
  - `specs/{secret-store,output-delivery}/spec.md` (the other deltas are untouched by N1/N2)
  - Current spec `openspec/specs/output-delivery/spec.md:61-110`, used to check that the new MODIFIED delta matches the existing requirement headers and keeps their scenarios

  Read-only. No builds or tests run.

## Recheck of Required Changes

| ID | Required change | Status | Evidence |
|---|---|---|---|
| N1 | Groups 3 and 4 use the same plugin commitment scheme; `--tags plugin` added to 3.3's verification | **Resolved** | See below. |
| N2 | Historical file references pinned by live work are imported; `validateLiveSecrets` accepts same-transaction imports; test extended; output-delivery MODIFIED delta added | **Resolved** | See below. |

**N1 evidence:**
- Task 3.3 now keeps plugin snapshot commitments in their M1 scheme "until the Configure resolver and commitment writer cut over together in group 4" (`tasks.md:114-115`). The `hmac-sha256:` assertion that used to be in 3.3 is gone.
- Task 4.2 switches the commitment writer, the Configure resolver and the `plugin_output_activates` assertion in the same group (`tasks.md:139-144`).
- Task 3.3's verification now runs `mise run test -- --tags plugin` (`tasks.md:122`).
- Group 3 therefore writes bare SHA-256 plugin commitments, which the unchanged Configure check still accepts. The cutover rule at `design.md:159-163` holds.
- New `secret_record` rows for plugin secrets carry the keyed commitment (`design.md:83-84`). This causes no conflict in group 3: the resolver checks the requested commitment by its scheme (`design.md:80-83`), and Configure does not read the store until 4.2.

**N2 evidence:**
- **D5:** Publication imports historical references still pinned by live outbox work. Webhook references are checked against `signing_key_commitment` and plugin references by scheme. Import uses the same rebinding and `key_mismatch` checks, and the candidate set is limited to the supplied file entries (`design.md:118-126`). The user decision is recorded at `design.md:128-130` and as summary row `:277`.
- **Flow gap:** The new "Upgrade with queued M1 work" entry is at `design.md:402-404`.
- **Task 3.3:** Imports file entries pinned by live webhook intents or plugin definitions that are absent from the new config. It verifies pinned commitments by scheme, keeps the M1 `ingest_secret_commitment` check for unstored references, and validates live webhook keys against the store, including records imported in the same transaction (`tasks.md:103-108`). `missing_webhook_key_fails_startup` now seeds a reference absent from both store and file (`tasks.md:108-109`).
- **Test, task 4.1:** `m1_plugin_work_drains_after_upgrade` now seeds an M1 webhook row signed under a historical key that is absent from the upgraded config but present in the file. It asserts the import, a successful startup, and delivery with unchanged pinned digests after a restart without the file (`tasks.md:128-133`). Test map row `tasks.md:18` traces the new output-delivery scenario to it.
- **Spec delta:** `specs/output-delivery/spec.md` modifies three requirements whose headers match the current spec exactly (`openspec/specs/output-delivery/spec.md:61,77,96`):
  - "Signing key availability before acquisition"
  - "Kind-aware startup validation"
  - "Validated plugin output definitions"

  Every existing scenario is kept. The startup check is now store-based and accepts same-transaction imports (`specs/output-delivery/spec.md:23`). The new scenario "M1 work with historical secret references drains after upgrade" is at `:41-44`.
- **Proposal:** Updated to match (`proposal.md:38-39,59-60`).

**Security invariant check:** A record is sealed for a historical reference only when the supplied bytes match a commitment already pinned by live work, or pass the M1 `ingest_secret_commitment` rebinding check (`design.md:120-124`, `tasks.md:105-107`). The amendment therefore cannot attach new bytes to a pinned reference. It adds no unkeyed plugin-secret hash: historical plugin records get keyed record commitments (`design.md:83-84`), and the pinned bare hashes already existed in M1 (`design.md:88-91`). The import scan is limited to the operator file's entries (128 at most, `design.md:383`), not the whole outbox (`design.md:121-122`).

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

- **S8 — Group 3 checks startup against the store, but relays and Configure still read the file (introduced by the N2 move of the store-based check into 3.3).**
  - After 3.3, `validateLiveSecrets` reads the store (`tasks.md:107-108`) and the secret file becomes optional (`tasks.md:109-110`).
  - The webhook relay filter (`loadedReferences`) and plugin Configure (`bootstrap.secret`) switch to the resolver only in 4.2 (`tasks.md:139-142`).
  - In between, a worker started without the file would pass startup but leave webhook work queued and report `plugin_secret_unavailable`.
  - No group 3 gate starts a worker without the file, so no verified boundary goes red. This is not required. Consider a one-line note in 3.3 that running without the file is supported only from group 4.
- **S9 — Wording.** The "Upgrade from M1" flow gap still says the first publication "imports the referenced secrets" (`design.md:411-413`). The new entry at `:402-404` covers historical imports, so this is ambiguous but not contradictory. Consider "imports the referenced secrets and file material pinned by live work".

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

None remaining. N1 and N2 are resolved; S8 and S9 are optional.

CHANGES_APPLIED: yes

## Rebuttals