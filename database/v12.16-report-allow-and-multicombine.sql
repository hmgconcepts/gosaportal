-- ============================================================================
-- School Connect V12.16 — REPORT ALLOW/DISALLOW ONE-CLICK + MULTI-COMBO FROM PRE-EXISTING CBTs (pass 91)
-- ----------------------------------------------------------------------------
-- Fixes:
-- 1. Report Cards student auto-fill robust + admin one-click allow/disallow per term
--    - Adds academic_periods.allow_student_report boolean default false
--    - Adds school_settings.allow_student_report_global boolean default false (fallback)
--    - RPC sc_set_report_generation_allowed(p_term text, p_session text, p_allowed boolean) admin-only, upserts academic_periods
--    - RPC sc_is_report_generation_allowed(p_term text, p_session text) returns boolean (checks academic_periods row, else global, else false)
--    - Student generation blocked when not allowed (with bold message)
-- 2. Multi-subject CBT from pre-existing CBTs one-click — JS in cbt-multi.html (no DB change, but marker)
--    - Admin can select multiple existing CBTs and create multi-subject in one click
-- 3. Audit every page — ensures robustness
--
-- Idempotent
-- ============================================================================
select 'RUNNING: School Connect report allow/disallow + multi-combine pack V12.16' as running_version;

-- 1. Add column to academic_periods
alter table public.academic_periods add column if not exists allow_student_report boolean not null default false;
alter table public.academic_periods add column if not exists allow_parent_report boolean not null default false;

-- 2. Add global fallback to school_settings
alter table public.school_settings add column if not exists allow_student_report_global boolean not null default false;
alter table public.school_settings add column if not exists allow_parent_report_global boolean not null default false;

-- 3. RPC to set allowed per term/session (admin-only, one-click)
create or replace function public.sc_set_report_generation_allowed(p_term text, p_session text, p_allowed boolean, p_allow_parent boolean default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_exists boolean;
begin
  if not public.is_admin(auth.uid()) and not public.is_school_leader(auth.uid()) then
    return jsonb_build_object('ok',false,'error','Only admin/principal can set report generation permission');
  end if;
  if p_term is null or p_term='' then
    return jsonb_build_object('ok',false,'error','Term required');
  end if;
  -- Upsert academic_periods row for that term/session
  -- If session null, try to find current session or use provided
  insert into public.academic_periods(term, session, is_current, allow_student_report, allow_parent_report, starts_on)
  values (p_term, coalesce(p_session, (select session from public.academic_periods where is_current=true limit 1), ''), false, p_allowed, coalesce(p_allow_parent, p_allowed), current_date)
  on conflict (term, session) do update set allow_student_report=excluded.allow_student_report, allow_parent_report=coalesce(excluded.allow_parent_report, public.academic_periods.allow_parent_report);
  -- Also handle case where table has no unique constraint on (term,session) — try update if insert conflict not caught
  -- Fallback: update any row with matching term and (session = p_session or p_session null)
  if p_session is not null then
    update public.academic_periods set allow_student_report=p_allowed, allow_parent_report=coalesce(p_allow_parent, p_allowed) where term=p_term and session=p_session;
  else
    update public.academic_periods set allow_student_report=p_allowed, allow_parent_report=coalesce(p_allow_parent, p_allowed) where term=p_term;
  end if;
  return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',p_allowed,'allow_parent',coalesce(p_allow_parent,p_allowed));
end$$;

revoke all on function public.sc_set_report_generation_allowed(text,text,boolean,boolean) from public, anon;
grant execute on function public.sc_set_report_generation_allowed(text,text,boolean,boolean) to authenticated;

-- 4. RPC to check if allowed
create or replace function public.sc_is_report_generation_allowed(p_term text, p_session text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_allowed boolean := false;
declare v_parent boolean := false;
declare v_row record;
declare v_global record;
begin
  -- Try specific term/session
  if p_session is not null then
    select allow_student_report, allow_parent_report into v_row from public.academic_periods where term=p_term and session=p_session limit 1;
    if found then
      return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',coalesce(v_row.allow_student_report,false),'allow_parent',coalesce(v_row.allow_parent_report,false),'source','academic_periods');
    end if;
  end if;
  -- Try term only
  select allow_student_report, allow_parent_report into v_row from public.academic_periods where term=p_term order by is_current desc, starts_on desc limit 1;
  if found then
    return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',coalesce(v_row.allow_student_report,false),'allow_parent',coalesce(v_row.allow_parent_report,false),'source','academic_periods_term');
  end if;
  -- Fallback to global setting
  select allow_student_report_global, allow_parent_report_global into v_global from public.school_settings where id=1;
  if found then
    return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',coalesce(v_global.allow_student_report_global,false),'allow_parent',coalesce(v_global.allow_parent_report_global,false),'source','school_settings_global');
  end if;
  return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',false,'allow_parent',false,'source','default_false');
end$$;

revoke all on function public.sc_is_report_generation_allowed(text,text) from public, anon;
grant execute on function public.sc_is_report_generation_allowed(text,text) to authenticated;

-- 5. RPC to set global allow (one-click for all terms)
create or replace function public.sc_set_report_generation_global(p_allowed boolean, p_allow_parent boolean default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin(auth.uid()) and not public.is_school_leader(auth.uid()) then
    return jsonb_build_object('ok',false,'error','Only admin can set global');
  end if;
  update public.school_settings set allow_student_report_global=p_allowed, allow_parent_report_global=coalesce(p_allow_parent, p_allowed) where id=1;
  -- Also update all academic_periods if you want? No, global is fallback, per-term overrides
  return jsonb_build_object('ok',true,'allowed',p_allowed,'allow_parent',coalesce(p_allow_parent,p_allowed),'scope','global');
end$$;

revoke all on function public.sc_set_report_generation_global(boolean,boolean) from public, anon;
grant execute on function public.sc_set_report_generation_global(boolean,boolean) to authenticated;

-- Ensure subject-inclusive index still exists
drop index if exists assignment_scores_cbt_subject_unique;
create unique index if not exists assignment_scores_cbt_subject_unique on public.assignment_scores(cbt_exam_id, student_id, subject) where cbt_exam_id is not null;
drop index if exists assignment_scores_cbt_unique;

-- Marker
insert into public.sc_install_state(key,details) values ('v12.16-report-allow-and-multicombine.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.16 report allow/disallow + multi-combine pack installed' as status;
