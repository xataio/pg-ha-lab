#!/usr/bin/env bash
# sync01: strongest 3-node config (sync any/1 + failoverQuorum), asymmetric
# partition: {primary node, one replica node} | {rest + control plane}.
# EXPECTED (design): no promotion (R=1,W=1,N=2 fails R+W>N); the trapped
# pair keeps serving cleanly and safely; zero clean-ack loss. Availability
# on the majority side drops to zero — measured, not judged.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOLD="${HOLD:-300}"
scenario::init sync01-asym-3

stack::destroy || true
stack::deploy "$ROOT/stacks/$LAB_STACK/clusters/sync-q-3.yaml"
scenario::start_clients

echo ">> baseline for 60s"
sleep 60

primary=$(stack::primary_pod)
pnode_short=$(node_short "$(stack::node_of "$primary")")
replica_node_short=$(stack::instances | awk -v p="$primary" '$1 != p {print $2; exit}')
replica_node_short=$(node_short "$replica_node_short")
groupA="$pnode_short,$replica_node_short"
groupB=$(all_node_shorts | grep -vx "$pnode_short" | grep -vx "$replica_node_short" | paste -sd, -)
scenario::event "{\"event\":\"observation\",\"t\":\"$(ts)\",\"primary\":\"$primary\",\"groupA\":\"$groupA\"}"

echo ">> partition: {$groupA} | {$groupB} for ${HOLD}s"
scenario::event "$("$ROOT/nemesis/partition.sh" apply "$groupA" "$groupB")"
sleep "$HOLD"
scenario::event "$("$ROOT/nemesis/partition.sh" heal)"

echo ">> waiting for convergence"
stack::wait_healthy 600 || true
sleep 30

scenario::collect
scenario::stop_clients
scenario::finish
