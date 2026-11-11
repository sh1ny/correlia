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
