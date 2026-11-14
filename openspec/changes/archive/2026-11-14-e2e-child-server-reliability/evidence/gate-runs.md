# Gate runs

## Provenance

- Source: `c3edda3f3d164b29cd631485b603cd2f9f95dcd2`, branch `feat/e2e-child-server-reliability`.
- Runs 1–3: `mise run test:all -- --file-reporter json:<scratch>/runN.json`, default concurrency, standard load exclusion only. No test retries or timeout overrides.
- Working-checkout `mise run check` passed in 219.94s: 15 OpenSpec items, clean analysis/format/generated/protocol checks, fast/tool/widget suites passed.
- Direct stdout is absent from the JSON reporter; retry lines were collected from stdout. Labels follow the harness file’s fixed sequential test order.

## Results

| Run | Passed / total | Failures | Wall time (s) | Injected retry lines | Extra retry lines |
|---|---:|---:|---:|---:|---:|
| 1 | 461 / 461 | 0 | 690 | 6 | 0 |
| 2 | 461 / 461 | 0 | 677 | 6 | 0 |
| 3 | 460 / 461 | 1 | 616 | 6 | 0 |
| 4 (fresh clone) | 461 / 461 | 0 | 567 | 6 | 0 |

## Run 1

Result line: `11:00 +461: All tests passed!`.

| Five slowest e2e tests | Elapsed (s) | Timeout (s) | Used |
|---|---:|---:|---:|
| `Kill -9 during a 1,000-alert burst` | 107.62 | 360 | 29.9% |
| `nats_server_changed_with_work_pending` | 101.801 | 360 | 28.3% |
| `killing only the harness twice leaves no child, no cluster process, no extra root, and leaves an outside decoy untouched` | 75.607 | 360 | 21.0% |
| `DUR-8 crash budget exceeded` | 68.294 | 300 | 22.8% |
| `malformed_secret_or_credential_bearing_input_is_not_echoed` | 52.369 | 420 | 12.5% |

Within 25% of timeout: none among all e2e tests.

Lost-port retry lines:

```text
lost_api_port_is_retried_on_fresh_ports: ChildServer lost-port retry after attempt 1 (api=38075 web=38335 insights=46005)
port_lost_on_every_attempt_fails_after_three: ChildServer lost-port retry after attempt 1 (api=34967 web=44179 insights=42585)
port_lost_on_every_attempt_fails_after_three: ChildServer lost-port retry after attempt 2 (api=40331 web=39517 insights=45251)
exit_and_readiness_race_sees_retried_attempt: ChildServer lost-port retry after attempt 1 (api=36475 web=38999 insights=37597)
stolen_api_port_answering_200_is_not_ready: ChildServer lost-port retry after attempt 1 (api=40355 web=35417 insights=34383)
stop_during_pending_retry_starts_no_further_attempt: ChildServer lost-port retry after attempt 1 (api=46803 web=44435 insights=41877)
```

E2e results: 54/54 passed.

Failures: none.

## Run 2

Result line: `10:45 +461: All tests passed!`.

| Five slowest e2e tests | Elapsed (s) | Timeout (s) | Used |
|---|---:|---:|---:|
| `Kill -9 during a 1,000-alert burst` | 113.637 | 360 | 31.6% |
| `nats_server_changed_with_work_pending` | 93.433 | 360 | 26.0% |
| `killing only the harness twice leaves no child, no cluster process, no extra root, and leaves an outside decoy untouched` | 88.803 | 360 | 24.7% |
| `malformed_secret_or_credential_bearing_input_is_not_echoed` | 76.085 | 420 | 18.1% |
| `DUR-8 crash budget exceeded` | 61.204 | 300 | 20.4% |

Within 25% of timeout: none among all e2e tests.

Lost-port retry lines:

```text
lost_api_port_is_retried_on_fresh_ports: ChildServer lost-port retry after attempt 1 (api=42207 web=36117 insights=34923)
port_lost_on_every_attempt_fails_after_three: ChildServer lost-port retry after attempt 1 (api=41805 web=34923 insights=34201)
port_lost_on_every_attempt_fails_after_three: ChildServer lost-port retry after attempt 2 (api=43749 web=36329 insights=41711)
exit_and_readiness_race_sees_retried_attempt: ChildServer lost-port retry after attempt 1 (api=46125 web=43953 insights=34555)
stolen_api_port_answering_200_is_not_ready: ChildServer lost-port retry after attempt 1 (api=37839 web=46733 insights=46249)
stop_during_pending_retry_starts_no_further_attempt: ChildServer lost-port retry after attempt 1 (api=39679 web=44407 insights=34659)
```

E2e results: 54/54 passed.

Failures: none.

## Run 3

Result line: `09:50 +460 -1: Some tests failed.`.

| Five slowest e2e tests | Elapsed (s) | Timeout (s) | Used |
|---|---:|---:|---:|
| `Kill -9 during a 1,000-alert burst` | 114.75 | 360 | 31.9% |
| `nats_server_changed_with_work_pending` | 104.648 | 360 | 29.1% |
| `killing only the harness twice leaves no child, no cluster process, no extra root, and leaves an outside decoy untouched` | 78.274 | 360 | 21.7% |
| `DUR-8 crash budget exceeded` | 58.454 | 300 | 19.5% |
| `malformed_secret_or_credential_bearing_input_is_not_echoed` | 49.389 | 420 | 11.8% |

Within 25% of timeout: none among all e2e tests.

Lost-port retry lines:

```text
lost_api_port_is_retried_on_fresh_ports: ChildServer lost-port retry after attempt 1 (api=45433 web=45459 insights=35039)
port_lost_on_every_attempt_fails_after_three: ChildServer lost-port retry after attempt 1 (api=45207 web=38393 insights=36765)
port_lost_on_every_attempt_fails_after_three: ChildServer lost-port retry after attempt 2 (api=46253 web=35229 insights=44087)
exit_and_readiness_race_sees_retried_attempt: ChildServer lost-port retry after attempt 1 (api=37265 web=41267 insights=37061)
stolen_api_port_answering_200_is_not_ready: ChildServer lost-port retry after attempt 1 (api=45671 web=44619 insights=41761)
stop_during_pending_retry_starts_no_further_attempt: ChildServer lost-port retry after attempt 1 (api=34703 web=38433 insights=38775)
```

E2e results: 54/54 passed.

Out-of-scope failure: `plugin supervision through worker lifecycle plugin_ignores_shutdown`, owned by the separate M1 plugin-supervision shutdown follow-up described in [tasks.md → Workflow follow-up](../tasks.md#workflow-follow-up). That follow-up has not yet been assigned an OpenSpec change id.

```text
Expected: not null
  Actual: <null>

package:matcher                                 expect
test/plugin/plugin_supervision_test.dart 290:9  main.<fn>.<fn>

```

```text
Bad state: Future already completed
dart:async                                                     _AsyncCompleter.complete
package:correlia_server/src/pipeline/pipeline.dart 783:16      PipelineSubsystem.stop
package:correlia_server/src/ingest/ingest_workers.dart 102:60  IngestWorkers.stop
===== asynchronous gap ===========================
test/plugin/plugin_supervision_test.dart 106:9                 main.<fn>.<fn>

```

## Run 4 — fresh clone

- Fresh local `git clone --no-hardlinks --single-branch --branch feat/e2e-child-server-reliability` at source commit `c3edda3f3d164b29cd631485b603cd2f9f95dcd2`.
- Prepared with `mise exec -- flutter pub get` and `mise run setup`, then ran `mise run test:all -- --file-reporter json:<scratch>/run4.json` with default concurrency.
- Exit code: 0; result line: `09:19 +461: All tests passed!`.

| Five slowest e2e tests | Elapsed (s) | Timeout (s) | Used |
|---|---:|---:|---:|
| `Kill -9 during a 1,000-alert burst` | 106.825 | 360 | 29.7% |
| `nats_server_changed_with_work_pending` | 98.192 | 360 | 27.3% |
| `killing only the harness twice leaves no child, no cluster process, no extra root, and leaves an outside decoy untouched` | 67.982 | 360 | 18.9% |
| `DUR-8 crash budget exceeded` | 62.422 | 300 | 20.8% |
| `malformed_secret_or_credential_bearing_input_is_not_echoed` | 46.494 | 420 | 11.1% |

Within 25% of timeout: none among all e2e tests.

Lost-port retry lines:

```text
ChildServer lost-port retry after attempt 1 (api=42359 web=44555 insights=33429)
ChildServer lost-port retry after attempt 1 (api=42177 web=45481 insights=46609)
ChildServer lost-port retry after attempt 2 (api=42405 web=43541 insights=43547)
ChildServer lost-port retry after attempt 1 (api=46261 web=43441 insights=37993)
ChildServer lost-port retry after attempt 1 (api=45735 web=45305 insights=40701)
ChildServer lost-port retry after attempt 1 (api=33861 web=41411 insights=43021)
```

E2e results: 54/54 passed. SIGKILL child recovery and all five harness unit tests passed. All 461 server tests passed; no failures.

The clone’s own shared embedded cluster was stopped by its exact data directory before removing the scratch clone; the main checkout’s cluster and all unrelated PostgreSQL servers were left alone.

## Owner-amended acceptance (2026-11-14)

- Task 4.2 judges this change's scope: all e2e tests, every other child-server test, every touched test, and only the intentional lost-port retries.
- Runs 1–3 satisfy that scoped criterion: all 54 e2e tests and every other test except the untouched plugin-supervision test passed. The timeout guard also passed in the 83-test tooling suite within `mise run check`.
- Run 3's stopped status without a reason and non-idempotent `PipelineSubsystem.stop` are assigned to the separate M1 plugin-supervision shutdown follow-up in [tasks.md](../tasks.md#workflow-follow-up). No plugin fix is included here.
- The full zero-failure clean-clone gate remains an M1-close obligation; the owner explicitly authorized completing this harness change without absorbing that follow-up.
- All four runs satisfy the amended scoped criterion. Run 3 remains a recorded full-suite failure, not a claim of an all-green M1 gate.
