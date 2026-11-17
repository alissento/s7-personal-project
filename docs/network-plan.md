# Network plan

> **Homelab** values are confirmed and were checked on the nodes on 2026-11-06. **EduCloud** (the school cloud, previously Netlab; runs Apache CloudStack 4.22) values are decided (VPC design chosen on 2026-11-14) and are created by OpenTofu (`opentofu/educloud/`); they are not yet checked on running VMs. When a value changes, update every file listed under [Where the values live](#where-the-values-live).

Rule: **no range may overlap between the two sites.** The sites are linked by NetBird, which routes each site's node subnet to the other, so overlapping node subnets would break the link. Unique pod and service ranges keep logs, network policies and dashboards unambiguous, and keep Cilium Cluster Mesh possible later.

## Address plan

| Range | Homelab (Poland) | EduCloud | Notes |
|---|---|---|---|
| Site range | 10.10.10.0/24 | 10.10.30.0/23 (the VPC) | the range the other site routes through NetBird |
| Node subnet | 10.10.10.0/24 | 10.10.30.0/24 (VPC tier `nodes`) | dedicated VLAN/bridge for the cluster if possible |
| Gateway | 10.10.10.1 | 10.10.30.1 (the VPC's virtual router) | |
| DNS servers | 1.1.1.1, 8.8.8.8 | the tier's virtual router (10.10.30.1 for the nodes) | the Homelab gateway does not answer DNS (TCP 53 refused); at EduCloud the ACLs allow DNS only to the virtual router |
| API VIP (kube-vip) | 10.10.10.5 | 10.10.30.5 *(proposed)* | same last octet on both sites. EduCloud's was listed as 10.10.30.10, which is `ec-master-01`'s address (found 2026-11-17) |
| Pod CIDR | 10.42.0.0/16 | 10.44.0.0/16 | unique per site |
| Service CIDR | 10.43.0.0/16 | 10.45.0.0/16 | |
| Cluster DNS | 10.43.0.10 | 10.45.0.10 | inside the service CIDR |
| LoadBalancer pool | 10.10.10.200–239 | 10.10.30.200–239 | Cilium LB IPAM, later |
| Cilium cluster name / ID | `homelab` / 1 | `educloud` / 2 | unique per cluster |
| NetBird gateway (routing peer) | `gw-01` 10.10.10.30 *(proposed)* | `ec-gw-01` 10.10.31.30 (tier `edge`) | advertises the site's node subnet to the other site ([ideas §2](ideas.md#2-cross-site-connectivity-netbird)) |
| Rancher | — | `ec-rancher-01` 10.10.31.40 (tier `mgmt`) | Rancher's own single-node cluster |

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

Masters use `.10–.19`, workers `.20–.29`, infrastructure VMs (gateway, Rancher) `.30–.49`. EduCloud uses the same scheme with an `ec-` prefix, so the two clusters are not confused in shared dashboards; there the gateway and Rancher sit in their own small subnets (`.31.30`, `.31.40`, see below).

## EduCloud network and VMs

EduCloud runs Apache CloudStack. The site is one **VPC** (10.10.30.0/23) with one virtual router (VR) and three **tiers** (subnets), each behind its own **network ACL**: deny by default in both directions, then only the listed traffic. Traffic between VMs in the same tier does not pass the VR and is not filtered. Chosen on 2026-11-14 over a plain isolated network (whose EduCloud offerings can only *block* named egress, not allow it) and a single-tier VPC (where the gateway's and Rancher's rules would apply to every node). Code: `opentofu/educloud/network.tf`.

| Tier | Subnet | VR / gateway | Holds |
|---|---|---|---|
| `nodes` | 10.10.30.0/24 | 10.10.30.1 | masters, workers, API VIP, LoadBalancer pool |
| `edge` | 10.10.31.16/28 | 10.10.31.17 | `ec-gw-01`: NetBird routing peer |
| `mgmt` | 10.10.31.32/28 | 10.10.31.33 | `ec-rancher-01` |
| *free* | rest of 10.10.31.0/24 | | room for more /28 tiers |

| Hostname | Role | Tier | IP |
|---|---|---|---|
| `ec-master-01` … `03` | RKE2 server, provisioned by Rancher | `nodes` | 10.10.30.10 – .12 |
| `ec-worker-01`, `02` | RKE2 agent, provisioned by Rancher | `nodes` | 10.10.30.20, .21 |
| `ec-gw-01` | NetBird routing peer | `edge` | 10.10.31.30 |
| `ec-rancher-01` | Rancher (single-node cluster) | `mgmt` | 10.10.31.40 |

What the ACLs allow (everything else is denied):

| Tier | In | Out |
|---|---|---|
| `nodes` | 22 and 6443 from `edge`; ICMP from the VPC | DNS to the VR; 80, 443, time sync, ICMP to anywhere |
| `edge` | ICMP from the VPC; nothing from outside (NetBird only dials out) | DNS to the VR; 80, 443, time sync, ICMP to anywhere; 22 to the VPC; 6443 to `nodes`; all UDP to anywhere (NetBird: STUN and direct WireGuard connections to peers) |
| `mgmt` | 443 from `nodes` and `edge`; 22 from `edge`; ICMP from the VPC | DNS to the VR; 80, 443, time sync, ICMP to anywhere |

Time sync is two rules: TCP 4460 and UDP 123. Ubuntu 26.04's chrony uses NTS (authenticated NTP), which fetches its keys over TCP 4460 before syncing over UDP 123; with only 123 open the clock never synchronised (found on `ec-gw-01`, 2026-11-17).

EduCloud's additional "public" IPs are private addresses (10.52.x, 10.53.x) that only the school network and its VPN can reach; only the VPC's source NAT IP is on the internet. So nothing at EduCloud can be published to the internet, and admin access from outside the school goes through NetBird, which only dials out.

Admin access (since 2026-11-17): the admin's PC and `ec-gw-01` both run NetBird. `ec-gw-01` is the routing peer for 10.10.30.0/23, and a NetBird policy lets the PC reach the VPC on TCP 22, 443 and 6443. The traffic arrives in the other tiers from `ec-gw-01`'s address (masquerade), which is what their ACLs allow from `edge`. Break-glass: the VM console in the EduCloud UI. The temporary SSH port forward used to bootstrap this is removed.

## Cross-site traffic

Neither site opens an inbound port: the NetBird gateways only dial out, to NetBird's control server and to each other. The NetBird access policy (deny by default) lets only these through:

| Port | Proto | From → To | Purpose |
|---|---|---|---|
| 443 | TCP | Homelab nodes → `ec-rancher-01` | Rancher agents of the imported Homelab cluster |
| 6443 | TCP | admin → masters of either site | Kubernetes API |
| 22, 443 | TCP | admin → EduCloud VPC | SSH and Ansible; the Rancher UI (in place since 2026-11-17) |
| 5432 | TCP | EduCloud replica → Homelab primary | database replication (DR phase) |

## Where the values live

| Value | Files |
|---|---|
| Node IPs, hostnames | `ansible/inventory/homelab/hosts.yml`, this file |
| VIP, API hostname, CIDRs, NIC name, Cilium cluster name / ID | `ansible/inventory/homelab/group_vars/all.yml`, this file |
| RKE2 and kube-vip versions, node region label | `ansible/inventory/homelab/group_vars/all.yml` |
| Gateway, DNS servers | the nodes' own network config (not managed by Ansible), this file |
| EduCloud VPC, tiers, gateways, ACL rules | `opentofu/educloud/network.tf`, this file |
| EduCloud VM names, IPs, sizes | `opentofu/educloud/instances.tf`, `opentofu/educloud/README.md`, this file |
| NetBird network, routing peer, groups and access policies | the NetBird dashboard (not in the repo yet) |
