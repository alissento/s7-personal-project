# Network plan

> **Homelab** values are confirmed and were checked on the nodes on 2026-11-06. **EduCloud** (the school cloud, previously Netlab; runs Apache CloudStack) values are still examples. When a value changes, update every file listed under [Where the values live](#where-the-values-live).

Rule: **no range may overlap between the two sites.** The sites are linked by NetBird, which routes each site's node subnet to the other, so overlapping node subnets would break the link. Unique pod and service ranges keep logs, network policies and dashboards unambiguous, and keep Cilium Cluster Mesh possible later.

## Address plan

| Range | Homelab (Poland) | EduCloud | Notes |
|---|---|---|---|
| Node subnet | 10.10.10.0/24 | 10.10.30.0/24 *(ask EduCloud)* | dedicated VLAN/bridge for the cluster if possible |
| Gateway | 10.10.10.1 | 10.10.30.1 | |
| DNS servers | 1.1.1.1, 8.8.8.8 | 10.10.30.1 *(ask EduCloud)* | the Homelab gateway does not answer DNS (TCP 53 refused) |
| API VIP (kube-vip) | 10.10.10.5 | 10.10.30.10 | |
| Pod CIDR | 10.42.0.0/16 | 10.44.0.0/16 | unique per site |
| Service CIDR | 10.43.0.0/16 | 10.45.0.0/16 | |
| Cluster DNS | 10.43.0.10 | 10.45.0.10 | inside the service CIDR |
| LoadBalancer pool | 10.10.10.200–239 | 10.10.30.200–239 | Cilium LB IPAM, later |
| Cilium cluster name / ID | `homelab` / 1 | `educloud` / 2 | unique per cluster |
| NetBird gateway (routing peer) | `gw-01` 10.10.10.30 *(proposed)* | `ec-gw-01` 10.10.30.30 *(proposed)* | advertises the site's node subnet to the other site ([ideas §2](ideas.md#2-cross-site-connectivity-netbird)) |
| Rancher | — | `ec-rancher-01` 10.10.30.40 *(proposed)* | Rancher's own single-node cluster |

## Homelab nodes

Proxmox bridge network 10.10.10.0/24, NIC `ens18` on every node. All IPs are static and there is no DHCP on this network. Login user on every node: `nknez`.

| Hostname | Role | IP |
|---|---|---|
| `api.hl.home.arpa` | kube-vip VIP | 10.10.10.5 |
| master-01 | RKE2 server (init) | 10.10.10.10 |
| master-02 | RKE2 server | 10.10.10.11 |
| master-03 | RKE2 server | 10.10.10.12 |
| worker-01 | RKE2 agent | 10.10.10.20 |
| worker-02 | RKE2 agent | 10.10.10.21 |

Masters use `.10–.19`, workers `.20–.29`, infrastructure VMs (gateway, Rancher) `.30–.49`. EduCloud uses the same scheme on 10.10.30.0/24 with an `ec-` prefix, so the two clusters are not confused in shared dashboards.

## EduCloud nodes (proposed)

| Hostname | Role | IP |
|---|---|---|
| ec-master-01 … 03 | RKE2 server, provisioned by Rancher | 10.10.30.10 – .12 |
| ec-worker-01, 02 | RKE2 agent, provisioned by Rancher | 10.10.30.20, .21 |
| ec-gw-01 | NetBird routing peer | 10.10.30.30 |
| ec-rancher-01 | Rancher (single-node cluster) | 10.10.30.40 |

DNS: Homelab has no local DNS server, so nodes reach the API through the VIP's IP. The name `api.hl.home.arpa` still goes on the API certificate (RKE2 `tls-san`), so a DNS record can be added later without reissuing certificates. Until then, a workstation can use it through an `/etc/hosts` entry. `home.arpa` is the domain reserved for home networks ([RFC 8375](https://www.rfc-editor.org/rfc/rfc8375)).

## Ports between Homelab nodes

If ufw or the Proxmox firewall is on, allow these within the node subnet.

Checked 2026-11-06: ufw is disabled on all nodes (`ENABLED=no`). Probing TCP 6443, 9345, 10250, 2379 and 4240 between all nodes returned "connection refused" every time, so nothing drops that traffic. UDP was not tested; confirm 8472 once Cilium is running.

| Port | Proto | From → To | Purpose |
|---|---|---|---|
| 6443 | TCP | all nodes, admin workstation → masters | Kubernetes API |
| 9345 | TCP | all nodes → masters | RKE2 supervisor (node join) |
| 2379–2381 | TCP | masters ↔ masters | etcd client / peer / metrics |
| 10250 | TCP | all ↔ all | kubelet |
| 30000–32767 | TCP | clients → all | NodePort services |
| 4240 | TCP | all ↔ all | Cilium health checks |
| 4244 | TCP | all ↔ all | Hubble server (relay → nodes) |
| 8472 | UDP | all ↔ all | Cilium VXLAN |
| 51871 | UDP | all ↔ all | Cilium WireGuard (once encryption is enabled) |
| ICMP echo | — | all ↔ all | Cilium health |

## Cross-site traffic

Neither site opens an inbound port: the NetBird gateways only dial out, to NetBird's control server and to each other. The NetBird access policy (deny by default) lets only these through:

| Port | Proto | From → To | Purpose |
|---|---|---|---|
| 443 | TCP | Homelab nodes → `ec-rancher-01` | Rancher agents of the imported Homelab cluster |
| 6443 | TCP | admin → masters of either site | Kubernetes API |
| 5432 | TCP | EduCloud replica → Homelab primary | database replication (DR phase) |

## Where the values live

| Value | Files |
|---|---|
| Node IPs, hostnames | `ansible/inventory/homelab/hosts.yml`, this file |
| VIP, API hostname, CIDRs, NIC name, Cilium cluster name / ID | `ansible/inventory/homelab/group_vars/all.yml`, this file |
| RKE2 and kube-vip versions, node region label | `ansible/inventory/homelab/group_vars/all.yml` |
| Gateway, DNS servers | the nodes' own network config (not managed by Ansible), this file |
