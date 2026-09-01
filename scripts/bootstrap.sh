#!/usr/bin/env bash
# Bring clusters up.
#
#   ./scripts/bootstrap.sh                            every enrolled cluster
#   ./scripts/bootstrap.sh --cluster mgmt-cluster
#   ./scripts/bootstrap.sh --cluster heal-k3d-dev
#
# Only mgmt-cluster is created here. A workload cluster is created by CAPI
# because capi/clusters/ says it exists, so naming one means "wait for Git to
# deliver it, and report where it stopped". Enrolling a cluster is a commit,
# not a flag.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MGMT_K3D_CLUSTER=dropp-mgmt
MGMT_CONTEXT="k3d-${MGMT_K3D_CLUSTER}"
CAPI_NAMESPACE=default
KUBECONFIG_DIR="${HOME}/.kube"

: "${CLUSTER_TIMEOUT:=900}"
: "${FLUX_TIMEOUT:=900}"

TARGETS_RAW=all
SKIP_FLUX_WAIT=false

usage() {
  cat <<'USAGE'
Bring clusters up.

  ./scripts/bootstrap.sh                            every enrolled cluster
  ./scripts/bootstrap.sh --cluster mgmt-cluster
  ./scripts/bootstrap.sh --cluster heal-k3d-dev,heal-k3d-prod

Options:
  --cluster <a,b,...>   Default: all. Valid: all, mgmt-cluster, and any
                        cluster under capi/clusters/local/.
  --no-wait             Create the management cluster and stop.
  -h, --help            This text.

Environment:
  SOPS_GPG_KEY_FILE     Armoured management private key.
                        Default: ~/.dropp-heal/mgmt.asc
  CLUSTER_TIMEOUT       Seconds to wait for a CAPI cluster. Default: 900.
  FLUX_TIMEOUT          Seconds to wait for that cluster's Flux. Default: 900.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) TARGETS_RAW="${2:?--cluster needs a value}"; shift 2 ;;
    --cluster=*) TARGETS_RAW="${1#*=}"; shift ;;
    --no-wait) SKIP_FLUX_WAIT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { printf '\n==> %s\n' "$*"; }
step() { printf '    %s\n' "$*"; }
die()  { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }

known_clusters() {
  find "${REPO_ROOT}/capi/clusters/local" -mindepth 1 -maxdepth 1 -type d \
    -printf '%f\n' 2>/dev/null | sort
}

# Ask kustomize what it emits rather than grepping for the name; a grep cannot
# tell a listed entry from one sitting behind a #.
enrolled_clusters() {
  kubectl kustomize "${REPO_ROOT}/capi/clusters" 2>/dev/null |
    awk '
      /^kind: Cluster$/   { kind = 1; next }
      /^---/              { kind = 0 }
      kind && /^  name: / { print $2; kind = 0 }
    ' | sort -u
}

is_enrolled() { enrolled_clusters | grep -qx "$1"; }

has_bootstrap_kustomization() {
  kubectl kustomize "${REPO_ROOT}/capi/mgmt-cluster/flux" 2>/dev/null |
    grep -q "name: $1-cluster-bootstrap"
}

mapfile -t KNOWN < <(known_clusters)

TARGETS=()
add_target() {
  for existing in ${TARGETS[@]+"${TARGETS[@]}"}; do
    [ "${existing}" = "$1" ] && return 0
  done
  TARGETS+=("$1")
}

IFS=',' read -r -a REQUESTED <<< "${TARGETS_RAW}"
for raw in "${REQUESTED[@]}"; do
  target="$(printf '%s' "${raw}" | tr -d '[:space:]')"
  [ -n "${target}" ] || continue
  case "${target}" in
    all)
      add_target mgmt-cluster
      while read -r c; do [ -n "${c}" ] && add_target "${c}"; done < <(enrolled_clusters)
      ;;
    mgmt-cluster|mgmt) add_target mgmt-cluster ;;
    *)
      printf '%s\n' "${KNOWN[@]}" | grep -qx "${target}" \
        || die "unknown cluster '${target}'; known: mgmt-cluster $(printf '%s ' "${KNOWN[@]}")"
      add_target "${target}"
      ;;
  esac
done

[ ${#TARGETS[@]} -gt 0 ] || die "nothing to do"

WANT_MGMT=false
WORKLOAD_TARGETS=()
for t in "${TARGETS[@]}"; do
  if [ "${t}" = mgmt-cluster ]; then WANT_MGMT=true; else WORKLOAD_TARGETS+=("${t}"); fi
done

# The management cluster runs the controllers that build the others.
if [ ${#WORKLOAD_TARGETS[@]} -gt 0 ] && ! k3d cluster list "${MGMT_K3D_CLUSTER}" >/dev/null 2>&1; then
  step "management cluster is absent; bringing it up first"
  WANT_MGMT=true
fi

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed; try: just prepare"; }
need docker; need kubectl
${WANT_MGMT} && { need k3d; need clusterctl; need flux; }

docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"

: "${SOPS_GPG_KEY_FILE:=${HOME}/.dropp-heal/mgmt.asc}"
if ${WANT_MGMT} && [ ! -f "${SOPS_GPG_KEY_FILE}" ]; then
  die "no management GPG key at ${SOPS_GPG_KEY_FILE}
     Every .sops.yaml here resolves to the management key, so without it Flux
     installs and then fails to decrypt anything. See README.md."
fi
export SOPS_GPG_KEY_FILE

log "bootstrapping: ${TARGETS[*]}"

if ${WANT_MGMT}; then
  log "management cluster"

  step "k3d cluster (1/3)"
  "${REPO_ROOT}/capi/mgmt-cluster/bootstrap/install-k3d-mgmt-cluster.sh"

  step "CAPI providers (2/3)"
  "${REPO_ROOT}/capi/mgmt-cluster/capi/install-capi.sh"

  step "Flux (3/3)"
  "${REPO_ROOT}/capi/mgmt-cluster/flux/install-flux.sh"

  # Until the deploy key is registered nothing downstream can move, so fail
  # here rather than on a timeout further down.
  if ! kubectl --context "${MGMT_CONTEXT}" -n flux-system \
        wait --for=condition=Ready --timeout=120s gitrepository/flux-system >/dev/null 2>&1; then
    cat >&2 <<EOF

    The flux-system GitRepository is not Ready.

    On a first bootstrap, register the public key printed above as a read-only
    deploy key on https://github.com/dropporg/dropp-infra/settings/keys, then
    re-run this script.

    Otherwise:  flux --context ${MGMT_CONTEXT} get sources git -A
EOF
    exit 1
  fi
  step "Git source Ready"
fi

[ ${#WORKLOAD_TARGETS[@]} -gt 0 ] || { log "done"; exit 0; }

if ${SKIP_FLUX_WAIT}; then
  log "--no-wait: leaving ${WORKLOAD_TARGETS[*]} to Flux"
  step "watch: flux --context ${MGMT_CONTEXT} get kustomizations -A"
  exit 0
fi

# Flux reconciles GitHub, not the working tree.
warn_if_unpushed() {
  local files="capi/clusters/local/kustomization.yaml capi/mgmt-cluster/flux/kustomization.yaml"
  local dirty upstream ahead
  dirty="$(git -C "${REPO_ROOT}" status --porcelain -- ${files} 2>/dev/null || true)"
  upstream="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  ahead=""
  [ -n "${upstream}" ] && ahead="$(git -C "${REPO_ROOT}" log --oneline "${upstream}..HEAD" -- ${files} 2>/dev/null || true)"
  if [ -n "${dirty}" ] || [ -n "${ahead}" ]; then
    echo >&2
    echo "    Warning: the enrollment files have uncommitted or unpushed changes." >&2
    echo "    What is waited on below is what the remote says." >&2
  fi
}
warn_if_unpushed

wait_for_cluster() {
  local cluster="$1"

  is_enrolled "${cluster}" || die "${cluster} is declared but not enrolled.
     capi/clusters/local/kustomization.yaml does not list it, so Flux will never
     create it. Uncomment it there and in capi/mgmt-cluster/flux/kustomization.yaml."

  # Enrolled in capi/clusters/ but with no bootstrap Kustomization means CAPI
  # builds the nodes and nothing is ever installed on them.
  has_bootstrap_kustomization "${cluster}" || {
    echo >&2
    echo "    Warning: ${cluster} has no bootstrap Kustomization in" >&2
    echo "    capi/mgmt-cluster/flux/kustomization.yaml; it will come up empty." >&2
  }

  log "${cluster}"

  step "reconciling the management cluster's Git source"
  flux --context "${MGMT_CONTEXT}" reconcile source git flux-system >/dev/null 2>&1 || true
  flux --context "${MGMT_CONTEXT}" -n flux-system reconcile kustomization capi-clusters >/dev/null 2>&1 || true

  step "waiting for the Cluster object to appear"
  local deadline=$(( SECONDS + CLUSTER_TIMEOUT ))
  until kubectl --context "${MGMT_CONTEXT}" -n "${CAPI_NAMESPACE}" \
          get cluster "${cluster}" >/dev/null 2>&1; do
    [ ${SECONDS} -lt ${deadline} ] || die "${cluster} never appeared; Flux has not applied it.
       flux --context ${MGMT_CONTEXT} get kustomizations -A"
    sleep 5
  done

  # Polled, not `kubectl wait`: CAPI v1beta2 reports Available and
  # ControlPlaneAvailable, v1beta1 reported ControlPlaneReady, and `kubectl
  # wait` on a condition that does not exist blocks until the timeout instead
  # of failing.
  step "waiting for the control plane (up to ${CLUSTER_TIMEOUT}s)"
  deadline=$(( SECONDS + CLUSTER_TIMEOUT ))
  until kubectl --context "${MGMT_CONTEXT}" -n "${CAPI_NAMESPACE}" get cluster "${cluster}" \
          -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{"\n"}{end}' 2>/dev/null |
        grep -qxE 'Available|ControlPlaneAvailable|ControlPlaneReady'; do
    [ ${SECONDS} -lt ${deadline} ] || die "${cluster}'s control plane did not become ready.
     Nodes NotReady with 'cni plugin not initialized' means Calico was never
     delivered; check the management node is on the kind network:
       docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}'"
    sleep 10
  done

  step "writing ${KUBECONFIG_DIR}/${cluster}.kubeconfig"
  mkdir -p "${KUBECONFIG_DIR}"
  clusterctl --kubeconfig-context "${MGMT_CONTEXT}" \
    get kubeconfig "${cluster}" -n "${CAPI_NAMESPACE}" \
    > "${KUBECONFIG_DIR}/${cluster}.kubeconfig"
  chmod 600 "${KUBECONFIG_DIR}/${cluster}.kubeconfig"

  local kc="${KUBECONFIG_DIR}/${cluster}.kubeconfig"

  step "waiting for nodes to go Ready"
  kubectl --kubeconfig "${kc}" wait --for=condition=Ready node --all --timeout=300s ||
    die "${cluster}'s nodes did not go Ready; the CNI is the usual cause"

  step "waiting for this cluster's own Flux"
  local fdeadline=$(( SECONDS + FLUX_TIMEOUT ))
  until kubectl --kubeconfig "${kc}" -n flux-system \
          get deploy kustomize-controller >/dev/null 2>&1; do
    [ ${SECONDS} -lt ${fdeadline} ] || die "Flux was never installed into ${cluster}.
       flux --context ${MGMT_CONTEXT} -n default get kustomizations"
    sleep 10
  done

  # --all is re-evaluated per attempt, so a Kustomization that appears halfway
  # through is still waited on.
  step "waiting for the platform and the application (up to ${FLUX_TIMEOUT}s)"
  if ! kubectl --kubeconfig "${kc}" wait --for=condition=Ready \
        --timeout="${FLUX_TIMEOUT}s" kustomization --all -A 2>/dev/null; then
    cat >&2 <<EOF

    ${cluster} is up but not everything converged.

      KUBECONFIG=${kc} flux get kustomizations -A
      KUBECONFIG=${kc} flux get helmreleases -A
EOF
    return 1
  fi

  step "${cluster} ready"
  printf '    use it with: export KUBECONFIG=%s\n' "${kc}"
}

FAILED=()
for cluster in "${WORKLOAD_TARGETS[@]}"; do
  wait_for_cluster "${cluster}" || FAILED+=("${cluster}")
done

if [ ${#FAILED[@]} -gt 0 ]; then
  log "did not fully converge: ${FAILED[*]}"
  exit 1
fi

log "done: ${TARGETS[*]}"
