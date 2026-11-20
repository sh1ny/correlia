#!/usr/bin/env bash
# Capture real Icinga 2 notifications for linux-x64 with Docker (task 9.1).
#
# usage: tool/icinga2_capture.sh RELEASE [RELEASE ...]   (for example 2.16.6)
#
# Builds nothing itself: run `mise run build:icinga2-notify` first. Each release runs in its own
# container from the official icinga/icinga2 image, on the host network, with an ephemeral REST API
# port. The driver (correlia_server/tool/icinga2_capture/main.dart) writes the evidence under
# correlia_server/test/unit/ingest/fixtures/icinga2/<release>/linux-x64/. Set CAPTURE_ONLY to a comma separated list of
# scenario names to run a subset.
set -euo pipefail

if (( $# < 1 )); then
  echo "usage: $0 RELEASE [RELEASE ...]" >&2
  exit 2
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
server="$root/correlia_server"
sender="$root/build/icinga2-notify/linux-x64/correlia-icinga2-notify"
contrib="$root/contrib/icinga2"
out="$server/test/unit/ingest/fixtures/icinga2"
[[ -x $sender ]] || { echo "build the sender first: mise run build:icinga2-notify" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/i2cap-XXXXXXXX")
suffix=${tmp##*/i2cap-}
names=()
cleanup() {
  for name in "${names[@]}"; do docker rm -fv "$name" >/dev/null 2>&1 || true; done
  rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

status=0
for release in "$@"; do
  image="icinga/icinga2:$release"
  docker pull --quiet "$image" >/dev/null
  digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)
  name="i2cap-${release//./-}-$suffix"
  names+=("$name")
  api_port=$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(('127.0.0.1', 0))
print(sock.getsockname()[1])
PY
)
  args=(--release "$release" --image "$image" --digest "$digest" --container "$name"
        --api-port "$api_port" --out "$out" --sender "$sender" --contrib "$contrib")
  if [[ -n ${CAPTURE_ONLY:-} ]]; then args+=(--only "$CAPTURE_ONLY"); fi
  (cd "$server" && mise exec -- dart run tool/icinga2_capture/main.dart "${args[@]}") || status=1
  docker rm -fv "$name" >/dev/null 2>&1 || true
done
exit "$status"
