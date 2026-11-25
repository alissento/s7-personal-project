# 0001. In-cluster storage: local-path-provisioner, replication by the applications

- Status: Accepted
- Date: 2026-11-25
- Related: [docs/ideas.md §7](../ideas.md#7-in-cluster-storage) (earlier proposal: Longhorn) · [platform/local-path/](../../platform/local-path/README.md) (the implementation) · DR design in [docs/ideas.md §6](../ideas.md)

## Context

Neither cluster has a StorageClass (EduCloud checked with `kubectl get storageclass` on 2026-11-25), so no PersistentVolumeClaim can be bound. The first app that needs one is Kaneo (project management, with PostgreSQL); after it come the banking app's databases and the platform's stateful parts.

What needs storage in the plan, and how each part survives the loss of a worker:

| Workload | Survives a worker loss through |
|---|---|
| PostgreSQL: the bank's account and ledger databases, Kaneo | CloudNativePG: two or more instances on different workers, streaming replication between them |
| OpenBao (secrets manager) | its integrated Raft storage, replicated by OpenBao itself |
| Prometheus, logs | can be rebuilt; history loss is acceptable |
| Argo CD, Kyverno, Istio, Tetragon, cert-manager, External Secrets | no volumes |

Constraints:

- **Small workers.** EduCloud: 2 workers with 2 vCPU, 6 GiB RAM and a 40 GB root disk each (`opentofu/educloud/instances.tf`); its 3 masters are tainted, so workloads only run on the workers (checked 2026-11-25). Homelab: 2 workers with about 6 GB RAM and a 40 GB disk; its vCPU count is not recorded in the repo yet. The banking app (Bank of Anthos) alone requests about 1.1 vCPU and 2.1 GiB (the requests in its `kubernetes-manifests/`, summed on 2026-11-25), and the security tools come on top. CPU is the first limit, not disk.
- **Pod Security "restricted"** everywhere (RKE2 CIS profile on both clusters). Any storage system needs privileged pods on the nodes; fewer of them means less attack surface for the lateral-movement tests (research question 3).
- **Disaster recovery happens at the database level** (research question 4): a CloudNativePG replica cluster at the other site, plus Velero for the rest. Storage must not get in the way of that, and Velero must be able to back its volumes up.
- **Both sites the same way.** One storage design for Homelab (Proxmox) and EduCloud (CloudStack).

## Options considered

### Option A — local-path-provisioner
Each PVC becomes a folder on the local disk of the worker that runs the pod (`local` volume with node affinity).
- Pros: almost no overhead (one small pod per cluster); no node preparation; identical on both sites; matches the shared-nothing model CloudNativePG recommends, where each instance has its own volume on its own node and Postgres does the replication; `local` volumes are supported by Velero's file system backup.
- Cons: a volume cannot move: if its worker is down, the pod waits for it. The requested size is not enforced, so a volume can fill the node's disk. On the root disk for now, shared with container images. Its namespace must be `privileged` (helper pods mount a node folder).

### Option B — Longhorn
Distributed block storage: each volume is replicated to several nodes over the network.
- Pros: a volume survives the loss of a worker and the pod can move; snapshots, backups to S3 and cross-cluster DR volumes; integrated with Rancher; the same tool on both sites; much to learn.
- Cons: below its recommended minimum here: Longhorn v1.13.0 asks for at least 3 nodes with 4 vCPU and 4 GiB each, and reserves 12% of each node's CPU for its instance manager by default. Needs node preparation (open-iscsi with iscsid running, NFSv4 client, cryptsetup, dmsetup; multipathd must ignore its devices) and recommends a dedicated disk. Runs privileged components on every worker. For PostgreSQL, CloudNativePG advises one storage replica with `strict-local` data locality to avoid write amplification, so most volumes in this plan would not use the replication. Its backups would be a third DR mechanism beside CloudNativePG and Velero.

### Option C — the hypervisor's CSI driver (the equivalent of AWS EBS)
Each PVC becomes a VM disk that can be reattached to another worker: CloudStack CSI at EduCloud, Proxmox CSI at Homelab.
- Pros: volumes survive a worker loss without replication overhead; no storage daemons beyond the CSI driver.
- Cons: two different drivers for the two sites. Each cluster holds credentials for the hypervisor's API: at EduCloud, CloudStack API keys for the account; at Homelab, a Proxmox API token, even if limited to disk privileges. Apache CloudStack ships no CSI driver of its own. The maintained one (Leaseweb's, v0.14.1, October 2026) is "tested only in a KVM zone" and needs a custom-size shared disk offering and node names that match the instance names, which EduCloud's offerings may not provide.

## Decision

Use **local-path-provisioner** (v0.0.37, upstream's Helm chart) as the default StorageClass on both clusters, with `local` volumes. Data that must survive the loss of a worker is replicated by the application that owns it (CloudNativePG, OpenBao Raft), not by the storage layer.

## Consequences

- **Easier:** storage works on both clusters now, with almost no CPU or RAM taken from the banking app and the security tools; there is no node preparation, and both sites are configured the same way.
- **Harder:** every stateful workload must bring its own replication, or accept downtime while its worker is down. Draining a worker needs a CloudNativePG switchover first. Disk usage must be watched, since sizes are not enforced.
- **Next:**
  - install with [platform/local-path/](../../platform/local-path/README.md) on both clusters;
  - run CloudNativePG clusters with at least two instances on different workers;
  - later, a dedicated disk per worker for `/opt/local-path-provisioner` (OpenTofu at EduCloud, Proxmox at Homelab, mounted by Ansible).
- **Revisit** if a site gets a third worker with 4 vCPU and a dedicated disk, or a workload appears that needs a movable volume and cannot replicate itself: then Longhorn (Option B) is the candidate.
- **Validation in the lab:**
  - the smoke test in `platform/local-path/smoke-test.yaml` (volume bound, `fsGroup` applied, folder removed on delete);
  - stop a worker while a two-instance CloudNativePG cluster runs, and record the failover time;
  - in the DR phase, back up and restore a `local-path` volume with Velero.

## Sources

All accessed 2026-11-25.

- local-path-provisioner: https://github.com/rancher/local-path-provisioner (README: "No support for the volume capacity limit currently"; chart values at v0.0.37; release v0.0.37 published 2026-08-05)
- Longhorn v1.13.0: installation requirements https://longhorn.io/docs/latest/deploy/install/#installation-requirements · best practices (minimum hardware, Guaranteed Instance Manager CPU, dedicated disk) https://longhorn.io/docs/latest/best-practices/ · data locality https://longhorn.io/docs/1.13.0/high-availability/data-locality/ · multipath https://longhorn.io/kb/troubleshooting-volume-with-multipath/
- CloudNativePG storage, "Block storage considerations (Ceph/Longhorn)": https://github.com/cloudnative-pg/cloudnative-pg/blob/main/docs/src/storage.md
- Velero file system backup ("hostPath volumes are not supported, but the local volume type is supported"): https://velero.io/docs/main/file-system-backup/
- CloudStack CSI driver: https://github.com/leaseweb/cloudstack-csi-driver · Apache's provider has no CSI driver: https://github.com/apache/cloudstack-kubernetes-provider
- Proxmox CSI plugin: https://github.com/sergelogvinov/proxmox-csi-plugin
- Bank of Anthos manifests: https://github.com/GoogleCloudPlatform/bank-of-anthos/tree/main/kubernetes-manifests
