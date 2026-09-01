#!/usr/bin/env bash
# Step 2 of 3: install the Cluster API controllers on the management cluster.
#
# EXP_CLUSTER_RESOURCE_SET is required. Calico reaches every workload cluster
# as a ClusterResourceSet (see capi/addons/), and that API is behind the gate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CONTEXT=k3d-dropp-mgmt

kubectl config use-context "${CONTEXT}"

export CLUSTER_TOPOLOGY=true
export EXP_CLUSTER_RESOURCE_SET=true

if kubectl get providers -A 2>/dev/null | grep -q cluster-api; then
  echo "==> CAPI providers already installed"
else
  echo "==> installing CAPI providers (docker infrastructure, k3s bootstrap and control plane)"
  clusterctl init \
    --config "${REPO_ROOT}/capi/clusterctl.yaml" \
    --infrastructure docker \
    --bootstrap k3s \
    --control-plane k3s
fi

echo "==> waiting for the controllers"
for ns_deploy in \
  "capi-system:capi-controller-manager" \
  "capd-system:capd-controller-manager" \
  "capi-k3s-bootstrap-system:capi-k3s-bootstrap-controller-manager" \
  "capi-k3s-control-plane-system:capi-k3s-control-plane-controller-manager"; do
  ns="${ns_deploy%%:*}"; deploy="${ns_deploy##*:}"
  kubectl wait --for=condition=Available --timeout=300s -n "${ns}" "deploy/${deploy}"
done

echo "==> CAPI ready"
kubectl get providers -A
