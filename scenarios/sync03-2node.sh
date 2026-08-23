#!/usr/bin/env bash
# sync03: two-node sync any/1 + quorum, primary's node fully isolated.
# EXPECTED: zero clean-ack loss (the survivor holds every acked commit, so
# promotion is always safe); zero write availability on BOTH sides — the
# minority's commits hang from t0, and the promoted survivor's commits hang
# until the old primary rejoins as its replica (measure recovery beyond
# heal). Pseudo-acks expected on both sides: LOST on the minority (erased
# timeline), SURVIVED on the promoted side (winning timeline). Doomed reads
# expected on the minority until the isolation fence completes.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOLD="${HOLD:-300}"
scenario::init sync03-2node

stack::destroy || true
stack::deploy "$ROOT/stacks/$LAB_STACK/clusters/sync-q-2.yaml"
scenario::start_clients

echo ">> baseline for 60s"
sleep 60

primary=$(stack::primary_pod)
pnode_short=$(node_short "$(stack::node_of "$primary")")
others=$(all_node_shorts | grep -vx "$pnode_short" | paste -sd, -)
scenario::event "{\"event\":\"observation\",\"t\":\"$(ts)\",\"primary\":\"$primary\",\"primary_node\":\"$pnode_short\"}"

echo ">> partition: {$pnode_short} | {$others} for ${HOLD}s"
scenario::event "$("$ROOT/nemesis/partition.sh" apply "$pnode_short" "$others")"
sleep "$HOLD"
scenario::event "$("$ROOT/nemesis/partition.sh" heal)"

echo ">> waiting for convergence"
stack::wait_healthy 600 || true
sleep 30

scenario::collect
scenario::stop_clients
scenario::finish
