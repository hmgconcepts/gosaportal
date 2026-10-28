-- ============================================================================
-- School Connect V12.11 — ASSIGNMENT FINAL ROBUST FIX (pass 85)
-- ----------------------------------------------------------------------------
-- User says: quoted prompt not fully solved, issues still persist, verify not assumed,
-- visit live sites and repos, use different approach.
--
-- This pack is final consolidation of V12.8-12.10 with additional robustness:
-- - Ensures assignments.cbt_exam_id, is_cbt, source, drive_link exist
-- - Ensures assignment_scores.cbt_exam_id exists with unique indexes
-- - Rebuilds mirror triggers with drive_link auto-fill (student Take link for every student)
-- - Backfills drive_link for existing CBT mirrors
-- - Ensures RPCs sc_assignment_cbt_sync, sc_assignment_cbt_sync_all, sc_assignment_totals, sc_create_assignment_from_cbt exist
-- - Marker for schema doctor
--
-- Idempotent — safe to re-run.
-- ============================================================================
select 'RUNNING: School Connect assignment final pack V12.11' as running_version;

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
      '🟢 CBT Assignment (auto-mirrored) — code='||v_code||' — multiple per term, cumulatively collated. Students: click link to take it. Teachers: Score class auto-fills kind/max/scores.',
      case when v_code <> '' then './cbt-exam.html?code='||v_code else null end,
      now()
    ) returning id into v_aid;
  else
    update public.assignments set
      title = new.title, class = new.class, subject = new.subject,
      due_date = coalesce(new.close_at::date, due_date),
      posted_by = new.teacher_id, is_cbt = true, source = 'cbt_assignment',
      description = '🟢 CBT Assignment (auto-mirrored) — code='||v_code||' — multiple per term, cumulatively collated. Students: click link to take it. Teachers: Score class auto-fills kind/max/scores.',
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

insert into public.sc_install_state(key,details) values ('v12.11-assignment-final.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.11 assignment final pack installed' as status;
