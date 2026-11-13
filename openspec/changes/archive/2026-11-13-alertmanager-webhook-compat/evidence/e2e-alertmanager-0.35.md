# Real Alertmanager compatibility acceptance

## Procedure

Followed `docs/runbooks/alertmanager-compatibility.md` with Linux Docker images
`prom/alertmanager:v0.35.0` and `prom/alertmanager:v0.27.0`, real Correlia
`bin/main.dart --mode test --apply-migrations`, `output-nats` and `natsdev`.
The private server used API 18080, web 18082 and a dedicated embedded PostgreSQL
Unix socket under the demo directory. Neither the PostgreSQL TCP listener on
127.0.0.1:5432 nor the existing server on 8080–8082 was used or stopped.

The console was built into the private demo directory with
`SERVER_URL=http://localhost:18080/`, selected by `CORRELIA_TEST_CONSOLE_DIR`.
The pinned output executable was copied into a private mode-0700 plugin directory;
its SHA-256 was `1953aed2d264c4c20fbfe7a81fcaee7f8814a230953fe56de7250bd38d60ae72`.
Source credentials were random, stored in mode-0600 files and mounted as
Alertmanager's Bearer `credentials_file`. No credentials or raw payloads are
included here.

## Observed results

A Chromium tab at `http://localhost:18082/` showed the warning-severity
`compatibility demo` alert and **1 held** after firing each release-specific
instance. After its resolution, the same console showed **0 held** and
**No firing alerts**. These were actual rendered-console screenshots, not an API
substitute. The temporary screenshots were deleted after inspection.

The live NATS subscriber received:

| Sender instance | Status | Canonical event id |
|---|---|---|
| demo-v0.27.0:9100 | firing | a457e897-75af-5844-ab12-7a91d9619197 |
| demo-v0.27.0:9100 | resolved | 71d69dfd-874f-59fa-a942-152946ea3f95 |
| demo-v0.35.0:9100 | firing | 46c708ab-0c39-5c87-8d5e-c8d5f9fc47f4 |
| demo-v0.35.0:9100 | resolved | 324846b1-c9b1-58b2-938a-dd18a319632d |

Restricted SQL against only the demo's Unix socket returned:

```text
instance             status  unknown names  overflow  deliveries
demo-v0.27.0:9100    done    []             0         2
demo-v0.35.0:9100    done    []             0         2
pipeline_failures: 0 rows
```

All eight output intents, including rehearsal deliveries, were `delivered`.
A rehearsal identified two runbook isolation requirements, now documented:
private plugin copies prevent concurrent `test:all` rebuilds from changing the
pinned executable; per-release instance labels prevent an earlier resolution's
ordering fence from making the next release's firing observation stale. Neither
required a production-code exception or contract change.

## Additional verification

- `tool/alertmanager_capture.sh` captured firing and resolved payloads from
  v0.35.0 and v0.16.2. All four matched the committed captures after removing only
  `startsAt` and `endsAt` timestamps.
- Version matrix: 41 tests passed. Removing `routeLabels` from the allowlist
  failed exactly the four 0.34/0.35 cases; restoration returned 41 passing.
- Focused decoder, version, warning, pipeline and routing run: 81 passing.
- `mise run check`: exit 0; 15 OpenSpec items valid; analysis, formatting,
  generated-code and protocol checks passed; 201 fast, 72 tooling and 19 Flutter
  tests passed.
- `mise run test:all`: exit 0; 440 tests passed, load tier excluded.

## Teardown

Removed every started `amcap-*` and `am-e2e-correlia-amcompat` container; Docker
listing confirmed none remained. Stopped the demo server by stdin EOF (exit 0),
closed natsdev stdin (exit 0), and terminated/reaped its subscriber. Removed the
private database, console build, plugin copies, credentials, captures and logs.
Removed the three images pulled for this task: v0.16.2, v0.27.0 and v0.35.0.
The shared database-test cluster was left running as required.

## Owner criterion

This is agent-run evidence for task 5.2, not owner acceptance. Task 5.3 remains
unticked; the owner must perform and tick the real-Alertmanager check before
archive or milestone closure.
