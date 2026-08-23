#!/usr/bin/env bash
# s03: strongest 5-node config (sync any/2 + failoverQuorum), asymmetric
# partition: {primary node, one replica node} | {3 replicas + control plane}.
# EXPECTED (design): clean acks on the old primary stop immediately (it
# cannot assemble 2 acks); the majority side promotes (R=3,W=2,N=4); the
# old primary remains an unfenced zombie until heal (window measured);
# zero clean-ack loss; pseudo-acks/doomed reads possible on the trapped side.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOLD="${HOLD:-300}"
scenario::init s03-sync-q-asym-5

stack::destroy || true
stack::deploy "$ROOT/stacks/$LAB_STACK/clusters/sync-q-5.yaml"
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
