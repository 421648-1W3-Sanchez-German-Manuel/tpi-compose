#!/usr/bin/env bash
# Loads the policies in vault/policies/*.hcl into a running Vault and makes sure
# each identity-* policy has its AppRole. Bootstrap does this once; run this after
# changing a policy, so it does not need a new bootstrap.
#
#   VAULT_ADDR=https://<vault>:8200 ./scripts/vault-apply-policies.sh
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
# shellcheck source=lib/vault.sh
. scripts/lib/vault.sh
vault_login

for f in vault/policies/*.hcl; do
  name="$(basename "$f" .hcl)"
  vault_cli policy write "$name" - < "$f" >/dev/null
  echo "policy: $name"
  case "$name" in
    identity-*)
      vault_cli write "auth/approle/role/$name" token_policies="$name" \
        token_ttl=1h token_max_ttl=4h secret_id_ttl=0 >/dev/null </dev/null
      echo "approle: $name"
      ;;
  esac
done
