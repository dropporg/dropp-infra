# Dropp org. Platform Infra

Cluster infrastructure for the Dropp platform: Cluster API definitions for the
`heal` clusters, and each cluster's own Flux configuration.

Everything here is GitOps except the three commands that create the thing which
reads Git. After those, no `kubectl apply` is part of any workflow.

## The chain

```
you ──► install-k3d-mgmt-cluster.sh   k3d, one node
        install-capi.sh               CAPI controllers (CAPD + cluster-api-k3s)
        install-flux.sh               Flux + this repo's deploy key + SOPS key
        ───────────────────────────── last imperative step
Git ──► capi/clusters/                CAPI creates heal-k3d-dev's containers
        capi/addons/                  ClusterResourceSet delivers Calico
        capi/mgmt-cluster/flux/       a Kustomization reaches *into* the new
                                      cluster over its CAPI kubeconfig and
                                      installs Flux there
        capi/workload-clusters/       that Flux reconciles cert-manager,
                                      Envoy Gateway, and the heal namespace
        dropp-heal-gitops             and hands the application to its own repo
```

The step worth noticing is the fourth. A workload cluster is never bootstrapped
by hand: `capi/mgmt-cluster/flux/heal-dev-cluster-bootstrap-kustomization.yaml`
is an ordinary Flux `Kustomization` with a `kubeConfig.secretRef` pointing at
the Secret that CAPI generates for every cluster it creates. The management
cluster's Flux therefore installs the workload cluster's Flux. Creating a
cluster and giving it a source of truth are both `git push`.

## Layout

```
capi/
├── clusterctl.yaml                 provider selection; needed by --config
├── mgmt-cluster/
│   ├── bootstrap/                  the k3d cluster that runs CAPI itself
│   ├── capi/                       clusterctl init
│   └── flux/                       Flux on the management cluster, and the
│                                   Kustomizations it reconciles
├── clusters/
│   ├── local/heal-k3d-dev/         1 control plane, 2 workers
│   ├── local/heal-k3d-prod/        3 control planes, 3 workers (not enrolled)
│   ├── ac-bmd-1/, aws-vg-1/        placeholders for non-local infrastructure
│   └── kustomization.yaml
├── addons/
│   ├── calico/                     the vendored CNI manifest, shared
│   └── heal-k3d-*/calico/          one ClusterResourceSet per cluster
└── workload-clusters/heal-k3d-*/
    ├── flux-system/                Flux + bootstrap secrets for that cluster
    ├── platform/                   cert-manager, Envoy Gateway, issuers, Gateway
    └── heal/                       the namespace, and the pointer to
                                    dropp-heal-gitops
```

## Bring-up

```bash
capi/mgmt-cluster/bootstrap/install-k3d-mgmt-cluster.sh
capi/mgmt-cluster/capi/install-capi.sh
capi/mgmt-cluster/flux/install-flux.sh
```

The third script prints a public key. Register it as a read-only deploy key on
this repository before Flux can reconcile anything.

Then watch it build itself:

```bash
flux get kustomizations -A
kubectl get clusters -A
clusterctl get kubeconfig heal-k3d-dev > ~/.kube/heal-k3d-dev.kubeconfig
KUBECONFIG=~/.kube/heal-k3d-dev.kubeconfig flux get kustomizations -A
```

## Why CAPD and cluster-api-k3s

There is no Cluster API infrastructure provider for k3d. CAPD creates each node
as a container on the host Docker daemon — the same substrate k3d uses — and
cluster-api-k3s bootstraps k3s on those nodes instead of kubeadm. The
management cluster is plain k3d because something has to run the CAPI
controllers before CAPI can create anything.

## Calico, and why the CNI is not flannel

k3s ships flannel enabled. Handing networking to Calico means turning that off,
and cluster-api-k3s v0.4.0 exposes no field for `--flannel-backend`:
`disableComponents` covers traefik and servicelb, not the CNI. k3s merges every
file in `/etc/rancher/k3s/config.yaml.d` before it starts, so the setting is
written there through `kthreesConfigSpec.files`.

`disable-network-policy` goes with it. Leaving k3s's built-in policy controller
running alongside Calico gives two controllers writing the same iptables
chains.

Calico itself arrives as a `ClusterResourceSet`, which reads manifests from a
ConfigMap in the Cluster's namespace and cannot fetch a URL — hence the
vendored `capi/addons/calico/calico.yaml`. Vendoring also pins what is applied,
where an upstream URL would let the CNI change under a cluster nobody touched.

## Secrets

Three keys, and the split matters:

| Key | Encrypts | Lives on |
| --- | --- | --- |
| management | everything in this repository | management cluster |
| `heal-k3d-dev` | application secrets in dropp-heal-gitops | heal-k3d-dev |
| `heal-k3d-prod` | the same, for prod | heal-k3d-prod |

Every `.sops.yaml` here resolves to the management key, including the files
under `capi/workload-clusters/`, because it is the management cluster's Flux
that decrypts them and applies them into the workload cluster. A workload
cluster never holds the management key, and its own key cannot read another
cluster's secrets.

`sops` finds its configuration by walking up from the current directory, not
from the file being edited, so encrypt with an explicit config:

```bash
sops --config capi/workload-clusters/heal-k3d-dev/.sops.yaml \
     -e -i capi/workload-clusters/heal-k3d-dev/flux-system/<file>.sops.yaml
```

Three things cannot come from Git, because they are what makes reading Git
possible: the Flux controllers, the deploy key that reads this repository, and
the GPG key that decrypts everything else. `install-flux.sh` creates those and
nothing more.

## heal-k3d-prod

Declared in full, deliberately not enrolled. It is 3 control planes and 3
workers — seven containers on top of the management cluster and heal-k3d-dev —
which does not fit on an 8 GB workstation. Enrolling it is two uncommented
lines, in `capi/clusters/local/kustomization.yaml` and
`capi/mgmt-cluster/flux/kustomization.yaml`, plus registering its deploy keys.

## Gateway hostnames

The Gateway listener is `*.heal.local`. Gateway API wildcards match exactly one
label and never the apex: `*.heal.local` matches `heal-dev.heal.local` but not
`heal.local`, and `*.dev.heal.local` would match neither. A route whose
hostname falls outside the listener pattern attaches silently and never serves,
with no error anywhere — compare the two before debugging further.
