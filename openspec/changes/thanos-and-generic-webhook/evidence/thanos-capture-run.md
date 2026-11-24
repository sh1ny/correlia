# Thanos capture run

## A2: runnable release images

On Linux amd64 with Docker 29.6.0, `docker pull` and
`docker run --rm --network none <image> --version` succeeded for all six images.
The four Thanos releases also ran `rule --help` and listed `--alert.label-drop`.
The Thanos tags are the latest patches of the four newest stable minors reported
by the upstream release list on 2026-11-24.

| Image | Manifest digest |
|---|---|
| `quay.io/thanos/thanos:v0.39.2` | `sha256:1d022ef4b8eff056a0e3b7822f953d931c5704d068413f2d7ce5266aa96c9e80` |
| `quay.io/thanos/thanos:v0.40.1` | `sha256:aae7b2b030ed00d88abd8c5a357d08b46f22151ca0d50d9c796223fa332389c8` |
| `quay.io/thanos/thanos:v0.41.0` | `sha256:cf3e9b292e4302ad4a4955b56379703aea39516607d382a57604a3d003c35d10` |
| `quay.io/thanos/thanos:v0.42.5` | `sha256:0a546b98a8dd47735456ab389983675ee363d68127e334937a9fceeea10da5e7` |
| `prom/alertmanager:v0.35.0` | `sha256:e638797febd034838eca8b98cdbd46f951e9bf7f178777aa8669167406a9946c` |
| `prom/prometheus:v3.16.0` | `sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06` |

## Red test

`thanos_versions_test.dart` compiled and failed all eight scenarios on the missing
`test/unit/ingest/fixtures/thanos/manifest.json` before the first capture.

## A1: keep and drop runs

```sh
mise exec -- tool/alertmanager_capture.sh --thanos \
  correlia_server/test/unit/ingest/fixtures/thanos \
  v0.39.2 v0.40.1 v0.41.0 v0.42.5
```

All runtime containers passed `/-/ready`. For each release and run, both Rulers'
`thanos_alert_sender_alerts_sent_total` counters advanced from 0 to 2: each sent
an alert after the firing reload and again after the resolving reload.
The receiver recorded 24 unmodified v4 notifications: four per keep run
(firing and resolved for each replica), two per drop run (one firing and one
resolved with no replica label). The manifest contains the sequence, status,
replica labels and image/counter evidence for each notification.

All eight `thanos_versions_test.dart` scenarios passed on these captures.
Both replicas share the same fingerprint in the drop run without Correlia
identity exclusions. Keeping the label yields two fingerprints unless it is
explicitly excluded on the Correlia source.

`two_tenants_with_equal_labels`, `tenant_header_on_a_delivery` and
`thanos_source_kind` passed without production changes and guard the existing
Alertmanager registration, namespace and header behavior.
