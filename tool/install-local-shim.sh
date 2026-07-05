#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname "$script_dir")
cli_script="$repo_dir/packages/flutter_scout/bin/flutter_scout.dart"

if [ ! -f "$cli_script" ]; then
  echo "flutter_scout CLI script not found at $cli_script" >&2
  exit 1
fi

bin_dir="${PUB_CACHE:-$HOME/.pub-cache}/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/flutter-scout" <<EOF
#!/usr/bin/env sh
exec dart "$cli_script" "\$@"
EOF
chmod +x "$bin_dir/flutter-scout"

printf '{"ok":true,"path":"%s","target":"%s"}\n' \
  "$bin_dir/flutter-scout" \
  "$cli_script"
