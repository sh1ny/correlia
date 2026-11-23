#!/usr/bin/env bash
# Capture real Icinga 2 notifications or Event Streams for linux-x64 with Docker.
#
# usage: tool/icinga2_capture.sh [--stream] RELEASE [RELEASE ...]   (for example 2.16.6)
#
# Builds nothing itself: run `mise run build:icinga2-notify` first. Each release runs in its own
# container from the official icinga/icinga2 image, on the host network, with an ephemeral REST API
# port. The driver (correlia_server/tool/icinga2_capture/main.dart) writes the evidence under
# correlia_server/test/unit/ingest/fixtures/icinga2/<release>/linux-x64/. Set CAPTURE_ONLY to a comma separated list of
# scenario names to run a subset.
# --stream captures the upstream API without starting Correlia or using the webhook sender.
set -euo pipefail

stream=0
if [[ ${1:-} == --stream ]]; then
  stream=1
  shift
fi

if (( $# < 1 )); then
  echo "usage: $0 [--stream] RELEASE [RELEASE ...]" >&2
  exit 2
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
server="$root/correlia_server"
sender="$root/build/icinga2-notify/linux-x64/correlia-icinga2-notify"
contrib="$root/contrib/icinga2"
out="$server/test/unit/ingest/fixtures/icinga2"
if (( !stream )) && [[ ! -x $sender ]]; then
  echo "build the sender first: mise run build:icinga2-notify" >&2
  exit 2
fi

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
  # The sender under test is linux-x64, so Icinga 2 must be too: pull the amd64 image, then run exactly the image
  # inspected here (by its ID), so neither emulation nor a tag moved since the inspection can change what runs.
  docker pull --platform linux/amd64 --quiet "$image" >/dev/null
  image_id=$(docker image inspect --format '{{.Id}}' "$image")
  platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_id")
  if [[ $platform != linux/amd64 ]]; then
    echo "$image resolved to $platform, not linux/amd64" >&2
    status=1
    continue
  fi
  digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image_id" 2>/dev/null || true)
  name="i2cap-${release//./-}-$suffix"
  names+=("$name")
  api_port=$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(('127.0.0.1', 0))
print(sock.getsockname()[1])
PY
)
  args=(--release "$release" --image "$image" --image-id "$image_id" --image-platform "$platform"
        --digest "$digest" --container "$name"
        --api-port "$api_port" --out "$out")
  if (( stream )); then
    driver=tool/icinga2_capture/streams.dart
  else
    driver=tool/icinga2_capture/main.dart
    args+=(--sender "$sender" --contrib "$contrib")
    if [[ -n ${CAPTURE_ONLY:-} ]]; then args+=(--only "$CAPTURE_ONLY"); fi
  fi
  (cd "$server" && mise exec -- dart run "$driver" "${args[@]}") || status=1
  docker rm -fv "$name" >/dev/null 2>&1 || true
done
exit "$status"
