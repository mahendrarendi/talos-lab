#!/usr/bin/env bash

# Print a Talos v1.14 control-plane API VIP patch using values loaded from .env.
talos_lab_vip_patch() {
  local node_id="${1:-}"
  local link_var=""

  case "$node_id" in
    cp1) link_var="CP1_VIP_LINK" ;;
    cp2) link_var="CP2_VIP_LINK" ;;
    cp3) link_var="CP3_VIP_LINK" ;;
    *) echo "VIP patch target must be cp1, cp2, or cp3." >&2; return 2 ;;
  esac

  local vip_ip="${API_VIP_IP:-}"
  local vip_link="${!link_var:-}"
  if [[ -z "$vip_ip" || -z "$vip_link" ]]; then
    echo "Set API_VIP_IP and $link_var in the local .env before rendering $node_id's VIP patch." >&2
    return 1
  fi
  if [[ ! "$vip_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "API_VIP_IP must be an IPv4 address." >&2
    return 1
  fi
  local octet
  local -a octets
  IFS=. read -r -a octets <<< "$vip_ip"
  for octet in "${octets[@]}"; do
    if (( 10#$octet > 255 )); then
      echo "API_VIP_IP has an invalid IPv4 octet." >&2
      return 1
    fi
  done
  local address_var
  for address_var in CP1_IP CP2_IP CP3_IP W1_IP W2_IP; do
    if [[ "$vip_ip" == "${!address_var:-}" ]]; then
      echo "API_VIP_IP must not equal $address_var." >&2
      return 1
    fi
  done
  if [[ ! "$vip_link" =~ ^[a-zA-Z0-9_.:-]+$ ]]; then
    echo "$link_var must be one Talos network link name." >&2
    return 1
  fi

  printf 'apiVersion: v1alpha1\nkind: Layer2VIPConfig\nname: %s\nlink: %s\n' "$vip_ip" "$vip_link"
}
