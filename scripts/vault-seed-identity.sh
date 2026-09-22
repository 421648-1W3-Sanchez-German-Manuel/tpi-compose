#!/usr/bin/env bash
# Creates the secrets of the identity namespace that do not exist yet:
#
#   secret/tpi/identity/db         MySQL root password
#   secret/tpi/identity/jwt        RS256 key pair (private_key, public_key, kid)
#   secret/tpi/identity/bootstrap  initial ADMIN password
#   secret/tpi/identity/grafana    Grafana admin password
#
# Idempotent: an existing secret is left alone. It never prints a value; read one
# back with `vault kv get -mount=secret tpi/identity/bootstrap` when you need it.
#
#   VAULT_ADDR=https://<vault>:8200 ./scripts/vault-seed-identity.sh
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
# shellcheck source=lib/vault.sh
. scripts/lib/vault.sh
command -v openssl >/dev/null 2>&1 || { echo "openssl is not on your PATH (Git for Windows ships it in usr/bin)." >&2; exit 1; }

vault_login

exists() { vault_cli kv get -mount=secret "$1" >/dev/null 2>&1 </dev/null; }
rand() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
seeded() { echo "created: $1"; }
kept() { echo "kept:    $1 (already exists)"; }

if exists tpi/identity/db; then kept identity/db; else
  printf '%s' "$(rand 40)" | vault_cli kv put -mount=secret tpi/identity/db password=- >/dev/null; seeded identity/db
fi

# "Aa1" prefix: the same shape AdminBootstrap generates, so it passes PasswordPolicy.
if exists tpi/identity/bootstrap; then kept identity/bootstrap; else
  printf '%s' "Aa1$(rand 24)" | vault_cli kv put -mount=secret tpi/identity/bootstrap password=- >/dev/null; seeded identity/bootstrap
fi

if exists tpi/identity/grafana; then kept identity/grafana; else
  printf '%s' "$(rand 32)" | vault_cli kv put -mount=secret tpi/identity/grafana password=- >/dev/null; seeded identity/grafana
fi

if exists tpi/identity/jwt; then kept identity/jwt; else
  # Relative (and gitignored) so a native Windows openssl resolves it too.
  mkdir -p secrets
  tmp="$(mktemp -d secrets/.seed.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/private.pem" 2>/dev/null \
    && openssl rsa -in "$tmp/private.pem" -pubout -out "$tmp/public.pem" 2>/dev/null \
    || { echo "openssl could not generate the key pair" >&2; exit 1; }
  # PEM to a JSON string: newlines become \n. Base64 bodies contain no other escapes.
  esc() { sed ':a;N;$!ba;s/\n/\\n/g' "$1"; }
  printf '{"private_key":"%s","public_key":"%s","kid":"dev"}' "$(esc "$tmp/private.pem")" "$(esc "$tmp/public.pem")" \
    | vault_cli kv put -mount=secret tpi/identity/jwt - >/dev/null
  seeded identity/jwt
fi
