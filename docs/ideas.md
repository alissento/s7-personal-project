# Ideas & development roadmap

Options and a proposal for each part of the project, mapped to the requirements in the [project plan](Project%20Plan_v1.pdf). Record each decision as an ADR in `docs/adr/` (`/adr` in Claude Code) once it is made.

Tool versions and project status as of 2026-11-14.

## Decisions

### Made on 2026-11-14 (ADRs still to write)

| Decision | Choice | Why |
|---|---|---|
| Second site | **EduCloud**, the school cloud (previously called Netlab): VPC-style networks and VMs; room for 3 masters + 2 workers plus extra VMs | |
| Kubernetes on both sites | **RKE2** | one distribution to learn and harden, the same CIS baseline on both sites, the Homelab Ansible work carries over, first-class Rancher support. Talos was dropped: a new OS without SSH would cost days and make the Ansible role useless there. |
| Cross-site connectivity | **NetBird** | no port forwarding at either site, deny-by-default access policies, open source including the control server, and it routes whole subnets so ordinary tools (`ping`, `tcpdump`) work. Tailscale and OpenZiti were considered (§2). |
| Central management | **Rancher**, on its own VM at EduCloud | the plan's "centralized management plane"; at the DR site it survives the loss of the primary (§5) |
| EduCloud cluster lifecycle | **provisioned by Rancher** (custom cluster); fallback: the same Ansible role as Homelab | keeps "two different deployment approaches" with one distribution (§1) |

### Open

| # | Decision | Depends on | Proposal |
|---|---|---|---|
| 1 | Which site is primary | EduCloud uptime | Homelab primary, EduCloud DR: you control power, hardware and uptime at home |
| 2 | Where the NetBird control server runs | time | NetBird Cloud (free plan) for the skeleton; self-hosted on a VPS later |
| 3 | mTLS inside each cluster | maturity at implementation time | Istio ambient mode |
| 4 | Secrets manager | — | OpenBao + External Secrets Operator |
| 5 | GitOps tool and placement | 1 | Argo CD, one instance per cluster; Fleet (built into Rancher) is the alternative |
| 6 | Where backups live | budget, EduCloud storage | object storage that is *not* on the primary site |
| 7 | Dummy banking app | — | Bank of Anthos, adapted (§9) |

**Ask EduCloud:** whether VMs may reach the internet over HTTPS and UDP (NetBird and Rancher's agents only dial out), and whether VMs can be created through an API (for OpenTofu later).

---

## 1. Two RKE2 clusters, two deployment approaches

The plan calls for two different enterprise deployment approaches. With RKE2 on both sites, the contrast moves from the *distribution* to the *lifecycle*: how a cluster is created, upgraded and scaled.

| | Homelab | EduCloud |
|---|---|---|
| Approach | **Configuration management.** Ansible prepares the nodes and installs RKE2; the finished cluster is *imported* into Rancher. | **Management platform.** Rancher *provisions* the cluster as a "custom cluster": Rancher generates a registration command that is run on prepared VMs, and an agent on each VM installs RKE2 the way Rancher defines it. (With a node driver, e.g. OpenStack or vSphere, Rancher would also create the VMs; EduCloud has none.) |
| Source of truth | this repo (`ansible/`) | Rancher's cluster object (`clusters.provisioning.cattle.io`), which can be kept in Git or managed with OpenTofu's `rancher2` provider |
| Upgrades and scaling | re-run Ansible, or system-upgrade-controller Plans | change the version or add a node in Rancher |
| Depends on | Git + Ansible on a workstation | Rancher being up (the cluster keeps running without it, but cannot be changed) |

The Ansible `common` role (SSH hardening, disk, swap, packages) prepares the EduCloud VMs too.

For the report: effort to build, rebuild and upgrade each cluster, and what each approach depends on during a disaster.

**Check with the coaches** that RKE2 on both sites with two lifecycle approaches still counts as "two different deployment approaches". It changes the project plan.

**Versions:** Rancher v2.15 added Kubernetes v1.36 support; the v2.15.1 notes list RKE2 v1.36.3 as the default ([release notes](https://documentation.suse.com/cloudnative/rancher-manager/v2.15/en/release-notes/v2.15.1.html), checked 2026-11-14). Keep `rke2_version` on a release the chosen Rancher version supports. Those notes also flag that Rancher Backups may not appear under Cluster Tools on v1.36 clusters.

## 2. Cross-site connectivity: NetBird

Requirement: secure link between sites despite NAT and strict firewalls, without port forwarding at home.

| | Tailscale | **NetBird** | OpenZiti |
|---|---|---|---|
| What it is | WireGuard mesh | WireGuard mesh with access policies | zero-trust overlay: access per service, no routed networks |
| Port forwarding needed | no | no | no, but needs a publicly reachable controller and router |
| Control server | closed source (Headscale is a third-party open-source rewrite) | open source; NetBird Cloud or self-hosted | open source, self-hosted |
| Routes whole subnets | yes | yes (routing peers) | no: TCP/UDP services only, so no `ping` and no Cilium Cluster Mesh |
| Effort for the skeleton | low | low | high (controller, routers, identities, enrollment) |

**Choice: NetBird.** It gives zero-trust network access between the sites (deny by default, explicit policies, every machine enrolled with its own identity) at the effort of a VPN. The zero-trust requirements inside the clusters (lateral movement, mTLS, secrets) are met by the in-cluster stack (§3), not by the link. OpenZiti stays a candidate for a stretch goal (admin access only through an overlay) and is the comparison in the Library research.

Design:
- One small **routing peer** VM per site (`gw-01` at Homelab, `ec-gw-01` at EduCloud), enrolled with a setup key. Each advertises its site's node subnet with NetBird **Networks**, the recommended feature for site-to-site links ([docs](https://docs.netbird.io/manage/networks/use-cases/site-to-site), checked 2026-11-14).
- **Kubernetes nodes do not run NetBird.** They get a static route to the other site's subnet via their local gateway (set by Ansible), so VPN software never interferes with Cilium on the nodes.
- **Masquerade** (on by default): the remote site sees the gateway's IP, so no return routes are needed ([docs](https://docs.netbird.io/manage/networks/masquerade)). Trade-off: the other site cannot tell which node a connection came from.
- **Access policy:** NetBird is deny-by-default ([docs](https://docs.netbird.io/use-cases/implement-zero-trust)). Only these cross the link: TCP 443 (Rancher agents → Rancher), TCP 6443 (Kubernetes API, admin), TCP 5432 (database replication).
- **Control server:** NetBird Cloud's free plan for the skeleton. Traffic goes directly between the gateways, encrypted; NetBird Cloud only exchanges keys and policies. Self-hosting it on a VPS later removes that third-party dependency. Check the free plan's limits: device posture checks appear to be a paid feature.
- **DR:** the secondary must be able to take over with the link down (§6). The link carries management, admin access and lower-RPO database streaming, not survival.
- **Cilium Cluster Mesh** stays possible later, since the sites are routed. It would need masquerade off and return routes; it is not planned for the skeleton.

## 3. Zero trust: preventing lateral movement

Requirements: block unauthorised lateral movement, mTLS between workloads, zero-trust principles.

| Layer | Tooling | What it gives you |
|---|---|---|
| L3/L4 network policy | Cilium NetworkPolicy, default-deny per namespace | only explicitly allowed flows exist |
| L7 + DNS egress | Cilium L7 rules, `toFQDNs` | e.g. ledger service may only `POST /transactions`; pods may reach only named external hosts |
| Workload identity + mTLS | **Istio ambient** (ztunnel, no sidecars) or Cilium mutual authentication (SPIFFE/SPIRE) | encrypted, authenticated service-to-service traffic; identity-based AuthorizationPolicy |
| Node-to-node encryption | Cilium WireGuard | all pod traffic between nodes is encrypted |
| Cross-site access | NetBird access policy on the gateways | deny by default; only TCP 443, 6443 and 5432 cross sites (§2) |
| Admission control | Kyverno (or built-in ValidatingAdmissionPolicy) | no privileged pods, pinned images, required labels, signed images (cosign) |
| Runtime detection | Tetragon (eBPF, same project family as Cilium) or Falco | alerts on shells in containers, sensitive file reads, unexpected processes |
| Human access | OIDC login (Keycloak / Authentik / Dex) + RBAC | no shared admin kubeconfig; least privilege |
| Supply chain | Trivy Operator | vulnerability and misconfiguration reports in-cluster |

**Proposal:** Cilium for L3–L7 policy and node encryption, Istio ambient for mTLS and identity, Kyverno for admission, Tetragon for runtime. Check Istio's platform prerequisites for Cilium with kube-proxy replacement before installing, and check the maturity of both mTLS options in their current docs — this comparison is itself a good "Library" research item.

Alternative worth comparing in the Library phase: **NeuVector** (SUSE, open source, integrates with Rancher) covers network segmentation, runtime protection and admission control in one product. "One integrated product" vs. "composed from Cilium + Kyverno + Tetragon" is a useful comparison for the report.

Extra RKE2 hardening:
- Join nodes with the **secure token format** (`K10<CA hash>::server:<secret>` from `/var/lib/rancher/rke2/server/token` and `.../agent-token` on master-01) so joining nodes verify the cluster CA.
- Enable an **API audit policy** (`audit-policy-file` in the RKE2 server config) and ship the audit log to Loki.
- Move secrets encryption at rest to **KMS v2** backed by OpenBao.

## 4. Secrets management

Requirement: centralised secrets.

- **OpenBao** (open-source Vault fork, MPL licence) or HashiCorp Vault (BSL licence) as the source of truth.
- **External Secrets Operator** syncs secrets from it into Kubernetes Secrets.
- **SOPS + age** for the few bootstrap secrets needed before OpenBao exists (GitOps repo credentials, initial unseal setup).

DR angle worth a section in the report: **the secrets manager is a DR dependency.** If it lives only on the primary site, the secondary cannot start the app. Options: an OpenBao instance per site with Raft snapshots shipped off-site, or the secrets manager hosted at the secondary site.

## 5. GitOps and the management plane

Requirements: everything declarative, version-controlled, no configuration drift; central management.

- **Argo CD** (UI is good for demos, ApplicationSets template the same apps onto both clusters) or **Flux** (lighter, pure CLI/Git).
- **Placement matters for DR:** an Argo CD hub on the primary dies with the primary. Proposal: one Argo CD per cluster, both pulling from this repo — Git is the central plane, and each site rebuilds itself independently.
- **Rancher** (decided) is the central management plane: one UI and RBAC for both clusters, cluster provisioning (§1), and built-in tools (monitoring, backups).
- **Run Rancher on its own small cluster**, a single-VM RKE2 or K3s cluster, not inside a workload cluster. Rancher cannot provision the cluster it runs on, and keeping it separate means a Rancher problem never touches the banking app. It runs on a VM at EduCloud, the DR site, so it survives the loss of the primary; Homelab's agents reach it through NetBird.
- Rancher is **not in the data path**: if it goes down, both clusters keep running and `kubectl` still works; only central management is lost. Back it up with the rancher-backup operator to off-site storage (§6).
- Rancher includes **Fleet** for GitOps. Fleet runs from the Rancher cluster (hub-and-spoke), so it inherits Rancher's placement; one Argo CD per cluster has no such dependency (open decision 5).

Repo layout to grow into:

```
clusters/homelab/   clusters/educloud/    # per-cluster entry points (Argo CD app-of-apps)
platform/           # cilium policies, kyverno, observability, ESO ... (base + per-site overlays)
apps/bank/          # banking app (base + per-site overlays)
```

## 6. Disaster recovery

Requirements: survive total loss of the primary cluster; defined RTO and RPO; asynchronous state replication accepted.

Recovery layers:

| Layer | Tool | Notes |
|---|---|---|
| Cluster config + apps | GitOps | secondary already runs the platform; nothing to restore |
| Database | **CloudNativePG** with a replica cluster at the secondary site | async replication via WAL archive in object storage (and streaming over the NetBird link); failover = promote the replica |
| Kubernetes objects + volumes | Velero (Kopia) → S3 | for anything not covered by GitOps or CNPG |
| Control plane | RKE2 etcd snapshots → S3 | rebuilding the primary itself (needs the original `cluster-token`) |
| Management plane | rancher-backup → S3 | restore Rancher on a new VM; the workload clusters keep running meanwhile |
| Traffic | DNS failover: k8gb, or external-dns + health-checked DNS | users follow the healthy site |

**Proposal: warm standby.** The secondary runs the app scaled down with a CNPG replica. Failover automation (k8gb, or a small controller/script driven by health checks) promotes the DB, scales up the app and flips DNS. Start with a documented manual runbook, then automate it — the before/after RTO is a good result for the report.

Targets to define, then measure: e.g. **RTO ≤ 5 min, RPO ≤ 1 min** (bounded by CNPG's WAL archive timeout).

Object storage must not live on the primary site. Options: storage at EduCloud, cloud object storage (Backblaze B2, Hetzner, Cloudflare R2), or self-hosted Garage / SeaweedFS. If you consider MinIO, check its current community-edition status first; it changed significantly in 2025.

## 7. In-cluster storage

| Option | Fit |
|---|---|
| **Longhorn** | from Rancher, pairs well with RKE2, replicated volumes, snapshots and backups to S3. Needs `open-iscsi` on workers. |
| Proxmox CSI | volumes as Proxmox disks; ties the cluster to the hypervisor |
| Rook-Ceph | most "enterprise", heavy for 2 workers |

**Proposal:** Longhorn on a second disk per worker. CloudNativePG replicates at the database level anyway.

## 8. Observability

Requirement: security events, blocked traffic and infrastructure metrics centrally visible and measurable.

- Metrics: kube-prometheus-stack per cluster; one Grafana with both clusters as data sources, or remote-write to a central store at the secondary site (survives primary loss).
- Logs: Loki + Grafana Alloy (include the Kubernetes audit log).
- Security: Hubble metrics and flow logs (dropped flows, policy verdicts) + Tetragon events → Grafana dashboards and alerts.
- Turn on `etcd-expose-metrics` in the RKE2 server config once Prometheus is in place.

## 9. The dummy banking app

**Bank of Anthos** (Google, Apache 2.0) fits well: a web frontend, user/contacts/ledger/balance/history microservices, two PostgreSQL databases, JWT auth between services, and a load generator.

- Clear trust boundaries → natural network and authorisation policies (e.g. only `ledgerwriter` may write to `ledger-db`).
- Swap its built-in PostgreSQL StatefulSets for CloudNativePG to get replication and failover.
- The load generator creates a steady stream of transactions → **measure RPO by counting transactions lost in a failover.**

## 10. Testing (DOT "Lab")

Run every scenario **before and after hardening** — the difference is the evidence for the report.

Security:
- **Baseline scans:** kube-bench (has RKE2 benchmark profiles) right after bring-up; Kubescape (NSA/CISA and MITRE frameworks).
- **Lateral movement:** assume the frontend pod is compromised. From it, try the ledger DB, other namespaces, the Kubernetes API with the service-account token, node ports, and the internet. Tools: Peirates, curl/nmap from a debug pod. Map the attempts to the MITRE ATT&CK Containers matrix.
- **Cross-site:** from the same compromised pod, try to reach anything at EduCloud. Only the ports allowed by the NetBird policy should get through.
- **Evidence:** Hubble dropped flows, Tetragon alerts, Kyverno denials — screenshots and counts.

Resilience:
- Single worker loss, master loss (VIP failover), full primary-site loss (power off all Homelab VMs or cut the uplink), database corruption (point-in-time restore).
- Measure **RTO** with an external synthetic probe and **RPO** with the transaction count.
- Chaos Mesh or LitmusChaos for repeatable pod and network faults.

Performance (requirement: "acceptable, measured latency overhead"):
- fortio or k6 against the app, adding one layer at a time: no policies → Cilium policies → Cilium WireGuard → mTLS → cross-site over NetBird. Report p50/p95/p99 latency.
- iperf3 between the sites: throughput and latency overhead of the NetBird link.

## 11. Automation path

1. **Now:** Ansible in `ansible/` prepares the nodes and installs RKE2 (chosen over a manual bring-up). Node setup is tasks, configs are templates. Writing your own small role teaches more and is easier to explain in the report than adopting a large community role. Join tokens are plain files in the gitignored `ansible/secrets/` folder, backed up in a password manager.
2. **EduCloud:** the same `common` role prepares the nodes, then Rancher provisions RKE2 (§1).
3. **OpenTofu** with the `bpg/proxmox` provider: the 5 VMs from the template with cloud-init (replaces creating them by hand in Proxmox).
4. **Upgrades:** RKE2's system-upgrade-controller with Plans committed to Git — upgrades become GitOps changes.

## Suggested next steps

Milestone: the **skeleton by 2026-11-19**: both RKE2 clusters running, Rancher managing both, the NetBird link working.

1. Homelab RKE2 with Ansible (`ansible/`); run kube-bench straight away for the baseline.
2. EduCloud: network 10.10.30.0/24, VMs, the Ansible `common` role; Rancher on its own VM.
3. EduCloud RKE2 provisioned by Rancher (fallback: the Ansible role).
4. NetBird: one gateway per site, routes, access policy, static routes on the nodes; import Homelab into Rancher.
5. Check the RKE2-on-both-sites change with the coaches (§1).
6. Write ADRs for the decisions made on 2026-11-14.
