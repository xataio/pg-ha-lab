#!/usr/bin/env bash
# Patroni (Spilo) stack adapter — same stack::* contract as stacks/cnpg/lib.sh.
# Sourced by scenario scripts. Requires: kubectl, jq. Env: NS, CLUSTER.

CLUSTER="${CLUSTER:-pglab}"

stack::deploy() { # <path-to-manifest>
  # cross-stack guard: a leftover CNPG cluster would collide on names
  kubectl -n "$NS" delete cluster.postgresql.cnpg.io "$CLUSTER" \
    --ignore-not-found --wait=true 2>/dev/null || true
  kubectl -n "$NS" apply -f "$1"
  stack::wait_healthy 600
}

stack::wait_healthy() { # <timeout-seconds>
  local deadline=$(( $(date +%s) + $1 ))
  local want
  want=$(kubectl -n "$NS" get sts "$CLUSTER" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo -1)
  while true; do
    local masters ready
    masters=$(kubectl -n "$NS" get pods -l cluster-name="$CLUSTER",spilo-role=master \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready=$(kubectl -n "$NS" get pods -l cluster-name="$CLUSTER" -o json 2>/dev/null \
      | jq '[.items[] | select(.status.containerStatuses[0].ready == true)] | length')
    if [[ "$masters" == "1" && "$ready" == "$want" ]]; then
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      echo "!! patroni cluster not healthy after $1s (masters=$masters ready=$ready/$want)" >&2
      return 1
    fi
    sleep 5
  done
}

stack::primary_pod() {
  kubectl -n "$NS" get pods -l cluster-name="$CLUSTER",spilo-role=master \
    -o jsonpath='{.items[0].metadata.name}'
}

stack::node_of() { # <pod>
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}'
}

# "pod node role" per line; Patroni roles: master / replica / sync_standby
stack::instances() {
  kubectl -n "$NS" get pods -l cluster-name="$CLUSTER",application=spilo \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.metadata.labels.spilo-role}{"\n"}{end}'
}

stack::pod_ip() { # <pod>
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.podIP}'
}

stack::rw_service() { echo "${CLUSTER}-rw.${NS}.svc"; }

stack::app_secret() { echo "${CLUSTER}-app"; }

stack::app_db() { echo "postgres"; }

stack::collect() { # <outdir>
  local out="$1"; mkdir -p "$out"
  kubectl -n "$NS" get sts "$CLUSTER" -o yaml > "$out/statefulset.yaml" 2>&1 || true
  kubectl -n "$NS" get cm -l cluster-name="$CLUSTER" -o yaml > "$out/dcs-configmaps.yaml" 2>&1 || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp -o json > "$out/events.json" 2>&1 || true
  kubectl -n "$NS" get pods -o wide > "$out/pods.txt" 2>&1 || true
  local primary
  primary=$(stack::primary_pod 2>/dev/null || true)
  if [[ -n "$primary" ]]; then
    kubectl -n "$NS" exec "$primary" -- patronictl list > "$out/patronictl-list.txt" 2>&1 || true
    kubectl -n "$NS" exec "$primary" -- patronictl history > "$out/patronictl-history.txt" 2>&1 || true
  fi
  local pod
  while read -r pod _node _role; do
    [[ -n "$pod" ]] || continue
    kubectl -n "$NS" logs "$pod" --tail=-1 > "$out/instance-$pod.log" 2>&1 || true
    kubectl -n "$NS" logs "$pod" --previous --tail=-1 > "$out/instance-$pod.previous.log" 2>&1 || true
  done < <(stack::instances)
}

stack::destroy() {
  kubectl -n "$NS" delete sts "$CLUSTER" --ignore-not-found --wait=true
  kubectl -n "$NS" delete svc "${CLUSTER}-rw" "${CLUSTER}-headless" --ignore-not-found
  kubectl -n "$NS" delete pvc -l cluster-name="$CLUSTER" --ignore-not-found
  # Patroni's DCS state MUST go too, or the next cluster inherits a stale
  # initialize key (system identifier mismatch -> bootstrap refusal)
  kubectl -n "$NS" delete cm -l cluster-name="$CLUSTER" --ignore-not-found
  kubectl -n "$NS" delete cm "${CLUSTER}-leader" "${CLUSTER}-config" \
    "${CLUSTER}-sync" "${CLUSTER}-failover" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete secret "${CLUSTER}-app" --ignore-not-found
  kubectl -n "$NS" delete sa,role,rolebinding "${CLUSTER}-patroni" --ignore-not-found 2>/dev/null || true
}

stack::dump_final_ids() { # <outfile>
  local pod
  for pod in $(stack::primary_pod) $(stack::instances | awk '{print $1}'); do
    if kubectl -n "$NS" exec "$pod" -- \
        psql -U postgres -d postgres -At -c "SELECT id FROM lab_writes ORDER BY id" > "$1" 2>/dev/null; then
      echo ">> final state dumped from $pod"
      return 0
    fi
  done
  return 1
}
