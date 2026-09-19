#!/usr/bin/env bash
# Registers a service client (client_credentials) in users-service and hands the
# secret to Vault instead of to the terminal.
#
#   ./scripts/seed-service-client-v2.sh <clientId> [scope,scope,...] [--legacy-print]
#   ./scripts/seed-service-client-v2.sh cursos-service users.profile.read
#
# When one micro calls another there is NO user behind it, so it authenticates
# with its own credentials and asks for a service token. The Identity team
# issues those credentials — that is, this script — because the table is ours.
#
# What it does, in this order:
#   1. generates the clientSecret;
#   2. writes it, in clear, to Vault: secret/tpi/shared/clients/<team>, where the
#      owning team's AppRole can read it (team = clientId without "-service");
#   3. stores its BCrypt hash in MySQL (service_clients.secret_hash), which is
#      all users-service ever needs to verify it.
# Vault goes first: if the MySQL step fails, run it again (both steps are
# idempotent: Vault gets a new version, MySQL deletes and recreates).
#
# The secret is NOT printed. --legacy-print prints it once, as the old script did
# (for a consumer that still takes it from an environment variable).
#
# It is a script and not a Flyway migration on purpose: registering a client is
# a manual procedure. A migration would also run in production and sow a secret
# there that nobody chose.
set -euo pipefail

cd "$(dirname "$0")/.."

PRINT=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --legacy-print) PRINT=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
CLIENT_ID="${ARGS[0]:-}"
SCOPES="${ARGS[1]:-users.profile.read}"

if [ -z "$CLIENT_ID" ]; then
  cat >&2 <<'USAGE'
Missing the clientId.

  ./scripts/seed-service-client-v2.sh <clientId> [comma-separated scopes] [--legacy-print]

By convention the clientId is the serviceId the micro registers in Eureka
with (cursos-service, desafios-service). It is what later travels in the `sub`
of the token and in the X-Service-Id header, so them matching saves surprises.

Scopes that can be issued today (ScopeCatalog of users-service, CLOSED
catalog):
  users.profile.read   -> audience users-service

A scope that is not in that catalog is rejected AT ISSUE, not at use. Adding
one is touching ScopeCatalog.java and deploying users-service.
USAGE
  exit 1
fi
[[ "$CLIENT_ID" =~ ^[a-z0-9-]+$ ]] || { echo "clientId must be lowercase letters, digits and dashes." >&2; exit 1; }
[[ "$SCOPES" =~ ^[A-Za-z0-9._,-]+$ ]] || { echo "invalid scopes: $SCOPES" >&2; exit 1; }
TEAM="${CLIENT_ID%-service}"

[ -f .env ] || { echo "Missing .env. Copy it from .env.example." >&2; exit 1; }
set -a; . ./.env; set +a
# shellcheck source=lib/vault.sh
. scripts/lib/vault.sh
vault_login

# The MySQL root password is in Vault; it goes to the container through the
# environment, never through the command line.
MYSQL_PWD="$(vault_cli kv get -mount=secret -field=password tpi/identity/db </dev/null)"
export MYSQL_PWD

SECRET="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)"

printf '%s' "$SECRET" | vault_cli kv put -mount=secret "tpi/shared/clients/$TEAM" \
  client_id="$CLIENT_ID" client_secret=- >/dev/null

# BCrypt cost 12, the project standard. htpasswd comes from a throwaway image
# so we do not depend on it being installed on the machine. The password is read
# from stdin, not from the command line.
HASH="$(printf '%s' "$SECRET" | docker run --rm -i httpd:alpine htpasswd -inBC 12 "" 2>/dev/null | tr -d ':\r\n')"
case "$HASH" in
  '$2'*) ;;
  *) echo "Could not generate the BCrypt hash." >&2; exit 1 ;;
esac

SQL="SET @id = UUID();
DELETE s FROM service_client_scopes s
  JOIN service_clients c ON c.id = s.service_client_id
  WHERE c.client_id = '${CLIENT_ID}';
DELETE FROM service_clients WHERE client_id = '${CLIENT_ID}';
INSERT INTO service_clients (id, client_id, secret_hash, description, created_at)
  VALUES (@id, '${CLIENT_ID}', '${HASH}', 'Service client for ${CLIENT_ID}', UTC_TIMESTAMP(6));"
for sc in $(echo "$SCOPES" | tr ',' ' '); do
  SQL="${SQL}
INSERT INTO service_client_scopes (service_client_id, scope) VALUES (@id, '${sc}');"
done

printf '%s\n' "$SQL" | docker compose exec -T -e MYSQL_PWD mysql mysql -uroot users

cat <<FIN

  Service client registered
    client_id: ${CLIENT_ID}
    scopes:    ${SCOPES}
    secret:    Vault, secret/tpi/shared/clients/${TEAM} (field client_secret)

  The owning team reads it with its own AppRole; nobody has to pass it around.

  How the owning team uses it — WATCH OUT, grantType is required:

    POST http://localhost:3000/api/users/public/auth/token
    {
      "clientId":     "${CLIENT_ID}",
      "clientSecret": "...",
      "grantType":    "client_credentials",
      "scope":        "${SCOPES%%,*}",
      "audience":     "users-service"
    }

  The token lasts 5 minutes, carries the MS role and only works against the
  \`audience\` it asked for. Against any other destination: 403
  invalid-audience.

FIN

if [ "$PRINT" -eq 1 ]; then
  cat <<FIN
  --legacy-print: clientSecret (printed a single time, it will end up in a
  terminal history and a scrollback):

    ${SECRET}

FIN
fi
