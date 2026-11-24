-- =====================================================================================
-- B1 — AUTH FOUNDATION (purely additive)                            sql/b1-foundation.sql
-- Jeremyaibuild (repo: auditpro) · written 2026-11-24 · baseline: sql/baseline-2026-11-24.json
-- Design (the authority — roles, helpers, the B5 policies, the B0–B6 plan): docs/auth-design.md
--
-- HOW TO RUN: Supabase dashboard → SQL Editor → New query → paste this WHOLE file → Run.
-- Run it ONCE. It is one transaction: it either all lands or none of it does.
--   SUCCESS = one result row reading "B1 foundation applied".
--   FAILURE = a red error message. NOTHING was changed. Do not run the rollback.
-- Then run sql/b1-verify.sql. Undo (only if told to): sql/b1-rollback.sql.
-- =====================================================================================
--
-- WHAT THIS ADDS
--   1. schema  private             — not exposed by the REST API; holds the helpers below.
--   2. table   public.ap_profiles    — one row per login (auth.users); is_owner flag (GLOBAL).
--   3. table   public.ap_memberships — one role per login per venue: 'auditor' or 'client'.
--   4. private.is_owner() · private.can_work(slug) · private.is_staff() · private.can_view(slug)
--      SECURITY DEFINER, fixed empty search_path. These are what the B5 RLS policies will call.
--   5. public.ap_can_work(p_slug) · public.ap_is_staff() — thin RPCs for the Worker,
--      executable by authenticated ONLY.
--   6. Jeremy's owner row (from auth.users, by email — aborts if that user does not exist).
--   7. public.ap_mobile_counts.client_slug — the venue a phone count belongs to,
--      backfilled for the existing counts from the ClientId line the phone wrote into each CSV.
--
-- WHAT THIS DOES NOT TOUCH (b1-verify.sql proves each one against the baseline)
--   - The six original tables' RLS flags, their allow-all policies ("public_all" ×5 and
--     "allow all" on ap_mobile_counts) and the anon/authenticated grants on them.
--     Who can read or write ap_clients, ap_audit_sessions, ap_master_products,
--     ap_mobile_counts, ap_batches and ap_products is EXACTLY what it was.
--     ONE measured side effect: the two new foreign keys reference ap_clients, so a plain
--     TRUNCATE of ap_clients is now refused (and TRUNCATE … CASCADE too, because only
--     service_role may truncate ap_memberships). Nothing in either app, and no documented
--     repair, truncates anything.
--   - Storage and its four service_role invoices_full_access policies.
--   - The UNIQUE (code) constraint on ap_mobile_counts, and its unused client_id column.
--   - Anything in the apps. r101 desktop and phone keep working unchanged.
--
-- ROLES — the design agreed 20 Nov 2026, recorded in docs/auth-design.md (that file decides)
--   owner   — ap_profiles.is_owner, a GLOBAL flag. Everything at every venue, including venues
--             created later, whatever memberships exist — nothing can be orphaned from Jeremy.
--   auditor — PER VENUE (ap_memberships). All the work at that venue: desktop AND phone counting.
--   client  — PER VENUE (ap_memberships), read-only, for report history. Reaches NO existing
--             table: ap_clients holds site alarm/safe codes and costs, and RLS can't split JSON.
--             A future ap_published_reports table will serve clients.
--   There is no 'staff' and no 'viewer' role; the CHECK refuses both.
--
--                              is_owner()  can_work(v)       is_staff()  can_view(v)
--     owner                       yes      yes, every venue     yes      yes, every venue
--     auditor of venue v          no       v only               yes      v only
--     client  of venue v          no       no                   no       v only
--     no membership / anonymous   no       no                   no       no
--
--   is_staff() takes NO venue: any auditor membership anywhere (the shared master catalogue,
--   and AI spend). In B1 all of this is inert: no policy on an existing table calls a helper
--   yet (that is B5), and Jeremy is the only login.
--
-- DECISION 1 — a NEW column client_slug, not the existing always-null client_id
--   a. Every other venue-scoped table here already calls it client_slug (ap_audit_sessions,
--      and ap_products in the app's bootstrap SQL), and it holds ap_clients.slug. One name
--      means every later policy reads the same way: private.can_view(client_slug).
--   b. "client_id" reads as a pointer to ap_clients.id — and ap_clients.id is the bigint
--      row id (1 Up is row 5), not the slug. A slug stored in a column named for the id
--      is a wrong-key bug waiting for the first policy written against it.
--   c. Neither app reads or writes client_id (zero hits in index.html / mobile.html), and
--      nothing records where it came from. Leaving it untouched keeps B1 purely additive;
--      removing it is a separate, later cleanup (no build is scheduled for it).
--   d. The rollback becomes "remove one new column" instead of "re-null an old one".
--
-- DECISION 2 — KEEP UNIQUE (code); do NOT switch to UNIQUE (client_slug, code) yet
--   a. r101's desktop imports by code ALONE (ap_mobile_counts?code=eq.AP-1234) and takes
--      the first row. Global uniqueness is the only thing that makes that row this venue's.
--      With per-venue uniqueness two venues could both hold AP-1234 and the desktop could
--      silently import the other venue's stock count into this venue's period.
--   b. r101's phone never sends client_slug, so every count synced after B1 arrives with it
--      NULL — and Postgres treats NULLs as distinct, so UNIQUE (client_slug, code) would
--      stop enforcing anything at all for new rows.
--   c. The phone removes any row with its code, then inserts — it never upserts on the
--      constraint — so keeping it changes nothing on the sync path.
--   Revisit in the build where BOTH apps send and filter by client_slug: only then is
--   (client_slug, code) the right key (AP-1000..AP-9999 is 9,000 codes; shared across
--   venues they will collide). The phone must send it before B5 locks ap_mobile_counts
--   anyway: that table's INSERT policy requires client_slug IS NOT NULL.
--
-- FOR THE WORKER (B2 logs, B4 enforces):
--   POST /rest/v1/rpc/ap_can_work  body {"p_slug":"c_…"}   — may this login work at this venue?
--   POST /rest/v1/rpc/ap_is_staff  body {}                  — may this login use AI / the catalogue?
--   with apikey = the publishable key and Authorization = "Bearer <the USER's access token>".
--   Only authenticated may EXECUTE them: an anonymous call AND a call made with the secret key
--   (service_role, which has no user) are both refused with a permission error, so a Worker
--   wired to the wrong key fails loudly instead of answering "no" for everyone.
--   Treat anything other than a literal true as "no".
-- =====================================================================================

begin;

-- ── 0. Guard: refuse to run twice, or against a database that does not match the baseline ──
do $guard$
begin
  if to_regnamespace('private') is not null then
    -- The superseded first draft (commit e1b4b70) had is_staff(text) and roles staff/viewer.
    if to_regprocedure('private.is_staff(text)') is not null then
      raise exception 'B1 NOT APPLIED: the superseded FIRST DRAFT of B1 (commit e1b4b70, roles staff/viewer) is already applied. Nothing was changed. Do not run sql/b1-rollback.sql; send this message to Claude.';
    end if;
    raise exception 'B1 NOT APPLIED: a schema named "private" already exists, so B1 has probably been run already. Nothing was changed. Run sql/b1-verify.sql to check.';
  end if;
  if to_regclass('public.ap_profiles') is not null or to_regclass('public.ap_memberships') is not null then
    raise exception 'B1 NOT APPLIED: ap_profiles or ap_memberships already exists. Nothing was changed.';
  end if;
  if to_regclass('public.ap_clients') is null or to_regclass('public.ap_mobile_counts') is null then
    raise exception 'B1 NOT APPLIED: ap_clients or ap_mobile_counts is missing — wrong project? Nothing was changed.';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'ap_mobile_counts'
                and column_name = 'client_slug') then
    raise exception 'B1 NOT APPLIED: ap_mobile_counts.client_slug already exists. Nothing was changed.';
  end if;
  if not exists (select 1 from public.ap_clients where slug = 'c_1775024388916') then
    raise exception 'B1 NOT APPLIED: venue c_1775024388916 (1 Up Sports Bar) is not in ap_clients — wrong project? Nothing was changed.';
  end if;
end
$guard$;

-- ── 1. The private schema — NOT exposed by the REST API ────────────────────────────────────
-- authenticated needs USAGE because a later RLS policy runs as the caller and calls these
-- helpers. anon gets nothing: an anonymous request can never reach a helper.
create schema private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;
comment on schema private is
  'B1 — auth helpers for RLS. Not exposed by the REST API. anon has no USAGE.';

-- ── 2. ap_profiles — one row per login ──────────────────────────────────────────────────────
create table public.ap_profiles (
  user_id    uuid        not null,
  email      text,
  is_owner   boolean     not null default false,
  created_at timestamptz not null default now(),
  constraint ap_profiles_pkey         primary key (user_id),
  constraint ap_profiles_user_id_fkey foreign key (user_id)
    references auth.users (id) on delete cascade
);
comment on table public.ap_profiles is
  'B1 — one row per Supabase Auth login. is_owner = may do everything at every venue. email is a display copy only; nothing decides access on it.';

-- ── 3. ap_memberships — one role per login per venue: auditor or client ─────────────────────
-- The owner needs no rows here: is_owner is global. 'owner', 'staff' and 'viewer' are refused.
create table public.ap_memberships (
  user_id     uuid        not null,
  client_slug text        not null,
  role        text        not null,
  created_at  timestamptz not null default now(),
  constraint ap_memberships_pkey             primary key (user_id, client_slug),
  constraint ap_memberships_user_id_fkey     foreign key (user_id)
    references public.ap_profiles (user_id) on delete cascade,
  constraint ap_memberships_client_slug_fkey foreign key (client_slug)
    references public.ap_clients (slug) on update cascade on delete cascade,
  constraint ap_memberships_role_check       check (role in ('auditor', 'client'))
);
create index ap_memberships_client_slug_idx on public.ap_memberships (client_slug);
comment on table public.ap_memberships is
  'B1 — one role per login per venue: auditor (all work at the venue, desktop and phone) | client (read-only; reaches no existing table — for the future ap_published_reports). The owner needs no rows here. Design: docs/auth-design.md';

-- ── 4. Their own RLS, and their own grants ──────────────────────────────────────────────────
-- Supabase's default privileges hand every new public table to anon AND authenticated with
-- ALL rights (TRUNCATE included, which RLS does not govern). Take that back first, then give
-- signed-in users read-only access. Writes (adding an auditor or a client, changing a role)
-- stay with the SQL Editor / service_role — so nobody can make themselves an owner from a browser.
alter table public.ap_profiles    enable row level security;
alter table public.ap_memberships enable row level security;

revoke all on table public.ap_profiles, public.ap_memberships from public, anon, authenticated;
grant select on table public.ap_profiles, public.ap_memberships to authenticated;
grant all    on table public.ap_profiles, public.ap_memberships to service_role;

-- ── 5. The helpers (SECURITY DEFINER: they read the two tables above without tripping RLS) ──
-- Each always returns true or false, never NULL. auth.uid() is NULL for an anonymous caller,
-- so every helper says false to one. Created in dependency order: can_view calls can_work.
create function private.is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.is_owner
       from public.ap_profiles p
      where p.user_id = (select auth.uid())),
    false)
$$;

create function private.can_work(p_slug text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_owner()
      or exists (select 1
                   from public.ap_memberships m
                  where m.user_id     = (select auth.uid())
                    and m.client_slug = p_slug
                    and m.role        = 'auditor')
$$;

create function private.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_owner()
      or exists (select 1
                   from public.ap_memberships m
                  where m.user_id = (select auth.uid())
                    and m.role    = 'auditor')
$$;

create function private.can_view(p_slug text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.can_work(p_slug)
      or exists (select 1
                   from public.ap_memberships m
                  where m.user_id     = (select auth.uid())
                    and m.client_slug = p_slug
                    and m.role        = 'client')
$$;

comment on function private.is_owner()      is 'B1 — true iff the caller''s ap_profiles row has is_owner (global: every venue, including ones created later).';
comment on function private.can_work(text) is 'B1 — owner, or an auditor membership of THIS venue: all work there, desktop and phone.';
comment on function private.is_staff()      is 'B1 — owner, or an auditor membership of ANY venue: the shared master catalogue and AI spend.';
comment on function private.can_view(text)  is 'B1 — can_work, or a client membership of this venue. For the future ap_published_reports only.';

-- Functions are executable by PUBLIC (so by anon) the moment they exist. Take that back.
revoke all on function private.is_owner(), private.can_work(text),
                       private.is_staff(), private.can_view(text) from public, anon;
grant execute on function private.is_owner(), private.can_work(text),
                          private.is_staff(), private.can_view(text) to authenticated, service_role;

-- ── 6. Read policies on the two new tables: your own row; the owner sees all ────────────────
create policy ap_profiles_read_own_or_owner on public.ap_profiles
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_owner()));

create policy ap_memberships_read_own_or_owner on public.ap_memberships
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_owner()));

-- ── 7. The two RPCs for the Worker — thin wrappers, SECURITY INVOKER ────────────────────────
-- They add no power of their own: they run as the caller and ask the helpers above.
create function public.ap_can_work(p_slug text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$ select private.can_work(p_slug) $$;

create function public.ap_is_staff()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$ select private.is_staff() $$;

comment on function public.ap_can_work(text) is
  'B1 — for the Worker: may the signed-in caller do audit work at this venue? Call with the USER''s token. Anonymous and secret-key calls: refused.';
comment on function public.ap_is_staff() is
  'B1 — for the Worker: is the signed-in caller the owner or an auditor anywhere (AI spend, master catalogue)? Call with the USER''s token. Anonymous and secret-key calls: refused.';

-- Supabase's default privileges grant EXECUTE on new public functions to anon, authenticated
-- AND service_role. Take all of it back, then give it to signed-in users only (design §2).
revoke all on function public.ap_can_work(text), public.ap_is_staff() from public, anon, service_role;
grant execute on function public.ap_can_work(text), public.ap_is_staff() to authenticated;

-- ── 8. Jeremy's owner row — fails loudly rather than inserting nothing ──────────────────────
do $owner$
declare
  v_email constant text := 'jeremyaibuid@gmail.com';
  v_users integer;
  v_rows  integer;
begin
  select count(*) into v_users from auth.users u where lower(u.email) = lower(v_email);
  if v_users = 0 then
    raise exception 'B1 NOT APPLIED: there is no Supabase Auth user with the email %. Check Authentication → Users. Nothing was changed.', v_email;
  end if;
  if v_users > 1 then
    raise exception 'B1 NOT APPLIED: % Auth users match the email %; expected exactly one. Nothing was changed.', v_users, v_email;
  end if;

  insert into public.ap_profiles (user_id, email, is_owner)
  select u.id, u.email, true
    from auth.users u
   where lower(u.email) = lower(v_email);
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'B1 NOT APPLIED: the owner row was not written (% rows). Nothing was changed.', v_rows;
  end if;
end
$owner$;

-- ── 9. The venue column on mobile counts ────────────────────────────────────────────────────
-- Nullable with no default, so r101's phone (which does not send it) keeps syncing exactly
-- as before; its new rows simply arrive untagged until the phone is taught to send it.
-- ON DELETE SET NULL: deleting a venue on the desktop still works exactly as before.
alter table public.ap_mobile_counts add column client_slug text;
alter table public.ap_mobile_counts
  add constraint ap_mobile_counts_client_slug_fkey foreign key (client_slug)
  references public.ap_clients (slug) on update cascade on delete set null;
create index ap_mobile_counts_client_slug_idx on public.ap_mobile_counts (client_slug);
comment on column public.ap_mobile_counts.client_slug is
  'B1 — the venue (ap_clients.slug) this count belongs to. NULL = synced by a phone that does not send it yet (r101).';

-- ── 10. Backfill — from what the phone itself wrote, then insist every count got its venue ──
-- Every CSV the phone builds starts "Client,<venue>" then "ClientId,<slug>" on line 2.
-- Measured 2026-11-24: 2 rows (AP-5723, AP-3128), both "ClientId,c_1775024388916".
do $backfill$
declare
  v_tagged integer;
  v_left   integer;
  v_list   text;
begin
  update public.ap_mobile_counts m
     set client_slug = c.slug
    from public.ap_clients c
   where m.client_slug is null
     and split_part(m.csv_data, chr(10), 2) = 'ClientId,' || c.slug;
  get diagnostics v_tagged = row_count;

  select count(*), string_agg(m.code || ' (row ' || m.id || ')', ', ' order by m.id)
    into v_left, v_list
    from public.ap_mobile_counts m
   where m.client_slug is null;
  if v_left > 0 then
    raise exception 'B1 NOT APPLIED: % mobile count(s) name no known venue on the ClientId line of their CSV: %. Nothing was changed. Send this message to Claude.', v_left, v_list;
  end if;

  select count(*), string_agg(m.code || ' → ' || m.client_slug, ', ' order by m.id)
    into v_left, v_list
    from public.ap_mobile_counts m
   where m.client_slug <> 'c_1775024388916';
  if v_left > 0 then
    raise exception 'B1 NOT APPLIED: % mobile count(s) belong to a venue other than 1 Up: %. Nothing was changed. Send this message to Claude.', v_left, v_list;
  end if;

  raise notice 'B1 backfill: % mobile count(s) tagged c_1775024388916.', v_tagged;
end
$backfill$;

commit;

-- ── The one result row you should see ───────────────────────────────────────────────────────
-- Expected: result = B1 foundation applied · owner_logins = 1 · owner_email = Jeremy's ·
--           counts_tagged_1up = 2 (more only if a phone synced since 24 Nov) · counts_untagged = 0
select 'B1 foundation applied'                                                          as result,
       (select count(*) from public.ap_profiles where is_owner)                         as owner_logins,
       (select string_agg(email, ', ') from public.ap_profiles where is_owner)          as owner_email,
       (select count(*) from public.ap_mobile_counts where client_slug = 'c_1775024388916') as counts_tagged_1up,
       (select count(*) from public.ap_mobile_counts where client_slug is null)         as counts_untagged;
