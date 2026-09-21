#!/usr/bin/env bash
# Onboards a team into Vault: its policy, its AppRole, an account for each person
# who will store values by hand (UI or CLI), and the Agent config it runs.
#
#   ./scripts/vault-onboard-team.sh <team> [member ...]
#   ./scripts/vault-onboard-team.sh cursos ana luis
#
# Run it again to rotate: the AppRole gets a new secret_id, and a member listed
# again gets a new password. Nothing sensitive is printed except, once, what has
# to be handed over:
#   - the secret_id is response-wrapped (10 minutes, one use): the team unwraps
#     it and that is the first time anyone reads it, Identity included;
#   - a member's initial password, generated here. Send it through a private
#     channel (it can only be replaced by re-running this script for that member).
#
# The Tailscale side (a tagged auth key for the team) is done in the Tailscale
# console; it is not something Vault can do.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
# shellcheck source=lib/vault.sh
. scripts/lib/vault.sh

TEAM="${1:-}"
[ -n "$TEAM" ] && shift
MEMBERS=("$@")

[[ "$TEAM" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "usage: $0 <team> [member ...]   (team: lowercase letters, digits, dashes)" >&2; exit 1; }
case "$TEAM" in identity|shared|sys|auth|secret) echo "'$TEAM' is reserved." >&2; exit 1 ;; esac
for m in "${MEMBERS[@]:-}"; do
  [ -z "$m" ] || [[ "$m" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "invalid member name: $m" >&2; exit 1; }
done
command -v openssl >/dev/null 2>&1 || { echo "openssl is not on your PATH." >&2; exit 1; }

vault_login

# Policy from the template
sed "s/__TEAM__/$TEAM/g" vault/policies/team.hcl.tpl | vault_cli policy write "team-$TEAM" - >/dev/null

# AppRole
vault_cli write "auth/approle/role/$TEAM" token_policies="team-$TEAM" \
  token_ttl=1h token_max_ttl=4h secret_id_ttl=0 >/dev/null </dev/null
ROLE_ID="$(vault_cli read -field=role_id "auth/approle/role/$TEAM/role-id" </dev/null)"
WRAPPING_TOKEN="$(vault_cli write -wrap-ttl=10m -f -field=wrapping_token "auth/approle/role/$TEAM/secret-id" </dev/null)"

# Agent config for the team
mkdir -p "secrets/vault/teams/$TEAM"
sed "s/__TEAM__/$TEAM/g" vault/agent/team-agent.hcl.tpl > "secrets/vault/teams/$TEAM/agent.hcl"

# People
declare -A PASSWORDS=()
for m in "${MEMBERS[@]:-}"; do
  [ -z "$m" ] && continue
  pw="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c 20)"
  printf '%s' "$pw" | vault_cli write "auth/userpass/users/$TEAM-$m" password=- \
    policies="team-$TEAM" token_ttl=8h token_max_ttl=8h >/dev/null
  PASSWORDS[$m]="$pw"
done

cat <<FIN

  Team '$TEAM' is set up in Vault.

  Hand over (private channel):
    VAULT_ADDR      $VAULT_ADDR
    role_id         $ROLE_ID
    wrapping token  $WRAPPING_TOKEN     (valid 10 minutes, one use)
    ca.pem          $VAULT_CACERT
    agent.hcl       secrets/vault/teams/$TEAM/agent.hcl

  The team unwraps the token once and keeps the result as .vault/secret_id:
    VAULT_ADDR=$VAULT_ADDR VAULT_CACERT=<path to ca.pem> vault unwrap -field=secret_id <wrapping token>

  Where the team stores values:  secret/tpi/$TEAM/*
    launch parameters and env    secret/tpi/$TEAM/env   (rendered as /run/secrets/app.env)
  UI: ${VAULT_ADDR%/}/ui  (method: Username)
FIN
for m in "${MEMBERS[@]:-}"; do
  [ -z "$m" ] && continue
  echo "    login $TEAM-$m   initial password: ${PASSWORDS[$m]}"
done
cat <<FIN

  Still manual: the team joins the mesh with the shared tag:microservicio auth key (vincular-tailscale-mesh).
  Guide for the team: docs/vault-teams.md

FIN
