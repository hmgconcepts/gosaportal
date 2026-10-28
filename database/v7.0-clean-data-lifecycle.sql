-- ============================================================
-- V7.0 — CLEAN DATA LIFECYCLE (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- 11. Deleting a student now really removes their footprint:
--     • BEFORE DELETE trigger archives the full student row (JSON)
--       into module_records (module 'student_archive') for record
--       tracking, then AFTER DELETE cleans every loose row that
--       referenced the student only by name/admission number
--       (report_scores, results, attendance, traits, comments,
--       punctuality, CBT roster). The admission number becomes
--       reusable immediately.
-- 13. Ghost report sheets: deleting an assessment column already
--     cascades report_scores, but the rows MIRRORED into `results`
--     (assessment_source='report_sheet') survived and kept printing.
--     sc_sweep_report_ghosts() removes those orphans + any
--     score rows belonging to students that no longer exist.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this release.
-- ============================================================

-- ---------- 11a. archive on delete (record tracking) ----------
create or replace function public.sc_archive_student_on_delete()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.module_records (module, title, body, status, data, created_by)
  values ('student_archive',
          'Deleted student: ' || coalesce(old.full_name,'(unnamed)') || ' (' || coalesce(old.admission_no,'no adm no') || ')',
          'Full record archived automatically at deletion. The admission number is free for reuse.',
          'archived',
          to_jsonb(old),
          auth.uid());
  return old;
end $$;
drop trigger if exists trg_student_archive on public.students;
create trigger trg_student_archive before delete on public.students
for each row execute function public.sc_archive_student_on_delete();

-- ---------- 11b. full cleanup of name/admission-linked leftovers ----------
create or replace function public.sc_cleanup_student_leftovers()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  -- rows that referenced the student ONLY by admission number / name
  delete from public.report_scores
   where (old.admission_no is not null and student_id_ref = old.admission_no)
      or (student_id is null and lower(student_name) = lower(old.full_name));
  delete from public.results
   where student_id is null
     and ((old.admission_no is not null and coalesce(student_id_ref,'') = old.admission_no)
          or lower(coalesce(student_name,'')) = lower(old.full_name));
  delete from public.punctuality_awards
   where (old.admission_no is not null and student_id_ref = old.admission_no)
      or (student_id is null and lower(student_name) = lower(old.full_name));
  delete from public.cbt_roster
   where old.admission_no is not null and student_id_ref = old.admission_no;
  delete from public.attendance_checkins
   where old.admission_no is not null and student_id_ref = old.admission_no;
  return old;
end $$;
drop trigger if exists trg_student_cleanup on public.students;
create trigger trg_student_cleanup after delete on public.students
for each row execute function public.sc_cleanup_student_leftovers();

-- results.student_id_ref may not exist on very old installs
alter table public.results add column if not exists student_id_ref text default '';

-- ---------- 13. ghost sweeper (admin button on Report Cards) ----------
create or replace function public.sc_sweep_report_ghosts(
  p_class text default '', p_term text default '', p_session text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare mirrored int := 0; orphans int := 0; ghosts int := 0;
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'Admin role required.';
  end if;
  -- A. mirrored report-sheet rows in `results` whose backing report_scores
  --    entry no longer exists (column deleted / re-created)
  delete from public.results r
   where r.assessment_source = 'report_sheet'
     and (p_class=''   or r.class   = p_class)
     and (p_term=''    or r.term    = p_term)
     and (p_session='' or r.session = p_session)
     and not exists (select 1 from public.report_scores s
                      where lower(s.student_name) = lower(r.student_name)
                        and s.class = r.class and s.subject = r.subject
                        and s.term = r.term and s.session = r.session);
  get diagnostics mirrored = row_count;
  -- B. report_scores rows whose student no longer exists at all
  delete from public.report_scores s
   where (p_class=''   or s.class   = p_class)
     and (p_term=''    or s.term    = p_term)
     and (p_session='' or s.session = p_session)
     and s.student_id is null
     and not exists (select 1 from public.students st
                      where st.admission_no = s.student_id_ref
                         or lower(st.full_name) = lower(s.student_name));
  get diagnostics orphans = row_count;
  -- C. legacy `results` rows for students that no longer exist (name-only rows)
  delete from public.results r
   where (p_class=''   or r.class   = p_class)
     and (p_term=''    or r.term    = p_term)
     and (p_session='' or r.session = p_session)
     and r.student_id is null
     and not exists (select 1 from public.students st
                      where lower(st.full_name) = lower(coalesce(r.student_name,''))
                         or (coalesce(r.student_id_ref,'') <> '' and st.admission_no = r.student_id_ref));
  get diagnostics ghosts = row_count;
  return jsonb_build_object('ok', true, 'mirrored_removed', mirrored,
                            'orphan_scores_removed', orphans, 'ghost_results_removed', ghosts);
end $$;
revoke execute on function public.sc_sweep_report_ghosts(text,text,text) from public, anon;
grant  execute on function public.sc_sweep_report_ghosts(text,text,text) to authenticated;

notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V7.0 clean data lifecycle installed ✅' as status;
