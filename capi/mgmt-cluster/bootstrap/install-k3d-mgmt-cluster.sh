#!/usr/bin/env bash
# Step 1 of 3: create the k3d cluster that hosts the CAPI controllers.
# Re-running against an existing cluster does nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER=dropp-mgmt
CONTEXT="k3d-${CLUSTER}"

if k3d cluster list "${CLUSTER}" >/dev/null 2>&1; then
  echo "==> ${CLUSTER} already exists"
else
  echo "==> creating ${CLUSTER}"
  k3d cluster create --config "${HERE}/k3d-mgmt-cluster.yaml"
fi

kubectl config use-context "${CONTEXT}"

echo "==> waiting for the node to be ready"
kubectl wait --for=condition=Ready node --all --timeout=180s

# CAPD puts workload-cluster nodes on the `kind` network. Creating it here
# means the management cluster can join it before the first one exists.
if ! docker network inspect kind >/dev/null 2>&1; then
  echo "==> creating the kind docker network"
  docker network create kind
fi

# Join the management node to that network too.
#
# k3d puts its containers on their own bridge, and Docker drops traffic between
# bridges. CAPD writes the workload kubeconfig with the load balancer's
# container address, so without this the controllers cannot reach any cluster
# they create: ClusterResourceSets report "connection to the workload cluster
# is down", Calico is never delivered, nodes stay NotReady, and the control
# plane never becomes Available. It looks like a broken CNI but it is routing.
for node in $(k3d node list --no-headers 2>/dev/null | awk -v c="${CLUSTER}" '$0 ~ c {print $1}'); do
  if ! docker inspect "${node}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -qw kind; then
    echo "==> attaching ${node} to the kind network"
    docker network connect kind "${node}"
  fi
done

echo "==> management cluster ready (context ${CONTEXT})"
kubectl get nodes
