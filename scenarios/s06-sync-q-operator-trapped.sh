#!/usr/bin/env bash
# s06: the s02 geometry (sync any/1 + quorum, {primary + sync standby}
# trapped) with the s05 twist: the single-replica operator is re-pinned onto
# the primary's node first, so it is trapped too.
#
# EXPECTED: during the fault, identical to s02 (the operator was
# quorum-denied anyway): no promotion, fence at ~cut+213s, outage until
# heal. At heal, the s05 race occurs but should be DEFANGED by sync+quorum:
# the returning operator either (a) loses the race to the resuming primary
# (s02 outcome), or (b) promotes — in which case the quorum check must deny
# until both replicas are visible (R=2) and the LSN sort must pick the
# trapped sync standby, which holds every acked commit. Either way: ZERO
# clean-ack loss. A loss here would be a significant quorum-machinery bug.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOLD="${HOLD:-300}"
[[ "$LAB_STACK" == cnpg ]] || { echo "!! $0 is cnpg-only (it manipulates the cnpg operator deployment)"; exit 1; }
scenario::init s06-sync-q-operator-trapped

restore_operator_pin() {
  kubectl -n cnpg-system patch deployment cnpg-controller-manager --type=strategic -p '{
    "spec": {"template": {"spec": {
      "nodeSelector": {"kubernetes.io/hostname": null,
                       "node-role.kubernetes.io/control-plane": ""}
  }}}}' >/dev/null 2>&1 || true
}

stack::destroy || true
stack::deploy "$ROOT/stacks/cnpg/clusters/sync-q-3.yaml"
scenario::start_clients

echo ">> baseline for 60s"
sleep 60

primary=$(stack::primary_pod)
pnode=$(stack::node_of "$primary")
pnode_short=$(node_short "$pnode")
replica_node=$(stack::instances | awk -v p="$primary" '$1 != p {print $2; exit}')
replica_node_short=$(node_short "$replica_node")

echo ">> trapping the operator on $pnode"
trap 'restore_operator_pin; "$ROOT/nemesis/partition.sh" heal >/dev/null 2>&1 || true' EXIT TERM INT
kubectl -n cnpg-system patch deployment cnpg-controller-manager --type=strategic -p "{
  \"spec\": {\"template\": {\"spec\": {
    \"nodeSelector\": {\"kubernetes.io/hostname\": \"$pnode\",
                       \"node-role.kubernetes.io/control-plane\": null}
}}}}"
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=120s

groupA="$pnode_short,$replica_node_short"
groupB=$(all_node_shorts | grep -vx "$pnode_short" | grep -vx "$replica_node_short" | paste -sd, -)
scenario::event "{\"event\":\"observation\",\"t\":\"$(ts)\",\"primary\":\"$primary\",\"groupA\":\"$groupA\",\"operator_node\":\"$pnode_short\"}"

echo ">> partition: {$groupA} | {$groupB} for ${HOLD}s"
scenario::event "$("$ROOT/nemesis/partition.sh" apply "$groupA" "$groupB")"
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
