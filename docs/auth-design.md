# Auth design: roles, helpers, table policies, build plan

**Agreed 20 Nov 2026** in the planning chat. **Written into the repo 24 Nov 2026**, because the first
B1 draft (commit `e1b4b70`) had to reconstruct it and got it wrong: it invented `staff` and `viewer`
roles and made `is_staff` per-venue. That draft is superseded.

**This file is the authority.** If a SQL file, a prompt or a CLAUDE.md line disagrees with it, that
thing is wrong. To change the design, edit this file first and on purpose, then change the SQL to
match. Never let the SQL drift on its own.

---

## 1. Roles

| Role | Where it lives | Scope | What it may do |
|---|---|---|---|
| **owner** | `ap_profiles.is_owner` (a **global** flag) | every venue, **including venues created later** | Everything, everywhere, whatever memberships exist. Nothing can be orphaned from Jeremy. |
| **auditor** | `ap_memberships` row, `role = 'auditor'` | **per venue** | All the work on the venues they are assigned to: desktop (counts, invoices, finalise, reports) **and** phone counting. One person does both. There is no separate phone-only role. |
| **client** | `ap_memberships` row, `role = 'client'` | **per venue**, **read-only** | Intended for report history. Gets **no access to any existing table** in this build. `ap_clients` holds site alarm/safe codes and costs, and RLS can't split a JSON column, so the whole row is off-limits. A future `ap_published_reports` table will serve clients. |

- `ap_memberships.role` is `CHECK (role IN ('auditor','client'))`. **There is no `staff` role and no
  `viewer` role.** `owner` is not a membership role either; it is the flag.
- One role per login per venue (primary key `(user_id, client_slug)`).
- A login with no profile, or a profile with no membership, gets nothing. So does every anonymous
  caller, because `auth.uid()` is NULL.

## 2. Helpers

They live in schema `private`, which the REST API does not expose. All are `SECURITY DEFINER` with
`search_path = ''`, and each always returns true or false, never NULL.

| Helper | True when |
|---|---|
| `private.is_owner()` | the caller's `ap_profiles` row has `is_owner` |
| `private.can_work(slug)` | `is_owner()` **or** the caller has an **auditor** membership of that slug |
| `private.is_staff()` | `is_owner()` **or** the caller has **any** auditor membership, at any venue. Used for the shared master catalogue and for AI spend. |
| `private.can_view(slug)` | `can_work(slug)` **or** the caller has a **client** membership of that slug. For the future published reports. |

Public RPCs for the Worker, **executable by `authenticated` only** (no `anon`, no `service_role`):

| RPC | Returns |
|---|---|
| `public.ap_can_work(p_slug)` | `private.can_work(p_slug)` |
| `public.ap_is_staff()` | `private.is_staff()` |

The Worker calls them with the publishable key as `apikey` and the **user's** access token as
`Bearer`. With the secret key there is no user, so the call is refused. Treat anything other than
a literal `true` as "no".

### Who each helper says yes to

| | `is_owner()` | `can_work(v)` | `is_staff()` | `can_view(v)` |
|---|---|---|---|---|
| owner | yes | yes, every venue | yes | yes, every venue |
| auditor of venue v | no | **v only** | yes | **v only** |
| client of venue v | no | no | no | **v only** |
| no membership, or anonymous | no | no | no | no |

## 3. Intended table policies (written in B5, NOT in B1)

B1 creates the helpers but writes **no** policy on any existing table. Those tables keep their
allow-all policies until B5 locks them one at a time.

| Table | Policy |
|---|---|
| `ap_clients` | SELECT / UPDATE: `can_work(slug)`. INSERT / DELETE: `is_owner()` |
| `ap_audit_sessions` | SELECT / INSERT / UPDATE: `can_work(client_slug)`. DELETE: `is_owner()` |
| `ap_master_products` | SELECT: `is_staff()`. Writes: `is_owner()` |
| `ap_mobile_counts` | all operations: `can_work(client_slug)`. INSERT also requires `client_slug IS NOT NULL` |
| `ap_batches` | owner only |
| `ap_products` | deny all (legacy) |
| `ap_profiles` / `ap_memberships` | read your own rows, or the owner reads all. Writes only via the SQL Editor. (B1 creates these two tables already with exactly this.) |

No existing table has a client policy. A client membership is useful only once
`ap_published_reports` exists.

## 4. Build plan

Use these names everywhere: SQL headers, commits, prompts, CLAUDE.md, memory.

| Build | What |
|---|---|
| **B0** | Pre-flight. **Done 24 Nov 2026** (the baseline capture, `sql/baseline-2026-11-24.json`). |
| **B1** | Foundation SQL: `sql/b1-foundation.sql`, `b1-verify.sql`, `b1-rollback.sql`. Purely additive. |
| **B2** | Worker **log-only** mode. It verifies logins and refuses nothing. |
| **B3** | App **r102**: sign-in on desktop and phone. |
| **B4** | Worker **enforce**. |
| **B5.1–B5.6** | Lock the six tables **one at a time**, `ap_products` first and `ap_clients` last. |
| **B6** | Close-out. |

**A separate gate comes before inviting anyone else:**

- strip the commercial fields from the master catalogue;
- an escaping/injection pass;
- make the backup owner-only;
- decide how clients get published reports.

## 5. Decisions made in B1 (kept)

The SQL header of `sql/b1-foundation.sql` gives the full reasoning.

- **A new `ap_mobile_counts.client_slug`** (nullable, FK to `ap_clients.slug`, `ON DELETE SET NULL`),
  backfilled from each CSV's `ClientId,<slug>` line. The unused `client_id` is left untouched,
  because its name reads as `ap_clients.id`, the bigint row id.
- **Keep `UNIQUE (code)`.** r101's desktop imports by code alone. Move to `(client_slug, code)` only
  in the build where both apps send and filter by slug.

## 6. Notes for B5, measured by the B1 harness (NOT part of the 20 Nov design)

These are facts for B5 to plan around, not decisions. They come from the B1 PGlite harness
(scratchpad only; 24 Nov 2026, 157/157 pass), which applied §3's policies to a copy of the
baseline and ran r101's real request shapes against them.

1. **TRUNCATE is not governed by RLS.** The baseline grants `TRUNCATE` (and `REFERENCES`,
   `TRIGGER`) on all six tables to `anon` and `authenticated`. With only §3's policies in place, a
   client, a login with no membership, and `anon` (the public publishable key alone) can all still
   TRUNCATE. Measured on `ap_batches` and `ap_audit_sessions`. **Every B5 step must also REVOKE
   TRUNCATE on the table it locks**, and decide what `anon` keeps at all.
   (`ap_clients` is the one exception since B1: the two new foreign keys make a plain TRUNCATE of
   it fail.)
2. **The phone must send `client_slug` before B5 locks `ap_mobile_counts`.** r101's insert carries
   no `client_slug`, so under §3 it is refused for everyone, the owner included.
3. **Master writes are owner-only, so an auditor's master write is refused.** That includes
   `addToMasterCatalogue` (density edits from `saveProduct` and invoice import). r101 only
   `console.warn`s on that failure, so an auditor's density correction would silently never reach
   master. The fix needs an app change, or a deliberate acceptance.
4. **Under §3, `anon` gets nothing.** Every r101 request fails once its table is locked, so B3
   sign-in, and every device actually running r102, must come before each B5 step.
5. **Read in the code, not run:** r101's `addClient` saves a new venue through `dbSaveClient`,
   which is `PATCH ap_clients?slug=eq.<new slug>`. That matches zero rows and returns 204, and the
   app shows "✓ Saved". No r101 code path INSERTs into `ap_clients`, so a venue added on the desktop
   never reaches the server. This predates B1 and B1 did not cause it. It matters for B5's
   `ap_clients` INSERT = `is_owner()`.
6. **These already behave correctly under §3:**
   - An auditor's `dbSaveSession` upsert works at their own venue.
   - An upsert that names another venue's `session_id` is refused, so a period can't be taken
     over by its ID.
   - Moving a count to another venue is refused.
   - `importByCode` with another venue's code returns no rows. Per-venue RLS therefore also
     closes the cross-venue import risk that keeps `UNIQUE (code)` in place today (§5).
