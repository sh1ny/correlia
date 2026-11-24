# Icinga2 Event Streams compiled-consumer capture

Linux x86_64; Dart 3.13.7 and Serverpod 4.1.0. The Correlia server was built with `dart build cli` and started as a real worker on an isolated PostgreSQL test database for each positive and omitted-grant case. The worker verified the disposable Icinga instance's generated CA and `localhost` certificate. The positive runs used the shipped `contrib/icinga2/event-streams/correlia-stream-api-user.conf`, kept outside the qualified webhook bundle.

Reproduce from the repository root:

```bash
mise run setup
build=$(mktemp -d)
trap 'rm -rf -- "$build"' EXIT
(cd correlia_server && mise exec -- dart build cli --target=bin/main.dart --output="$build")
mise exec -- tool/icinga2_capture.sh --stream --consumer "$build/bundle/bin/main" 2.13.14 2.14.10 2.15.7 2.16.6
```

The executable used for this capture had SHA-256 `bdfd9c13c9520cb19337c9d43f60fad9e10399630d029448d14491402fbaaaea`. Exact official `linux/amd64` image digests, upstream wire records and decoded key bytes are in `correlia_server/test/unit/ingest/fixtures/icinga2/<release>/stream/`.

| Release | Successful subscription | Framing | First sync | Service state after live recovery |
|---|---|---|---|---|
| 2.13.14 | HTTP 200 | Close-delimited | Complete | Resolved |
| 2.14.10 | HTTP 200 | Close-delimited | Complete | Resolved |
| 2.15.7 | HTTP 200 | Close-delimited | Complete | Resolved |
| 2.16.6 | HTTP 200 | Chunked | Complete | Resolved |

For each release, a check admitted from the event stream by one worker matched the event ID and fingerprint of the same check admitted by a second worker's first sync. The next live check resolved the same service. The workers used separate databases so existing deduplication did not conceal a mismatch.

Each table cell is **upstream HTTP status / persisted consumer error class** for a different run with exactly that grant omitted:

| Omitted grant | 2.13.14 | 2.14.10 | 2.15.7 | 2.16.6 |
|---|---|---|---|---|
| `events/StateChange` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` |
| `events/AcknowledgementSet` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` |
| `events/AcknowledgementCleared` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` |
| `events/DowntimeStarted` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` |
| `events/DowntimeRemoved` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` |
| `events/Flapping` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` | 404 / `http_status` |
| `objects/query/Host` | 404 / `http_status` | 403 / `forbidden` | 403 / `forbidden` | 403 / `forbidden` |
| `objects/query/Service` | 404 / `http_status` | 403 / `forbidden` | 403 / `forbidden` | 403 / `forbidden` |

All 24 subscription refusals started no sync. The eight object-query refusals started a sync and failed it with the corresponding read problem. None of the 32 negative cases completed a first sync. `consumer-run.json` records these outcomes separately for every grant; the fast version matrix checks them against the upstream manifest.
