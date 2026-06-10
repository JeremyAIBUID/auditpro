# AuditPro — CLAUDE.md

## Project Overview
AuditPro is a hospitality audit platform for any hospitality venue. Built as single-file HTML/CSS/JS apps with Supabase persistence. No framework, no build step — pure vanilla JS. 1 Up Sports Bar (Auckland, NZ) is the first test client.

**Owner:** Jeremy (non-technical, builds entirely through Claude prompting)

---

## Claude Code Session Setup

**Planning chat (claude.ai):** Always use Claude Opus model for the AuditPro planning and prompt-drafting chat. This is the main chat where fixes are designed, Claude Code prompts are written, and results are analysed.

**Claude Code CLI:** `claude --model claude-opus-4-8`, first message `/effort xhigh`.

---

## Deployment
| Asset | URL |
|-------|-----|
| Desktop app | https://jeremyaibuid.github.io/auditpro/index.html |
| Mobile PWA | https://jeremyaibuid.github.io/auditpro/mobile.html |
| GitHub repo | https://github.com/JeremyAIBUID/auditpro |
| Supabase project | https://hjtguzieguogfjbwikwt.supabase.co |
| Cloudflare Worker proxy | https://auditpro-proxi.jeremyaibuid.workers.dev |

**Deploy process:** Edit local files → commit via GitHub Desktop → GitHub Pages auto-deploys in ~1 min.

**Current build stamp:** `2026-06-10-r11` — the `APP_VERSION` const in index.html, logged to the console on load. Check it matches after a deploy to confirm you're not seeing a cached build.

**mobile2.html must always be kept identical to mobile.html — update both files in every commit.**

---

## Local File Paths
```
/mnt/user-data/outputs/auditpro.html        ← Desktop app (index.html)
/mnt/user-data/outputs/auditpro-mobile.html ← Mobile app (mobile.html + mobile2.html)
/home/claude/auditpro-deploy/               ← Deploy folder (copy files here before zipping)
```

**Always copy both files to deploy folder before packaging:**
```bash
cp /mnt/user-data/outputs/auditpro.html /home/claude/auditpro-deploy/index.html
cp /mnt/user-data/outputs/auditpro-mobile.html /home/claude/auditpro-deploy/mobile.html
cp /mnt/user-data/outputs/auditpro-mobile.html /home/claude/auditpro-deploy/mobile2.html
cd /home/claude/auditpro-deploy && zip -r /mnt/user-data/outputs/auditpro-netlify.zip .
```

**Always check brace balance after edits:**
```bash
python3 -c "
import re
with open('/mnt/user-data/outputs/auditpro.html') as f: c=f.read()
scripts=re.findall(r'<script[^>]*>(.*?)</script>',c,re.DOTALL)
for i,s in enumerate(scripts):
    o,cl=s.count('{'),s.count('}')
    print(f'Script {i}: {o}/{cl} diff={o-cl}')
"
```

---

## Supabase Schema
| Table | Purpose | Key columns |
|-------|---------|-------------|
| `ap_clients` | All venue data | `slug` (PK), `data` (JSONB) |
| `ap_master_products` | Shared product catalogue | `slug` (PK), `data` (JSONB) |
| `ap_audit_sessions` | Audit sessions | `session_id` (PK), `data` (JSONB) |
| `ap_mobile_counts` | Mobile sync counts | `code`, `client`, `csv_data` |
| `ap_batches` | Cocktail batches | `id`, `data` (JSONB) |

**Supabase keys:**
```
Anon key:         eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhqdGd1emllZ3VvZ2ZqYndpa3d0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwMDg1NDUsImV4cCI6MjA5MDU4NDU0NX0.yH_TrwX6jdeSi6WNOWvvQ4yzkznoXvCWEmDKFg9-DEE
Service role key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhqdGd1emllZ3VvZ2ZqYndpa3d0Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NTAwODU0NSwiZXhwIjoyMDkwNTg0NTQ1fQ.Iyt8MzLOjGI9StCysg-aPe1t5BsE6jdOnahPo8EdXo4
```

**RLS note:** Supabase RLS blocks SQL Editor updates. Use service role key via browser console fetch for direct writes. PATCH returns 204 even if RLS blocks — always verify with a GET after.

**Upsert pattern (required for all tables):**
```javascript
fetch(`${SUPABASE_URL}/rest/v1/ap_clients?on_conflict=slug`, {
  method: 'POST',
  headers: { 'Prefer': 'resolution=merge-duplicates,return=minimal', ... },
  body: JSON.stringify({ slug, data: client })
})
```

---

## Active Client
| Field | Value |
|-------|-------|
| Name | 1 Up Sports Bar |
| Slug | `c_1775024388916` |
| Supabase row | id = 5 |

**Client data structure (`ap_clients.data`):**
```javascript
{
  id, name, city, type, color, initials, contact,
  products: [...],        // Array of product objects — source of truth
  deliveries: [...],      // Invoice purchase history
  invoiceArchive: [...],  // Deleted invoices available for re-import
  auditSessions: [...],   // Audit period sessions
  suppliers: [...],       // Supplier list
  wasteRows: [...],
  sales: {...},           // Sales data by product name
}
```

---

## Architecture

### Desktop (auditpro.html / index.html)
- Single HTML file, dark theme (#0d0f12)
- Fonts: DM Serif Display, Syne, DM Mono
- State: `let clients = []`, `let activeClient = null`
- Pages: overview, dashboard, products, purchases, sales, variances, suppliers, stocktake, finalise, reports, insights

### Mobile (auditpro-mobile.html / mobile.html)
- Separate single-file PWA
- State: `let session = { code, client, counts: {} }`
- PRODUCTS array loaded from Supabase `ap_clients.data.products` on connect
- Venues loaded from Supabase, fallback to `const VENUES = [{ name: '1 Up Sports Bar', color: '#c8f064' }]`

---

## Key Functions — Desktop

```javascript
// Navigation
navigate(page)              // Go to page + render
renderPage(page)            // Render page content
selectClientOnly(id)        // Set activeClient without navigating
selectClient(id)            // Set activeClient + navigate to dashboard

// Data persistence
dbLoadAll()                 // Load all clients + master products from Supabase
dbSaveProducts(client)      // PATCH ap_clients with full client object
dbSaveClient(client)        // Same as above (alias)
dbSaveSession(c, session)   // Save audit session

// Products page
renderProducts(c, query)    // Render product catalogue
editProduct(idx)            // Open edit modal for product at index
deleteProduct(idx)          // Delete product with confirm dialog
saveProduct()               // Save product form (async — syncs to all venues)

// Variance
computeVariances(client)    // Build variance rows from sessions + deliveries
renderVarTable()            // Render variance table (requires DB._ready)

// Invoices
renderInvoiceResults(id, invoice, filename)  // Render processing card
openInvoiceReviewModal(id)                   // Open review modal (re-runs matching)
applyInvoiceToProducts(id)                  // Import invoice to catalogue + purchase history
addDumpInvoiceToClient(c, invoice, id)      // Add to deliveries + archive + suppliers
deleteInvoice(idx)                          // Move to archive + remove from deliveries
reimportArchivedInvoice(archiveIdx)         // Re-add from archive to deliveries
viewInvoice(idx)                            // Show invoice modal
editInvoice(idx)                            // Show editable invoice modal
saveEditedInvoice(idx)                      // Save edits

// Suppliers
renderSupplierList(q)       // Render supplier cards
openSupplierDetail(name)    // Show supplier with linked products + invoices

// Sales
confirmZeroSales()          // Wipe all sales data
confirmSalesImport(id)      // Import parsed sales CSV into client
```

## Key Functions — Mobile

```javascript
processBarcode(barcode)         // Match barcode → show product or offer creation
showScanResult(product)         // Display scan result + set _numpadFresh=true
numpadPress(method, key)        // Handle numpad input (replaces default 1 on first press)
saveMobileProduct()             // Save new product + push to Supabase ap_clients
pushProductToSupabase(prod)     // PATCH ap_clients to add product to venue
loadProductsFromSupabase()      // Load products from ap_clients for active venue
acceptAndSync()                 // Build CSV + push to ap_mobile_counts
pushCountToSupabase(csv)        // DELETE existing + POST new to ap_mobile_counts
resetForNextAudit()             // Clear all counts for fresh audit
updateCountUI()                 // Re-render count list with tap-to-edit
editCountItem(idx)              // Prompt to edit qty of counted item
```

---

## Product Object Structure
```javascript
{
  n: 'APPLETON ESTATE SIGNATURE BLEND',  // Primary name field (always use p.n||p.name)
  name: 'APPLETON ESTATE...',            // Duplicate — always set both
  cat: 'Spirits',
  subcat: 'Rum',
  barcode: '5024576001303',
  unitVol: 1000,          // ml per bottle/unit
  serveVol: 30,           // ml per serve
  tareG: 715,             // Empty vessel weight in grams
  fullG: 1662,            // Full vessel weight in grams
  density: '0.94',        // Liquid density (string)
  soldAs: 'Bottles',      // 'Bottles' | 'Cans' | 'Kegs' | 'Cases'
  costPrice: 0,
  sellPrice: 0,
  supplier: '',
  idealGP: 72,
  costHistory: [{ date, price, source, priceExGST }],
}
```

**Density values:**
- Spirits: 0.9467
- Wine: 0.9805
- Beer/Cider: 1.014
- Liqueur: 1.06

---

## Invoice Matching Logic
Located in `openInvoiceReviewModal()` — runs fresh every time modal opens (not cached).

Match priority:
1. Barcode (exact, strips leading zeros)
2. Exact name (case-insensitive)
3. Normalised name (strips volumes, pack sizes, BTL/KEG/CAN, apostrophes)
4. Partial string includes
5. Word overlap score (picks BEST score, not first above threshold)

Normalisation strips: `'`, pack sizes (24S), BTL/BTLS, CAN/CANS, KEG/KEGS, CASE/CASES, CAR, RTD, volumes (330ml, 50L).

Unmatched items → blank red-bordered field, Confirm button disabled until all matched.

**Invoice totals & extras:** The invoice total uses `d.t` — the total **printed on the invoice, incl. GST** — which can exceed the sum of line items. The gap (fuel surcharges, freight, levies) is stored as `d.extras = d.t − lineSum`. `saveEditedInvoice()` preserves `d.extras` through line edits so the printed total stays intact.

---

## Variance Calculation
`computeVariances(client)` runs even without a finalised session.

**Purchase sources (merged):**
1. `deliveryPurchases` — built from `c.deliveries[].lines` with fuzzy name matching
2. `sessionPurchases` — from `c.auditSessions[-1].purchases`

**Only shows products in `prodMap`** (catalogue products) — prevents test/stale products appearing.

**Unit display:** Bottles/Cans/RTD show units (e.g. "36 units"), Spirits/Wine/Kegs show volume (L/ml).

**Sales depletion:** For Bottles/Cans/Kegs, each sale = 1 full unitVol. For spirits, uses serveVol.

---

## PDF Audit Report (Week 2 — In Progress)
Full audit-report generator on the **Reports** page — a cover page plus 9 content sections, exported to PDF via **html2pdf.js**.

**Section order (pages 1 → 10):**
1. Cover
2. Executive Summary — metric cards + 2 donut charts + variance-by-category table
3. Variance Trend
4. GP Analysis
5. Auditor Comments — AI-generated, inline-editable before export
6. Loss & Gain Leaders
7. Variance Summary by Category
8. Full Product Detail
9. Purchase History
10. Sign-off

**Category order (everywhere in the report):** Spirits, Wine, Sparkling, Draught, Beer & Cider, RTD, Misc

**Variance thresholds (per category):**
| Category | Threshold |
|----------|-----------|
| Spirits | +4% |
| Wine | −2% |
| Sparkling | −2% |
| Draught | −3% |
| Beer & Cider | −0.5% |
| RTD | −0.5% |
| Misc | −0.5% |

Spirits are weighed and expected to show a gain, so a Spirits result below +4% is flagged.

**Stock flags:**
- **Dead stock:** 60+ days with no sales
- **Slow mover:** 30 days / <2% usage

**Donut charts** render with the **Canvas 2D API** — conic-gradient and SVG `<path>` wedges both came out as blank grey circles inside html2canvas. Canvases are painted *after* the report HTML is in the DOM (`drawReportDonuts()`).

**Key functions:**
```javascript
exportReportPDF()        // Flip body.pdf-export-mode, run html2pdf on #report-preview, save record
renderReportDocument()   // Build all 10 pages of report HTML
calculateReportData()    // Reuse computeVariances() → totals, categories, leaders, flags
drawReportDonuts()       // Paint queued donut canvases after HTML insertion
rptDonut()               // Emit a donut <canvas> + legend, queue slice data
fmtMoney()               // Report currency formatter (defaults to 2 dp — cents always show)
```

---

## KNOWN ISSUE — PDF Export Layout (UNRESOLVED)
The PDF export still has layout problems after multiple fix attempts:

- **Currency rounding, right-edge clipping, and section top-gaps** were all attempted in build `2026-06-10-r9` but are **not yet confirmed working** on a real export.
- The earlier **detached-clone** approach in `exportReportPDF()` was abandoned (the clone lost its CSS custom properties → blank PDF). It now flips a `body.pdf-export-mode` class and runs html2pdf **directly on `#report-preview`**.
- Current layout settings: `.rpt-doc` container width **720px**, html2pdf margin **[8,8,8,8]**, html2canvas **width 720** (+ windowWidth 720), `.rpt-table` `table-layout:fixed`.
- Invoice extras stored as **`d.extras = d.t − lineSum`** to preserve fuel surcharges / freight through edits.

**Next step:** confirm on a real export whether cents, right-edge fit, and top gaps actually render correctly. Treat any reported regression as possibly stale GitHub Pages cache — verify `APP_VERSION` in the console first.

---

## Constants Required in Desktop App
These must all be defined (were missing at various points — ensure they exist):
```javascript
const CAT_ORDER_PROD    // ['Spirits','Beer','Wine','RTD','Soft drinks','Food','Cocktails','Other']
const CAT_COLORS_PROD   // { Spirits: {bg, text, icon}, ... }
const SUBCAT_ORDER      // { Spirits: [...], Beer: [...], Wine: [...] }
const SUBCAT_ICONS      // { Gin:'🌿', Vodka:'🫧', ... }
const PROD_SUBCATS      // { Spirits: [...], Beer: [...], ... }
const DENSITY           // { spirits: 0.9467, wine: 0.9805, beer: 1.014, liqueur: 1.06 }
```

---

## Common Pitfalls

1. **`p.n` crashes if undefined** — always use `p.n||p.name||''`
2. **`indexOf` returns -1 after Supabase reload** — use `findIndex` by name
3. **`forEach` with async doesn't await** — always use `for...of` with await for sequential saves
4. **Supabase PATCH returns 204 even when RLS blocks write** — verify with GET after
5. **GitHub Pages caches aggressively** — force redeploy by making a trivial commit
6. **`_cleanName` is cached in `_invoiceDataStore`** — `openInvoiceReviewModal` re-runs matching fresh
7. **Demo client data was hardcoded** — `let clients = []` now, loads from Supabase only
8. **`on_conflict=slug` required** for Supabase upserts — without it POST causes 409

---

## Saturday Audit Workflow
1. Mobile → connect to 1 Up → count all stock → Accept & sync
2. Desktop → enter sync code → import as opening stock
3. Invoices arrive → upload PDFs → review & match → import
4. End of week → upload POS sales CSV
5. Variance page shows automatically
6. Finalise Audit → locks period → opens next

## Reset for New Period (console)
```javascript
// Wipe sessions/deliveries/sales — keeps products
const svcKey = 'SERVICE_ROLE_KEY';
activeClient.auditSessions = [];
activeClient.deliveries = [];
activeClient.invoiceArchive = [];
fetch('https://hjtguzieguogfjbwikwt.supabase.co/rest/v1/ap_clients?slug=eq.c_1775024388916', {
  method: 'PATCH',
  headers: {'Content-Type':'application/json','apikey':svcKey,'Authorization':'Bearer '+svcKey,'Prefer':'return=minimal'},
  body: JSON.stringify({ data: activeClient })
}).then(r => console.log('Status:', r.status));
```
