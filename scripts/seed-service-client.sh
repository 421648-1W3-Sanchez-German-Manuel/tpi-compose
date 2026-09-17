#!/usr/bin/env bash
# Registers a service client (client_credentials) in users-service.
#
#   ./scripts/seed-service-client.sh <clientId> [scope,scope,...]
#   ./scripts/seed-service-client.sh cursos-service users.profile.read
#
# When one micro calls another there is NO user behind it, so it authenticates
# with its own credentials and asks for a service token. The Identity team
# issues those credentials — that is, this script — because the table is ours.
#
# It is a script and not a Flyway migration on purpose: registering a client
# is a manual procedure. A migration would also run in production and sow a
# secret there that nobody chose.
#
# The secret is printed a single time and is not stored anywhere. It is passed
# to the owning team through a private channel; if it is lost, run this again
# (the registration is idempotent: it deletes and recreates).
set -euo pipefail

cd "$(dirname "$0")/.."

CLIENT_ID="${1:-}"
SCOPES="${2:-users.profile.read}"

if [ -z "$CLIENT_ID" ]; then
  cat >&2 <<'USAGE'
Missing the clientId.

  ./scripts/seed-service-client.sh <clientId> [comma-separated scopes]

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

[ -f .env ] || { echo "Missing .env. Copy it from .env.example." >&2; exit 1; }
set -a; . ./.env; set +a

SECRET="$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)"

# BCrypt cost 12, the project standard. htpasswd comes from a throwaway image
# so we do not depend on it being installed on the machine.
HASH="$(docker run --rm httpd:alpine htpasswd -bnBC 12 "" "$SECRET" 2>/dev/null | tr -d ':\r\n')"
case "$HASH" in
  '$2'*) ;;
  *) echo "Could not generate the BCrypt hash." >&2; exit 1 ;;
esac

ID="$(python -c 'import uuid;print(uuid.uuid4())')"

SQL="SET @id='${ID}';
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

docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users -e "$SQL"

cat <<FIN

  Service client registered
    client_id: ${CLIENT_ID}
    scopes:    ${SCOPES}

  clientSecret (printed a single time):

    ${SECRET}

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
