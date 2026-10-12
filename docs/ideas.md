# Ideas & development roadmap

Options and a proposal for each part of the project, mapped to the requirements in the [project plan](Project%20Plan_v1.pdf). Nothing here is decided: review it, then record each decision as an ADR in `docs/adr/` (`/adr` in Claude Code).

Tool versions and project status as of 2026-10-12.

## Open decisions

| # | Decision | Depends on | Proposal |
|---|---|---|---|
| 1 | Which site is primary | Netlab uptime and reachability | Homelab primary, Netlab DR — you control power, hardware and uptime at home |
| 2 | Kubernetes approach at Netlab | what Netlab provides (VMs? which hypervisor?) | Talos Linux |
| 3 | Site-to-site link | whether Netlab allows outbound UDP | plain WireGuard; NetBird or Headscale if UDP is blocked |
| 4 | mTLS layer | maturity at implementation time | Istio ambient mode |
| 5 | Secrets manager | — | OpenBao + External Secrets Operator |
| 6 | GitOps tool and placement | decision 1 | Argo CD, one instance per cluster |
| 7 | Where backups live | budget, Netlab storage | object storage that is *not* on the primary site |
| 8 | Dummy banking app | — | Bank of Anthos |

**Ask Netlab early:** what you get (VMs or bare metal, which hypervisor, how much CPU/RAM), the IP range, whether outbound UDP is allowed, and whether anything can be reachable from outside. Decisions 1–3 and 7 depend on the answers.

---

## 1. Second cluster: "a different enterprise approach"

The plan calls for two different enterprise deployment approaches. The contrast is research material, so pick the option that gives the most interesting comparison, not the easiest one.

| Option | What it is | Contrast with RKE2 | Effort |
|---|---|---|---|
| **Talos Linux** | Immutable, minimal OS managed only through an API — no SSH, no shell, no package manager | Hardened distro on a general-purpose OS vs. an OS that *is* the hardening | medium |
| kubeadm on Ubuntu | Upstream reference install | Shows what RKE2 gives for free (CIS defaults, encryption, PSA) — you do it all by hand | high |
| OKD / OpenShift | Opinionated enterprise platform | Very "enterprise", but heavy on resources and install complexity | high |
| Rancher-provisioned RKE2 (Cluster API) | Same distro, different lifecycle tooling | Weak — same distro twice | low |

**Proposal: Talos.** It runs Cilium (so Cluster Mesh works), ships CIS-aligned defaults, and gives clear comparison axes for the report: mutable vs. immutable node OS, SSH vs. API-only management, node attack surface, time to provision, kube-bench score.

## 2. Site-to-site connectivity

Requirement: secure link between sites despite NAT and strict firewalls.

| Option | NAT traversal | Notes |
|---|---|---|
| **WireGuard** (gateway VM per site) | needs one side reachable on UDP (port-forward at home; Netlab connects outbound) | simplest, fastest, fully self-hosted; static config |
| NetBird (self-hosted) | yes, relays over TCP/HTTPS when UDP is blocked | WireGuard-based mesh with ACLs and SSO; more moving parts |
| Headscale + Tailscale clients | yes, DERP relays over HTTPS | self-hosted Tailscale control server |

**Proposal:** WireGuard site-to-site between two small gateway VMs, routing the two node subnets. Fall back to NetBird if Netlab blocks outbound UDP.

On top of the tunnel, **Cilium Cluster Mesh** joins the clusters: pods can reach services in the other cluster, and network policies can match identities across clusters. A *global service* (`service.cilium.io/global: "true"`) with local affinity sends traffic to the other cluster only when local endpoints are gone — a building block for automatic failover.

Watch out for:
- **MTU** — VXLAN inside WireGuard inside your uplink. Measure with `ping -M do -s <size>` across the tunnel and lower Cilium's MTU if needed.
- The tunnel is a single point of failure for cross-site traffic, but failover must *not* depend on it (the primary site may be the one that is down).

## 3. Zero trust: preventing lateral movement

Requirements: block unauthorised lateral movement, mTLS between workloads, zero-trust principles.

| Layer | Tooling | What it gives you |
|---|---|---|
| L3/L4 network policy | Cilium NetworkPolicy, default-deny per namespace | only explicitly allowed flows exist |
| L7 + DNS egress | Cilium L7 rules, `toFQDNs` | e.g. ledger service may only `POST /transactions`; pods may reach only named external hosts |
| Workload identity + mTLS | **Istio ambient** (ztunnel, no sidecars) or Cilium mutual authentication (SPIFFE/SPIRE) | encrypted, authenticated service-to-service traffic; identity-based AuthorizationPolicy |
| Node-to-node encryption | Cilium WireGuard | all pod traffic between nodes is encrypted |
| Admission control | Kyverno (or built-in ValidatingAdmissionPolicy) | no privileged pods, pinned images, required labels, signed images (cosign) |
| Runtime detection | Tetragon (eBPF, same project family as Cilium) or Falco | alerts on shells in containers, sensitive file reads, unexpected processes |
| Human access | OIDC login (Keycloak / Authentik / Dex) + RBAC | no shared admin kubeconfig; least privilege |
| Supply chain | Trivy Operator | vulnerability and misconfiguration reports in-cluster |

**Proposal:** Cilium for L3–L7 policy and node encryption, Istio ambient for mTLS and identity, Kyverno for admission, Tetragon for runtime. Check Istio's platform prerequisites for Cilium with kube-proxy replacement before installing, and check the maturity of both mTLS options in their current docs — this comparison is itself a good "Library" research item.

Extra RKE2 hardening:
- Join nodes with the **secure token format** (`K10<CA hash>::server:<secret>` from `/var/lib/rancher/rke2/server/token` and `.../agent-token` on hl-master-01) so joining nodes verify the cluster CA.
- Enable an **API audit policy** (`audit-policy-file` in server.yaml) and ship the audit log to Loki.
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
- Optional central view: Rancher importing both clusters.

Repo layout to grow into:

```
clusters/homelab/   clusters/netlab/     # per-cluster entry points (Argo CD app-of-apps)
platform/           # cilium policies, kyverno, observability, ESO ... (base + per-site overlays)
apps/bank/          # banking app (base + per-site overlays)
```

## 6. Disaster recovery

Requirements: survive total loss of the primary cluster; defined RTO and RPO; asynchronous state replication accepted.

Recovery layers:

| Layer | Tool | Notes |
|---|---|---|
| Cluster config + apps | GitOps | secondary already runs the platform; nothing to restore |
| Database | **CloudNativePG** with a replica cluster at the secondary site | async replication via WAL archive in object storage (and streaming over the VPN); failover = promote the replica |
| Kubernetes objects + volumes | Velero (Kopia) → S3 | for anything not covered by GitOps or CNPG |
| Control plane | RKE2 etcd snapshots → S3 | rebuilding the primary itself (needs the original `cluster-token`) |
| Traffic | DNS failover: k8gb, or external-dns + health-checked DNS | users follow the healthy site |

**Proposal: warm standby.** The secondary runs the app scaled down with a CNPG replica. Failover automation (k8gb, or a small controller/script driven by health checks) promotes the DB, scales up the app and flips DNS. Start with a documented manual runbook, then automate it — the before/after RTO is a good result for the report.

Targets to define, then measure: e.g. **RTO ≤ 5 min, RPO ≤ 1 min** (bounded by CNPG's WAL archive timeout).

Object storage must not live on the primary site. Options: storage at Netlab, cloud object storage (Backblaze B2, Hetzner, Cloudflare R2), or self-hosted Garage / SeaweedFS. If you consider MinIO, check its current community-edition status first; it changed significantly in 2025.

## 7. In-cluster storage

| Option | Fit |
|---|---|
| **Longhorn** | from Rancher, pairs well with RKE2, replicated volumes, snapshots and backups to S3. Needs `open-iscsi` on workers. |
| Proxmox CSI | volumes as Proxmox disks; ties the cluster to the hypervisor |
| Rook-Ceph | most "enterprise", heavy for 3 workers |

**Proposal:** Longhorn on a second disk per worker. CloudNativePG replicates at the database level anyway.

## 8. Observability

Requirement: security events, blocked traffic and infrastructure metrics centrally visible and measurable.

- Metrics: kube-prometheus-stack per cluster; one Grafana with both clusters as data sources, or remote-write to a central store at the secondary site (survives primary loss).
- Logs: Loki + Grafana Alloy (include the Kubernetes audit log).
- Security: Hubble metrics and flow logs (dropped flows, policy verdicts) + Tetragon events → Grafana dashboards and alerts.
- Turn on `etcd-expose-metrics` in server.yaml once Prometheus is in place.

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
- **Evidence:** Hubble dropped flows, Tetragon alerts, Kyverno denials — screenshots and counts.

Resilience:
- Single worker loss, master loss (VIP failover), full primary-site loss (power off all Homelab VMs or cut the uplink), database corruption (point-in-time restore).
- Measure **RTO** with an external synthetic probe and **RPO** with the transaction count.
- Chaos Mesh or LitmusChaos for repeatable pod and network faults.

Performance (requirement: "acceptable, measured latency overhead"):
- fortio or k6 against the app, adding one layer at a time: no policies → Cilium policies → WireGuard → mTLS → cross-site. Report p50/p95/p99 latency.
- iperf3 across the VPN for throughput.

## 11. Automation path

1. **Now:** manual bring-up with `rke2-config/` — you learn how each piece works.
2. **OpenTofu** with the `bpg/proxmox` provider: the 6 VMs from the template with cloud-init (replaces the `qm` loop).
3. **Ansible** in `ansible/`: `prepare-node.sh` steps as tasks, configs as templates, tokens from Ansible Vault or SOPS. Writing your own small role teaches more and is easier to explain in the report than adopting a large community role.
4. **Upgrades:** RKE2's system-upgrade-controller with Plans committed to Git — upgrades become GitOps changes.

## Suggested next steps

1. Review `rke2-config/` and `docs/network-plan.md`; replace the example values.
2. Send Netlab the questions at the top of this page.
3. Build the Homelab cluster by hand, following `rke2-config/README.md`.
4. Run kube-bench immediately — baseline result for the report.
5. Record decisions 1–8 as ADRs as you make them.
6. Codify the cluster: OpenTofu for VMs, Ansible for nodes.
