#!/usr/bin/env bash
# Builds the Icinga 2 sender and publishes it for each architecture with a qualified release pair.
#
# Usage: tool/release_icinga2_notify.sh [<repository root>]
#
# The earlier publication is removed before anything is built: the installation guide calls the release directory
# qualified, so a build or a publisher run that fails must leave no earlier sender or definitions there.
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [<repository root>]" >&2
  exit 2
fi
tools=$(cd "$(dirname "$0")" && pwd)
root=$(cd "${1:-$tools/..}" && pwd)
out="$root/build/icinga2-notify"

rm -rf "$out/release"
for architecture in x64 arm64; do
  install -d "$out/linux-$architecture"
  "$tools/build_icinga2_notify.sh" "$root/correlia_icinga2_notify" "$architecture" \
    "$out/linux-$architecture/correlia-icinga2-notify"
done
cd "$root/correlia_server"
dart run tool/icinga2_publish.dart
