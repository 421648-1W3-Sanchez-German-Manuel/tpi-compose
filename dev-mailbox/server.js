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
import mysql from 'mysql2/promise';

const PORT = Number(process.env.PORT ?? 4300);
const LIMITE_MAX = 50;

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

const servidor = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('Cache-Control', 'no-store');

  if (url.pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('ok\n');
  }

  if (url.pathname !== '/' && url.pathname !== '/dev/mailbox') {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    return res.end('{"error":"no existe"}');
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
