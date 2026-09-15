#!/usr/bin/env bash
# Destraba una cuenta que quedo en PENDING_COURSE, publicando el evento que en
# la plataforma real publica Cursos (Tema 02).
#
#   ./scripts/resolver-padron.sh alumno@utn.edu.ar
#
# Un alumno que activa su email NO queda habilitado: pasa a PENDING_COURSE y
# espera a que Cursos valide su padron. Esa validacion llega por Kafka, en el
# topico course-events, y no hay ningun endpoint HTTP que la dispare — es
# asincronica a proposito (DEC-09). Mientras tanto la persona solo puede
# hablar con /api/users/**.
#
# Este script se hace pasar por Cursos. Es una herramienta de DESARROLLO: en la
# plataforma real el evento lo manda el otro equipo y nosotros solo lo
# consumimos.
set -euo pipefail

cd "$(dirname "$0")/.."

EMAIL="${1:-}"
RESULTADO="${2:-APROBADO}"

if [ -z "$EMAIL" ]; then
  cat >&2 <<'USO'
Falta el email.

  ./scripts/resolver-padron.sh <email> [APROBADO|RECHAZADO]

Para ver quien esta esperando:

  docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users \
    -e "SELECT email, account_status FROM users WHERE account_status='PENDING_COURSE';"
USO
  exit 1
fi

[ -f .env ] || { echo "Falta .env. Copialo de .env.example." >&2; exit 1; }
set -a; . ./.env; set +a

sql() { docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users -N -B -e "$1" 2>/dev/null; }

USER_ID="$(sql "SELECT id FROM users WHERE email='${EMAIL}' AND deleted_at IS NULL LIMIT 1;")"
ESTADO="$(sql "SELECT account_status FROM users WHERE email='${EMAIL}' AND deleted_at IS NULL LIMIT 1;")"

if [ -z "$USER_ID" ]; then
  echo "No existe ninguna cuenta con ese email." >&2
  exit 1
fi

case "$ESTADO" in
  PENDING_COURSE) ;;
  PENDING_EMAIL)
    echo "La cuenta esta en PENDING_EMAIL: todavia no activo el email." >&2
    echo "Abri primero el enlace de activacion (esta en el buzon: boton 📬 del front)." >&2
    exit 1 ;;
  ACTIVE)
    echo "La cuenta ya esta ACTIVE. No hay nada que destrabar."
    exit 0 ;;
  *)
    echo "La cuenta esta en ${ESTADO}; este script solo resuelve PENDING_COURSE." >&2
    exit 1 ;;
esac

EVENT_ID="$(python -c 'import uuid;print(uuid.uuid4())')"
AHORA="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# El listener es idempotente por eventId (DEC-13): un eventId repetido se
# descarta en silencio, por eso cada corrida genera uno nuevo.
EVENTO="{\"eventId\":\"${EVENT_ID}\",\"eventType\":\"COURSE-VALIDATION-RESOLVED\",\"eventVersion\":1,\"producer\":\"tema-02-cursos\",\"timestamp\":\"${AHORA}\",\"payload\":{\"userId\":\"${USER_ID}\",\"result\":\"${RESULTADO}\",\"courseId\":\"prog4-2026\"}}"

# MSYS_NO_PATHCONV: en Git Bash sobre Windows, /opt/... se reescribe a una ruta
# de Windows antes de llegar al contenedor y el exec falla diciendo que no
# existe el script. El // del path es la otra mitad del mismo truco.
echo "$EVENTO" | MSYS_NO_PATHCONV=1 docker compose exec -T kafka \
  //opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic "${TOPIC_COURSE_VALIDATION:-course-events}" 2>/dev/null

# El consumo es asincronico: dar por bueno sin mirar seria mentir.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  NUEVO="$(sql "SELECT account_status FROM users WHERE email='${EMAIL}' LIMIT 1;")"
  [ "$NUEVO" != "PENDING_COURSE" ] && break
done

echo
echo "  ${EMAIL}"
echo "  ${ESTADO}  ->  ${NUEVO}"
echo

if [ "$NUEVO" = "ACTIVE" ]; then
  cat <<'FIN'
  Ojo: el token que ya tenes en el navegador SIGUE diciendo PENDING_COURSE.
  Los portones se evaluan contra los claims del token, no contra la base, asi
  que hay que VOLVER A LOGUEARSE para que el token nuevo traiga est=ACTIVE.
  La pantalla de cuenta pendiente lo detecta sola con su boton "Verificar
  estado" y te ofrece re-loguearte.
FIN
else
  echo "  El evento se publico pero el estado no cambio. Mira los logs:"
  echo "    docker compose logs --tail=50 users-service"
fi
