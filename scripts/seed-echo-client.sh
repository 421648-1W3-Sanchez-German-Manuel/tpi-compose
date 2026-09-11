#!/usr/bin/env bash
# El cliente de servicio de echo-service, que es un caso mas del general.
# Quedo como atajo porque el README y el .env.example lo nombran; lo que hace
# el trabajo es seed-service-client.sh.
#
#   ./scripts/seed-echo-client.sh
#
# El secreto que imprime va a ECHO_CLIENT_SECRET en el .env, y despues:
#   docker compose up -d --force-recreate echo-service
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Falta .env. Copialo de .env.example." >&2; exit 1; }
set -a; . ./.env; set +a

exec "$(dirname "$0")/seed-service-client.sh" \
  "${ECHO_CLIENT_ID:-echo-service}" \
  "${ECHO_SCOPES:-users.profile.read}"
