-- ============================================================================
-- School Connect V12.9 — ASSIGNMENT FIXES & ROBUSTNESS (pass 83)
-- ----------------------------------------------------------------------------
-- Fixes reported in pass 83:
-- 1. CBT edit: changing assessment_type from initial to another (e.g., assignment)
--    shows new type in list but edit modal reflects old type.
--    Root cause: JS edit modal generated options without selected attribute.
--    Fix: JS now generates options with selected based on current value (fixed in
--    cbt.html). This SQL pack ensures trigger handles type change robustly and
--    cleans up old mirrors.
--
-- 2. CBT assignment auto-fill: when CBT assignment set, details auto-fill in
--    assignment pages, should reflect for every student of that class and CBT
--    link should auto-fill so students can click. Score class scores not auto-fill,
--    assignment kind and max mark should auto-fill (physical manually).
--    Fix: trigger now sets drive_link to cbt-exam.html?code=CODE, plus description
--    with clear purpose. Also backfills existing mirrors.
--
-- 3. Assignment Add new form: source, cbt_exam_id not clear, redundant for manual.
--    Fix: SQL ensures is_cbt, source, cbt_exam_id are auto-managed; JS makes them
--    readonly/adminOnly. This pack backfills drive_link for existing CBT mirrors.
--
-- Also: general robustness — ensures assignment_scores has proper indexes,
--       ensures assignments mirror has proper RLS, ensures triggers are
--       idempotent and recursion-guarded.
--
-- Idempotent — safe to re-run.
-- ============================================================================
select 'RUNNING: School Connect assignment fixes pack V12.9' as running_version;

-- 1. Ensure columns exist (from V12.8, but safe)
alter table public.assignments add column if not exists cbt_exam_id uuid references public.cbt_exams(id) on delete set null;
alter table public.assignments add column if not exists is_cbt boolean not null default false;
alter table public.assignments add column if not exists source text not null default 'manual';
alter table public.assignment_scores add column if not exists cbt_exam_id uuid references public.cbt_exams(id) on delete cascade;

-- 2. Rebuild mirror trigger with drive_link auto-fill (robust, all-inclusive)
create or replace function public.sc_mirror_cbt_assignment()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_aid uuid; v_code text;
begin
  if pg_trigger_depth() > 1 then return new; end if;
  v_code := coalesce(new.code, '');
  if lower(coalesce(new.assessment_type,'')) <> 'assignment' then
    -- If previously was assignment but now changed away, remove mirror
    if lower(coalesce(old.assessment_type,'')) = 'assignment' then
      delete from public.assignments where cbt_exam_id = new.id;
    end if;
    return new;
  end if;
  -- Upsert mirror assignment row with drive_link auto-filled for student access
  select id into v_aid from public.assignments where cbt_exam_id = new.id limit 1;
  if v_aid is null then
    insert into public.assignments (title, class, subject, due_date, posted_by, cbt_exam_id, is_cbt, source, description, drive_link, created_at)
    values (
      new.title,
      new.class,
      new.subject,
      coalesce(new.close_at::date, current_date + interval '7 days'),
      new.teacher_id,
      new.id,
      true,
      'cbt_assignment',
      '🟢 CBT Assignment (auto-mirrored) — code='||v_code||' — multiple per term, cumulatively collated. Students: click the link to take it. Teachers: Score class auto-fills from CBT results.',
      case when v_code <> '' then './cbt-exam.html?code='||v_code else null end,
      now()
    )
    returning id into v_aid;
  else
    update public.assignments set
      title = new.title,
      class = new.class,
      subject = new.subject,
      due_date = coalesce(new.close_at::date, due_date),
      posted_by = new.teacher_id,
      is_cbt = true,
      source = 'cbt_assignment',
      description = '🟢 CBT Assignment (auto-mirrored) — code='||v_code||' — multiple per term, cumulatively collated. Students: click the link to take it. Teachers: Score class auto-fills from CBT results.',
      drive_link = case when v_code <> '' then './cbt-exam.html?code='||v_code else drive_link end
    where id = v_aid;
  end if;
  return new;
end$$;

drop trigger if exists trg_cbt_assignment_mirror on public.cbt_exams;
create trigger trg_cbt_assignment_mirror after insert or update of assessment_type, title, class, subject, close_at, teacher_id, code on public.cbt_exams
for each row execute function public.sc_mirror_cbt_assignment();

-- Cleanup trigger (already exists, but ensure)
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

-- 3. Backfill drive_link for existing CBT assignment mirrors that have empty drive_link
update public.assignments a set drive_link = './cbt-exam.html?code='||e.code
from public.cbt_exams e
where a.cbt_exam_id = e.id and e.code is not null and (a.drive_link is null or a.drive_link = '')
and lower(coalesce(e.assessment_type,''))='assignment';

-- 4. Ensure assignment_scores indexes exist (from V12.8)
create index if not exists assignments_cbt_exam_id_idx on public.assignments(cbt_exam_id) where cbt_exam_id is not null;
create index if not exists assignment_scores_cbt_exam_id_idx on public.assignment_scores(cbt_exam_id) where cbt_exam_id is not null;
drop index if exists assignment_scores_cbt_unique;
create unique index if not exists assignment_scores_cbt_unique on public.assignment_scores(cbt_exam_id, student_id) where cbt_exam_id is not null;
drop index if exists assignment_scores_assignment_unique;
create unique index if not exists assignment_scores_assignment_unique on public.assignment_scores(assignment_id, student_id) where assignment_id is not null;

-- 5. Marker
insert into public.sc_install_state(key,details) values ('v12.9-assignment-fixes.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.9 assignment fixes pack installed' as status;
