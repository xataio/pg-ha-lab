#!/usr/bin/env bash
# Pairwise network partition between two groups of kind nodes, via iptables
# rules inserted inside the kind node containers. Blocks node IPs AND pod
# CIDRs so both host-level traffic (kubelet/API server, instance-manager ->
# API) and pod-to-pod traffic are cut.
#
# Usage:
#   partition.sh apply "<groupA>" "<groupB>" [--one-way]
#   partition.sh heal
#   partition.sh status
#
# Groups are comma-separated node short names, e.g.
#   "worker,worker2" "worker3,worker4,worker5,control-plane"
# (kind container names are ${KIND_NAME}-<shortname>).
#
# --one-way: only group A drops traffic *coming from* group B (A is deaf to
# B; B still hears A). Default is a symmetric cut, applied on both sides.
set -euo pipefail

KIND_NAME="${KIND_NAME:-pg-ha-lab}"
CHAIN="PGLAB"

node_container() { echo "${KIND_NAME}-$1"; }

node_ip() { # <shortname>
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$(node_container "$1")"
}

pod_cidr() { # <shortname>
  kubectl get node "$(node_container "$1")" -o jsonpath='{.spec.podCIDR}'
}

ensure_chain() { # <shortname>
  local c; c=$(node_container "$1")
  docker exec "$c" iptables -N "$CHAIN" 2>/dev/null || true
  for hook in INPUT OUTPUT FORWARD; do
    docker exec "$c" iptables -C "$hook" -j "$CHAIN" 2>/dev/null \
      || docker exec "$c" iptables -I "$hook" -j "$CHAIN"
  done
}

# On node $1, drop all traffic to/from node $2 (or only from, if one-way).
block() { # <on> <peer> <mode:both|from>
  local on="$1" peer="$2" mode="$3"
  local c ip cidr
  c=$(node_container "$on")
  ip=$(node_ip "$peer")
  cidr=$(pod_cidr "$peer")
  ensure_chain "$on"
  docker exec "$c" iptables -A "$CHAIN" -s "$ip" -j DROP
  docker exec "$c" iptables -A "$CHAIN" -s "$cidr" -j DROP
  if [[ "$mode" == "both" ]]; then
    docker exec "$c" iptables -A "$CHAIN" -d "$ip" -j DROP
    docker exec "$c" iptables -A "$CHAIN" -d "$cidr" -j DROP
  fi
}

all_nodes() {
  docker ps --format '{{.Names}}' | grep "^${KIND_NAME}-" | sed "s/^${KIND_NAME}-//"
}

cmd="${1:-}"
case "$cmd" in
  apply)
    groupA="${2:?groupA required}"
    groupB="${3:?groupB required}"
    mode="both"
    [[ "${4:-}" == "--one-way" ]] && mode="one-way"
    IFS=',' read -ra A <<< "$groupA"
    IFS=',' read -ra B <<< "$groupB"
    t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for a in "${A[@]}"; do
      for b in "${B[@]}"; do
        if [[ "$mode" == "both" ]]; then
          block "$a" "$b" both
          block "$b" "$a" both
        else
          # A drops incoming from B only
          block "$a" "$b" from
        fi
      done
    done
    echo "{\"event\":\"partition_apply\",\"t\":\"$t0\",\"groupA\":\"$groupA\",\"groupB\":\"$groupB\",\"mode\":\"$mode\"}"
    ;;
  heal)
    t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for n in $(all_nodes); do
      c=$(node_container "$n")
      docker exec "$c" iptables -F "$CHAIN" 2>/dev/null || true
    done
    echo "{\"event\":\"partition_heal\",\"t\":\"$t0\"}"
    ;;
  status)
    for n in $(all_nodes); do
      c=$(node_container "$n")
      echo "== $c"
      docker exec "$c" iptables -S "$CHAIN" 2>/dev/null || echo "  (no chain)"
    done
    ;;
  *)
    grep '^#' "$0" | head -20
    exit 1
    ;;
esac
