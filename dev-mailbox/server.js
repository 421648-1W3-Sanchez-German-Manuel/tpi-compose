// Buzon de desarrollo. Lee outbox_events y devuelve los mails ya masticados:
// destinatario, tipo, y el codigo de 6 digitos o el enlace, que es lo unico
// que uno necesita para seguir un flujo a mano.
//
// ---------------------------------------------------------------------------
// ESTO NO VA A PRODUCCION. NI DETRAS DE UN FLAG.
//
// Lista tokens de activacion y codigos de 2FA de CUALQUIER cuenta: con esto
// publicado, cualquiera se apodera de cualquier usuario sin saber su password.
// Vive en un contenedor aparte, y no adentro de users-service, justamente para
// que este codigo no exista dentro de la imagen que se despliega. Apagarlo es
// borrar el servicio del compose; no hay que acordarse de ninguna variable.
// ---------------------------------------------------------------------------
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import mysql from 'mysql2/promise';
import { Kafka } from 'kafkajs';

const PORT = Number(process.env.PORT ?? 4300);
const LIMITE_MAX = 50;
const TOPIC_PADRON = process.env.TOPIC_COURSE_VALIDATION ?? 'tema-02-cursos.validacion-resuelta.v1';

const pool = mysql.createPool({
  host: process.env.DB_HOST ?? 'mysql',
  port: Number(process.env.DB_PORT ?? 3306),
  user: process.env.DB_USER ?? 'root',
  password: process.env.DB_PASSWORD ?? '',
  database: process.env.DB_NAME ?? 'users',
  connectionLimit: 4,
  // El poller de users-service borra o marca las filas; si el buzon se queda
  // con conexiones colgadas le come el pool a quien hace el trabajo real.
  waitForConnections: true,
});

/** El codigo de 2FA sale del HTML ya renderizado: <strong>123456</strong>. */
const codigoDe = (html) => html.match(/<strong>\s*(\d{6})\s*<\/strong>/)?.[1] ?? null;

/** El enlace de activacion o de reset, que es el unico http del cuerpo. */
const enlaceDe = (html) => html.match(/https?:\/\/[^\s"'<>]+/)?.[0] ?? null;

function aMail(fila) {
  let sobre;
  try {
    // `payload` es una columna JSON y mysql2 la devuelve YA parseada como
    // objeto. Hacerle JSON.parse tira, y como el error se traga fila por fila
    // el buzon contesta [] con la tabla llena: parece que no hay mails.
    sobre = typeof fila.payload === 'string' ? JSON.parse(fila.payload) : fila.payload;
  } catch {
    // Una fila ilegible no puede tumbar el buzon entero.
    return null;
  }
  const html = sobre?.payload?.html ?? '';
  return {
    id: fila.event_id,
    para: sobre?.payload?.to ?? null,
    asunto: sobre?.payload?.asunto ?? null,
    tipo: sobre?.eventType ?? null,
    fecha: fila.created_at,
    codigo: codigoDe(html),
    enlace: enlaceDe(html),
  };
}

async function mails(limite, email) {
  const filtrado = email ? 'WHERE JSON_UNQUOTE(JSON_EXTRACT(payload, "$.payload.to")) = ?' : '';
  const args = email ? [email, limite] : [limite];
  const [filas] = await pool.query(
    `SELECT event_id, payload, created_at FROM outbox_events ${filtrado}
     ORDER BY created_at DESC LIMIT ?`,
    args,
  );
  return filas.map(aMail).filter(Boolean);
}

// --- Padron -----------------------------------------------------------------
// Un alumno que activa su email NO queda habilitado: pasa a PENDING_COURSE y
// espera a que Cursos (Tema 02) valide su padron. Esa validacion llega por
// Kafka y NO hay endpoint HTTP que la dispare — es asincronica a proposito
// (DEC-09). Como el equipo de Cursos todavia no existe, nadie publica ese
// evento y la cuenta se queda esperando para siempre.
//
// Esto se hace pasar por Cursos. Publica el evento de verdad en vez de tocar
// la base a mano: asi ejercita el listener, la idempotencia por eventId y el
// mail de "padron resuelto". Un UPDATE directo daria el mismo estado final sin
// probar nada de eso, y taparia justo el pedazo que falla si falla.
const kafka = new Kafka({
  clientId: 'dev-mailbox',
  brokers: (process.env.KAFKA_BROKERS ?? 'kafka:9092').split(','),
  retry: { retries: 2 },
});

let productor;
async function publicar(mensaje) {
  if (!productor) {
    productor = kafka.producer();
    await productor.connect();
  }
  await productor.send({ topic: TOPIC_PADRON, messages: [{ value: JSON.stringify(mensaje) }] });
}

async function cuenta(email) {
  const [filas] = await pool.query(
    'SELECT id, email, account_status FROM users WHERE email = ? AND deleted_at IS NULL LIMIT 1',
    [email],
  );
  return filas[0] ?? null;
}

/** Las que estan esperando el padron: lo unico que este boton puede destrabar. */
async function pendientes() {
  const [filas] = await pool.query(
    `SELECT id, email FROM users
      WHERE account_status = 'PENDING_COURSE' AND deleted_at IS NULL
      ORDER BY created_at DESC LIMIT 20`,
  );
  return filas;
}

async function resolverPadron(email, resultado) {
  const u = await cuenta(email);
  if (!u) return { ok: false, estado: 404, error: 'No existe ninguna cuenta con ese email.' };

  if (u.account_status === 'ACTIVE') {
    return { ok: true, ya: true, de: 'ACTIVE', a: 'ACTIVE' };
  }
  if (u.account_status !== 'PENDING_COURSE') {
    return {
      ok: false,
      estado: 409,
      error:
        u.account_status === 'PENDING_EMAIL'
          ? 'Todavía no activó el email. Abrí primero el enlace de activación.'
          : `La cuenta está en ${u.account_status}; esto sólo resuelve PENDING_COURSE.`,
    };
  }

  // El listener es idempotente por eventId (DEC-13): uno repetido se descarta
  // en silencio, por eso cada pedido genera uno nuevo.
  await publicar({
    eventId: randomUUID(),
    eventType: 'VALIDACION_RESUELTA',
    producer: 'tema-02-cursos',
    timestamp: new Date().toISOString(),
    payload: { userId: u.id, resultado: resultado ?? 'APROBADO', cursoId: 'prog4-2026' },
  });

  // El consumo es asincronico: contestar sin mirar seria mentirle al que apreto.
  for (let i = 0; i < 15; i++) {
    await new Promise((r) => setTimeout(r, 400));
    const ahora = await cuenta(email);
    if (ahora && ahora.account_status !== 'PENDING_COURSE') {
      return { ok: true, de: 'PENDING_COURSE', a: ahora.account_status };
    }
  }
  return {
    ok: false,
    estado: 504,
    error: 'El evento se publicó pero el estado no cambió. Mirá los logs de users-service.',
  };
}

function leerCuerpo(req) {
  return new Promise((resolve, reject) => {
    let datos = '';
    req.on('data', (c) => {
      datos += c;
      if (datos.length > 4096) reject(new Error('cuerpo demasiado grande'));
    });
    req.on('end', () => {
      try {
        resolve(datos ? JSON.parse(datos) : {});
      } catch {
        reject(new Error('cuerpo ilegible'));
      }
    });
    req.on('error', reject);
  });
}

const servidor = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('Cache-Control', 'no-store');

  if (url.pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('ok\n');
  }

  const json = (codigo, cuerpo) => {
    res.writeHead(codigo, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(cuerpo));
  };

  if (url.pathname === '/dev/pendientes') {
    try {
      return json(200, await pendientes());
    } catch (e) {
      console.error('PENDIENTES_FALLO', e.message);
      return json(503, { error: 'la base no responde todavia' });
    }
  }

  if (url.pathname === '/dev/resolver-padron') {
    if (req.method !== 'POST') return json(405, { error: 'usa POST' });
    try {
      const { email, resultado } = await leerCuerpo(req);
      if (!email) return json(400, { error: 'falta email' });
      const r = await resolverPadron(email, resultado);
      return json(r.ok ? 200 : r.estado, r);
    } catch (e) {
      console.error('PADRON_FALLO', e.message);
      return json(500, { error: e.message });
    }
  }

  if (url.pathname !== '/' && url.pathname !== '/dev/mailbox') {
    return json(404, { error: 'no existe' });
  }

  try {
    const limite = Math.min(Number(url.searchParams.get('limit')) || 20, LIMITE_MAX);
    const cuerpo = await mails(limite, url.searchParams.get('email') || null);
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(cuerpo));
  } catch (e) {
    // Arrancar antes que MySQL es normal con docker compose: contestar 503 deja
    // que el front reintente en el proximo refresco en vez de romperse.
    console.error('BUZON_FALLO', e.message);
    res.writeHead(503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'la base no responde todavia' }));
  }
});

servidor.listen(PORT, () => console.log(`buzon de desarrollo en :${PORT}`));
