# CI runs: `Linux verification` on PR #66

Every `Linux verification` run on the PR head, in order. Each failure was diagnosed to its root cause before the
fix. Nothing was re-run without a change, and no test was skipped or weakened.

## Run 1: failed at the check gate

- Run: https://github.com/sh1ny/correlia/actions/runs/44088772938
- Head: `547b28314e48bca23c574d06a01a3b6a7026f518`
- Conclusion: `failure` (13:02:25Z to 13:04:49Z, 2026-11-17)

| Step | Conclusion | Duration |
|---|---|---|
| Check out the repository | success | 1 s |
| Install the pinned toolchain with mise | success | 2 min 14 s (cold cache; Flutter about 119 s) |
| Check gate | failure | 1 s |
| Test tiers (fast, db, e2e, plugin) | skipped | - |

Failure (job log, `setup` task of `mise run check`):

```
Because correlia_flutter requires the Flutter SDK, version solving failed.
Flutter users should use `flutter pub` instead of `dart pub`.
```

Root cause: on a freshly extracted Flutter SDK, the first bare `dart` call goes through Flutter's
`bin/internal/shared.sh` `upgrade_flutter`. That deletes `bin/cache/flutter.version.json` and returns early
for `dart`, without rebuilding it. Only the `flutter` command writes the file back. pub then cannot read the
Flutter version and refuses the workspace. Developer machines had already run `flutter`, so it never showed
locally. A fresh clone on a prepared SDK resolves fine; that was checked locally.

Fix: `871179191655e01208b99605aa97a42fd671c90f` adds a "Prepare the Flutter SDK" step
(`mise exec -- flutter --version`) before the gate. This was a design D1 amendment, and design review round 3
approved it.

The run also showed the "Failing gate" scenario for real: the gate failed, the test-tier step was skipped, and
the log named the failing step.

## Run 2: check gate passed; 473 of 474 tests passed

- Run: https://github.com/sh1ny/correlia/actions/runs/44090816148
- Head: `871179191655e01208b99605aa97a42fd671c90f`
- Conclusion: `failure` (13:14:53Z to 13:34:41Z, 2026-11-17)

| Step | Conclusion | Duration |
|---|---|---|
| Check out the repository | success | 5 s |
| Install the pinned toolchain with mise | success | 18 s (cache hit) |
| Prepare the Flutter SDK | success | 17 s |
| Check gate | success | 4 min 3 s |
| Test tiers (fast, db, e2e, plugin) | failure | 14 min 56 s |

Doctor step inside the check gate, on the runner (job log):

```
ok  dart 3.13.7 /home/runner/.local/share/mise/installs/flutter/3.47.9/bin/dart
ok  flutter 3.47.9 /home/runner/.local/share/mise/installs/flutter/3.47.9/bin/flutter
ok  go 1.27.3 /home/runner/.local/share/mise/installs/go/1.27.3/bin/go
ok  buf 1.75.0 /home/runner/.local/share/mise/installs/buf/1.75.0/buf/bin/buf
ok  openspec 1.16.0 /home/runner/.local/share/mise/installs/npm-fission-ai-openspec/1.16.0/node_modules/.bin/openspec
ok  serverpod_cli 4.1.0 /home/runner/.pub-cache/hosted/pub.dev/serverpod_cli-4.1.0
```

Test tiers: `473 tests passed, 1 failed.` The one failure:

```
test/plugin/plugin_host_test.dart: invalid startup fails bounded and reaps own child
Expected: not null
  Actual: <null>
test/plugin/plugin_host_test.dart 266:5
```

Line 266 is `expect(foreignFailure.evidence, isNotNull)` in the foreign-owner socket case. Its fixture starts
under `unshare --user --map-root-user --map-auto` to get a socket owned by another UID. Ubuntu 24.04 restricts
unprivileged user namespaces through AppArmor (`kernel.apparmor_restrict_unprivileged_userns=1`), so the fixture
never started, startup failed for another reason, and no ownership evidence was recorded. WSL has no such
restriction, which is why the case passes locally.

The run also passed the e2e tests, `plugin_ignores_shutdown` and `health_call_stalls_under_load`, which had been
flaky locally.

Fix: an "Allow unprivileged user namespaces" step before the test tiers, which lifts the sysctl on the
throwaway runner and then runs `unshare --user --map-root-user --map-auto -- true` so a missing prerequisite
fails by name. This was a design D1 and D3 amendment.

## Run 3: cancelled (superseded)

- Run: https://github.com/sh1ny/correlia/actions/runs/44095228953
- Head: `d4be3da88d032cda738e431e46f1f87c417f1c8d`
- Conclusion: `cancelled` (13:41:21Z to 13:56:53Z, 2026-11-17)

It was still running when the feedback fix `035c8be` was pushed to the PR, and the PR concurrency group cancelled
it, which is the "Superseded run" scenario on a real run. `035c8be` added the prerequisite checks to the
user-namespace step (Kody review) and the head-bound Codex report rule (Codex security review, P2).

## Run 4: success

- Run: https://github.com/sh1ny/correlia/actions/runs/44097789647
- Head: `035c8beed8515493ad59bb0900bbe9cb85d8a4ef`
- Conclusion: `success` (13:56:35Z to 14:20:00Z, 2026-11-17; job about 23 min)

| Step | Conclusion | Duration |
|---|---|---|
| Check out the repository | success | 1 s |
| Install the pinned toolchain with mise | success | 28 s (cache hit) |
| Prepare the Flutter SDK | success | 18 s |
| Check gate | success | 5 min 2 s |
| Allow unprivileged user namespaces | success | under 1 s |
| Test tiers (fast, db, e2e, plugin) | success | 17 min 9 s |

- Doctor step: every tool `ok` at its pinned version under `/home/runner/.local/share/mise/installs/` (dart 3.13.7,
  flutter 3.47.9, go 1.27.3, buf 1.75.0, openspec 1.16.0, serverpod_cli 4.1.0), as in run 2.
- Check gate: 213 fast server, 91 tool and 19 widget tests passed.
- User-namespace step: `kernel.apparmor_restrict_unprivileged_userns = 0`, `/usr/bin/newuidmap` and
  `/usr/bin/newgidmap` found, subordinate ranges present, and `unshare` succeeded.
- Test tiers: `474 tests passed.` That includes `plugin_host_test.dart: invalid startup fails bounded and reaps own
  child`, `plugin_ignores_shutdown` and `health_call_stalls_under_load`.

"Passing pull request" and "Pinned tools only" are green on this run.
