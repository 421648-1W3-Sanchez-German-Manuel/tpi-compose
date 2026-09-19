# Vault Agent for grafana. Grafana reads GF_SECURITY_ADMIN_PASSWORD__FILE.

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
  contents             = "{{ with secret \"secret/data/tpi/identity/grafana\" }}{{ .Data.data.password }}{{ end }}"
  destination          = "/run/secrets/admin-password"
  perms                = "0444"
  error_on_missing_key = true
}
