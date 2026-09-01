#!/usr/bin/env bash
# Step 3 of 3: install Flux on the management cluster and point it at this
# repo. The last imperative step; everything after it arrives through Git.
#
# Three things cannot come from Git, because they are what makes reading Git
# possible: the Flux controllers, the deploy key that reads this repository,
# and the GPG key that decrypts everything else.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FLUX_DIR="${REPO_ROOT}/capi/mgmt-cluster/flux"
CONTEXT=k3d-dropp-mgmt
KEY_DIR="${HOME}/.dropp-heal"

: "${SOPS_GPG_KEY_FILE:=${KEY_DIR}/mgmt.asc}"

kubectl config use-context "${CONTEXT}"

if [ ! -f "${SOPS_GPG_KEY_FILE}" ]; then
  echo "no GPG key at ${SOPS_GPG_KEY_FILE}" >&2
  echo "export SOPS_GPG_KEY_FILE=<armoured private key matching capi/mgmt-cluster/.sops.yaml>" >&2
  exit 1
fi

kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

# `flux create secret git` generates a keypair and keeps the private half in
# the cluster. The public half has to be registered on the repository as a
# read-only deploy key before the first reconcile can work.
if kubectl -n flux-system get secret flux-system >/dev/null 2>&1; then
  echo "==> deploy key secret already present"
else
  echo "==> generating a deploy key for dropporg/dropp-infra"
  flux create secret git flux-system \
    --namespace=flux-system \
    --url=ssh://git@github.com/dropporg/dropp-infra.git \
    --ssh-key-algorithm=ed25519
  cat <<'NOTE'

  ^ Register the public key above as a deploy key on
    https://github.com/dropporg/dropp-infra/settings/keys
    Read-only is sufficient; Flux never writes to this repository.

NOTE
fi

# In two namespaces on purpose. Flux looks up decryption.secretRef in the
# namespace of the Kustomization asking for it: the repo-level ones are in
# flux-system, and the workload bootstrap ones are in `default`, beside the
# CAPI kubeconfig Secrets they use.
for ns in flux-system default; do
  echo "==> creating the sops-gpg secret in ${ns}"
  kubectl -n "${ns}" create secret generic sops-gpg \
    --from-file=sops.asc="${SOPS_GPG_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# Two passes, in this order. gotk-components.yaml has the CRDs and the
# controllers; gotk-sync.yaml has a GitRepository and a Kustomization, which
# are instances of those CRDs. Applying the directory at once fails with "no
# matches for kind Kustomization", because kubectl resolves every resource
# against the discovery cache as it reads the file.
echo "==> installing the Flux controllers"
kubectl apply -f "${FLUX_DIR}/flux-system/gotk-components.yaml"

echo "==> waiting for the CRDs to be established"
kubectl wait --for=condition=Established --timeout=120s \
  crd/gitrepositories.source.toolkit.fluxcd.io \
  crd/kustomizations.kustomize.toolkit.fluxcd.io \
  crd/helmreleases.helm.toolkit.fluxcd.io \
  crd/helmrepositories.source.toolkit.fluxcd.io

echo "==> waiting for the controllers"
kubectl -n flux-system wait --for=condition=Available --timeout=300s \
  deploy/source-controller deploy/kustomize-controller \
  deploy/helm-controller deploy/notification-controller

echo "==> pointing Flux at this repository"
kubectl apply -f "${FLUX_DIR}/flux-system/gotk-sync.yaml"

cat <<'EOF2'

==> Flux installed.

Watch it take over:

  flux get sources git -A
  flux get kustomizations -A
  kubectl get clusters -A

If the GitRepository reports an SSH error, the deploy key is not registered yet.
EOF2
