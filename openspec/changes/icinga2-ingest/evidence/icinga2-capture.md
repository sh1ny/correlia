# Icinga 2 capture run (task 9.4)

Date: 2026-11-20. Capture host: linux-x64 (WSL2 Ubuntu 24.04, Docker). linux-arm64 was not captured: the
owner chose on 2026-11-20 not to register QEMU emulation on this host, so arm64 has no qualified pair and its
artifact is built but not published.

## Script

- `tool/icinga2_capture.sh` (driver `correlia_server/tool/icinga2_capture/`), script version
  `10` (recorded in every `manifest.json`). Version 2 routes the capture source to a webhook output and records
  each committed event's outbox intents; its downtime scenario tells the expiring and the hand-removed downtime
  apart by comment and records when the manual removal was requested. Version 3 adds
  `concurrent_signed_notifications_beyond_the_cap`: three signed notifications from one Icinga 2 action overlap
  at Correlia through a proxy that holds each request's last byte until Correlia logs its refusal. A partial run
  that selects `retained_state_across_a_restart` without the first-problem scenario it relies on is refused.
  Version 4 adds a case to `macro_text_in_a_setting_is_literal`: the sender installed at a path holding macro
  text (`/usr/local/bin/correlia-$host.name$-notify`) is run from exactly that path. Version 5 records, for
  every admitted request, the proxied body's SHA-256 and size and the raw row's id and stored digest, which the
  decode gate matches against each event's raw reference. It adds twenty CUSTOM notifications through each
  unmodified command, whose emitted notification times the clock gate measures, and a `nul_in_a_file_path`
  case whose sender path holds a NUL with a working sender at its prefix. Version 6 adds two cases to
  `setting_not_deliverable_exactly`: a relative token path, and a bare sender name with a working sender on
  `env`'s default search path. Version 7 adds a token and an HMAC key pasted as their file paths to that
  scenario, with a scan of Icinga 2's log for both; pulls each image for linux/amd64, runs it by the inspected
  image ID and records that ID, the image's platform and the machine `uname -m` reports in the container; and
  records when Icinga 2 accepted each submitted check result. The driver counts only the sampled CUSTOM
  notifications of the clock scenario as samples (other deliveries stay recorded). Version 8 adds a sender path
  holding `=`, with a working sender at it, to `setting_not_deliverable_exactly`, and records what the
  definitions make of that path; `captured_host_transitions` now submits only a DOWN and then an UP result.
  Version 9 writes random values to the wrong token and wrong HMAC key files and has the rejection scenario
  scan Icinga 2's log for them, and for each rejected header both whole and as its bare token or digest.
  Version 10 adds an accepted HTTPS delivery to `inherited_correlia_settings_are_ignored`: no `--ca-file`, a
  fresh certificate for 127.0.0.1 appended to the container's distribution bundle for that case only, a
  forwarder that ends TLS in front of the recording proxy, and `CORRELIA_CA_FILE` in Icinga 2's environment.
  A secret scan that finds a value now fails its scenario, and the value is redacted from the evidence file.
- Full run (after the pre-ship review, round 11, which stopped an abandoned delivery from sending after the
  deadline and captured a delivery that trusts the distribution's bundle): `tool/icinga2_capture.sh 2.16.6`
  first, to check the new case, then `tool/icinga2_capture.sh 2.13.14 2.14.10 2.15.7`; every mapped scenario on
  each release, no failed scenario.
- Sender artifact (linux-x64): SHA-256 `122240da645ab6cd0f4ed52ccf0dce555dd9a38ad858206b20dae0d1c08e9e0c`, the same in every manifest.
  `mise run release:icinga2-notify` rebuilds it and publishes it only because the rebuild has this hash.
- Definitions: `contrib/icinga2/` SHA-256 per file in each manifest
  (`correlia-commands.conf` `783f1cb92391d4cd…`,
  `correlia-functions.conf` `f57295b61cb1a82b…`,
  `correlia.conf` `ba23a7c8031d5783…`).

## Gate results per pair

Gates: S = same-second service state, H = same-second host state, N = same-second notification time,
C = production notification clock, D = downtime removal, F = first problem of a new object,
202 = recorded 202 and decoded event. Judged by `correlia_server/test/unit/ingest/icinga2_versions_test.dart`
on the committed captures (72 tests, all passing).

| Release | Architecture | Image | Digest | Icinga 2 | S | H | N | C | D | F | 202 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2.13.14 | linux-x64 | `icinga/icinga2:2.13.14` | `sha256:9012302e8a7413209ae7f3fa73ad121971b8b6cbfccd5fd50fc613e3a5ab2ad7` | v2.13.14 | pass | pass | pass | pass | pass | pass | pass |
| 2.14.10 | linux-x64 | `icinga/icinga2:2.14.10` | `sha256:7bc65998bd2438471695dd091498a33b806d5abc039aa06747e1524b395efc09` | v2.14.10 | pass | pass | pass | pass | pass | pass | pass |
| 2.15.7 | linux-x64 | `icinga/icinga2:2.15.7` | `sha256:bf4a1f12d7f5aa2589df2d4065b70a4c484b31ae5edbd91b66a57631272fa253` | v2.15.7 | pass | pass | pass | pass | pass | pass | pass |
| 2.16.6 | linux-x64 | `icinga/icinga2:2.16.6` | `sha256:2748b8d8166435f3419de68b704d5eac7671e74d97f7dea6ffa1f04738c74902` | v2.16.6 | pass | pass | pass | pass | pass | pass | pass |

Observations recorded by the captures:

- Every release sends `DOWNTIMEEND` for both the expiry and the manual removal of a fixed downtime, and each
  commits an informational event with one outbox intent. 2.14.10 and later end the expired downtime at its end
  time; 2.13.14 ends it on its expiry timer, about 60 s later, still before the manual removal.
- Three overlapping signed notifications: Correlia refuses one with 503 and admits two, and Icinga 2 logs the
  refused command as exit code 1 with output `status 503`.
- The runtime-created host's first HARD DOWN carries the first HARD result's execution end, about 24 s after
  the daemon's `program_start` on every release, and its row is applied, not `late`.
- 2.13.14 and 2.14.10 log a failed command's output unquoted (`output: <text>`); 2.15.7 and 2.16.6 quote it.
- The order in which a refire's PROBLEM and a delayed RECOVERY are delivered differs by release; each yields one
  event and one `duplicate_observation`.

## Statement

`docs/ingest-pipeline.md`, "Supported Icinga 2 releases": 2.13.14, 2.14.10, 2.15.7 and 2.16.6 on linux-x64.
`mise run release:icinga2-notify` published linux-x64 only and reported "not published linux-arm64: no
qualified pair".
