# Vault Agent for team __TEAM__ (rendered by scripts/vault-onboard-team.sh).
# VAULT_ADDR and VAULT_CACERT come from the environment. The AppRole credentials
# are two files, role_id and secret_id, in /vault/auth.
#
# Everything stored at secret/tpi/__TEAM__/env is rendered as KEY=value lines in
# /run/secrets/app.env, one line per key. Put launch parameters there
# (JAVA_OPTS, SPRING_PROFILES_ACTIVE, a topic name) next to the API keys. The
# file is plain dotenv: no quotes, one line per key, values without newlines.
# Load it with vault/agent/load-env.sh (see docs/vault-teams.md).

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
  contents    = <<EOT
{{ with secret "secret/data/tpi/__TEAM__/env" }}{{ range $k, $v := .Data.data }}{{ $k }}={{ $v }}
{{ end }}{{ end }}
EOT
  destination = "/run/secrets/app.env"
  perms       = "0444"
}

# The client secret Identity issued to this team (seed-service-client-v2.sh), if
# the team calls other micros. Uncomment once it exists.
# template {
#   contents    = "{{ with secret \"secret/data/tpi/shared/clients/__TEAM__\" }}{{ .Data.data.client_secret }}{{ end }}"
#   destination = "/run/secrets/client-secret"
#   perms       = "0444"
# }
