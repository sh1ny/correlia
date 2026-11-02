# Writing the PR title and description

The diff is already on GitHub. The description explains what the diff cannot show: why, what was decided and rejected, what to look at, how it was verified. Cut any sentence a reader could reconstruct from the diff.

**Title:** imperative, under 72 characters, names the outcome ("Fix double-submit on checkout", not "Update checkout.rb"). Match the repo's convention (check `git log`). Never mark a change breaking (`!`, `BREAKING CHANGE:`) without the user's confirmation.

**Size by decision cost, not diff size:**

| Change | Body |
|---|---|
| Small and obvious | 1-2 sentences, under ~300 characters |
| Small but non-obvious | 3-5 sentences: why, the key decision, how verified |
| Large or risky | Sections below, ~100 lines at most |

**Opening:** one or two sentences carrying one idea - what changes for the user or system, and why now.

**For an OpenSpec change:** link the change (`openspec/changes/<name>/` or its archive path) instead of restating the proposal. Pull the "why" from proposal.md and the key decisions (with rejected alternatives) from design.md.

**Store-backed changes** (planning in an OpenSpec store, so the change has a code PR and a store PR):
- The **store PR** carries the planning: its body is the change summary (why and the key decisions from proposal.md and design.md) and links the change folder in the store. When there is no code PR (no code commits, no code PR in any state), say `No code changes: this change is planning-only.`
- The **code PR** links the store PR instead of restating the proposal: `Planning: <store PR url>`. When no store PR is expected (the store has no GitHub remote), name the store branch to share instead.
- Write each body once; `pr-pair.sh link` adds the cross-link marker comment when the peer PR did not exist yet.

**Sections for large changes** (omit any that would be empty):
- Why
- What changed (grouped by area, not by file)
- Decisions and trade-offs (what was rejected and why)
- Risk and rollback
- Verification (commands run and results; a test map summary if there is one)
- Review focus (where a reviewer should look hardest)

**Review** (a section of its own, only when it has content; omit it when none of the three lists below has an entry). What the pre-ship review left for the PR's readers:
- Spec amendments made in response to it: the commits in `<main>..HEAD` of either repo with an `Amendment:` trailer, each with its class (clarification or behaviour-change) and what it changed. Drift amendments from apply have no `Amendment:` trailer and were already re-reviewed by the design review, so they are not listed.
- P2 and P3 findings left open: priority, file, line and title.
- Waived P0/P1 findings, each with the user's reason.
Read the findings and waivers from the record that `review-run.sh gate` matched (its `open` and the record's findings and `waivers`), never from memory of the review.

**References:** `Fixes #N` only when the PR fully resolves issue N; otherwise `Related: #N` (a partly resolved issue gets `Related`, never a closing keyword). Never invent issue numbers.
- One keyword per issue, each on its own line: `Fixes #21`, `Fixes #24`. Never `Fixes #21, #24`: GitHub reads only the first reference after a keyword.
- Closing lines go on the PR in the repository that holds the issue (normally the code PR). In a store-backed change the store PR uses `Related: <owner>/<repo>#N` for those issues.
- When no PR is expected in the repository that holds the issue (a planning-only store-backed change whose issues are in the code repo), the PR that does exist carries `Fixes <owner>/<repo>#N` on its own line.
- GitHub applies closing keywords only on a PR into the default branch. After `ensure-pr`, ship runs `pr-pair.sh closing-check` to compare these lines with what GitHub will close. It reads them from GitHub's own rendering of the description (`POST /markdown`, in the PR's repository as context): text GitHub renders as code, such as a fenced block, indented code, a code span or an HTML comment, is never read, and text it renders as prose is. When the rendering cannot be read the check exits 3, and ship reports it as not done.

**Evidence:** label test output as test output. Screenshots only for visible UI changes.

**Templates:** if the repo has a PR template, it is the minimum structure and wins on conflict.

**Audit before posting:** (1) Does every sentence say something the diff does not? (2) Is the length proportional to the decisions a reviewer must make? (3) Are all claims (tests run, issues fixed) true?
