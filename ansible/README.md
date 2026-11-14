# Ansible: Homelab node preparation and RKE2

This folder turns five freshly installed Ubuntu 26.04 VMs into an RKE2 Kubernetes cluster (3 masters, 2 workers). Everything is code: running the same playbook again changes only what does not match, so the nodes cannot drift from what is written here.

Status on 2026-11-14: node preparation is done and confirmed on all nodes; RKE2 is installed and configured and the join tokens are in place. Next: the ordered first start (see [What is missing](#9-what-is-missing)).

## Contents

1. [Quick start](#1-quick-start)
2. [Ansible in two minutes](#2-ansible-in-two-minutes)
3. [Folder layout](#3-folder-layout)
4. [Configuration and inventory](#4-configuration-and-inventory)
5. [Playbooks](#5-playbooks)
6. [Role `common`: node preparation](#6-role-common-node-preparation)
7. [Role `rke2`: install and configure](#7-role-rke2-install-and-configure)
8. [Running parts with tags](#8-running-parts-with-tags)
9. [What is missing](#9-what-is-missing)
10. [Troubleshooting](#10-troubleshooting)
11. [Sources](#11-sources)

---

## 1. Quick start

**Prerequisites on the workstation** (WSL, Ubuntu 24.04 here):

| What | Why | How |
|---|---|---|
| ansible-core 2.21+ | runs the playbooks | Ansible PPA: `sudo apt install ansible ansible-core` |
| `community.general` collection | the `lvol` disk module | `ansible-galaxy collection install -r requirements.yml` |
| SSH key `~/.ssh/homelab-ansible` | login to every node; password login is disabled | already on all nodes (`ssh-copy-id`) |
| the key loaded in ssh-agent | the key has a passphrase, and Ansible connects to 5 nodes at once, so it cannot ask for it | `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/homelab-ansible`, or `keychain` (see [Troubleshooting](#10-troubleshooting)) |
| the sudo password of `nknez` | Ansible becomes root with sudo on the nodes | typed at the `BECOME password:` prompt (`-K`) |

**Commands**, always run from inside `ansible/`:

```bash
ansible all -m ping                      # can Ansible reach every node?
ansible-lint && yamllint .               # check the code before running it
ansible-playbook site.yml -K --check     # dry run: show what would change
ansible-playbook site.yml -K             # prepare the nodes and install RKE2; safe to repeat
ansible-playbook upgrade.yml -K          # OS upgrades and reboots, only when you mean to
ansible-playbook workstation.yml -K      # kubectl + kubeconfig on this PC, once the cluster runs
```

`-K` (`--ask-become-pass`) asks for the sudo password. A second run of `site.yml` should end with `changed=0` on every node: that is the proof nothing drifted.

---

## 2. Ansible in two minutes

Ansible connects to each machine over SSH and makes it match a description. Nothing is installed on the nodes besides Python, which Ubuntu already has.

| Term | Meaning | Example here |
|---|---|---|
| **inventory** | the list of machines, in groups | `inventory/homelab/hosts.yml` |
| **variable** | a value used by tasks and templates | `rke2_api_vip: 10.10.10.5` |
| **task** | one action, written as "this should be true" | "this file exists with this content" |
| **module** | the code behind a task | `copy`, `apt`, `template`, `lvol` |
| **role** | a folder of tasks, files and templates for one job | `roles/common`, `roles/rke2` |
| **playbook** | which roles or tasks run on which hosts | `site.yml` |
| **handler** | a task that runs only when another task changed something | restart SSH after its config changed |
| **template** (`.j2`) | a file with `{{ placeholders }}` filled in from variables | `config-server.yaml.j2` |
| **tag** | a label to run one part only | `--tags swap` |
| **become** | run as another user (root), using sudo | `become: true` in `site.yml` |
| **idempotent** | running it twice gives the same result as running it once | second run reports `changed=0` |

Every run ends with a **PLAY RECAP**: per node, `ok` (already correct), `changed` (Ansible fixed it), `failed`, `skipped`. Add `--check --diff` to see changes without making them.

---

## 3. Folder layout

```
ansible/
├── ansible.cfg                    how Ansible behaves (default inventory, host key checks)
├── requirements.yml               extra Ansible collections
├── site.yml                       main playbook: prepare the nodes, install RKE2
├── upgrade.yml                    OS upgrade and reboot, run on purpose only
├── workstation.yml                sets up this PC: kubectl and the admin kubeconfig
├── inventory/
│   └── homelab/                   WHERE and WITH WHICH VALUES
│       ├── hosts.yml              the 5 machines, in groups masters / workers
│       └── group_vars/
│           ├── all.yml            values for every node: login, sudo, cluster settings
│           ├── masters.yml        rke2_type: server
│           └── workers.yml        rke2_type: agent
└── roles/                         HOW: the same for every site
    ├── common/                    generic node preparation
    │   ├── tasks/                 main.yml lists: preflight, ssh, disk, swap, packages
    │   ├── files/                 00-ssh-hardening.conf
    │   └── handlers/              Restart ssh
    └── rke2/                      everything RKE2-specific
        ├── tasks/                 main.yml lists: install, sysctl, config, tokens
        ├── files/                 61-k8s-inotify.conf
        ├── templates/             config-server, config-agent, join, rke2-cilium-config, kube-vip
        └── handlers/              Reload sysctl
```

The split that matters: **roles say how, the inventory says where and with which values.** Roles contain no IP addresses. The EduCloud site will get its own `inventory/educloud/` and reuse the same roles; the site is then chosen with `-i inventory/educloud`.

Inside a role, Ansible finds things by folder name: `tasks/main.yml` runs first, `copy` looks in `files/`, `template` looks in `templates/`, `notify` looks in `handlers/`.

---

## 4. Configuration and inventory

### `ansible.cfg`

Ansible reads this automatically when a command runs from this folder.

| Setting | Effect |
|---|---|
| `inventory = inventory/homelab` | use Homelab when no `-i` is given. Remove it once EduCloud exists, so the site always has to be named. |
| `host_key_checking = True` | refuse to connect if a node's SSH host key changed: protects against someone impersonating a node |
| `interpreter_python = auto_silent` | find Python on the nodes without printing a warning |

### `inventory/homelab/hosts.yml`

| Group | Hosts | IPs |
|---|---|---|
| `masters` | master-01, master-02, master-03 | 10.10.10.10 – .12 |
| `workers` | worker-01, worker-02 | 10.10.10.20, .21 |

The name (`master-01`) is what Ansible and Kubernetes call the node; `ansible_host` is the IP Ansible connects to. The group names are used by the code: `groups['masters'][0]` means "the first master", which is the one that creates the cluster.

### `inventory/homelab/group_vars/`

Files named after a group apply to every host in it, and `all.yml` to every host. Ansible loads them because they sit next to `hosts.yml`. [docs/network-plan.md](../docs/network-plan.md) explains the network values and lists every file they appear in.

**`all.yml`: login**

| Variable | Value | Why |
|---|---|---|
| `ansible_user` | `nknez` | the login user on every node |
| `ansible_ssh_private_key_file` | `~/.ssh/homelab-ansible` | key-only login (password login is disabled by `roles/common`) |
| `ansible_become_exe` | `sudo.ws` | Ubuntu 26.04 uses sudo-rs, whose password prompt Ansible does not recognise yet, so become times out ([Launchpad bug 2122414](https://bugs.launchpad.net/ubuntu/+source/ansible-core/+bug/2122414)). `sudo.ws` is the classic sudo, still installed next to it. |

**`all.yml`: cluster**

| Variable | Value | Used for |
|---|---|---|
| `rke2_version` | `v1.36.5+rke2r1` | the RKE2 release to install (checked 2026-11-06) |
| `rke2_api_vip` | `10.10.10.5` | the floating API address, held by one master at a time (kube-vip) |
| `rke2_api_hostname` | `api.hl.home.arpa` | extra name on the API certificate; no DNS record yet |
| `rke2_node_interface` | `ens18` | the NIC kube-vip puts the VIP on; also checked by preflight |
| `rke2_node_region` | `homelab` | label `topology.kubernetes.io/region` on every node, to tell the sites apart |
| `kube_vip_version` | `v1.3.1` | kube-vip image version |
| `rke2_cluster_cidr` | `10.42.0.0/16` | pod IPs; must stay unique per site |
| `rke2_service_cidr` | `10.43.0.0/16` | service IPs; unique per site |
| `rke2_cluster_dns` | `10.43.0.10` | the DNS service IP, inside the service range |
| `cilium_cluster_name` / `cilium_cluster_id` | `homelab` / `1` | unique per cluster; changing the ID later restarts every pod |

**`masters.yml` / `workers.yml`**: one variable, `rke2_type` (`server` or `agent`). The RKE2 role uses it to pick the install type, the config template and whether master-only steps run.

---

## 5. Playbooks

### `site.yml`: the main playbook

Four plays, in order:

| Play | Hosts | Does |
|---|---|---|
| Prepare all nodes and install RKE2 | all | role `common`, then role `rke2` (install, kernel settings, config, tokens) |
| Start the first master | master-01 | start RKE2, which creates the cluster; wait for the VIP and for the node to be Ready |
| Join the other masters | master-02, master-03, one at a time (`serial: 1`) | start RKE2, wait until Ready |
| Join the workers | worker-01, worker-02, one at a time | start RKE2, wait until Ready, add the worker role label |

This is the one to run whenever something in the roles or variables changes. It never reboots a node and never restarts RKE2: starting an already running service changes nothing.

### `upgrade.yml`: OS upgrades, on purpose only

Upgrades every package (`apt dist-upgrade`, which includes new kernels), removes unneeded packages, and reboots a node only if Ubuntu asks for it (`/var/run/reboot-required`). `serial: 1` finishes one node, reboot included, before touching the next, and stops if that node fails.

It is separate from `site.yml` so that a routine run can never reboot nodes. **Not safe on a running cluster yet:** it does not drain a node (move its pods away) before rebooting or wait for it to be Ready afterwards.

### `workstation.yml`: this PC

Two plays:
1. On master-01: read `/etc/rancher/rke2/rke2.yaml`, the admin kubeconfig RKE2 writes once it runs. `no_log` keeps it out of the output.
2. On this PC (`localhost`): install `kubectl` at the cluster's Kubernetes version (download checked against the published SHA-256), save the kubeconfig as `~/.kube/homelab.yaml` with `127.0.0.1` replaced by the VIP, and add `export KUBECONFIG=~/.kube/homelab.yaml` to `~/.bashrc`.

`--tags kubectl` installs only kubectl and needs neither the cluster nor sudo. The kubeconfig is full cluster-admin: it stays out of Git (see `.gitignore`).

### `cis-scan.yml`: CIS benchmark scan

Runs [kube-bench](https://github.com/aquasecurity/kube-bench) on every node against the CIS Kubernetes Benchmark for RKE2 and saves the results in `docs/lab/cis/<date>/` (a `.txt` per node to read, a `.json` for the numbers). Run it on the fresh cluster as the baseline, then after each hardening step, and compare the totals (PASS / FAIL / WARN).

| Node | Sections checked |
|---|---|
| master-01 | control plane, etcd, kubelet, and the cluster-wide policies (RBAC, Pod Security, network policies) |
| master-02, master-03 | control plane, etcd, kubelet |
| workers | kubelet |

The download is checked against the release's checksum file; the only change on the nodes is kube-bench unpacked into `/opt`. kube-bench v0.16.0's newest RKE2 profile is `rke2-cis-1.9`, which was written for older Kubernetes versions than 1.36: some results may reflect that, and the report should name the profile used.

---

## 6. Role `common`: node preparation

Generic preparation that any Linux server in this project gets. `tasks/main.yml` only lists the parts in order, each with a tag.

### `preflight` (`tasks/preflight.yml`)

Read-only checks that stop the run early when a node does not match the plan. Safe to repeat.

| Check | Why |
|---|---|
| hostname equals the inventory name | RKE2 rejects a second node with the same name |
| the node has its planned IP on `ens18` | catches a VM with the wrong network config |
| the clock is NTP-synchronised (waits up to 60 s) | etcd and TLS certificates break when clocks differ |
| ufw is off | ufw would silently block cluster ports; if it is ever turned on, open the ports in the network plan first |

### `ssh` (`tasks/ssh.yml`, `files/00-ssh-hardening.conf`)

Copies an SSH config drop-in to `/etc/ssh/sshd_config.d/`:

| Setting | Effect |
|---|---|
| `PasswordAuthentication no`, `KbdInteractiveAuthentication no` | key-only login |
| `PermitRootLogin no` | log in as `nknez`, then sudo |
| `AllowUsers nknez` | no other account can log in over SSH |
| `MaxAuthTries 3` | fewer guesses per connection |
| `X11Forwarding no` | no graphical forwarding (not needed) |

- `validate: sshd -t -f %s` tests the file **before** installing it, so a typo cannot lock anyone out.
- The name starts with `00-` because sshd keeps the first value it reads for a setting, and drop-ins are read alphabetically.
- The `Restart ssh` handler runs only when the file changed.
- Break-glass access if SSH ever fails: the Proxmox console, which still accepts the password.

### `disk` (`tasks/disk.yml`)

The Ubuntu installer put `/` on LVM but used only 19 of the 38 GB in the volume group. `community.general.lvol` grows `ubuntu-vg/ubuntu-lv` into all free space and `resizefs` grows the ext4 filesystem with it, online. Once there is no free space left, it does nothing.

### `swap` (`tasks/swap.yml`)

The kubelet refuses to run with swap on: Kubernetes plans memory per pod and expects RAM to be RAM.
1. `swapoff -a`, only if facts show swap is on.
2. Comment out swap lines in `/etc/fstab`, so it stays off after a reboot.
3. Delete `/swap.img` (about 4 GB back).

### `packages` (`tasks/packages.yml`)

Installs what is missing: `curl` (used by the RKE2 install script) and `qemu-guest-agent` (Proxmox can see the VM's IP and shut it down cleanly), then starts the agent. That start fails if the VM's **QEMU Guest Agent** option is off in Proxmox. Upgrades live in `upgrade.yml`, never here.

---

## 7. Role `rke2`: install and configure

RKE2 is Rancher's Kubernetes distribution, built for security-focused environments (CIS-hardened defaults). Every node runs one service: `rke2-server` on masters (control plane + etcd) or `rke2-agent` on workers. **Nothing in this role starts RKE2.**

### `rke2-install` (`tasks/install.yml`)

| Step | Where | Why |
|---|---|---|
| create the `etcd` group and user | masters | the CIS profile runs etcd as this user and refuses to start without it |
| download `https://get.rke2.io` to `/root/rke2-install.sh` | all | the official install script |
| run it with `INSTALL_RKE2_VERSION` and `INSTALL_RKE2_TYPE` | all | installs the pinned version (server or agent) to `/usr/local` and verifies the download's SHA-256; does not start anything |
| create `/etc/rancher/rke2/` and `config.yaml.d/` | all | where the config goes |
| create `/var/lib/rancher/rke2/server/manifests/` | masters | RKE2 applies every YAML file in this folder by itself, so Cilium and kube-vip settings must be there before the first start |

`creates: /usr/local/bin/rke2` makes the install run only once. **Changing `rke2_version` does not upgrade a running cluster**; upgrades will go through RKE2's system-upgrade-controller.

### `rke2-sysctl` (`tasks/sysctl.yml`)

- Copies `/usr/local/share/rke2/rke2-cis-sysctl.conf`, which comes with RKE2, to `/etc/sysctl.d/60-rke2-cis.conf`. With the CIS profile the kubelet refuses to start unless these kernel settings match. This is why it runs after the install.
- Adds `files/61-k8s-inotify.conf`: higher file-watch limits, which Ubuntu's defaults run out of with many pods.
- The `Reload sysctl` handler applies both.

### `rke2-config` (`tasks/config.yml`)

Writes the config files from templates. There is deliberately **no restart handler**: changing the config of a running cluster should be a planned restart, one node at a time, not a side effect of a playbook run.

| Template | Written to | On |
|---|---|---|
| `config-server.yaml.j2` | `/etc/rancher/rke2/config.yaml` | masters |
| `config-agent.yaml.j2` | `/etc/rancher/rke2/config.yaml` | workers |
| `join.yaml.j2` | `/etc/rancher/rke2/config.yaml.d/10-join.yaml` | master-02, master-03 |
| `rke2-cilium-config.yaml.j2` | `/var/lib/rancher/rke2/server/manifests/` | masters |
| `kube-vip.yaml.j2` | `/var/lib/rancher/rke2/server/manifests/` | masters |

#### The server config (`config-server.yaml.j2`)

Every master gets the same file: RKE2 refuses to join a server whose cluster-wide settings differ from the others.

| Section | Settings | Meaning |
|---|---|---|
| Join secrets | `token-file`, `agent-token-file` | masters join with the cluster token, workers with a separate agent token, so a stolen worker token cannot add a fake master. The tokens are files on the node, never in this repo. |
| API endpoint | `tls-san`: the VIP and `api.hl.home.arpa`; `write-kubeconfig-mode: "0600"` | the API certificate is valid for the VIP, so `kubectl` through it is trusted; the admin kubeconfig is root-only |
| Networking | `cni: cilium`, `disable-kube-proxy: true`, the three ranges, `ingress-controller: traefik` | Cilium is the network plugin and replaces kube-proxy with eBPF; Traefik is RKE2's default ingress since v1.36 |
| Hardening | `profile: cis`, `secrets-encryption-provider: secretbox` | CIS mode: Pod Security "restricted" outside system namespaces, default NetworkPolicies, host checks at startup. Kubernetes Secrets are encrypted inside etcd with secretbox (the docs advise against the aescbc default). |
| Placement | `node-taint: CriticalAddonsOnly=true:NoExecute`, region label | only system components (Cilium, CoreDNS, kube-vip) run on masters, so applications never share a node with etcd |
| Backups | snapshot every 6 h, keep 28 | 7 days of local etcd snapshots on each master; off-site copies come in the disaster-recovery phase |

#### The agent config (`config-agent.yaml.j2`)

`server: https://10.10.10.5:9345` (join through the VIP on the RKE2 supervisor port), `token-file` pointing at the **agent** token, `profile: cis` (same host checks), and the region label.

#### The join file (`join.yaml.j2`)

One line, `server: https://10.10.10.5:9345`, on every master except the first. RKE2 reads `config.yaml` and then `config.yaml.d/*.yaml`, so this adds "join the existing cluster instead of creating a new one" without making the main config differ between masters.

#### Cilium (`rke2-cilium-config.yaml.j2`)

A `HelmChartConfig` that overrides the Cilium chart bundled with RKE2:

| Value | Why |
|---|---|
| `kubeProxyReplacement: true` | Cilium handles Services with eBPF (kube-proxy is disabled) |
| `k8sServiceHost: localhost`, port 6443 | Cilium reaches the API through the node itself, **not** the VIP: kube-vip needs working networking before the VIP exists, so the VIP would deadlock the first boot |
| `ipam.mode: kubernetes` | pod IPs come from `10.42.0.0/16`, one /24 per node (Cilium's own default, 10.0.0.0/8, would overlap the node network) |
| `cluster.name` / `cluster.id` | unique per cluster, set from the start |
| `operator.tolerations` (chart defaults + `CriticalAddonsOnly`) | the masters' `CriticalAddonsOnly` taint is not in the operator's default tolerations (rke2-cilium 1.20.200). Without the operator the agent waits forever for its CRDs, Service IPs never work, and kube-vip cannot reach the API to claim the VIP. Found on the first start, 2026-11-14. |
| `hubble`, relay and UI enabled | see which pod talked to which, and what a policy dropped |

#### kube-vip (`kube-vip.yaml.j2`)

A DaemonSet on the masters (with its ServiceAccount and RBAC). The masters hold a leader election over a Kubernetes lease (`plndr-cp-lock`); the leader answers ARP for `10.10.10.5` on `ens18`. If it goes down, another master takes over within about 15 seconds. Result: one address for the API (6443) and the join port (9345) that survives a master failure. It is used only for the control plane, not for LoadBalancer Services.

### `rke2-tokens` (`tasks/tokens.yml`)

RKE2 nodes prove they belong to the cluster with a shared secret, the **join token**. There are two:

| Token | File on the node | Who gets it | Used for |
|---|---|---|---|
| cluster token | `/etc/rancher/rke2/cluster-token` | masters | joining as a server; also encrypts the cluster's bootstrap data in etcd, so **restoring an etcd snapshot needs the original** |
| agent token | `/etc/rancher/rke2/agent-token` | all nodes | workers join with it; masters need it to accept them. A stolen agent token cannot join a server. |

They are created **once, by hand**, on the workstation in `ansible/secrets/homelab/` (gitignored, path in `rke2_token_dir`), and backed up in a password manager:

```bash
mkdir -p secrets/homelab && chmod 700 secrets secrets/homelab
(umask 077; openssl rand -hex 32 > secrets/homelab/cluster-token; openssl rand -hex 32 > secrets/homelab/agent-token)
```

The tasks check that both files exist and stop if not, then copy them to the nodes as root-only files (`0600`). Ansible deliberately never generates them: a fresh checkout without the folder would otherwise push new tokens to a running cluster and break it. `diff: false` keeps the token out of the output when running with `--diff`.

### Starting: `tasks/start.yml`

Not listed in the role's `main.yml`: `site.yml` imports it in three ordered plays (see [Playbooks](#5-playbooks)), so each node starts only after the previous one is Ready.

| Task | Why |
|---|---|
| start and enable `rke2-server` / `rke2-agent` | the first start downloads images and takes a few minutes; systemd waits until RKE2 reports ready |
| on master-01: wait until the VIP answers on 9345 | the other nodes join through the VIP; kube-vip only runs once Cilium is up |
| wait until the node reports `Ready` (asked on master-01, up to 10 minutes) | a node is Ready once its kubelet runs and Cilium has set up its networking |
| on workers: add the label `node-role.kubernetes.io/worker=true` | the kubelet may not set role labels on itself, so it is set through the API |

The wait tasks are skipped in `--check` mode, since nothing actually starts there.

---

## 8. Running parts with tags

| Tag | Runs |
|---|---|
| `preflight` | the read-only checks |
| `ssh` | SSH hardening |
| `disk` | grow the root volume |
| `swap` | swap off |
| `packages` | base packages |
| `rke2-install` | etcd user, RKE2 install, folders |
| `rke2-sysctl` | kernel settings |
| `rke2-config` | config files and manifests |
| `rke2-tokens` | copy the join tokens to the nodes |
| `rke2-start` | the three start plays (combine with `--limit` to start one node) |

```bash
ansible-playbook site.yml -K --tags swap              # one part
ansible-playbook site.yml -K --tags rke2-config --check --diff   # preview config changes
ansible-playbook site.yml --list-tasks                # show every task and its tags
```

---

## 9. What is missing

Before the cluster can start:

1. **Ordered first start** (`--tags rke2-start`): master-01 first, until it is Ready and the VIP answers; then master-02 and master-03 one at a time (keeps etcd quorum healthy); then the workers.
2. **Verification.** 5 nodes Ready, Cilium healthy, VIP failover tested, then `workstation.yml` and a kube-bench baseline.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ssh_askpass: exec(/usr/bin/ssh-askpass): No such file or directory` … `Permission denied (publickey)` on every node | the key has a passphrase and is not loaded in an ssh-agent | `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/homelab-ansible`. Permanent: `sudo apt install keychain` and add `eval "$(keychain --eval --quiet homelab-ansible)"` to `~/.bashrc` |
| `Timeout waiting for privilege escalation prompt` | sudo-rs on Ubuntu 26.04 | `ansible_become_exe: sudo.ws` in `group_vars/all.yml` (already set) |
| `BECOME password:` prompt | `-K` asks for `nknez`'s sudo password on the nodes | type it; it is the same password as on the Proxmox console |
| `Start the guest agent` fails | the VM's **QEMU Guest Agent** option is off in Proxmox | enable it under VM → Options, then stop and start the VM |
| a preflight assertion fails | the node does not match the plan (name, IP, clock, ufw) | the message says what differs; fix the node or the inventory |
| the second run still shows `changed` | something is not idempotent or keeps drifting | run with `--diff` to see what changes each time |

---

## 11. Sources

Checked 2026-11-14 unless noted.

- Ansible: [inventory](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html) · [roles](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html) · [handlers](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html) · [tags](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_tags.html) · [check mode](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_checkmode.html)
- RKE2: [server configuration reference](https://docs.rke2.io/reference/server_config) · [agent configuration reference](https://docs.rke2.io/reference/linux_agent_config) · [CIS hardening guide](https://docs.rke2.io/security/hardening_guide) · [HA install](https://docs.rke2.io/install/ha) · [network options (Cilium)](https://docs.rke2.io/networking/basic_network_options)
- [kube-vip documentation](https://kube-vip.io/docs/)
- [Launchpad bug 2122414: Ansible times out after BECOME password request (sudo-rs)](https://bugs.launchpad.net/ubuntu/+source/ansible-core/+bug/2122414) (checked 2026-11-02)
- Network values: [docs/network-plan.md](../docs/network-plan.md) · design decisions: [docs/ideas.md](../docs/ideas.md)
