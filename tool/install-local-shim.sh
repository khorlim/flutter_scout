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

# Path activation deliberately leaves Pub's generated executable as
# `dart pub global run ...`. That wrapper re-resolves the path package on
# every invocation, which writes dependency chatter to stdout before the CLI
# can emit its JSON response. Keep the normal global activation bookkeeping,
# but replace that generated wrapper with a locally compiled executable.
#
# Installer diagnostics belong on stderr: callers that refresh the CLI as part
# of an automation pipeline can continue to parse this script's one JSON line
# from stdout.
"$dart_bin" pub global activate --source path "$cli_package" >&2

bin_dir="${PUB_CACHE:-$HOME/.pub-cache}/bin"
executable="$bin_dir/flutter-scout"
if [ ! -x "$executable" ]; then
  echo "Pub did not install flutter-scout at $executable" >&2
  exit 1
fi

cache_dir="${PUB_CACHE:-$HOME/.pub-cache}/flutter-scout-local"
mkdir -p "$cache_dir"
compiled_executable="$cache_dir/flutter-scout"
staged_executable="$cache_dir/.flutter-scout.$$"
staged_shim="$bin_dir/.flutter-scout.$$"

cleanup() {
  rm -f "$staged_executable" "$staged_shim"
}
trap cleanup EXIT HUP INT TERM

"$dart_bin" compile exe --verbosity=error \
  -o "$staged_executable" \
  "$cli_package/bin/flutter_scout.dart" >&2
chmod +x "$staged_executable"
mv -f "$staged_executable" "$compiled_executable"

# Resolve the compiled executable relative to the shim rather than embedding a
# host-specific path. This keeps the local activation portable if PUB_CACHE is
# relocated after installation.
cat > "$staged_shim" <<'EOF'
#!/usr/bin/env sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/../flutter-scout-local/flutter-scout" "$@"
EOF
chmod +x "$staged_shim"
mv -f "$staged_shim" "$executable"

printf '{"ok":true,"path":"%s","source":"path","package":"%s","compiledExecutable":true}\n' \
  "$executable" \
  "$cli_package"
