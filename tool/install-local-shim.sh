#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname "$script_dir")
cli_package="$repo_dir/packages/flutter_scout"
dart_bin="${DART_BIN:-dart}"

if [ ! -f "$cli_package/pubspec.yaml" ]; then
  echo "flutter_scout CLI package not found at $cli_package" >&2
  exit 1
fi

"$dart_bin" pub global activate --source path "$cli_package"

bin_dir="${PUB_CACHE:-$HOME/.pub-cache}/bin"
executable="$bin_dir/flutter-scout"
if [ ! -x "$executable" ]; then
  echo "Pub did not install flutter-scout at $executable" >&2
  exit 1
fi

printf '{"ok":true,"path":"%s","source":"path","package":"%s","compiledSnapshotCache":true}\n' \
  "$executable" \
  "$cli_package"
