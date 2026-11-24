-- =====================================================================================
-- B1 — VERIFY (read-only)                                                sql/b1-verify.sql
-- Run AFTER sql/b1-foundation.sql has shown "B1 foundation applied".
--
-- HOW TO RUN: SQL Editor → New query → paste this WHOLE file → Run.
-- It is ONE read-only SELECT. It changes nothing, so it is safe to run as often as you like.
--
-- WHAT YOU SHOULD SEE: one row per check, plus a last row "SUMMARY".
--   Every row has ok = true, and SUMMARY reads "all 30 checks ok".
--   Any ok = false → copy the whole result to Claude. Do not roll back on your own.
--   "relation ... does not exist" / "column client_slug does not exist" → B1 is not applied.
--
-- The "baseline" checks (area D) compare the live database against values copied by script
-- from sql/baseline-2026-11-24.json (the SQL Editor cannot read a file). They read the same
-- catalog views the baseline was captured from, so like is compared with like.
-- Running it again after a phone count has synced is fine: a count synced after B1 arrives
-- without a venue (r101 does not send one) and no check counts it as a failure.
-- Areas A, E and F check the agreed design in docs/auth-design.md: roles auditor/client only,
-- is_staff() with no venue, and the Worker RPCs executable by authenticated only.
-- =====================================================================================
with
-- ── The baseline, transcribed by script from sql/baseline-2026-11-24.json — do not hand-edit ──
base_rls (tbl, rls) as (values
  ('ap_mobile_counts', true),
  ('ap_products', true),
  ('ap_clients', true),
  ('ap_audit_sessions', true),
  ('ap_batches', true),
  ('ap_master_products', true)
),
base_policies (schemaname, tablename, policyname, roles, cmd, qual, with_check) as (values
  ('public', 'ap_mobile_counts', 'allow all', '{public}', 'ALL', 'true', 'true'),
  ('public', 'ap_products', 'public_all', '{public}', 'ALL', 'true', 'true'),
  ('public', 'ap_clients', 'public_all', '{public}', 'ALL', 'true', 'true'),
  ('public', 'ap_audit_sessions', 'public_all', '{public}', 'ALL', 'true', 'true'),
  ('public', 'ap_batches', 'public_all', '{public}', 'ALL', 'true', 'true'),
  ('public', 'ap_master_products', 'public_all', '{public}', 'ALL', 'true', 'true'),
  ('storage', 'objects', 'invoices_full_access blin7q_3', '{service_role}', 'DELETE', 'true', null),
  ('storage', 'objects', 'invoices_full_access blin7q_2', '{service_role}', 'UPDATE', 'true', null),
  ('storage', 'objects', 'invoices_full_access blin7q_1', '{service_role}', 'INSERT', null, 'true'),
  ('storage', 'objects', 'invoices_full_access blin7q_0', '{service_role}', 'SELECT', 'true', null)
),
base_grants (table_name, grantee, privs) as (values  -- privilege lists sorted, as compared below
  ('ap_audit_sessions', 'anon', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_audit_sessions', 'authenticated', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_batches', 'anon', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_batches', 'authenticated', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_clients', 'anon', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_clients', 'authenticated', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_master_products', 'anon', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_master_products', 'authenticated', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_mobile_counts', 'anon', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_mobile_counts', 'authenticated', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_products', 'anon', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE'),
  ('ap_products', 'authenticated', 'DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE')
),
base_constraints (tbl, conname, def) as (values
  ('ap_audit_sessions', 'ap_audit_sessions_pkey', 'PRIMARY KEY (id)'),
  ('ap_audit_sessions', 'ap_audit_sessions_session_id_key', 'UNIQUE (session_id)'),
  ('ap_batches', 'ap_batches_pkey', 'PRIMARY KEY (id)'),
  ('ap_clients', 'ap_clients_pkey', 'PRIMARY KEY (id)'),
  ('ap_clients', 'ap_clients_slug_key', 'UNIQUE (slug)'),
  ('ap_master_products', 'ap_master_products_pkey', 'PRIMARY KEY (id)'),
  ('ap_master_products', 'ap_master_products_slug_key', 'UNIQUE (slug)'),
  ('ap_mobile_counts', 'ap_mobile_counts_code_key', 'UNIQUE (code)'),
  ('ap_mobile_counts', 'ap_mobile_counts_pkey', 'PRIMARY KEY (id)'),
  ('ap_products', 'ap_products_pkey', 'PRIMARY KEY (id)')
),
base_mc_columns (column_name, data_type, is_nullable) as (values
  ('id', 'bigint', 'NO'),
  ('code', 'text', 'YES'),
  ('client', 'text', 'YES'),
  ('client_id', 'text', 'YES'),
  ('csv_data', 'text', 'YES'),
  ('lines', 'integer', 'YES'),
  ('created_at', 'timestamp with time zone', 'YES')
),
six (tbl) as (select tbl from base_rls),

-- ── The same views, read live ─────────────────────────────────────────────────────────────
live_rls as (
  select c.relname::text as tbl, c.relrowsecurity as rls
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
),
live_policies as (
  select schemaname::text as schemaname, tablename::text as tablename, policyname::text as policyname,
         roles::text as roles, cmd::text as cmd, qual::text as qual, with_check::text as with_check
    from pg_policies
),
live_grants as (
  select table_name::text as table_name, grantee::text as grantee,
         string_agg(privilege_type::text, ',' order by privilege_type::text collate "C") as privs
    from information_schema.role_table_grants
   where table_schema = 'public'
   group by table_name, grantee
),
live_constraints as (
  select cl.relname::text as tbl, co.conname::text as conname, pg_get_constraintdef(co.oid) as def
    from pg_constraint co
    join pg_class cl on cl.oid = co.conrelid
   where co.connamespace = 'public'::regnamespace
     and co.contype <> 'n'          -- NOT NULL rows only exist from Postgres 18; not in the baseline
),
live_mc_columns as (
  select column_name::text as column_name, data_type::text as data_type, is_nullable::text as is_nullable,
         column_default::text as column_default
    from information_schema.columns
   where table_schema = 'public' and table_name = 'ap_mobile_counts'
),
b1_functions as (
  select p.oid, n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as fn,
         p.prosecdef, p.proconfig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private'
      or (n.nspname = 'public' and p.proname in ('ap_can_work', 'ap_is_staff'))
),
b1_ran_at as (
  select min(created_at) as at from public.ap_profiles where is_owner
),

checks (n, area, check_name, expected, actual) as (

  -- ═══ A. The new objects exist ══════════════════════════════════════════════════════════
  -- Expected: present
  select 1, 'A new objects', 'schema private exists',
         'present',
         case when to_regnamespace('private') is not null then 'present' else 'absent' end
  union all
  -- Expected: present, RLS on
  select 2, 'A new objects', 'table ap_profiles exists with RLS on',
         'present, RLS on',
         coalesce((select case when c.relrowsecurity then 'present, RLS on' else 'present, RLS OFF' end
                     from pg_class c where c.oid = to_regclass('public.ap_profiles')), 'absent')
  union all
  -- Expected: present, RLS on
  select 3, 'A new objects', 'table ap_memberships exists with RLS on',
         'present, RLS on',
         coalesce((select case when c.relrowsecurity then 'present, RLS on' else 'present, RLS OFF' end
                     from pg_class c where c.oid = to_regclass('public.ap_memberships')), 'absent')
  union all
  -- Expected: exactly one read policy on each new table, for signed-in users only
  select 4, 'A new objects', 'policies on the two new tables',
         'ap_memberships.ap_memberships_read_own_or_owner SELECT {authenticated}; ap_profiles.ap_profiles_read_own_or_owner SELECT {authenticated}',
         coalesce((select string_agg(tablename || '.' || policyname || ' ' || cmd || ' ' || roles, '; '
                                     order by tablename collate "C", policyname collate "C")
                     from live_policies
                    where schemaname = 'public' and tablename in ('ap_profiles', 'ap_memberships')), 'none')
  union all
  -- Expected: the four helpers, all SECURITY DEFINER, and nothing else in the schema.
  -- is_staff() takes NO venue (any auditor membership anywhere). "is_staff(p_slug text)" = the superseded draft.
  select 5, 'A new objects', 'helper functions in schema private',
         'private.can_view(p_slug text) definer; private.can_work(p_slug text) definer; private.is_owner() definer; private.is_staff() definer',
         coalesce((select string_agg(fn || case when prosecdef then ' definer' else ' invoker' end, '; '
                                     order by fn collate "C")
                     from b1_functions where fn like 'private.%'), 'none')
  union all
  -- Expected: the two Worker RPCs, both SECURITY INVOKER (they add no power of their own)
  select 6, 'A new objects', 'Worker RPCs in schema public',
         'public.ap_can_work(p_slug text) invoker; public.ap_is_staff() invoker',
         coalesce((select string_agg(fn || case when prosecdef then ' definer' else ' invoker' end, '; '
                                     order by fn collate "C")
                     from b1_functions where fn like 'public.%'), 'none')
  union all
  -- Expected: 6 of 6 (a SECURITY DEFINER function without a fixed search_path can be hijacked)
  select 7, 'A new objects', 'all six functions pin an empty search_path',
         '6 of 6',
         (select count(*) filter (where proconfig @> array['search_path=""']) || ' of ' || count(*) from b1_functions)
  union all
  -- Expected: text, nullable, no default (so r101's phone, which does not send it, still inserts)
  select 8, 'A new objects', 'ap_mobile_counts.client_slug column',
         'text, nullable, no default',
         coalesce((select data_type || ', ' || case is_nullable when 'YES' then 'nullable' else 'NOT NULL' end
                          || ', ' || coalesce('default ' || column_default, 'no default')
                     from live_mc_columns where column_name = 'client_slug'), 'absent')
  union all
  -- Expected: the venue key, which lets a venue be deleted exactly as before (SET NULL)
  select 9, 'A new objects', 'client_slug foreign key',
         'FOREIGN KEY (client_slug) REFERENCES ap_clients(slug) ON UPDATE CASCADE ON DELETE SET NULL',
         coalesce((select replace(def, 'public.', '') from live_constraints
                    where tbl = 'ap_mobile_counts' and conname = 'ap_mobile_counts_client_slug_fkey'), 'absent')

  -- ═══ B. Jeremy is the owner ═════════════════════════════════════════════════════════════
  union all
  -- Expected: is_owner = true
  select 10, 'B owner', 'jeremyaibuid@gmail.com has a profile with is_owner = true',
         'is_owner = true',
         coalesce((select string_agg('is_owner = ' || p.is_owner::text, ', ')
                     from public.ap_profiles p
                     join auth.users u on u.id = p.user_id
                    where lower(u.email) = lower('jeremyaibuid@gmail.com')), 'no profile row')
  union all
  -- Expected: 1 profile, 1 owner, 0 memberships (more only once you add logins yourself)
  select 11, 'B owner', 'profiles / owners / memberships',
         '1 profile, 1 owner, 0 memberships',
         (select count(*) from public.ap_profiles) || ' profile, '
           || (select count(*) from public.ap_profiles where is_owner) || ' owner, '
           || (select count(*) from public.ap_memberships) || ' memberships'

  -- ═══ C. The two existing counts are backfilled ══════════════════════════════════════════
  union all
  -- Expected: 2: AP-3128, AP-5723 (a third code only if a phone synced between 24 Nov and B1)
  select 12, 'C backfill', 'counts tagged to 1 Up (c_1775024388916)',
         '2: AP-3128, AP-5723',
         (select count(*) || ': ' || coalesce(string_agg(code, ', ' order by code collate "C"), '')
            from public.ap_mobile_counts where client_slug = 'c_1775024388916')
  union all
  -- Expected: 0. (Counts synced AFTER B1 are untagged by design and are not counted here.)
  select 13, 'C backfill', 'counts older than B1 still without a venue',
         '0',
         (select count(*)::text from public.ap_mobile_counts m, b1_ran_at b
           where m.client_slug is null and (m.created_at is null or m.created_at < b.at))
  union all
  -- Expected: none (no count may point at a venue other than 1 Up)
  select 14, 'C backfill', 'counts tagged to any other venue',
         'none',
         coalesce((select string_agg(code || ' → ' || client_slug, ', ' order by code collate "C")
                     from public.ap_mobile_counts where client_slug <> 'c_1775024388916'), 'none')

  -- ═══ D. Everything in the baseline is UNCHANGED ═════════════════════════════════════════
  union all
  -- Expected: 0 differ (RLS still ON on all six original tables)
  select 20, 'D baseline', 'RLS on the six original tables',
         '0 differ',
         (select count(*) || ' differ' || coalesce(': ' || string_agg(b.tbl, ', ' order by b.tbl collate "C"), '')
            from base_rls b left join live_rls l on l.tbl = b.tbl
           where l.rls is distinct from b.rls)
  union all
  -- Expected: 0 missing or changed (the 6 allow-all policies + the 4 Storage policies)
  select 21, 'D baseline', 'the 10 baseline policies are all still there, unchanged',
         '0 missing or changed',
         (select count(*) || ' missing or changed'
                 || coalesce(': ' || string_agg(b.schemaname || '.' || b.tablename || '.' || b.policyname, ', '
                                                order by b.tablename collate "C", b.policyname collate "C"), '')
            from base_policies b
           where not exists (select 1 from live_policies l
                              where l.schemaname = b.schemaname and l.tablename = b.tablename
                                and l.policyname = b.policyname and l.roles = b.roles and l.cmd = b.cmd
                                and l.qual is not distinct from b.qual
                                and l.with_check is not distinct from b.with_check))
  union all
  -- Expected: 0 added (no new policy on any original table, nor on Storage)
  select 22, 'D baseline', 'no policy added to the six original tables or to Storage',
         '0 added',
         (select count(*) || ' added'
                 || coalesce(': ' || string_agg(l.schemaname || '.' || l.tablename || '.' || l.policyname, ', '
                                                order by l.tablename collate "C", l.policyname collate "C"), '')
            from live_policies l
           where ((l.schemaname = 'public' and l.tablename in (select tbl from six))
                  or (l.schemaname = 'storage' and l.tablename = 'objects'))
             and not exists (select 1 from base_policies b
                              where b.schemaname = l.schemaname and b.tablename = l.tablename
                                and b.policyname = l.policyname))
  union all
  -- Expected: 0 differ (anon + authenticated keep exactly the 7 privileges they had on all six)
  select 23, 'D baseline', 'anon / authenticated grants on the six original tables',
         '0 differ',
         (select count(*) || ' differ' || coalesce(': ' || string_agg(x, ', ' order by x collate "C"), '')
            from (select b.table_name || '/' || b.grantee as x
                    from base_grants b
                    left join live_grants l on l.table_name = b.table_name and l.grantee = b.grantee
                   where l.privs is distinct from b.privs
                  union all
                  select l.table_name || '/' || l.grantee || ' (new)'
                    from live_grants l
                   where l.table_name in (select tbl from six)
                     and l.grantee in ('anon', 'authenticated', 'PUBLIC')
                     and not exists (select 1 from base_grants b
                                      where b.table_name = l.table_name and b.grantee = l.grantee)) d)
  union all
  -- Expected: 0 missing or changed (UNIQUE (code) and UNIQUE (slug) among them)
  select 24, 'D baseline', 'the 10 baseline constraints are all still there, unchanged',
         '0 missing or changed',
         (select count(*) || ' missing or changed'
                 || coalesce(': ' || string_agg(b.tbl || '.' || b.conname, ', ' order by b.conname collate "C"), '')
            from base_constraints b
           where not exists (select 1 from live_constraints l
                              where l.tbl = b.tbl and l.conname = b.conname and l.def = b.def))
  union all
  -- Expected: exactly one — the new venue key on ap_mobile_counts
  select 25, 'D baseline', 'constraints added to the six original tables',
         'ap_mobile_counts.ap_mobile_counts_client_slug_fkey',
         coalesce((select string_agg(l.tbl || '.' || l.conname, ', ' order by l.conname collate "C")
                     from live_constraints l
                    where l.tbl in (select tbl from six)
                      and not exists (select 1 from base_constraints b
                                       where b.tbl = l.tbl and b.conname = l.conname)), 'none')
  union all
  -- Expected: 0 differ (the 7 original ap_mobile_counts columns are untouched)
  select 26, 'D baseline', 'the 7 original ap_mobile_counts columns',
         '0 differ',
         (select count(*) || ' differ' || coalesce(': ' || string_agg(b.column_name, ', ' order by b.column_name collate "C"), '')
            from base_mc_columns b
            left join live_mc_columns l on l.column_name = b.column_name
           where l.data_type is distinct from b.data_type or l.is_nullable is distinct from b.is_nullable)
  union all
  -- Expected: client_slug (and nothing else)
  select 27, 'D baseline', 'columns added to ap_mobile_counts',
         'client_slug',
         coalesce((select string_agg(l.column_name, ', ' order by l.column_name collate "C")
                     from live_mc_columns l
                    where not exists (select 1 from base_mc_columns b where b.column_name = l.column_name)), 'none')

  -- ═══ E. Anonymous callers can reach none of it ═════════════════════════════════════════
  union all
  -- Expected: none (counts grants to PUBLIC too, which anon inherits)
  select 30, 'E permissions', 'functions anon can execute (of the six B1 functions)',
         'none',
         coalesce((select string_agg(fn, ', ' order by fn collate "C")
                     from b1_functions where has_function_privilege('anon', oid, 'EXECUTE')), 'none')
  union all
  -- Expected: 6 of 6 (signed-in users need them, because later policies run as the caller)
  select 31, 'E permissions', 'functions authenticated can execute',
         '6 of 6',
         (select count(*) filter (where has_function_privilege('authenticated', oid, 'EXECUTE'))
                 || ' of ' || count(*) from b1_functions)
  union all
  -- Expected: anon no, authenticated yes
  select 32, 'E permissions', 'USAGE on schema private',
         'anon: no, authenticated: yes',
         'anon: ' || case has_schema_privilege('anon', to_regnamespace('private')::oid, 'USAGE')
                       when true then 'yes' when false then 'no' else 'schema absent' end
           || ', authenticated: ' || case has_schema_privilege('authenticated', to_regnamespace('private')::oid, 'USAGE')
                       when true then 'yes' when false then 'no' else 'schema absent' end
  union all
  -- Expected: none
  select 33, 'E permissions', 'anon / PUBLIC privileges on ap_profiles and ap_memberships',
         'none',
         coalesce((select string_agg(table_name || '/' || grantee || ': ' || privs, '; '
                                     order by table_name collate "C", grantee collate "C")
                     from live_grants
                    where table_name in ('ap_profiles', 'ap_memberships') and grantee in ('anon', 'PUBLIC')), 'none')
  union all
  -- Expected: read-only — no INSERT/UPDATE/DELETE/TRUNCATE, so nobody can make themselves owner
  select 34, 'E permissions', 'authenticated privileges on ap_profiles and ap_memberships',
         'ap_memberships: SELECT; ap_profiles: SELECT',
         coalesce((select string_agg(table_name || ': ' || privs, '; ' order by table_name collate "C")
                     from live_grants
                    where table_name in ('ap_profiles', 'ap_memberships') and grantee = 'authenticated'), 'none')
  union all
  -- Expected: authenticated ONLY, on both. Not anon, and not service_role: the secret key carries no
  -- user, so a Worker wired to it must get a permission error rather than "no" for everyone.
  select 35, 'E permissions', 'who may execute the two Worker RPCs (of anon / authenticated / service_role)',
         'public.ap_can_work(p_slug text): authenticated; public.ap_is_staff(): authenticated',
         coalesce((select string_agg(f.fn || ': ' || coalesce(
                                       (select string_agg(r.rolname, ', ' order by r.rolname collate "C")
                                          from (values ('anon'), ('authenticated'), ('service_role')) r (rolname)
                                         where has_function_privilege(r.rolname, f.oid, 'EXECUTE')), 'nobody'),
                                     '; ' order by f.fn collate "C")
                     from b1_functions f where f.fn like 'public.%'), 'none')

  -- ═══ F. The roles are the agreed ones (docs/auth-design.md §1) ═════════════════════════
  union all
  -- Expected: auditor and client ONLY. 'staff' / 'viewer' were the superseded draft's; owner is a flag, not a role.
  select 40, 'F roles', 'ap_memberships.role may only be auditor or client',
         'CHECK ((role = ANY (ARRAY[''auditor''::text, ''client''::text])))',
         coalesce((select def from live_constraints
                    where tbl = 'ap_memberships' and conname = 'ap_memberships_role_check'), 'absent')
  union all
  -- Expected: one role per login per venue
  select 41, 'F roles', 'ap_memberships key: one role per login per venue',
         'PRIMARY KEY (user_id, client_slug)',
         coalesce((select def from live_constraints
                    where tbl = 'ap_memberships' and conname = 'ap_memberships_pkey'), 'absent')
)
select n, area, check_name, expected, actual, (actual = expected) as ok
  from checks
union all
select 99, 'SUMMARY', 'all checks', 'all ' || count(*) || ' checks ok',
       case when count(*) filter (where actual is distinct from expected) = 0
            then 'all ' || count(*) || ' checks ok'
            else count(*) filter (where actual is distinct from expected) || ' of ' || count(*) || ' FAILED: '
                 || string_agg(n::text, ', ' order by n) filter (where actual is distinct from expected) end,
       count(*) filter (where actual is distinct from expected) = 0
  from checks
order by n;
