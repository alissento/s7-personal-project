# OpenTofu: EduCloud network and VMs

This folder will describe everything the project needs in EduCloud (the school cloud, running Apache CloudStack 4.22.1.1) as code: the network and the 7 VMs from [docs/network-plan.md](../../docs/network-plan.md). OpenTofu compares this description with what exists in EduCloud and creates, changes or deletes only the difference.

Status on 2026-11-14: **step 3a**. The provider connects to EduCloud and looks up the zone, the Ubuntu image and the offerings. Nothing is created yet. Next: the VPC with its three tiers and ACLs (3b), then the SSH key and the VMs (3c).

## 1. Quick start

**Prerequisites on the workstation:**

| What | Version (checked 2026-11-14) | Why |
|---|---|---|
| OpenTofu (`tofu`) | 1.13.9, from the official apt repository, `apt-mark hold` | runs this code |
| CloudMonkey (`cmk`) | 6.6.0, SHA-256 checked against the release notes | CloudStack's CLI, for looking things up by hand |
| EduCloud API keys | — | generated in the EduCloud UI (your profile → *Generate keys*); they can do anything your account can |
| `~/.config/educloud/cloudstack.env` | — | the keys and the state passphrase as environment variables, outside the repo, mode `0600` |

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
| `variables.tf` | `state_passphrase`, sensitive and ephemeral |
| `data.tf` | look-ups: zone, template, compute offerings, VPC and tier offerings |
| `outputs.tf` | prints what the look-ups found |
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

## 5. Look-ups (`data.tf`)

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

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `tofu` asks for `var.state_passphrase` | the env file is not loaded in this terminal | `source ~/.config/educloud/cloudstack.env` |
| `passphrase is too short (minimum 16 characters)` | OpenTofu's own minimum for pbkdf2 | use the generated passphrase |
| `decryption failed for all provided methods` | wrong passphrase for an existing state | take the one from the password manager |
| `No … is matching with the specified regex` | the name or ID no longer exists in EduCloud | check with `cmk list templates templatefilter=executable keyword=ubuntu` (or `serviceofferings`, ...) |
| provider error about the API URL or keys | the `CLOUDSTACK_*` variables are missing or wrong | `source` the env file; test the keys with `cmk list zones` |

## 7. Sources

Checked 2026-11-14.

- OpenTofu: [install on Debian/Ubuntu](https://opentofu.org/docs/intro/install/deb/) · [state and plan encryption](https://opentofu.org/docs/language/state/encryption/) · [releases](https://github.com/opentofu/opentofu/releases)
- CloudStack provider: [v0.7.0 docs](https://github.com/apache/cloudstack-terraform-provider/tree/v0.7.0/website/docs) · [provider configuration](https://github.com/apache/cloudstack-terraform-provider/blob/v0.7.0/website/docs/index.html.markdown)
- [CloudMonkey 6.6.0 release](https://github.com/apache/cloudstack-cloudmonkey/releases)
- CloudStack 4.22: [guest traffic and egress rules](http://docs.cloudstack.apache.org/en/4.22.0.1/adminguide/networking_and_traffic.html) · [VPC and network ACLs](https://docs.cloudstack.apache.org/en/latest/adminguide/networking/virtual_private_cloud_config.html)
