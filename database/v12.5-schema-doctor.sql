-- ============================================================================
-- School Connect V12.5 — SCHEMA DOCTOR (pass 73)
-- ----------------------------------------------------------------------------
-- THE RECURRING DISEASE, cured structurally: three full compliance audits in
-- a row traced "the issue still persists" to ONE cause — code deployed while
-- its SQL pack was never run in that school's Supabase. Nobody could SEE
-- which packs a database carried.
--
-- This pack gives every portal a self-diagnosis:
--   1. sc_installed_packs() — a SECURITY DEFINER reader over sc_install_state
--      that returns which packs this database has (admins only).
--   2. Marker rows for every prior pack THIS database already carries —
--      detected from their own artifacts (functions/columns/triggers), so the
--      markers are TRUTHFUL even on databases that ran packs before markers
--      existed.
--   3. Every FUTURE pack appends its own marker (template at the bottom).
-- The Platform Health Console's new "Schema Doctor" card calls the RPC and
-- lists exactly which database/*.sql files still need one run. Idempotent.
-- ============================================================================
select 'RUNNING: School Connect schema-doctor pack V12.5' as running_version;

-- 1. Reader RPC (admin/staff only — install state is not public knowledge)
create or replace function public.sc_installed_packs()
returns jsonb language plpgsql security definer stable set search_path=public as $$
begin
  if not public.is_staff(auth.uid()) then
    return '[]'::jsonb;
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('key', key, 'applied_at', applied_at))
                     from public.sc_install_state where key like 'v%.sql'), '[]'::jsonb);
end$$;
revoke execute on function public.sc_installed_packs() from public, anon;
grant execute on function public.sc_installed_packs() to authenticated;

-- 2. TRUTHFUL retro-markers: probe this database's own artifacts.
do $doctor$
begin
  -- v10.7: fee locks
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='students' and column_name='portal_locked') then
    insert into public.sc_install_state(key,details) values ('v10.7-fee-locks-arrears.sql','{"detected":"students.portal_locked"}') on conflict (key) do nothing;
  end if;
  -- v10.9b: fee doctor
  if to_regprocedure('public.sc_fee_ledger_doctor(boolean)') is not null then
    insert into public.sc_install_state(key,details) values ('v10.9b-fee-doctor.sql','{"detected":"sc_fee_ledger_doctor"}') on conflict (key) do nothing;
  end if;
  -- v11.0: timetable pro
  if to_regprocedure('public.sc_timetable_capacity(text[],integer,jsonb)') is not null then
    insert into public.sc_install_state(key,details) values ('v11.0-timetable-pro.sql','{"detected":"sc_timetable_capacity"}') on conflict (key) do nothing;
  end if;
  -- v11.7: admission year
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='students' and column_name='admission_year') then
    insert into public.sc_install_state(key,details) values ('v11.7-admission-year.sql','{"detected":"students.admission_year"}') on conflict (key) do nothing;
  end if;
  -- v11.9: voting integrity
  if to_regprocedure('public.sc_poll_results(uuid)') is not null then
    insert into public.sc_install_state(key,details) values ('v11.9-voting-integrity.sql','{"detected":"sc_poll_results"}') on conflict (key) do nothing;
  end if;
  -- v12.0: audit columns
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='staff' and column_name='date_of_birth') then
    insert into public.sc_install_state(key,details) values ('v12.0-audit-columns.sql','{"detected":"staff.date_of_birth"}') on conflict (key) do nothing;
  end if;
  -- v12.2: photo sync (trigger-only pack — THE one the client cannot probe)
  if exists (select 1 from pg_trigger where tgname='trg_students_photo_sync') then
    insert into public.sc_install_state(key,details) values ('v12.2-photo-sync.sql','{"detected":"trg_students_photo_sync"}') on conflict (key) do nothing;
  end if;
  -- v12.3: write columns
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='attendance_checkins' and column_name='status') then
    insert into public.sc_install_state(key,details) values ('v12.3-write-columns.sql','{"detected":"attendance_checkins.status"}') on conflict (key) do nothing;
  end if;
exception when others then
  raise notice 'schema-doctor retro-markers skipped (%)', sqlerrm;
end $doctor$;

-- 3. This pack's own marker (the template every future pack copies):
insert into public.sc_install_state(key,details)
  values ('v12.5-schema-doctor.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.5 schema-doctor pack installed' as status;
