// auditpro-proxi — the Cloudflare Worker behind Jeremyaibuild (repo: auditpro). Build B2
// (= r100 + login checks in REPORT-ONLY mode; see the B2 section at the end of this file and
// docs/auth-design.md §7).
//
// The source of truth for this Worker is THIS FILE. It is deployed by pasting it into the
// Cloudflare dashboard editor (Workers & Pages → auditpro-proxi → Edit code). It contains
// NO secret values — only references to Cloudflare secrets/variables on `env`:
//
//   env.ANTHROPIC_KEY        existing — the Anthropic API key used by the AI proxy
//   env.SUPABASE_SECRET_KEY  new (r100) — a Supabase SECRET key (sb_secret_…). Bypasses RLS,
//                            which is why it lives here and never in a browser. Supabase
//                            refuses secret keys sent from a browser, so this is the only
//                            place it can work.
//   env.SUPABASE_URL         new (r100) — https://<project-ref>.supabase.co
//   env.ALLOWED_SLUGS        OPTIONAL — comma-separated venue folder names, e.g.
//                            "c_1775024388916". When set, uploads to any other folder are
//                            refused. When unset, any well-formed folder name is accepted.
//   env.AUTH_MODE            B2, OPTIONAL — a plain variable. Unset or "report" = check the
//                            caller's Supabase login and LOG the result, refusing nothing.
//                            This build has no other mode: any other value is logged as
//                            unsupported and treated exactly like "report". Enforcement is B4.
//                            env.SUPABASE_URL is also what the login check trusts (issuer + keys).
//
// ROUTES
//   OPTIONS  any path                     CORS preflight — as pre-r100, but B2 also allows the
//                                         Authorization header (r102 will send a login token)
//   POST     /invoice-pdf?slug=…&ref=…    r100: store one invoice PDF and return its signed link
//   anything else                         the Anthropic proxy — unchanged from the pre-r100 Worker
//
// The pre-r100 source was never in the repo. The Anthropic branch below reproduces the
// behaviour observed from the live Worker on 2026-11-17: OPTIONS → 200, empty body, the three
// CORS headers below; POST → the request's JSON forwarded to /v1/messages and the reply
// returned with HTTP 200 WHATEVER Anthropic's own status was (index.html:12172 relies on that
// "200 with an error envelope"); a GET → an uncaught exception (request.json() on no body).

const ANTHROPIC_URL     = 'https://api.anthropic.com/v1/messages';
const ANTHROPIC_VERSION = '2023-06-01';

const INVOICE_ROUTE   = '/invoice-pdf';
const BUCKET          = 'Invoices';
// The largest invoice in the bucket on 2026-11-17 was 93,858 bytes (14 objects, all PDF).
// 10 MB is ~110× that and leaves room for a multi-page phone scan. index.html carries the same
// number as INVOICE_UPLOAD_MAX_BYTES so it can refuse before sending; THIS is the enforcement.
const MAX_PDF_BYTES   = 10 * 1024 * 1024;
const SIGN_EXPIRES_IN = 315360000;          // 10 years, in seconds — the same as pre-r100
// What index.html's clientSlug() produces: lower-case letters, digits, underscore.
const SLUG_RE = /^[a-z0-9_]{1,64}$/;
// What index.html's invoiceStorageRef() produces (and attachInvoicePDF always produced).
// No dot, no slash, no backslash, no percent, no space: there is nothing to traverse WITH.
const REF_RE  = /^[A-Za-z0-9_-]{1,100}$/;

// B2 — Authorization is allowed so that r102's first request carrying a login token passes the
// browser's preflight. This is the only response that carries Access-Control-Allow-Headers: it
// is the only one a browser reads it from, so no other response needed (or got) a change.
const CORS_PREFLIGHT_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_PREFLIGHT_HEADERS });
    }
    // B2 — check who is calling and LOG it. This runs ALONGSIDE the request, never in front of
    // it: whatever it finds, and even if it fails outright, the request below is served
    // exactly as before. A preflight never carries a token (browsers do not send one), so it
    // is neither checked nor logged.
    reportAuth(request, env, ctx);
    const url = new URL(request.url);
    if (url.pathname === INVOICE_ROUTE) {
      return handleInvoicePdf(request, env, url);
    }
    return anthropicProxy(request, env);
  },
};

// ── The Anthropic proxy — UNCHANGED BEHAVIOUR. The four AI call sites in index.html
// (generateAIQuestions, genReportAIComments, processDumpFile, processInvoiceWithAI) post to
// the Worker's root and depend on exactly this: body forwarded as-is, reply always HTTP 200.
async function anthropicProxy(request, env) {
  const body = await request.json();
  const response = await fetch(ANTHROPIC_URL, {
    method: 'POST',
    headers: {
      'Content-Type':      'application/json',
      'x-api-key':         env.ANTHROPIC_KEY,
      'anthropic-version': ANTHROPIC_VERSION,
    },
    body: JSON.stringify(body),
  });
  const data = await response.json();
  return new Response(JSON.stringify(data), {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
}

// ── r100 — the invoice PDF route. There is no user auth, so nothing the browser sends can
// be a secret. The route is therefore made NARROW rather than trusted: it accepts one thing
// (a PDF of bounded size), writes it to one place (Invoices/<slug>/<ref>.pdf, a path IT
// builds from two validated tokens), and signs only the path it has just written. The
// client never supplies a path, a bucket, a header for Supabase or an expiry.
async function handleInvoicePdf(request, env, url) {
  if (request.method !== 'POST') {
    return fail(405, 'method_not_allowed', 'Use POST to upload an invoice PDF.');
  }

  const supabaseUrl = String(env.SUPABASE_URL || '').trim().replace(/\/+$/, '');
  const secret      = String(env.SUPABASE_SECRET_KEY || '').trim();
  if (!secret || !/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(supabaseUrl)) {
    return fail(500, 'not_configured',
      'The Worker is not configured for uploads: SUPABASE_SECRET_KEY must be set, and ' +
      'SUPABASE_URL must look like https://<project>.supabase.co.');
  }

  // Exactly two query parameters, each exactly once. Anything else is refused rather than
  // ignored, so a caller can never smuggle in a second meaning.
  const params = [...url.searchParams.keys()];
  if (params.length !== 2 || url.searchParams.getAll('slug').length !== 1 ||
      url.searchParams.getAll('ref').length !== 1) {
    return fail(400, 'bad_request', 'Expected exactly ?slug=<venue>&ref=<invoice>.');
  }
  const slug = url.searchParams.get('slug');
  const ref  = url.searchParams.get('ref');
  if (!SLUG_RE.test(slug)) {
    return fail(400, 'bad_slug', 'The venue folder must be 1-64 characters of a-z, 0-9 or _.');
  }
  if (!REF_RE.test(ref)) {
    return fail(400, 'bad_ref', 'The invoice reference must be 1-100 characters of A-Z, a-z, 0-9, _ or -.');
  }
  const allowed = String(env.ALLOWED_SLUGS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (allowed.length && !allowed.includes(slug)) {
    return fail(403, 'slug_not_allowed', 'Uploads are not enabled for venue folder "' + slug + '".');
  }

  const contentType = (request.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
  if (contentType !== 'application/pdf') {
    return fail(415, 'not_pdf', 'Only application/pdf is accepted.');
  }
  const declared = request.headers.get('Content-Length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_PDF_BYTES)) {
    return fail(413, 'too_large', 'The file is over the ' + mb(MAX_PDF_BYTES) + ' MB limit.');
  }
  // The declared length is a claim; the byte count is enforced while reading, so a body sent
  // without (or lying about) Content-Length is still cut off at the cap.
  const bytes = await readCapped(request.body, MAX_PDF_BYTES);
  if (bytes === null) {
    return fail(413, 'too_large', 'The file is over the ' + mb(MAX_PDF_BYTES) + ' MB limit.');
  }
  if (!bytes.length) {
    return fail(400, 'empty', 'The upload was empty.');
  }
  if (!isPdfMagic(bytes)) {
    return fail(415, 'not_pdf', 'The file does not start with %PDF- — it is not a PDF.');
  }

  const path = slug + '/' + ref + '.pdf';
  // FIX 3 — headers are BUILT, never copied. Nothing from `request.headers` reaches Supabase:
  // a forwarded browser User-Agent makes Supabase refuse the secret key with 401, and a
  // forwarded apikey/Authorization/x-upsert would let the caller choose its own credentials or
  // semantics. Authorization repeats the apikey value, which Supabase accepts for non-JWT keys.
  const auth = { 'apikey': secret, 'Authorization': 'Bearer ' + secret };

  let upload;
  try {
    upload = await fetch(supabaseUrl + '/storage/v1/object/' + BUCKET + '/' + path, {
      method:  'POST',
      headers: { ...auth, 'Content-Type': 'application/pdf', 'x-upsert': 'true' },
      body:    bytes,
    });
  } catch (e) {
    return fail(502, 'storage_unreachable', 'Supabase Storage could not be reached: ' + errText(e));
  }
  if (!upload.ok) {
    return fail(502, 'storage_rejected_upload',
      'Supabase Storage refused the upload (HTTP ' + upload.status + '): ' + await bodyText(upload),
      upload.status);
  }

  let sign;
  try {
    sign = await fetch(supabaseUrl + '/storage/v1/object/sign/' + BUCKET + '/' + path, {
      method:  'POST',
      headers: { ...auth, 'Content-Type': 'application/json' },
      body:    JSON.stringify({ expiresIn: SIGN_EXPIRES_IN }),
    });
  } catch (e) {
    return fail(502, 'storage_unreachable',
      'The PDF was stored, but Supabase Storage could not be reached to sign its link: ' + errText(e));
  }
  if (!sign.ok) {
    return fail(502, 'storage_rejected_sign',
      'The PDF was stored, but Supabase Storage refused to sign its link (HTTP ' + sign.status + '): ' +
      await bodyText(sign), sign.status);
  }
  const signed = await sign.json().catch(() => null);
  const rel    = signed && typeof signed.signedURL === 'string' ? signed.signedURL : '';
  const link   = supabaseUrl + (rel.startsWith('/storage/v1/') ? '' : '/storage/v1') + rel;
  // Only a link to the path just written is ever returned.
  if (!rel || !link.startsWith(supabaseUrl + '/storage/v1/object/sign/' + BUCKET + '/' + path + '?')) {
    return fail(502, 'bad_signed_url', 'Supabase Storage did not return a signed link for ' + BUCKET + '/' + path + '.');
  }

  return reply(200, { ok: true, path: BUCKET + '/' + path, url: link, bytes: bytes.length });
}

async function readCapped(stream, max) {
  if (!stream) return new Uint8Array(0);
  const reader = stream.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      try { await reader.cancel(); } catch (e) { /* already closed */ }
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.byteLength; }
  return out;
}

function isPdfMagic(bytes) {
  // %PDF-
  return bytes.length >= 5 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 &&
         bytes[3] === 0x46 && bytes[4] === 0x2d;
}

function mb(n) { return Math.round(n / 1048576); }

function errText(e) { return (e && e.message) ? e.message : String(e); }

async function bodyText(res) {
  try { return (await res.text()).slice(0, 300); } catch (e) { return '(no body)'; }
}

function fail(status, error, message, upstreamStatus) {
  const body = { ok: false, error, message };
  if (upstreamStatus) body.upstreamStatus = upstreamStatus;
  return reply(status, body);
}

function reply(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type':                'application/json',
      'Access-Control-Allow-Origin': '*',
      'Cache-Control':               'no-store',
    },
  });
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// B2 — LOGIN CHECK, REPORT ONLY (docs/auth-design.md §7)
//
// Nothing below can refuse, delay or change a request. reportAuth() starts the check, hands it
// to ctx.waitUntil and returns at once; the request is then served by the unchanged code above.
// Each checked request produces exactly ONE log line:
//
//   [auth] mode=report route=anthropic auth=missing
//   [auth] mode=report route=invoice-pdf auth=ok sub=<the user's id>
//   [auth] mode=report route=anthropic auth=invalid reason=bad_signature
//   [auth] mode=report route=anthropic auth=expired
//
// The token is NEVER logged, nor any part of it, nor anything read out of a token that has not
// passed every check: a reason is always one of the fixed words below, and sub is logged only
// from a fully verified token, after it has matched the UUID pattern.
//
// A token is "ok" only if ALL of this holds (§7):
//   - the header is "Authorization: Bearer <jwt>";
//   - its alg is ES256 and its kid is a key in the project's JWKS
//     (SUPABASE_URL + /auth/v1/.well-known/jwks.json);
//   - the signature verifies (ECDSA P-256 / SHA-256, WebCrypto, no imports);
//   - iss = SUPABASE_URL + /auth/v1; aud includes "authenticated"; role = "authenticated";
//   - exp is in the future; iat is not in the future; sub is a UUID; is_anonymous is not true.
// A signature-valid token that fails only on exp is "expired"; any other failure is "invalid".
//
// reasons: not_bearer · malformed · alg · no_kid · not_configured · jwks_unavailable ·
//          unknown_kid · bad_signature · iss · aud · role · sub · anonymous · iat · exp · internal
// ═══════════════════════════════════════════════════════════════════════════════════════════

const JWKS_PATH       = '/auth/v1/.well-known/jwks.json';
const JWKS_TTL_MS     = 10 * 60 * 1000;   // a fetched key set is trusted for 10 minutes, no longer
const JWKS_MIN_GAP_MS = 60 * 1000;        // and fetched at most once a minute, however many unknown kids arrive
const JWKS_TIMEOUT_MS = 5000;
// Supabase's and Cloudflare's clocks can differ by a second or two, so a token issued "now" must
// not read as issued in the future. exp gets NO leeway.
const IAT_LEEWAY_S    = 30;
const SUPABASE_URL_RE = /^https:\/\/[a-z0-9-]+\.supabase\.co$/;   // the rule handleInvoicePdf applies
const UUID_RE         = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const B64URL_RE       = /^[A-Za-z0-9_-]+$/;

// The key set, cached per Worker instance. A new deploy starts new instances with an empty cache.
let jwksCache = { url: '', keys: new Map(), fetchedAt: 0, triedAt: 0, inflight: null };

function reportAuth(request, env, ctx) {
  let job;
  try {
    const route = new URL(request.url).pathname === INVOICE_ROUTE ? 'invoice-pdf' : 'anthropic';
    job = checkAuth(request, env, Date.now())
      .catch(() => ({ result: 'invalid', reason: 'internal' }))
      .then((a) => console.log(authLine(env, route, a)))
      .catch(() => {});
  } catch (e) {
    return;   // the check must never be able to break the request
  }
  if (ctx && typeof ctx.waitUntil === 'function') ctx.waitUntil(job);
}

function authLine(env, route, a) {
  const requested = env.AUTH_MODE == null ? '' : String(env.AUTH_MODE).trim();
  let line = '[auth] mode=report';
  if (requested !== '' && requested !== 'report') {
    // This build only reports. Any other value is named in the log and changes nothing.
    line += ' unsupported_auth_mode=' + (requested.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 20) || '?');
  }
  line += ' route=' + route + ' auth=' + a.result;
  if (a.reason) line += ' reason=' + a.reason;
  if (a.result === 'ok') line += ' sub=' + a.sub;
  return line;
}

async function checkAuth(request, env, now) {
  const header = request.headers.get('Authorization');
  if (header === null || header.trim() === '') return { result: 'missing' };
  const m = /^Bearer +(\S+)$/i.exec(header.trim());
  if (!m) return invalid('not_bearer');
  const parts = m[1].split('.');
  if (parts.length !== 3 || !parts.every((p) => B64URL_RE.test(p))) return invalid('malformed');
  const head   = jsonPart(parts[0]);
  const claims = jsonPart(parts[1]);
  if (!head || !claims) return invalid('malformed');
  // Only ES256 is ever verified, and only with ECDSA, so no other alg can be smuggled in.
  if (head.alg !== 'ES256') return invalid('alg');
  if (typeof head.kid !== 'string' || head.kid === '') return invalid('no_kid');

  const supabaseUrl = String(env.SUPABASE_URL || '').trim().replace(/\/+$/, '');
  if (!SUPABASE_URL_RE.test(supabaseUrl)) return invalid('not_configured');
  const found = await jwksKey(supabaseUrl, head.kid, now);
  if (!found.key) return invalid(found.reason);

  const sig = b64urlBytes(parts[2]);
  if (!sig || sig.length !== 64) return invalid('bad_signature');
  const signedPart = new TextEncoder().encode(parts[0] + '.' + parts[1]);
  const genuine = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, found.key, sig, signedPart);
  if (!genuine) return invalid('bad_signature');

  // Only a token the project really signed gets this far. Now check what it says.
  const nowS = now / 1000;
  if (claims.iss !== supabaseUrl + '/auth/v1') return invalid('iss');
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes('authenticated')) return invalid('aud');
  if (claims.role !== 'authenticated') return invalid('role');
  if (typeof claims.sub !== 'string' || !UUID_RE.test(claims.sub)) return invalid('sub');
  if (claims.is_anonymous === true) return invalid('anonymous');
  if (typeof claims.iat !== 'number' || !Number.isFinite(claims.iat) || claims.iat > nowS + IAT_LEEWAY_S) {
    return invalid('iat');
  }
  if (typeof claims.exp !== 'number' || !Number.isFinite(claims.exp)) return invalid('exp');
  if (claims.exp <= nowS) return { result: 'expired' };
  return { result: 'ok', sub: claims.sub.toLowerCase() };
}

// → { key } or { reason: 'jwks_unavailable' | 'unknown_kid' }
async function jwksKey(supabaseUrl, kid, now) {
  const url = supabaseUrl + JWKS_PATH;
  if (jwksCache.url !== url) {
    jwksCache = { url, keys: new Map(), fetchedAt: 0, triedAt: 0, inflight: null };
  }
  const c = jwksCache;
  const fresh = () => c.fetchedAt > 0 && now - c.fetchedAt < JWKS_TTL_MS;
  if (c.inflight) {
    await c.inflight;                       // another request is already fetching: share it
  } else if (!(fresh() && c.keys.has(kid)) && (c.triedAt === 0 || now - c.triedAt >= JWKS_MIN_GAP_MS)) {
    await refreshJwks(c, now);              // stale, or an unknown kid — at most once a minute
  }
  if (!fresh()) return { reason: 'jwks_unavailable' };
  return c.keys.has(kid) ? { key: c.keys.get(kid) } : { reason: 'unknown_kid' };
}

function refreshJwks(c, now) {
  c.triedAt = now;
  const job = (async () => {
    try {
      // Headers are BUILT, never copied: nothing from the caller's request goes to Supabase.
      const res = await fetch(c.url, {
        headers: { 'Accept': 'application/json' },
        signal:  AbortSignal.timeout(JWKS_TIMEOUT_MS),
      });
      if (!res.ok) return;
      const body = await res.json();
      const keys = new Map();
      for (const k of (body && Array.isArray(body.keys)) ? body.keys : []) {
        if (!k || k.kty !== 'EC' || k.crv !== 'P-256' || typeof k.kid !== 'string' || k.kid === '') continue;
        if ((k.alg !== undefined && k.alg !== 'ES256') || (k.use !== undefined && k.use !== 'sig')) continue;
        try {
          keys.set(k.kid, await crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x: k.x, y: k.y },
            { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']));
        } catch (e) { /* a malformed key is skipped, not fatal */ }
      }
      c.keys = keys;
      c.fetchedAt = now;
    } catch (e) {
      /* unreachable, timed out or not JSON: the cache is left alone and goes stale on schedule */
    }
  })();
  c.inflight = job;
  job.then(() => { if (c.inflight === job) c.inflight = null; });
  return job;
}

function b64urlBytes(s) {
  try {
    const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch (e) { return null; }
}

function jsonPart(s) {
  const bytes = b64urlBytes(s);
  if (!bytes) return null;
  try {
    const v = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    return v && typeof v === 'object' && !Array.isArray(v) ? v : null;
  } catch (e) { return null; }
}

function invalid(reason) { return { result: 'invalid', reason }; }
