#!/usr/bin/env bash
# Unblocks an account stuck in PENDING_COURSE by publishing the event that
# Courses (Theme 02) publishes on the real platform.
#
#   ./scripts/resolver-padron.sh alumno@utn.edu.ar
#
# A student who activates their email is NOT enabled: they move to
# PENDING_COURSE and wait for Courses to validate their padron. That
# validation arrives over Kafka, on the course-events topic, and no HTTP
# endpoint triggers it — it is asynchronous on purpose (DEC-09). Meanwhile the
# person can only talk to /api/users/**.
#
# This script poses as Courses. It is a DEVELOPMENT tool: on the real platform
# the other team sends the event and we only consume it.
set -euo pipefail

cd "$(dirname "$0")/.."

EMAIL="${1:-}"
RESULT="${2:-APROBADO}"

if [ -z "$EMAIL" ]; then
  cat >&2 <<'USAGE'
Missing the email.

  ./scripts/resolver-padron.sh <email> [APROBADO|RECHAZADO]

To see who is waiting:

  MYSQL_PWD="$(vault kv get -mount=secret -field=password tpi/identity/db)" \
  docker compose exec -T -e MYSQL_PWD mysql mysql -uroot users \
    -e "SELECT email, account_status FROM users WHERE account_status='PENDING_COURSE';"
USAGE
  exit 1
fi

[ -f .env ] || { echo "Missing .env. Copy it from .env.example." >&2; exit 1; }
set -a; . ./.env; set +a
# shellcheck source=lib/vault.sh
. scripts/lib/vault.sh
vault_login

# The MySQL root password lives in Vault; it reaches the container through the
# environment, not the command line.
MYSQL_PWD="$(vault_cli kv get -mount=secret -field=password tpi/identity/db </dev/null)"
export MYSQL_PWD

sql() { docker compose exec -T -e MYSQL_PWD mysql mysql -uroot users -N -B -e "$1" 2>/dev/null; }

USER_ID="$(sql "SELECT id FROM users WHERE email='${EMAIL}' AND deleted_at IS NULL LIMIT 1;")"
STATE="$(sql "SELECT account_status FROM users WHERE email='${EMAIL}' AND deleted_at IS NULL LIMIT 1;")"

if [ -z "$USER_ID" ]; then
  echo "No account exists with that email." >&2
  exit 1
fi

case "$STATE" in
  PENDING_COURSE) ;;
  PENDING_EMAIL)
    echo "The account is in PENDING_EMAIL: the email was not activated yet." >&2
    echo "Open the activation link first (it is in the mailbox: the 📬 button of the front)." >&2
    exit 1 ;;
  ACTIVE)
    echo "The account is already ACTIVE. There is nothing to unblock."
    exit 0 ;;
  *)
    echo "The account is in ${STATE}; this script only resolves PENDING_COURSE." >&2
    exit 1 ;;
esac

EVENT_ID="$(python -c 'import uuid;print(uuid.uuid4())')"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The listener is idempotent by eventId (DEC-13): a repeated eventId is
# silently discarded, that is why each run generates a new one.
EVENT="{\"eventId\":\"${EVENT_ID}\",\"eventType\":\"COURSE-VALIDATION-RESOLVED\",\"eventVersion\":1,\"producer\":\"tema-02-cursos\",\"timestamp\":\"${NOW}\",\"payload\":{\"userId\":\"${USER_ID}\",\"result\":\"${RESULT}\",\"courseId\":\"prog4-2026\"}}"

# MSYS_NO_PATHCONV: on Git Bash over Windows, /opt/... gets rewritten to a
# Windows path before reaching the container and the exec fails saying the
# script does not exist. The // in the path is the other half of the same
# trick.
echo "$EVENT" | MSYS_NO_PATHCONV=1 docker compose exec -T kafka \
  //opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic "${TOPIC_COURSE_VALIDATION:-course-events}" 2>/dev/null

# Consumption is asynchronous: declaring success without looking would be a
# lie.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  NEW_STATE="$(sql "SELECT account_status FROM users WHERE email='${EMAIL}' LIMIT 1;")"
  [ "$NEW_STATE" != "PENDING_COURSE" ] && break
done

echo
echo "  ${EMAIL}"
echo "  ${STATE}  ->  ${NEW_STATE}"
echo

if [ "$NEW_STATE" = "ACTIVE" ]; then
  cat <<'SIGNED_OUT'
  Watch out: the token already in your browser STILL says PENDING_COURSE.
  The gates are evaluated against the token claims, not the database, so you
  must LOG IN AGAIN for the new token to carry est=ACTIVE. The pending-account
  screen detects it on its own with its "Verificar estado" button and offers
  you to re-login.
SIGNED_OUT
else
  echo "  The event was published but the state did not change. Check the logs:"
  echo "    docker compose logs --tail=50 users-service"
fi
