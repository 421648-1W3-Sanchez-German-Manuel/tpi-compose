// Development mailbox. Reads outbox_events and returns the mail already
// chewed: recipient, type, and the 6-digit code or the link, which is the only
// thing one needs to follow a flow by hand. It also serves /dev/logs, the
// micro-to-micro trace that the Gateway leaves in Redis: where each call went,
// with status and timing. That does not come from the database: it comes from
// the `intermicro:trace` list written by api-gateway.
//
// ---------------------------------------------------------------------------
// THIS DOES NOT GO TO PRODUCTION. NOT EVEN BEHIND A FLAG.
//
// It lists activation tokens and 2FA codes of ANY account: with this
// published, anyone can take over any user without knowing their password. It
// lives in a separate container, and not inside users-service, precisely so
// this code does not exist inside the image that gets deployed. Turning it off
// is deleting the service from the compose; no variable to remember.
// ---------------------------------------------------------------------------
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import mysql from 'mysql2/promise';
import { Kafka } from 'kafkajs';
import Redis from 'ioredis';

const PORT = Number(process.env.PORT ?? 4300);
const MAX_LIMIT = 50;
const LOGS_MAX_LIMIT = 200;
const COURSE_VALIDATION_TOPIC = process.env.TOPIC_COURSE_VALIDATION ?? 'course-events';

// The trace list the Gateway writes (InterMicroTraceFilter) with one entry per
// call routed to a micro: origin (person/service), destination, timing and
// status. The mailbox reads it for the Logs tab; it never writes it.
const REDIS_KEY_TRACE = 'intermicro:trace';

// lazyConnect on purpose: the mailbox starts along with the stack and Redis
// (and the rest) may take a while; without this a failed connection at boot
// would bring the whole container down. It only connects when someone opens
// /dev/logs.
const redis = new Redis({
  host: process.env.REDIS_HOST ?? 'redis',
  port: Number(process.env.REDIS_PORT ?? 6379),
  lazyConnect: true,
  maxRetriesPerRequest: 1,
});

// DB_PASSWORD_FILE (a file written by the Vault Agent) wins over DB_PASSWORD.
const dbPassword = process.env.DB_PASSWORD_FILE
  ? readFileSync(process.env.DB_PASSWORD_FILE, 'utf8').trim()
  : (process.env.DB_PASSWORD ?? '');

const pool = mysql.createPool({
  host: process.env.DB_HOST ?? 'mysql',
  port: Number(process.env.DB_PORT ?? 3306),
  user: process.env.DB_USER ?? 'root',
  password: dbPassword,
  database: process.env.DB_NAME ?? 'users',
  connectionLimit: 4,
  // The users-service poller deletes or marks the rows; if the mailbox keeps
  // hanging connections it eats the pool of whoever does the real work.
  waitForConnections: true,
});

/** The 2FA code comes out of the already-rendered HTML: <strong>123456</strong>. */
const extractCode = (html) => html.match(/<strong>\s*(\d{6})\s*<\/strong>/)?.[1] ?? null;

/** The activation or reset link, the only http in the body. */
const extractLink = (html) => html.match(/https?:\/\/[^\s"'<>]+/)?.[0] ?? null;

function toMail(row) {
  let envelope;
  try {
    // `payload` is a JSON column and mysql2 returns it ALREADY parsed as an
    // object. JSON.parsing it throws, and since the error is swallowed row by
    // row the mailbox answers [] with a full table: it looks like there are no
    // mails.
    envelope = typeof row.payload === 'string' ? JSON.parse(row.payload) : row.payload;
  } catch {
    // An unreadable row must not take the whole mailbox down.
    return null;
  }
  const html = envelope?.payload?.html ?? '';
  return {
    id: row.event_id,
    para: envelope?.payload?.to ?? null,
    asunto: envelope?.payload?.subject ?? null,
    tipo: envelope?.eventType ?? null,
    fecha: row.created_at,
    codigo: extractCode(html),
    enlace: extractLink(html),
  };
}

async function listMails(limit, email) {
  const filter = email ? 'WHERE JSON_UNQUOTE(JSON_EXTRACT(payload, "$.payload.to")) = ?' : '';
  const args = email ? [email, limit] : [limit];
  const [rows] = await pool.query(
    `SELECT event_id, payload, created_at FROM outbox_events ${filter}
     ORDER BY created_at DESC LIMIT ?`,
    args,
  );
  return rows.map(toMail).filter(Boolean);
}

// --- Padron -----------------------------------------------------------------
// A student who activates their email is NOT enabled: they move to
// PENDING_COURSE and wait for Courses (Theme 02) to validate their padron.
// That validation arrives over Kafka and there is NO HTTP endpoint that
// triggers it — it is asynchronous on purpose (DEC-09). Since the Courses team
// does not exist yet, nobody publishes that event and the account waits
// forever.
//
// This poses as Courses. It publishes the real event instead of touching the
// database by hand: that exercises the listener, the idempotency by eventId
// and the "padron resolved" mail. A direct UPDATE would reach the same final
// state without testing any of that, and would cover exactly the piece that
// fails when it fails.
const kafka = new Kafka({
  clientId: 'dev-mailbox',
  brokers: (process.env.KAFKA_BROKERS ?? 'kafka:9092').split(','),
  retry: { retries: 2 },
});

let producer;
async function publish(message) {
  if (!producer) {
    producer = kafka.producer();
    await producer.connect();
  }
  await producer.send({ topic: COURSE_VALIDATION_TOPIC, messages: [{ value: JSON.stringify(message) }] });
}

async function findAccount(email) {
  const [rows] = await pool.query(
    'SELECT id, email, account_status FROM users WHERE email = ? AND deleted_at IS NULL LIMIT 1',
    [email],
  );
  return rows[0] ?? null;
}

/** The ones waiting for the padron: the only thing this button can unblock. */
async function listPending() {
  const [rows] = await pool.query(
    `SELECT id, email FROM users
      WHERE account_status = 'PENDING_COURSE' AND deleted_at IS NULL
      ORDER BY created_at DESC LIMIT 20`,
  );
  return rows;
}

async function resolvePadron(email, result) {
  const account = await findAccount(email);
  if (!account) return { ok: false, estado: 404, error: 'No account exists with that email.' };

  if (account.account_status === 'ACTIVE') {
    return { ok: true, ya: true, de: 'ACTIVE', a: 'ACTIVE' };
  }
  if (account.account_status !== 'PENDING_COURSE') {
    return {
      ok: false,
      estado: 409,
      error:
        account.account_status === 'PENDING_EMAIL'
          ? 'The email was not activated yet. Open the activation link first.'
          : `The account is in ${account.account_status}; this only resolves PENDING_COURSE.`,
    };
  }

  // The listener is idempotent by eventId (DEC-13): a repeated one is
  // silently discarded, that is why each request generates a new one.
  await publish({
    eventId: randomUUID(),
    eventType: 'COURSE-VALIDATION-RESOLVED',
    eventVersion: 1,
    producer: 'tema-02-cursos',
    timestamp: new Date().toISOString(),
    payload: { userId: account.id, result: result ?? 'APROBADO', courseId: 'prog4-2026' },
  });

  // Consumption is asynchronous: answering without looking would be lying to
  // whoever pressed the button.
  for (let i = 0; i < 15; i++) {
    await new Promise((r) => setTimeout(r, 400));
    const current = await findAccount(email);
    if (current && current.account_status !== 'PENDING_COURSE') {
      return { ok: true, de: 'PENDING_COURSE', a: current.account_status };
    }
  }
  return {
    ok: false,
    estado: 504,
    error: 'The event was published but the state did not change. Check the users-service logs.',
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => {
      data += c;
      if (data.length > 4096) reject(new Error('body too large'));
    });
    req.on('end', () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch {
        reject(new Error('unreadable body'));
      }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('Cache-Control', 'no-store');

  if (url.pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('ok\n');
  }

  const json = (status, body) => {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(body));
  };

  if (url.pathname === '/dev/pendientes') {
    try {
      return json(200, await listPending());
    } catch (e) {
      console.error('PENDING_FAIL', e.message);
      return json(503, { error: 'the database is not responding yet' });
    }
  }

  if (url.pathname === '/dev/logs') {
    try {
      const raw = url.searchParams.get('limit');
      const num = raw === null || raw.trim() === '' ? NaN : Number(raw);
      const limit = Number.isFinite(num)
        ? Math.min(Math.max(Math.floor(num), 1), LOGS_MAX_LIMIT)
        : 20;
      const rows = await redis.lrange(REDIS_KEY_TRACE, 0, limit - 1);
      // The Gateway already stores assembled JSON; an unreadable row does not
      // take the mailbox down.
      const logs = rows
        .map((f) => {
          try { return JSON.parse(f); } catch { return null; }
        })
        .filter(Boolean);
      return json(200, logs);
    } catch (e) {
      // Redis may not be ready on the first refresh: answer 503 and let the
      // front retry on the next cycle.
      console.error('LOGS_FAIL', e.message);
      return json(503, { error: 'redis is not responding yet' });
    }
  }

  if (url.pathname === '/dev/resolver-padron') {
    if (req.method !== 'POST') return json(405, { error: 'use POST' });
    try {
      const { email, resultado } = await readBody(req);
      if (!email) return json(400, { error: 'missing email' });
      const r = await resolvePadron(email, resultado);
      return json(r.ok ? 200 : r.estado, r);
    } catch (e) {
      console.error('PADRON_FAIL', e.message);
      return json(500, { error: e.message });
    }
  }

  if (url.pathname !== '/' && url.pathname !== '/dev/mailbox') {
    return json(404, { error: 'not found' });
  }

  try {
    const raw = url.searchParams.get('limit');
    const num = raw === null || raw.trim() === '' ? NaN : Number(raw);
    const limit = Number.isFinite(num)
      ? Math.min(Math.max(Math.floor(num), 1), MAX_LIMIT)
      : 20;
    const body = await listMails(limit, url.searchParams.get('email') || null);
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(body));
  } catch (e) {
    // Starting before MySQL is normal with docker compose: answering 503 lets
    // the front retry on the next refresh instead of breaking.
    console.error('MAILBOX_FAIL', e.message);
    res.writeHead(503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'the database is not responding yet' }));
  }
});

server.listen(PORT, () => console.log(`development mailbox on :${PORT}`));
