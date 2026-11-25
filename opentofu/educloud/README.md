# OpenTofu: EduCloud network and VMs

This folder will describe everything the project needs in EduCloud (the school cloud, running Apache CloudStack 4.22.1.1) as code: the network and the 7 VMs from [docs/network-plan.md](../../docs/network-plan.md). OpenTofu compares this description with what exists in EduCloud and creates, changes or deletes only the difference.

Status on 2026-11-17:
- **3a** done: the provider connects to EduCloud and looks up the zone, the Ubuntu image and the offerings.
- **3b** done, applied 2026-11-15: the VPC with its three tiers and network ACLs ([section 5](#5-network-networktf)).
- **3c** done, applied 2026-11-17: the 7 VMs and their first-boot setup ([section 6](#6-vms-and-admin-access-instancestf-cloud-inityamltftpl)).
- Added 2026-11-25, not applied yet: rule 130 of tier `nodes`, TCP 443 from the NetBird gateway, so apps behind the cluster's ingress (Traefik on the workers, first Kaneo) can be reached over NetBird.
- Admin access goes through NetBird (`ec-gw-01` is the routing peer, set up by Ansible: [ansible/README.md](../../ansible/README.md), section 8). The temporary SSH port forward used to bootstrap it was removed on 2026-11-17.
- Later, with the Homelab gateway: the VPC static route to Homelab and the cross-site ACL rules.

## 1. Quick start

**Prerequisites on the workstation:**

| What | Version (checked 2026-11-14) | Why |
|---|---|---|
| OpenTofu (`tofu`) | 1.13.9, from the official apt repository, `apt-mark hold` | runs this code |
| CloudMonkey (`cmk`) | 6.6.0, SHA-256 checked against the release notes | CloudStack's CLI, for looking things up by hand |
| EduCloud API keys | — | generated in the EduCloud UI (your profile → *Generate keys*); they can do anything your account can |
| `~/.config/educloud/cloudstack.env` | — | the keys, the state passphrase and the sudo password hash as environment variables, outside the repo, mode `0600` |
| SSH key `~/.ssh/educloud-ansible` | ed25519, with a passphrase | login to every EduCloud VM. A separate key from Homelab's, so a key leaked at one site does not open the other |

**One-time setup of the env file** (`read -s` keeps the values off the screen and out of the shell history):

```bash
mkdir -p ~/.config/educloud && chmod 700 ~/.config/educloud
read -rp  'API URL: ' url; read -rsp 'API key: ' key; echo; read -rsp 'Secret key: ' secret; echo
(umask 077; printf "export CLOUDSTACK_API_URL='%s'\nexport CLOUDSTACK_API_KEY='%s'\nexport CLOUDSTACK_SECRET_KEY='%s'\n" \
  "$url" "$key" "$secret" > ~/.config/educloud/cloudstack.env)
unset url key secret

# the passphrase that encrypts the state, at least 16 characters (OpenTofu's minimum)
# either generated (44 random characters) ...
(umask 077; printf "export TF_VAR_state_passphrase='%s'\n" "$(openssl rand -base64 33)" >> ~/.config/educloud/cloudstack.env)
# ... or chosen: several unrelated words, e.g. word-lamp-orbit-tulip (no single quote in it)
read -rsp 'State passphrase: ' p; echo
(umask 077; printf "export TF_VAR_state_passphrase='%s'\n" "$p" >> ~/.config/educloud/cloudstack.env); unset p
```

The passphrase is the only protection of a copied state file, and it can be guessed offline at any speed, so a single word, even repeated, is too weak. Keep it in a password manager. **Without it the state cannot be read.** The VMs keep running, but OpenTofu would no longer know they are its own.

**The SSH key** for the VMs. Only the public half (`.pub`) is read by OpenTofu:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/educloud-ansible -C educloud-ansible   # set a passphrase
ssh-add ~/.ssh/educloud-ansible
```

**The sudo password** of the admin user on the VMs, as a hash. `openssl` asks for the password twice and prints only the hash, which goes straight into the env file:

```bash
(umask 077; printf "export TF_VAR_sudo_password_hash='%s'\n" "$(openssl passwd -6)" >> ~/.config/educloud/cloudstack.env)
```

Keep the password in a password manager: Ansible asks for it (`-K`), and it is the login on the CloudStack console if SSH ever fails.

**Commands**, always run from inside `opentofu/educloud/`:

```bash
source ~/.config/educloud/cloudstack.env   # once per terminal: keys + passphrase
tofu init        # download the provider (first time, or after a version change)
tofu fmt -check  # formatting
tofu validate    # syntax and references, without contacting EduCloud
tofu plan        # what would change in EduCloud; changes nothing
tofu apply       # make the changes, after showing the plan and asking "yes"
```

## 2. Files

| File | Contents |
|---|---|
| `versions.tf` | required OpenTofu (1.13.x) and provider (`cloudstack/cloudstack` 0.7.0) versions; state and plan encryption |
| `providers.tf` | the CloudStack provider, empty on purpose: credentials come from the environment |
| `variables.tf` | `state_passphrase` (sensitive, ephemeral); `ssh_public_key_file`; `sudo_password_hash` (sensitive) |
| `data.tf` | look-ups: zone, template, compute offerings, VPC and tier offerings |
| `network.tf` | the VPC, its three tiers, one network ACL per tier and their rules |
| `instances.tf` | the 7 VMs: name, tier, fixed IP and size |
| `cloud-init.yaml.tftpl` | first-boot setup of every VM: the admin user, its SSH key and sudo password |
| `outputs.tf` | prints what the look-ups found, the VPC's public IP, the tier IDs and the VM IPs |
| `.terraform.lock.hcl` | written by `tofu init`: the exact provider version and its checksums. **Committed**, so every `init` gets the same, verified provider |

Not in Git (see `.gitignore`): `.terraform/` (the downloaded provider), `terraform.tfstate*` (the state), `*.tfvars`.

## 3. OpenTofu for Terraform users

OpenTofu is the open-source (MPL 2.0) fork of Terraform, made after HashiCorp moved Terraform to the BSL licence in 2023. It is a Linux Foundation project. The language (HCL), the workflow (`init` / `plan` / `apply`) and the providers are the same. The differences that matter here:

| | Terraform | OpenTofu (this folder) |
|---|---|---|
| Command | `terraform` | `tofu` |
| Provider registry | registry.terraform.io | registry.opentofu.org; `source = "cloudstack/cloudstack"` resolves there |
| The `terraform { }` block | — | keeps its name for compatibility |
| State encryption | not built in; the state is plain JSON, protected only by the backend | **built in**: the `encryption` block in `versions.tf` |
| Variables in the `terraform { }` block | not allowed | allowed (early evaluation), which is how the passphrase reaches the encryption block |

## 4. State and its encryption

The **state** (`terraform.tfstate`, in this folder) is OpenTofu's record of what it created: every resource's ID and attributes. Once VMs exist it holds their IPs, the SSH public key and the network layout. It is gitignored. It is also **encrypted**:

- the key is derived from `TF_VAR_state_passphrase` with PBKDF2, and the state is encrypted with AES-GCM;
- `enforced = true` makes OpenTofu refuse to write an unencrypted state or plan file, even if the encryption settings are ever removed;
- the variable is `ephemeral`, so the passphrase itself is never stored, not even in a saved plan file (`tofu plan -out`).

What an encrypted state looks like: `head -c 200 terraform.tfstate` shows `serial`, `lineage`, a `meta` entry and `encrypted_data`, with no resource details in plain text. Tested on 2026-11-14 with OpenTofu 1.13.9: a wrong passphrase fails with "decryption failed".

The state is stored locally, so it lives on this PC only. Because it is encrypted, a copy can be kept anywhere (cloud drive, USB stick). A remote backend (S3) is a later improvement.

## 5. Network (`network.tf`)

One VPC with three tiers. The addresses, the rule summary and the reasons for this design are in [docs/network-plan.md](../../docs/network-plan.md#educloud-network-and-vms).

| Resource | Count | What it is |
|---|---|---|
| `cloudstack_vpc.educloud` | 1 | the VPC 10.10.30.0/23. CloudStack starts its virtual router (VR) and gives it a public source NAT IP (shown in the `vpc` output) |
| `cloudstack_network_acl.tier` | 3 | an empty ACL per tier (`ec-nodes`, `ec-edge`, `ec-mgmt`) |
| `cloudstack_network.tier` | 3 | the tiers, each attached to its ACL |
| `cloudstack_network_acl_ruleset.<tier>` | 3 | the rules of each ACL (`<tier>` is `nodes`, `edge` or `mgmt`) |

`for_each` creates one ACL and one tier per entry of `local.tiers`. The rules are three separate resources because they differ per tier and are easier to review side by side.

How CloudStack's network ACLs behave, and so how to read `network.tf`:
- rules are checked from the lowest number up, and the first match decides. Numbering here: `1xx` ingress allow, `199` ingress deny all, `5xx` egress allow, `599` egress deny all;
- they are stateful: replies to an allowed connection always get back;
- a new ACL denies unmatched ingress but **allows** unmatched egress, hence the explicit `599` rule;
- for egress rules the CIDR is the destination and the source is the whole tier, so a rule cannot be limited to one VM. This is why the gateway and Rancher have their own tiers;
- traffic between VMs in the same tier does not pass the VR and is not filtered (host firewalls or Cilium host policies can cover that later);
- the rules filter by port and CIDR, not by domain name: "443 to anywhere" means any HTTPS server. Name-based egress control comes later, inside the clusters (Cilium `toFQDNs`).

`managed = true` on each ruleset: a rule added by hand (in the EduCloud UI or with `cmk`) is deleted on the next `apply`, so the ACLs cannot drift from this file.

## 6. VMs and admin access (`instances.tf`, `cloud-init.yaml.tftpl`)

### The VMs

| VM | Tier | IP | Offering (vCPU / RAM / root disk) |
|---|---|---|---|
| `ec-master-01` … `03` | `nodes` | 10.10.30.10 – .12 | Small Instance ++ (2 / 6 GiB / 40 GB) |
| `ec-worker-01`, `02` | `nodes` | 10.10.30.20, .21 | Small Instance ++ (2 / 6 GiB / 40 GB) |
| `ec-gw-01` | `edge` | 10.10.31.30 | Small Instance (1 / 1 GiB / 10 GB) |
| `ec-rancher-01` | `mgmt` | 10.10.31.40 | Medium Instance (2 / 8 GiB / 50 GB) |

`local.vms` in `instances.tf` is the list; `for_each` creates one `cloudstack_instance` per entry, so adding a node is one line. The VMs differ only in name, tier, IP and size.

- **Fixed IPs:** CloudStack's DHCP, on the virtual router, always gives a VM the address written here.
- **`expunge = true`:** a destroyed VM is deleted at once. Without it, it stays in CloudStack's recycle bin and keeps counting against the quota.
- OpenTofu creates empty machines only. Rancher and RKE2 are installed afterwards (Ansible, then Rancher).

### First boot (`cloud-init.yaml.tftpl`)

The Ubuntu cloud image contains [cloud-init](https://cloudinit.readthedocs.io/), which fetches this file from CloudStack on the first boot and applies it once. `templatefile()` fills in the three values. It does only what is needed to let Ansible in:

| Setting | Effect |
|---|---|
| `users:` with one entry, `nknez`, and no `default` | the image's standard `ubuntu` user is never created. `nknez` is the user the Ansible `common` role allows over SSH (`AllowUsers`) |
| `ssh_authorized_keys` | the public key from `~/.ssh/educloud-ansible.pub` |
| `groups: [sudo]`, `passwd` (a hash), `lock_passwd: false` | sudo asks for the password, like on Homelab: a stolen SSH key alone is not root |
| `ssh_pwauth: false` | SSH accepts keys only, from the first boot on |
| `disable_root: true` | no root login over SSH |

Limits to know:
- cloud-init runs this **once**. Changing the file later does not change existing VMs; replace a VM on purpose with `tofu apply -replace='cloudstack_instance.vm["ec-worker-02"]'`.
- Any process on a VM can read this file from CloudStack's metadata service, so it holds only a public key and a password **hash**. Never put a token or a private key in it.

### Admin access: through NetBird

No VM is reachable from the internet, and EduCloud could not offer that anyway: its additional "public" IPs are private addresses (10.52.x, 10.53.x) that only the school network and its VPN can reach. Only the VPC's source NAT IP, used for outbound traffic, is on the internet.

Access goes through [NetBird](https://netbird.io): `ec-gw-01` runs the NetBird client as a **routing peer** for the VPC (10.10.30.0/23), and the admin's PC runs the client too. Both only dial out. A NetBird policy lets the admin reach the VPC on TCP 22, 443 and 6443 (its source is still `All` on 2026-11-18, to be narrowed to an `Admins` group: [network plan](../../docs/network-plan.md#cross-site-traffic)); the gateway forwards that traffic with its own address (masquerade), which is what the `nodes` and `mgmt` ACLs allow. The Ansible role and the dashboard objects are described in [ansible/README.md](../../ansible/README.md), section 8.

With NetBird connected, the VMs are reached at their own addresses. `~/.ssh/config`:

```
Host ec-gw-01
    HostName 10.10.31.30
Host ec-master-01
    HostName 10.10.30.10
Host ec-master-02
    HostName 10.10.30.11
Host ec-master-03
    HostName 10.10.30.12
Host ec-worker-01
    HostName 10.10.30.20
Host ec-worker-02
    HostName 10.10.30.21
Host ec-rancher-01
    HostName 10.10.31.40

Host ec-* 10.10.30.* 10.10.31.*
    User nknez
    IdentityFile ~/.ssh/educloud-ansible
    IdentitiesOnly yes
```

The IP patterns are what Ansible needs: it connects to the IPs, and its inventory names no key, so this block decides which key it uses. On the laptop the key is `~/.ssh/educloud-laptop`; the whole key setup (agent, host keys) is in [ansible/README.md](../../ansible/README.md#ssh-keys).

Break-glass, if NetBird is down: the VM console in the EduCloud web UI, with the admin user's password.

How it was bootstrapped (2026-11-17): before NetBird ran, a temporary port forward (TCP 22 on a 10.53.x address, reachable over the school VPN) led to `ec-gw-01`, which also served as SSH jump host. It was removed once NetBird worked.

### Verified on the VMs (2026-11-17)

- cloud-init finished on first boot: user `nknez`, key-only SSH, no `ubuntu` user. Its status is "degraded" because of two harmless warnings (no default user to give CloudStack's generated password to; a DHCP probe during boot).
- NIC `ens3`; root filesystem directly on `/dev/vda1` (no LVM), grown to the offering's disk size.
- The clock synchronises only with TCP 4460 open (section 5).

## 7. Look-ups (`data.tf`)

What `cmk` found on 2026-11-14, and what each look-up must return:

| Look-up | Filter | Expected |
|---|---|---|
| zone | `^Eindhoven-Zone$` | `a2b7478e-f708-44c6-b06a-f24c90d72afe` (the only zone) |
| template | ID `4c696cd0-d745-45b6-8650-752a3467dab3` | "Ubuntu 26.04 LTS Cloud (Resolute Raccoon)", created 2026-05-14, virtio disk and NIC |
| offering `node` | `^Small Instance \+\+$` | 2 vCPU, 6 GiB, 40 GB root (masters and workers) |
| offering `gateway` | `^Small Instance$` | 1 vCPU, 1 GiB, 10 GB root (NetBird gateway) |
| offering `rancher` | `^Medium Instance$` | 2 vCPU, 8 GiB, 50 GB root |
| VPC offering | `^Default VPC offering$` | one virtual router for all tiers, with network ACLs |
| tier offering | `^DefaultIsolatedNetworkOfferingForVpcNetworksNoLB$` | egress denied by default; no CloudStack load balancer |

Sizing: 5 × 6 + 1 + 8 = **39 of the 40 GiB RAM quota**. 13 of 40 vCPU, 260 of 400 GB storage.

Two provider behaviours to know (provider v0.7.0 source code):
- every filter value is a **regular expression**, so they are anchored with `^…$`: `Small Instance` alone would also match `Small Instance +` and `Small Instance ++`;
- when several items match, the provider **silently picks the newest**. A loose template filter would pick the newer "Ubuntu 26.0.4 …" template, whose description says it has a `ubuntu/ubuntu` login baked in. That is why the template is pinned by ID: a new upload with the same name must not replace the VMs.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `tofu` asks for `var.state_passphrase` or `var.sudo_password_hash` | the env file is not loaded in this terminal, or the line is missing | `source ~/.config/educloud/cloudstack.env` |
| `ssh_public_key_file must exist and be an SSH PUBLIC key` | the key pair does not exist yet, or the path points at the private key | `ssh-keygen` (section 1); the variable takes the `.pub` file |
| `ssh ec-gw-01` times out | NetBird is not connected on the PC, or its login session expired | `netbird status` and `netbird networks list` on the PC: the network 10.10.30.0/23 must be listed. On the gateway (via the console): `sudo systemctl restart netbird` |
| `Permission denied (publickey)` | the key is not loaded, or cloud-init failed on the VM | `ssh-add ~/.ssh/educloud-ansible`; otherwise log in on the CloudStack console and read `cloud-init status --long` |
| `passphrase is too short (minimum 16 characters)` | OpenTofu's own minimum for pbkdf2 | use the generated passphrase |
| `decryption failed for all provided methods` | wrong passphrase for an existing state | take the one from the password manager |
| `No … is matching with the specified regex` | the name or ID no longer exists in EduCloud | check with `cmk list templates templatefilter=executable keyword=ubuntu` (or `serviceofferings`, ...) |
| provider error about the API URL or keys | the `CLOUDSTACK_*` variables are missing or wrong | `source` the env file; test the keys with `cmk list zones` |

## 9. Sources

Checked 2026-11-14.

- OpenTofu: [install on Debian/Ubuntu](https://opentofu.org/docs/intro/install/deb/) · [state and plan encryption](https://opentofu.org/docs/language/state/encryption/) · [releases](https://github.com/opentofu/opentofu/releases)
- CloudStack provider: [v0.7.0 docs](https://github.com/apache/cloudstack-terraform-provider/tree/v0.7.0/website/docs) · [provider configuration](https://github.com/apache/cloudstack-terraform-provider/blob/v0.7.0/website/docs/index.html.markdown)
- [CloudMonkey 6.6.0 release](https://github.com/apache/cloudstack-cloudmonkey/releases)
- CloudStack 4.22: [guest traffic and egress rules](http://docs.cloudstack.apache.org/en/4.22.0.1/adminguide/networking_and_traffic.html) · [VPC and network ACLs](https://docs.cloudstack.apache.org/en/latest/adminguide/networking/virtual_private_cloud_config.html)
