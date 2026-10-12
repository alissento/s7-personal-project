# Homelab cluster — RKE2 (3 masters + 3 workers)

Configuration and bring-up procedure for the Homelab Kubernetes cluster: RKE2 v1.36 on Ubuntu 26.04 VMs in Proxmox, CIS profile, Cilium (with kube-proxy replacement) and a kube-vip virtual IP for the API.

> All IPs, hostnames and domains are **examples** — see [docs/network-plan.md](../docs/network-plan.md) for the full plan and the list of files to update when you change them.

## Files

| File | Goes to | On |
|---|---|---|
| [server.yaml](server.yaml) | `/etc/rancher/rke2/config.yaml` | all masters |
| [server-join.yaml](server-join.yaml) | `/etc/rancher/rke2/config.yaml.d/10-join.yaml` | hl-master-02, hl-master-03 |
| [agent.yaml](agent.yaml) | `/etc/rancher/rke2/config.yaml` | all workers |
| [manifests/rke2-cilium-config.yaml](manifests/rke2-cilium-config.yaml) | `/var/lib/rancher/rke2/server/manifests/` | all masters |
| [manifests/kube-vip.yaml](manifests/kube-vip.yaml) | `/var/lib/rancher/rke2/server/manifests/` | all masters |
| [prepare-node.sh](prepare-node.sh) | run once | all nodes |
| `cluster-token` (not in git) | `/etc/rancher/rke2/cluster-token` | all masters |
| `agent-token` (not in git) | `/etc/rancher/rke2/agent-token` | all nodes |

RKE2 applies every manifest in `/var/lib/rancher/rke2/server/manifests/` automatically and keeps it in sync, which is how Cilium settings and kube-vip get into the cluster without `kubectl apply`.

## Nodes

| Hostname | Role | IP | vCPU | RAM | Disk |
|---|---|---|---|---|---|
| hl-master-01 | server (bootstraps etcd) | 10.10.20.11 | 4 | 8 GB | 60 GB |
| hl-master-02 | server | 10.10.20.12 | 4 | 8 GB | 60 GB |
| hl-master-03 | server | 10.10.20.13 | 4 | 8 GB | 60 GB |
| hl-worker-01 | agent | 10.10.20.21 | 4 | 16 GB | 100 GB |
| hl-worker-02 | agent | 10.10.20.22 | 4 | 16 GB | 100 GB |
| hl-worker-03 | agent | 10.10.20.23 | 4 | 16 GB | 100 GB |
| `api.hl.home.arpa` | kube-vip VIP | 10.10.20.10 | | | |

Total: 24 vCPU, 72 GB RAM. RKE2's minimum is 2 vCPU / 4 GB per node, so masters can shrink to 2/4 if the host is tight. Workers will later get a second disk for persistent storage (Longhorn).

## Bring-up

### 0. Replace the example values

Edit IPs/names in `server.yaml` (`tls-san`), `server-join.yaml`, `agent.yaml`, `manifests/kube-vip.yaml` (`address`, `vip_interface`). Proxmox virtio NICs on Ubuntu are usually `ens18` — confirm with `ip -br addr`.

### 1. Create the VMs (on the Proxmox host)

```bash
TEMPLATE=9000      # VMID of your Ubuntu 26.04 cloud-init template
GW=10.10.20.1
for spec in "211 hl-master-01 10.10.20.11 8192 60G" "212 hl-master-02 10.10.20.12 8192 60G" \
            "213 hl-master-03 10.10.20.13 8192 60G" "221 hl-worker-01 10.10.20.21 16384 100G" \
            "222 hl-worker-02 10.10.20.22 16384 100G" "223 hl-worker-03 10.10.20.23 16384 100G"; do
  read -r id name ip mem disk <<<"$spec"
  qm clone "$TEMPLATE" "$id" --name "$name" --full 1
  qm set "$id" --cores 4 --memory "$mem" --cpu host --agent enabled=1 \
    --ipconfig0 "ip=$ip/24,gw=$GW" --nameserver "$GW" --searchdomain home.arpa \
    --ciuser ubuntu --sshkeys ~/.ssh/id_ed25519.pub
  qm resize "$id" scsi0 "$disk"     # disk may be virtio0 depending on your template
  qm start "$id"
done
```

Template checklist:
- **Unique machine-id per clone** — the template should have an empty `/etc/machine-id` (`truncate -s 0 /etc/machine-id` before converting to a template). Duplicates cause identical DHCP leases and confusing network bugs.
- **Unique hostnames** — Proxmox cloud-init sets the hostname from the VM name. RKE2 rejects a second node with an existing name.
- **SSD/NVMe storage for masters** — etcd is sensitive to disk latency.
- **CPU type `host`** — exposes AES-NI etc. to the VM (matters once WireGuard encryption is on).
- With several Proxmox hosts, put each master on a different host, or a single host failure takes out quorum.

The plan is to replace this loop with OpenTofu later — see [docs/ideas.md](../docs/ideas.md).

### 2. Prepare every node

```bash
scp -r rke2-config ubuntu@10.10.20.11:     # repeat for each node
ssh ubuntu@10.10.20.11
sudo ./rke2-config/prepare-node.sh server   # masters
sudo ./rke2-config/prepare-node.sh agent    # workers
```

The script disables swap, creates the `etcd` user (CIS), installs RKE2 `v1.36.5+rke2r1` without starting it, and applies the CIS kernel parameters.

### 3. Create the join tokens (on your workstation, outside the repo)

```bash
openssl rand -hex 32 > cluster-token
openssl rand -hex 32 > agent-token
```

Copy them to the nodes and lock them down (`sudo chmod 600`, owner root):
- masters: `/etc/rancher/rke2/cluster-token` **and** `/etc/rancher/rke2/agent-token`
- workers: `/etc/rancher/rke2/agent-token` only

> **Back up `cluster-token` somewhere safe (password manager).** It encrypts the cluster's bootstrap data in etcd, so it is required to restore an etcd snapshot. Losing it breaks disaster recovery.

### 4. First master (hl-master-01)

```bash
sudo cp rke2-config/server.yaml /etc/rancher/rke2/config.yaml
sudo cp rke2-config/manifests/*.yaml /var/lib/rancher/rke2/server/manifests/
sudo systemctl enable --now rke2-server     # takes a few minutes the first time
sudo journalctl -u rke2-server -f           # follow progress (Ctrl+C to stop)
```

Check it, as root (`sudo -i`):

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get nodes                          # hl-master-01 Ready
kubectl -n kube-system get pods            # cilium, coredns, kube-vip running
ping -c 3 10.10.20.10                      # the VIP answers
```

### 5. Other masters, one at a time

On hl-master-02, wait until it is `Ready`, then repeat on hl-master-03:

```bash
sudo cp rke2-config/server.yaml /etc/rancher/rke2/config.yaml
sudo cp rke2-config/server-join.yaml /etc/rancher/rke2/config.yaml.d/10-join.yaml
sudo cp rke2-config/manifests/*.yaml /var/lib/rancher/rke2/server/manifests/
sudo systemctl enable --now rke2-server
```

One at a time keeps etcd quorum healthy while members are added.

### 6. Workers

```bash
sudo cp rke2-config/agent.yaml /etc/rancher/rke2/config.yaml
sudo systemctl enable --now rke2-agent
```

Then, from a master: `kubectl label node hl-worker-01 hl-worker-02 hl-worker-03 node-role.kubernetes.io/worker=true`

### 7. Verify

```bash
kubectl get nodes -o wide                                     # 6 nodes Ready
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'   # master holding the VIP
```

VIP failover test: shut down the master holding the VIP. Within ~15 s another master takes it over and `kubectl` through the VIP keeps working.

### 8. Access from your workstation

```bash
ssh ubuntu@10.10.20.11 sudo cat /etc/rancher/rke2/rke2.yaml > ~/.kube/homelab.yaml
sed -i 's/127.0.0.1/10.10.20.10/' ~/.kube/homelab.yaml
chmod 600 ~/.kube/homelab.yaml
export KUBECONFIG=~/.kube/homelab.yaml
```

This kubeconfig is cluster-admin: keep it out of git and do not hand it to tools that don't need it. For Claude Code, use a read-only one ([docs/claude-code-guide.md](../docs/claude-code-guide.md#7-mcp-servers-and-cluster-access)).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `rke2-server` exits right away mentioning CIS/sysctl/etcd user | `prepare-node.sh` not run, or sysctls not applied — rerun it |
| Join fails with "critical configuration value mismatch" | `server.yaml` differs between masters |
| Nodes stay `NotReady` | Cilium not running — `kubectl -n kube-system logs ds/cilium` |
| VIP never answers | wrong `vip_interface` in kube-vip.yaml — `kubectl -n kube-system logs ds/kube-vip-ds` |
| Pods rejected: "violates PodSecurity restricted" | CIS profile default — fix the pod's securityContext (preferred) or relax that namespace's PSA label |
| Something in `kube-system` unreachable from other namespaces | CIS profile's default NetworkPolicies |
| Start over on a node | `sudo /usr/local/bin/rke2-uninstall.sh` |

## Design choices

| Choice | Why |
|---|---|
| CIS profile from day one | Security is the core of the project; switching on Pod Security "restricted" later breaks workloads that were never built for it. It also gives a clean baseline for the kube-bench comparison in the report. |
| Cilium + kube-proxy replacement | eBPF network policies (L3–L7), Hubble flow logs (the "blocked traffic must be visible" requirement), Cluster Mesh for the second site, WireGuard encryption. Set up at install time because swapping CNI later means rebuilding. |
| kube-vip (ARP mode) | HA API endpoint with no extra load-balancer VMs. |
| Tainted masters | 3 dedicated workers exist, so app pods never share a node with etcd — less noise for etcd and less reach for an attacker after a pod compromise. |
| Separate agent token | A leaked worker token cannot be used to join a rogue server and read etcd. |
| Tokens via `token-file` | No secrets in any file in this repo. |
| `secretbox` encryption at rest | Kubernetes docs flag `aescbc` as not recommended (CBC padding-oracle risk). KMS v2 backed by OpenBao/Vault is the stronger target for the hardening phase. |
| Traefik | RKE2 1.36 default; ingress-nginx is end-of-life. Gateway API via Cilium is a later option. |
| etcd snapshots every 6 h, kept 7 days | Control-plane RPO of 6 h locally; off-site S3 copies come in the DR phase. |

Sources (checked 2026-10-12): [RKE2 HA install](https://docs.rke2.io/install/ha) · [Cilium options](https://docs.rke2.io/networking/basic_network_options) · [CIS hardening guide](https://docs.rke2.io/security/hardening_guide) · [server config reference](https://docs.rke2.io/reference/server_config) · [requirements & ports](https://docs.rke2.io/install/requirements) · [RKE2 v1.36 support matrix (Ubuntu 26.04 validated)](https://www.suse.com/suse-rke2/support-matrix/all-supported-versions/rke2-v1-36) · [kube-vip](https://kube-vip.io/docs/)
