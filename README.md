# tpi-compose

Stack local de la Plataforma Gamificada TUP · Tema 01. Materializa **DEC-40**
(`api-gateway/docs/SPEC-api-gateway.md` §16).

El proyecto de Compose se llama `tpi-compose`, así que en Docker Desktop aparece
agrupado con ese nombre y no se mezcla con otros stacks.

## Estructura esperada

```
TPI/
├── users/           repo del users-service
├── api-gateway/     repo del gateway
├── echo-service/    servicio de prueba del subsistema
└── tpi-compose/     ← estás acá
```

El compose construye desde `../users`, `../api-gateway` y `../echo-service`:
los cuatro tienen que ser hermanos.

## Levantarlo

```bash
cd tpi-compose
bash ../users/scripts/gen-dev-keys.sh dev    # claves RS256 de desarrollo
cp .env.example .env                         # y completá MYSQL_ROOT_PASSWORD

docker compose up -d --build                 # la primera vez compila los tres servicios
docker compose logs -f api-gateway
```

`secrets/` y `.env` están en el `.gitignore` y no viajan con el repo. Sin las
claves RS256 el users-service **se niega a arrancar**, a propósito: un servicio
de identidad no tiene que levantar con claves improvisadas.

## Qué levanta

| Servicio | Imagen / build | Puerto |
|---|---|---|
| `eureka` | `steeltoeoss/eureka-server` | interno 8761 |
| `mysql` | `mysql:8.4` | interno 3306 |
| `redis` | `redis:7-alpine` | interno 6379 |
| `kafka` | `apache/kafka:3.8.0` (KRaft) | interno 9092 |
| `users-service` | `../users` | interno 8082 / 8083 |
| `api-gateway` | `../api-gateway` | **8080 publicado** |
| `echo-service` | `../echo-service` | interno 8084 / 8085 |

**El único puerto publicado del stack es el 8080 del gateway.** No es una
comodidad de despliegue: es el control de seguridad del que dependen todos los
demás. El users-service no valida el JWT, confía en los headers `X-*` porque el
gateway es la única entrada. Con el 8082 publicado, esto funciona sin password,
sin token y sin segundo factor:

```bash
curl -X DELETE http://localhost:8082/api/users/{id} -H "X-User-Roles: ADMIN"
```

Por eso `users-service` declara `expose:` y nunca `ports:`.

## Qué es propio y qué es de la plataforma

| | Dueño | En el compose |
|---|---|---|
| `mysql`, `redis` | del Tema 01, uno por servicio | definitivos |
| `eureka` | del Tema 01: solo lo usan el gateway y el users-service | imagen de terceros, **provisoria** hasta que exista el servidor propio |
| `kafka` | de la plataforma, infraestructura compartida | broker local de desarrollo |

Los topics `tema-01-users.*` son propios. Los otros dos pertenecen a otros
equipos: `tema-02-cursos.validacion-resuelta.v1` se consume, y
`tema-XX-notificaciones.email.v1` se produce para Notificaciones — ese `XX` es
literal, el contrato todavía no está cerrado.

> ⚠️ El Kafka local tiene `KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"`, por eso
> funciona sin que nadie cree nada. En el broker compartido eso suele estar
> apagado: los topics tienen que existir y estar acordados antes, o el
> `OutboxPoller` deja las filas pendientes reintentando.

## Probar que anda

El actuator del gateway vive en el 8081, que no está publicado. Desde el host se
prueba con una ruta real:

```bash
# 1. password del ADMIN inicial (se imprime UNA sola vez)
docker compose logs users-service | grep -A3 'INITIAL ADMIN CREATED'

# 2. fase 1 del login -> devuelve challengeId, sin tokens
curl -s -X POST http://localhost:8080/api/users/public/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@frc.utn.edu.ar","password":"LA-DEL-LOG"}'

# 3. el code de 2FA no llega por mail: queda en el outbox
source .env
docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users -N -B \
  -e "SELECT payload FROM outbox_events ORDER BY created_at DESC LIMIT 1;" \
  | grep -oE 'letter-spacing:4px[^0-9]*[0-9]{6}' | grep -oE '[0-9]{6}$'

# 4. fase 2 -> recién acá salen accessToken y refreshToken
curl -s -X POST http://localhost:8080/api/users/public/auth/2fa/verify \
  -H 'Content-Type: application/json' \
  -d '{"challengeId":"EL-DEL-PASO-2","code":"EL-DEL-PASO-3"}'
```

Y la comprobación que importa, la de seguridad: el users-service **no** tiene
que contestar desde el host.

```bash
curl -m 5 http://localhost:8082/api/users     # tiene que fallar la conexión
```

Si eso contesta algo, alguien le agregó `ports:` y el gateway dejó de ser la
única entrada.

## Trampas conocidas

- **El primer login después de levantar el stack puede devolver 503.** BCrypt
  cost 12 sobre una JVM fría se pasa del timeout del circuit breaker. Reintentar
  una vez alcanza. Si pasa siempre y no solo la primera, ahí sí es un problema.
- **Esperá ~4 segundos después de loguearte** antes de usar el token. El gateway
  cachea el estado de sesión 3 segundos. Lo mismo después de un logout.
- **No hay servidor de mail.** Los códigos y los enlaces de activación quedan
  encolados en `outbox_events`:

  ```bash
  docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users \
    -e "SELECT topic, published_at, LEFT(payload,200) FROM outbox_events \
        ORDER BY created_at DESC LIMIT 5\G"
  ```

- **Cambiar la password cierra la sesión.** Hay que volver a entrar.
- **Los límites por email son de 15 minutos**: 5 fallos de login, 5 desafíos de
  2FA y 3 pedidos de reset. Un `429` en desarrollo suele ser eso y no un bug.

## Comandos útiles

```bash
docker compose ps
docker compose logs -f users-service
docker compose exec redis redis-cli KEYS 'session:*'
docker compose restart users-service
docker compose down          # baja el stack, deja los datos
docker compose down -v       # + borra MySQL, Redis y Kafka
```
