# Look-ups ("data sources"): they read from EduCloud and create nothing.
# They turn names into the IDs the resources will need, so no UUIDs have to be
# copied into the code. Values found with cmk on 2026-11-14.
#
# Watch out, provider behaviour (v0.7.0 source code):
# - every filter value is a regular expression, so all are anchored with ^...$
#   ("Small Instance" would also match "Small Instance ++");
# - when several items still match, the provider silently picks the newest
#   one instead of failing.

data "cloudstack_zone" "this" {
  filter {
    name  = "name"
    value = "^Eindhoven-Zone$"
  }
}

# Ubuntu 26.04 cloud image (KVM, QCOW2, virtio disk + NIC), uploaded by the
# EduCloud admins on 2026-05-14. Pinned by ID like any other version: a new
# upload under the same name must not silently replace the VMs. The second,
# newer "Ubuntu 26.0.4 ..." template is avoided on purpose: its description
# says it has a ubuntu/ubuntu login baked in.
data "cloudstack_template" "ubuntu_2604" {
  template_filter = "executable"

  filter {
    name  = "id"
    value = "^4c696cd0-d745-45b6-8650-752a3467dab3$"
  }
}

# Compute offerings (vCPU / RAM / root disk). Sizing for the 40 GiB RAM
# quota: 3 masters + 2 workers on "Small Instance ++" (2 / 6 GiB / 40 GB),
# the NetBird gateway on "Small Instance" (1 / 1 GiB / 10 GB), Rancher on
# "Medium Instance" (2 / 8 GiB / 50 GB): 39 GiB in total.
data "cloudstack_service_offering" "node" {
  filter {
    name  = "name"
    value = "^Small Instance \\+\\+$"
  }
}

data "cloudstack_service_offering" "gateway" {
  filter {
    name  = "name"
    value = "^Small Instance$"
  }
}

data "cloudstack_service_offering" "rancher" {
  filter {
    name  = "name"
    value = "^Medium Instance$"
  }
}

# The VPC: one virtual router for all tiers, with network ACLs per tier.
data "cloudstack_vpc_offering" "default" {
  filter {
    name  = "name"
    value = "^Default VPC offering$"
  }
}

# Offering for each tier inside the VPC. "NoLB": without CloudStack's load
# balancer (Cilium does load balancing later), so the router runs one
# service less. Egress default is deny; the ACLs decide what may leave.
data "cloudstack_network_offering" "vpc_tier" {
  filter {
    name  = "name"
    value = "^DefaultIsolatedNetworkOfferingForVpcNetworksNoLB$"
  }
}
