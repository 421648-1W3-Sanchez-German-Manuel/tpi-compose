# Vault Agent for users-service. VAULT_ADDR and VAULT_CACERT come from the
# environment. Files land in the volume users-secrets, mounted read-only in
# users-service:
#   /run/secrets/config/*   read through Spring Config Tree (application.yml)
#   /run/secrets/jwt-private.pem, /run/secrets/jwks/dev.pem   read by FileSystemSigningKeyProvider
#
# A secret that was never seeded renders an empty file, and the Agent healthcheck
# (test -s) then keeps it unhealthy, so the consumer does not start. error_on_missing_key
# also fails the render when a secret exists but a field is missing.

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/vault/auth/role_id"
      secret_id_file_path                 = "/vault/auth/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template {
  contents             = "{{ with secret \"secret/data/tpi/identity/db\" }}{{ .Data.data.password }}{{ end }}"
  destination          = "/run/secrets/config/db-password"
  perms                = "0444"
  error_on_missing_key = true
}

template {
  contents             = "{{ with secret \"secret/data/tpi/identity/bootstrap\" }}{{ .Data.data.password }}{{ end }}"
  destination          = "/run/secrets/config/admin-bootstrap-password"
  perms                = "0444"
  error_on_missing_key = true
}

template {
  contents             = "{{ with secret \"secret/data/tpi/identity/jwt\" }}{{ .Data.data.private_key }}{{ end }}"
  destination          = "/run/secrets/jwt-private.pem"
  perms                = "0444"
  error_on_missing_key = true
}

# The file name is the kid (JWT_ACTIVE_KID, default "dev"). Rotating the kid
# means changing this destination and JWT_ACTIVE_KID together.
template {
  contents             = "{{ with secret \"secret/data/tpi/identity/jwt\" }}{{ .Data.data.public_key }}{{ end }}"
  destination          = "/run/secrets/jwks/dev.pem"
  perms                = "0444"
  error_on_missing_key = true
}
