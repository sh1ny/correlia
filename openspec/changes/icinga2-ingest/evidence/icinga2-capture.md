# Icinga 2 capture run (task 9.4)

Date: 2026-11-20. Capture host: linux-x64 (WSL2 Ubuntu 24.04, Docker). linux-arm64 was not captured: the
owner chose on 2026-11-20 not to register QEMU emulation on this host, so arm64 has no qualified pair and its
artifact is built but not published.

## Script

- `tool/icinga2_capture.sh` (driver `correlia_server/tool/icinga2_capture/`), script version
  `1` (recorded in every `manifest.json`).
- Full run: `tool/icinga2_capture.sh 2.16.6 2.15.7 2.14.10 2.13.14`, every mapped scenario, no failed scenario.
- Re-run after review: `CAPTURE_ONLY=first_check_result_of_a_new_host_is_down,retained_state_across_a_restart
  tool/icinga2_capture.sh 2.16.6 2.15.7 2.14.10 2.13.14`, adding the daemon start time
  (`/v1/status/IcingaApplication` `program_start`) to the first-problem evidence; no failed scenario.
- Sender artifact (linux-x64): SHA-256 `f61fb561668a32be0f2e09a4757bfa66f9007965e826262a66bac69da6f455c9`, the same in every manifest. A rebuild with
  `mise run build:icinga2-notify` reproduced it byte for byte.
- Definitions: `contrib/icinga2/` SHA-256 per file in each manifest
  (`correlia-commands.conf` `61ed6c9b80eaf5d1…`,
  `correlia-functions.conf` `4f2e6549bc0b491c…`,
  `correlia.conf` `847ffbb96fad73a6…`).

## Gate results per pair

Gates: S = same-second service state, H = same-second host state, N = same-second notification time,
C = production notification clock, D = downtime removal, F = first problem of a new object,
202 = recorded 202 and decoded event. Judged by `correlia_server/test/unit/ingest/icinga2_versions_test.dart`
on the committed captures (52 tests, all passing).

| Release | Architecture | Image | Digest | Icinga 2 | S | H | N | C | D | F | 202 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2.13.14 | linux-x64 | `icinga/icinga2:2.13.14` | `sha256:9012302e8a7413209ae7f3fa73ad121971b8b6cbfccd5fd50fc613e3a5ab2ad7` | v2.13.14 | pass | pass | pass | pass | pass | pass | pass |
| 2.14.10 | linux-x64 | `icinga/icinga2:2.14.10` | `sha256:7bc65998bd2438471695dd091498a33b806d5abc039aa06747e1524b395efc09` | v2.14.10 | pass | pass | pass | pass | pass | pass | pass |
| 2.15.7 | linux-x64 | `icinga/icinga2:2.15.7` | `sha256:bf4a1f12d7f5aa2589df2d4065b70a4c484b31ae5edbd91b66a57631272fa253` | v2.15.7 | pass | pass | pass | pass | pass | pass | pass |
| 2.16.6 | linux-x64 | `icinga/icinga2:2.16.6` | `sha256:2748b8d8166435f3419de68b704d5eac7671e74d97f7dea6ffa1f04738c74902` | v2.16.6 | pass | pass | pass | pass | pass | pass | pass |

Observations recorded by the captures:

- Every release sends `DOWNTIMEEND` for both the expiry and the manual removal of a triggered downtime.
- The runtime-created host's first HARD DOWN carries the first HARD result's execution end, about 24 s after
  the daemon's `program_start` on every release, and its row is applied, not `late`.
- 2.13.14 and 2.14.10 log a failed command's output unquoted (`output: <text>`); 2.15.7 and 2.16.6 quote it.
- The order in which a refire's PROBLEM and a delayed RECOVERY are delivered differs by release; each yields one
  event and one `duplicate_observation`.

## Statement

`docs/ingest-pipeline.md`, "Supported Icinga 2 releases": 2.13.14, 2.14.10, 2.15.7 and 2.16.6 on linux-x64.
`mise run release:icinga2-notify` published linux-x64 only and reported "not published linux-arm64: no
qualified pair".
