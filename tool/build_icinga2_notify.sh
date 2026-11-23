#!/usr/bin/env bash
# Compiles the Icinga 2 sender so its bytes do not depend on where the repository is checked out.
#
# Usage: tool/build_icinga2_notify.sh <package dir> <x64|arm64> <output file>
#
# `dart compile exe` embeds the absolute file URI of the entry point, so the same sources built from two checkout
# paths differ. The release task publishes a sender only when its SHA-256 is the one the qualified captures ran, so
# every build compiles a copy of the package at one fixed path instead. The copy leaves the pub workspace and
# resolves offline against the workspace's lock file, so it gets the same dependency versions.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <package dir> <x64|arm64> <output file>" >&2
  exit 2
fi
package=$(cd "$1" && pwd)
architecture=$2
output=$3
lock="$package/../pubspec.lock"
[[ -f $package/pubspec.yaml && -d $package/bin && -d $package/lib && -f $lock ]] ||
  { echo "not the sender package of a resolved workspace: $package" >&2; exit 2; }

stage=/tmp/correlia-icinga2-notify-build
if ! mkdir "$stage" 2>/dev/null; then
  echo "$stage exists: another sender build is running, or an interrupted one left it (remove it)" >&2
  exit 2
fi
trap 'rm -rf "$stage"' EXIT

copy="$stage/correlia_icinga2_notify"
mkdir "$copy"
cp -R "$package/bin" "$package/lib" "$copy/"
grep -v '^resolution: workspace$' "$package/pubspec.yaml" > "$copy/pubspec.yaml"
cp "$lock" "$copy/pubspec.lock"
(cd "$copy" && dart pub get --offline > /dev/null)

mkdir -p "$(dirname "$output")"
dart compile exe --target-os linux --target-arch "$architecture" -o "$output" "$copy/bin/main.dart" > /dev/null
echo "Generated: $output"
