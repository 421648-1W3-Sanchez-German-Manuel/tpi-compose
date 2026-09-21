# tpi-compose

Stack local de la Plataforma Gamificada TUP · Tema 01 (Identidad y Usuarios).
Materializa **DEC-40** (`api-gateway/docs/SPEC-api-gateway.md` §16).

> **¿Venís de otro equipo y querés que el Gateway rutee tu micro?**
> Andá derecho a [Sumar un microservicio de otro equipo](#sumar-un-microservicio-de-otro-equipo).

## Estructura esperada

```
TPI/
├── users/            repo del users-service
├── api-gateway/      repo del gateway
├── frontend-users/   la SPA de Angular
└── tpi-compose/      ← estás acá
```

El compose construye desde `../users`, `../api-gateway` y `../frontend-users`:
los repos tienen que ser hermanos de `tpi-compose`.

## Levantarlo

```bash
cd tpi-compose
bash ../users/scripts/gen-dev-keys.sh dev    # claves RS256 de desarrollo
cp .env.example .env                         # y completá MYSQL_ROOT_PASSWORD

docker compose up -d --build                 # la primera vez compila los servicios propios
docker compose logs -f api-gateway
```

`secrets/` y `.env` están en el `.gitignore` y no viajan con el repo. Sin las
claves RS256 el users-service **se niega a arrancar**, a propósito: un servicio
de identidad no tiene que levantar con claves improvisadas.

## Topología

```
                          ┌──► webapp (Angular)   [tpi-front]
navegador ──► nginx :3000 ─┤
              [tpi-edge]   └──► api-gateway ──► users-service
                                [tpi-platform]  (y los que vengan)
```

El front y la API salen por el **mismo origen** (`:3000`). De ahí que no exista
preflight y no haya CORS que configurar en ninguna parte.

| Red | Quién vive ahí | Para qué |
|---|---|---|
| `tpi-front` | nginx + `webapp` | El front **no comparte red con el gateway**: no hay forma de pegarle directo, ni por error |
| `tpi-edge` | nginx + api-gateway | Dos miembros y punto |
| **`tpi-platform`** | gateway, eureka, kafka, los micros | **La red compartida.** Es a la que se enganchan los otros equipos |
| `tpi-data` | mysql + redis (+ quien los usa) | Fuera de la red compartida: un micro ajeno se registra en Eureka, no le habla a nuestra base |

| Servicio | Imagen / build | Puerto |
|---|---|---|
| `nginx` | `nginx:1.27-alpine` | **3000 publicado** |
| `webapp` | `../frontend-users` | interno 4200 |
| `eureka` | `steeltoeoss/eureka-server` | **8761 publicado** (es el registro) |
| `api-gateway` | `../api-gateway` | interno 8080 / 8081 |
| `users-service` | `../users` | interno 8082 / 8083 |
| `mysql` | `mysql:8.4` | interno 3306 |
| `redis` | `redis:7-alpine` | interno 6379 |
| `kafka` | `apache/kafka:3.8.0` (KRaft) | interno 9092 |

### Por qué los micros no publican puerto

El users-service no valida el JWT: confía en los headers `X-*` **porque el
gateway es la única entrada**. Con el 8082 publicado, esto funciona sin
password, sin token y sin segundo factor:

```bash
curl -X DELETE http://localhost:8082/api/users/{id} -H "X-User-Roles: ADMIN"
```

Por eso todo lleva `expose:` y nunca `ports:`. Esa línea del compose **es** el
control de seguridad, no un detalle de despliegue. Lo mismo vale para tu micro.

### Por qué hay un proxy reverso adelante

Dos razones, y las dos son estructurales:

1. **El navegador habla con un solo origen** (`:3000`), así que no hay preflight
   y **no hace falta CORS en ningún lado**. Un CORS mal puesto es una
   vulnerabilidad; no tener que ponerlo es mejor que ponerlo bien.
2. **El gateway deja de publicar puerto.** El front vive en `tpi-front` y el
   gateway en `tpi-edge`: sin red en común, no hay ruta.

Ver `nginx/nginx.conf`. El contenedor del front vive **solo** en `tpi-front`,
sin membresía en `tpi-edge` ni en `tpi-platform`: desde ahí no hay ruta al
gateway ni a los micros. Todo lo que el navegador pide a `/api` lo reenvía el
proxy. Los estáticos los sirve el nginx interno del front
(`frontend-users/nginx.conf`), con `try_files` para que un `/activate?token=...`
abierto directo desde el mail llegue al Router de Angular.

### Por qué Eureka sí publica puerto

Es la única excepción a "un solo puerto público", y es deliberada: un equipo que
corre su micro desde el IDE necesita una dirección a la cual registrarse.
**Publicar el registro no expone nada**: Eureka solo dice quién está vivo, y
estar registrado **no alcanza** para que el gateway te rutee.

---

## Sumar un microservicio de otro equipo

Descubrimiento y exposición son dos cosas distintas.

- **El descubrimiento es automático.** Te registrás en Eureka y el gateway
  resuelve tus instancias solo: escalás, reiniciás o cambiás de IP y nadie toca
  nada.
- **La exposición no lo es, a propósito.** Hasta que tu `serviceId` esté en la
  allowlist, `/api/lo-tuyo/**` devuelve 404 aunque estés registrado. Con doce
  equipos sumando servicios, exponer algo sin querer pesa más que el trámite.

### Lo que hace el equipo que se suma

**1 · El nombre.** `spring.application.name = cursos-service`. De ahí sale tu
path: minúsculas, sin el sufijo `-service`, o sea `/api/cursos/**`. El mismo
string es tu `serviceId` en Eureka, tu entrada en la allowlist, tu `audience` y
tu `X-Service-Id`. Elegilo una vez.

**2 · El registro.**

```yaml
eureka:
  client:
    service-url:
      defaultZone: ${EUREKA_URL:http://eureka:8761/eureka/}
    register-with-eureka: true
    fetch-registry: false        # SOLO el Gateway tiene true
    healthcheck:
      enabled: true              # publica tu readiness, no el mero heartbeat
  instance:
    prefer-ip-address: true
```

**3 · La red.** En tu `docker-compose.yml`:

```yaml
services:
  cursos-service:
    expose: ["8080"]             # NUNCA ports:
    environment:
      EUREKA_URL: http://eureka:8761/eureka/
    networks: [tpi-platform]

networks:
  tpi-platform:
    external: true               # la crea el stack de Identidad
```

Nuestro stack tiene que estar arriba primero — cosa que igual necesitás, porque
ahí viven Eureka y el gateway. Si corrés desde el IDE en vez de Docker, apuntá a
`http://localhost:8761/eureka/`.

**4 · El contrato.** Rutas bajo `/api/cursos/**` (el path **no se reescribe**, lo
recibís entero), lo público bajo `/api/cursos/public/**`, un filtro que arme el
principal desde `X-Principal-Type` / `X-User-Id` / `X-User-Roles` y rechace si
falta el primero, errores en `problem+json`, y `/actuator/health/readiness`
respondiendo. Todo el detalle está en la skill `integrar-con-identidad` del
harness de cualquiera de los dos repos.

**5 · Avisarle a Identidad** el nombre exacto, para el alta en la allowlist.

### Lo que hace Identidad

```bash
# 1. allowlist: agregar el serviceId en .env y recrear el gateway
#    GATEWAY_ALLOWLIST=users-service,cursos-service
docker compose up -d api-gateway

# 2. si además va a LLAMAR a otro micro, sus credenciales de servicio
./scripts/seed-service-client.sh cursos-service users.profile.read
#    imprime el clientSecret UNA vez -> se lo pasás por un canal privado
```

### Verificar, de los dos lados

```bash
# ¿se registró?
curl -s http://localhost:8761/eureka/apps | grep -o '<name>[^<]*</name>'

# ¿lo rutea el gateway?
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/api/cursos/loquesea
#   404 -> no está en la allowlist
#   503 -> está en la allowlist, sin instancias UP (Retry-After en el header)
#   401 -> está ruteado; falta el token, que es lo esperable sin uno
```

### Llamar a users desde otro micro

No hay llamadas directas: A → Gateway → B, con un token de servicio.

```bash
curl -s -X POST http://localhost:3000/api/users/public/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"clientId":"cursos-service","clientSecret":"...",
       "grantType":"client_credentials",
       "scope":"users.profile.read","audience":"users-service"}'
```

> ⚠️ **`grantType` es obligatorio.** Si falta, la respuesta es `400 validation`
> con `"grantType: must not be blank"`, que se lee como "mis credenciales están
> mal" y manda a buscar el problema donde no está.

El token dura 5 minutos, lleva rol `MS` y **solo sirve contra el `audience` que
pidió**: contra cualquier otro destino da `403 invalid-audience`. El catálogo de
scopes es cerrado (hoy solo `users.profile.read`) y sumar uno es un cambio en
`ScopeCatalog.java` de users-service, no configuración: pedilo con tiempo.

---

## Qué es propio y qué es de la plataforma

| | Dueño | En el compose |
|---|---|---|
| `mysql`, `redis` | del Tema 01, uno por servicio | definitivos, en `tpi-data` |
| `eureka` | registro de la plataforma | imagen de terceros, **provisoria** hasta que exista el servidor propio |
| `kafka` | de la plataforma, infraestructura compartida | broker local de desarrollo, en `tpi-platform` |

Los topics de dominio son propios o de contrato: `user-events` se produce,
`course-events` se consume (Cursos), y `notification-events` se produce para
Notificaciones. Los nombres viejos (`tema-01-users.*`,
`tema-02-cursos.validacion-resuelta.v1`, `tema-XX-notificaciones.email.v1`)
quedan como referencia histórica; el contrato con esos equipos todavía puede
ajustarse.

> ⚠️ El Kafka local tiene `KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"`, por eso
> funciona sin que nadie cree nada. En el broker compartido eso suele estar
> apagado: los topics tienen que existir y estar acordados antes, o el
> `OutboxPoller` deja las filas pendientes reintentando.

## Probar que anda

```bash
# 1. password del ADMIN inicial (se imprime UNA sola vez)
docker compose logs users-service | grep -A3 'INITIAL ADMIN CREATED'

# 2. fase 1 del login -> devuelve challengeId, sin tokens
curl -s -X POST http://localhost:3000/api/users/public/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@frc.utn.edu.ar","password":"LA-DEL-LOG"}'

# 3. el code de 2FA no llega por mail: queda en el outbox
source .env
docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users -N -B \
  -e "SELECT payload FROM outbox_events ORDER BY created_at DESC LIMIT 1;" \
  | grep -oE 'letter-spacing:4px[^0-9]*[0-9]{6}' | grep -oE '[0-9]{6}$'

# 4. fase 2 -> recién acá salen accessToken y refreshToken
curl -s -X POST http://localhost:3000/api/users/public/auth/2fa/verify \
  -H 'Content-Type: application/json' \
  -d '{"challengeId":"EL-DEL-PASO-2","code":"EL-DEL-PASO-3"}'
```

Y las comprobaciones que importan, las de seguridad:

```bash
curl -m 5 http://localhost:8082/api/users     # users-service: tiene que fallar
curl -m 5 http://localhost:8080/api/users     # gateway: tiene que fallar
```

Si alguna de las dos contesta algo, alguien agregó `ports:` y el proxy dejó de
ser la única entrada.

## Resiliencia · qué hay puesto

La cadena completa del manifiesto (§"patrones aplicados"), cada capa cubriendo
una falla distinta:

| capa | dónde |
|---|---|
| rate limit | `RateLimitFilter` @Order(80), por IP en las rutas caras |
| bulkhead | `BulkheadFilter` @Order(90), concurrencia máxima **por destino** |
| timeout | `TimeLimiter` 3s en `ResilienceConfig` |
| retry | filtro `Retry` del gateway, **solo GET**, 1 reintento con backoff |
| circuit breaker | Resilience4j, ventana de 20, abre al 50% de fallos |
| fallback | `FallbackController` → 503 + `Retry-After` |

Para comprobar que el bulkhead está vivo:

```bash
BULKHEAD_MAX_CONCURRENT=1 docker compose up -d --force-recreate api-gateway
for i in $(seq 1 10); do (curl -s -o /dev/null -w '%{http_code} ' \
  http://localhost:3000/api/users/public/legal/terms) & done; wait
# esperado: nueve 503 y un 200, con lineas BULKHEAD_LLENO en el log
docker compose up -d --force-recreate api-gateway   # volver a 64
```

## Trampas conocidas

- **El primer login después de levantar el stack puede devolver 503.** BCrypt
  cost 12 sobre una JVM fría se pasa del timeout del circuit breaker. Reintentar
  una vez alcanza. Si pasa siempre y no solo la primera, ahí sí es un problema.
- **Esperá ~4 segundos después de loguearte** antes de usar el token. El gateway
  cachea el estado de sesión 3 segundos. Lo mismo después de un logout.
- **Una ruta inexistente da 401 y no 404 si el request no trae token.** La
  cadena de Security corre antes que el ruteo. Con token válido sí da
  `404 route-not-found`.
- **No hay servidor de mail.** Los códigos y los enlaces de activación quedan
  encolados en `outbox_events`. Se consultan por consola:

  ```bash
  docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" users \
    -e "SELECT topic, published_at, LEFT(payload,200) FROM outbox_events \
        ORDER BY created_at DESC LIMIT 5\G"
  ```

- **Si tu `.env` es viejo, `USERS_FRONT_URL` dice `:4200` y los enlaces de
  activación y de reset del mail quedan muertos** — ese puerto no se publica.
  Tiene que decir `http://localhost:3000`. El `.env.example` ya está bien; el
  `.env` de cada uno no se actualiza solo.
- **Cambiar la password cierra la sesión.** Hay que volver a entrar.
- **Los límites por email son de 15 minutos**: 5 fallos de login, 5 desafíos de
  2FA y 3 pedidos de reset. Un `429` en desarrollo suele ser eso y no un bug.

## Comandos útiles

```bash
docker compose ps
docker compose logs -f users-service
docker compose exec redis redis-cli KEYS 'session:*'
curl -s http://localhost:8761/eureka/apps | grep -o '<name>[^<]*</name>'
docker compose restart users-service
docker compose down          # baja el stack, deja los datos
docker compose down -v       # + borra MySQL, Redis y Kafka
```
