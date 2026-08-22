#!/usr/bin/env bash
# Install a pinned CloudNativePG operator version and wait for it to be ready.
set -euo pipefail

if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/pg-ha-lab.config" ]]; then
  export KUBECONFIG="$HOME/.kube/pg-ha-lab.config"
fi

CNPG_VERSION="${CNPG_VERSION:-1.30.0}"
RELEASE_BRANCH="release-$(echo "$CNPG_VERSION" | cut -d. -f1-2)"
MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${RELEASE_BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"

echo ">> installing CloudNativePG ${CNPG_VERSION}"
kubectl apply --server-side -f "$MANIFEST"

# Pin the operator to the control-plane node: the data-plane workers are
# partition targets, and an operator trapped inside a partition cannot run
# failovers (a legitimate fault to study, but as its own scenario — by
# including control-plane in a partition group — not as an accident).
kubectl -n cnpg-system patch deployment cnpg-controller-manager --type=strategic -p '{
  "spec": {"template": {"spec": {
    "nodeSelector": {"node-role.kubernetes.io/control-plane": ""},
    "tolerations": [{"key": "node-role.kubernetes.io/control-plane",
                     "operator": "Exists", "effect": "NoSchedule"}]
}}}}'
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=180s
echo ">> operator ready"
