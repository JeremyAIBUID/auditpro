// auditpro-proxi — the Cloudflare Worker behind Jeremyaibuild (repo: auditpro). Build r100.
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
//
// ROUTES
//   OPTIONS  any path                     CORS preflight — unchanged from the pre-r100 Worker
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

const CORS_PREFLIGHT_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_PREFLIGHT_HEADERS });
    }
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
