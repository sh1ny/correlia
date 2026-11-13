# Alertmanager compatibility captures and end-to-end check

## Reproduce the captures

The supported matrix is the latest patch of each minor from 0.16 through 0.35. The change's evidence contains one firing and one resolved notification per minor. They came from `prom/alertmanager:<version>` Docker images on Linux host networking, each on a separate local port, with clustering disabled. A loopback Python receiver recorded the actual webhook. The route groups by `alertname`, waits 1 second, uses a 2-second group interval and sends resolved notifications. `CapTest` was posted to `/api/v2/alerts`, then posted again with an explicit past `endsAt`. JSON keys were sorted and indented, and only `externalURL` was normalized to `http://alertmanager.example:9093`; timestamps remain actual capture times.

From the repository root, with Docker, Python 3 and curl available, add a release's pair to a scratch directory:

```sh
mkdir -p /tmp/my-am-captures
tool/alertmanager_capture.sh /tmp/my-am-captures v0.35.0 v0.16.2
```

The script removes its own `amcap-*` container and temporary files on normal exit, failure or interruption. It does not remove Docker images. Compare against the fixtures in `correlia_server/test/unit/ingest/fixtures/alertmanager/` (the original captures are archived in `openspec/changes/archive/2026-11-13-alertmanager-webhook-compat/evidence/alertmanager-captures/`) after ignoring only alert `startsAt` and `endsAt` timestamps. To extend the supported matrix, capture the new release, review both actual payloads and copy them into the fixture directory used by the version-matrix test. Do not hand-author a payload. Delete the scratch output and any images you pulled for this check when finished.

## Isolated real-Alertmanager check

This is a local development-only demonstration, not a production deployment. It uses a private test-mode embedded PostgreSQL, loopback-only Alertmanager, an unauthenticated loopback NATS server and test credentials. It does not use PostgreSQL port 5432 or existing Correlia listeners. Commands below are run from the repository root in one Bash session. Pick unused ports before starting; these examples use 18080–18082 and 19093. Build the console into this demo's private directory, not the running server's web directory.

```bash
mise run setup
mise run plugins:build
export DEMO_DIR="$(mktemp -d /tmp/correlia-am-e2e-XXXXXXXX)"
chmod 700 "$DEMO_DIR"
(cd correlia_flutter && mise exec -- flutter build web --base-href / \
  --output "$DEMO_DIR/web" --dart-define=SERVER_URL=http://localhost:18080/)
mkdir -m 700 "$DEMO_DIR/plugins"
cp build/plugins/output-nats build/plugins/natsdev "$DEMO_DIR/plugins/"
chmod 700 "$DEMO_DIR/plugins/"*
export CORRELIA_PLUGIN_DIR="$DEMO_DIR/plugins"
export CORRELIA_INGEST_CONFIG="$DEMO_DIR/ingest.json"
export CORRELIA_INGEST_SECRETS="$DEMO_DIR/secrets.json"
export AM_CONTAINER="am-e2e-${DEMO_DIR##*-}"
# Keep natsdev stdin open; it shuts down when stdin reaches EOF.
mkfifo "$DEMO_DIR/nats.stdin"
exec 9<>"$DEMO_DIR/nats.stdin"
"$CORRELIA_PLUGIN_DIR/natsdev" serve --port 0 --store "$DEMO_DIR/nats" \
  <"$DEMO_DIR/nats.stdin" 9>&- >"$DEMO_DIR/nats.log" 2>&1 &
NATS_PID=$!
```

Wait for `ready nats://127.0.0.1:<port>` in `"$DEMO_DIR/nats.log"`, then use the printed URL (do not guess it):

```bash
export NATS_URL="$(awk '/^ready nats:\/\// {print $2; exit}' "$DEMO_DIR/nats.log")"
test -n "$NATS_URL" || { echo 'NATS is not ready yet'; false; }
"$CORRELIA_PLUGIN_DIR/natsdev" stream --url "$NATS_URL"
"$CORRELIA_PLUGIN_DIR/natsdev" sub --url "$NATS_URL" 9>&- >"$DEMO_DIR/sub.log" 2>&1 &
SUB_PID=$!
```

Wait for `ready` in `"$DEMO_DIR/sub.log"` before sending alerts: the subscriber is live-only. Create the source token, separate mode-0600 secret file, and plugin-pinned bootstrap. The token file is mounted read-only into Alertmanager and must not be printed or committed.

```bash
umask 077
openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > "$DEMO_DIR/token"
export PLUGIN_SHA="$(sha256sum "$CORRELIA_PLUGIN_DIR/output-nats" | cut -d' ' -f1)"
python3 - <<'PY'
import json, os
from pathlib import Path
p = Path(os.environ['DEMO_DIR'])
source = '11111111-1111-4111-8111-111111111111'
output = '22222222-2222-4222-8222-222222222222'
(p / 'secrets.json').write_text(json.dumps({'alertmanager-token-v1': (p / 'token').read_text()}))
config = {'format_version': 1, 'revision': 1,
  'sources': [{'id': source, 'enabled': True, 'token_ref': 'alertmanager-token-v1',
               'path_token_enabled': False, 'body_limit_bytes': 1048576,
               'excluded_identity_labels': [], 'output_ids': [output]}],
  'outputs': [{'id': output, 'kind': 'plugin', 'plugin': 'output-nats',
               'sha256': os.environ['PLUGIN_SHA'],
               'config': {'server': os.environ['NATS_URL'], 'stream': 'CORRELIA_EVENTS'},
               'secret_refs': {}}]}
(p / 'ingest.json').write_text(json.dumps(config))
PY
chmod 600 "$DEMO_DIR/token" "$DEMO_DIR/secrets.json"
```

Start the server in a **second terminal**, from the repository root. Replace `DEMO_DIR` with the path printed by `echo "$DEMO_DIR"` in the first terminal; it contains no credential itself. Keep this terminal open and wait for startup and migrations to finish. Server output is redirected to a file so the process does not lose its logging pipe.

```bash
export DEMO_DIR=/tmp/correlia-am-e2e-REPLACE_ME
export CORRELIA_PLUGIN_DIR="$DEMO_DIR/plugins"
export CORRELIA_INGEST_CONFIG="$DEMO_DIR/ingest.json"
export CORRELIA_INGEST_SECRETS="$DEMO_DIR/secrets.json"
export SERVERPOD_API_SERVER_PORT=18080 SERVERPOD_INSIGHTS_SERVER_PORT=18081
export SERVERPOD_WEB_SERVER_PORT=18082 SERVERPOD_DATABASE_PORT=0
export SERVERPOD_DATABASE_DATA_PATH="$DEMO_DIR/pgdata"
export CORRELIA_TEST_CONSOLE_DIR="$DEMO_DIR/web"
(cd correlia_server && mise exec -- dart bin/main.dart --mode test --apply-migrations) >"$DEMO_DIR/server.log" 2>&1
```

Back in the first terminal, check `"$DEMO_DIR/server.log"` for successful startup, then run each of 0.35.0 and 0.27.0 in turn. The container uses host networking, and the token file is mounted at the same absolute path. Replace `AM_VERSION` to repeat after removing the previous container.

```bash
export AM_VERSION=v0.35.0
cat > "$DEMO_DIR/am.yml" <<EOF
route:
  receiver: correlia
  group_by: [alertname]
  group_wait: 1s
  group_interval: 2s
  repeat_interval: 1h
receivers:
  - name: correlia
    webhook_configs:
      - url: http://127.0.0.1:18082/hooks/alertmanager/11111111-1111-4111-8111-111111111111
        send_resolved: true
        http_config:
          authorization:
            type: Bearer
            credentials_file: $DEMO_DIR/token
EOF
docker run -d --name "$AM_CONTAINER" --user 0:0 --network host \
  -v "$DEMO_DIR/am.yml:/etc/alertmanager/alertmanager.yml:ro" \
  -v "$DEMO_DIR/token:$DEMO_DIR/token:ro" "prom/alertmanager:$AM_VERSION" \
  --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager \
  --web.listen-address=127.0.0.1:19093 --cluster.listen-address=
```

Wait until `curl -fsS http://127.0.0.1:19093/-/ready` succeeds. Post a firing alert, then inspect the console **before** resolving it:

```bash
export STARTS_AT="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"
python3 - <<'PY' | curl -fsS -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:19093/api/v2/alerts
import json, os
print(json.dumps([{'labels': {'alertname': 'CompatibilityDemo', 'instance': 'demo-' + os.environ['AM_VERSION'] + ':9100', 'severity': 'warning'},
                   'annotations': {'summary': 'compatibility demo'}, 'startsAt': os.environ['STARTS_AT']}]))
PY
```

Open <http://localhost:18082/> in a local browser. Confirm the `compatibility demo` summary appears in the firing alert list, and `"$DEMO_DIR/sub.log"` contains its `correlia.v1.ev...` canonical CloudEvent. A 202 from ingress alone is not proof of processing. The release-specific instance label prevents the preceding release's resolved fence from making a quick second run's firing evidence stale. Resolve the same alert and confirm a resolved event reaches the subscriber and the firing alert disappears from the console:

```bash
export ENDS_AT="$(date -u -d '1 second ago' +%Y-%m-%dT%H:%M:%SZ)"
python3 - <<'PY' | curl -fsS -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:19093/api/v2/alerts
import json, os
print(json.dumps([{'labels': {'alertname': 'CompatibilityDemo', 'instance': 'demo-' + os.environ['AM_VERSION'] + ':9100', 'severity': 'warning'},
                   'annotations': {'summary': 'compatibility demo'}, 'startsAt': os.environ['STARTS_AT'],
                   'endsAt': os.environ['ENDS_AT']}]))
PY
```

Use restricted SQL against **only this demo's** embedded PostgreSQL Unix socket. Automatic startup uses a socket, not a TCP listener. The test database is `correlia_test`, user `postgres`. The socket lives in the sibling `run` directory of the data path. Each completed delivery must have `unknown_top_level_fields: []` and `unknown_top_level_overflow: 0`; inspect `pipeline_failures` if not. Do not include raw bodies or credentials in evidence.

```bash
read -r PGHOST PGPORT PSQL < <(python3 - <<'PY'
import os, pathlib, shlex
p = pathlib.Path(os.environ['DEMO_DIR'])
socket = next(s for s in (p / 'run').iterdir() if s.is_socket())
psql = pathlib.Path(shlex.split((p / 'pgdata' / 'postmaster.opts').read_text())[0]).with_name('psql')
print(socket.parent, socket.name.rsplit('.', 1)[1], psql)
PY
)
export PGHOST PGPORT
mise exec -- "$PSQL" -U postgres -d correlia_test \
  -c "SELECT status, outcome_json FROM raw_inbox ORDER BY observed_at;"
mise exec -- "$PSQL" -U postgres -d correlia_test \
  -c 'SELECT "errorClass", "fieldPath" FROM pipeline_failures;'
```

Remove the container (`docker rm -f "$AM_CONTAINER"`), set `AM_VERSION=v0.27.0`, and repeat the container and alert commands for the older release. Use fresh timestamps so the second firing is a new observation.

## Teardown

Stop the server in its terminal with Ctrl-C and wait for it and its embedded PostgreSQL to exit before deleting its data. In the first terminal, remove only this demo's container and images, stop the subscriber and close natsdev's stdin, and remove its private directory:

```bash
docker rm -f "$AM_CONTAINER" 2>/dev/null || true
# Remove only images pulled by this check and not needed by other users:
# docker image rm prom/alertmanager:v0.35.0 prom/alertmanager:v0.27.0
kill "$SUB_PID" 2>/dev/null || true
wait "$SUB_PID" 2>/dev/null || true
exec 9>&-
wait "$NATS_PID"
rm -rf -- "$DEMO_DIR"
```

Only remove images that this check pulled and that are not needed by other users. The capture script's images, if separately pulled, can likewise be removed with `docker image rm prom/alertmanager:<version>`.
