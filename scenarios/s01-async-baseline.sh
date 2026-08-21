#!/usr/bin/env bash
# s01: harness validation on the async baseline (the cloudnative-pg#7407
# geometry). Fully isolate the primary's node; clients on that node keep
# writing to the old primary through stale routing while a replica is
# promoted outside. EXPECTED: lost acknowledged writes detected — the
# checker must flag them, or the harness cannot be trusted.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOLD="${HOLD:-300}"
scenario::init s01-async-baseline

stack::destroy || true
stack::deploy "$ROOT/stacks/cnpg/clusters/async-3.yaml"
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
