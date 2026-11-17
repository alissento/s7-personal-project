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

# The PUBLIC key that cloud-init puts on every VM for the admin user.
# Create the key pair with:
#   ssh-keygen -t ed25519 -f ~/.ssh/educloud-ansible -C educloud-ansible
variable "ssh_public_key_file" {
  description = "Path to the SSH public key allowed to log in to the VMs."
  type        = string
  default     = "~/.ssh/educloud-ansible.pub"

  # A private key file starts with "-----BEGIN", so it is rejected here.
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-)", file(pathexpand(var.ssh_public_key_file))))
    error_message = "ssh_public_key_file must exist and be an SSH PUBLIC key (the .pub file)."
  }
}

# The admin user's password, as a hash; sudo on the VMs asks for it (Ansible:
# -K), like on Homelab. Set with TF_VAR_sudo_password_hash in
# ~/.config/educloud/cloudstack.env; create the hash with: openssl passwd -6
# Only the hash reaches EduCloud, but any process on a VM can read it from
# CloudStack's metadata service, so the password itself must be strong.
variable "sudo_password_hash" {
  description = "SHA-512 crypt hash of the admin user's password (sudo, console)."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^\\$6\\$[./A-Za-z0-9]+\\$[./A-Za-z0-9]{86}$", var.sudo_password_hash))
    error_message = "sudo_password_hash must be a SHA-512 crypt hash (starts with $6$), as printed by: openssl passwd -6. Never the password itself."
  }
}
