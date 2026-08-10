-- ============================================================================
-- School Connect V8.4 — Assignment & Digital-Library points → report card
-- ============================================================================
-- 1. assignment_scores — every assignment a subject teacher gives can now be
--    SCORED per student; scores accumulate per subject/term and can be pushed
--    into any report-card column (scaled to the column's max mark).
-- 2. reading_scores upgraded with term/session/admission-no so multiple
--    digital-library quizzes accumulate per term and push the same way.
-- Idempotent — safe to run repeatedly.
-- ============================================================================
create table if not exists public.assignment_scores (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid references public.assignments(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  student_id_ref text,
  student_name text,
  class text, subject text, term text, session text,
  score numeric default 0, max_score numeric default 10,
  recorded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now(),
  unique(assignment_id, student_id)
);
alter table public.assignment_scores enable row level security;
drop policy if exists asg_scores_staff_all on assignment_scores;
create policy asg_scores_staff_all on public.assignment_scores
  for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists asg_scores_self_read on assignment_scores;
create policy asg_scores_self_read on public.assignment_scores
  for select using (exists (select 1 from public.students s
    where s.id = assignment_scores.student_id
      and (s.user_id = auth.uid() or public.is_parent_of(auth.uid(), s.id))));
create index if not exists idx_asg_scores_ctx on public.assignment_scores (class, subject, term, session);

alter table public.reading_scores add column if not exists term text;
alter table public.reading_scores add column if not exists session text;
alter table public.reading_scores add column if not exists student_id_ref text;
create index if not exists idx_reading_scores_ctx on public.reading_scores (class, subject, term, session);

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V8.4 assignment/digital-library points installed' as status;
