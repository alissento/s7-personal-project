# The 7 EduCloud VMs. Names, tiers and IPs: docs/network-plan.md.
#
# Every VM is created from the same Ubuntu 26.04 image and differs only in
# name, tier, fixed IP and size. First-boot setup (the admin user and SSH key)
# is in cloud-init.yaml.tftpl; everything after that is Ansible's job.

locals {
  # The login user. Must match AllowUsers in the Ansible common role
  # (ansible/roles/common/files/00-ssh-hardening.conf), or the first Ansible
  # run would lock SSH.
  admin_user = "nknez"

  # Only the PUBLIC half of the key is read; the private key never leaves
  # the workstation.
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))

  vms = {
    "ec-master-01"  = { tier = "nodes", ip = "10.10.30.10", size = "node" }
    "ec-master-02"  = { tier = "nodes", ip = "10.10.30.11", size = "node" }
    "ec-master-03"  = { tier = "nodes", ip = "10.10.30.12", size = "node" }
    "ec-worker-01"  = { tier = "nodes", ip = "10.10.30.20", size = "node" }
    "ec-worker-02"  = { tier = "nodes", ip = "10.10.30.21", size = "node" }
    "ec-gw-01"      = { tier = "edge", ip = "10.10.31.30", size = "gateway" }
    "ec-rancher-01" = { tier = "mgmt", ip = "10.10.31.40", size = "rancher" }
  }

  # size -> compute offering (vCPU / RAM / root disk), looked up in data.tf.
  service_offering_ids = {
    node    = data.cloudstack_service_offering.node.id    # 2 / 6 GiB / 40 GB
    gateway = data.cloudstack_service_offering.gateway.id # 1 / 1 GiB / 10 GB
    rancher = data.cloudstack_service_offering.rancher.id # 2 / 8 GiB / 50 GB
  }
}

resource "cloudstack_instance" "vm" {
  for_each = local.vms

  # CloudStack also hands this name to the VM as its hostname.
  name             = each.key
  service_offering = local.service_offering_ids[each.value.size]
  template         = data.cloudstack_template.ubuntu_2604.id
  zone             = data.cloudstack_zone.this.id

  # One NIC, in the VM's tier, with a fixed IP. CloudStack's DHCP (on the
  # virtual router) always hands the VM this address.
  network_id = cloudstack_network.tier[each.value.tier].id
  ip_address = each.value.ip

  # cloud-init reads this on the first boot only. Changing it later does not
  # re-run it: replace the VM on purpose (tofu apply -replace=...).
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_user         = local.admin_user
    ssh_public_key     = local.ssh_public_key
    sudo_password_hash = var.sudo_password_hash
  })

  # Destroying a VM deletes it at once instead of keeping it in CloudStack's
  # recycle bin, where it would still count against the quota.
  expunge = true
}
