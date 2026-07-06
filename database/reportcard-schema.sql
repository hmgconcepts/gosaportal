-- =====================================================================
-- School Connect — Report Card Schema (FLEXIBLE) — Gen v2
-- =====================================================================
-- A fully flexible report-card engine. Teachers/admins:
--   1. define ANY assessment columns per class/subject (e.g. CA1, CA2,
--      Assignment, Project, Practical, Exam) and apportion a MAX MARK to each,
--   2. enter scores per student per column,
--   3. and CBT/online results auto-map into the matching column.
-- Totals, grades and positions are computed from the columns + their weights.
--
-- ORDERING RULE (prevents 42P01): tables → helper → policies.
-- Self-contained & idempotent. Run AFTER database/schema.sql (recommended)
-- so it can reference students; works standalone too.
-- =====================================================================

create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- minimal deps (no-op if main schema already ran)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text, full_name text, phone text,
  role text not null default 'student',
  status text not null default 'pending',
  photo_url text, campus text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

create table if not exists public.students (
  id uuid primary key default uuid_generate_v4(),
  admission_no text unique,
  full_name text not null,
  class text, arm text,
  guardian_email text,
  created_at timestamptz default now()
);
alter table public.students enable row level security;
alter table public.students add column if not exists user_id uuid references public.profiles(id) on delete set null;
create index if not exists students_user_id_idx on public.students(user_id);

-- =====================================================================
-- 1. TABLES
-- =====================================================================

-- 1a. Assessment columns — the customisable structure of a report.
-- A teacher creates, for a given class+subject+term+session, a set of columns
-- such as: CA1 (max 10), CA2 (max 10), Assignment (max 5), Project (max 15),
-- Exam (max 60). The "source" tells the system whether the column is filled
-- manually or pulled from CBT.
create table if not exists public.assessment_columns (
  id uuid primary key default uuid_generate_v4(),
  class text not null,
  subject text not null,
  term text not null default '',
  session text not null default '',
  name text not null,                 -- e.g. 'CA1', 'Project', 'Exam'
  max_mark numeric not null default 10,
  weight numeric not null default 1,  -- relative weight when scaling (usually 1)
  position int not null default 0,    -- display order
  source text not null default 'manual' check (source in ('manual','cbt')),
  cbt_assessment_type text default '',-- if source='cbt': which assessment_type maps here
  created_by uuid references public.profiles(id),
  created_at timestamptz default now(),
  unique(class, subject, term, session, name)
);
alter table public.assessment_columns enable row level security;

-- 1b. Per-student score for one column.
create table if not exists public.report_scores (
  id uuid primary key default uuid_generate_v4(),
  column_id uuid not null references public.assessment_columns(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  student_name text not null default '',
  student_id_ref text default '',     -- admission_no, for CBT matching
  class text default '',
  subject text default '',
  term text default '',
  session text default '',
  score numeric not null default 0,
  source text default 'manual',
  cert_code text default '',          -- if pulled from a CBT result
  updated_by uuid references public.profiles(id),
  updated_at timestamptz default now(),
  created_at timestamptz default now(),
  unique(column_id, student_id_ref, student_name)
);
alter table public.report_scores enable row level security;
create index if not exists report_scores_lookup_idx
  on public.report_scores (class, subject, term, session);

-- 1c. Per-student per-term report meta (comments, traits, attendance).
create table if not exists public.report_cards (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  student_name text default '',
  student_id_ref text default '',
  class text, term text, session text,
  teacher_comment text default '',
  head_comment text default '',
  attendance_present int default 0,
  attendance_total int default 0,
  affective jsonb default '{}'::jsonb,   -- {punctuality:5, neatness:4, ...}
  psychomotor jsonb default '{}'::jsonb,
  next_term_begins date,
  position int,
  published boolean default false,
  created_at timestamptz default now(),
  unique(student_id_ref, class, term, session)
);
alter table public.report_cards enable row level security;

-- =====================================================================
-- 2. HELPER (no-op if main schema already made it)
-- =====================================================================

-- ENTERPRISE V4 REPORTCARD PARENT_CHILD: standalone reportcard schema privacy dependency
create table if not exists public.parent_child (
  id uuid primary key default uuid_generate_v4(),
  parent_id uuid references public.profiles(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  relationship text default 'parent',
  verified boolean default false,
  created_at timestamptz default now(),
  unique(parent_id, student_id)
);
alter table public.parent_child enable row level security;

create or replace function public.is_parent_of(uid uuid, child uuid)
returns boolean language sql security definer stable as $$
  select exists (select 1 from public.parent_child where parent_id=uid and student_id=child);
$$;

create or replace function public.is_staff(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','principal','proprietor','head_teacher','staff','teacher','bursar')
      and status in ('approved','active')
  );
$$;

-- =====================================================================
-- 3. THE INTERCONNECTION FUNCTION
--    Called by the CBT engine after a submission. It finds (or creates) the
--    matching report column for the subject/term/session, scales the CBT
--    score to that column's max_mark, and upserts the student's score.
-- =====================================================================
create or replace function public.cbt_push_to_reportcard(
  p_student_name   text,
  p_student_id_ref text,
  p_class          text,
  p_subject        text,
  p_term           text,
  p_session        text,
  p_column         text,
  p_raw_score      numeric,
  p_raw_total      numeric,
  p_max_score      numeric
) returns jsonb language plpgsql security definer as $$
declare
  v_col public.assessment_columns;
  v_max numeric;
  v_scaled numeric;
begin
  if coalesce(p_column,'') = '' then
    return jsonb_build_object('mapped', false, 'reason', 'no report_column set on exam');
  end if;

  -- find or create the column
  select * into v_col from public.assessment_columns
   where class = p_class and subject = p_subject
     and term = coalesce(p_term,'') and session = coalesce(p_session,'')
     and name = p_column
   limit 1;

  if not found then
    v_max := case when coalesce(p_max_score,0) > 0 then p_max_score
                  when coalesce(p_raw_total,0) > 0 then p_raw_total
                  else 100 end;
    insert into public.assessment_columns (class, subject, term, session, name, max_mark, source, cbt_assessment_type)
    values (p_class, p_subject, coalesce(p_term,''), coalesce(p_session,''), p_column, v_max, 'cbt', '')
    returning * into v_col;
  end if;

  v_max := coalesce(v_col.max_mark, 100);
  -- scale the raw CBT score onto the column's max mark
  if coalesce(p_raw_total,0) > 0 then
    v_scaled := round((p_raw_score / p_raw_total) * v_max, 2);
  else
    v_scaled := least(p_raw_score, v_max);
  end if;

  insert into public.report_scores (
    column_id, student_name, student_id_ref, class, subject, term, session, score, source
  ) values (
    v_col.id, p_student_name, coalesce(p_student_id_ref,''), p_class, p_subject,
    coalesce(p_term,''), coalesce(p_session,''), v_scaled, 'cbt'
  )
  on conflict (column_id, student_id_ref, student_name)
  do update set score = excluded.score, source = 'cbt', updated_at = now();

  return jsonb_build_object('mapped', true, 'column', v_col.name, 'scaled', v_scaled, 'max', v_max);
end; $$;

-- A convenience view: each student's subject total across all columns.
-- Drop first so re-runs never hit 42P16 "cannot drop columns from view".
drop view if exists public.report_subject_totals cascade;
create or replace view public.report_subject_totals as
select rs.class, rs.subject, rs.term, rs.session,
       rs.student_id_ref, rs.student_name,
       round(sum(rs.score), 2) as obtained,
       round(sum(ac.max_mark), 2) as obtainable,
       case when sum(ac.max_mark) > 0
            then round(sum(rs.score) / sum(ac.max_mark) * 100, 2) else 0 end as percent
from public.report_scores rs
join public.assessment_columns ac on ac.id = rs.column_id
group by rs.class, rs.subject, rs.term, rs.session, rs.student_id_ref, rs.student_name;

-- =====================================================================
-- 4. RLS POLICIES
-- =====================================================================
drop policy if exists "ac_staff" on public.assessment_columns;
drop policy if exists "ac_read"  on public.assessment_columns;
create policy "ac_staff" on public.assessment_columns for all using (public.is_staff(auth.uid()));
create policy "ac_read"  on public.assessment_columns for select using (auth.role() = 'authenticated');

drop policy if exists "rs_staff" on public.report_scores;
drop policy if exists "rs_read"  on public.report_scores;
create policy "rs_staff" on public.report_scores for all using (public.is_staff(auth.uid()));
-- students/parents may read; the parent-scoping in the main schema's
-- parent_child still governs deeper access patterns at the app layer.
create policy "rs_read"  on public.report_scores for select using (auth.role() = 'authenticated');

drop policy if exists "rc_staff" on public.report_cards;
drop policy if exists "rc_read"  on public.report_cards;
create policy "rc_staff" on public.report_cards for all using (public.is_staff(auth.uid()));
create policy "rc_read" on public.report_cards for select using (public.is_staff(auth.uid()) or student_id in (select id from public.students where user_id=auth.uid()) or public.is_parent_of(auth.uid(), student_id));

-- the mapping function is called by the (security-definer) cbt_submit flow and
-- by staff; expose it to authenticated callers.
grant execute on function public.cbt_push_to_reportcard(text,text,text,text,text,text,text,numeric,numeric,numeric) to authenticated, anon;

-- =====================================================================
-- DONE ✅  Flexible report cards installed and wired to the CBT engine.
-- =====================================================================
select 'School Connect Report-Card schema v2 installed ✅' as status;

-- =====================================================================
-- ENTERPRISE V10 FAMILY-SAFE REPORT CARD POLICIES (2026-07-06)
-- Parents/students may SELECT only their own/linked report scores; staff write.
-- =====================================================================
drop policy if exists "rs_read" on public.report_scores;
drop policy if exists "rs_select_family" on public.report_scores;
create policy "rs_select_family" on public.report_scores for select using (
  public.is_staff(auth.uid())
  or exists (
    select 1 from public.students s
    where (s.id = report_scores.student_id
       or lower(s.full_name) = lower(report_scores.student_name)
       or s.admission_no = report_scores.student_id_ref)
      and (s.user_id = auth.uid() or public.is_parent_of(auth.uid(), s.id))
  )
);

-- Make the aggregate view obey underlying table RLS in modern PostgreSQL/Supabase.
do $$ begin
  execute 'alter view public.report_subject_totals set (security_invoker = true)';
exception when others then
  raise notice 'security_invoker not supported on this Postgres version; rely on app filtering + table RLS.';
end $$;
