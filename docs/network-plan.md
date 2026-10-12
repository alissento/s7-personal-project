# Network plan

> All values are **examples**. Replace them with your real ranges, then update every file listed under [Where the values live](#where-the-values-live).

The one hard rule: **no range may overlap between the two sites or with the VPN.** Cilium Cluster Mesh routes pod IPs directly between clusters, and the site-to-site VPN routes node subnets — any overlap breaks both.

## Address plan

| Range | Homelab (Poland) | Netlab | Notes |
|---|---|---|---|
| Node subnet | 10.10.20.0/24 | 10.10.30.0/24 *(ask Netlab)* | dedicated VLAN/bridge for the cluster if possible |
| Gateway / DNS | 10.10.20.1 | 10.10.30.1 | |
| API VIP (kube-vip) | 10.10.20.10 | 10.10.30.10 | |
| Pod CIDR | 10.42.0.0/16 | 10.44.0.0/16 | must not overlap (Cluster Mesh) |
| Service CIDR | 10.43.0.0/16 | 10.45.0.0/16 | |
| Cluster DNS | 10.43.0.10 | 10.45.0.10 | inside the service CIDR |
| LoadBalancer pool | 10.10.20.200–239 | 10.10.30.200–239 | Cilium LB IPAM, later |
| Cilium cluster name / ID | `homelab` / 1 | `netlab` / 2 | unique per cluster |
| VPN overlay | 100.64.0.0/10 (Headscale/NetBird) or 10.99.0.0/24 (plain WireGuard) | | see docs/ideas.md |

## Homelab nodes

| Hostname | Role | IP | Proxmox VMID |
|---|---|---|---|
| `api.hl.home.arpa` | kube-vip VIP | 10.10.20.10 | — |
| hl-master-01 | RKE2 server (init) | 10.10.20.11 | 211 |
| hl-master-02 | RKE2 server | 10.10.20.12 | 212 |
| hl-master-03 | RKE2 server | 10.10.20.13 | 213 |
| hl-worker-01 | RKE2 agent | 10.10.20.21 | 221 |
| hl-worker-02 | RKE2 agent | 10.10.20.22 | 222 |
| hl-worker-03 | RKE2 agent | 10.10.20.23 | 223 |

Naming: `<site>-<role>-NN`, site `hl` = Homelab, `nl` = Netlab. VMID is `2` followed by the IP's last octet (211 ↔ .11), so one can be read off the other.

DNS: `home.arpa` is the domain reserved for home networks ([RFC 8375](https://www.rfc-editor.org/rfc/rfc8375)). Add `api.hl.home.arpa → 10.10.20.10` and the node names on your router / Pi-hole / AdGuard; if you own a real domain, a subdomain of it works too (`tls-san` in server.yaml must match).

## Ports between Homelab nodes

If ufw or the Proxmox firewall is on, allow these within the node subnet.

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

Cross-site ports (VPN, Cluster Mesh API) are added once the site-to-site design is decided.

## Where the values live

| Value | Files |
|---|---|
| VIP | `rke2-config/server.yaml` (tls-san), `server-join.yaml`, `agent.yaml`, `manifests/kube-vip.yaml` (`address`) |
| VIP DNS name | `rke2-config/server.yaml` (tls-san) |
| NIC name | `rke2-config/manifests/kube-vip.yaml` (`vip_interface`) |
| Pod / service CIDR, cluster DNS | `rke2-config/server.yaml` |
| Cilium cluster name / ID | `rke2-config/manifests/rke2-cilium-config.yaml` |
| Node IPs, hostnames | `rke2-config/README.md` (VM loop, node table), this file |
