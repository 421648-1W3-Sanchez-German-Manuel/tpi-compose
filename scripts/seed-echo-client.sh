#!/usr/bin/env bash
# echo-service's service client, which is one more case of the general one.
# It stayed as a shortcut because the README and the .env.example name it; the
# one that does the work is seed-service-client-v2.sh.
#
#   ./scripts/seed-echo-client.sh
#
# echo-service still takes its secret from an environment variable, so this
# prints it once (--legacy-print) in addition to storing it in Vault. The secret
# it prints goes to ECHO_CLIENT_SECRET in the .env, and then:
#   docker compose up -d --force-recreate echo-service
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Missing .env. Copy it from .env.example." >&2; exit 1; }
set -a; . ./.env; set +a

exec "$(dirname "$0")/seed-service-client-v2.sh" \
  "${ECHO_CLIENT_ID:-echo-service}" \
  "${ECHO_SCOPES:-users.profile.read}" \
  --legacy-print
