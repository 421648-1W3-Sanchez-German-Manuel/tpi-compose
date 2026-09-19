# Vault Agent for dev-mailbox (development only). It reads DB_PASSWORD_FILE.

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
  destination          = "/run/secrets/db-password"
  perms                = "0444"
  error_on_missing_key = true
}
