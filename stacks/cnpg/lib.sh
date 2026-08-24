#!/usr/bin/env bash
# CNPG stack adapter. Every stack must implement this same set of
# stack::* functions (see stacks/patroni/README.md for the contract).
# Sourced by scenario scripts. Requires: kubectl, jq. Env: NS, CLUSTER.

CLUSTER="${CLUSTER:-pglab}"

# Deploy a cluster config and wait until it is healthy.
stack::deploy() { # <path-to-cluster-yaml>
  # cross-stack guard: leftover Patroni resources collide on names —
  # unlike CNPG's (owner-ref'd to the Cluster), they need explicit teardown
  kubectl -n "$NS" delete sts "$CLUSTER" --ignore-not-found --wait=true 2>/dev/null || true
  kubectl -n "$NS" delete svc "${CLUSTER}-rw" "${CLUSTER}-headless" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete pvc,cm -l cluster-name="$CLUSTER" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete secret "${CLUSTER}-app" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete sa,role,rolebinding "${CLUSTER}-patroni" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" apply -f "$1"
  stack::wait_healthy 600
}

stack::app_db() { echo "app"; }

stack::wait_healthy() { # <timeout-seconds>
  local deadline=$(( $(date +%s) + $1 ))
  while true; do
    local phase ready instances
    phase=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    ready=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)
    instances=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.spec.instances}' 2>/dev/null || echo -1)
    if [[ "$phase" == "Cluster in healthy state" && "$ready" == "$instances" ]]; then
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      echo "!! cluster not healthy after $1s (phase='$phase' ready=$ready/$instances)" >&2
      return 1
    fi
    sleep 5
  done
}

# Name of the current primary pod (per the operator's view).
stack::primary_pod() {
  kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}'
}

# Kubernetes node hosting a given pod.
stack::node_of() { # <pod>
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}'
}

# All instance pods with their nodes and roles: "pod node role" per line.
stack::instances() {
  kubectl -n "$NS" get pods -l cnpg.io/cluster="$CLUSTER",cnpg.io/podRole=instance \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.metadata.labels.cnpg\.io/instanceRole}{"\n"}{end}'
}

# Pod IP of an instance (clients can target it directly).
stack::pod_ip() { # <pod>
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.podIP}'
}

# Read-write service DNS name.
stack::rw_service() { echo "${CLUSTER}-rw.${NS}.svc"; }

# Secret holding app credentials (keys: username, password).
stack::app_secret() { echo "${CLUSTER}-app"; }

# Dump stack-side evidence into a run directory: cluster state, events,
# operator logs, instance-manager logs, failover quorum object if present.
stack::collect() { # <outdir>
  local out="$1"; mkdir -p "$out"
  kubectl -n "$NS" get cluster "$CLUSTER" -o yaml > "$out/cluster.yaml" 2>&1 || true
  kubectl -n "$NS" get failoverquorum "$CLUSTER" -o yaml > "$out/failoverquorum.yaml" 2>&1 || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp -o json > "$out/events.json" 2>&1 || true
  kubectl -n "$NS" get pods -o wide > "$out/pods.txt" 2>&1 || true
  kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=-1 > "$out/operator.log" 2>&1 || true
  local pod
  while read -r pod _node _role; do
    [[ -n "$pod" ]] || continue
    kubectl -n "$NS" logs "$pod" -c postgres --tail=-1 > "$out/instance-$pod.log" 2>&1 || true
    kubectl -n "$NS" logs "$pod" -c postgres --previous --tail=-1 > "$out/instance-$pod.previous.log" 2>&1 || true
  done < <(stack::instances)
}

# Delete the cluster (PVCs included) so the next scenario starts clean.
stack::destroy() {
  kubectl -n "$NS" delete cluster "$CLUSTER" --ignore-not-found --wait=true
  kubectl -n "$NS" delete pvc -l cnpg.io/cluster="$CLUSTER" --ignore-not-found
}

# Dump the final content of the write table (one id per line), bypassing
# services. Prefer the current primary; fall back to any instance that
# answers (a wedged failover must not void the durability check).
stack::dump_final_ids() { # <outfile>
  local pod
  for pod in $(stack::primary_pod) $(stack::instances | awk '{print $1}'); do
    if kubectl -n "$NS" exec "$pod" -c postgres -- \
        psql -U postgres -d app -At -c "SELECT id FROM lab_writes ORDER BY id" > "$1" 2>/dev/null; then
      echo ">> final state dumped from $pod"
      return 0
    fi
  done
  return 1
}
