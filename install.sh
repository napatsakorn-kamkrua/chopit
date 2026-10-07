#!/usr/bin/env bash
# chopit installer for Linux: curl -fsSL https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main/install.sh | bash
set -euo pipefail

raw_base="${CHOPIT_RAW_BASE:-https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main}"
app_dir="${XDG_DATA_HOME:-$HOME/.local/share}/chopit/app"

command -v python3 >/dev/null 2>&1 || { echo 'chopit: python3 is required. Install it with your package manager.' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'chopit: curl is required.' >&2; exit 1; }

mkdir -p "$app_dir"
curl -fsSL "$raw_base/chopit.py" -o "$app_dir/chopit.py.tmp"
mv "$app_dir/chopit.py.tmp" "$app_dir/chopit.py"
chmod 755 "$app_dir/chopit.py"

python3 "$app_dir/chopit.py" install
echo "Installed chopit from $raw_base into $app_dir."
