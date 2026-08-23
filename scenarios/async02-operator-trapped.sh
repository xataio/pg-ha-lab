#!/usr/bin/env bash
# async02: same fault as async01 (async config, primary's node fully isolated), but
# with the single-replica operator deliberately re-pinned onto the primary's
# node first, so the partition traps them together.
#
# EXPECTED (vs async01, which differs only in operator placement): NO promotion
# for the entire fault (no operator able to act); the trapped primary serves
# its zone until the isolation fence completes (~cut+210s) and those acks
# SURVIVE (no promotion -> no rewind); then total write outage until heal;
# clean resume of the same primary afterwards. Zero data loss, zero
# dual-ack — the availability/consistency inversion of async01.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOLD="${HOLD:-300}"
[[ "$LAB_STACK" == cnpg ]] || { echo "!! $0 is cnpg-only (it manipulates the cnpg operator deployment)"; exit 1; }
scenario::init async02-operator-trapped

# NOTE: strategic-merge patches MERGE map keys, so each pin must explicitly
# null out the other pin's key or the selector becomes unsatisfiable.
restore_operator_pin() {
  kubectl -n cnpg-system patch deployment cnpg-controller-manager --type=strategic -p '{
    "spec": {"template": {"spec": {
      "nodeSelector": {"kubernetes.io/hostname": null,
                       "node-role.kubernetes.io/control-plane": ""}
  }}}}' >/dev/null 2>&1 || true
}

stack::destroy || true
stack::deploy "$ROOT/stacks/cnpg/clusters/async-3.yaml"
scenario::start_clients

echo ">> baseline for 60s"
sleep 60

primary=$(stack::primary_pod)
pnode=$(stack::node_of "$primary")
pnode_short=$(node_short "$pnode")

echo ">> trapping the operator on $pnode"
trap 'restore_operator_pin; "$ROOT/nemesis/partition.sh" heal >/dev/null 2>&1 || true' EXIT TERM INT
kubectl -n cnpg-system patch deployment cnpg-controller-manager --type=strategic -p "{
  \"spec\": {\"template\": {\"spec\": {
    \"nodeSelector\": {\"kubernetes.io/hostname\": \"$pnode\",
                       \"node-role.kubernetes.io/control-plane\": null}
}}}}"
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=120s
scenario::event "{\"event\":\"observation\",\"t\":\"$(ts)\",\"primary\":\"$primary\",\"primary_node\":\"$pnode_short\",\"operator_node\":\"$pnode_short\"}"

others=$(all_node_shorts | grep -vx "$pnode_short" | paste -sd, -)
echo ">> partition: {$pnode_short} | {$others} for ${HOLD}s"
scenario::event "$("$ROOT/nemesis/partition.sh" apply "$pnode_short" "$others")"
sleep "$HOLD"
scenario::event "$("$ROOT/nemesis/partition.sh" heal)"

echo ">> restoring operator to the control plane"
restore_operator_pin
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=120s || true

echo ">> waiting for convergence"
stack::wait_healthy 600 || true
sleep 30

scenario::collect
scenario::stop_clients
scenario::finish
