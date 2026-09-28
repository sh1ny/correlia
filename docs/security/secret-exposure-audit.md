# Secret-exposure audit — 2026-09-28

No real credential was confirmed in the inspected scope, and no candidate remains unresolved after contextual review and owner attestation. This is a bounded audit of reachable Git content, not a certification that the repository has never contained a secret.

This report supplies the historical-audit and prevention evidence for [issue #15](https://github.com/sh1ny/correlia/issues/15). Candidate values, locations, raw scanner reports, ref inventories and private triage notes are deliberately omitted.

## Scanner and confidentiality

- **Tool:** [Gitleaks v8.30.1](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1), temporary official Windows x64 release.
- **Release ZIP SHA-256:** `d29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e`, verified against the versioned release checksum manifest. This checks downloaded bytes, not independent publisher identity.
- **Configuration:** bundled default rules; no repository override, baseline, fingerprint ignore or fixture-only rule. Inline allow comments were ignored. Full redaction was enabled; verbose output was not used.
- **Bounds:** archive depth 1, decoding depth 1, maximum target size 20 MB.
- **Storage:** the mirror, extracted inputs, scanner outputs and scanner temporary storage were confined to an access-restricted local workspace outside the checkout. No candidate was submitted to an online validation service. Only this manually prepared summary is published.

## Frozen scope

The audited tracked tip was `8fd4569ceafdb2b7040bf64953de3e4539e05dbc`. Local refs and advertised remote refs were captured and reconciled in an isolated mirror before scanning.

| Ref category | Start inventory | End inventory |
|---|---:|---:|
| Remote branch heads | 3 | 4 |
| Remote tags | 1 | 1 |
| Advertised PR heads | 7 | 7 |
| Advertised PR merge refs | 0 | 0 |

Nine local refs were included separately: four local branches, four remote-tracking refs and one tag. The frozen mirror held 20 refs; these are ref records, not 20 disjoint histories. The sole remote change during the audit was creation of the authorized protection-test branch at the already-audited tip. No existing remote ref moved or disappeared, and that addition introduced no new objects.

Both source and mirror were non-shallow. Ref reconciliation found no mismatch; full Git object verification passed with no missing reachable object.

| Reachable object class | Count |
|---|---:|
| Commits | 528 |
| Annotated tag objects | 1 |
| Trees | 1,730 |
| Unique complete blobs | 2,946 |
| Total | 5,205 |

The complete-blob scanner input accounted for all **46,134,895 bytes** of the 2,946 blobs. Separate metadata input accounted for **265,673 bytes** from all 528 commit objects and the annotated tag. The corrected tracked-tip input contained **289 regular files**, totalling **3,546,891 bytes**. These files were extracted with binary `git cat-file --batch` reads; every payload's size and Git blob ID were verified before scanning. Input counts and bytes were reconciled against Git object sizes, independently of the scanner's patch count.

PR review identified LF-to-CRLF conversion in the original Windows `git archive` export: it added 64,939 bytes. That tip pass is superseded by the byte-exact rerun below. Reconstructing the original export reproduced its 3,611,830-byte input; scans of both exports returned the same three rule/path/line observations and raw Git source contexts. No new candidate context or owner attestation was needed. The original complete-blob and metadata passes used binary extraction, not the archive path; independently reconstructing the frozen ref inventories reproduced both snapshot digests and their recorded object counts and byte totals.

## Executed passes

| Pass | Inspected input | Scanner observations | Exit |
|---|---|---:|---:|
| Git history | Patches across all frozen refs with full-history traversal | 20 | 1 |
| Complete blobs | Every unique reachable blob | 25 | 1 |
| Metadata | Commit objects and annotated-tag text, separately extracted | 0 | 0 |
| Tracked tip | Byte-exact binary extraction of the audited tip, separate from the working directory | 3 | 1 |

All four reports were valid JSON, with no operational error diagnostics. Exit 1 was not accepted as proof of successful scanning by itself: qualification also demonstrated a scanner configuration error that returns 1 without a valid report. Findings and operational failures were assessed separately.

The 20 patch observations map to the five distinct matched lines in the complete-blob pass. All three tracked-tip observations also map to those groups. Counts overlap across passes and historical versions; they must not be summed as distinct credentials.

### Triage

| Complete-blob category | Historical observations | Basis |
|---|---:|---|
| Content-checksum manifest entry | 4 | Exact value derived from SHA-256 of a separately reachable Git blob |
| Static test fixtures | 13 | Test-function context and source provenance |
| Documentation examples | 8 | Two groups reviewed privately by the repository owner, who attested neither was ever issued or used to authenticate |
| **Total** | **25** | **Five distinct matched lines** |

Supplementary contextual review covered 110 distinct credential-assignment-pattern lines, three distinct credential-bearing URL lines and four sensitive-named blob versions. The URL examples appeared in 36 historical observations. Syntax-only matches were distinguished from literal values. Six additional distinct strings required owner review, in separate batches of four and two. The owner attested that all six were constructed examples, never issued or used to authenticate. Each answer was applied only to the exact entries presented; neither location in documentation nor an earlier answer established a later candidate's provenance. The final ledger accounts for all 117 contextual-review rows with none left unreviewed.

**Final disposition:** zero confirmed credentials, zero unresolved candidates. No revocation or rotation was required for these dispositions. The owner attestations are provenance evidence, not scanner-derived proof of credential validity. Raw values and per-candidate contexts were kept private throughout triage.

After the final dispositions and sanitized evidence were reconciled, the audit-created mirror, scanner download, extracts, raw reports, private triage notes and qualification fixtures were removed. No confirmed incident required retention of secret material.

### Coverage qualification and exclusions

Before real scanning, a disposable repository and fixture-only detector exercised:

- deleted historical content and tag-only reachable history;
- merge-only content found by complete-blob scanning but missed by patch scanning;
- commit-message-only and annotated-tag-only content in separate metadata inputs;
- a one-level ZIP member and explicit binary exclusion accounting;
- missing-object verification failure, missing-ref reconciliation failure, and scanner-error/report distinctions.

The fixture rule was not used for production scanning. The real inventory contained no NUL-bearing binary or non-UTF-8 blob, no blob above the size bound, no archive detected by the inspected ZIP/TAR/GZIP/7z/RAR signatures, no LFS pointer, no submodule gitlink and no symlink. No private-key block or key/certificate/database/archive-extension candidate was found by the contextual inventory. These are bounded inventory results, not proof that every possible container or encoding is recognized.

## Future-prevention proof

### Git staging policy

A disposable real-Git smoke exercised the proposed ignore file, not assertions about its text:

- Before the change, all six root/nested `.env`, `.env.local` and `.env.production` fixtures entered the index through ordinary staging.
- After the change, those six files were ignored. Root and nested `.env.example` files and an unrelated configuration file remained stageable.
- A previously tracked synthetic `.env` file remained tracked, demonstrating that ignore rules are not retroactive.
- The actual checkout's tracked environment-file inventory contained only `.env.example`.

The disposable fixture was removed. The unchanged sample-contract test was inspected but not rerun; sample contents did not change. No permanent source-string test or additional scanner integration was added.

### Native GitHub controls

An authorized administrator readback on **2026-09-28 at 16:41:01 UTC** showed repository secret scanning and repository push protection disabled. Both were enabled and read back as enabled at **16:41:18 UTC**. Only those two controls were targeted; unrelated settings and bypass permissions were preserved. The CLI identity was restored and verified as `KintsugiBot` afterward.

The repository owner authorized the work branch as the proof target. Its initial tip was the audited SHA above; it had no branch-protection rule that could masquerade as secret rejection. In a browser verified as signed in to `sh1ny`, the [GitHub-documented dummy token](https://docs.github.com/en/get-started/learning-to-code/storing-your-secrets-safely#2-committing-a-dummy-token) was entered into a disposable new-file edit. No real token was created or used.

At **16:47:08 UTC**, the attempted web commit was blocked with **“Secret scanning found a GitHub Secret Scanning secret on line 1.”** The attempt was cancelled, the editor changes discarded, and no bypass reason or “Allow Secret” action selected. At **16:47:57 UTC**, an independent ref readback confirmed the tip was unchanged. No fixture file or commit was published; the dedicated browser tab was released.

This qualifies the exercised **GitHub web-commit path** alongside repository-level settings. It does not claim a separate Git CLI or API push test. Repository administrators own continuing alert and bypass review; credential owners own any private revocation or rotation. See [contribution guidance](../../CONFIGURATION.md#keeping-credentials-out-of-git).

## Limits and issue criteria

Unavailable or unadvertised history, deleted/unreachable objects, forks, clones and cached SHA views were not audited. Hosted issue/comment text, Actions artifacts and other non-Git surfaces were outside this audit. No PR merge refs were advertised. No history rewrite, remote deletion, credential rotation or visibility change was performed.

Signature scanning can miss low-entropy passwords, unsupported formats and encodings. Archive qualification covered one-level ZIP, not every archive format. Native push protection has supported-pattern, size, processing and bypass limits; it is not universal credential prevention. A clean current tip does not dismiss historical exposure.

| Issue #15 criterion | Evidence |
|---|---|
| Tool/version, reachable-ref coverage and sanitized triage | Scanner, frozen scope, executed passes and triage sections above |
| Private remediation outcome for confirmed credentials | None confirmed after contextual review and owner dispositions; rotation not applicable |
| Environment exclusions with sample exception; tracked-file inspection | Git staging smoke and actual tracked environment inventory |
| Synthetic non-secret prevention proof and contribution guidance | Native settings plus cancelled secret-specific browser block; linked guidance |

Docker exclusions, credential-free samples, dependency-advisory scanning and the existing `Linux verification` workflow were preserved. They are separate safeguards, not substitutes for this audit or the native blocking proof. The audited SHA identifies the historical snapshot; it is not a claim that later revisions have been scanned.
