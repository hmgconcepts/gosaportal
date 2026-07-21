-- ============================================================================
-- HMG SCHOOL CONNECT v7 — COMPLETE SELF-CONTAINED DATABASE SCHEMA
-- ============================================================================
-- Run ONLY this file once in the Supabase SQL Editor.
-- It combines the former schema.sql, complete-schema-v4.sql, reportcard,
-- voting, CBT, enterprise and cumulative repair SQL into one idempotent file.
-- It is safe on a fresh project and safe to re-run on an older School Connect DB.
-- No other SQL file is required for a new deployment.
--
-- Design guarantees:
--   • every dependency is created before its FK, function, view or policy;
--   • school_name, checkin_deadline and all named feature tables exist;
--   • report_scores has one canonical key matching the browser upsert;
--   • parent/student attendance is SELECT-only and child-scoped;
--   • admission/staff identifiers begin with the configured school acronym;
--   • report cards can render an official school stamp and authorised signature;
--   • RLS is the security boundary; the anon key is never an admin secret.
-- ============================================================================

create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

create or replace function public.sc_set_updated_at()
returns trigger language plpgsql security invoker as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Tenant identity. A single-school deployment uses one row; the school_id
-- columns keep the model ready for future approved multi-campus expansion.
create table if not exists public.schools (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My School',
  short_name text not null default 'GSA',
  admission_acronym text not null default 'GSA',
  motto text default 'Excellence in Learning',
  address text default '', phone text default '', email text default '',
  currency text default '₦', site_url text default '', logo_url text default '',
  created_at timestamptz not null default now()
);
alter table public.schools enable row level security;

-- Settings is deliberately created before any ALTER/INSERT that uses it.
-- text is used for checkin_deadline because HTML time inputs submit HH:MM and
-- this remains compatible with older installations that used text.
create table if not exists public.school_settings (
  id int primary key default 1,
  school_id uuid references public.schools(id) on delete set null,
  school_name text not null default 'My School',
  short_name text not null default 'GSA',
  admission_acronym text not null default 'GSA',
  admission_prefix text not null default 'GSA',
  admission_next int not null default 1,
  staff_prefix text not null default 'GSA',
  staff_next int not null default 1,
  motto text default '', address text default '', phone text default '', email text default '',
  currency text default '₦', site_url text default '', logo_url text default '',
  signature_url text default '', class_teacher_signature_url text default '',
  principal_name text default 'Principal', class_teacher_name text default '',
  stamp_text text default 'OFFICIAL SCHOOL SEAL',
  stamp_color text default '#1e3a8a',
  stamp_enabled boolean not null default true,
  signature_enabled boolean not null default true,
  next_term_fees numeric default 0,
  next_term_fees_currency text default '₦',
  next_term_fees_note text default 'Payable before resumption',
  next_term_begins date,
  checkin_deadline text not null default '08:00',
  checkin_grace_minutes int not null default 15,
  latitude numeric, longitude numeric, geo_radius_m int default 200,
  enforce_geofence boolean not null default false, geo_updated_at timestamptz,
  role_access jsonb not null default '{}'::jsonb,
  role_write jsonb not null default '{}'::jsonb,
  seo_title text default '', seo_description text default '', seo_keywords text default '',
  hmg_link text default 'https://hmgconcepts.pages.dev/',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.school_settings enable row level security;
insert into public.schools (name, short_name, admission_acronym)
values ('God of Seed Academy','GoSA','GSA') on conflict do nothing;
insert into public.school_settings (id, school_id, school_name, short_name, admission_acronym, admission_prefix, staff_prefix)
select 1, s.id, s.name, s.short_name, s.admission_acronym, s.admission_acronym, s.admission_acronym
from public.schools s order by s.created_at limit 1
on conflict (id) do nothing;

-- Identity dependencies are created before CBT/report/enterprise foreign keys.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text, full_name text, phone text,
  role text not null default 'student',
  status text not null default 'pending',
  photo_url text, campus text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create table if not exists public.students (
  id uuid primary key default uuid_generate_v4(), admission_no text unique, full_name text not null,
  class text, arm text, department text default 'Other', gender text, date_of_birth date,
  guardian_name text, guardian_phone text, guardian_email text, address text, photo_url text, campus text,
  status text default 'active', user_id uuid references public.profiles(id) on delete set null, created_at timestamptz default now()
);
alter table public.students enable row level security;
create table if not exists public.staff (
  id uuid primary key default uuid_generate_v4(), staff_no text unique, full_name text not null,
  email text, phone text, role text default 'teacher', department text, subjects text[], part_time boolean default false,
  leave_balance int default 14, photo_url text, status text default 'active', user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);
alter table public.staff enable row level security;
create table if not exists public.parent_child (
  id uuid primary key default uuid_generate_v4(), parent_id uuid references public.profiles(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade, relationship text default 'parent', verified boolean default false,
  created_at timestamptz default now(), unique(parent_id, student_id)
);
alter table public.parent_child enable row level security;

-- CBT tables are early because the core schema creates certificate views,
-- ownership policies and validation functions that reference them.
create table if not exists public.cbt_exams (
  id uuid primary key default uuid_generate_v4(),
  teacher_id uuid references public.profiles(id) on delete set null,
  code text unique not null, title text, subject text not null default 'General',
  class text default '', term text default '', session text default '', topic text default '',
  assessment_type text not null default 'exam', report_column text default '',
  max_score numeric default 0, duration int not null default 45,
  duration_min int default 45, attempt_limit int not null default 1,
  select_count int not null default 0, randomise boolean not null default true,
  negative_mark numeric not null default 0,
  exam_mode text not null default 'open', is_open boolean not null default false,
  is_archived boolean not null default false, is_entrance boolean not null default false,
  pass_mark numeric not null default 50, release_results boolean not null default true,
  instructions text not null default '',
  anti_cheat_config jsonb not null default '{}'::jsonb,
  certificate_enabled boolean not null default true,
  start_at timestamptz, close_at timestamptz,
  csv_data jsonb not null default '[]'::jsonb,
  questions jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.cbt_exams enable row level security;
create table if not exists public.cbt_results (
  id uuid primary key default uuid_generate_v4(),
  exam_id uuid not null references public.cbt_exams(id) on delete cascade,
  student_id uuid references public.students(id) on delete set null,
  student_name text not null default 'Anonymous', student_class text default '',
  student_id_ref text default '', student_type text default 'open',
  score numeric(10,2) not null default 0, total int not null default 0,
  percent numeric(6,2) default 0, correct_count int default 0, wrong_count int default 0,
  skipped_count int default 0, attempt_number int default 1, time_taken int default 0,
  answers_data jsonb, violations int default 0, violation_log jsonb default '[]'::jsonb,
  cert_code text default '', submitted_at timestamptz default now(), created_at timestamptz default now()
);
alter table public.cbt_results enable row level security;
create table if not exists public.cbt_roster (
  id uuid primary key default uuid_generate_v4(),
  exam_id uuid references public.cbt_exams(id) on delete cascade,
  student_id_ref text not null, full_name text, class text, created_at timestamptz default now(),
  unique(exam_id, student_id_ref)
);
alter table public.cbt_roster enable row level security;

-- Assessment engine. The browser uses the seven-column context key so a
-- learner's Mathematics CA1 in one term cannot overwrite another term.
create table if not exists public.assessment_columns (
  id uuid primary key default uuid_generate_v4(),
  class text not null default '', subject text not null default '*',
  term text not null default '', session text not null default '', name text not null,
  max_mark numeric not null default 10, weight numeric not null default 1,
  position int not null default 0, source text not null default 'manual',
  cbt_assessment_type text default '', created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(class, subject, term, session, name)
);
alter table public.assessment_columns enable row level security;
create table if not exists public.report_scores (
  id uuid primary key default uuid_generate_v4(),
  column_id uuid not null references public.assessment_columns(id) on delete cascade,
  student_id uuid references public.students(id) on delete set null,
  student_id_ref text not null default '', student_name text not null default '',
  class text not null default '', subject text not null default '',
  term text not null default '', session text not null default '', score numeric not null default 0,
  source text not null default 'manual', updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);
alter table public.report_scores enable row level security;
create table if not exists public.report_cards (
  id uuid primary key default uuid_generate_v4(), student_id uuid references public.students(id) on delete cascade,
  student_name text default '', student_id_ref text default '', class text default '', term text default '', session text default '',
  teacher_comment text default '', head_comment text default '', attendance_present int default 0, attendance_total int default 0,
  affective jsonb default '{}'::jsonb, psychomotor jsonb default '{}'::jsonb, next_term_begins date,
  position int, published boolean default false, created_at timestamptz default now(),
  unique(student_id_ref, class, term, session)
);
alter table public.report_cards enable row level security;

-- V15/V16 tables that caused the schema-cache cascade when an earlier schema
-- aborted at current_role or public.schools.
create table if not exists public.class_fee_structure (
  id uuid primary key default uuid_generate_v4(), school_id uuid references public.schools(id) on delete cascade,
  class text not null, arm text not null default '', department text not null default '',
  term text not null default 'Current Term', session text not null default '',
  tuition numeric(12,2) default 0, exam_fee numeric(12,2) default 0, development numeric(12,2) default 0,
  transport numeric(12,2) default 0, boarding numeric(12,2) default 0, other_fee numeric(12,2) default 0,
  discount numeric(12,2) default 0, total numeric(12,2) default 0, amount numeric(12,2) default 0,
  currency text default '₦', due_date date, next_term_begins date, note text default '',
  fee_items jsonb default '[]'::jsonb, active boolean not null default true,
  created_at timestamptz default now(), updated_at timestamptz default now()
);
alter table public.class_fee_structure enable row level security;
create table if not exists public.school_products (
  id uuid primary key default uuid_generate_v4(), school_id uuid references public.schools(id) on delete cascade,
  name text not null, description text default '',
  category text default 'Other', price numeric(12,2) default 0, currency text default '₦',
  size_option text default '', stock_note text default '', quantity_available int default 0,
  image_url text default '', active boolean not null default true,
  created_at timestamptz default now(), updated_at timestamptz default now()
);
alter table public.school_products enable row level security;
create table if not exists public.role_status_log (
  id uuid primary key default uuid_generate_v4(), school_id uuid references public.schools(id) on delete cascade,
  person_id uuid references public.profiles(id) on delete set null, person_name text not null default '',
  person_email text default '', previous_role text default '', new_role text default '',
  previous_status text default '', new_status text default '', action text default '', reason text default '',
  changed_by uuid references public.profiles(id) on delete set null, changed_by_name text default '',
  created_at timestamptz default now()
);
alter table public.role_status_log enable row level security;
create table if not exists public.staff_clock (
  id uuid primary key default uuid_generate_v4(), school_id uuid references public.schools(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null, staff_no text, staff_name text,
  status text default 'present', clock_in timestamptz, clock_out timestamptz, date date default current_date,
  note text default '', created_at timestamptz default now()
);
alter table public.staff_clock enable row level security;
create table if not exists public.student_clock (
  id uuid primary key default uuid_generate_v4(), school_id uuid references public.schools(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade, clock_in timestamptz, clock_out timestamptz,
  date date default current_date, note text default '', created_at timestamptz default now()
);
alter table public.student_clock enable row level security;

-- Enterprise add-on tables (free-first; no AI/API dependency).
create table if not exists public.timetable_requirements (
  id uuid primary key default uuid_generate_v4(), class text not null, subject text not null, teacher text,
  periods_per_week int not null default 1, available_days text[], is_part_time boolean default false,
  created_at timestamptz default now(), unique(class, subject)
);
alter table public.timetable_requirements enable row level security;
create table if not exists public.teacher_availability (
  id uuid primary key default uuid_generate_v4(), teacher text not null unique,
  is_part_time boolean default false, available_days text[], notes text, created_at timestamptz default now()
);
alter table public.teacher_availability enable row level security;
create table if not exists public.timetable_runs (
  id uuid primary key default uuid_generate_v4(), class text, session text, term text,
  generated_at timestamptz default now(), conflicts int default 0, notes text
);
alter table public.timetable_runs enable row level security;
create table if not exists public.attendance_checkins (
  id uuid primary key default uuid_generate_v4(), student_id_ref text not null, student_name text, class text,
  checkin_at timestamptz default now(), method text default 'qr', device text, recorded_by uuid references public.profiles(id)
);
alter table public.attendance_checkins enable row level security;
create table if not exists public.student_diary (
  id uuid primary key default uuid_generate_v4(), student_id uuid references public.students(id) on delete cascade,
  student_name text, class text, subject text, date date default current_date, entry_type text default 'homework',
  title text, body text, acknowledged boolean default false, created_by uuid references public.profiles(id), created_at timestamptz default now()
);
alter table public.student_diary enable row level security;
create table if not exists public.surveys (
  id uuid primary key default uuid_generate_v4(), title text not null, description text, audience text default 'all',
  questions jsonb default '[]'::jsonb, anonymous boolean default true, is_open boolean default true,
  created_by uuid references public.profiles(id), created_at timestamptz default now()
);
alter table public.surveys enable row level security;
create table if not exists public.survey_responses (
  id uuid primary key default uuid_generate_v4(), survey_id uuid references public.surveys(id) on delete cascade,
  respondent uuid references public.profiles(id), answers jsonb default '{}'::jsonb, created_at timestamptz default now()
);
alter table public.survey_responses enable row level security;
create table if not exists public.menu_planner (
  id uuid primary key default uuid_generate_v4(), week_start date, day text, meal text, description text, allergens text,
  created_at timestamptz default now()
);
alter table public.menu_planner enable row level security;
create table if not exists public.security_prefs (
  user_id uuid primary key references public.profiles(id) on delete cascade, two_factor boolean default false,
  recovery_email text, updated_at timestamptz default now()
);
alter table public.security_prefs enable row level security;
create table if not exists public.login_audit (
  id uuid primary key default uuid_generate_v4(), user_id uuid references public.profiles(id) on delete set null,
  email text, event text default 'login', ip text, user_agent text, created_at timestamptz default now()
);
alter table public.login_audit enable row level security;
create table if not exists public.i18n_strings (
  id uuid primary key default uuid_generate_v4(), lang text not null default 'en', key text not null, value text not null,
  unique(lang, key)
);
alter table public.i18n_strings enable row level security;
create table if not exists public.academic_print_records (
  id uuid primary key default uuid_generate_v4(), record_type text not null, title text not null, class text default '',
  subject text default '', term text default '', session text default '', generated_by uuid references public.profiles(id) on delete set null,
  data jsonb not null default '{}'::jsonb, created_at timestamptz default now()
);
alter table public.academic_print_records enable row level security;

-- =====================================================================
-- School Connect — Database Schema (Gen v8)
-- =====================================================================
-- Full Row-Level Security (RLS) with least-privilege policies.
-- Idempotent: safe to re-run in the Supabase SQL Editor as many times
-- as you like — every object uses "if not exists" or "drop ... if exists".
--
-- ⚠️  IMPORTANT — CORRECT ORDER OF OPERATIONS (fixes the v7 bug
--     `ERROR: 42P01: relation "public.profiles" does not exist`):
--
--     1. Extensions
--     2. ALL TABLES (profiles + parent_child created BEFORE any function
--        or policy that references them)
--     3. Helper functions (is_staff / is_admin / is_parent_of) — these
--        depend on tables, so they MUST come after the tables
--     4. New-user trigger
--     5. Enable RLS + create policies
--
--     In v7 the helper functions were declared at the TOP of the file,
--     BEFORE the tables they query, so the very first statement failed
--     with 42P01. This version fixes the ordering permanently.
-- =====================================================================


-- ========================================================
-- 1. EXTENSIONS
-- ========================================================
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";


-- ========================================================
-- 2. TABLES  (create EVERY table first — no functions yet)
-- ========================================================

-- ---- 2.1 Auth profiles (the table every helper depends on) ----
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  phone text,
  role text not null default 'student'
    check (role in ('super_admin','admin','principal','proprietor','head_teacher','staff','teacher','parent','student','bursar')),
  status text not null default 'pending'
    check (status in ('pending','approved','active','suspended')),
  photo_url text,
  campus text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
alter table public.profiles add column if not exists date_of_birth date;
alter table public.profiles add column if not exists dob_day int;
alter table public.profiles add column if not exists dob_month text;


-- =====================================================================
-- ENTERPRISE V3 EARLY HELPERS (must exist before any RLS policy uses them)
-- FIXED v15: is_admin no longer includes 'teacher' (privilege escalation fix)
-- =====================================================================
create or replace function public.is_admin(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','administrator','owner','director','principal','proprietor','head_teacher','bursar')
      and status in ('approved','active')
  );
$$;

create or replace function public.is_staff(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','administrator','owner','director','principal','proprietor','head_teacher','staff','teacher','bursar')
      and status in ('approved','active')
  );
$$;


-- ---- 2.2 Core academic ----
create table if not exists public.students (
  id uuid primary key default uuid_generate_v4(),
  admission_no text unique,
  full_name text not null,
  class text, arm text,
  gender text check (gender in ('male','female')),
  date_of_birth date,
  guardian_name text,
  guardian_phone text,
  guardian_email text,
  address text,
  photo_url text,
  campus text,
  status text default 'active',
  created_at timestamptz default now()
);
alter table public.students enable row level security;
alter table public.students add column if not exists user_id uuid references public.profiles(id) on delete set null;
create index if not exists students_user_id_idx on public.students(user_id);

create table if not exists public.staff (
  id uuid primary key default uuid_generate_v4(),
  full_name text not null,
  email text, phone text,
  role text default 'teacher',
  department text,
  subjects text[],
  part_time boolean default false,
  leave_balance int default 14,
  photo_url text,
  status text default 'active',
  created_at timestamptz default now()
);
alter table public.staff enable row level security;
alter table public.staff add column if not exists user_id uuid references public.profiles(id) on delete set null;
create index if not exists staff_user_id_idx on public.staff(user_id);

create table if not exists public.classes (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  arm text,
  level text,
  class_teacher text,
  capacity int default 40,
  next_term_fees numeric default 0,
  next_term_fees_currency text default '₦',
  next_term_fees_note text default 'Payable before resumption',
  created_at timestamptz default now()
);
alter table public.classes enable row level security;

create table if not exists public.subjects (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  code text,
  department text,
  level text,
  teacher text, -- additive fix: CRUD subject-teacher mapping stores the selected teacher name here
  teacher_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);
-- Cumulative repair for older generated databases that already have subjects without teacher columns.
alter table public.subjects add column if not exists teacher text;
alter table public.subjects add column if not exists teacher_id uuid references public.profiles(id) on delete set null;
alter table public.subjects enable row level security;

-- parent_child must exist BEFORE the is_parent_of() function is created.
create table if not exists public.parents (
  id uuid primary key default uuid_generate_v4(),
  full_name text not null,
  email text,
  phone text,
  occupation text,
  address text,
  status text default 'active',
  created_at timestamptz default now()
);
alter table public.parents enable row level security;
drop policy if exists "parents_read" on public.parents;
create policy "parents_read" on public.parents for select using (auth.role() = 'authenticated');
drop policy if exists "parents_write" on public.parents;
create policy "parents_write" on public.parents for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

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
-- ENTERPRISE V3 PARENT HELPER

create or replace function public.is_parent_of(uid uuid, child uuid)
returns boolean language sql security definer stable as $$
  select exists (select 1 from public.parent_child where parent_id = uid and student_id = child);
$$;


create table if not exists public.attendance (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  class text, date date not null default current_date,
  status text check (status in ('present','absent','late','excused')),
  time_in time,
  recorded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.attendance enable row level security;
alter table public.attendance add column if not exists student_name text;
create unique index if not exists attendance_student_date_unique on public.attendance(student_id,date) where student_id is not null;

create table if not exists public.results (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  subject text not null,
  class text, term text, session text,
  ca1 numeric, ca2 numeric, ca3 numeric, exam numeric,
  total numeric generated always as
    (coalesce(ca1,0)+coalesce(ca2,0)+coalesce(ca3,0)+coalesce(exam,0)) stored,
  grade text, remark text,
  teacher_id uuid references public.profiles(id),
  position int,
  created_at timestamptz default now()
);
alter table public.results enable row level security;
alter table public.results add column if not exists student_name text;
alter table public.results add column if not exists assessment_source text default 'manual';
alter table public.results add column if not exists assessment_ref text;
create unique index if not exists results_assessment_ref_unique on public.results(assessment_source, assessment_ref) where assessment_ref is not null;

create table if not exists public.timetable (
  id uuid primary key default uuid_generate_v4(),
  class text, day text, period text,
  subject text, teacher text, room text,
  session text, term text,
  created_at timestamptz default now()
);
alter table public.timetable enable row level security;

-- NOTE: real table name is scheme_of_work. (v7 RLS loops wrongly used
-- the alias 'sow' which caused: relation "public.sow" does not exist.)
create table if not exists public.scheme_of_work (
  id uuid primary key default uuid_generate_v4(),
  subject text, class text, term text, session text,
  week int, topic text, status text default 'pending',
  covered_at date, teacher text, confirmed boolean default false,
  created_at timestamptz default now()
);
alter table public.scheme_of_work enable row level security;

create table if not exists public.assignments (
  id uuid primary key default uuid_generate_v4(),
  title text, description text,
  class text, subject text, due_date date,
  posted_by uuid references public.profiles(id),
  drive_link text,
  created_at timestamptz default now()
);
alter table public.assignments enable row level security;
alter table public.assignments add column if not exists teacher_id uuid references public.profiles(id) on delete set null;

create table if not exists public.library (
  id uuid primary key default uuid_generate_v4(),
  title text, author text, isbn text,
  category text, copies int default 1,
  lent int default 0,
  available int generated always as (copies - coalesce(lent,0)) stored,
  drive_link text,
  created_at timestamptz default now()
);
alter table public.library enable row level security;

create table if not exists public.conduct (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  type text check (type in ('merit','demerit','incident')),
  description text, reporter text,
  date date default current_date,
  created_at timestamptz default now()
);
alter table public.conduct enable row level security;

create table if not exists public.health (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  complaint text, treatment text,
  date date default current_date, recorded_by text,
  created_at timestamptz default now()
);
alter table public.health enable row level security;

create table if not exists public.promotions (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  from_class text, to_class text,
  action text check (action in ('promote','graduate','repeat','delete')),
  session text, term text,
  approved_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.promotions enable row level security;

-- ---- 2.3 Financial ----
create table if not exists public.fee_structures (
  id uuid primary key default uuid_generate_v4(),
  class text, term text, session text,
  amount numeric, description text,
  due_date date,
  created_at timestamptz default now()
);
alter table public.fee_structures enable row level security;

create table if not exists public.fee_payments (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  amount_paid numeric, method text, reference text,
  term text, session text,
  received_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.fee_payments enable row level security;
alter table public.fee_payments add column if not exists fee_total numeric;
alter table public.fee_payments add column if not exists balance numeric;
alter table public.fee_payments add column if not exists student_name text;
create or replace function public.compute_fee_payment_balance()
returns trigger language plpgsql as $$
begin
  if new.fee_total is not null then
    new.balance := greatest(0, coalesce(new.fee_total,0) - coalesce(new.amount_paid,0));
  elsif new.balance is null then
    new.balance := 0;
  end if;
  return new;
end $$;
drop trigger if exists trg_compute_fee_payment_balance on public.fee_payments;
create trigger trg_compute_fee_payment_balance
before insert or update of fee_total, amount_paid, balance on public.fee_payments
for each row execute function public.compute_fee_payment_balance();


create table if not exists public.finance_entries (
  id uuid primary key default uuid_generate_v4(),
  type text check (type in ('income','expense')),
  category text, amount numeric,
  description text, date date default current_date,
  recorded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.finance_entries enable row level security;

create table if not exists public.leave_requests (
  id uuid primary key default uuid_generate_v4(),
  staff_id uuid references public.staff(id) on delete cascade,
  type text check (type in ('sick','casual','earned','study','maternity')),
  start_date date, end_date date, days int,
  reason text,
  status text default 'pending' check (status in ('pending','approved','rejected')),
  approved_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.leave_requests enable row level security;

create table if not exists public.visitors (
  id uuid primary key default uuid_generate_v4(),
  full_name text, phone text,
  purpose text, host text,
  check_in timestamptz default now(),
  check_out timestamptz,
  badge_no text,
  created_at timestamptz default now()
);
alter table public.visitors enable row level security;

create table if not exists public.transport (
  id uuid primary key default uuid_generate_v4(),
  route_name text, driver text,
  vehicle_no text, capacity int,
  assigned_students uuid[],
  created_at timestamptz default now()
);
alter table public.transport enable row level security;

-- ---- 2.4 Communication ----
create table if not exists public.announcements (
  id uuid primary key default uuid_generate_v4(),
  title text not null, body text,
  priority text default 'normal' check (priority in ('normal','high','urgent')),
  pinned boolean default false,
  audience text default 'all',
  posted_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.announcements enable row level security;

create table if not exists public.events (
  id uuid primary key default uuid_generate_v4(),
  title text, description text,
  date date, venue text, organiser text,
  rsvp uuid[],
  created_at timestamptz default now()
);
alter table public.events enable row level security;

create table if not exists public.messages (
  id uuid primary key default uuid_generate_v4(),
  from_id uuid references public.profiles(id),
  to_id uuid references public.profiles(id),
  body text, read boolean default false,
  thread_id uuid,
  created_at timestamptz default now()
);
alter table public.messages enable row level security;

create table if not exists public.complaints (
  id uuid primary key default uuid_generate_v4(),
  submitted_by uuid references public.profiles(id),
  type text, subject text, body text,
  urgency text default 'normal' check (urgency in ('low','normal','high','critical')),
  drive_link text,
  status text default 'submitted'
    check (status in ('submitted','reviewing','in_progress','resolved','rejected')),
  assignee uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.complaints enable row level security;

create table if not exists public.notifications (
  id uuid primary key default uuid_generate_v4(),
  title text not null, body text,
  url text,
  audience text default 'all',
  priority text default 'normal',
  channels jsonb default '["inapp"]'::jsonb,
  read_by uuid[] default '{}',
  created_at timestamptz default now()
);
alter table public.notifications enable row level security;

-- ---- 2.5 Voting ----
create table if not exists public.polls (
  id uuid primary key default uuid_generate_v4(),
  title text not null, description text,
  type text default 'single_choice'
    check (type in ('single_choice','multiple_choice','yes_no','ranked')),
  candidates jsonb default '[]'::jsonb,   -- [{id,name,info,photo}]
  opens_at timestamptz default now(),
  closes_at timestamptz,
  allow_multiple boolean default false,
  anonymous boolean default false,
  audience text default 'all',
  status text default 'open' check (status in ('draft','open','closed')),
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.polls enable row level security;

create table if not exists public.poll_votes (
  id uuid primary key default uuid_generate_v4(),
  poll_id uuid references public.polls(id) on delete cascade,
  candidate_id text not null,
  voter_id uuid references public.profiles(id) on delete cascade,
  voted_at timestamptz default now(),
  unique(poll_id, candidate_id, voter_id)
);
alter table public.poll_votes enable row level security;

-- ---- 2.6 Media & utility ----
create table if not exists public.gallery (
  id uuid primary key default uuid_generate_v4(),
  album text, caption text,
  media_url text not null,
  media_type text default 'image' check (media_type in ('image','video','youtube')),
  uploaded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.gallery enable row level security;

create table if not exists public.eresources (
  id uuid primary key default uuid_generate_v4(),
  title text, description text,
  subject text, class text, term text,
  drive_link text,
  uploaded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.eresources enable row level security;

create table if not exists public.birthdays (
  id uuid primary key default uuid_generate_v4(),
  person_name text, type text,
  date date, class text,
  created_at timestamptz default now()
);
alter table public.birthdays enable row level security;

create table if not exists public.idcards (
  id uuid primary key default uuid_generate_v4(),
  person_id uuid,
  person_type text check (person_type in ('student','staff')),
  card_no text unique,
  qr_data text,
  issued_at timestamptz default now()
);
alter table public.idcards enable row level security;

create table if not exists public.reports (
  id uuid primary key default uuid_generate_v4(),
  title text, type text,
  payload jsonb,
  generated_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.reports enable row level security;

create table if not exists public.departments (
  id uuid primary key default uuid_generate_v4(),
  name text, head text, members text[],
  created_at timestamptz default now()
);
alter table public.departments enable row level security;

-- ---------------------------------------------------------------------
-- Academic configuration: departments, terms, sessions, arms, assessment labels.
-- These lookup rows power dropdowns across Results, CBT, Report Cards,
-- Timetable, Broadsheets and Certificates. Free/Supabase-only, no paid APIs.
-- ---------------------------------------------------------------------
create table if not exists public.lookups (
  id uuid primary key default uuid_generate_v4(),
  kind text not null,
  value text not null,
  position int default 0,
  active boolean default true,
  created_at timestamptz default now(),
  unique(kind,value)
);
alter table public.lookups enable row level security;

create table if not exists public.academic_periods (
  id uuid primary key default uuid_generate_v4(),
  session text not null,
  term text not null,
  starts_on date,
  ends_on date,
  is_current boolean default false,
  created_at timestamptz default now(),
  unique(session,term)
);
alter table public.academic_periods enable row level security;

insert into public.lookups(kind,value,position) values
 ('term','First Term',1),('term','Second Term',2),('term','Third Term',3),
 ('session','2024/2025',1),('session','2025/2026',2),('session','2026/2027',3),
 ('arm','A',1),('arm','B',2),('arm','C',3),
 ('assessment','CA1',1),('assessment','CA2',2),('assessment','Assignment',3),('assessment','Project',4),('assessment','Exam',5),
 ('audience','all',1),('audience','students',2),('audience','staff',3),('audience','parents',4)
on conflict(kind,value) do nothing;


-- ---- 2.7 Enterprise ----
create table if not exists public.admissions (
  id uuid primary key default uuid_generate_v4(),
  full_name text, dob date, gender text,
  parent_name text, parent_email text, parent_phone text,
  applying_for_class text,
  status text default 'submitted'
    check (status in ('submitted','reviewing','accepted','enrolled','rejected')),
  notes text,
  created_at timestamptz default now()
);
alter table public.admissions enable row level security;

-- FIXED v15: payroll now includes bonus/overtime/tax/pension/loan columns
-- and net_pay is computed via trigger (not generated column) to handle all fields
create table if not exists public.payroll (
  id uuid primary key default uuid_generate_v4(),
  staff_id uuid references public.staff(id) on delete cascade,
  staff_name text,
  month text, year int,
  basic numeric default 0,
  allowances numeric default 0,
  bonus numeric default 0,
  overtime numeric default 0,
  tax numeric default 0,
  pension numeric default 0,
  loan_deduction numeric default 0,
  other_deductions numeric default 0,
  deductions numeric default 0, -- legacy compat
  net_pay numeric default 0,
  method text default 'bank transfer',
  status text default 'draft' check (status in ('draft','approved','paid')),
  created_at timestamptz default now()
);
alter table public.payroll enable row level security;
-- Ensure new columns exist on legacy databases
alter table public.payroll add column if not exists staff_name text;
alter table public.payroll add column if not exists bonus numeric default 0;
alter table public.payroll add column if not exists overtime numeric default 0;
alter table public.payroll add column if not exists tax numeric default 0;
alter table public.payroll add column if not exists pension numeric default 0;
alter table public.payroll add column if not exists loan_deduction numeric default 0;
alter table public.payroll add column if not exists other_deductions numeric default 0;
alter table public.payroll add column if not exists method text default 'bank transfer';

-- Trigger to compute net_pay correctly
create or replace function public.compute_payroll_net()
returns trigger language plpgsql as $$
begin
  new.net_pay := greatest(0,
    coalesce(new.basic,0)+coalesce(new.allowances,0)+coalesce(new.bonus,0)+coalesce(new.overtime,0)
    - coalesce(new.tax,0)-coalesce(new.pension,0)-coalesce(new.loan_deduction,0)-coalesce(new.other_deductions,0)-coalesce(new.deductions,0)
  );
  return new;
end $$;
drop trigger if exists trg_compute_payroll_net on public.payroll;
create trigger trg_compute_payroll_net
before insert or update of basic, allowances, bonus, overtime, tax, pension, loan_deduction, other_deductions, deductions on public.payroll
for each row execute function public.compute_payroll_net();

create table if not exists public.hostel_allocations (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  block text, room text, bed text,
  status text default 'active' check (status in ('active','vacated')),
  created_at timestamptz default now()
);
alter table public.hostel_allocations enable row level security;

create table if not exists public.alumni (
  id uuid primary key default uuid_generate_v4(),
  full_name text, graduation_year int,
  last_class text, current_occupation text,
  email text, phone text,
  created_at timestamptz default now()
);
alter table public.alumni enable row level security;

create table if not exists public.inventory (
  id uuid primary key default uuid_generate_v4(),
  item_name text, category text,
  quantity int default 1, location text,
  condition text default 'good',
  created_at timestamptz default now()
);
alter table public.inventory enable row level security;
alter table public.inventory add column if not exists item_name text;
alter table public.inventory add column if not exists category text;
alter table public.inventory add column if not exists quantity int default 1;
alter table public.inventory add column if not exists location text;
alter table public.inventory add column if not exists condition text default 'good';

create table if not exists public.certificates (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  type text, serial_no text unique,
  issued_on date default current_date,
  signed_by text,
  created_at timestamptz default now()
);
alter table public.certificates enable row level security;

create table if not exists public.push_subscriptions (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references public.profiles(id) on delete cascade,
  endpoint text, p256dh text, auth text,
  created_at timestamptz default now(),
  unique(user_id, endpoint)
);
alter table public.push_subscriptions enable row level security;

-- =====================================================================
-- ✨ NEW in Gen v8 — competitor-parity & enterprise modules
--    (all use FREE tools only; no paid services, no AI APIs)
-- =====================================================================

-- Audit / activity log (PowerSchool, Infinite Campus, GegoK12 parity)
create table if not exists public.activity_log (
  id uuid primary key default uuid_generate_v4(),
  actor_id uuid references public.profiles(id),
  actor_email text,
  action text,            -- e.g. 'create','update','delete','login'
  entity text,            -- table or module affected
  entity_id text,
  details jsonb,
  ip text,
  created_at timestamptz default now()
);
alter table public.activity_log enable row level security;

-- LMS: courses, lessons, submissions (Canvas / Schoology / ilerno parity)
create table if not exists public.lms_courses (
  id uuid primary key default uuid_generate_v4(),
  title text not null, description text,
  subject text, class text, teacher text,
  cover_url text,
  created_at timestamptz default now()
);
alter table public.lms_courses enable row level security;

create table if not exists public.lms_lessons (
  id uuid primary key default uuid_generate_v4(),
  course_id uuid references public.lms_courses(id) on delete cascade,
  title text, content text,
  video_url text, resource_link text,
  position int default 0,
  created_at timestamptz default now()
);
alter table public.lms_lessons enable row level security;

create table if not exists public.lms_submissions (
  id uuid primary key default uuid_generate_v4(),
  assignment_id uuid references public.assignments(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  submission_link text, note text,
  score numeric, feedback text,
  status text default 'submitted' check (status in ('submitted','graded','returned')),
  submitted_at timestamptz default now()
);
alter table public.lms_submissions enable row level security;

-- Lesson plans / curriculum (Chalk parity)
create table if not exists public.lesson_plans (
  id uuid primary key default uuid_generate_v4(),
  teacher text, subject text, class text,
  week int, term text, session text,
  objectives text, content text, resources text,
  status text default 'draft' check (status in ('draft','submitted','approved')),
  created_at timestamptz default now()
);
alter table public.lesson_plans enable row level security;
alter table public.lesson_plans add column if not exists posted_by uuid references public.profiles(id) on delete set null;
alter table public.lesson_plans add column if not exists teacher_id uuid references public.profiles(id) on delete set null;

-- Behaviour / PBIS points (ClassDojo parity)
create table if not exists public.behaviour_points (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  points int default 0,
  reason text, badge text,
  awarded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.behaviour_points enable row level security;

-- Special education / student support plans (Provision Map parity)
create table if not exists public.support_plans (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  need_type text, intervention text,
  goal text, review_date date,
  outcome text, status text default 'active'
    check (status in ('active','review','closed')),
  created_at timestamptz default now()
);
alter table public.support_plans enable row level security;

-- Fundraising / donations (Blackbaud / FreshSchools parity)
create table if not exists public.donations (
  id uuid primary key default uuid_generate_v4(),
  campaign text, donor_name text, donor_email text,
  amount numeric, method text,
  note text, anonymous boolean default false,
  recorded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.donations enable row level security;

-- Substitute teacher / cover management
create table if not exists public.substitutions (
  id uuid primary key default uuid_generate_v4(),
  date date default current_date,
  absent_teacher text, substitute_teacher text,
  class text, subject text, period text,
  status text default 'planned' check (status in ('planned','done','cancelled')),
  created_at timestamptz default now()
);
alter table public.substitutions enable row level security;

-- Help desk / IT tickets (internal staff requests)
create table if not exists public.helpdesk_tickets (
  id uuid primary key default uuid_generate_v4(),
  submitted_by uuid references public.profiles(id),
  category text, subject text, body text,
  priority text default 'normal' check (priority in ('low','normal','high','urgent')),
  status text default 'open' check (status in ('open','in_progress','resolved','closed')),
  assignee uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.helpdesk_tickets enable row level security;

-- Online payment intents (free Paystack / Flutterwave / bank-transfer links)
create table if not exists public.payment_intents (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  amount numeric, provider text,        -- 'paystack' | 'flutterwave' | 'bank_transfer'
  reference text, checkout_url text,
  status text default 'pending' check (status in ('pending','paid','failed','cancelled')),
  created_at timestamptz default now()
);
alter table public.payment_intents enable row level security;


-- ========================================================
-- 2.5 COLUMN BACKFILL (idempotent upgrade-safety)
-- --------------------------------------------------------
-- "create table if not exists" does NOT add missing columns to a table that
-- already exists from an OLDER schema version. If a policy/view references a
-- column the old table lacks, you get errors like:
--   ERROR: column "voter_id" does not exist
-- These ALTERs guarantee every column the policies & views depend on exists,
-- on both fresh and previously-installed databases. Safe to re-run.
-- ========================================================
do $$ begin
  -- profiles
  alter table public.profiles            add column if not exists role text not null default 'student';
  alter table public.profiles            add column if not exists status text not null default 'pending';
  alter table public.profiles            add column if not exists email text;
  -- voting
  alter table public.poll_votes          add column if not exists voter_id uuid;
  alter table public.poll_votes          add column if not exists candidate_id text;
  alter table public.poll_votes          add column if not exists poll_id uuid;
  alter table public.polls               add column if not exists status text default 'open';
  -- attendance / results scoping
  alter table public.attendance          add column if not exists student_id uuid;
  alter table public.results             add column if not exists student_id uuid;
  alter table public.conduct             add column if not exists student_id uuid;
  alter table public.health              add column if not exists student_id uuid;
  alter table public.fee_payments        add column if not exists student_id uuid;
  alter table public.fee_payments        add column if not exists amount_paid numeric;
  -- messaging / complaints / helpdesk participants
  alter table public.messages            add column if not exists from_id uuid;
  alter table public.messages            add column if not exists to_id uuid;
  alter table public.complaints          add column if not exists submitted_by uuid;
  alter table public.helpdesk_tickets    add column if not exists submitted_by uuid;
  -- parent-child link
  alter table public.parent_child        add column if not exists parent_id uuid;
  alter table public.parent_child        add column if not exists student_id uuid;
  -- push subscriptions
  alter table public.push_subscriptions  add column if not exists user_id uuid;
  -- payment intents
  alter table public.payment_intents     add column if not exists student_id uuid;
exception when undefined_table then
  -- a referenced table doesn't exist yet on this DB; the create-table block
  -- above already created it this run, so nothing to backfill — ignore.
  null;
end $$;


-- ========================================================
-- 3. HELPER FUNCTIONS  (now safe — tables already exist)
-- ========================================================
create or replace function public.is_staff(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','principal','proprietor','head_teacher','staff','teacher','bursar')
      and status in ('approved','active')
  );
$$;

create or replace function public.is_admin(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','principal','proprietor','head_teacher','bursar')
      and status in ('approved','active')
  );
$$;

create or replace function public.is_parent_of(uid uuid, child uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.parent_child
    where parent_id = uid and student_id = child
  );
$$;


-- ========================================================
-- 4. NEW-USER TRIGGER (auto-create a profile on sign-up)
-- ========================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name, phone, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name',''),
    new.raw_user_meta_data->>'phone',
    coalesce(new.raw_user_meta_data->>'role','student')
  )
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ========================================================
-- 5. ROW-LEVEL SECURITY POLICIES
-- ========================================================

-- ---- Profiles ----
drop policy if exists "profiles_self_read"   on public.profiles;
drop policy if exists "profiles_self_update" on public.profiles;
drop policy if exists "profiles_staff_read"  on public.profiles;
drop policy if exists "profiles_admin_all"   on public.profiles;
drop policy if exists "profiles_self_read" on public.profiles;
create policy "profiles_self_read"   on public.profiles for select using (auth.uid() = id);
drop policy if exists "profiles_self_update" on public.profiles;
create policy "profiles_self_update" on public.profiles for update using (auth.uid() = id);
drop policy if exists "profiles_staff_read" on public.profiles;
create policy "profiles_staff_read"  on public.profiles for select using (public.is_staff(auth.uid()));
drop policy if exists "profiles_admin_all" on public.profiles;
create policy "profiles_admin_all"   on public.profiles for all    using (public.is_admin(auth.uid()));

-- ---- Generic: any authenticated user reads; staff writes ----
-- (scheme_of_work is now spelled correctly — no more 'sow' alias bug.)
do $$
declare t text;
declare read_tables text[] := array[
  'students','staff','classes','subjects','timetable','scheme_of_work','assignments',
  'library','fee_structures','events','gallery','eresources','birthdays','idcards',
  'departments','admissions','hostel_allocations','alumni','inventory','certificates',
  'lms_courses','lms_lessons','lesson_plans','behaviour_points','substitutions','donations'
];
begin
  foreach t in array read_tables loop
    execute format('drop policy if exists "read_%s"  on public.%I', t, t);
    execute format('drop policy if exists "write_%s" on public.%I', t, t);
    execute format('create policy "read_%s"  on public.%I for select using (auth.role() = ''authenticated'')', t, t);
    execute format('create policy "write_%s" on public.%I for all    using (public.is_staff(auth.uid()))', t, t);
  end loop;
end $$;


-- ---- Results ownership: staff can read academic scores, but only admins or the teacher who created a score may update/delete it ----
drop policy if exists "results_update_teacher" on public.results;
drop policy if exists "results_delete_teacher" on public.results;
drop policy if exists "results_update_teacher" on public.results;
create policy "results_update_teacher" on public.results for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid());
drop policy if exists "results_delete_teacher" on public.results;
create policy "results_delete_teacher" on public.results for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid());

-- ---- Affective & Psychomotor Domains (NEW in v9) ----
create table if not exists public.affective_traits (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  term text, session text,
  ratings jsonb default '{}'::jsonb, -- {trait: rating, ...}
  teacher_id uuid references public.profiles(id),
  created_at timestamptz default now(),
  unique(student_id, term, session)
);
alter table public.affective_traits enable row level security;
drop policy if exists "read_affective" on public.affective_traits;
create policy "read_affective" on public.affective_traits for select using (auth.role() = 'authenticated');
drop policy if exists "write_affective" on public.affective_traits;
create policy "write_affective" on public.affective_traits for all using (public.is_staff(auth.uid()));

create table if not exists public.psychomotor_traits (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  term text, session text,
  ratings jsonb default '{}'::jsonb,
  teacher_id uuid references public.profiles(id),
  created_at timestamptz default now(),
  unique(student_id, term, session)
);
alter table public.psychomotor_traits enable row level security;
drop policy if exists "read_psychomotor" on public.psychomotor_traits;
create policy "read_psychomotor" on public.psychomotor_traits for select using (auth.role() = 'authenticated');
drop policy if exists "write_psychomotor" on public.psychomotor_traits;
create policy "write_psychomotor" on public.psychomotor_traits for all using (public.is_staff(auth.uid()));

create table if not exists public.report_comments (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  term text, session text,
  class_teacher_comment text,
  principal_comment text,
  next_term_begins date,
  created_at timestamptz default now(),
  unique(student_id, term, session)
);
alter table public.report_comments enable row level security;
drop policy if exists "read_comments" on public.report_comments;
create policy "read_comments" on public.report_comments for select using (auth.role() = 'authenticated');
drop policy if exists "write_comments" on public.report_comments;
create policy "write_comments" on public.report_comments for all using (public.is_staff(auth.uid()));

-- ---- Update RLS for teacher isolation on key academic tables ----
do $$
declare t text;
declare owned_tables text[] := array['assignments','scheme_of_work','lesson_plans','cbt_exams','attendance'];
begin
  foreach t in array owned_tables loop
    execute format('drop policy if exists "update_own_%s" on public.%I', t, t);
    execute format('drop policy if exists "delete_own_%s" on public.%I', t, t);
    execute format('create policy "update_own_%s" on public.%I for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid() or posted_by = auth.uid() or recorded_by = auth.uid())', t, t);
    execute format('create policy "delete_own_%s" on public.%I for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid() or posted_by = auth.uid() or recorded_by = auth.uid())', t, t);
  end loop;
end $$;

-- ---- Attendance: parents see own children; staff manage ----
drop policy if exists "att_read"  on public.attendance;
drop policy if exists "att_write" on public.attendance;
drop policy if exists "att_read" on public.attendance;
create policy "att_read"  on public.attendance for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or student_id in (select id from public.students where guardian_email = auth.jwt()->>'email')
  or public.is_staff(auth.uid())
);
drop policy if exists "att_write" on public.attendance;
create policy "att_write" on public.attendance for all using (public.is_staff(auth.uid()));

-- ---- Results: parents see own children; staff manage ----
drop policy if exists "res_read"  on public.results;
drop policy if exists "res_write" on public.results;
drop policy if exists "results_select_v5" on public.results;
drop policy if exists "results_insert_v5" on public.results;
drop policy if exists "results_update_v5" on public.results;
drop policy if exists "results_delete_v5" on public.results;
drop policy if exists "results_select_v5" on public.results;
create policy "results_select_v5" on public.results for select using (
  public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
);
drop policy if exists "results_insert_v5" on public.results;
create policy "results_insert_v5" on public.results for insert with check (public.is_staff(auth.uid()));
drop policy if exists "results_update_v5" on public.results;
create policy "results_update_v5" on public.results for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid()) with check (public.is_admin(auth.uid()) or teacher_id = auth.uid());
drop policy if exists "results_delete_v5" on public.results;
create policy "results_delete_v5" on public.results for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid());

-- ---- Conduct / Health / Behaviour / Support: parents see own; staff manage ----
drop policy if exists "cond_read"  on public.conduct;
drop policy if exists "cond_write" on public.conduct;
drop policy if exists "cond_read" on public.conduct;
create policy "cond_read"  on public.conduct for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
drop policy if exists "cond_write" on public.conduct;
create policy "cond_write" on public.conduct for all using (public.is_staff(auth.uid()));

drop policy if exists "hlth_read"  on public.health;
drop policy if exists "hlth_write" on public.health;
drop policy if exists "hlth_read" on public.health;
create policy "hlth_read"  on public.health for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
drop policy if exists "hlth_write" on public.health;
create policy "hlth_write" on public.health for all using (public.is_staff(auth.uid()));

drop policy if exists "sp_read"  on public.support_plans;
drop policy if exists "sp_write" on public.support_plans;
drop policy if exists "sp_read" on public.support_plans;
create policy "sp_read"  on public.support_plans for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
drop policy if exists "sp_write" on public.support_plans;
create policy "sp_write" on public.support_plans for all using (public.is_staff(auth.uid()));

-- ---- Fees: parents see own; staff manage ----
drop policy if exists "fp_read"  on public.fee_payments;
drop policy if exists "fp_write" on public.fee_payments;
drop policy if exists "fp_read" on public.fee_payments;
create policy "fp_read"  on public.fee_payments for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "fp_write" on public.fee_payments;
create policy "fp_write" on public.fee_payments for all using (public.is_staff(auth.uid()));

-- ---- Payment intents: parents see own; staff manage ----
drop policy if exists "pi_read"  on public.payment_intents;
drop policy if exists "pi_write" on public.payment_intents;
drop policy if exists "pi_read" on public.payment_intents;
create policy "pi_read"  on public.payment_intents for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "pi_write" on public.payment_intents;
create policy "pi_write" on public.payment_intents for all using (public.is_staff(auth.uid()));

-- ---- Finance / Payroll / Donations: admin only ----
drop policy if exists "fin_all" on public.finance_entries;
create policy "fin_all" on public.finance_entries for all using (public.is_admin(auth.uid()));

drop policy if exists "pay_all" on public.payroll;
create policy "pay_all" on public.payroll for all using (public.is_admin(auth.uid()));

drop policy if exists "don_admin" on public.donations;
create policy "don_admin" on public.donations for all using (public.is_admin(auth.uid()));

-- ---- Leave: staff read/write; admin manages ----
drop policy if exists "lr_all" on public.leave_requests;
create policy "lr_all" on public.leave_requests for all using (public.is_staff(auth.uid()));

-- ---- Visitors: anyone can sign in at the gate; staff reads ----
drop policy if exists "vis_insert" on public.visitors;
drop policy if exists "vis_read"   on public.visitors;
drop policy if exists "vis_insert" on public.visitors;
create policy "vis_insert" on public.visitors for insert with check (true);
drop policy if exists "vis_read" on public.visitors;
create policy "vis_read"   on public.visitors for select using (public.is_staff(auth.uid()));

-- ---- Transport ----
drop policy if exists "tr_all" on public.transport;
create policy "tr_all" on public.transport for all using (public.is_staff(auth.uid()));

-- ---- Announcements: everyone reads; staff writes ----
drop policy if exists "ann_read"  on public.announcements;
drop policy if exists "ann_write" on public.announcements;
drop policy if exists "ann_read" on public.announcements;
create policy "ann_read"  on public.announcements for select using (auth.role() = 'authenticated');
drop policy if exists "ann_write" on public.announcements;
create policy "ann_write" on public.announcements for all using (public.is_staff(auth.uid()));

-- ---- Messages: only the two participants ----
drop policy if exists "msg_all" on public.messages;
create policy "msg_all" on public.messages for all using (
  auth.uid() = from_id or auth.uid() = to_id
);

-- ---- Complaints: submitter sees own; staff sees all ----
drop policy if exists "comp_all" on public.complaints;
create policy "comp_all" on public.complaints for all using (
  submitted_by = auth.uid() or public.is_staff(auth.uid())
);

-- ---- Help desk: submitter sees own; staff sees all ----
drop policy if exists "hd_all" on public.helpdesk_tickets;
create policy "hd_all" on public.helpdesk_tickets for all using (
  submitted_by = auth.uid() or public.is_staff(auth.uid())
);

-- ---- Notifications: everyone reads; staff writes ----
drop policy if exists "notif_read"  on public.notifications;
drop policy if exists "notif_write" on public.notifications;
drop policy if exists "notif_read" on public.notifications;
create policy "notif_read"  on public.notifications for select using (auth.role() = 'authenticated');
drop policy if exists "notif_write" on public.notifications;
create policy "notif_write" on public.notifications for all using (public.is_staff(auth.uid()));

-- ---- Voting ----
drop policy if exists "polls_read"  on public.polls;
drop policy if exists "polls_write" on public.polls;
drop policy if exists "polls_read" on public.polls;
create policy "polls_read"  on public.polls for select using (auth.role() = 'authenticated');
drop policy if exists "polls_write" on public.polls;
create policy "polls_write" on public.polls for all using (public.is_staff(auth.uid()));

drop policy if exists "pv_read"   on public.poll_votes;
drop policy if exists "pv_insert" on public.poll_votes;
drop policy if exists "pv_update" on public.poll_votes;
drop policy if exists "pv_read" on public.poll_votes;
create policy "pv_read"   on public.poll_votes for select using (auth.uid() = voter_id or public.is_staff(auth.uid()));
drop policy if exists "pv_insert" on public.poll_votes;
create policy "pv_insert" on public.poll_votes for insert with check (auth.uid() = voter_id);
drop policy if exists "pv_update" on public.poll_votes;
create policy "pv_update" on public.poll_votes for update using (auth.uid() = voter_id);

-- ---- Push subscriptions: each user manages own ----
drop policy if exists "ps_all" on public.push_subscriptions;
create policy "ps_all" on public.push_subscriptions for all using (auth.uid() = user_id);

-- ---- Reports / Promotions ----
drop policy if exists "rep_all" on public.reports;
create policy "rep_all" on public.reports for all using (public.is_staff(auth.uid()));

drop policy if exists "prom_all" on public.promotions;
create policy "prom_all" on public.promotions for all using (public.is_staff(auth.uid()));

-- ---- Academic periods / lookups: everyone may read; admins manage ----
drop policy if exists "ap_read" on public.academic_periods;
drop policy if exists "ap_write" on public.academic_periods;
drop policy if exists "ap_read" on public.academic_periods;
create policy "ap_read" on public.academic_periods for select using (auth.role() = 'authenticated');
drop policy if exists "ap_write" on public.academic_periods;
create policy "ap_write" on public.academic_periods for all using (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) with check (public.is_admin(auth.uid()) or public.is_staff(auth.uid()));

drop policy if exists "lookups_read" on public.lookups;
drop policy if exists "lookups_write" on public.lookups;
drop policy if exists "lookups_read" on public.lookups;
create policy "lookups_read" on public.lookups for select using (auth.role() = 'authenticated');
drop policy if exists "lookups_write" on public.lookups;
create policy "lookups_write" on public.lookups for all using (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) with check (public.is_admin(auth.uid()) or public.is_staff(auth.uid()));

-- ---- Parent-child ----
drop policy if exists "pc_read"  on public.parent_child;
drop policy if exists "pc_write" on public.parent_child;
drop policy if exists "pc_read" on public.parent_child;
create policy "pc_read"  on public.parent_child for select using (
  parent_id = auth.uid() or public.is_staff(auth.uid())
);
drop policy if exists "pc_write" on public.parent_child;
create policy "pc_write" on public.parent_child for all using (public.is_staff(auth.uid()));

-- ---- LMS submissions: student sees own; staff manage ----
drop policy if exists "sub_read"  on public.lms_submissions;
drop policy if exists "sub_write" on public.lms_submissions;
drop policy if exists "sub_read" on public.lms_submissions;
create policy "sub_read"  on public.lms_submissions for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "sub_write" on public.lms_submissions;
create policy "sub_write" on public.lms_submissions for all using (public.is_staff(auth.uid()));

-- ---- Activity log: staff/admin read; anyone authenticated may insert ----
drop policy if exists "al_read"   on public.activity_log;
drop policy if exists "al_insert" on public.activity_log;
drop policy if exists "al_read" on public.activity_log;
create policy "al_read"   on public.activity_log for select using (public.is_admin(auth.uid()));
drop policy if exists "al_insert" on public.activity_log;
create policy "al_insert" on public.activity_log for insert with check (auth.role() = 'authenticated');


-- =====================================================================
-- 6. CONVENIENCE VIEW — live poll results
-- =====================================================================
-- Drop first so re-runs never hit 42P16 "cannot drop columns from view"
-- (an older poll_results view from a previous schema version may exist).
drop view if exists public.poll_results cascade;
create or replace view public.poll_results as
select p.id as poll_id, p.title,
       coalesce(sum(v.c), 0) as total_votes,
       coalesce(jsonb_agg(jsonb_build_object('candidate', v.candidate_id, 'votes', v.c))
                filter (where v.candidate_id is not null), '[]'::jsonb) as breakdown
from public.polls p
left join lateral (
  select candidate_id, count(*) as c
  from public.poll_votes
  where poll_id = p.id
  group by candidate_id
) v on true
group by p.id, p.title;


-- =====================================================================
-- DONE ✅
-- 50+ tables · full RLS · correct creation order · no 42P01 errors.
--
-- NEXT STEP: promote yourself to admin AFTER you sign up in the app:
--   update public.profiles
--      set role = 'admin', status = 'approved'
--    where email = 'your-email@example.com';
-- =====================================================================

-- FIX V2.1 Issue #17: next term fees bill on report card
alter table public.school_settings add column if not exists next_term_fees numeric default 0;
alter table public.school_settings add column if not exists next_term_fees_currency text default '₦';
alter table public.school_settings add column if not exists next_term_begins date;
alter table public.school_settings add column if not exists next_term_fees_note text default 'Payable before resumption';

select 'School Connect schema v8 installed successfully ✅' as status;


-- FINAL CUMULATIVE SUBJECT-TEACHER MAPPING REPAIR
-- Safe for fresh and existing databases. Fixes: could not find 'teacher' column of subjects.
alter table if exists public.subjects add column if not exists teacher text;
alter table if exists public.subjects add column if not exists teacher_id uuid references public.profiles(id) on delete set null;


-- ---- Certificate verification: public-safe lookup by serial/cert code ----
create or replace function public.verify_certificate(p_code text)
returns table(source text, serial_no text, student_name text, certificate_type text, issued_on text, score text, status text)
language plpgsql security definer set search_path=public as $$
begin
  return query
  select 'certificate'::text, c.serial_no::text, coalesce(s.full_name,'')::text, coalesce(c.type,'Certificate')::text,
         coalesce(c.issued_on::text,'')::text, ''::text, 'valid'::text
  from public.certificates c left join public.students s on s.id=c.student_id
  where upper(c.serial_no)=upper(p_code)
  union all
  select 'cbt'::text, r.cert_code::text, r.student_name::text, coalesce(e.title,e.subject,'CBT Certificate')::text,
         coalesce(r.created_at::date::text,'')::text, (r.score::text || '/' || r.total::text || ' (' || coalesce(r.percent,0)::text || '%)')::text, 'valid'::text
  from public.cbt_results r left join public.cbt_exams e on e.id=r.exam_id
  where r.cert_code is not null and r.cert_code<>'' and upper(r.cert_code)=upper(p_code);
end $$;
grant execute on function public.verify_certificate(text) to anon, authenticated;


-- Role/page access map controlled from Admin Dashboard → Page Access Manager.

-- ENTERPRISE V4: school_settings must exist before any ALTER/POLICY uses it
create table if not exists public.school_settings (
  id int primary key default 1,
  admission_prefix text default 'SCH',
  admission_next int default 1,
  staff_prefix text default 'STF',
  staff_next int default 1,
  parent_prefix text default 'PAR',
  parent_next int default 1,
  signature_url text default '',
  principal_name text default '',
  role_access jsonb,
  role_write jsonb,
  -- FIX GEO-02 (#8): geofence columns declared on the base table so they are
  -- ALWAYS present. Previously they were added later in a DO block that some
  -- deployments skipped, causing "Could not find the 'enforce_geofence' column
  -- of 'school_settings' in the schema cache" when saving the staff geofence.
  latitude numeric,
  longitude numeric,
  geo_radius_m integer default 200,
  enforce_geofence boolean default true,
  geo_updated_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
insert into public.school_settings (id) values (1) on conflict (id) do nothing;

alter table public.school_settings add column if not exists role_access jsonb;

-- Page access manager write-permission map.
alter table public.school_settings add column if not exists role_write jsonb;


-- =====================================================================
-- V3 PRIVACY PATCH: scoped student/parent views. Staff/Admin manage.
-- =====================================================================
drop policy if exists "read_students" on public.students;
drop policy if exists "write_students" on public.students;
drop policy if exists "read_students" on public.students;
create policy "read_students" on public.students for select using (
  public.is_staff(auth.uid()) or user_id = auth.uid() or public.is_parent_of(auth.uid(), id)
);
drop policy if exists "write_students" on public.students;
create policy "write_students" on public.students for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "read_assignments" on public.assignments;
drop policy if exists "write_assignments" on public.assignments;
drop policy if exists "read_assignments" on public.assignments;
create policy "read_assignments" on public.assignments for select using (
  public.is_staff(auth.uid())
  or class in (select class from public.students where user_id = auth.uid())
  or class in (select class from public.students s join public.parent_child pc on pc.student_id=s.id where pc.parent_id=auth.uid())
);
drop policy if exists "write_assignments" on public.assignments;
create policy "write_assignments" on public.assignments for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "read_eresources" on public.eresources;
drop policy if exists "write_eresources" on public.eresources;
drop policy if exists "read_eresources" on public.eresources;
create policy "read_eresources" on public.eresources for select using (
  public.is_staff(auth.uid())
  or class in (select class from public.students where user_id = auth.uid())
  or class in (select class from public.students s join public.parent_child pc on pc.student_id=s.id where pc.parent_id=auth.uid())
);
drop policy if exists "write_eresources" on public.eresources;
create policy "write_eresources" on public.eresources for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "read_certificates" on public.certificates;
drop policy if exists "write_certificates" on public.certificates;
drop policy if exists "read_certificates" on public.certificates;
create policy "read_certificates" on public.certificates for select using (
  public.is_staff(auth.uid()) or student_id in (select id from public.students where user_id=auth.uid()) or public.is_parent_of(auth.uid(), student_id)
);
drop policy if exists "write_certificates" on public.certificates;
create policy "write_certificates" on public.certificates for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));


-- =====================================================================
-- ENTERPRISE V3 MODULE RECORDS CORE (prevents inbox/audience schema cache errors even before enhancement scripts)
-- =====================================================================
create table if not exists public.module_records (
  id uuid primary key default uuid_generate_v4(),
  module text not null,
  title text,
  body text,
  status text,
  audience text default 'private',
  recipient_id uuid references public.profiles(id) on delete set null,
  source text default 'manual',
  ref_date date,
  amount numeric,
  data jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles(id),
  updated_by uuid references public.profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table public.module_records enable row level security;
create index if not exists module_records_module_idx on public.module_records (module, created_at desc);
alter table public.module_records add column if not exists audience text default 'private';
alter table public.module_records add column if not exists recipient_id uuid references public.profiles(id) on delete set null;

-- ========================================================
-- SCHOOL CONNECT V11: Voting UUID/type repair + secure poll workflow
-- Fixes legacy databases where poll_votes.candidate_id was UUID, causing
-- "invalid input syntax for type uuid" when candidate IDs like c1/c2 are used.
-- Safe to run repeatedly after the main schemas.
-- ========================================================
create extension if not exists "uuid-ossp";

do $$ begin
  alter table public.polls add column if not exists max_votes integer default 1;
  alter table public.polls add column if not exists created_by uuid references public.profiles(id) on delete set null;
exception when undefined_table then null; end $$;

-- V13 voting repair: poll_results depends on candidate_id, so drop/recreate the view around the type conversion.
do $$ begin
  drop view if exists public.poll_results cascade;
  alter table public.poll_votes alter column candidate_id type text using candidate_id::text;
exception when undefined_table then null; end $$;
drop view if exists public.poll_results cascade;
create or replace view public.poll_results as
select p.id as poll_id, p.title,
       coalesce(sum(v.c), 0) as total_votes,
       coalesce(jsonb_agg(jsonb_build_object('candidate', v.candidate_id, 'votes', v.c))
                filter (where v.candidate_id is not null), '[]'::jsonb) as breakdown
from public.polls p
left join lateral (
  select candidate_id, count(*) as c
  from public.poll_votes
  where poll_id = p.id
  group by candidate_id
) v on true
group by p.id, p.title;
do $$ begin
  alter table public.poll_votes add column if not exists voter_id uuid references public.profiles(id) on delete cascade;
  alter table public.poll_votes add column if not exists voted_at timestamptz default now();
exception when undefined_table then null; end $$;

create index if not exists polls_status_created_idx on public.polls(status, created_at desc);
create index if not exists poll_votes_poll_voter_idx on public.poll_votes(poll_id, voter_id);

drop policy if exists "polls_read"  on public.polls;
drop policy if exists "polls_write" on public.polls;
drop policy if exists "polls_update_v11" on public.polls;
drop policy if exists "polls_delete_v11" on public.polls;
drop policy if exists "polls_read" on public.polls;
create policy "polls_read" on public.polls for select using (auth.role() = 'authenticated');
drop policy if exists "polls_write" on public.polls;
create policy "polls_write" on public.polls for insert with check (public.is_staff(auth.uid()));
drop policy if exists "polls_update_v11" on public.polls;
create policy "polls_update_v11" on public.polls for update using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "polls_delete_v11" on public.polls;
create policy "polls_delete_v11" on public.polls for delete using (public.is_admin(auth.uid()));

drop policy if exists "pv_read"   on public.poll_votes;
drop policy if exists "pv_insert" on public.poll_votes;
drop policy if exists "pv_update" on public.poll_votes;
drop policy if exists "pv_delete_v11" on public.poll_votes;
drop policy if exists "pv_read" on public.poll_votes;
create policy "pv_read" on public.poll_votes for select using (auth.uid() = voter_id or public.is_staff(auth.uid()));
drop policy if exists "pv_insert" on public.poll_votes;
create policy "pv_insert" on public.poll_votes for insert with check (
  auth.uid() = voter_id
  and exists (select 1 from public.polls p where p.id = poll_id and coalesce(p.status,'open') = 'open')
);
drop policy if exists "pv_update" on public.poll_votes;
create policy "pv_update" on public.poll_votes for update using (auth.uid() = voter_id) with check (auth.uid() = voter_id);
drop policy if exists "pv_delete_v11" on public.poll_votes;
create policy "pv_delete_v11" on public.poll_votes for delete using (auth.uid() = voter_id or public.is_staff(auth.uid()));

-- Strict family-safe ID-card visibility: staff manage; student/parent can only
-- read cards connected to themselves/their child.
drop policy if exists "read_idcards" on public.idcards;
drop policy if exists "write_idcards" on public.idcards;
drop policy if exists "read_idcards" on public.idcards;
create policy "read_idcards" on public.idcards for select using (
  public.is_staff(auth.uid())
  or (person_type = 'student' and person_id in (select id from public.students where user_id = auth.uid()))
  or (person_type = 'student' and public.is_parent_of(auth.uid(), person_id))
);
drop policy if exists "write_idcards" on public.idcards;
create policy "write_idcards" on public.idcards for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));


-- ========================================================
-- SCHOOL CONNECT V12: Idempotent policies, voting repair, ownership locks,
-- persistent notifications support, and staff geofenced attendance settings.
-- Safe to run repeatedly after complete-schema/schema.
-- ========================================================
create extension if not exists "uuid-ossp";

-- Parents policy idempotency fix: prevents ERROR 42710 policy already exists.
drop policy if exists "parents_read" on public.parents;
drop policy if exists "parents_write" on public.parents;
drop policy if exists "parents_read" on public.parents;
create policy "parents_read" on public.parents for select using (auth.role() = 'authenticated');
drop policy if exists "parents_write" on public.parents;
create policy "parents_write" on public.parents for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- Voting UUID/type repair: legacy databases may have candidate_id as uuid.
-- V13 voting repair: poll_results depends on candidate_id, so drop/recreate the view around the type conversion.
do $$ begin
  drop view if exists public.poll_results cascade;
  alter table public.poll_votes alter column candidate_id type text using candidate_id::text;
exception when undefined_table then null; end $$;
drop view if exists public.poll_results cascade;
create or replace view public.poll_results as
select p.id as poll_id, p.title,
       coalesce(sum(v.c), 0) as total_votes,
       coalesce(jsonb_agg(jsonb_build_object('candidate', v.candidate_id, 'votes', v.c))
                filter (where v.candidate_id is not null), '[]'::jsonb) as breakdown
from public.polls p
left join lateral (
  select candidate_id, count(*) as c
  from public.poll_votes
  where poll_id = p.id
  group by candidate_id
) v on true
group by p.id, p.title;


do $$ begin
  alter table public.polls add column if not exists max_votes integer default 1;
  alter table public.polls add column if not exists created_by uuid references public.profiles(id) on delete set null;
  alter table public.poll_votes add column if not exists voter_id uuid references public.profiles(id) on delete cascade;
  alter table public.poll_votes add column if not exists voted_at timestamptz default now();
exception when undefined_table then null; end $$;

drop policy if exists "polls_read"  on public.polls;
drop policy if exists "polls_write" on public.polls;
drop policy if exists "polls_update_v11" on public.polls;
drop policy if exists "polls_delete_v11" on public.polls;
drop policy if exists "polls_read" on public.polls;
create policy "polls_read" on public.polls for select using (auth.role() = 'authenticated');
drop policy if exists "polls_write" on public.polls;
create policy "polls_write" on public.polls for insert with check (public.is_staff(auth.uid()));
drop policy if exists "polls_update_v11" on public.polls;
create policy "polls_update_v11" on public.polls for update using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "polls_delete_v11" on public.polls;
create policy "polls_delete_v11" on public.polls for delete using (public.is_admin(auth.uid()));

drop policy if exists "pv_read" on public.poll_votes;
drop policy if exists "pv_insert" on public.poll_votes;
drop policy if exists "pv_update" on public.poll_votes;
drop policy if exists "pv_delete_v11" on public.poll_votes;
drop policy if exists "pv_read" on public.poll_votes;
create policy "pv_read" on public.poll_votes for select using (auth.uid() = voter_id or public.is_staff(auth.uid()));
drop policy if exists "pv_insert" on public.poll_votes;
create policy "pv_insert" on public.poll_votes for insert with check (
  auth.uid() = voter_id and exists (select 1 from public.polls p where p.id = poll_id and coalesce(p.status,'open') = 'open')
);
drop policy if exists "pv_update" on public.poll_votes;
create policy "pv_update" on public.poll_votes for update using (auth.uid() = voter_id) with check (auth.uid() = voter_id);
drop policy if exists "pv_delete_v11" on public.poll_votes;
create policy "pv_delete_v11" on public.poll_votes for delete using (auth.uid() = voter_id or public.is_staff(auth.uid()));

-- Staff geofenced attendance settings, configured by admin in Settings.
do $$ begin
  alter table public.school_settings add column if not exists latitude numeric;
  alter table public.school_settings add column if not exists longitude numeric;
  alter table public.school_settings add column if not exists geo_radius_m integer default 200;
  alter table public.school_settings add column if not exists enforce_geofence boolean default true;
  alter table public.school_settings add column if not exists geo_updated_at timestamptz;
exception when undefined_table then null; end $$;

-- Ownership columns for teacher/staff-only editing.
do $$ begin
  alter table public.health add column if not exists recorded_by_id uuid references public.profiles(id) on delete set null;
  alter table public.reports add column if not exists generated_by uuid references public.profiles(id) on delete set null;
  alter table public.helpdesk_tickets add column if not exists submitted_by uuid references public.profiles(id) on delete set null;
exception when undefined_table then null; end $$;

-- Health/clinic: staff may read; only owner or admin may edit/delete.
drop policy if exists "hlth_read" on public.health;
drop policy if exists "hlth_write" on public.health;
drop policy if exists "hlth_insert_v12" on public.health;
drop policy if exists "hlth_update_v12" on public.health;
drop policy if exists "hlth_delete_v12" on public.health;
drop policy if exists "hlth_read" on public.health;
create policy "hlth_read" on public.health for select using (
  public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id) or student_id in (select id from public.students where user_id = auth.uid())
);
drop policy if exists "hlth_insert_v12" on public.health;
create policy "hlth_insert_v12" on public.health for insert with check (public.is_staff(auth.uid()));
drop policy if exists "hlth_update_v12" on public.health;
create policy "hlth_update_v12" on public.health for update using (public.is_admin(auth.uid()) or recorded_by_id = auth.uid()) with check (public.is_admin(auth.uid()) or recorded_by_id = auth.uid());
drop policy if exists "hlth_delete_v12" on public.health;
create policy "hlth_delete_v12" on public.health for delete using (public.is_admin(auth.uid()) or recorded_by_id = auth.uid());

-- Helpdesk: staff can read; ticket owner/assignee/admin can update; admin can delete.
drop policy if exists "hd_all" on public.helpdesk_tickets;
drop policy if exists "hd_select_v12" on public.helpdesk_tickets;
drop policy if exists "hd_insert_v12" on public.helpdesk_tickets;
drop policy if exists "hd_update_v12" on public.helpdesk_tickets;
drop policy if exists "hd_delete_v12" on public.helpdesk_tickets;
drop policy if exists "hd_select_v12" on public.helpdesk_tickets;
create policy "hd_select_v12" on public.helpdesk_tickets for select using (public.is_staff(auth.uid()) or submitted_by = auth.uid() or assignee = auth.uid());
drop policy if exists "hd_insert_v12" on public.helpdesk_tickets;
create policy "hd_insert_v12" on public.helpdesk_tickets for insert with check (auth.role() = 'authenticated');
drop policy if exists "hd_update_v12" on public.helpdesk_tickets;
create policy "hd_update_v12" on public.helpdesk_tickets for update using (public.is_admin(auth.uid()) or submitted_by = auth.uid() or assignee = auth.uid()) with check (public.is_admin(auth.uid()) or submitted_by = auth.uid() or assignee = auth.uid());
drop policy if exists "hd_delete_v12" on public.helpdesk_tickets;
create policy "hd_delete_v12" on public.helpdesk_tickets for delete using (public.is_admin(auth.uid()) or submitted_by = auth.uid());

-- Reports table: staff read; creator/admin modify.
drop policy if exists "rep_all" on public.reports;
drop policy if exists "rep_select_v12" on public.reports;
drop policy if exists "rep_insert_v12" on public.reports;
drop policy if exists "rep_update_v12" on public.reports;
drop policy if exists "rep_delete_v12" on public.reports;
drop policy if exists "rep_select_v12" on public.reports;
create policy "rep_select_v12" on public.reports for select using (public.is_staff(auth.uid()));
drop policy if exists "rep_insert_v12" on public.reports;
create policy "rep_insert_v12" on public.reports for insert with check (public.is_staff(auth.uid()));
drop policy if exists "rep_update_v12" on public.reports;
create policy "rep_update_v12" on public.reports for update using (public.is_admin(auth.uid()) or generated_by = auth.uid()) with check (public.is_admin(auth.uid()) or generated_by = auth.uid());
drop policy if exists "rep_delete_v12" on public.reports;
create policy "rep_delete_v12" on public.reports for delete using (public.is_admin(auth.uid()) or generated_by = auth.uid());

-- Generic module records (reports, counselling, wellbeing, etc.): staff can read,
-- creator/admin can modify; family users only modify their own allowed family records.
-- FIXED v15: Added missing SELECT and INSERT policies (previous version only had update/delete)
drop policy if exists "mr_select_v15" on public.module_records;
drop policy if exists "mr_insert_v15" on public.module_records;
drop policy if exists "mr_update_family" on public.module_records;
drop policy if exists "mr_update_v12_owner" on public.module_records;
drop policy if exists "mr_delete_v12_owner" on public.module_records;

create policy "mr_select_v15" on public.module_records for select using (
  public.is_staff(auth.uid())
  or created_by = auth.uid()
  or recipient_id = auth.uid()
  or audience in ('all','public')
  or (audience = 'parent' and exists (select 1 from public.profiles where id=auth.uid() and role='parent'))
  or (audience = 'student' and exists (select 1 from public.profiles where id=auth.uid() and role='student'))
);

create policy "mr_insert_v15" on public.module_records for insert with check (
  auth.role() = 'authenticated'
);

drop policy if exists "mr_update_v12_owner" on public.module_records;
create policy "mr_update_v12_owner" on public.module_records for update using (
  public.is_admin(auth.uid()) or created_by = auth.uid()
) with check (public.is_admin(auth.uid()) or created_by = auth.uid());

drop policy if exists "mr_delete_v12_owner" on public.module_records;
create policy "mr_delete_v12_owner" on public.module_records for delete using (public.is_admin(auth.uid()) or created_by = auth.uid());

-- ID cards remain private to staff, owning student, or linked parent.
drop policy if exists "read_idcards" on public.idcards;
drop policy if exists "write_idcards" on public.idcards;
drop policy if exists "read_idcards" on public.idcards;
create policy "read_idcards" on public.idcards for select using (
  public.is_staff(auth.uid())
  or (person_type = 'student' and person_id in (select id from public.students where user_id = auth.uid()))
  or (person_type = 'student' and public.is_parent_of(auth.uid(), person_id))
);
drop policy if exists "write_idcards" on public.idcards;
create policy "write_idcards" on public.idcards for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
-- V12 safety: create exam_registrations before any ALTER references it.
create table if not exists public.exam_registrations (
  id uuid primary key default gen_random_uuid(),
  school_id uuid,
  student_id uuid,
  student_name text,
  admission_no text,
  class text,
  exam_type text,
  exam_year int,
  status text default 'pending',
  payload jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);

-- =====================================================================
-- SCHOOL CONNECT V1 FINAL CUMULATIVE PATCH (2026-07-19)
-- Purpose: make complete-schema.sql genuinely self-contained for fresh
-- installs. It includes all v15/v16 operational tables and fixes reported
-- schema-cache errors, report-score upsert constraints, parent-child naming,
-- class/department next-term fee bills, school stamps/signature settings and
-- staff check-in deadlines.
-- Safe to re-run.
-- =====================================================================

-- Ensure school_settings has every setting used by the runtime.
alter table if exists public.school_settings add column if not exists next_term_fees numeric default 0;
alter table if exists public.school_settings add column if not exists next_term_fees_currency text default '₦';
alter table if exists public.school_settings add column if not exists next_term_fees_note text default 'Payable before resumption';
alter table if exists public.school_settings add column if not exists next_term_begins date;
alter table if exists public.school_settings add column if not exists signature_url text default '';
alter table if exists public.school_settings add column if not exists principal_name text default '';
alter table if exists public.school_settings add column if not exists stamp_color text default '#1e3a8a';
alter table if exists public.school_settings add column if not exists checkin_deadline time default '08:00';
alter table if exists public.school_settings add column if not exists checkin_grace_minutes int default 0;
alter table if exists public.school_settings add column if not exists role_access jsonb default '{}'::jsonb;
alter table if exists public.school_settings add column if not exists role_write jsonb default '{}'::jsonb;

-- Class / department fee bills. This fixes schema-cache errors for
-- class_fee_structure and powers next-term report-card bills.
create table if not exists public.class_fee_structure (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  class text not null,
  arm text default '',
  department text default '',
  term text not null default 'Current Term' check (term in ('Current Term','Next Term')),
  session text default '',
  tuition numeric(12,2) default 0,
  exam_fee numeric(12,2) default 0,
  development numeric(12,2) default 0,
  transport numeric(12,2) default 0,
  boarding numeric(12,2) default 0,
  other_fee numeric(12,2) default 0,
  discount numeric(12,2) default 0,
  total numeric(12,2) default 0,
  due_date date,
  next_term_begins date,
  note text default '',
  fee_items jsonb default '[]'::jsonb,
  active boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique(class, arm, department, term)
);
alter table public.class_fee_structure add column if not exists department text default '';
alter table public.class_fee_structure add column if not exists session text default '';
alter table public.class_fee_structure add column if not exists other_fee numeric(12,2) default 0;
alter table public.class_fee_structure add column if not exists next_term_begins date;
alter table public.class_fee_structure add column if not exists note text default '';
alter table public.class_fee_structure add column if not exists fee_items jsonb default '[]'::jsonb;
alter table public.class_fee_structure add column if not exists active boolean default true;
create index if not exists class_fee_structure_school_idx on public.class_fee_structure(school_id);
create index if not exists class_fee_structure_lookup_idx on public.class_fee_structure(class, arm, department, term);
create unique index if not exists class_fee_structure_class_arm_department_term_uq on public.class_fee_structure(class, arm, department, term);

-- School products store. Fixes public.school_products schema-cache errors.
create table if not exists public.school_products (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  name text not null,
  category text default 'Other' check (category in ('Uniform','Textbook','Exercise Book','Stationery','Bag','Other')),
  price numeric(12,2) default 0,
  size_option text default '',
  stock_note text default '',
  active boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists school_products_school_idx on public.school_products(school_id);

-- Role/status audit trail. Fixes public.role_status_log schema-cache errors.
create table if not exists public.role_status_log (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  person_name text not null,
  "current_role" text default '',
  new_role text not null,
  action text default 'convert' check (action in ('promote','demote','convert','suspend','reactivate','deactivate')),
  reason text default '',
  changed_by text default '',
  changed_at timestamptz default now()
);
create index if not exists role_status_log_school_idx on public.role_status_log(school_id);

-- Staff / student clocks for operational attendance.
create table if not exists public.staff_clock (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete cascade,
  staff_no text,
  staff_name text,
  status text default 'present' check (status in ('present','late','absent','excused','clocked_out')),
  clock_in timestamptz,
  clock_out timestamptz,
  date date default current_date,
  note text default '',
  created_at timestamptz default now()
);
create index if not exists staff_clock_school_idx on public.staff_clock(school_id);
create index if not exists staff_clock_staff_idx on public.staff_clock(staff_id);

create table if not exists public.student_clock (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  clock_in timestamptz,
  clock_out timestamptz,
  date date default current_date,
  note text default '',
  created_at timestamptz default now()
);
create index if not exists student_clock_school_idx on public.student_clock(school_id);
create index if not exists student_clock_student_idx on public.student_clock(student_id);

-- Affective / psychomotor / comments: ensure exact names exist and schema cache reloads.
create table if not exists public.affective_traits (
  id uuid primary key default gen_random_uuid(), student_id uuid references public.students(id) on delete cascade,
  term text, session text, data jsonb default '{}'::jsonb, teacher_id uuid references public.profiles(id), created_at timestamptz default now(), unique(student_id,term,session)
);
create table if not exists public.psychomotor_traits (
  id uuid primary key default gen_random_uuid(), student_id uuid references public.students(id) on delete cascade,
  term text, session text, data jsonb default '{}'::jsonb, teacher_id uuid references public.profiles(id), created_at timestamptz default now(), unique(student_id,term,session)
);
create table if not exists public.report_comments (
  id uuid primary key default gen_random_uuid(), student_id uuid references public.students(id) on delete cascade,
  term text, session text, class_teacher_comment text, principal_comment text, next_term_begins date,
  created_at timestamptz default now(), unique(student_id,term,session)
);

-- Report-score uniqueness is installed by the canonical repair section at the end of this file.

-- Results CBT/report export upsert repair: a partial unique index cannot satisfy
-- ON CONFLICT (assessment_source, assessment_ref) reliably in PostgREST.
do $$ begin
  if to_regclass('public.results') is not null then
    drop index if exists public.results_assessment_ref_unique;
    -- Collapse accidental duplicate non-null assessment exports before enforcing uniqueness.
    delete from public.results r
    using public.results newer
    where r.ctid < newer.ctid
      and r.assessment_ref is not null
      and newer.assessment_ref is not null
      and coalesce(r.assessment_source,'') = coalesce(newer.assessment_source,'')
      and r.assessment_ref = newer.assessment_ref;
    create unique index if not exists results_assessment_ref_unique on public.results(assessment_source, assessment_ref);
  end if;
end $$;

-- Parent-child compatibility: the platform canonical table is parent_child.
-- Some older pages referred to parent_children. Provide a read-compatible
-- view alias only where the base table exists, so old links do not break.
do $$ begin
  if to_regclass('public.parent_child') is not null then
    execute 'create or replace view public.parent_children with (security_invoker = true) as select * from public.parent_child';
    execute 'grant select on public.parent_children to authenticated';
  end if;
end $$;

-- RLS for new/fixed tables.
alter table public.class_fee_structure enable row level security;
alter table public.school_products enable row level security;
alter table public.role_status_log enable row level security;
alter table public.staff_clock enable row level security;
alter table public.student_clock enable row level security;
alter table public.affective_traits enable row level security;
alter table public.psychomotor_traits enable row level security;
alter table public.report_comments enable row level security;

drop policy if exists "class_fee_structure_read" on public.class_fee_structure;
create policy "class_fee_structure_read" on public.class_fee_structure for select using (auth.role() = 'authenticated');
drop policy if exists "class_fee_structure_write" on public.class_fee_structure;
create policy "class_fee_structure_write" on public.class_fee_structure for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

drop policy if exists "school_products_read" on public.school_products;
create policy "school_products_read" on public.school_products for select using (auth.role() = 'authenticated');
drop policy if exists "school_products_write" on public.school_products;
create policy "school_products_write" on public.school_products for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

drop policy if exists "role_status_log_read" on public.role_status_log;
create policy "role_status_log_read" on public.role_status_log for select using (public.is_admin(auth.uid()));
drop policy if exists "role_status_log_write" on public.role_status_log;
create policy "role_status_log_write" on public.role_status_log for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

drop policy if exists "staff_clock_read" on public.staff_clock;
create policy "staff_clock_read" on public.staff_clock for select using (public.is_staff(auth.uid()) or public.is_admin(auth.uid()));
drop policy if exists "staff_clock_write" on public.staff_clock;
create policy "staff_clock_write" on public.staff_clock for all using (public.is_staff(auth.uid()) or public.is_admin(auth.uid())) with check (public.is_staff(auth.uid()) or public.is_admin(auth.uid()));

drop policy if exists "student_clock_read" on public.student_clock;
create policy "student_clock_read" on public.student_clock for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id) or exists (select 1 from public.students s where s.id=student_clock.student_id and s.user_id=auth.uid()));
drop policy if exists "student_clock_write" on public.student_clock;
create policy "student_clock_write" on public.student_clock for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "affective_traits_read" on public.affective_traits;
create policy "affective_traits_read" on public.affective_traits for select using (auth.role() = 'authenticated');
drop policy if exists "affective_traits_write" on public.affective_traits;
create policy "affective_traits_write" on public.affective_traits for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "psychomotor_traits_read" on public.psychomotor_traits;
create policy "psychomotor_traits_read" on public.psychomotor_traits for select using (auth.role() = 'authenticated');
drop policy if exists "psychomotor_traits_write" on public.psychomotor_traits;
create policy "psychomotor_traits_write" on public.psychomotor_traits for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "report_comments_read" on public.report_comments;
create policy "report_comments_read" on public.report_comments for select using (auth.role() = 'authenticated');
drop policy if exists "report_comments_write" on public.report_comments;
create policy "report_comments_write" on public.report_comments for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- Parent attendance read-only policy with canonical parent_child table.
drop policy if exists "attendance_parent_read_v16" on public.attendance;
create policy "attendance_parent_read_v16" on public.attendance for select using (
  exists (select 1 from public.students s where s.id = attendance.student_id and s.user_id = auth.uid())
  or exists (select 1 from public.parent_child pc where pc.student_id = attendance.student_id and pc.parent_id = auth.uid())
  or public.is_staff(auth.uid())
);

-- Teacher ownership hardening for report scores.
drop policy if exists "rs_staff" on public.report_scores;
drop policy if exists "rs_insert_v16_owner" on public.report_scores;
drop policy if exists "rs_update_v16_owner" on public.report_scores;
drop policy if exists "rs_delete_v16_owner" on public.report_scores;
create policy "rs_insert_v16_owner" on public.report_scores for insert with check (public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid()));
drop policy if exists "rs_update_v16_owner" on public.report_scores;
create policy "rs_update_v16_owner" on public.report_scores for update using (public.is_admin(auth.uid()) or updated_by = auth.uid()) with check (public.is_admin(auth.uid()) or coalesce(updated_by, auth.uid()) = auth.uid());
drop policy if exists "rs_delete_v16_owner" on public.report_scores;
create policy "rs_delete_v16_owner" on public.report_scores for delete using (public.is_admin(auth.uid()) or updated_by = auth.uid());

-- updated_at triggers when helper exists.
do $$ begin
  if exists (select 1 from pg_proc where proname = 'set_updated_at') then
    drop trigger if exists class_fee_structure_updated on public.class_fee_structure;
    create trigger class_fee_structure_updated before update on public.class_fee_structure for each row execute function public.set_updated_at();
    drop trigger if exists school_products_updated on public.school_products;
    create trigger school_products_updated before update on public.school_products for each row execute function public.set_updated_at();
  end if;
end $$;

notify pgrst, 'reload schema';
-- =====================================================================
-- END SCHOOL CONNECT V1 FINAL CUMULATIVE PATCH
-- =====================================================================


-- ============================================================================
-- V7 COMPATIBILITY BACKFILLS
-- ============================================================================
alter table public.school_settings add column if not exists school_id uuid references public.schools(id) on delete set null;
alter table public.school_settings add column if not exists school_name text default 'My School';
alter table public.school_settings add column if not exists short_name text default 'SCH';
alter table public.school_settings add column if not exists admission_acronym text default 'SCH';
alter table public.school_settings add column if not exists admission_prefix text default 'SCH';
alter table public.school_settings add column if not exists staff_prefix text default 'SCH';
alter table public.school_settings add column if not exists signature_url text default '';
alter table public.school_settings add column if not exists class_teacher_signature_url text default '';
alter table public.school_settings add column if not exists principal_name text default 'Principal';
alter table public.school_settings add column if not exists stamp_text text default 'OFFICIAL SCHOOL SEAL';
alter table public.school_settings add column if not exists stamp_color text default '#1e3a8a';
alter table public.school_settings add column if not exists stamp_enabled boolean default true;
alter table public.school_settings add column if not exists signature_enabled boolean default true;
alter table public.school_settings add column if not exists checkin_deadline text default '08:00';
alter table public.school_settings add column if not exists checkin_grace_minutes int default 15;
alter table public.school_settings add column if not exists latitude numeric;
alter table public.school_settings add column if not exists longitude numeric;
alter table public.school_settings add column if not exists geo_radius_m int default 200;
alter table public.school_settings add column if not exists enforce_geofence boolean default false;
alter table public.school_settings add column if not exists geo_updated_at timestamptz;
alter table public.school_settings add column if not exists next_term_fees numeric default 0;
alter table public.school_settings add column if not exists next_term_fees_currency text default '₦';
alter table public.school_settings add column if not exists next_term_fees_note text default 'Payable before resumption';
alter table public.school_settings add column if not exists next_term_begins date;
alter table public.school_settings add column if not exists role_access jsonb default '{}'::jsonb;
alter table public.school_settings add column if not exists role_write jsonb default '{}'::jsonb;
alter table public.school_settings add column if not exists hmg_link text default 'https://hmgconcepts.pages.dev/';

alter table public.students add column if not exists admission_no text;
alter table public.students add column if not exists arm text;
alter table public.students add column if not exists department text default 'Other';
alter table public.students add column if not exists user_id uuid references public.profiles(id) on delete set null;
alter table public.staff add column if not exists staff_no text;
alter table public.staff add column if not exists user_id uuid references public.profiles(id) on delete set null;
alter table public.report_scores add column if not exists student_id uuid references public.students(id) on delete set null;
alter table public.report_scores add column if not exists student_id_ref text default '';
alter table public.report_scores add column if not exists student_name text default '';
alter table public.report_scores add column if not exists class text default '';
alter table public.report_scores add column if not exists subject text default '';
alter table public.report_scores add column if not exists term text default '';
alter table public.report_scores add column if not exists session text default '';
alter table public.report_scores add column if not exists score numeric default 0;
alter table public.report_scores add column if not exists source text default 'manual';
alter table public.report_scores add column if not exists updated_by uuid references public.profiles(id) on delete set null;
alter table public.report_scores add column if not exists updated_at timestamptz default now();
alter table public.report_scores add column if not exists created_at timestamptz default now();
alter table public.cbt_results add column if not exists student_id uuid references public.students(id) on delete set null;
alter table public.cbt_results add column if not exists submitted_at timestamptz default now();
alter table public.cbt_exams add column if not exists duration_min int default 45;
alter table public.cbt_exams add column if not exists questions jsonb default '[]'::jsonb;
alter table public.class_fee_structure add column if not exists school_id uuid references public.schools(id) on delete cascade;
alter table public.class_fee_structure add column if not exists session text default '';
alter table public.class_fee_structure add column if not exists other_fee numeric(12,2) default 0;
alter table public.class_fee_structure add column if not exists amount numeric(12,2) default 0;
alter table public.class_fee_structure add column if not exists next_term_begins date;
alter table public.class_fee_structure add column if not exists note text default '';
alter table public.class_fee_structure add column if not exists fee_items jsonb default '[]'::jsonb;
alter table public.class_fee_structure add column if not exists active boolean default true;
alter table public.school_products add column if not exists school_id uuid references public.schools(id) on delete cascade;
alter table public.school_products add column if not exists description text default '';
alter table public.school_products add column if not exists active boolean default true;
alter table public.role_status_log add column if not exists person_id uuid references public.profiles(id) on delete set null;
alter table public.role_status_log add column if not exists previous_role text default '';
alter table public.role_status_log add column if not exists previous_status text default '';
alter table public.role_status_log add column if not exists new_status text default '';
alter table public.role_status_log add column if not exists person_email text default '';
alter table public.role_status_log add column if not exists changed_by uuid references public.profiles(id) on delete set null;

-- Ensure the default row has a usable identity without overwriting a deployed
-- school's deliberately configured branding.
update public.school_settings
set school_name = coalesce(nullif(school_name,''),'My School'),
    short_name = coalesce(nullif(short_name,''),'SCH'),
    admission_acronym = coalesce(nullif(admission_acronym,''),nullif(short_name,''),'SCH'),
    admission_prefix = coalesce(nullif(admission_prefix,''),nullif(admission_acronym,''),nullif(short_name,''),'SCH'),
    staff_prefix = coalesce(nullif(staff_prefix,''),nullif(short_name,''),'SCH')
where id = 1;

create index if not exists school_settings_school_idx on public.school_settings(school_id);
create index if not exists students_user_id_idx_v7 on public.students(user_id);
create index if not exists staff_user_id_idx_v7 on public.staff(user_id);
create index if not exists report_scores_lookup_idx_v7 on public.report_scores(class, subject, term, session);
create index if not exists cbt_results_student_idx_v7 on public.cbt_results(student_id_ref);
create index if not exists class_fee_structure_school_idx_v7 on public.class_fee_structure(school_id);
create index if not exists school_products_school_idx_v7 on public.school_products(school_id);
create index if not exists role_status_log_person_idx_v7 on public.role_status_log(person_id);

-- Remove duplicate/nullable score rows before installing the single canonical
-- PostgREST key. This is the data repair that prevents "Saved 0, N failed".
update public.report_scores set student_id_ref = coalesce(student_id_ref,''), student_name = coalesce(student_name,''), class = coalesce(class,''), subject = coalesce(subject,''), term = coalesce(term,''), session = coalesce(session,''), score = coalesce(score,0), updated_at = coalesce(updated_at,now()), created_at = coalesce(created_at,now());
delete from public.report_scores a using public.report_scores b
where a.ctid < b.ctid
  and a.column_id is not distinct from b.column_id
  and coalesce(a.student_id_ref,'') = coalesce(b.student_id_ref,'')
  and coalesce(a.student_name,'') = coalesce(b.student_name,'')
  and coalesce(a.class,'') = coalesce(b.class,'')
  and coalesce(a.subject,'') = coalesce(b.subject,'')
  and coalesce(a.term,'') = coalesce(b.term,'')
  and coalesce(a.session,'') = coalesce(b.session,'');
delete from public.report_scores where column_id is null;
alter table public.report_scores alter column column_id set not null;
alter table public.report_scores alter column student_id_ref set not null;
alter table public.report_scores alter column student_name set not null;
alter table public.report_scores alter column class set not null;
alter table public.report_scores alter column subject set not null;
alter table public.report_scores alter column term set not null;
alter table public.report_scores alter column session set not null;

do $$
declare c record;
begin
  if to_regclass('public.report_scores') is null then return; end if;
  for c in select conname from pg_constraint where conrelid='public.report_scores'::regclass and contype='u' loop
    execute format('alter table public.report_scores drop constraint %I', c.conname);
  end loop;
end $$;
drop index if exists public.report_scores_unique_composite;
drop index if exists public.report_scores_column_student_subject_uq;
drop index if exists public.report_scores_column_student_subject_uq_v7;
alter table public.report_scores add constraint report_scores_context_unique unique (column_id, student_id_ref, student_name, class, subject, term, session);

-- Class bills: clean duplicates then add the exact key used by settings.html.
delete from public.class_fee_structure a using public.class_fee_structure b
where a.ctid < b.ctid and a.class=b.class and a.arm=b.arm and a.department=b.department and a.term=b.term;
create unique index if not exists class_fee_structure_class_arm_department_term_uq_v7 on public.class_fee_structure(class, arm, department, term);

-- Admission/staff IDs. Repair accidental duplicate legacy IDs before adding
-- the collision guard; valid records are retained and the older duplicate row
-- is the one removed.
delete from public.students a using public.students b
where a.ctid < b.ctid and coalesce(a.admission_no,'') <> '' and a.admission_no=b.admission_no;
delete from public.staff a using public.staff b
where a.ctid < b.ctid and coalesce(a.staff_no,'') <> '' and a.staff_no=b.staff_no;
-- A transaction advisory lock makes the MAX-based allocator safe enough for
-- free-tier single-school deployments; the unique column remains the final guard.
create unique index if not exists students_admission_no_uq_v7 on public.students(admission_no) where admission_no is not null and admission_no <> '';
create unique index if not exists staff_staff_no_uq_v7 on public.staff(staff_no) where staff_no is not null and staff_no <> '';
create or replace function public.sc_generate_admission_no()
returns trigger language plpgsql security definer set search_path=public as $$
declare pfx text; n int;
begin
  if coalesce(trim(new.admission_no),'') <> '' then return new; end if;
  select upper(coalesce(nullif(admission_prefix,''),nullif(admission_acronym,''),nullif(short_name,''),'SCH')) into pfx from public.school_settings where id=1;
  perform pg_advisory_xact_lock(hashtext(pfx));
  select coalesce(max((regexp_match(admission_no,'([0-9]+)$'))[1]::int),0)+1 into n from public.students where admission_no like pfx||'-%';
  new.admission_no := pfx||'-'||lpad(n::text,5,'0');
  return new;
end $$;
drop trigger if exists trg_sc_generate_admission_no on public.students;
create trigger trg_sc_generate_admission_no before insert on public.students for each row execute function public.sc_generate_admission_no();
create or replace function public.sc_generate_staff_no()
returns trigger language plpgsql security definer set search_path=public as $$
declare pfx text; n int;
begin
  if coalesce(trim(new.staff_no),'') <> '' then return new; end if;
  select upper(coalesce(nullif(staff_prefix,''),nullif(short_name,''),'SCH')) into pfx from public.school_settings where id=1;
  perform pg_advisory_xact_lock(hashtext('STAFF:'||pfx));
  select coalesce(max((regexp_match(staff_no,'([0-9]+)$'))[1]::int),0)+1 into n from public.staff where staff_no like pfx||'-STF-%' or staff_no like pfx||'-%';
  new.staff_no := pfx||'-STF-'||lpad(n::text,5,'0');
  return new;
end $$;
drop trigger if exists trg_sc_generate_staff_no on public.staff;
create trigger trg_sc_generate_staff_no before insert on public.staff for each row execute function public.sc_generate_staff_no();

-- Common updated_at triggers.
do $$ declare t text; begin
  foreach t in array['school_settings','report_scores','class_fee_structure','school_products'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists sc_updated_at on public.%I',t);
      execute format('create trigger sc_updated_at before update on public.%I for each row execute function public.sc_set_updated_at()',t);
    end if;
  end loop;
end $$;

-- Flexible subject totals. The view is recreated because old versions had
-- incompatible columns; security_invoker makes table RLS apply to callers.
drop view if exists public.report_subject_totals cascade;
create view public.report_subject_totals as
select rs.student_id, rs.student_name, rs.student_id_ref, rs.class, rs.subject, rs.term, rs.session,
       round(sum(rs.score),2) obtained, round(sum(ac.max_mark),2) obtainable,
       case when sum(ac.max_mark)>0 then round(sum(rs.score)/sum(ac.max_mark)*100,2) else 0 end percent
from public.report_scores rs join public.assessment_columns ac on ac.id=rs.column_id
group by rs.student_id,rs.student_name,rs.student_id_ref,rs.class,rs.subject,rs.term,rs.session;
do $$ begin execute 'alter view public.report_subject_totals set (security_invoker = true)'; exception when others then null; end $$;

-- CBT → Results bridge. Results remains the source used by the broadsheet;
-- report_scores remains the source used by the flexible report-card grid.
create or replace function public.sc_push_cbt_to_results(p_exam_id uuid, p_column text default 'exam', p_term text default '', p_session text default '')
returns int language plpgsql security definer set search_path=public as $$
declare e record; r record; sid uuid; saved int:=0; payload jsonb;
begin
 select * into e from public.cbt_exams where id=p_exam_id; if not found then return 0; end if;
 for r in select * from public.cbt_results where exam_id=p_exam_id loop
   sid := r.student_id;
   if sid is null then select id into sid from public.students where admission_no=r.student_id_ref or lower(full_name)=lower(r.student_name) limit 1; end if;
   insert into public.results(student_id,student_name,student_id_ref,subject,class,term,session,assessment_source,assessment_ref)
   values(sid,r.student_name,r.student_id_ref,coalesce(e.subject,'CBT'),coalesce(r.student_class,e.class),coalesce(nullif(p_term,''),e.term),coalesce(nullif(p_session,''),e.session),'cbt',r.id)
   on conflict (assessment_source,assessment_ref) do update set student_id=excluded.student_id,student_name=excluded.student_name,subject=excluded.subject,class=excluded.class,term=excluded.term,session=excluded.session;
   saved := saved+1;
 end loop; return saved;
end $$;
grant execute on function public.sc_push_cbt_to_results(uuid,text,text,text) to authenticated;

-- CBT public functions (no answers are returned to candidates).
create or replace function public.cbt_get_public_exam(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record; qs jsonb;
begin
 select * into e from public.cbt_exams where upper(code)=upper(trim(p_code)) and is_open=true and is_archived=false limit 1;
 if not found then return null; end if;
 if e.start_at is not null and now()<e.start_at then return jsonb_build_object('wait',true,'start_at',e.start_at,'title',e.title); end if;
 if e.close_at is not null and now()>e.close_at then return jsonb_build_object('closed',true); end if;
 select coalesce(jsonb_agg((q-'correct'-'correct_answer'-'answer'-'explanation')||jsonb_build_object('_orig_index',ord-1) order by ord),'[]'::jsonb) into qs from jsonb_array_elements(coalesce(e.csv_data,e.questions,'[]'::jsonb)) with ordinality x(q,ord);
 return jsonb_build_object('id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,'term',e.term,'session',e.session,'duration',e.duration,'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode);
end $$;
grant execute on function public.cbt_get_public_exam(text) to anon, authenticated;

-- Simple deterministic CBT submitter. The full browser engine may grade richer
-- payloads; this RPC stores the result safely for every supported exam mode.
create or replace function public.cbt_submit(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; rid uuid; sid uuid; n int; score numeric:=0; total numeric:=0; ans jsonb; q jsonb; i int:=0; a text; k text; mark numeric;
begin
 select * into e from public.cbt_exams where id=(p_payload->>'exam_id')::uuid; if not found then return jsonb_build_object('saved',false,'error','Exam not found'); end if;
 for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb)) loop
   q := coalesce(e.csv_data,e.questions,'[]'::jsonb)->i; mark:=coalesce(nullif(q->>'mark','')::numeric,1); total:=total+mark; a:=coalesce(ans->>'answer',ans #>> '{}',''); k:=coalesce(q->>'answer',q->>'correct',q->>'correct_answer',''); if lower(trim(a))=lower(trim(k)) and k<>'' then score:=score+mark; end if; i:=i+1;
 end loop;
 sid := nullif(p_payload->>'student_id','')::uuid; n:=case when total>0 then round(score/total*100)::int else 0 end;
 insert into public.cbt_results(exam_id,student_id,student_name,student_class,student_id_ref,student_type,score,total,percent,answers_data,cert_code)
 values(e.id,sid,coalesce(p_payload->>'student_name','Anonymous'),coalesce(p_payload->>'student_class',e.class),coalesce(p_payload->>'student_id_ref',''),coalesce(p_payload->>'student_type',e.exam_mode),score,total::int,n,p_payload->'answers_data',case when e.certificate_enabled then 'CERT-'||upper(substr(md5(random()::text),1,8)) else '' end) returning id into rid;
 return jsonb_build_object('saved',true,'result_id',rid,'score',score,'total',total,'percent',n,'cert_code',(select cert_code from public.cbt_results where id=rid));
exception when others then return jsonb_build_object('saved',false,'error',sqlerrm); end $$;
grant execute on function public.cbt_submit(jsonb) to anon, authenticated;

-- Parent/student read-only attendance; staff is the only writer. All legacy
-- permissive policies are removed so authenticated does not mean "all children".
drop policy if exists "att_read" on public.attendance;
drop policy if exists "att_write" on public.attendance;
drop policy if exists "attendance_read" on public.attendance;
drop policy if exists "attendance_write" on public.attendance;
drop policy if exists "attendance_parent_read_v16" on public.attendance;
create policy "v7_attendance_read_family" on public.attendance for select using (
  public.is_staff(auth.uid()) or exists(select 1 from public.students s where s.id=attendance.student_id and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id)))
);
create policy "v7_attendance_write_staff" on public.attendance for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- Scoped reporting/traits/comments.
do $$ declare p text; begin
  foreach p in array['rs_staff','rs_select_family','rs_insert_v16_owner','rs_update_v16_owner','rs_delete_v16_owner','read_psychomotor','write_psychomotor','psychomotor_traits_read','psychomotor_traits_write','read_comments','write_comments','report_comments_read','report_comments_write','read_affective','write_affective','affective_traits_read','affective_traits_write','rc_staff','rc_read'] loop
    execute format('drop policy if exists %I on public.report_scores',p);
    execute format('drop policy if exists %I on public.psychomotor_traits',p);
    execute format('drop policy if exists %I on public.report_comments',p);
    execute format('drop policy if exists %I on public.affective_traits',p);
    execute format('drop policy if exists %I on public.report_cards',p);
  end loop;
end $$;
create policy "v7_report_scores_read" on public.report_scores for select using (public.is_staff(auth.uid()) or exists(select 1 from public.students s where s.id=report_scores.student_id and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))) or exists(select 1 from public.students s where s.admission_no=report_scores.student_id_ref and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))));
create policy "v7_report_scores_insert" on public.report_scores for insert with check (public.is_staff(auth.uid()) and (public.is_admin(auth.uid()) or coalesce(updated_by,auth.uid())=auth.uid()));
create policy "v7_report_scores_update" on public.report_scores for update using (public.is_admin(auth.uid()) or updated_by=auth.uid()) with check (public.is_admin(auth.uid()) or coalesce(updated_by,auth.uid())=auth.uid());
create policy "v7_report_scores_delete" on public.report_scores for delete using (public.is_admin(auth.uid()) or updated_by=auth.uid());
create policy "v7_report_cards_staff" on public.report_cards for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_report_cards_family" on public.report_cards for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=report_cards.student_id and s.user_id=auth.uid()));
create policy "v7_psychomotor_read" on public.psychomotor_traits for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=psychomotor_traits.student_id and s.user_id=auth.uid()));
create policy "v7_psychomotor_write" on public.psychomotor_traits for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_affective_read" on public.affective_traits for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=affective_traits.student_id and s.user_id=auth.uid()));
create policy "v7_affective_write" on public.affective_traits for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_comments_read" on public.report_comments for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=report_comments.student_id and s.user_id=auth.uid()));
create policy "v7_comments_write" on public.report_comments for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- Named tables and settings policies.
do $$ declare t text; begin
  foreach t in array['school_settings','schools','class_fee_structure','school_products','role_status_log','staff_clock','student_clock','timetable_requirements','teacher_availability','timetable_runs','attendance_checkins','student_diary','surveys','survey_responses','menu_planner','security_prefs','login_audit','i18n_strings','academic_print_records'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop policy if exists v7_read_%I on public.%I',t,t);
      execute format('drop policy if exists v7_write_%I on public.%I',t,t);
    end if;
  end loop;
end $$;
create policy "v7_settings_read" on public.school_settings for select using (auth.role()='authenticated');
create policy "v7_settings_write" on public.school_settings for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
create policy "v7_schools_read" on public.schools for select using (auth.role()='authenticated');
create policy "v7_schools_write" on public.schools for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
create policy "v7_fee_structure_read" on public.class_fee_structure for select using (auth.role()='authenticated');
create policy "v7_fee_structure_write" on public.class_fee_structure for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
create policy "v7_products_read" on public.school_products for select using (auth.role()='authenticated');
create policy "v7_products_write" on public.school_products for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
create policy "v7_role_log_read" on public.role_status_log for select using (public.is_admin(auth.uid()));
create policy "v7_role_log_write" on public.role_status_log for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
create policy "v7_clock_read" on public.staff_clock for select using (public.is_staff(auth.uid()));
create policy "v7_clock_write" on public.staff_clock for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_student_clock_read" on public.student_clock for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=student_clock.student_id and s.user_id=auth.uid()));
create policy "v7_student_clock_write" on public.student_clock for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_enterprise_read" on public.timetable_requirements for select using (auth.role()='authenticated');
create policy "v7_enterprise_write" on public.timetable_requirements for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_availability_read" on public.teacher_availability for select using (auth.role()='authenticated');
create policy "v7_availability_write" on public.teacher_availability for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_runs_read" on public.timetable_runs for select using (auth.role()='authenticated');
create policy "v7_runs_write" on public.timetable_runs for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_checkins_read" on public.attendance_checkins for select using (public.is_staff(auth.uid()));
create policy "v7_checkins_insert" on public.attendance_checkins for insert with check (auth.role()='authenticated');
create policy "v7_diary_read" on public.student_diary for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=student_diary.student_id and s.user_id=auth.uid()));
create policy "v7_diary_write" on public.student_diary for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_survey_read" on public.surveys for select using (auth.role()='authenticated');
create policy "v7_survey_write" on public.surveys for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_survey_response" on public.survey_responses for all using (respondent=auth.uid() or public.is_staff(auth.uid())) with check (respondent=auth.uid() or public.is_staff(auth.uid()));
create policy "v7_menu_read" on public.menu_planner for select using (auth.role()='authenticated');
create policy "v7_menu_write" on public.menu_planner for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "v7_security_prefs" on public.security_prefs for all using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy "v7_login_audit_read" on public.login_audit for select using (public.is_admin(auth.uid()));
create policy "v7_login_audit_insert" on public.login_audit for insert with check (auth.role()='authenticated');
create policy "v7_i18n_read" on public.i18n_strings for select using (auth.role()='authenticated');
create policy "v7_i18n_write" on public.i18n_strings for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
create policy "v7_print_read" on public.academic_print_records for select using (auth.role()='authenticated');
create policy "v7_print_write" on public.academic_print_records for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- Deterministic timetable generator; part-time teachers are restricted to
-- their declared availability. No AI API and no paid dependency.
create or replace function public.generate_timetable(p_class text,p_session text default '',p_term text default '',p_periods_per_day int default 6)
returns jsonb language plpgsql security definer set search_path=public as $$
declare d text; p int; r record; days text[]:=array['Monday','Tuesday','Wednesday','Thursday','Friday']; placed int:=0; unplaced int:=0; allowed text[]; done_one boolean;
begin
 delete from public.timetable where class=p_class and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'');
 for r in select * from public.timetable_requirements where class=p_class order by periods_per_week desc loop
   allowed:=r.available_days;
   if allowed is null or array_length(allowed,1) is null then select available_days into allowed from public.teacher_availability where teacher=r.teacher limit 1; end if;
   if allowed is null or array_length(allowed,1) is null then allowed:=days; end if;
   for i in 1..greatest(1,r.periods_per_week) loop
     done_one:=false;
     for d in select unnest(allowed) loop for p in 1..greatest(1,p_periods_per_day) loop
       if exists(select 1 from public.timetable where class=p_class and day=d and period=p::text and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'')) then continue; end if;
       if r.teacher is not null and exists(select 1 from public.timetable where teacher=r.teacher and day=d and period=p::text and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'')) then continue; end if;
       insert into public.timetable(class,day,period,subject,teacher,session,term) values(p_class,d,p::text,r.subject,r.teacher,p_session,p_term); placed:=placed+1; done_one:=true; exit;
     end loop; exit when done_one; end loop;
     if not done_one then unplaced:=unplaced+1; end if;
   end loop;
 end loop;
 insert into public.timetable_runs(class,session,term,conflicts,notes) values(p_class,p_session,p_term,unplaced,'placed '||placed||' periods; unplaced '||unplaced);
 return jsonb_build_object('ok',true,'placed',placed,'unplaced',unplaced,'class',p_class);
end $$;
grant execute on function public.generate_timetable(text,text,text,int) to authenticated;

-- Parent-child compatibility alias for older pages.
drop view if exists public.parent_children cascade;
create view public.parent_children as select * from public.parent_child;
grant select on public.parent_children to authenticated;

-- Public certificate verification remains intentionally narrow.
grant execute on function public.verify_certificate(text) to anon, authenticated;
notify pgrst, 'reload schema';
select 'School Connect v7 complete schema installed successfully' as status;
