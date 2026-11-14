# Printed after plan/apply: proof of what the look-ups in data.tf found.
# Compare with the cmk results in README.md.

output "zone" {
  description = "Zone the VPC and VMs go into."
  value       = { id = data.cloudstack_zone.this.id, name = data.cloudstack_zone.this.name }
}

output "template" {
  description = "Ubuntu 26.04 image every VM is created from."
  value = {
    id      = data.cloudstack_template.ubuntu_2604.id
    name    = data.cloudstack_template.ubuntu_2604.name
    created = data.cloudstack_template.ubuntu_2604.created
  }
}

output "service_offerings" {
  description = "Compute offering IDs, by VM type."
  value = {
    node    = data.cloudstack_service_offering.node.id
    gateway = data.cloudstack_service_offering.gateway.id
    rancher = data.cloudstack_service_offering.rancher.id
  }
}

output "network_offerings" {
  description = "VPC and VPC-tier offering IDs."
  value = {
    vpc      = data.cloudstack_vpc_offering.default.id
    vpc_tier = data.cloudstack_network_offering.vpc_tier.id
  }
}
