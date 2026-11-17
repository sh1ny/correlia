# Proposal

## Why

On 2026-11-15 the owner moved Correlia to GitHub. The rebuild replaced the legacy Python history on
`sh1ny/correlia` `main`; that history is kept on the remote branch `legacy/python`. From now on every change
reaches `main` through a pull request. The repository still describes the local-only era:
- `finish: local` in `openspec/specwright.yaml`;
- the "Nothing is pushed" rule in `AGENTS.md`;
- open decision D17.

There is also no CI. ADR 0014 says CI is added by the first change after the owner enables GitHub, and that it
runs `mise run check` and every test tier except `load` on Linux. `main`'s branch protection already requires
a status check named `Linux verification`. Nothing produces that check now, so no pull request can merge until
this change adds it.

This change serves M1 (walking skeleton). It advances the exit criterion "`mise run check` and every test tier
except `load` pass from a clean clone": once this change lands, every pull request runs that check on a fresh
Linux runner instead of only on the owner's WSL checkout.

## What Changes

- Add a GitHub Actions workflow with one job, `Linux verification`. It runs on every pull request to `main`
  and on every push to `main`. It installs the pinned toolchain through mise and runs `mise run check`, then
  `mise run test:all`.
- `openspec/specwright.yaml`:
  - `finish: pr` and `pr.merge: agent`, so a ready PR is merged by the agent after its required reviewer and CI
    pass;
  - `github.review_request.after_fixes: true`.
  - The comments say the GitHub workflow is enabled.
- `AGENTS.md`: replace the "Nothing is pushed" rule with the PR workflow rule (every change goes through a PR,
  never push `main` directly, CI and the Codex review gate the merge), and update the Specwright note on
  `finish`.
- `docs/plan/open-decisions.md`: resolve D17 (GitHub enabled 2026-11-15, CI on Linux).
- `workspace-tooling` spec: a requirement that pull requests run the Linux CI gate. The check gate is run
  before every push and is also run by CI.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workspace-tooling`: adds the "Linux CI verification" requirement (pull requests and `main` run the check
  gate and every tier except `load` on a plain Linux runner, under the job name branch protection requires),
  and amends "Check gate" to say CI runs it too.

## Impact

- New `.github/workflows/ci.yml`. It is the only CI. The legacy Python workflow left `main` when the history was
  replaced.
- `openspec/specwright.yaml`, `AGENTS.md`, `docs/plan/open-decisions.md`. Specwright's ship, watch and finish
  steps go from local merges to PRs, and the agent merges them.
- GitHub Actions minutes (public repository). Each run is about 15 minutes: `check` takes about 3 minutes and
  `test:all` about 10 minutes locally.
- No product code, API, schema or migration changes.

## Decision Making

DECISION_MAKING: autonomous
- **Source:** setting

### S1: Move to the GitHub PR workflow

- **Choice:** `finish: pr`. Every change reaches `main` through a PR, and branch protection requires a PR.
- **Rejected:** staying on `finish: local` (the owner ended the local-only rule).
- **Reversal cost:** low
- **Important:** yes (changes behaviour and settings users see)
- **Chosen by:** user ("All workflow should go through a PR from here on")

### S2: Agent merges ready PRs

- **Choice:** `pr.merge: agent`. Watch merges a PR once the required reviewer (`chatgpt-codex-connector`) has
  reported on the ready head and the required check passes.
- **Rejected:** `merge: user` (the owner merges every PR by hand).
- **Reversal cost:** low
- **Important:** yes (changes behaviour users see)
- **Chosen by:** user ("4 -merge:agent")

### S3: Re-request review after fixes

- **Choice:** `github.review_request.after_fixes: true`. Because `pr.reviewers` is set, Specwright already
  re-requests the tagged Codex review after each pushed fix. The key records the owner's intent and keeps the
  behaviour if `pr.reviewers` is ever removed.
- **Rejected:** leaving it `false`.
- **Reversal cost:** low
- **Important:** no
- **Chosen by:** user ("also do after_fixes: yes so we re-request reviews after fixes on pr's")

### S4: CI scope is the full gate on every PR

- **Choice:** One job, `Linux verification`. It runs `mise run check`, then `mise run test:all`, on pull
  requests to `main` and on pushes to `main`. `load` is excluded.
- **Rejected:** check only (leaves the db, e2e and plugin tiers unverified off the owner's machine); a matrix
  of one job per tier (more setup minutes, and branch protection would need every job name).
- **Reversal cost:** low
- **Important:** yes (binds future changes: the required check name and what it proves)
- **Chosen by:** agent (ADR 0014 sets the scope; the job name matches the existing protection rule)
