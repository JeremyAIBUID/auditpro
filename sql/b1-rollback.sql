-- =====================================================================================
-- B1 — ROLLBACK                                                        sql/b1-rollback.sql
-- Undoes exactly sql/b1-foundation.sql and nothing else, returning the database to
-- sql/baseline-2026-11-24.json.
--
-- RUN THIS ONLY IF b1-foundation.sql SUCCEEDED (you saw "B1 foundation applied") AND THEN
-- one of these happened:
--   - sql/b1-verify.sql shows a check with ok = false that Claude says cannot be fixed forward;
--   - the r101 desktop app or a phone count sync stops working after B1;
--   - Claude asks you to.
-- If b1-foundation.sql showed an ERROR, it changed nothing — do NOT run this file.
--
-- HOW TO RUN: SQL Editor → New query → paste this WHOLE file → Run. Supabase will warn that
-- the query contains destructive operations — that is expected for THIS file only; confirm.
--   SUCCESS = one result row reading "B1 rolled back".
--   FAILURE = a red error. Nothing was changed. Send the message to Claude.
--
-- WHAT IS LOST: the owner row, any logins and auditor/client memberships you added after B1,
-- and the venue tag on mobile counts. The counts themselves (codes, CSVs, line totals) are NOT
-- touched.
--
-- SAFETY: no CASCADE anywhere. If something built later (a B5 table policy, say) depends on a
-- B1 object, Postgres refuses and this whole file changes nothing — roll the later step back first.
-- This undoes THIS version of B1 only. If it refuses because the superseded first draft
-- (commit e1b4b70) is applied, it has changed nothing: send the message to Claude.
-- =====================================================================================

begin;

do $guard$
begin
  if to_regnamespace('private') is null then
    raise exception 'ROLLBACK NOT RUN: B1 is not applied (there is no "private" schema). Nothing was changed.';
  end if;
  if to_regclass('public.ap_profiles') is null or to_regclass('public.ap_memberships') is null then
    raise exception 'ROLLBACK NOT RUN: ap_profiles or ap_memberships is missing, so this is not the state B1 leaves. Nothing was changed. Send this message to Claude.';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ap_mobile_counts'
                    and column_name = 'client_slug') then
    raise exception 'ROLLBACK NOT RUN: ap_mobile_counts.client_slug is missing, so this is not the state B1 leaves. Nothing was changed. Send this message to Claude.';
  end if;
  if to_regprocedure('private.is_staff(text)') is not null then
    raise exception 'ROLLBACK NOT RUN: this database has the superseded FIRST DRAFT of B1 (commit e1b4b70, roles staff/viewer), which this file does not undo. Nothing was changed. Send this message to Claude.';
  end if;
end
$guard$;

-- The Worker RPCs first (nothing in B1 depends on them).
drop function public.ap_is_staff();
drop function public.ap_can_work(text);

-- The two tables, with their own policies, grants, indexes and keys. Their policies call
-- private.is_owner(), so the tables must go before the helpers.
drop table public.ap_memberships;
drop table public.ap_profiles;

-- The helpers (reverse of creation order), then the schema, which must now be empty —
-- RESTRICT is the default.
drop function private.can_view(text);
drop function private.is_staff();
drop function private.can_work(text);
drop function private.is_owner();
drop schema private;

-- The venue column. Its foreign key and index belong to the column and go with it.
alter table public.ap_mobile_counts drop column client_slug;

commit;

-- Expected: result = B1 rolled back · private_schema = absent · new_tables = 0 ·
--           client_slug_column = absent · mobile_counts = 2 (or however many existed)
select 'B1 rolled back'                                                                  as result,
       case when to_regnamespace('private') is null then 'absent' else 'STILL PRESENT' end as private_schema,
       (select count(*) from pg_class
         where relnamespace = 'public'::regnamespace
           and relname in ('ap_profiles', 'ap_memberships'))                              as new_tables,
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'ap_mobile_counts'
                            and column_name = 'client_slug')
            then 'STILL PRESENT' else 'absent' end                                       as client_slug_column,
       (select count(*) from public.ap_mobile_counts)                                   as mobile_counts;
