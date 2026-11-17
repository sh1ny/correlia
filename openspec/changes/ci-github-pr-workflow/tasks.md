# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| workspace-tooling → Check gate | Clean workspace | `tool/test/check_test.dart` | existing check gate tests (unchanged; re-run) | green |
| workspace-tooling → Check gate | Analysis issue | `tool/test/check_test.dart` | existing check gate tests (unchanged; re-run) | green |
| workspace-tooling → Linux CI verification | Passing pull request | `tool/test/ci_workflow_test.dart` + `evidence/ci-runs.md` | `job_runs_check_then_test_all_on_pr_and_main` + the PR's `Linux verification` run concluding `success` | test green; CI run pending |
| workspace-tooling → Linux CI verification | Failing gate | `tool/test/ci_workflow_test.dart` | `gate_failure_fails_job_before_test_all` | green |
| workspace-tooling → Linux CI verification | Failing test tier | `tool/test/ci_workflow_test.dart` | `test_all_failure_fails_job_and_load_never_runs` | green |
| workspace-tooling → Linux CI verification | Pinned tools only | `tool/test/ci_workflow_test.dart` + `evidence/ci-runs.md` | `toolchain_comes_from_mise_with_pinned_actions` + doctor step passing in the PR run | test green; CI run pending |
| workspace-tooling → Linux CI verification | Superseded run | `tool/test/ci_workflow_test.dart` | `pr_runs_share_a_cancelling_group` | green |
| workspace-tooling → Linux CI verification | Successive pushes to main | `tool/test/ci_workflow_test.dart` | `main_pushes_get_unique_uncancelled_groups` | green |

The workflow test parses `.github/workflows/ci.yml` and asserts the exact properties each scenario depends on.
These properties are: triggers, job name and runner, step order, no `continue-on-error` and no `|| true`,
no `load` tier, the concurrency expressions, `contents: read`, no `secrets.` references, and actions pinned to
40-hex SHAs. GitHub's own semantics are taken as given: a failed step skips the later ones, and
`cancel-in-progress` is evaluated per group. `evidence/ci-runs.md` records that the workflow runs on a real
runner. It is a fast-tier test (the `tool` package, run by `mise run check`).

## 1. Linux CI workflow

- [x] 1.1 Add `yaml` as a dev dependency of `tool` (`mise exec -- dart pub add --dev yaml` in `tool/`) and write
  `tool/test/ci_workflow_test.dart` with the six tests in the test map, plus `token_is_read_only_without_secrets`
  (D3). Run `cd tool && mise exec -- dart test test/ci_workflow_test.dart`: every test fails because
  `.github/workflows/ci.yml` does not exist.
- [x] 1.2 Write `.github/workflows/ci.yml` per design D1–D4:
  - job `Linux verification` on `ubuntu-24.04` with `timeout-minutes: 60`;
  - triggers: `pull_request` and `push` to `main`, and `workflow_dispatch`;
  - the D2 concurrency group;
  - `permissions: contents: read`;
  - `actions/checkout` v7.0.1 pinned by SHA, with `persist-credentials: false`;
  - `jdx/mise-action` v5.2.8 pinned by SHA, with `version: 2026.11.8`, `install: true` and `cache: true`;
  - `MISE_TRUSTED_CONFIG_PATHS`;
  - steps `mise run check`, then `mise run test:all`.

  Add `.github/workflows` to the files scanned by `tool/test/task_definitions_test.dart`. Run
  `cd tool && mise exec -- dart test`: all tests pass. Flip the six `ci_workflow_test.dart` rows' test parts
  green.

- [x] 1.3 Make `tool/test/doctor_test.dart` "a Windows dart earlier on PATH does not win over the pinned one"
  independent of the caller's mise activation. Found during apply (2026-11-17): with mise 2026.11.8, when
  every mise tool directory is already on PATH (an activated shell, or a runner after mise-action),
  `mise exec` keeps them in place instead of putting them first, so the fake `dart` wins and `mise run check`
  fails on HEAD. The test now starts from the caller's PATH without mise's install and shim directories.
  Run `cd tool && mise exec -- dart test test/doctor_test.dart`: it fails before the fix and passes after.

## 2. PR workflow settings and documents

- [ ] 2.1 `openspec/specwright.yaml`:
  - `finish: pr`;
  - `pr.merge: agent`;
  - `github.review_request.after_fixes: true`;
  - comments stating GitHub was enabled on 2026-11-15 (owner) and the old local-only comment removed.

  Verify with `bash .claude/skills/specwright-pr/scripts/pr-pair.sh context --code "$PWD"`: it reports
  `merge: agent` with no `bad_setting` or `settings_problem`.
- [ ] 2.2 `AGENTS.md`:
  - replace the "Nothing is pushed" rule with the PR workflow rule: every change reaches `main` through a PR
    from a change branch; never push to `main` or force-push; `Linux verification` and the required Codex
    review gate the merge; the agent merges ready PRs (`pr.merge: agent`);
  - replace the `finish: local` Specwright note with `finish: pr`.

  Verify with `grep -n 'Nothing is pushed\|finish: local' AGENTS.md`: no match.
- [ ] 2.3 `docs/plan/open-decisions.md` D17: record the owner's answer (2026-11-15: GitHub enabled, every change
  through a PR, agent merge, CI on Linux via `Linux verification`). Verify by reading the row.

## 3. Verification

- [ ] 3.1 Run `mise run check` from the change branch: it exits 0. This re-runs the existing check gate tests,
  so the "Check gate" rows stay green.
- [ ] 3.2 [evidence] Record the first `Linux verification` run on the PR head: the run URL, head SHA,
  conclusion, the duration of each step, and that the doctor step passed. If it fails, follow
  specwright-debug, fix, and record each run → evidence/ci-runs.md. Flip "Passing pull request" and "Pinned
  tools only" fully green when a run concludes `success`.

## Workflow follow-up

- Pre-ship review (specwright-review), then ship the PR (specwright-pr ship, `@codex review` requested as
  `sh1ny`), then watch.
- `main` still has `finish: local` and `merge: user` until this PR merges, so watch reads this PR's merge
  settings as drift. Merging this PR needs the owner's yes (or the owner merges it). Agent merge applies from
  the next PR.
