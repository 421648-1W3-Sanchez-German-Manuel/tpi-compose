#!/usr/bin/env bash
# Issues the AppRole credentials a Vault Agent authenticates with, and writes
# them where docker-compose.yml mounts them: secrets/vault/agents/<role>/.
#
#   ./scripts/vault-agent-creds.sh identity-users
#   ./scripts/vault-agent-creds.sh all          # every identity-* role
#
# Running it again issues a NEW secret_id (that is how one is rotated); the old
# one keeps working until it is revoked. The secret_id is never printed.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
# shellcheck source=lib/vault.sh
. scripts/lib/vault.sh

ROLE="${1:-}"
[ -n "$ROLE" ] || { echo "usage: $0 <role>|all" >&2; exit 1; }

if [ "$ROLE" = "all" ]; then
  ROLES=()
  for f in vault/policies/identity-*.hcl; do ROLES+=("$(basename "$f" .hcl)"); done
else
  [[ "$ROLE" =~ ^[a-z0-9-]+$ ]] || { echo "invalid role name: $ROLE" >&2; exit 1; }
  ROLES=("$ROLE")
fi

vault_login

for r in "${ROLES[@]}"; do
  role_id="$(vault_cli read -field=role_id "auth/approle/role/$r/role-id" </dev/null)"
  secret_id="$(vault_cli write -f -field=secret_id "auth/approle/role/$r/secret-id" </dev/null)"
  dir="secrets/vault/agents/$r"
  mkdir -p "$dir"
  printf '%s' "$role_id" > "$dir/role_id"
  printf '%s' "$secret_id" > "$dir/secret_id"
  # The Agent runs as uid 100 inside its container and reads these through a bind mount.
  chmod 0755 "$dir"; chmod 0644 "$dir/role_id" "$dir/secret_id"
  echo "issued credentials for $r -> $dir"
done
