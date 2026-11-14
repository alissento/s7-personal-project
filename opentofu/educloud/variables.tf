# Set with the environment variable TF_VAR_state_passphrase (see README.md).
# Never put it in a .tfvars file. If it is not set, tofu asks for it.
# OpenTofu itself refuses passphrases shorter than 16 characters.
variable "state_passphrase" {
  description = "Passphrase the state and plan files are encrypted with (versions.tf)."
  type        = string
  # sensitive: OpenTofu never prints the value.
  sensitive = true
  # ephemeral: OpenTofu never stores the value, not even in a saved plan file.
  ephemeral = true
}

# The workstation's public IPs (home, school), allowed to reach the SSH jump
# host. Set with TF_VAR_admin_cidrs in ~/.config/educloud/cloudstack.env, e.g.
#   export TF_VAR_admin_cidrs='["203.0.113.7/32","198.51.100.0/24"]'
# Kept out of the repo: a home IP is personal data. If it changes, update the
# env file and run tofu apply (only the edge ACL changes).
variable "admin_cidrs" {
  description = "Public source CIDRs allowed to SSH to the jump host (ec-gw-01)."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs is empty; list at least one public IP, e.g. [\"203.0.113.7/32\"]."
  }

  # IPv4 with a prefix only: the ACLs are IPv4, and a bare IP (as printed by
  # ifconfig.me) has no prefix. Get the IPv4 address with: curl -4 -s https://ifconfig.me
  validation {
    condition = alltrue([
      for c in var.admin_cidrs :
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", c)) && can(cidrhost(c, 0))
    ])
    error_message = "Every admin_cidrs entry must be an IPv4 address with a prefix, e.g. \"203.0.113.7/32\". Not valid: ${join(", ", [for c in var.admin_cidrs : c if !(can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", c)) && can(cidrhost(c, 0)))])}."
  }

  validation {
    condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 would open SSH to the whole internet; list your own public IPs instead."
  }
}
