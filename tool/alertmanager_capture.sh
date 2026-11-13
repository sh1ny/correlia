#!/usr/bin/env bash
# Capture real Alertmanager webhook notifications on Linux with Docker.
set -euo pipefail

if (( $# < 2 )); then
  echo "usage: $0 OUTPUT_DIRECTORY v0.35.0 [v0.16.2 ...]" >&2
  exit 2
fi
out=$1; shift
mkdir -p "$out"
out=$(cd "$out" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/amcap-XXXXXXXX")
name="amcap-${tmp##*/amcap-}"
receiver_pid=
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  if [[ -n $receiver_pid ]]; then kill "$receiver_pid" 2>/dev/null || true; wait "$receiver_pid" 2>/dev/null || true; fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Reserve distinct ephemeral ports while choosing them; no existing service is touched.
read -r receiver_port am_port < <(python3 - <<'PY'
import socket
sockets = []
for _ in range(2):
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

out, port = sys.argv[1], int(sys.argv[2])
class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            status = data['status']
            if status not in ('firing', 'resolved'):
                raise ValueError('unexpected status')
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
python3 "$tmp/receiver.py" "$tmp" "$receiver_port" >"$tmp/receiver.log" 2>&1 &
receiver_pid=$!

for version in "$@"; do
  if [[ ! $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "invalid release: $version" >&2; exit 2; fi
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
