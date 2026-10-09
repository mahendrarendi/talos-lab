#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
settings_file="${TALOS_LAB_SETTINGS_FILE:-$repo_dir/.env}"
if [[ ! -f "$settings_file" ]]; then
  echo "Create .env from .env.example and confirm the values first." >&2
  exit 1
fi

# .env is a trusted, local shell configuration file.
set -a
source "$settings_file"
set +a
source "$repo_dir/scripts/lib/vip.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/render-vip.sh cp1|cp2|cp3" >&2
  exit 2
fi
node_id="$1"
vip_patch="$(talos_lab_vip_patch "$node_id")"

output_dir="${TALOS_LAB_OUTPUT_DIR:-$repo_dir/_out}"
mkdir -p "$output_dir"
chmod 700 "$output_dir"
output_file="$output_dir/api-vip-$node_id.yaml"
if [[ -e "$output_file" && "${TALOS_LAB_OVERWRITE:-0}" != 1 ]]; then
  echo "Refusing to replace $output_file. Set TALOS_LAB_OVERWRITE=1 to regenerate it." >&2
  exit 1
fi

printf '%s\n' "$vip_patch" > "$output_file"
chmod 600 "$output_file"
echo "Generated $output_file. No node was changed. Review the VIP and link before any live patch."
