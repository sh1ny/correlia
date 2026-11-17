## MODIFIED Requirements

### Requirement: Check gate
`mise run check` SHALL be the gate run before every push and by CI on every pull request, and SHALL fail when
any of its steps fails. Its steps SHALL cover OpenSpec validation, static analysis of every package with no
issues, formatting, and the fast tests.

#### Scenario: Clean workspace
- **WHEN** `mise run check` runs on a workspace with no analysis issues, formatted code and passing fast tests
- **THEN** it exits 0

#### Scenario: Analysis issue
- **WHEN** a package has an analysis warning
- **THEN** `mise run check` exits non-zero and its output names the file and the issue

## ADDED Requirements

### Requirement: Linux CI verification
Every pull request to `main`, and every push to `main`, SHALL run one CI job named `Linux verification` on a
fresh Linux runner. It installs the pinned toolchain from the repository, then runs `mise run check` and
`mise run test:all`. The job SHALL fail when either command fails, and it SHALL never run the `load` tier.

#### Scenario: Passing pull request
- **WHEN** a pull request to `main` has a head on which `mise run check` and `mise run test:all` pass
- **THEN** the `Linux verification` check of that head concludes `success`

#### Scenario: Failing gate
- **WHEN** a pull request's head fails `mise run check` (for example, an unformatted file)
- **THEN** the `Linux verification` check concludes `failure`, `mise run test:all` is not run, and the job log
  names the failing step

#### Scenario: Failing test tier
- **WHEN** `mise run check` passes and a `db`, `e2e` or `plugin` test fails
- **THEN** the `Linux verification` check concludes `failure` and the job log names the failing test

#### Scenario: Pinned tools only
- **WHEN** the job installs its toolchain
- **THEN** every tool it runs is the version pinned in `mise.toml`, and `mise run check`'s doctor step passes
  on the runner

#### Scenario: Superseded run
- **WHEN** a new commit is pushed to a pull request while its previous `Linux verification` run is still
  running
- **THEN** the previous run is cancelled and only the new head's run reports the check

#### Scenario: Successive pushes to main
- **WHEN** three commits are pushed to `main` one after another while the first push's `Linux verification`
  run is still running
- **THEN** none of the three runs is cancelled or replaced by concurrency grouping, and each runs
  `mise run check` and `mise run test:all` for its own commit
