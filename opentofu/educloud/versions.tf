# Which OpenTofu and provider versions this folder needs, and how its state
# is encrypted. Versions checked 2026-11-14.

terraform {
  # Any 1.13.x patch release; 1.14 must be adopted on purpose.
  required_version = ">= 1.13.0, < 1.14.0"

  required_providers {
    cloudstack = {
      # Resolves to registry.opentofu.org/cloudstack/cloudstack.
      source = "cloudstack/cloudstack"
      # Exact pin: 0.7.0 is the first release with VPC static routes to a
      # next-hop IP (needs CloudStack 4.22+; EduCloud runs 4.22.1.1).
      version = "0.7.0"
    }
  }

  # OpenTofu-only: the state and saved plan files are encrypted with AES-GCM,
  # using a key derived from a passphrase (PBKDF2). The passphrase comes
  # from var.state_passphrase, i.e. the environment variable
  # TF_VAR_state_passphrase, and is never written to disk by OpenTofu.
  # https://opentofu.org/docs/language/state/encryption/
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.passphrase
    }

    # enforced = true: refuse to write an unencrypted file, even if the
    # encryption settings are ever removed by mistake.
    state {
      method   = method.aes_gcm.default
      enforced = true
    }

    plan {
      method   = method.aes_gcm.default
      enforced = true
    }
  }
}
