#!/usr/bin/env bash
# Shared scenario plumbing. Scenario scripts source this, then use:
#   scenario::init <name>       -> sets RUN_DIR, sources the stack adapter
#   scenario::event <json>      -> append a nemesis/timeline event
#   scenario::start_clients     -> writer+reader pods on every instance node
#   scenario::collect           -> histories, stack evidence, final state
#   scenario::finish            -> checker + summary
set -euo pipefail

# LAB_STACK, not STACK: some environments export STACK for their own purposes
LAB_STACK="${LAB_STACK:-cnpg}"
NS="${NS:-pglab}"
KIND_NAME="${KIND_NAME:-pg-ha-lab}"
CLIENT_IMAGE="${CLIENT_IMAGE:-pg-ha-lab-client:dev}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "$ROOT/stacks/$LAB_STACK/lib.sh"

scenario::init() { # <scenario-name>
  SCENARIO_NAME="$1"
  RUN_ID="${SCENARIO_NAME}-$(date -u +%Y%m%d-%H%M%S)"
  RUN_DIR="$ROOT/results/$RUN_ID"
  mkdir -p "$RUN_DIR/history" "$RUN_DIR/stack"
  echo ">> run: $RUN_DIR"
  echo "{\"event\":\"scenario_start\",\"t\":\"$(ts)\",\"scenario\":\"$SCENARIO_NAME\",\"stack\":\"$LAB_STACK\"}" \
    > "$RUN_DIR/events.jsonl"
}

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

scenario::event() { # <json-line>  (already-formed JSON from nemesis scripts)
  echo "$1" | tee -a "$RUN_DIR/events.jsonl"
}

node_short() { echo "${1#"${KIND_NAME}"-}"; }

# All kind node shortnames (from kubernetes).
all_node_shorts() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | sed "s/^${KIND_NAME}-//"
}

# One clean writer, one cancel writer and one reader pod pinned to each node
# that hosts an instance. All connect through the -rw service, so stale
# kube-proxy routing inside a partition is part of the experiment.
scenario::start_clients() {
  # make sure leftovers from a previous run are fully gone first
  kubectl -n "$NS" delete pods -l app=pglab-client --ignore-not-found --wait=true
  local secret host
  secret=$(stack::app_secret)
  host=$(stack::rw_service)
  while read -r pod node _role; do
    [[ -n "$pod" ]] || continue
    local short; short=$(node_short "$node")
    for m in clean cancel read; do
      client_pod_manifest "$m" "$short" "$node" "$host" "$secret"
    done | kubectl -n "$NS" apply -f -
  done < <(stack::instances)
  kubectl -n "$NS" wait --for=condition=Ready pod -l app=pglab-client --timeout=120s
  scenario::event "{\"event\":\"clients_started\",\"t\":\"$(ts)\"}"
}

client_pod_manifest() { # <mode> <nodeshort> <nodename> <host> <secret>
  local m="$1" short="$2" node="$3" host="$4" secret="$5"
  cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: lab-$m-$short
  labels:
    app: pglab-client
    lab-mode: $m
spec:
  nodeName: $node
  restartPolicy: Always
  containers:
    - name: client
      image: $CLIENT_IMAGE
      imagePullPolicy: IfNotPresent
      args:
        - "-mode=$m"
        - "-host=$host"
        - "-client=$m-$short"
        - "-interval=500ms"
      env:
        - name: PGUSER
          valueFrom: {secretKeyRef: {name: $secret, key: username}}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: $secret, key: password}}
        - name: PGDATABASE
          value: app
EOF
}

scenario::collect_client_logs() {
  local pod
  for pod in $(kubectl -n "$NS" get pods -l app=pglab-client -o name); do
    pod="${pod#pod/}"
    kubectl -n "$NS" logs "$pod" --tail=-1 > "$RUN_DIR/history/$pod.jsonl" 2>/dev/null || true
    kubectl -n "$NS" logs "$pod" --previous --tail=-1 \
      > "$RUN_DIR/history/$pod.previous.jsonl" 2>/dev/null || true
  done
  find "$RUN_DIR/history" -name '*.previous.jsonl' -empty -delete 2>/dev/null || true
}

scenario::stop_clients() {
  kubectl -n "$NS" delete pods -l app=pglab-client --ignore-not-found --wait=false
}

scenario::collect() {
  scenario::event "{\"event\":\"collect_start\",\"t\":\"$(ts)\"}"
  scenario::collect_client_logs
  stack::collect "$RUN_DIR/stack"
  stack::dump_final_ids "$RUN_DIR/final_ids.txt" \
    || scenario::event "{\"event\":\"final_dump_failed\",\"t\":\"$(ts)\"}"
}

scenario::finish() {
  scenario::event "{\"event\":\"scenario_end\",\"t\":\"$(ts)\"}"
  echo
  python3 "$ROOT/checker/check.py" "$RUN_DIR" | tee "$RUN_DIR/report.txt" || true
  echo
  echo ">> full evidence in $RUN_DIR"
}
