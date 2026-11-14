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
