# local-path-provisioner: the default storage on both clusters

[local-path-provisioner](https://github.com/rancher/local-path-provisioner) (Rancher, Apache 2.0) gives each cluster a default StorageClass, `local-path`. Every PersistentVolumeClaim becomes a folder on the disk of the worker that runs the pod. It is installed with upstream's Helm chart and the values in this folder, identically on Homelab and EduCloud. Why this and not Longhorn or a hypervisor CSI driver: [ADR 0001](../../docs/adr/0001-in-cluster-storage.md).

| File | What it is |
|---|---|
| `namespace.yaml` | the `local-path-storage` namespace with Pod Security `privileged`, applied before the chart (the chart does not create or label its namespace) |
| `values.yaml` | the chart values; each setting has its reason next to it |
| `smoke-test.yaml` | a PVC and a pod that writes to it, to check an installation |

Versions: chart and app v0.0.37 (latest release, published 2026-08-05), helper image `busybox:1.38.0` (checked 2026-11-25).

## How it works

1. An app creates a PVC without a StorageClass, so it gets the default, `local-path`.
2. The class has `volumeBindingMode: WaitForFirstConsumer`: nothing happens until a pod that uses the PVC is scheduled. The scheduler picks a worker as for any pod.
3. The provisioner (one small pod in `local-path-storage`) sees the claim and starts a **helper pod** on that worker. The helper pod mounts `/opt/local-path-provisioner` from the node and runs the `setup` script: `mkdir -m 0777 -p <folder>`, where the folder is named `<pv-name>_<namespace>_<pvc-name>`.
4. The provisioner creates a PersistentVolume of type `local` that points at that folder, with a node affinity for that worker. The PVC becomes `Bound`.
5. The kubelet bind-mounts the folder into the pod and gives it to the pod's `fsGroup`.
6. From then on the PVC and every pod that uses it are **tied to that worker**. If the worker is down, the pod stays `Pending` until it returns. This is why databases run as two or more CloudNativePG instances on different workers: each has its own volume, and Postgres copies the data between them.
7. When the PVC is deleted (`reclaimPolicy: Delete`), a helper pod runs `teardown` (`rm -rf <folder>`) and the PV is removed.

Things to know:

- **The requested size is not enforced** (upstream: "No support for the volume capacity limit currently"). A volume can grow until the node's disk is full, and then the kubelet starts evicting pods from that node. The folders share the 40 GB root disk with the container images, so watch `df -h /opt` on the workers. A dedicated disk per worker is a later step (ADR 0001).
- **Draining a worker** cannot move its volumes: pods that use them stay `Pending` until the worker is back. For a CloudNativePG primary, switch it over to the other instance first.
- `ReadWriteOnce` only: every volume lives on one node.

## Install (once per cluster)

Needs Helm 3.8 or newer and a kubectl context for each cluster: `ansible/workstation.yml` installs Helm v4.3.2 and Homelab's context; EduCloud's kubeconfig comes from Rancher. Run from the repo root.

```bash
kubectx                           # lists the contexts: homelab and educloud (ansible/workstation.yml)
CTX=educloud                      # first EduCloud, then the same steps with CTX=homelab

# The chart is not published in a Helm repository: upstream installs it from a checkout of the release tag.
git clone --depth 1 --branch v0.0.37 https://github.com/rancher/local-path-provisioner.git /tmp/local-path-provisioner
CHART=/tmp/local-path-provisioner/deploy/chart/local-path-provisioner

kubectl --context "$CTX" apply -f platform/local-path/namespace.yaml

# --dry-run=server sends everything through the API server's checks (including Pod Security) without creating it
helm upgrade --install local-path-storage "$CHART" --kube-context "$CTX" \
  --namespace local-path-storage -f platform/local-path/values.yaml --dry-run=server
helm upgrade --install local-path-storage "$CHART" --kube-context "$CTX" \
  --namespace local-path-storage -f platform/local-path/values.yaml
```

## Check

```bash
kubectl --context "$CTX" -n local-path-storage get pods     # one pod, Running
kubectl --context "$CTX" get storageclass                   # local-path (default), and no other default

kubectl --context "$CTX" apply -f platform/local-path/smoke-test.yaml
kubectl --context "$CTX" get pvc local-path-smoke-test      # Bound once the pod is scheduled
kubectl --context "$CTX" logs local-path-smoke-test         # /data in group 1000 (fsGroup), then "written-by-1000"
kubectl --context "$CTX" get pv -o yaml | grep -A6 nodeAffinity   # the worker the volume lives on
# optional, on that worker: sudo ls -l /opt/local-path-provisioner
kubectl --context "$CTX" delete -f platform/local-path/smoke-test.yaml   # the folder on the worker is removed
```

If the provisioner pod is not created, `kubectl -n local-path-storage get events` shows why. A `violates PodSecurity` event means `namespace.yaml` was not applied before the chart. If the pod starts but crashes, check its logs: the non-root settings in `values.yaml` follow the chart's own suggestion but are new in this project, and removing `runAsUser`/`runAsGroup`/`runAsNonRoot` is the fallback.

## Upgrade and removal

- **Upgrade:** check out the new tag, compare its `values.yaml` with the old one (`git diff v0.0.37 <new tag> -- deploy/chart/`), update the versions and dates here and in `values.yaml`, then run the same `helm upgrade --install`. Existing volumes are not touched.
- **Removal:** delete every PVC of class `local-path` first (or their folders stay on the nodes), then `helm uninstall local-path-storage --kube-context "$CTX" -n local-path-storage`.

## Security notes

- The namespace is `privileged` because the helper pods mount a node folder. They only mount `/opt/local-path-provisioner`, and only the provisioner creates them.
- The provisioner pod itself meets `restricted`: non-root (UID 65534), read-only root filesystem, no capabilities, RuntimeDefault seccomp.
- Its ClusterRole may create and delete PersistentVolumes cluster-wide; that is what a provisioner needs.
- The `setup` script creates volume folders with mode `0777`; only root and the admin user log in to the nodes. Tightening this (`permPattern`) is a hardening item: it only works for pods that set an `fsGroup`.

## Later: GitOps

These files are already in the shape GitOps needs. With Argo CD it becomes one Application with two sources: upstream's repo at `deploy/chart/local-path-provisioner`, `targetRevision: v0.0.37`, and this repo for `values.yaml`, plus `managedNamespaceMetadata` for the Pod Security label. The manual commands above then go away.

## Sources

All checked 2026-11-25.

- local-path-provisioner: [README](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/README.md) · [chart values](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/deploy/chart/local-path-provisioner/values.yaml) · [releases](https://github.com/rancher/local-path-provisioner/releases) · [image Dockerfile](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/package/Dockerfile)
- Kubernetes: [Pod Security admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) · [local volumes](https://kubernetes.io/docs/concepts/storage/volumes/#local)
- Velero: [file system backup](https://velero.io/docs/main/file-system-backup/) ("hostPath volumes are not supported, but the local volume type is supported")
