# Vault Agent for the mysql container. The official image reads
# MYSQL_ROOT_PASSWORD_FILE, so the password never appears in the environment.

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
