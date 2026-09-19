#!/bin/sh
# One-time bootstrap. Runs inside the vault-init container, with the root token
# that init.sh left behind:
#
#   BOOTSTRAP_OPERATORS="alice bob" \
#     docker compose -f vault/server/docker-compose.yml exec -it -e BOOTSTRAP_OPERATORS vault-init sh /init/bootstrap.sh
#
# It enables the engines, loads every policy in vault/policies, creates one
# AppRole per identity-* policy, creates one userpass account per operator, and
# finally REVOKES the root token and deletes it from disk.
#
# Operator usernames: lowercase letters, digits and underscore. Passwords are
# prompted (or read from OPERATOR_PASSWORD_<name> for non-interactive runs).
set -eu

INIT=/vault/init
[ -f "$INIT/bootstrapped" ] && { echo "already bootstrapped ($INIT/bootstrapped exists)"; exit 1; }
[ -s "$INIT/root.token" ] || { echo "no root token in $INIT: was vault-init able to initialize?"; exit 1; }
: "${BOOTSTRAP_OPERATORS:?set BOOTSTRAP_OPERATORS to a space-separated list of operator usernames}"

VAULT_TOKEN="$(cat "$INIT/root.token")"
export VAULT_TOKEN

vault status >/dev/null || { echo "vault is sealed or unreachable"; exit 1; }

vault audit list 2>/dev/null | grep -q '^file/' || vault audit enable file file_path=/vault/logs/audit.log >/dev/null
vault secrets list | grep -q '^secret/' || vault secrets enable -path=secret -version=2 kv >/dev/null
vault auth list | grep -q '^approle/' || vault auth enable approle >/dev/null
vault auth list | grep -q '^userpass/' || vault auth enable userpass >/dev/null

for f in /vault/policies/*.hcl; do
  vault policy write "$(basename "$f" .hcl)" "$f" >/dev/null
  echo "policy: $(basename "$f" .hcl)"
done

# One AppRole per identity-* policy, same name as the policy. secret_id_ttl=0:
# the Agent re-authenticates for the life of the deployment; rotation is
# explicit (scripts/vault-agent-creds.sh issues a new secret_id).
for f in /vault/policies/identity-*.hcl; do
  role="$(basename "$f" .hcl)"
  vault write "auth/approle/role/$role" token_policies="$role" \
    token_ttl=1h token_max_ttl=4h secret_id_ttl=0 >/dev/null
  echo "approle: $role"
done

for u in $BOOTSTRAP_OPERATORS; do
  eval "pw=\${OPERATOR_PASSWORD_$u:-}"
  if [ -z "$pw" ]; then
    [ -t 0 ] || { echo "no TTY and OPERATOR_PASSWORD_$u not set"; exit 1; }
    printf 'Password for operator %s: ' "$u"; stty -echo; read -r pw; stty echo; echo
  fi
  vault write "auth/userpass/users/$u" password="$pw" policies=operator \
    token_ttl=8h token_max_ttl=8h >/dev/null
  echo "operator: $u"
done

vault token revoke -self >/dev/null
rm -f "$INIT/root.token"
touch "$INIT/bootstrapped"
echo "bootstrap done; root token revoked and deleted"
