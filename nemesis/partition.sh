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
#
# The cut is applied with ONE docker exec per node (all rules in a single
# shell), so it lands near-atomically; apply_start/apply_end timestamps are
# both emitted for the checker.
set -euo pipefail

KIND_NAME="${KIND_NAME:-pg-ha-lab}"
CHAIN="PGLAB"

node_container() { echo "${KIND_NAME}-$1"; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

node_ip() { # <shortname>
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$(node_container "$1")"
}

pod_cidr() { # <shortname>
  kubectl get node "$(node_container "$1")" -o jsonpath='{.spec.podCIDR}'
}

lookup() { # <shortname> -> "ip cidr" from the pre-resolved table
  awk -v n="$1" '$1==n{print $2, $3}' "$INFO"
}

# Emit the full iptables script for <node>, dropping traffic from (and, for
# mode=both, to) every peer in $2 (space-separated shortnames).
node_script() { # <node> <peers...> <mode:both|from>
  local node="$1" peers="$2" mode="$3" ip cidr
  echo "iptables -N $CHAIN 2>/dev/null || true"
  for hook in INPUT OUTPUT FORWARD; do
    echo "iptables -C $hook -j $CHAIN 2>/dev/null || iptables -I $hook -j $CHAIN"
  done
  for p in $peers; do
    read -r ip cidr < <(lookup "$p")
    echo "iptables -A $CHAIN -s $ip -j DROP"
    echo "iptables -A $CHAIN -s $cidr -j DROP"
    if [[ "$mode" == "both" ]]; then
      echo "iptables -A $CHAIN -d $ip -j DROP"
      echo "iptables -A $CHAIN -d $cidr -j DROP"
    fi
  done
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

    # pre-resolve all IPs/CIDRs so the cut itself is tight
    INFO=$(mktemp)
    trap 'rm -f "$INFO"' EXIT
    for n in "${A[@]}" "${B[@]}"; do
      echo "$n $(node_ip "$n") $(pod_cidr "$n")" >> "$INFO"
    done

    echo "{\"event\":\"partition_apply_start\",\"t\":\"$(ts)\",\"groupA\":\"$groupA\",\"groupB\":\"$groupB\",\"mode\":\"$mode\"}"
    for a in "${A[@]}"; do
      node_script "$a" "${B[*]}" "$([[ $mode == both ]] && echo both || echo from)" \
        | docker exec -i "$(node_container "$a")" sh -e
    done
    if [[ "$mode" == "both" ]]; then
      for b in "${B[@]}"; do
        node_script "$b" "${A[*]}" both \
          | docker exec -i "$(node_container "$b")" sh -e
      done
    fi
    echo "{\"event\":\"partition_apply\",\"t\":\"$(ts)\",\"groupA\":\"$groupA\",\"groupB\":\"$groupB\",\"mode\":\"$mode\"}"
    ;;
  heal)
    for n in $(all_nodes); do
      docker exec "$(node_container "$n")" iptables -F "$CHAIN" 2>/dev/null || true
    done
    echo "{\"event\":\"partition_heal\",\"t\":\"$(ts)\"}"
    ;;
  status)
    for n in $(all_nodes); do
      echo "== $(node_container "$n")"
      docker exec "$(node_container "$n")" iptables -S "$CHAIN" 2>/dev/null || echo "  (no chain)"
    done
    ;;
  *)
    grep '^#' "$0" | head -22
    exit 1
    ;;
esac
