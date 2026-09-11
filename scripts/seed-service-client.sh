#!/usr/bin/env bash
# Da de alta un cliente de servicio (client_credentials) en users-service.
#
#   ./scripts/seed-service-client.sh <clientId> [scope,scope,...]
#   ./scripts/seed-service-client.sh cursos-service users.profile.read
#
# Cuando un micro llama a otro NO hay usuario detras, asi que se autentica con
# credenciales propias y pide un token de servicio. Esas credenciales las emite
# el equipo de Identidad — o sea, este script — porque la tabla es nuestra.
#
# Es un script y no una migracion de Flyway a proposito: dar de alta un cliente
# es un tramite manual. Una migracion correria tambien en produccion y sembraria
# ahi un secreto que nadie eligio.
#
# El secreto se imprime UNA sola vez y no queda guardado en ningun lado. Se le
# pasa al equipo dueno por un canal privado; si se pierde, se vuelve a correr
# esto (el alta es idempotente: borra y recrea).
set -euo pipefail

cd "$(dirname "$0")/.."

CLIENT_ID="${1:-}"
SCOPES="${2:-users.profile.read}"

if [ -z "$CLIENT_ID" ]; then
  cat >&2 <<'USO'
Falta el clientId.

  ./scripts/seed-service-client.sh <clientId> [scopes separados por coma]

El clientId por convencion es el serviceId con el que el micro se registra en
Eureka (cursos-service, desafios-service). Es lo que despues viaja en el `sub`
del token y en el header X-Service-Id, asi que que coincida ahorra sorpresas.

Scopes emitibles hoy (ScopeCatalog de users-service, catalogo CERRADO):
  users.profile.read   -> audience users-service

Un scope que no este en ese catalogo se rechaza AL EMITIR, no al usar. Sumar
uno es tocar ScopeCatalog.java y desplegar users-service.
USO
  exit 1
fi

[ -f .env ] || { echo "Falta .env. Copialo de .env.example." >&2; exit 1; }
set -a; . ./.env; set +a

SECRET="$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)"

# BCrypt cost 12, el estandar del proyecto. htpasswd sale de una imagen
# descartable para no depender de que este instalado en la maquina.
HASH="$(docker run --rm httpd:alpine htpasswd -bnBC 12 "" "$SECRET" 2>/dev/null | tr -d ':\r\n')"
case "$HASH" in
  '$2'*) ;;
  *) echo "No se pudo generar el hash BCrypt." >&2; exit 1 ;;
esac

ID="$(python -c 'import uuid;print(uuid.uuid4())')"

SQL="SET @id='${ID}';
DELETE s FROM service_client_scopes s
  JOIN service_clients c ON c.id = s.service_client_id
  WHERE c.client_id = '${CLIENT_ID}';
DELETE FROM service_clients WHERE client_id = '${CLIENT_ID}';
INSERT INTO service_clients (id, client_id, secret_hash, description, created_at)
  VALUES (@id, '${CLIENT_ID}', '${HASH}', 'Cliente de servicio de ${CLIENT_ID}', UTC_TIMESTAMP(6));"
for sc in $(echo "$SCOPES" | tr ',' ' '); do
  SQL="${SQL}
INSERT INTO service_client_scopes (service_client_id, scope) VALUES (@id, '${sc}');"
done

docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users -e "$SQL"

cat <<FIN

  Cliente de servicio dado de alta
    client_id: ${CLIENT_ID}
    scopes:    ${SCOPES}

  clientSecret (se imprime UNA sola vez):

    ${SECRET}

  Como lo usa el equipo dueno — OJO con grantType, es obligatorio:

    POST http://localhost:3000/api/users/public/auth/token
    {
      "clientId":     "${CLIENT_ID}",
      "clientSecret": "...",
      "grantType":    "client_credentials",
      "scope":        "${SCOPES%%,*}",
      "audience":     "users-service"
    }

  El token dura 5 minutos, lleva rol MS y solo sirve contra el \`audience\` que
  pidio. Contra cualquier otro destino: 403 invalid-audience.

FIN
