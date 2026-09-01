#!/usr/bin/env bash
# Teardown based on clusters follow the following
#
# ./teardown -> teardown all the clusters and remove all the disks and volumes
# ./teardown --cluster <CLUSTER_NAME> (default is all) opts: clusters in this project like mgmt-cluster, heal-k3d-dev, heal-k3d-prod
# ./teardown --prune -> remove with volumes and storage of clusters.
#
# Example: ./teadown --cluster mgmt-cluster --prune -> remove mgmt-cluster with all of its storage and volumes.
#
# Deleting a workload cluster means suspending the Kustomization that declares
# it first, otherwise Flux recreates it. The suspension is left in place;
# resuming it is how a teardown is undone.
#
# The management cluster goes last: CAPD is what removes workload node
# containers, so removing it first orphans them.
#
# --prune removes each node's anonymous /var volume and the k3d image cache. It
# never touches the heal_* and dropp-heal-backend_* compose volumes, which are
# dropp-heal's local dev data.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MGMT_K3D_CLUSTER=dropp-mgmt
MGMT_CONTEXT="k3d-${MGMT_K3D_CLUSTER}"
CAPI_NAMESPACE=default
KUBECONFIG_DIR="${HOME}/.kube"
CAPD_LABEL=io.x-k8s.kind.cluster

TARGETS_RAW=all
PRUNE=false
ASSUME_YES=false
: "${DELETE_TIMEOUT:=600}"

usage() {
  cat <<'USAGE'
Tear clusters down.

  ./scripts/teardown.sh                                  everything
  ./scripts/teardown.sh --cluster heal-k3d-dev           one workload cluster
  ./scripts/teardown.sh --cluster mgmt-cluster --prune   with its storage
  ./scripts/teardown.sh --cluster heal-k3d-dev,heal-k3d-prod

Options:
  --cluster <a,b,...>   Comma-separated targets. Default: all.
                        Valid: all, mgmt-cluster, and any cluster under
                        capi/clusters/local/.
  --prune               Also remove each cluster's volumes and storage, its
                        generated kubeconfig, and the kind network once it is
                        empty. Never touches the dropp-heal compose volumes.
  -y, --yes             Do not ask.
  -h, --help            This text.

Environment:
  DELETE_TIMEOUT        Seconds to wait for CAPI to finish deleting a cluster
                        before falling back to removing containers. Default: 600.

Undo: the Kustomization that declares the workload clusters is left suspended.
      flux --context k3d-dropp-mgmt -n flux-system resume kustomization capi-clusters
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) TARGETS_RAW="${2:?--cluster needs a value}"; shift 2 ;;
    --cluster=*) TARGETS_RAW="${1#*=}"; shift ;;
    --prune) PRUNE=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { printf '\n==> %s\n' "$*"; }
step() { printf '    %s\n' "$*"; }
die()  { printf 'teardown: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"

known_clusters() {
  find "${REPO_ROOT}/capi/clusters/local" -mindepth 1 -maxdepth 1 -type d \
    -printf '%f\n' 2>/dev/null | sort
}

# "all" is what exists on this host, not what Git declares: a cluster built
# from a branch nobody has checked out still has containers.
live_capd_clusters() {
  docker ps -a --filter "label=${CAPD_LABEL}" \
    --format "{{.Label \"${CAPD_LABEL}\"}}" | sort -u
}

mgmt_reachable() {
  kubectl --context "${MGMT_CONTEXT}" --request-timeout=10s \
    get --raw /readyz >/dev/null 2>&1
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
      while read -r c; do [ -n "${c}" ] && add_target "${c}"; done < <(live_capd_clusters)
      add_target mgmt-cluster
      ;;
    mgmt-cluster|mgmt) add_target mgmt-cluster ;;
    *)
      if ! printf '%s\n' "${KNOWN[@]}" | grep -qx "${target}" &&
         ! live_capd_clusters | grep -qx "${target}"; then
        die "unknown cluster '${target}'; known: mgmt-cluster $(printf '%s ' "${KNOWN[@]}")"
      fi
      add_target "${target}"
      ;;
  esac
done

[ ${#TARGETS[@]} -gt 0 ] || { log "nothing to tear down"; exit 0; }

TEARDOWN_MGMT=false
WORKLOAD_TARGETS=()
for t in "${TARGETS[@]}"; do
  if [ "${t}" = mgmt-cluster ]; then TEARDOWN_MGMT=true; else WORKLOAD_TARGETS+=("${t}"); fi
done

# Removing the management cluster strands the workload clusters it manages.
if ${TEARDOWN_MGMT}; then
  while read -r c; do
    [ -n "${c}" ] || continue
    already=false
    for t in ${WORKLOAD_TARGETS[@]+"${WORKLOAD_TARGETS[@]}"}; do
      [ "${t}" = "${c}" ] && already=true
    done
    ${already} || {
      step "${c} is managed by the management cluster; including it"
      WORKLOAD_TARGETS+=("${c}")
    }
  done < <(live_capd_clusters)
fi

printf '\nAbout to tear down:\n'
for c in ${WORKLOAD_TARGETS[@]+"${WORKLOAD_TARGETS[@]}"}; do printf '  - %s\n' "${c}"; done
${TEARDOWN_MGMT} && printf '  - mgmt-cluster (k3d %s)\n' "${MGMT_K3D_CLUSTER}"
if ${PRUNE}; then
  printf '\n  --prune: node disks, the k3d image cache and the generated\n'
  printf '           kubeconfigs go too. The dropp-heal compose volumes stay.\n'
fi
if ! ${ASSUME_YES}; then
  if [ -t 0 ]; then
    read -r -p $'\nProceed? [y/N] ' reply
    case "${reply}" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
  else
    die "not a terminal and --yes was not given; refusing to guess"
  fi
fi

suspend_capi_clusters() {
  mgmt_reachable || return 0
  step "suspending capi-clusters so Flux stops recreating"
  flux --context "${MGMT_CONTEXT}" -n flux-system \
    suspend kustomization capi-clusters >/dev/null 2>&1 || true
  flux --context "${MGMT_CONTEXT}" -n flux-system \
    suspend kustomization capi-addons >/dev/null 2>&1 || true
}

# Cleans up what CAPI could not, either because the management cluster is gone
# or a Machine got stuck. A clean delete leaves nothing to match.
remove_capd_containers() {
  local cluster="$1" rm_flags=(-f)
  ${PRUNE} && rm_flags+=(-v)   # the anonymous /var volume is the node's disk

  mapfile -t containers < <(
    docker ps -a --filter "label=${CAPD_LABEL}=${cluster}" --format '{{.Names}}'
  )
  [ ${#containers[@]} -gt 0 ] || return 0

  step "removing ${#containers[@]} leftover container(s)"
  docker rm "${rm_flags[@]}" "${containers[@]}" >/dev/null
}

teardown_workload() {
  local cluster="$1"
  log "${cluster}"

  if mgmt_reachable && kubectl --context "${MGMT_CONTEXT}" -n "${CAPI_NAMESPACE}" \
       get cluster "${cluster}" >/dev/null 2>&1; then
    step "deleting the Cluster object (CAPI removes the containers)"
    if ! kubectl --context "${MGMT_CONTEXT}" -n "${CAPI_NAMESPACE}" \
           delete cluster "${cluster}" --wait --timeout="${DELETE_TIMEOUT}s"; then
      # A Machine whose container is already gone blocks on its finalizer
      # waiting for a node that will never answer.
      step "CAPI did not finish in ${DELETE_TIMEOUT}s; clearing finalizers"
      for kind in machines machinedeployments kthreescontrolplanes dockermachines dockerclusters clusters; do
        while read -r name; do
          [ -n "${name}" ] || continue
          kubectl --context "${MGMT_CONTEXT}" -n "${CAPI_NAMESPACE}" patch \
            "${kind}" "${name}" --type=merge -p '{"metadata":{"finalizers":null}}' \
            >/dev/null 2>&1 || true
        done < <(kubectl --context "${MGMT_CONTEXT}" -n "${CAPI_NAMESPACE}" get "${kind}" \
                   -l "cluster.x-k8s.io/cluster-name=${cluster}" \
                   -o name 2>/dev/null | cut -d/ -f2)
      done
      kubectl --context "${MGMT_CONTEXT}" -n "${CAPI_NAMESPACE}" \
        delete cluster "${cluster}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
  else
    step "no Cluster object to delete; removing containers directly"
  fi

  remove_capd_containers "${cluster}"

  if ${PRUNE}; then
    local kc="${KUBECONFIG_DIR}/${cluster}.kubeconfig"
    [ -f "${kc}" ] && { step "removing ${kc}"; rm -f "${kc}"; }
    kubectl config delete-context "${cluster}" >/dev/null 2>&1 || true
    kubectl config delete-cluster "${cluster}" >/dev/null 2>&1 || true
  fi

  step "${cluster} gone"
}

if [ ${#WORKLOAD_TARGETS[@]} -gt 0 ]; then
  suspend_capi_clusters
  for cluster in "${WORKLOAD_TARGETS[@]}"; do
    teardown_workload "${cluster}"
  done
fi

if ${TEARDOWN_MGMT}; then
  log "mgmt-cluster"
  if k3d cluster list "${MGMT_K3D_CLUSTER}" >/dev/null 2>&1; then
    step "k3d cluster delete ${MGMT_K3D_CLUSTER}"
    k3d cluster delete "${MGMT_K3D_CLUSTER}"
  else
    step "not present"
  fi

  if ${PRUNE}; then
    # k3d removes its volumes with the cluster; an interrupted delete does not.
    while read -r vol; do
      [ -n "${vol}" ] || continue
      step "removing volume ${vol}"
      docker volume rm "${vol}" >/dev/null 2>&1 || true
    done < <(docker volume ls -q --filter "name=k3d-${MGMT_K3D_CLUSTER}")

    rm -f "${KUBECONFIG_DIR}/${MGMT_K3D_CLUSTER}.kubeconfig"
  fi
  step "mgmt-cluster gone"
fi

# Shared, so it goes only when empty and only under --prune.
if ${PRUNE} && docker network inspect kind >/dev/null 2>&1; then
  remaining="$(docker network inspect kind --format '{{len .Containers}}')"
  if [ "${remaining}" = "0" ]; then
    log "removing the empty kind network"
    docker network rm kind >/dev/null 2>&1 || true
  else
    log "leaving the kind network: ${remaining} container(s) still attached"
  fi
fi

log "teardown complete"
if [ ${#WORKLOAD_TARGETS[@]} -gt 0 ] && ! ${TEARDOWN_MGMT}; then
  cat <<EOF

    capi-clusters is suspended, which is what keeps the clusters deleted:

      flux --context ${MGMT_CONTEXT} -n flux-system resume kustomization capi-clusters
      flux --context ${MGMT_CONTEXT} -n flux-system resume kustomization capi-addons
EOF
fi
