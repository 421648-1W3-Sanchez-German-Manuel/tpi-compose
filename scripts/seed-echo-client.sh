#!/usr/bin/env bash
# Da de alta el cliente de servicio de echo-service.
#
# Es un script y no una migracion de Flyway a proposito: dar de alta un cliente
# es un tramite manual y unico del equipo de Identidad. Una migracion correria
# tambien en produccion y sembraria ahi un secreto que nadie eligio.
#
# El secreto se imprime UNA sola vez. Va al .env, nunca al repo.
#
#   ./scripts/seed-echo-client.sh
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Falta .env. Copialo de .env.example." >&2; exit 1; }
set -a; . ./.env; set +a

CLIENT_ID="${ECHO_CLIENT_ID:-echo-service}"
SCOPES="${ECHO_SCOPES:-users.profile.read}"

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
  VALUES (@id, '${CLIENT_ID}', '${HASH}', 'Servicio de prueba del subsistema', UTC_TIMESTAMP(6));"
for sc in $(echo "$SCOPES" | tr ',' ' '); do
  SQL="${SQL}
INSERT INTO service_client_scopes (service_client_id, scope) VALUES (@id, '${sc}');"
done

docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users -e "$SQL"

echo
echo "  Cliente de servicio dado de alta"
echo "    client_id: ${CLIENT_ID}"
echo "    scopes:    ${SCOPES}"
echo
echo "  ECHO_CLIENT_SECRET=${SECRET}"
echo
echo "  Pegalo en .env y recrea el contenedor:"
echo "    docker compose up -d --force-recreate echo-service"
