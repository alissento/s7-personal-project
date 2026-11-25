# Secure Multi-Site Kubernetes for a Banking Workload

Semester 7 personal project. This repo holds the Infrastructure as Code and GitOps manifests for two Kubernetes clusters on two sites, hardened with zero-trust principles, with automated disaster recovery between them.

> **Status:** Phase 1 — building the skeleton by 2026-11-19: both RKE2 clusters, Rancher managing both, and the NetBird link between the sites. Homelab cluster done (2026-11-14); EduCloud next. See the [roadmap](#roadmap).

## Research question

> How can we architect a secure enterprise infrastructure with Kubernetes for a banking system that provides an automated disaster recovery system?

1. What is the current optimal way to architect and create enterprise-level clusters?
2. What security considerations matter while setting up and maintaining Kubernetes clusters?
3. How can network and application-level policies prevent unauthorised lateral movement between workloads?
4. How can disaster recovery be automated so there is almost no downtime when the main cluster goes down?

Full plan: [docs/Project Plan_v1.pdf](docs/Project%20Plan_v1.pdf)

## Target architecture

```mermaid
flowchart LR
    subgraph HL["Homelab · Poland · Proxmox — primary (proposed)"]
        direction TB
        HLCP["RKE2 control plane<br/>3 × master + kube-vip VIP"]
        HLW["2 × worker<br/>banking app · PostgreSQL primary"]
        HLCP --- HLW
    end
    subgraph NL["EduCloud — secondary / DR (proposed)"]
        direction TB
        NLCP["RKE2 control plane<br/>3 × master, provisioned by Rancher"]
        NLW["2 × worker<br/>standby app · PostgreSQL replica"]
        NLCP --- NLW
    end
    HL <-->|"NetBird link (WireGuard)<br/>gateway ↔ gateway<br/>target: TCP 443 · 22/6443 · 5432 only"| NL
    NB(["NetBird Cloud<br/>keys + policies; relays the<br/>encrypted tunnel today"]) -.- HL
    NB -.- NL
    RANCHER["Rancher<br/>own VM at EduCloud"] -.->|manages| HL
    RANCHER -.->|"provisions + manages"| NL
    GIT[("GitHub<br/>IaC + GitOps")] -.->|sync| HL
    GIT -.->|sync| NL
    S3[("Off-site<br/>object storage")]
    HL -->|"etcd snapshots · Velero · DB WAL"| S3
    S3 -->|restore| NL
```

| | Homelab | EduCloud |
|---|---|---|
| Location | Poland | school cloud (previously Netlab) |
| Hypervisor | Proxmox VE | TBD |
| Kubernetes | RKE2 v1.36 — 3 masters, 2 workers | RKE2 — 3 masters, 2 workers |
| Deployment approach | Ansible installs RKE2, cluster imported into Rancher | [Rancher provisions RKE2](docs/ideas.md#1-two-rke2-clusters-two-deployment-approaches) (custom cluster) |
| Role | primary (proposed) | secondary / DR (proposed) |

## Stack

| Layer | Choice | Status |
|---|---|---|
| Node OS | Ubuntu 26.04 LTS | decided |
| Kubernetes (Homelab) | RKE2 v1.36.5, CIS profile | decided |
| CNI | Cilium with kube-proxy replacement + Hubble | in the RKE2 role, to review |
| API high availability | kube-vip (ARP) | in the RKE2 role, to review |
| Ingress | Traefik (RKE2 default) | in the RKE2 role, to review |
| Kubernetes (EduCloud) | RKE2 | decided 2026-11-14 |
| Cross-site connectivity | NetBird: one gateway per site, deny-by-default policy | decided 2026-11-14 |
| Central management | Rancher, own VM at EduCloud | decided 2026-11-14 |
| mTLS, secrets, GitOps, DR, storage, observability | — | open — see [docs/ideas.md](docs/ideas.md) |

## Repository layout

```
.
├── docs/             project plan, network plan, ideas & roadmap, Claude Code guide
├── ansible/          node preparation and RKE2 install (in progress)
├── opentofu/         (planned) EduCloud VMs via the CloudStack API; later Homelab's Proxmox VMs
├── clusters/         (planned) GitOps entry point per cluster
├── platform/         (planned) shared platform services: policies, observability, secrets
└── apps/             (planned) the dummy banking application
```

## Getting started

1. Read [docs/network-plan.md](docs/network-plan.md) and replace the example IPs and hostnames.
2. Build the Homelab cluster with the playbooks in [ansible/](ansible/) (in progress). [ansible/README.md](ansible/README.md) explains every file. Run these from `ansible/`:

   ```bash
   ansible-galaxy collection install -r requirements.yml   # once, on a new workstation
   ansible-lint && yamllint .                              # check before running
   ansible-playbook -i inventory/homelab site.yml -K         # prepare the nodes; safe to repeat
   ansible-playbook -i inventory/homelab upgrade.yml -K      # OS upgrades and reboots, only when you mean to
   ansible-playbook -i inventory/homelab workstation.yml -K  # kubectl and kubeconfig on this machine, once the cluster runs
   ```

   `upgrade.yml` is separate so that `site.yml` can never reboot a node. It has no drain step yet, so don't use it on a live cluster.

## Roadmap

Phases follow the timeline in the project plan.

- **Weeks 1–7 — Research and design**
  - [x] Project plan
  - [ ] Product analysis: site link (Tailscale vs NetBird vs OpenZiti), mTLS, secrets, DR tooling
  - [ ] Architecture diagrams and network plan
  - [ ] Decisions recorded as ADRs
- **Weeks 4–9 — Two working clusters**
  - [x] Homelab RKE2 cluster (3 + 2) — Ansible, VIP failover tested
  - [x] Baseline CIS scan (kube-bench) — rerun before hardening
  - [ ] Rancher on its own VM at EduCloud; Homelab imported
  - [ ] EduCloud RKE2 cluster, provisioned by Rancher
  - [ ] NetBird link between the sites
  - [ ] GitOps bootstrap on both clusters
  - [ ] VMs and node setup as code (OpenTofu + Ansible)
- **Weeks 10–12 — Hardening and test application**
  - [ ] Default-deny network policies, mTLS, admission policies, runtime detection
  - [ ] Centralised secrets management
  - [ ] Banking test application deployed
- **Weeks 13–15 — Disaster recovery and backups**
  - [ ] RTO / RPO defined
  - [ ] etcd + Velero + database backups off-site
  - [ ] Database replication to the secondary site
  - [ ] Automated failover
- **Weeks 16–17 — Security and resilience testing**
  - [ ] Lateral movement simulation (before vs. after hardening)
  - [ ] Primary site failure, RTO / RPO measured
  - [ ] Latency overhead measured
- **Weeks 18–20 — Evaluation and documentation**
  - [ ] Research report, technical report, final presentation and live demo

## Methodology

The research follows the DOT framework:

| Method | Used for | Output |
|---|---|---|
| Available product analysis (Library) | choosing the stack | `docs/research/`, ADRs |
| IT architecture sketching (Workshop) | designing both clusters, connectivity, security, DR | diagrams, `docs/network-plan.md`, ADRs |
| System and security test (Lab) | functional, attack and failover tests | test reports, measurements |
| Peer review (Showroom) | feedback from coaches and peers | final report |

## Secrets

Nothing secret is ever committed. RKE2 join tokens are plain files on the nodes (`token-file`), kept on the workstation in the gitignored `ansible/secrets/` folder, kubeconfigs stay in `~/.kube`, and [.gitignore](.gitignore) blocks the usual suspects. Encrypted secrets (SOPS) and a secrets manager come in the hardening phase.

## Working with Claude Code

This repo is set up for [Claude Code](https://claude.com/claude-code): [CLAUDE.md](CLAUDE.md) carries the project context and [.claude/](.claude/) holds permissions, agents and skills. See [docs/claude-code-guide.md](docs/claude-code-guide.md).
