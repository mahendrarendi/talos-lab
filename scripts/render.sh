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

for value in CLUSTER_NAME CP_ENDPOINT INSTALL_DISK KUBERNETES_VERSION TALOS_VERSION_CONTRACT TALOS_INSTALLER_IMAGE SECRETS_FILE CP_WORKLOADS; do
  if [[ -z "${!value:-}" ]]; then
    echo "Missing $value in .env" >&2
    exit 1
  fi
done

secrets_path="$SECRETS_FILE"
if [[ "$secrets_path" != /* ]]; then
  secrets_path="$repo_dir/$secrets_path"
fi
if [[ ! -f "$secrets_path" ]]; then
  echo "Secrets file not found: $secrets_path" >&2
  exit 1
fi

usage() {
  echo "Usage: scripts/render.sh cp1|cp2|cp3|w1|w2" >&2
  echo "       scripts/render.sh worker <node-id> <hostname>" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
node_id="$1"
role=""
hostname_patch=""

case "$node_id" in
  cp1)
    [[ $# -eq 1 ]] || usage
    role="controlplane"
    hostname_patch="@$repo_dir/patches/srvcp1ab01.yaml"
    output_name="controlplane.yaml"
    ;;
  cp2)
    [[ $# -eq 1 ]] || usage
    role="controlplane"
    hostname_patch="@$repo_dir/patches/srvcp1ab02.yaml"
    output_name="controlplane-cp2.yaml"
    ;;
  cp3)
    [[ $# -eq 1 ]] || usage
    role="controlplane"
    hostname_patch="@$repo_dir/patches/srvcp1ab03.yaml"
    output_name="controlplane-cp3.yaml"
    ;;
  w1)
    [[ $# -eq 1 ]] || usage
    role="worker"
    hostname_patch="@$repo_dir/patches/srvwrk1ab01.yaml"
    output_name="worker.yaml"
    ;;
  w2)
    [[ $# -eq 1 ]] || usage
    role="worker"
    hostname_patch="@$repo_dir/patches/srvwrk1ab02.yaml"
    output_name="worker-w2.yaml"
    ;;
  worker)
    [[ $# -eq 3 ]] || usage
    node_id="$2"
    hostname="$3"
    if [[ ! "$node_id" =~ ^[a-z][a-z0-9-]*$ || ! "$hostname" =~ ^[a-z][a-z0-9-]*$ ]]; then
      echo "Node ID and hostname must contain lowercase letters, digits, or hyphens." >&2
      exit 2
    fi
    role="worker"
    output_name="worker-$node_id.yaml"
    printf -v hostname_patch 'apiVersion: v1alpha1\nkind: HostnameConfig\nauto:\n  $patch: delete\nhostname: %s\n' "$hostname"
    ;;
  *) usage ;;
esac

if [[ "$hostname_patch" == @* && ! -f "${hostname_patch#@}" ]]; then
  echo "Hostname patch not found: ${hostname_patch#@}" >&2
  exit 1
fi

output_dir="${TALOS_LAB_OUTPUT_DIR:-$repo_dir/_out}"
mkdir -p "$output_dir"
chmod 700 "$output_dir"
output_file="$output_dir/$output_name"
force_args=()
if [[ "${TALOS_LAB_OVERWRITE:-0}" == 1 ]]; then
  force_args+=(--force)
elif [[ -e "$output_file" ]]; then
  echo "Refusing to replace $output_file. Set TALOS_LAB_OVERWRITE=1 to regenerate it." >&2
  exit 1
fi

patch_args=(--config-patch "$hostname_patch")
if [[ -n "${COMMON_PATCH:-}" ]]; then
  common_patch_path="$COMMON_PATCH"
  if [[ "$common_patch_path" != /* ]]; then
    common_patch_path="$repo_dir/$common_patch_path"
  fi
  if [[ ! -f "$common_patch_path" ]]; then
    echo "Common patch not found: $common_patch_path" >&2
    exit 1
  fi
  patch_args+=(--config-patch "@$common_patch_path")
fi
if [[ "$role" == "controlplane" ]]; then
  if [[ -n "${API_VIP_IP:-}" ]]; then
    source "$repo_dir/scripts/lib/vip.sh"
    vip_patch="$(talos_lab_vip_patch "$node_id")"
    patch_args+=(--config-patch-control-plane "$vip_patch")
  fi
  if [[ "$CP_WORKLOADS" == "true" ]]; then
    patch_args+=(--config-patch-control-plane "@$repo_dir/patches/allow-scheduling.yaml")
  elif [[ "$CP_WORKLOADS" == "false" ]]; then
    patch_args+=(--config-patch-control-plane "@$repo_dir/cluster.yaml")
  else
    echo "CP_WORKLOADS must be true or false." >&2
    exit 1
  fi
fi

talosctl gen config "$CLUSTER_NAME" "$CP_ENDPOINT" \
  --with-secrets "$secrets_path" \
  --install-disk "$INSTALL_DISK" \
  --install-image "$TALOS_INSTALLER_IMAGE" \
  --talos-version "$TALOS_VERSION_CONTRACT" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --with-docs=false --with-examples=false \
  --output-types "$role" --output "$output_file" \
  "${force_args[@]}" \
  "${patch_args[@]}"

chmod 600 "$output_file"
talosctl validate --config "$output_file" --mode metal

client_force_args=()
if [[ "${TALOS_LAB_REGENERATE_CLIENT:-0}" == 1 ]]; then
  client_force_args+=(--force)
fi
if [[ ! -e "$output_dir/talosconfig" || "${TALOS_LAB_REGENERATE_CLIENT:-0}" == 1 ]]; then
  talosctl gen config "$CLUSTER_NAME" "$CP_ENDPOINT" \
    --with-secrets "$secrets_path" \
    --install-image "$TALOS_INSTALLER_IMAGE" \
    --talos-version "$TALOS_VERSION_CONTRACT" \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --output-types talosconfig --output "$output_dir/talosconfig" \
    "${client_force_args[@]}"
fi
chmod 600 "$output_dir/talosconfig"

echo "Generated $output_file and validated it. No node was changed."
