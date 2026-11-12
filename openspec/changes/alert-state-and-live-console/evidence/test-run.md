# Integration verification

Verified 2026-11-12 on `feat/alert-state-and-live-console`.
The acceptance run began from committed implementation with no outstanding source edits.
A formatter correction was committed as `4c0ef95` before the successful run.

## Commands

```sh
mise run check
mise run test:all
mise run build:web
```

All three completed successfully, in that order. The check gate took approximately
131 seconds, all-tier tests 307 seconds, and web compilation 22 seconds.

## Check gate

| Step | Result |
|---|---|
| Local password setup | Existing passwords preserved |
| Pinned schema-validator installation | Passed |
| Strict OpenSpec validation | 9 items passed |
| Toolchain doctor | All pinned Linux tools passed |
| Workspace Dart analysis, fatal infos | No issues |
| Flutter analysis, fatal infos | No issues |
| Formatting | 208 files, no changes |
| Serverpod generated-code consistency | Current |
| Event/protobuf compatibility and generation | Compatible and current |
| Fast server tests | 138 passed |
| Workspace tool tests | 64 passed |
| Flutter controller/widget tests | 16 passed |

## All-tier run

`mise run test:all` passed 285 server tests, with no failures and no skipped
acceptance scenarios. Tier registration counts reconcile with that observed total:

| Tier | Passed |
|---|---:|
| Fast | 138 |
| Database | 71 |
| End-to-end | 37 |
| Plugin processes | 39 |
| Total | 285 |

The manual `load` tier was not selected. The separate tool and Flutter suites are
included in `mise run check`, not in the 285-test server total.

Focused proofs during implementation included schema red/green verification,
12 pure ordering/transition tests, 49 combined state/feed/pipeline checks, and
3 real-client HTTP/WebSocket live-feed tests. The real-peer tests exposed and
verified the IPv4-mapped IPv6 loopback guard correction. Feed tests synchronize
with the cluster-wide xmin watermark, including transactions in other test databases.

## Built-console runtime proof

`mise run build:web` produced `correlia_server/web/app` successfully, including a
successful WebAssembly dry run. A temporary real `ChildServer` ran with:

```text
--mode test --apply-migrations --process-role api
```

It served the built Flutter application with HTTP 200 from its assigned web
listener. Chromium loaded that bundle from the API-role server. Its configured
API URL remained the normal local development backend, `http://localhost:8080`.

Browser verification showed the live empty alert list at 1280×800 and a working
filter/no-match state at 430×800, without overflow or browser JavaScript errors.
Non-empty live updates, resolution, partial reconciliation and reconnect behavior
are covered by the passing widget and real-client e2e scenarios.

The development runner was hot-restarted after integration. The temporary API-role
child exited successfully through stdin shutdown, and its embedded cluster root,
scratch program, browser tab and screenshots were removed. The SDK's web build
removed an obsolete generated-plugin-registrant ignore entry; that automatic
ignore-file upgrade is retained with this integration evidence.

## Approved pre-ship corrections

The owner requested all three nonblocking findings from the first pre-ship review
be fixed. The follow-up restored `flutter_driver` to development dependencies,
made informational duplicates leave alert state untouched, and distinguished a
pending list reconciliation from a known omitted-alert count.

Both behavioral regressions were observed failing for their reported causes
before the fixes: an informational duplicate changed `lastObservedAt`, and the
growing list displayed an unsubstantiated zero omitted count. After correction:

- `test/db/alert_state_test.dart`: 19 passed, including the new informational
  duplicate regression and all existing state scenarios.
- `correlia_flutter/test/alert_list_page_test.dart`: 8 passed, including the new
  overflow-to-reconciliation indicator regression.
- `mise run analyze`: no issues in workspace or Flutter analysis.
- Scoped `dart fix`: nothing to fix; changed Dart files formatted.

The 285-test all-tier and 16-test Flutter totals above describe the initial
acceptance run; these follow-up regression tests add one database and one widget
case without reclassifying or replacing that recorded run.

## Follow-up review corrections

A second review identified subscriptions accepted before the watermark subsystem
started. The regression test subscribed first and then started the subsystem;
before correction it timed out without a wake-up. Startup now schedules polling
for already-connected subscribers as well.

The test map attaches the new regressions to existing spec scenarios. A vacuous
local-variable source-time assertion was removed and replaced by a database case
that checks both the persisted event column/payload at the original two-hour-ahead
source time and the alert fence at the five-minute clamp.

The combined watermark, alert-state and ordering test files passed 26 tests after
correction. Strict OpenSpec validation passed all 9 items; scoped feed `dart fix`
reported nothing to fix.

## Client ordering correction

The next review found that the client used freshness as a fallback sort key for
unknown firing times, unlike the server's nulls-last snapshot order. The new
controller regression first observed the incorrect order `[3, 2, 1, 4]` instead
of `[1, 4, 2, 3]`. The comparator now places unknown firing times last and uses
the entity id for equal/unknown times. All 18 controller and widget tests passed
after correction.

## Final corrected-code acceptance run

A clean-tree run at code commit `633357a7e951a1cb7fc6981238c18576cc6042f5`
passed all three acceptance commands after every reported review correction:

- `mise run check`: strict OpenSpec validation (9 items), toolchain doctor,
  workspace and Flutter analysis, formatting (208 files unchanged), generated
  code and protocol compatibility checks, 138 fast server tests, 64 tool tests,
  and 18 Flutter controller/widget tests.
- `mise run test:all`: 288 server tests passed across the fast, database, e2e
  and plugin tiers. The manual load tier was not selected.
- `mise run build:web`: production bundle built successfully; Wasm dry run
  succeeded.

Task coverage still reports all 20 tasks covered exactly once, with no missing
evidence or pending task groups. OpenSpec apply reports `all_done` (20/20).
