# Recipes:
#
# bootstrap <clusters> -> clusters is comma separated opts: all (default), mgmt-cluster, heal-k3d-dev, heal-k3d-prod
#
# teardown <clusters:> <prune:bool>
#
# prepare -> Install requirements on ubuntu, fedora, or nixos like flux, kubectl, capi, clusterapi, sops, opengpg, and so on
#
# install-k3d-mgmt-cluster -> dropp-infra/capi/mgmt-cluster/bootstrap/install-k3d-mgmt-cluster.sh
#
# install-capi -> dropp-infra/capi/mgmt-cluster/capi/install-capi.sh
#
# install-flux -> dropp-infra/capi/mgmt-cluster/flux/install-flux.sh
#
# generate-kubeconfig <cluster:string> <user:string> <namespace:string>
#
# and so on

set shell := ["bash", "-euo", "pipefail", "-c"]

mgmt_context := "k3d-dropp-mgmt"
mgmt_cluster := "dropp-mgmt"
capi_namespace := "default"
kubeconfig_dir := env_var('HOME') / ".kube"
scripts := justfile_directory() / "scripts"
capi := justfile_directory() / "capi"

# List available recipes.
default:
    @just --list

# Bring clusters up. Naming a workload cluster waits for Git to deliver it.
bootstrap clusters="all" *args:
    {{scripts}}/bootstrap.sh --cluster {{clusters}} {{args}}

# Create the management cluster and stop, leaving the rest to Flux.
bootstrap-mgmt:
    {{scripts}}/bootstrap.sh --cluster mgmt-cluster

# Tear clusters down. prune=true also removes their disks and volumes.
teardown clusters="all" prune="false" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    flags=()
    case "{{prune}}" in
      true|yes|1) flags+=(--prune) ;;
      false|no|0|"") ;;
      *) echo "prune must be true or false, got '{{prune}}'" >&2; exit 2 ;;
    esac
    {{scripts}}/teardown.sh --cluster {{clusters}} "${flags[@]}" {{args}}

# Tear everything down with its storage, then bring it back. Local only.
rebuild:
    just teardown all true --yes
    just bootstrap all

# Step 1 of 3: the k3d cluster that hosts the CAPI controllers.
install-k3d-mgmt-cluster:
    {{capi}}/mgmt-cluster/bootstrap/install-k3d-mgmt-cluster.sh

# Step 2 of 3: the CAPI controllers (CAPD + cluster-api-k3s).
install-capi:
    {{capi}}/mgmt-cluster/capi/install-capi.sh

# Step 3 of 3: Flux, this repo's deploy key, and the SOPS key.
install-flux:
    {{capi}}/mgmt-cluster/flux/install-flux.sh

# Render every kustomization in this repo. Run before pushing.
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    rc=0
    while read -r dir; do
      if kubectl kustomize "${dir}" >/dev/null; then
        printf '  ok   %s\n' "${dir#{{justfile_directory()}}/}"
      else
        printf '  FAIL %s\n' "${dir#{{justfile_directory()}}/}"; rc=1
      fi
    done < <(find {{capi}} -name kustomization.yaml -printf '%h\n' | sort)
    exit ${rc}

# Render one kustomization to stdout, to see what Flux will apply.
render path:
    kubectl kustomize {{path}}

# What the management cluster would create for a cluster, before enrolling it.
diff cluster:
    kubectl --context {{mgmt_context}} diff -k {{capi}}/clusters/local/{{cluster}}

# Everything Flux is reconciling, on the management cluster and each workload.
status:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "== mgmt-cluster =="
    kubectl --context {{mgmt_context}} get clusters -A 2>/dev/null || echo "  unreachable"
    flux --context {{mgmt_context}} get kustomizations -A 2>/dev/null || true
    while read -r cluster; do
      [ -n "${cluster}" ] || continue
      kc="{{kubeconfig_dir}}/${cluster}.kubeconfig"
      [ -f "${kc}" ] || continue
      echo
      echo "== ${cluster} =="
      KUBECONFIG="${kc}" flux get kustomizations -A 2>/dev/null || echo "  unreachable"
      KUBECONFIG="${kc}" flux get helmreleases -A 2>/dev/null || true
    done < <(kubectl --context {{mgmt_context}} -n {{capi_namespace}} get clusters -o name 2>/dev/null | cut -d/ -f2)

# Write a workload cluster's admin kubeconfig to ~/.kube/<cluster>.kubeconfig.
kubeconfig cluster:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{kubeconfig_dir}}
    out="{{kubeconfig_dir}}/{{cluster}}.kubeconfig"
    clusterctl --kubeconfig-context {{mgmt_context}} \
      get kubeconfig {{cluster}} -n {{capi_namespace}} > "${out}"
    chmod 600 "${out}"
    echo "export KUBECONFIG=${out}"

# Does not create the ServiceAccount or grant it anything: who may do what on a
# cluster is desired state and belongs in Git. This only exchanges an existing
# identity for a credential.

# Mint a kubeconfig for a ServiceAccount that already exists on a cluster.
generate-kubeconfig cluster user namespace="default" ttl="24h":
    #!/usr/bin/env bash
    set -euo pipefail
    admin="{{kubeconfig_dir}}/{{cluster}}.kubeconfig"
    [ -f "${admin}" ] || { echo "no ${admin}; run: just kubeconfig {{cluster}}" >&2; exit 1; }

    kubectl --kubeconfig "${admin}" -n {{namespace}} get serviceaccount {{user}} >/dev/null || {
      echo "serviceaccount {{user}} does not exist in namespace {{namespace}} on {{cluster}}." >&2
      echo "Declare it and its RoleBinding in Git and let Flux create it." >&2
      exit 1
    }

    server="$(kubectl --kubeconfig "${admin}" config view --minify --raw \
                -o jsonpath='{.clusters[0].cluster.server}')"
    ca="$(kubectl --kubeconfig "${admin}" config view --minify --raw --flatten \
                -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    token="$(kubectl --kubeconfig "${admin}" -n {{namespace}} \
                create token {{user}} --duration={{ttl}})"

    cat <<EOF
    apiVersion: v1
    kind: Config
    clusters:
      - name: {{cluster}}
        cluster:
          server: ${server}
          certificate-authority-data: ${ca}
    users:
      - name: {{user}}
        user:
          token: ${token}
    contexts:
      - name: {{user}}@{{cluster}}
        context:
          cluster: {{cluster}}
          user: {{user}}
          namespace: {{namespace}}
    current-context: {{user}}@{{cluster}}
    EOF

# Pull the latest commit now instead of waiting out the reconcile interval.
reconcile cluster="mgmt-cluster":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{cluster}}" = mgmt-cluster ]; then
      flux --context {{mgmt_context}} reconcile source git flux-system --with-source
    else
      export KUBECONFIG="{{kubeconfig_dir}}/{{cluster}}.kubeconfig"
      flux reconcile source git flux-system --with-source
      flux reconcile source git heal-gitops -n flux-system --with-source 2>/dev/null || true
    fi

# Follow a cluster's Flux logs. The first place to look when nothing moves.
logs cluster="mgmt-cluster":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{cluster}}" = mgmt-cluster ]; then
      flux --context {{mgmt_context}} logs --all-namespaces --follow --tail=50
    else
      KUBECONFIG="{{kubeconfig_dir}}/{{cluster}}.kubeconfig" \
        flux logs --all-namespaces --follow --tail=50
    fi

# sops resolves .sops.yaml from the working directory, not from the file being
# edited, so these pass --config explicitly.

# Encrypt a file in place with the config that governs its directory.
encrypt file:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="$(cd "$(dirname "{{file}}")" && pwd)"
    config=""
    while [ "${dir}" != "/" ]; do
      [ -f "${dir}/.sops.yaml" ] && { config="${dir}/.sops.yaml"; break; }
      dir="$(dirname "${dir}")"
    done
    [ -n "${config}" ] || { echo "no .sops.yaml governs {{file}}" >&2; exit 1; }
    echo "using ${config}"
    sops --config "${config}" -e -i "{{file}}"

# Decrypt a file to stdout. Never writes plaintext to disk.
decrypt file:
    sops -d "{{file}}"

# Open a file in $EDITOR, decrypted, re-encrypting on save.
edit-secret file:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="$(cd "$(dirname "{{file}}")" && pwd)"
    config=""
    while [ "${dir}" != "/" ]; do
      [ -f "${dir}/.sops.yaml" ] && { config="${dir}/.sops.yaml"; break; }
      dir="$(dirname "${dir}")"
    done
    [ -n "${config}" ] || { echo "no .sops.yaml governs {{file}}" >&2; exit 1; }
    sops --config "${config}" "{{file}}"

# Fail if a *.sops.yaml file was left in plaintext. Worth a pre-push hook.
check-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    rc=0
    while read -r f; do
      if ! grep -q '^sops:' "${f}"; then
        printf '  PLAINTEXT %s\n' "${f#{{justfile_directory()}}/}"; rc=1
      else
        printf '  encrypted %s\n' "${f#{{justfile_directory()}}/}"
      fi
    # .sops.yaml is the config that names the key, not a payload.
    done < <(find {{justfile_directory()}} -name '*.sops.yaml' -not -name '.sops.yaml' \
               -not -path '*/.git/*' | sort)
    exit ${rc}

# Install the toolchain: docker, kubectl, k3d, clusterctl, flux, helm, sops, gnupg.
prepare:
    #!/usr/bin/env bash
    set -euo pipefail

    # Pinned: an unpinned clusterctl init against a provider that moved is how
    # a cluster that built yesterday stops building today.
    KUBECTL_VERSION=v1.31.6
    K3D_VERSION=v5.8.3
    CLUSTERCTL_VERSION=v1.14.0
    FLUX_VERSION=2.8.8
    HELM_VERSION=v3.16.4
    SOPS_VERSION=v3.9.4

    ID=unknown
    [ -r /etc/os-release ] && . /etc/os-release && ID="${ID:-unknown}"

    have() { command -v "$1" >/dev/null 2>&1; }
    bindir="${HOME}/.local/bin"; mkdir -p "${bindir}"
    case ":${PATH}:" in *":${bindir}:"*) ;; *) echo "note: ${bindir} is not on PATH" ;; esac

    case "${ID}" in
      nixos)
        # A binary in ~/.local/bin would be linked against an FHS that is not
        # there.
        cat <<'EOF'
    NixOS: add these to your configuration, or get a shell with them now:

      nix-shell -p kubectl kubernetes-helm k3d clusterctl fluxcd sops gnupg just docker

    Docker needs `virtualisation.docker.enable = true;` and your user in the
    "docker" group.
    EOF
        exit 0
        ;;
      ubuntu|debian|pop|linuxmint)
        sudo apt-get update -qq
        sudo apt-get install -y curl ca-certificates gnupg git make
        have docker || echo "note: install docker separately: https://docs.docker.com/engine/install/"
        ;;
      fedora|rhel|centos|rocky|almalinux)
        sudo dnf install -y curl ca-certificates gnupg2 git make
        have docker || echo "note: install docker separately: https://docs.docker.com/engine/install/"
        ;;
      *)
        echo "unrecognised distribution '${ID}'; installing the binaries only"
        ;;
    esac

    arch="$(uname -m)"
    case "${arch}" in
      x86_64) arch=amd64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) echo "unsupported architecture ${arch}" >&2; exit 1 ;;
    esac

    fetch() { curl -fsSL "$1" -o "$2"; }

    have kubectl || {
      echo "==> kubectl ${KUBECTL_VERSION}"
      fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" "${bindir}/kubectl"
      chmod +x "${bindir}/kubectl"
    }
    have k3d || {
      echo "==> k3d ${K3D_VERSION}"
      curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh |
        TAG="${K3D_VERSION}" K3D_INSTALL_DIR="${bindir}" USE_SUDO=false bash
    }
    have clusterctl || {
      echo "==> clusterctl ${CLUSTERCTL_VERSION}"
      fetch "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-linux-${arch}" "${bindir}/clusterctl"
      chmod +x "${bindir}/clusterctl"
    }
    have flux || {
      echo "==> flux ${FLUX_VERSION}"
      curl -fsSL https://fluxcd.io/install.sh |
        FLUX_VERSION="${FLUX_VERSION}" bash -s "${bindir}"
    }
    have helm || {
      echo "==> helm ${HELM_VERSION}"
      tmp="$(mktemp -d)"
      fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" "${tmp}/helm.tgz"
      tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
      install -m 0755 "${tmp}/linux-${arch}/helm" "${bindir}/helm"
      rm -rf "${tmp}"
    }
    have sops || {
      echo "==> sops ${SOPS_VERSION}"
      fetch "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${arch}" "${bindir}/sops"
      chmod +x "${bindir}/sops"
    }

    echo
    just doctor

# Report what is installed and whether the clusters are reachable.
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    for t in docker kubectl k3d clusterctl flux helm sops gpg git just; do
      if command -v "${t}" >/dev/null 2>&1; then
        printf '  %-11s %s\n' "${t}" "$(command -v "${t}")"
      else
        printf '  %-11s MISSING\n' "${t}"
      fi
    done
    echo
    if docker info >/dev/null 2>&1; then echo "  docker daemon   reachable"
    else echo "  docker daemon   UNREACHABLE"; fi
    if kubectl --context {{mgmt_context}} --request-timeout=5s get --raw /readyz >/dev/null 2>&1
      then echo "  mgmt-cluster    reachable"
    else echo "  mgmt-cluster    absent (just bootstrap-mgmt)"; fi
    key="${SOPS_GPG_KEY_FILE:-${HOME}/.dropp-heal/mgmt.asc}"
    if [ -f "${key}" ]; then echo "  sops key        ${key}"
    else echo "  sops key        MISSING at ${key}"; fi
