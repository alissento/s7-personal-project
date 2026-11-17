# EduCloud network: one VPC with three tiers, each behind its own network ACL.
# Design (option C) and addresses: docs/network-plan.md.
#
#   VPC 10.10.30.0/23 ── one virtual router (VR): gateway, DHCP, DNS, source NAT
#     tier nodes  10.10.30.0/24    masters, workers, API VIP, LoadBalancer pool
#     tier edge   10.10.31.16/28   ec-gw-01: the NetBird gateway (routing peer)
#     tier mgmt   10.10.31.32/28   ec-rancher-01
#
# How the ACLs work (CloudStack 4.22, VPC network ACLs):
# - an ACL belongs to one tier and filters traffic entering (ingress) or
#   leaving (egress) that tier through the VR. Traffic between VMs of the same
#   tier does not pass the VR and is not filtered.
# - rules are checked from the lowest number up; the first match decides.
# - rules are stateful: replies to an allowed connection always get through.
# - a custom ACL denies unmatched ingress but ALLOWS unmatched egress, so every
#   ACL here ends with an explicit "deny all" in both directions.
# - for egress rules the CIDR is the destination; the source is always the
#   whole tier, so a rule cannot be limited to one VM.
# - ONE CIDR per rule. With several, the VR enforces only the last one stored
#   and silently ignores the rest: rule 110 of tier mgmt listed nodes and edge,
#   and only the nodes reached Rancher; of the DNS rules only 1.1.1.1 worked,
#   never 1.0.0.1 (found 2026-11-17). Hence pairs like 110/111 and 502/503.
#
# Numbering: 1xx ingress allow, 199 ingress deny all,
#            5xx egress allow,  599 egress deny all.
#
# Time sync: Ubuntu 26.04 uses chrony with NTS (authenticated NTP). It first
# fetches keys over TCP 4460, then syncs over UDP 123. Both must be allowed, or
# the clock never synchronises (found on ec-gw-01, 2026-11-17).
#
# DNS: the VMs ask Cloudflare (1.1.1.1, 1.0.0.1), not the VR. The VR forwards to the school's resolvers,
# which returned stale addresses for AWS-hosted names: registry-1.docker.io and quay.io resolved to IPs
# that now serve other websites, so no container image could be pulled (found on ec-rancher-01,
# 2026-11-17). Rules 502-518 allow plain DNS and DNS over TLS (853) to Cloudflare; Ansible points
# the VMs at it (roles/common, tasks/dns.yml). The VR rules 500/510 stay for now: a VM that Ansible has
# not switched yet (ec-gw-01 until it is reachable over SSH) still needs them. Remove them once every VM
# uses Cloudflare.

locals {
  vpc_cidr = "10.10.30.0/23"

  # Cloudflare's public resolvers (https://developers.cloudflare.com/1.1.1.1/ip-addresses/, checked
  # 2026-11-17). Must match common_dns_servers in ansible/inventory/educloud/group_vars/all.yml.
  public_dns = ["1.1.1.1/32", "1.0.0.1/32"]

  # The edge text still says "jump host": it ends up in the ACL's description,
  # and CloudStack can only change that by replacing the whole ACL.
  tiers = {
    nodes = { cidr = "10.10.30.0/24", gateway = "10.10.30.1", purpose = "RKE2 masters and workers" }
    edge  = { cidr = "10.10.31.16/28", gateway = "10.10.31.17", purpose = "SSH jump host, later the NetBird gateway" }
    mgmt  = { cidr = "10.10.31.32/28", gateway = "10.10.31.33", purpose = "Rancher" }
  }
}

resource "cloudstack_vpc" "educloud" {
  name         = "ec-vpc"
  display_text = "Semester 7 Kubernetes Project"
  cidr         = local.vpc_cidr
  vpc_offering = data.cloudstack_vpc_offering.default.id
  zone         = data.cloudstack_zone.this.id
}

# One ACL per tier, so each tier can have its own rules.
resource "cloudstack_network_acl" "tier" {
  for_each = local.tiers

  name        = "ec-${each.key}"
  description = "Rules for tier ${each.key}: ${each.value.purpose}"
  vpc_id      = cloudstack_vpc.educloud.id
}

# The three tiers. The VR takes the gateway address (.1, .17, .33); VMs get
# fixed IPs in step 3c.
resource "cloudstack_network" "tier" {
  for_each = local.tiers

  name             = "ec-${each.key}"
  display_text     = each.value.purpose
  cidr             = each.value.cidr
  gateway          = each.value.gateway
  network_offering = data.cloudstack_network_offering.vpc_tier.id
  vpc_id           = cloudstack_vpc.educloud.id
  acl_id           = cloudstack_network_acl.tier[each.key].id
  zone             = data.cloudstack_zone.this.id
}

# ---------------------------------------------------------------------------
# tier nodes: RKE2 masters and workers
# ---------------------------------------------------------------------------
resource "cloudstack_network_acl_ruleset" "nodes" {
  acl_id = cloudstack_network_acl.tier["nodes"].id
  # managed: rules added by hand (e.g. in the EduCloud UI) are removed on the
  # next apply, so the ACL always matches this file.
  managed = true

  # --- ingress ---
  rule {
    rule_number  = 100
    description  = "SSH from the NetBird gateway (admin, Ansible)"
    traffic_type = "ingress"
    protocol     = "tcp"
    port         = "22"
    cidr_list    = [local.tiers.edge.cidr]
  }
  rule {
    rule_number  = 110
    description  = "Kubernetes API from the NetBird gateway (kubectl)"
    traffic_type = "ingress"
    protocol     = "tcp"
    port         = "6443"
    cidr_list    = [local.tiers.edge.cidr]
  }
  rule {
    rule_number  = 120
    description  = "ping from inside the VPC (troubleshooting)"
    traffic_type = "ingress"
    protocol     = "icmp"
    cidr_list    = [local.vpc_cidr]
  }
  rule {
    rule_number  = 199
    description  = "deny all other ingress"
    traffic_type = "ingress"
    action       = "deny"
    protocol     = "all"
    cidr_list    = ["0.0.0.0/0"]
  }

  # --- egress ---
  rule {
    rule_number  = 500
    description  = "DNS to the VR (only until every VM uses Cloudflare, see the DNS note at the top)"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = ["${local.tiers.nodes.gateway}/32"]
  }
  rule {
    rule_number  = 502
    description  = "DNS to Cloudflare: the VR's answers for AWS-hosted registries are stale"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 503
    description  = "DNS to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 510
    description  = "DNS over TCP to the VR (large answers)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = ["${local.tiers.nodes.gateway}/32"]
  }
  rule {
    rule_number  = 512
    description  = "DNS over TCP to Cloudflare (large answers)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 513
    description  = "DNS over TCP to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 517
    description  = "DNS over TLS to Cloudflare (encrypted, so the network in between cannot alter answers)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "853"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 518
    description  = "DNS over TLS to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "853"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 520
    description  = "HTTP: Ubuntu apt mirrors"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "80"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 530
    description  = "HTTPS: RKE2 install, container registries, GitHub, Rancher (tier mgmt)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "443"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 540
    description  = "NTP: etcd and certificates need synchronised clocks"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "123"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 545
    description  = "NTS key exchange: Ubuntu 26.04 authenticates its time servers before NTP"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "4460"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 550
    description  = "ICMP: ping and path MTU discovery"
    traffic_type = "egress"
    protocol     = "icmp"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 599
    description  = "deny all other egress"
    traffic_type = "egress"
    action       = "deny"
    protocol     = "all"
    cidr_list    = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# tier edge: ec-gw-01, the NetBird gateway. It only dials out to NetBird, so
# nothing from outside the VPC is let in. Admin and cross-site traffic leaves
# it with its own address (masquerade), which is what the other tiers allow.
# ---------------------------------------------------------------------------
resource "cloudstack_network_acl_ruleset" "edge" {
  acl_id  = cloudstack_network_acl.tier["edge"].id
  managed = true

  # --- ingress ---
  rule {
    rule_number  = 120
    description  = "ping from inside the VPC (troubleshooting)"
    traffic_type = "ingress"
    protocol     = "icmp"
    cidr_list    = [local.vpc_cidr]
  }
  rule {
    rule_number  = 199
    description  = "deny all other ingress"
    traffic_type = "ingress"
    action       = "deny"
    protocol     = "all"
    cidr_list    = ["0.0.0.0/0"]
  }

  # --- egress ---
  rule {
    rule_number  = 500
    description  = "DNS to the VR (only until every VM uses Cloudflare, see the DNS note at the top)"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = ["${local.tiers.edge.gateway}/32"]
  }
  rule {
    rule_number  = 502
    description  = "DNS to Cloudflare: the VR's answers for AWS-hosted registries are stale"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 503
    description  = "DNS to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 510
    description  = "DNS over TCP to the VR"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = ["${local.tiers.edge.gateway}/32"]
  }
  rule {
    rule_number  = 512
    description  = "DNS over TCP to Cloudflare (large answers)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 513
    description  = "DNS over TCP to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 517
    description  = "DNS over TLS to Cloudflare (encrypted, so the network in between cannot alter answers)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "853"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 518
    description  = "DNS over TLS to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "853"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 520
    description  = "HTTP: Ubuntu apt mirrors"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "80"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 530
    description  = "HTTPS: updates, NetBird control and relay servers, Rancher (tier mgmt)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "443"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 540
    description  = "NTP"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "123"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 545
    description  = "NTS key exchange: Ubuntu 26.04 authenticates its time servers before NTP"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "4460"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 550
    description  = "ICMP: ping and path MTU discovery"
    traffic_type = "egress"
    protocol     = "icmp"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 560
    description  = "SSH to every VM in the VPC (admin traffic arriving over NetBird)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "22"
    cidr_list    = [local.vpc_cidr]
  }
  rule {
    rule_number  = 570
    description  = "Kubernetes API of the EduCloud cluster (admin traffic arriving over NetBird)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "6443"
    cidr_list    = [local.tiers.nodes.cidr]
  }
  rule {
    rule_number  = 580
    description  = "NetBird: UDP to its STUN servers and directly to other peers (WireGuard)"
    traffic_type = "egress"
    protocol     = "udp"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 599
    description  = "deny all other egress"
    traffic_type = "egress"
    action       = "deny"
    protocol     = "all"
    cidr_list    = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# tier mgmt: ec-rancher-01
# ---------------------------------------------------------------------------
resource "cloudstack_network_acl_ruleset" "mgmt" {
  acl_id  = cloudstack_network_acl.tier["mgmt"].id
  managed = true

  # --- ingress ---
  rule {
    rule_number  = 100
    description  = "SSH from the NetBird gateway (admin, Ansible)"
    traffic_type = "ingress"
    protocol     = "tcp"
    port         = "22"
    cidr_list    = [local.tiers.edge.cidr]
  }
  rule {
    rule_number  = 110
    description  = "Rancher (HTTPS): agents on the nodes"
    traffic_type = "ingress"
    protocol     = "tcp"
    port         = "443"
    cidr_list    = [local.tiers.nodes.cidr]
  }
  rule {
    rule_number  = 111
    description  = "Rancher (HTTPS): UI and Homelab agents over NetBird"
    traffic_type = "ingress"
    protocol     = "tcp"
    port         = "443"
    cidr_list    = [local.tiers.edge.cidr]
  }
  rule {
    rule_number  = 120
    description  = "ping from inside the VPC (troubleshooting)"
    traffic_type = "ingress"
    protocol     = "icmp"
    cidr_list    = [local.vpc_cidr]
  }
  rule {
    rule_number  = 199
    description  = "deny all other ingress"
    traffic_type = "ingress"
    action       = "deny"
    protocol     = "all"
    cidr_list    = ["0.0.0.0/0"]
  }

  # --- egress ---
  rule {
    rule_number  = 500
    description  = "DNS to the VR (only until every VM uses Cloudflare, see the DNS note at the top)"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = ["${local.tiers.mgmt.gateway}/32"]
  }
  rule {
    rule_number  = 502
    description  = "DNS to Cloudflare: the VR's answers for AWS-hosted registries are stale"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 503
    description  = "DNS to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "53"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 510
    description  = "DNS over TCP to the VR"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = ["${local.tiers.mgmt.gateway}/32"]
  }
  rule {
    rule_number  = 512
    description  = "DNS over TCP to Cloudflare (large answers)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 513
    description  = "DNS over TCP to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "53"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 517
    description  = "DNS over TLS to Cloudflare (encrypted, so the network in between cannot alter answers)"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "853"
    cidr_list    = [local.public_dns[0]]
  }
  rule {
    rule_number  = 518
    description  = "DNS over TLS to Cloudflare, backup resolver"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "853"
    cidr_list    = [local.public_dns[1]]
  }
  rule {
    rule_number  = 520
    description  = "HTTP: Ubuntu apt mirrors"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "80"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 530
    description  = "HTTPS: RKE2 install, Helm charts, container registries"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "443"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 540
    description  = "NTP"
    traffic_type = "egress"
    protocol     = "udp"
    port         = "123"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 545
    description  = "NTS key exchange: Ubuntu 26.04 authenticates its time servers before NTP"
    traffic_type = "egress"
    protocol     = "tcp"
    port         = "4460"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 550
    description  = "ICMP: ping and path MTU discovery"
    traffic_type = "egress"
    protocol     = "icmp"
    cidr_list    = ["0.0.0.0/0"]
  }
  rule {
    rule_number  = 599
    description  = "deny all other egress"
    traffic_type = "egress"
    action       = "deny"
    protocol     = "all"
    cidr_list    = ["0.0.0.0/0"]
  }
}
