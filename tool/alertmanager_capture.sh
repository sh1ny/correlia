#!/usr/bin/env bash
# Capture real Alertmanager webhook notifications, optionally from Thanos Ruler.
set -euo pipefail

mode=alertmanager
if [[ ${1:-} == --thanos ]]; then
  mode=thanos
  shift
fi
if (( $# < 2 )); then
  echo "usage: $0 [--thanos] OUTPUT_DIRECTORY v0.35.0 [v0.16.2 ...]" >&2
  exit 2
fi
out=$1; shift
for version in "$@"; do
  if [[ ! $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "invalid release: $version" >&2
    exit 2
  fi
done
mkdir -p "$out"
out=$(cd "$out" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/amcap-XXXXXXXX")
name="amcap-${tmp##*/amcap-}"
receiver_pid=
containers=()
stop_receiver() {
  if [[ -n $receiver_pid ]]; then
    kill "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true
    receiver_pid=
  fi
}
cleanup() {
  local status=$?
  if (( ${#containers[@]} )); then
    if (( status != 0 )); then
      for container in "${containers[@]}"; do docker logs --tail 30 "$container" >&2 || true; done
    fi
    docker rm -fv "${containers[@]}" >/dev/null 2>&1 || true
  else
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
  stop_receiver
  rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Reserve distinct ephemeral ports while choosing them; no existing service is touched.
port_count=2
if [[ $mode == thanos ]]; then port_count=7; fi
read -r receiver_port am_port query_port a_http b_http a_grpc b_grpc < <(python3 - "$port_count" <<'PY'
import socket
import sys
sockets = []
for _ in range(int(sys.argv[1])):
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    sockets.append(sock)
print(*(sock.getsockname()[1] for sock in sockets))
PY
)
cat > "$tmp/receiver.py" <<'PY'
import http.server
import json
import os
import sys

out, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]

class Receiver(http.server.BaseHTTPRequestHandler):
    sequence = 0

    def do_GET(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        try:
            body = self.rfile.read(int(self.headers['Content-Length']))
            data = json.loads(body)
            status = data['status']
            if status not in ('firing', 'resolved'):
                raise ValueError('unexpected status')
            if mode == 'thanos':
                Receiver.sequence += 1
                path = os.path.join(out, f'{Receiver.sequence:04}.json')
                with open(path + '.tmp', 'xb') as f:
                    f.write(body)
                os.link(path + '.tmp', path)
                os.unlink(path + '.tmp')
            else:
                data['externalURL'] = 'http://alertmanager.example:9093'
                path = os.path.join(out, status + '.json')
                with open(path + '.tmp', 'w', encoding='utf-8') as f:
                    json.dump(data, f, indent=2, sort_keys=True, ensure_ascii=False)
                    f.write('\n')
                os.replace(path + '.tmp', path)
            self.send_response(200)
        except (ValueError, KeyError, json.JSONDecodeError):
            self.send_response(400)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(('127.0.0.1', port), Receiver).serve_forever()
PY
start_receiver() {
  python3 "$tmp/receiver.py" "$1" "$receiver_port" "$mode" >"$tmp/receiver.log" 2>&1 &
  receiver_pid=$!
}

if [[ $mode == thanos ]]; then
  # Use digest-qualified image refs for the actual containers, not mutable tags.
  digest_ref() {
    if ! docker image inspect "$1" >/dev/null 2>&1; then docker pull "$1" >&2; fi
    docker image inspect --format '{{index .RepoDigests 0}}' "$1"
  }
  wait_for() {
    local description=$1 deadline=$((SECONDS + 300)) status
    shift
    while true; do
      if "$@"; then return; else status=$?; fi
      if (( status == 2 )); then return 1; fi
      if (( SECONDS >= deadline )); then
        echo "timed out waiting for $description" >&2
        cat "$tmp/receiver.log" >&2
        return 1
      fi
      sleep 0.25
    done
  }
  ready() {
    curl -fsS --max-time 2 "http://127.0.0.1:$1/-/ready" >/dev/null 2>&1 || return 1
  }
  sent() {
    curl -fsS --max-time 2 "http://127.0.0.1:$1/metrics" |
      awk '/^thanos_alert_sender_alerts_sent_total\{/ {sum += $NF} END {printf "%.0f\n", sum}'
  }
  sent_after() {
    after_a=$(sent "$a_http") && after_b=$(sent "$b_http") &&
      (( after_a > $1 && after_b > $2 ))
  }
  write_rule() {
    cat > "$tmp/ruler-rules.yml" <<EOF
groups:
  - name: capture
    rules:
      - alert: CorreliaCapture
        expr: $1
        labels:
          instance: capture:9000
          severity: warning
        annotations:
          summary: Thanos Ruler capture
EOF
  }
  reload_rulers() {
    local port
    for port in "$a_http" "$b_http"; do
      curl -fsS --max-time 300 -X POST "http://127.0.0.1:$port/-/reload" >/dev/null
    done
  }
  captures_ready() {
    python3 - "$run_dir" "$run" "$1" <<'PY'
import json
from pathlib import Path
import sys

root, run, status = sys.argv[1:]
seen = set()
for path in Path(root).glob('*.json'):
    payload = json.loads(path.read_bytes())
    for alert in payload['alerts']:
        replica = alert['labels'].get('replica')
        if run == 'dropped' and 'replica' in alert['labels']:
            print(f'A1 failed: Ruler retained replica in {path.name} on the drop run', file=sys.stderr)
            sys.exit(2)
        if alert['status'] == status:
            seen.add(replica)
sys.exit(0 if seen == ({'a', 'b'} if run == 'kept' else {None}) else 1)
PY
  }

  if [[ -n $(find "$out" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo "Thanos capture needs an empty output directory: $out" >&2
    exit 2
  fi
  stage=$tmp/fixtures
  mkdir "$stage"
  query_image=prom/prometheus:v3.16.0
  am_image=prom/alertmanager:v0.35.0
  query_ref=$(digest_ref "$query_image")
  am_ref=$(digest_ref "$am_image")
  query_url="http://127.0.0.1:$query_port"
  am_url="http://127.0.0.1:$am_port"
  containers=("$name-query" "$name-am" "$name-a" "$name-b")
  printf 'global: {}\n' > "$tmp/prometheus.yml"
  docker run -d --name "$name-query" --network host --user 0:0 \
    -v "$tmp/prometheus.yml:/capture.yml:ro" "$query_ref" \
    --config.file=/capture.yml --storage.tsdb.path=/prometheus \
    --web.listen-address="127.0.0.1:$query_port" >/dev/null
  wait_for "Prometheus readiness" ready "$query_port"

  cat > "$tmp/alertmanager.yml" <<EOF
route:
  receiver: capture
  group_by: [alertname, replica]
  group_wait: 1s
  group_interval: 2s
  repeat_interval: 1h
receivers:
  - name: capture
    webhook_configs:
      - url: http://127.0.0.1:$receiver_port/
        send_resolved: true
EOF
  cat > "$tmp/ruler-alertmanagers.yml" <<EOF
alertmanagers:
  - scheme: http
    api_version: v2
    static_configs: ["127.0.0.1:$am_port"]
EOF
  for version in "$@"; do
    ruler_image="quay.io/thanos/thanos:$version"
    ruler_ref=$(digest_ref "$ruler_image")
    ruler_help=$(docker run --rm --network none "$ruler_ref" rule --help 2>&1)
    if [[ $ruler_help != *--alert.label-drop=* ]]; then
      echo "A1 failed: $version has no --alert.label-drop flag" >&2
      exit 1
    fi
    for run in kept dropped; do
      run_dir="$tmp/$version-$run"
      mkdir "$run_dir"
      start_receiver "$run_dir"
      wait_for "receiver readiness" ready "$receiver_port"
      docker run -d --name "$name-am" --network host --user 0:0 \
        -v "$tmp/alertmanager.yml:/capture.yml:ro" "$am_ref" \
        --config.file=/capture.yml --storage.path=/alertmanager \
        --web.listen-address="127.0.0.1:$am_port" --web.external-url="$am_url" \
        --cluster.listen-address= >/dev/null
      wait_for "Alertmanager readiness" ready "$am_port"
      write_rule 'vector(1) < 0'
      drop=()
      if [[ $run == dropped ]]; then drop=(--alert.label-drop=replica); fi
      for replica in a b; do
        if [[ $replica == a ]]; then http=$a_http; grpc=$a_grpc; else http=$b_http; grpc=$b_grpc; fi
        docker run -d --name "$name-$replica" --network host --user 0:0 \
          -v "$tmp/ruler-alertmanagers.yml:/alertmanagers.yml:ro" \
          -v "$tmp/ruler-rules.yml:/rules.yml:ro" "$ruler_ref" rule \
          --http-address="127.0.0.1:$http" --grpc-address="127.0.0.1:$grpc" \
          --data-dir=/tmp/ruler --rule-file=/rules.yml --eval-interval=1s \
          --query="$query_url" --alert.query-url="$query_url" \
          --alertmanagers.config-file=/alertmanagers.yml \
          --label="replica=\"$replica\"" "${drop[@]}" >/dev/null
        wait_for "$version $run Ruler $replica readiness" ready "$http"
      done
      before_a=$(sent "$a_http")
      before_b=$(sent "$b_http")
      write_rule 'vector(1)'
      reload_rulers
      wait_for "$version $run both replicas sending firing" sent_after "$before_a" "$before_b"
      wait_for "$version $run firing delivery" captures_ready firing
      firing_a=$after_a
      firing_b=$after_b
      write_rule 'vector(1) < 0'
      reload_rulers
      wait_for "$version $run both replicas sending resolved" sent_after "$firing_a" "$firing_b"
      wait_for "$version $run resolved delivery" captures_ready resolved
      docker rm -fv "$name-a" "$name-b" "$name-am" >/dev/null
      stop_receiver
      python3 - "$run_dir" "$stage" "$version" "$run" "$before_a" "$after_a" "$before_b" "$after_b" \
        "$ruler_image" "$ruler_ref" "$am_image" "$am_ref" "$query_image" "$query_ref" <<'PY'
import json
from pathlib import Path
import sys

root, stage, release, run, a0, a1, b0, b1, *images = sys.argv[1:]
stage = Path(stage)
with (stage / 'entries.ndjson').open('a') as manifest:
    for path in sorted(Path(root).glob('*.json')):
        payload = json.loads(path.read_bytes())
        name = f'{release}-{run}-{path.name}'
        labels = sorted({a['labels']['replica'] for a in payload['alerts'] if 'replica' in a['labels']})
        if run == 'dropped' and labels:
            sys.exit(f'A1 failed: Ruler retained replica in {name} on the drop run')
        entry = {
            'file': name, 'release': release, 'run': run, 'sequence': int(path.stem),
            'status': payload['status'], 'replica_labels': labels,
            'replicas': {
                'a': {'before': int(a0), 'after': int(a1)},
                'b': {'before': int(b0), 'after': int(b1)},
            },
            'images': {
                role: {'tag': tag, 'digest': ref.split('@', 1)[1]}
                for role, tag, ref in zip(('thanos', 'alertmanager', 'query'), images[::2], images[1::2])
            },
        }
        (stage / name).write_bytes(path.read_bytes())
        manifest.write(json.dumps(entry) + '\n')
PY
      printf 'captured %s %s; sent alerts a=%s→%s b=%s→%s\n' \
        "$version" "$run" "$before_a" "$after_a" "$before_b" "$after_b"
    done
  done
  python3 - "$stage" <<'PY'
import json
from pathlib import Path
import sys

stage = Path(sys.argv[1])
entries = [json.loads(line) for line in (stage / 'entries.ndjson').read_text().splitlines()]
(stage / 'manifest.json').write_text(json.dumps({'fixtures': entries}, indent=2) + '\n')
PY
  cp --no-clobber "$stage"/*.json "$out/"
  exit
fi

start_receiver "$tmp"

for version in "$@"; do
  rm -f "$tmp/firing.json" "$tmp/resolved.json"
  cat > "$tmp/am.yml" <<EOF
route:
  receiver: cap
  group_by: [alertname]
  group_wait: 1s
  group_interval: 2s
  repeat_interval: 1h
receivers:
  - name: cap
    webhook_configs:
      - url: http://127.0.0.1:$receiver_port/
        send_resolved: true
EOF
  docker run -d --name "$name" --user 0:0 --network host -v "$tmp/am.yml:/etc/alertmanager/alertmanager.yml:ro" \
    "prom/alertmanager:$version" --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/alertmanager --web.listen-address="127.0.0.1:$am_port" --cluster.listen-address= >/dev/null
  ready=false
  for _ in {1..100}; do
    if curl -fsS "http://127.0.0.1:$am_port/-/ready" >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.2
  done
  if [[ $ready != true ]]; then docker logs "$name" >&2; echo "Alertmanager $version failed to start" >&2; exit 1; fi
  starts=$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)
  post_alert() {
    python3 - "$starts" "$1" <<'PY' | curl -fsS -o /dev/null -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:$am_port/api/v2/alerts"
import json, sys
alert = {'labels': {'alertname': 'CapTest', 'instance': 'h1:9100', 'severity': 'warning'},
         'annotations': {'summary': 'capture'}, 'generatorURL': 'http://prom.demo/g', 'startsAt': sys.argv[1]}
if sys.argv[2]:
    alert['endsAt'] = sys.argv[2]
print(json.dumps([alert]))
PY
  }
  await_capture() {
    for _ in {1..150}; do
      if [[ -s $tmp/$1.json ]]; then return; fi
      if ! kill -0 "$receiver_pid" 2>/dev/null; then cat "$tmp/receiver.log" >&2; return 1; fi
      sleep 0.2
    done
    echo "timed out waiting for $version $1 notification" >&2
    docker logs "$name" >&2
    return 1
  }
  post_alert ''
  await_capture firing
  cp "$tmp/firing.json" "$out/$version-firing.json"
  post_alert "$(date -u -d '1 second ago' +%Y-%m-%dT%H:%M:%SZ)"
  await_capture resolved
  cp "$tmp/resolved.json" "$out/$version-resolved.json"
  docker rm -f "$name" >/dev/null
  echo "captured $version"
done
