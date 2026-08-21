#!/usr/bin/env bash
# Process-pause nemesis (coarse, node-level for now).
#
# Usage:
#   pause.sh node <shortname>          # freeze the whole kind node
#   pause.sh node <shortname> resume   # unfreeze
#
# Node-level docker pause freezes kubelet, kube-proxy, the instance manager
# and PostgreSQL simultaneously: the classic "machine stalls longer than the
# lease/ttl, then comes back believing nothing happened" fault.
set -euo pipefail

KIND_NAME="${KIND_NAME:-pg-ha-lab}"

case "${1:-}" in
  node)
    c="${KIND_NAME}-${2:?node shortname required}"
    t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ "${3:-}" == "resume" ]]; then
      docker unpause "$c"
      echo "{\"event\":\"node_resume\",\"t\":\"$t0\",\"node\":\"$c\"}"
    else
      docker pause "$c"
      echo "{\"event\":\"node_pause\",\"t\":\"$t0\",\"node\":\"$c\"}"
    fi
    ;;
  *)
    grep '^#' "$0" | head -12
    exit 1
    ;;
esac
