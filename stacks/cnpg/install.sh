#!/usr/bin/env bash
# Install a pinned CloudNativePG operator version and wait for it to be ready.
set -euo pipefail

CNPG_VERSION="${CNPG_VERSION:-1.30.0}"
RELEASE_BRANCH="release-$(echo "$CNPG_VERSION" | cut -d. -f1-2)"
MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${RELEASE_BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"

echo ">> installing CloudNativePG ${CNPG_VERSION}"
kubectl apply --server-side -f "$MANIFEST"
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=180s
echo ">> operator ready"
