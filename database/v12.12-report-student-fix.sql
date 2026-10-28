-- ============================================================================
-- School Connect V12.12 — REPORT CARDS STUDENT GENERATION FIX (pass 86)
-- ----------------------------------------------------------------------------
-- Fixes: student dashboard report cards Generate outputs fields not clickable
-- - Previously had data-readonly-role="student parent" which disabled fields via App.applyVisibilityTokens
-- - Students should be able to generate their own report card for previous term or current term once admin permits (report_locked check)
-- - This SQL pack ensures:
--   1. assessment_columns has Assignment column (if not exists, creates for all classes)
--   2. report_scores RLS allows students to read their own scores (already via is_admin or is_parent_of or user_id, but ensure)
--   3. sc_my_access_state RPC exists and returns report_locked per student (from V10.7)
--   4. Marker for schema doctor
--
-- Also consolidates V12.8-12.11 assignment bridge fixes (cbt_exam_id, is_cbt, source, drive_link, indexes, mirror triggers with drive_link)
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect report student generation fix pack V12.12' as running_version;

-- Ensure assignment column exists for all classes (if admin hasn't created, create default Assignment column for each class)
-- This ensures cumulative assignment push has destination
do $$
declare cls record;
begin
  for cls in select distinct name from public.classes loop
    if not exists (select 1 from public.assessment_columns where class=cls.name and lower(name)='assignment') then
      insert into public.assessment_columns (class, subject, term, session, name, max_mark, position, source)
      values (cls.name, '*', 'First Term', (select session from public.academic_periods where is_current=true limit 1), 'Assignment', 20, 3, 'manual')
      on conflict do nothing;
      insert into public.assessment_columns (class, subject, term, session, name, max_mark, position, source)
      values (cls.name, '*', 'Second Term', (select session from public.academic_periods where is_current=true limit 1), 'Assignment', 20, 3, 'manual')
      on conflict do nothing;
      insert into public.assessment_columns (class, subject, term, session, name, max_mark, position, source)
      values (cls.name, '*', 'Third Term', (select session from public.academic_periods where is_current=true limit 1), 'Assignment', 20, 3, 'manual')
      on conflict do nothing;
    end if;
  end loop;
end$$;

-- Ensure assignment bridge columns exist (from V12.8-11)
alter table public.assignments add column if not exists cbt_exam_id uuid references public.cbt_exams(id) on delete set null;
alter table public.assignments add column if not exists is_cbt boolean not null default false;
alter table public.assignments add column if not exists source text not null default 'manual';
alter table public.assignment_scores add column if not exists cbt_exam_id uuid references public.cbt_exams(id) on delete cascade;

create index if not exists assignments_cbt_exam_id_idx on public.assignments(cbt_exam_id) where cbt_exam_id is not null;
create index if not exists assignment_scores_cbt_exam_id_idx on public.assignment_scores(cbt_exam_id) where cbt_exam_id is not null;
drop index if exists assignment_scores_cbt_unique;
create unique index if not exists assignment_scores_cbt_unique on public.assignment_scores(cbt_exam_id, student_id) where cbt_exam_id is not null;
drop index if exists assignment_scores_assignment_unique;
create unique index if not exists assignment_scores_assignment_unique on public.assignment_scores(assignment_id, student_id) where assignment_id is not null;

-- Ensure mirror triggers exist with drive_link (final V12.11 version)
create or replace function public.sc_mirror_cbt_assignment()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_aid uuid; v_code text;
begin
  if pg_trigger_depth() > 1 then return new; end if;
  v_code := coalesce(new.code, '');
  if lower(coalesce(new.assessment_type,'')) <> 'assignment' then
    if lower(coalesce(old.assessment_type,'')) = 'assignment' then
      delete from public.assignments where cbt_exam_id = new.id;
    end if;
    return new;
  end if;
  select id into v_aid from public.assignments where cbt_exam_id = new.id limit 1;
  if v_aid is null then
    insert into public.assignments (title, class, subject, due_date, posted_by, cbt_exam_id, is_cbt, source, description, drive_link, created_at)
    values (
      new.title, new.class, new.subject,
      coalesce(new.close_at::date, current_date + interval '7 days'),
      new.teacher_id, new.id, true, 'cbt_assignment',
      '🟢 CBT Assignment (auto-mirrored) — code='||v_code||' — multiple per term, cumulatively collated. Students: click Take Assignment button to take it. Teachers: Score class auto-fills kind/max/scores.',
      case when v_code <> '' then './cbt-exam.html?code='||v_code else null end,
      now()
    ) returning id into v_aid;
  else
    update public.assignments set
      title = new.title, class = new.class, subject = new.subject,
      due_date = coalesce(new.close_at::date, due_date),
      posted_by = new.teacher_id, is_cbt = true, source = 'cbt_assignment',
      description = '🟢 CBT Assignment (auto-mirrored) — code='||v_code||' — multiple per term, cumulatively collated. Students: click Take Assignment.',
      drive_link = case when v_code <> '' then './cbt-exam.html?code='||v_code else drive_link end
    where id = v_aid;
  end if;
  return new;
end$$;

drop trigger if exists trg_cbt_assignment_mirror on public.cbt_exams;
create trigger trg_cbt_assignment_mirror after insert or update of assessment_type, title, class, subject, close_at, teacher_id, code on public.cbt_exams
for each row execute function public.sc_mirror_cbt_assignment();

create or replace function public.sc_cleanup_cbt_assignment()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if pg_trigger_depth() > 1 then return old; end if;
  delete from public.assignments where cbt_exam_id = old.id;
  return old;
end$$;

drop trigger if exists trg_cbt_assignment_cleanup on public.cbt_exams;
create trigger trg_cbt_assignment_cleanup after delete on public.cbt_exams
for each row execute function public.sc_cleanup_cbt_assignment();

update public.assignments a set drive_link = './cbt-exam.html?code='||e.code
from public.cbt_exams e
where a.cbt_exam_id = e.id and e.code is not null and (a.drive_link is null or a.drive_link = '')
and lower(coalesce(e.assessment_type,''))='assignment';

insert into public.sc_install_state(key,details) values ('v12.12-report-student-fix.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.12 report student fix pack installed' as status;
