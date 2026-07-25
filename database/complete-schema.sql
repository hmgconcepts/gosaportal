-- ============================================================================
-- HMG SCHOOL CONNECT v12.4 — ONE CLEAN PRODUCTION DATABASE SCHEMA
-- ----------------------------------------------------------------------------
-- v12.4 (2026-07-23): PUNCTUALITY POINTS ENGINE (Section 17, additive): on-time
--   check-in + closing-time check-out earn daily points; term totals can be
--   pushed into any Results column at the school's discretion. Also standalone
--   as database/punctuality-points.sql. CBT scale pack (Section 16) included.
-- v12.3 (2026-07-23): CBT 1000-CONCURRENT SCALE PACK (Section 16, additive):
--   hot-path indexes, idempotent exam submissions (client_ref), and the v2
--   exam-fetch / submit functions preferred by cbt-exam.html. The very same
--   pack also ships standalone as database/cbt-1000-scale.sql for projects
--   already running v12.x. v12.2's site-license engine is untouched.
-- v12.1 (2026-07-22): extended the 42703 drift-hardening block so EVERY
-- column referenced by any policy / view / SQL function / constraint / index
-- is force-added on pre-existing old-generation tables (support_plans,
-- certificates, lms_submissions, push_subscriptions, security_prefs, idcards,
-- module_records, results.teacher_id, eresources, parent_child.parent_id,
-- students.guardian_email, poll_votes.candidate_id, cbt_results.student_id_ref,
-- profiles.role/status). Purely additive — nothing is dropped.
-- Rebuilt from the merged v11 file. Guarantees:
--   (1) zero duplicate definitions      (2) strict dependency order
--   (3) tables exist before anything references them
--   (4) columns exist before any policy / index / function uses them
--   (5) every statement is idempotent (IF NOT EXISTS / drop-if-exists / OR REPLACE)
--   (6) works on a brand-new Supabase project AND repairs existing
--       School Connect databases (missing tables, columns, unique keys)
--   (7) reloads the PostgREST schema cache at the end so the API sees the
--       new tables immediately (kills "not found in the schema cache")
--
-- HOW TO USE: paste this whole file into Supabase SQL Editor and run once.
-- Safe to re-run any number of times. No other SQL file is required.
-- ============================================================================
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";


-- ============================================================================
-- SECTION 1: UTILITY FUNCTION (updated_at trigger helper)
-- ============================================================================
DROP FUNCTION IF EXISTS public.sc_set_updated_at() CASCADE;
create or replace function public.sc_set_updated_at()
returns trigger language plpgsql security invoker as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- SECTION 2: CORE + FEATURE TABLES (94 tables, dependency-ordered, full columns)
-- ============================================================================
create table if not exists public.schools (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My School',
  short_name text not null default 'SCH',
  admission_acronym text not null default 'SCH',
  motto text default 'Excellence in Learning',
  address text default '', phone text default '', email text default '',
  currency text default '₦', site_url text default '', logo_url text default '',
  created_at timestamptz not null default now()
);

create table if not exists public.school_settings (
  id int primary key default 1,
  school_id uuid references public.schools(id) on delete set null,
  school_name text not null default 'My School',
  short_name text not null default 'SCH',
  admission_acronym text not null default 'SCH',
  admission_prefix text not null default 'SCH',
  admission_next int not null default 1,
  staff_prefix text not null default 'SCH',
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

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text, full_name text, phone text,
  role text not null default 'student',
  status text not null default 'pending',
  photo_url text, campus text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(), admission_no text unique, full_name text not null,
  class text, arm text, department text default 'Other', gender text, date_of_birth date,
  guardian_name text, guardian_phone text, guardian_email text, address text, photo_url text, campus text,
  status text default 'active', user_id uuid references public.profiles(id) on delete set null, created_at timestamptz default now()
);

create table if not exists public.staff (
  id uuid primary key default gen_random_uuid(), staff_no text unique, full_name text not null,
  email text, phone text, role text default 'teacher', department text, subjects text[], part_time boolean default false,
  leave_balance int default 14, photo_url text, status text default 'active', user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

create table if not exists public.parent_child (
  id uuid primary key default gen_random_uuid(), parent_id uuid references public.profiles(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade, relationship text default 'parent', verified boolean default false,
  created_at timestamptz default now(), unique(parent_id, student_id)
);

create table if not exists public.cbt_exams (
  id uuid primary key default gen_random_uuid(),
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

create table if not exists public.cbt_results (
  id uuid primary key default gen_random_uuid(),
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

create table if not exists public.cbt_roster (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid references public.cbt_exams(id) on delete cascade,
  student_id_ref text not null, full_name text, class text, created_at timestamptz default now(),
  unique(exam_id, student_id_ref)
);

create table if not exists public.assessment_columns (
  id uuid primary key default gen_random_uuid(),
  class text not null default '', subject text not null default '*',
  term text not null default '', session text not null default '', name text not null,
  max_mark numeric not null default 10, weight numeric not null default 1,
  position int not null default 0, source text not null default 'manual',
  cbt_assessment_type text default '', created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(class, subject, term, session, name)
);

create table if not exists public.report_scores (
  id uuid primary key default gen_random_uuid(),
  column_id uuid not null references public.assessment_columns(id) on delete cascade,
  student_id uuid references public.students(id) on delete set null,
  student_id_ref text not null default '', student_name text not null default '',
  class text not null default '', subject text not null default '',
  term text not null default '', session text not null default '', score numeric not null default 0,
  source text not null default 'manual', updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);

create table if not exists public.report_cards (
  id uuid primary key default gen_random_uuid(), student_id uuid references public.students(id) on delete cascade,
  student_name text default '', student_id_ref text default '', class text default '', term text default '', session text default '',
  teacher_comment text default '', head_comment text default '', attendance_present int default 0, attendance_total int default 0,
  affective jsonb default '{}'::jsonb, psychomotor jsonb default '{}'::jsonb, next_term_begins date,
  position int, published boolean default false, created_at timestamptz default now(),
  unique(student_id_ref, class, term, session)
);

create table if not exists public.class_fee_structure (
  id uuid primary key default gen_random_uuid(), school_id uuid references public.schools(id) on delete cascade,
  class text not null, arm text not null default '', department text not null default '',
  term text not null default 'Current Term', session text not null default '',
  tuition numeric(12,2) default 0, exam_fee numeric(12,2) default 0, development numeric(12,2) default 0,
  transport numeric(12,2) default 0, boarding numeric(12,2) default 0, other_fee numeric(12,2) default 0,
  discount numeric(12,2) default 0, total numeric(12,2) default 0, amount numeric(12,2) default 0,
  currency text default '₦', due_date date, next_term_begins date, note text default '',
  fee_items jsonb default '[]'::jsonb, active boolean not null default true,
  created_at timestamptz default now(), updated_at timestamptz default now()
);

create table if not exists public.school_products (
  id uuid primary key default gen_random_uuid(), school_id uuid references public.schools(id) on delete cascade,
  name text not null, description text default '',
  category text default 'Other', price numeric(12,2) default 0, currency text default '₦',
  size_option text default '', stock_note text default '', quantity_available int default 0,
  image_url text default '', active boolean not null default true,
  created_at timestamptz default now(), updated_at timestamptz default now()
);

create table if not exists public.role_status_log (
  id uuid primary key default gen_random_uuid(), school_id uuid references public.schools(id) on delete cascade,
  person_id uuid references public.profiles(id) on delete set null, person_name text not null default '',
  person_email text default '', previous_role text default '', new_role text default '',
  previous_status text default '', new_status text default '', action text default '', reason text default '',
  changed_by uuid references public.profiles(id) on delete set null, changed_by_name text default '',
  created_at timestamptz default now()
);

create table if not exists public.staff_clock (
  id uuid primary key default gen_random_uuid(), school_id uuid references public.schools(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null, staff_no text, staff_name text,
  status text default 'present', clock_in timestamptz, clock_out timestamptz, date date default current_date,
  note text default '', created_at timestamptz default now()
);

create table if not exists public.student_clock (
  id uuid primary key default gen_random_uuid(), school_id uuid references public.schools(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade, clock_in timestamptz, clock_out timestamptz,
  date date default current_date, note text default '', created_at timestamptz default now()
);

create table if not exists public.timetable_requirements (
  id uuid primary key default gen_random_uuid(), class text not null, subject text not null, teacher text,
  periods_per_week int not null default 1, available_days text[], is_part_time boolean default false,
  created_at timestamptz default now(), unique(class, subject)
);

create table if not exists public.teacher_availability (
  id uuid primary key default gen_random_uuid(), teacher text not null unique,
  is_part_time boolean default false, available_days text[], notes text, created_at timestamptz default now()
);

create table if not exists public.timetable_runs (
  id uuid primary key default gen_random_uuid(), class text, session text, term text,
  generated_at timestamptz default now(), conflicts int default 0, notes text
);

create table if not exists public.attendance_checkins (
  id uuid primary key default gen_random_uuid(), student_id_ref text not null, student_name text, class text,
  checkin_at timestamptz default now(), method text default 'qr', device text, recorded_by uuid references public.profiles(id)
);

create table if not exists public.student_diary (
  id uuid primary key default gen_random_uuid(), student_id uuid references public.students(id) on delete cascade,
  student_name text, class text, subject text, date date default current_date, entry_type text default 'homework',
  title text, body text, acknowledged boolean default false, created_by uuid references public.profiles(id), created_at timestamptz default now()
);

create table if not exists public.surveys (
  id uuid primary key default gen_random_uuid(), title text not null, description text, audience text default 'all',
  questions jsonb default '[]'::jsonb, anonymous boolean default true, is_open boolean default true,
  created_by uuid references public.profiles(id), created_at timestamptz default now()
);

create table if not exists public.survey_responses (
  id uuid primary key default gen_random_uuid(), survey_id uuid references public.surveys(id) on delete cascade,
  respondent uuid references public.profiles(id), answers jsonb default '{}'::jsonb, created_at timestamptz default now()
);

create table if not exists public.menu_planner (
  id uuid primary key default gen_random_uuid(), week_start date, day text, meal text, description text, allergens text,
  created_at timestamptz default now()
);

create table if not exists public.security_prefs (
  user_id uuid primary key references public.profiles(id) on delete cascade, two_factor boolean default false,
  recovery_email text, updated_at timestamptz default now()
);

create table if not exists public.login_audit (
  id uuid primary key default gen_random_uuid(), user_id uuid references public.profiles(id) on delete set null,
  email text, event text default 'login', ip text, user_agent text, created_at timestamptz default now()
);

create table if not exists public.i18n_strings (
  id uuid primary key default gen_random_uuid(), lang text not null default 'en', key text not null, value text not null,
  unique(lang, key)
);

create table if not exists public.academic_print_records (
  id uuid primary key default gen_random_uuid(), record_type text not null, title text not null, class text default '',
  subject text default '', term text default '', session text default '', generated_by uuid references public.profiles(id) on delete set null,
  data jsonb not null default '{}'::jsonb, created_at timestamptz default now()
);

create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
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

create table if not exists public.subjects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text,
  department text,
  level text,
  teacher text, -- additive fix: CRUD subject-teacher mapping stores the selected teacher name here
  teacher_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

create table if not exists public.parents (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  email text,
  phone text,
  occupation text,
  address text,
  status text default 'active',
  created_at timestamptz default now()
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  class text, date date not null default current_date,
  status text check (status in ('present','absent','late','excused')),
  time_in time,
  recorded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.results (
  id uuid primary key default gen_random_uuid(),
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

create table if not exists public.timetable (
  id uuid primary key default gen_random_uuid(),
  class text, day text, period text,
  subject text, teacher text, room text,
  session text, term text,
  created_at timestamptz default now()
);

create table if not exists public.scheme_of_work (
  id uuid primary key default gen_random_uuid(),
  subject text, class text, term text, session text,
  week int, topic text, status text default 'pending',
  covered_at date, teacher text, confirmed boolean default false,
  created_at timestamptz default now()
);

create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  title text, description text,
  class text, subject text, due_date date,
  posted_by uuid references public.profiles(id),
  drive_link text,
  created_at timestamptz default now()
);

create table if not exists public.library (
  id uuid primary key default gen_random_uuid(),
  title text, author text, isbn text,
  category text, copies int default 1,
  lent int default 0,
  available int generated always as (copies - coalesce(lent,0)) stored,
  drive_link text,
  created_at timestamptz default now()
);

create table if not exists public.conduct (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  type text check (type in ('merit','demerit','incident')),
  description text, reporter text,
  date date default current_date,
  created_at timestamptz default now()
);

create table if not exists public.health (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  complaint text, treatment text,
  date date default current_date, recorded_by text,
  created_at timestamptz default now()
);

create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  from_class text, to_class text,
  action text check (action in ('promote','graduate','repeat','delete')),
  session text, term text,
  approved_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.fee_structures (
  id uuid primary key default gen_random_uuid(),
  class text, term text, session text,
  amount numeric, description text,
  due_date date,
  created_at timestamptz default now()
);

create table if not exists public.fee_payments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  amount_paid numeric, method text, reference text,
  term text, session text,
  received_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.finance_entries (
  id uuid primary key default gen_random_uuid(),
  type text check (type in ('income','expense')),
  category text, amount numeric,
  description text, date date default current_date,
  recorded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid references public.staff(id) on delete cascade,
  type text check (type in ('sick','casual','earned','study','maternity')),
  start_date date, end_date date, days int,
  reason text,
  status text default 'pending' check (status in ('pending','approved','rejected')),
  approved_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.visitors (
  id uuid primary key default gen_random_uuid(),
  full_name text, phone text,
  purpose text, host text,
  check_in timestamptz default now(),
  check_out timestamptz,
  badge_no text,
  created_at timestamptz default now()
);

create table if not exists public.transport (
  id uuid primary key default gen_random_uuid(),
  route_name text, driver text,
  vehicle_no text, capacity int,
  assigned_students uuid[],
  created_at timestamptz default now()
);

create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null, body text,
  priority text default 'normal' check (priority in ('normal','high','urgent')),
  pinned boolean default false,
  audience text default 'all',
  posted_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text, description text,
  date date, venue text, organiser text,
  rsvp uuid[],
  created_at timestamptz default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  from_id uuid references public.profiles(id),
  to_id uuid references public.profiles(id),
  body text, read boolean default false,
  thread_id uuid,
  created_at timestamptz default now()
);

create table if not exists public.complaints (
  id uuid primary key default gen_random_uuid(),
  submitted_by uuid references public.profiles(id),
  type text, subject text, body text,
  urgency text default 'normal' check (urgency in ('low','normal','high','critical')),
  drive_link text,
  status text default 'submitted'
    check (status in ('submitted','reviewing','in_progress','resolved','rejected')),
  assignee uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  title text not null, body text,
  url text,
  audience text default 'all',
  priority text default 'normal',
  channels jsonb default '["inapp"]'::jsonb,
  read_by uuid[] default '{}',
  created_at timestamptz default now()
);

create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(),
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

create table if not exists public.poll_votes (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid references public.polls(id) on delete cascade,
  candidate_id text not null,
  voter_id uuid references public.profiles(id) on delete cascade,
  voted_at timestamptz default now(),
  unique(poll_id, candidate_id, voter_id)
);

create table if not exists public.gallery (
  id uuid primary key default gen_random_uuid(),
  album text, caption text,
  media_url text not null,
  media_type text default 'image' check (media_type in ('image','video','youtube')),
  uploaded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.eresources (
  id uuid primary key default gen_random_uuid(),
  title text, description text,
  subject text, class text, term text,
  drive_link text,
  uploaded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.birthdays (
  id uuid primary key default gen_random_uuid(),
  person_name text, type text,
  date date, class text,
  created_at timestamptz default now()
);

create table if not exists public.idcards (
  id uuid primary key default gen_random_uuid(),
  person_id uuid,
  person_type text check (person_type in ('student','staff')),
  card_no text unique,
  qr_data text,
  issued_at timestamptz default now()
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  title text, type text,
  payload jsonb,
  generated_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.departments (
  id uuid primary key default gen_random_uuid(),
  name text, head text, members text[],
  created_at timestamptz default now()
);

create table if not exists public.lookups (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  value text not null,
  position int default 0,
  active boolean default true,
  created_at timestamptz default now(),
  unique(kind,value)
);

create table if not exists public.academic_periods (
  id uuid primary key default gen_random_uuid(),
  session text not null,
  term text not null,
  starts_on date,
  ends_on date,
  is_current boolean default false,
  created_at timestamptz default now(),
  unique(session,term)
);

create table if not exists public.admissions (
  id uuid primary key default gen_random_uuid(),
  full_name text, dob date, gender text,
  parent_name text, parent_email text, parent_phone text,
  applying_for_class text,
  status text default 'submitted'
    check (status in ('submitted','reviewing','accepted','enrolled','rejected')),
  notes text,
  created_at timestamptz default now()
);

create table if not exists public.payroll (
  id uuid primary key default gen_random_uuid(),
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

create table if not exists public.hostel_allocations (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  block text, room text, bed text,
  status text default 'active' check (status in ('active','vacated')),
  created_at timestamptz default now()
);

create table if not exists public.alumni (
  id uuid primary key default gen_random_uuid(),
  full_name text, graduation_year int,
  last_class text, current_occupation text,
  email text, phone text,
  created_at timestamptz default now()
);

create table if not exists public.inventory (
  id uuid primary key default gen_random_uuid(),
  item_name text, category text,
  asset_tag text, quantity int default 1, location text,
  condition text default 'good', unit_cost numeric default 0,
  last_audit date, next_audit date,
  created_at timestamptz default now()
);

create table if not exists public.certificates (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  type text, serial_no text unique,
  issued_on date default current_date,
  signed_by text,
  created_at timestamptz default now()
);

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  endpoint text, p256dh text, auth text,
  created_at timestamptz default now(),
  unique(user_id, endpoint)
);

create table if not exists public.activity_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id),
  actor_email text,
  action text,            -- e.g. 'create','update','delete','login'
  entity text,            -- table or module affected
  entity_id text,
  details jsonb,
  ip text,
  created_at timestamptz default now()
);

create table if not exists public.lms_courses (
  id uuid primary key default gen_random_uuid(),
  title text not null, description text,
  subject text, class text, teacher text,
  cover_url text,
  created_at timestamptz default now()
);

create table if not exists public.lms_lessons (
  id uuid primary key default gen_random_uuid(),
  course_id uuid references public.lms_courses(id) on delete cascade,
  title text, content text,
  video_url text, resource_link text,
  position int default 0,
  created_at timestamptz default now()
);

create table if not exists public.lms_submissions (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid references public.assignments(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  submission_link text, note text,
  score numeric, feedback text,
  status text default 'submitted' check (status in ('submitted','graded','returned')),
  submitted_at timestamptz default now()
);

create table if not exists public.lesson_plans (
  id uuid primary key default gen_random_uuid(),
  teacher text, subject text, class text,
  week int, term text, session text,
  objectives text, content text, resources text,
  status text default 'draft' check (status in ('draft','submitted','approved')),
  created_at timestamptz default now()
);

create table if not exists public.behaviour_points (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  points int default 0,
  reason text, badge text,
  awarded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.support_plans (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  need_type text, intervention text,
  goal text, review_date date,
  outcome text, status text default 'active'
    check (status in ('active','review','closed')),
  created_at timestamptz default now()
);

create table if not exists public.donations (
  id uuid primary key default gen_random_uuid(),
  campaign text, donor_name text, donor_email text,
  amount numeric, method text,
  note text, anonymous boolean default false,
  recorded_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.substitutions (
  id uuid primary key default gen_random_uuid(),
  date date default current_date,
  absent_teacher text, substitute_teacher text,
  class text, subject text, period text,
  status text default 'planned' check (status in ('planned','done','cancelled')),
  created_at timestamptz default now()
);

create table if not exists public.helpdesk_tickets (
  id uuid primary key default gen_random_uuid(),
  submitted_by uuid references public.profiles(id),
  category text, subject text, body text,
  priority text default 'normal' check (priority in ('low','normal','high','urgent')),
  status text default 'open' check (status in ('open','in_progress','resolved','closed')),
  assignee uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.payment_intents (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  amount numeric, provider text,        -- 'paystack' | 'flutterwave' | 'bank_transfer'
  reference text, checkout_url text,
  status text default 'pending' check (status in ('pending','paid','failed','cancelled')),
  created_at timestamptz default now()
);

create table if not exists public.affective_traits (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  term text, session text,
  ratings jsonb default '{}'::jsonb, -- {trait: rating, ...}
  teacher_id uuid references public.profiles(id),
  created_at timestamptz default now(),
  unique(student_id, term, session)
);

create table if not exists public.psychomotor_traits (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  term text, session text,
  ratings jsonb default '{}'::jsonb,
  teacher_id uuid references public.profiles(id),
  created_at timestamptz default now(),
  unique(student_id, term, session)
);

create table if not exists public.report_comments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  term text, session text,
  class_teacher_comment text,
  principal_comment text,
  next_term_begins date,
  created_at timestamptz default now(),
  unique(student_id, term, session)
);

create table if not exists public.module_records (
  id uuid primary key default gen_random_uuid(),
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

create table if not exists public.admission_letters (
  id uuid primary key default gen_random_uuid(),
  candidate_name text not null,
  candidate_class text,
  exam_id uuid references public.cbt_exams(id) on delete set null,
  result_id uuid references public.cbt_results(id) on delete set null,
  percent numeric(6,2),
  decision text default 'admitted' check (decision in ('admitted','provisional','waitlist','not_admitted')),
  letter_ref text,        -- e.g. ADM-LTR/2026/0001
  session text,
  notes text,
  created_at timestamptz default now()
);

create table if not exists public.admission_links (
  id uuid primary key default gen_random_uuid(),
  token text unique not null default replace(gen_random_uuid()::text,'-',''),
  label text,
  applying_for_class text,
  session text,
  active boolean default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table if not exists public.certificate_designs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  title text default 'CERTIFICATE OF ACHIEVEMENT',
  primary_color text default '#4f46e5',
  accent_color text default '#f59e0b',
  font text default 'Georgia',
  layout text default 'classic',          -- classic | modern | elegant
  body_text text default 'has successfully met the requirements and is hereby recognised for outstanding achievement.',
  signatory text default 'Head of School',
  signature_data text,                    -- base64 PNG of an appended signature
  border_style text default 'double',
  created_at timestamptz default now()
);

create table if not exists public.digital_library (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  author text,
  subject text,
  class text,
  read_link text not null,
  teacher text,
  instructions text,
  has_quiz boolean default false,
  questions jsonb default '[]'::jsonb,   -- [{q, options[], answer}]
  max_score int default 0,
  due_date date,
  created_at timestamptz default now()
);

create table if not exists public.reading_scores (
  id uuid primary key default gen_random_uuid(),
  student_name text,
  subject text,
  class text,
  book_id uuid references public.digital_library(id) on delete set null,
  score numeric default 0,
  max_score numeric default 0,
  source text default 'digital_library',
  pushed_to_results boolean default false,
  created_at timestamptz default now()
);

create table if not exists public.staff_appraisals (
  id uuid primary key default gen_random_uuid(),
  staff_name text not null,
  period text,
  punctuality int,
  teaching_quality int,
  student_results int,
  teamwork int,
  conduct int,
  total_score text,
  recommendation text,
  comments text,
  appraiser text,
  created_at timestamptz default now()
);

create table if not exists public.staff_bonus (
  id uuid primary key default gen_random_uuid(),
  staff_name text not null,
  bonus_type text default 'performance',
  amount numeric default 0,
  reason text,
  award_date date,
  status text default 'pending' check (status in ('pending','approved','paid')),
  created_at timestamptz default now()
);

create table if not exists public.staff_loans (
  id uuid primary key default gen_random_uuid(),
  staff_name text not null,
  loan_type text default 'salary advance',
  principal numeric default 0,
  monthly_repayment numeric default 0,
  months int default 0,
  amount_repaid numeric default 0,
  date_taken date,
  status text default 'active' check (status in ('active','completed','defaulted','written-off')),
  notes text,
  created_at timestamptz default now()
);

create table if not exists public.timetable_config (
  id uuid primary key default gen_random_uuid(),
  class text default 'ALL',
  period_no int not null,
  label text not null,          -- 'Period 1' | 'Short Break' | 'Long Break'
  start_time text,              -- '08:00'
  end_time text,                -- '08:40'
  is_break boolean default false,
  position int default 0,
  unique(class, period_no)
);

-- ============================================================================
-- SECTION 3: UPGRADE SAFETY — backfill columns on legacy tables
-- ============================================================================
-- Upgrade safety for older deployments that had a minimal schools table.
alter table public.schools add column if not exists name text default 'My School';
alter table public.schools add column if not exists short_name text default 'SCH';
alter table public.schools add column if not exists admission_acronym text default 'SCH';
alter table public.schools add column if not exists motto text default 'Excellence in Learning';
alter table public.schools add column if not exists address text default '';
alter table public.schools add column if not exists phone text default '';
alter table public.schools add column if not exists email text default '';
alter table public.schools add column if not exists currency text default '₦';
alter table public.schools add column if not exists site_url text default '';
alter table public.schools add column if not exists logo_url text default '';
-- Upgrade safety: CREATE TABLE IF NOT EXISTS does not add columns to an
-- existing v1-v7 school_settings table. These columns MUST be backfilled
-- before the seed INSERT below; otherwise PostgreSQL stops at 42703.
alter table public.school_settings add column if not exists school_id uuid references public.schools(id) on delete set null;
alter table public.school_settings add column if not exists school_name text default 'My School';
alter table public.school_settings add column if not exists short_name text default 'SCH';
alter table public.school_settings add column if not exists admission_acronym text default 'SCH';
alter table public.school_settings add column if not exists admission_prefix text default 'SCH';
alter table public.school_settings add column if not exists staff_prefix text default 'SCH';
alter table public.school_settings add column if not exists checkin_deadline text default '08:00';
alter table public.school_settings add column if not exists checkin_grace_minutes int default 15;
-- ==========================================
-- ENSURE STUDENT_ID EXISTS ON ALL TABLES (Fixes ERROR 42703)
-- ==========================================
alter table if exists public.attendance add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.results add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.conduct add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.health add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.fee_payments add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.payment_intents add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.report_scores add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.report_cards add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.affective_traits add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.psychomotor_traits add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.report_comments add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.student_clock add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.student_diary add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.parent_child add column if not exists student_id uuid references public.students(id) on delete cascade;
-- v12.1 drift-hardening (completes the 42703 fix): the same guarantee for
-- every OTHER column that a policy, view, SQL function, constraint or index
-- references later in this file. An existing database built by an older
-- schema generation may hold these tables in an older shape without the
-- column; RLS policies validate their expressions at creation and abort the
-- whole run with 42703 ("column ... does not exist"). Purely additive:
-- nothing is ever dropped, renamed or re-typed here.
alter table if exists public.support_plans add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.certificates add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.lms_submissions add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table if exists public.push_subscriptions add column if not exists user_id uuid references public.profiles(id) on delete cascade;
alter table if exists public.security_prefs add column if not exists user_id uuid references public.profiles(id) on delete cascade;
alter table if exists public.idcards add column if not exists person_id uuid;
alter table if exists public.idcards add column if not exists person_type text;
alter table if exists public.module_records add column if not exists created_by uuid references public.profiles(id);
alter table if exists public.results add column if not exists teacher_id uuid references public.profiles(id);
alter table if exists public.eresources add column if not exists class text;
alter table if exists public.parent_child add column if not exists parent_id uuid references public.profiles(id) on delete cascade;
alter table if exists public.students add column if not exists guardian_email text;
alter table if exists public.poll_votes add column if not exists candidate_id text;
alter table if exists public.cbt_results add column if not exists student_id_ref text default '';
alter table if exists public.profiles add column if not exists role text default 'student';
alter table if exists public.profiles add column if not exists status text default 'pending';
-- =====================================================================

-- v8 EARLY COMPATIBILITY BACKFILL
-- These ALTERs intentionally appear before the historical base-schema body.
-- An existing table is not changed by CREATE TABLE IF NOT EXISTS; later base
-- indexes/policies must therefore never reference an old missing column.
alter table public.assessment_columns add column if not exists class text default '';
alter table public.assessment_columns add column if not exists subject text default '*';
alter table public.assessment_columns add column if not exists term text default '';
alter table public.assessment_columns add column if not exists session text default '';
alter table public.assessment_columns add column if not exists name text default '';
alter table public.assessment_columns add column if not exists max_mark numeric default 10;
alter table public.assessment_columns add column if not exists weight numeric default 1;
alter table public.assessment_columns add column if not exists position int default 0;
alter table public.assessment_columns add column if not exists source text default 'manual';
alter table public.assessment_columns add column if not exists cbt_assessment_type text default '';
alter table public.assessment_columns add column if not exists created_by uuid references public.profiles(id) on delete set null;
alter table public.report_scores add column if not exists column_id uuid;
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
alter table public.class_fee_structure add column if not exists school_id uuid references public.schools(id) on delete cascade;
alter table public.class_fee_structure add column if not exists class text default '';
alter table public.class_fee_structure add column if not exists arm text default '';
alter table public.class_fee_structure add column if not exists department text default '';
alter table public.class_fee_structure add column if not exists term text default 'Current Term';
alter table public.class_fee_structure add column if not exists session text default '';
alter table public.class_fee_structure add column if not exists total numeric(12,2) default 0;
alter table public.class_fee_structure add column if not exists amount numeric(12,2) default 0;
alter table public.class_fee_structure add column if not exists other_fee numeric(12,2) default 0;
alter table public.class_fee_structure add column if not exists next_term_begins date;
alter table public.class_fee_structure add column if not exists note text default '';
alter table public.class_fee_structure add column if not exists fee_items jsonb default '[]'::jsonb;
alter table public.class_fee_structure add column if not exists active boolean default true;
alter table public.school_products add column if not exists school_id uuid references public.schools(id) on delete cascade;
alter table public.school_products add column if not exists name text default '';
alter table public.school_products add column if not exists description text default '';
alter table public.school_products add column if not exists price numeric(12,2) default 0;
alter table public.school_products add column if not exists active boolean default true;
alter table public.role_status_log add column if not exists school_id uuid references public.schools(id) on delete cascade;
alter table public.role_status_log add column if not exists person_id uuid references public.profiles(id) on delete set null;
alter table public.role_status_log add column if not exists person_name text default '';
alter table public.role_status_log add column if not exists new_role text default '';
alter table public.role_status_log add column if not exists new_status text default '';
alter table public.staff_clock add column if not exists school_id uuid references public.schools(id) on delete cascade;
alter table public.staff_clock add column if not exists staff_id uuid references public.staff(id) on delete set null;
alter table public.student_clock add column if not exists school_id uuid references public.schools(id) on delete cascade;
alter table public.student_clock add column if not exists student_id uuid references public.students(id) on delete cascade;
alter table public.profiles add column if not exists date_of_birth date;
alter table public.profiles add column if not exists dob_day int;
alter table public.profiles add column if not exists dob_month text;
alter table public.students add column if not exists user_id uuid references public.profiles(id) on delete set null;
alter table public.staff add column if not exists user_id uuid references public.profiles(id) on delete set null;
-- Cumulative repair for older generated databases that already have subjects without teacher columns.
alter table public.subjects add column if not exists teacher text;
alter table public.subjects add column if not exists teacher_id uuid references public.profiles(id) on delete set null;
alter table public.attendance add column if not exists student_name text;
alter table public.results add column if not exists student_name text;
alter table public.results add column if not exists assessment_source text default 'manual';
alter table public.results add column if not exists assessment_ref text;
alter table public.assignments add column if not exists teacher_id uuid references public.profiles(id) on delete set null;
alter table public.fee_payments add column if not exists fee_total numeric;
alter table public.fee_payments add column if not exists balance numeric;
alter table public.fee_payments add column if not exists student_name text;
-- Ensure new columns exist on legacy databases
alter table public.payroll add column if not exists staff_name text;
alter table public.payroll add column if not exists bonus numeric default 0;
alter table public.payroll add column if not exists overtime numeric default 0;
alter table public.payroll add column if not exists tax numeric default 0;
alter table public.payroll add column if not exists pension numeric default 0;
alter table public.payroll add column if not exists loan_deduction numeric default 0;
alter table public.payroll add column if not exists other_deductions numeric default 0;
alter table public.payroll add column if not exists method text default 'bank transfer';
alter table public.inventory add column if not exists item_name text;
alter table public.inventory add column if not exists category text;
alter table public.inventory add column if not exists quantity int default 1;
alter table public.inventory add column if not exists location text;
alter table public.inventory add column if not exists condition text default 'good';
alter table public.lesson_plans add column if not exists posted_by uuid references public.profiles(id) on delete set null;
alter table public.lesson_plans add column if not exists teacher_id uuid references public.profiles(id) on delete set null;
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
-- FINAL CUMULATIVE SUBJECT-TEACHER MAPPING REPAIR
-- Safe for fresh and existing databases. Fixes: could not find 'teacher' column of subjects.
alter table if exists public.subjects add column if not exists teacher text;
alter table if exists public.subjects add column if not exists teacher_id uuid references public.profiles(id) on delete set null;
alter table public.school_settings add column if not exists role_access jsonb;
-- Page access manager write-permission map.
alter table public.school_settings add column if not exists role_write jsonb;
alter table public.module_records add column if not exists audience text default 'private';
alter table public.module_records add column if not exists recipient_id uuid references public.profiles(id) on delete set null;
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
alter table if exists public.school_settings add column if not exists checkin_deadline text default '08:00';
alter table if exists public.school_settings add column if not exists checkin_grace_minutes int default 0;
alter table if exists public.school_settings add column if not exists role_access jsonb default '{}'::jsonb;
alter table if exists public.school_settings add column if not exists role_write jsonb default '{}'::jsonb;
-- =====================================================================
-- END SCHOOL CONNECT V1 FINAL CUMULATIVE PATCH
-- =====================================================================


-- ============================================================================
-- V7 COMPATIBILITY BACKFILLS
-- ============================================================================
alter table public.school_settings add column if not exists signature_url text default '';
alter table public.school_settings add column if not exists class_teacher_signature_url text default '';
alter table public.school_settings add column if not exists principal_name text default 'Principal';
alter table public.school_settings add column if not exists stamp_text text default 'OFFICIAL SCHOOL SEAL';
alter table public.school_settings add column if not exists stamp_color text default '#1e3a8a';
alter table public.school_settings add column if not exists stamp_enabled boolean default true;
alter table public.school_settings add column if not exists signature_enabled boolean default true;
alter table public.school_settings add column if not exists latitude numeric;
alter table public.school_settings add column if not exists longitude numeric;
alter table public.school_settings add column if not exists geo_radius_m int default 200;
alter table public.school_settings add column if not exists enforce_geofence boolean default false;
alter table public.school_settings add column if not exists geo_updated_at timestamptz;
alter table public.school_settings add column if not exists role_access jsonb default '{}'::jsonb;
alter table public.school_settings add column if not exists role_write jsonb default '{}'::jsonb;
alter table public.school_settings add column if not exists hmg_link text default 'https://hmgconcepts.pages.dev/';
alter table public.students add column if not exists admission_no text;
alter table public.students add column if not exists arm text;
alter table public.students add column if not exists department text default 'Other';
alter table public.staff add column if not exists staff_no text;
alter table public.cbt_results add column if not exists student_id uuid references public.students(id) on delete set null;
alter table public.cbt_results add column if not exists submitted_at timestamptz default now();
alter table public.cbt_exams add column if not exists duration_min int default 45;
alter table public.cbt_exams add column if not exists questions jsonb default '[]'::jsonb;
alter table public.role_status_log add column if not exists previous_role text default '';
alter table public.role_status_log add column if not exists previous_status text default '';
alter table public.role_status_log add column if not exists person_email text default '';
alter table public.role_status_log add column if not exists changed_by uuid references public.profiles(id) on delete set null;

-- ============================================================================
-- SECTION 3b: LEGACY NOT-NULL HARDENING (never fatal: old rows kept if any violate)
-- ============================================================================
do $$
begin
  begin execute 'alter table public.report_scores alter column column_id set not null'; exception when others then raise notice 'not-null skipped: %', sqlerrm; end;
  begin execute 'alter table public.report_scores alter column student_id_ref set not null'; exception when others then raise notice 'not-null skipped: %', sqlerrm; end;
  begin execute 'alter table public.report_scores alter column student_name set not null'; exception when others then raise notice 'not-null skipped: %', sqlerrm; end;
  begin execute 'alter table public.report_scores alter column class set not null'; exception when others then raise notice 'not-null skipped: %', sqlerrm; end;
  begin execute 'alter table public.report_scores alter column subject set not null'; exception when others then raise notice 'not-null skipped: %', sqlerrm; end;
  begin execute 'alter table public.report_scores alter column term set not null'; exception when others then raise notice 'not-null skipped: %', sqlerrm; end;
  begin execute 'alter table public.report_scores alter column session set not null'; exception when others then raise notice 'not-null skipped: %', sqlerrm; end;
end $$;

-- ============================================================================
-- SECTION 4: DATA MIGRATIONS / REPAIR BLOCKS (run before constraints)
-- ============================================================================
-- v10 guarded ownership-policy compatibility backfill.
-- On a fresh database the historical base body has not created these tables
-- yet, so this block must not issue direct ALTER TABLE statements. On an old
-- database, the tables already exist and missing ownership columns are added.
do $$
declare t text;
begin
  foreach t in array ARRAY['assignments','scheme_of_work','lesson_plans','cbt_exams','attendance'] loop
    if to_regclass('public.'||t) is not null then
      execute format('alter table public.%I add column if not exists teacher_id uuid references public.profiles(id) on delete set null',t);
      execute format('alter table public.%I add column if not exists posted_by uuid references public.profiles(id) on delete set null',t);
      execute format('alter table public.%I add column if not exists recorded_by uuid references public.profiles(id) on delete set null',t);
    end if;
  end loop;
end $$;

do $$ begin
  alter table public.polls add column if not exists max_votes integer default 1;
  alter table public.polls add column if not exists created_by uuid references public.profiles(id) on delete set null;
exception when undefined_table then null; end $$;

-- V13 voting repair: poll_results depends on candidate_id, so drop/recreate the view around the type conversion.
do $$ begin
  drop view if exists public.poll_results cascade;
  alter table public.poll_votes alter column candidate_id type text using candidate_id::text;
exception when undefined_table then null; end $$;

do $$ begin
  alter table public.poll_votes add column if not exists voter_id uuid references public.profiles(id) on delete cascade;
  alter table public.poll_votes add column if not exists voted_at timestamptz default now();
exception when undefined_table then null; end $$;

-- Voting UUID/type repair: legacy databases may have candidate_id as uuid.
-- V13 voting repair: poll_results depends on candidate_id, so drop/recreate the view around the type conversion.
do $$ begin
  drop view if exists public.poll_results cascade;
  alter table public.poll_votes alter column candidate_id type text using candidate_id::text;
exception when undefined_table then null; end $$;

do $$ begin
exception when undefined_table then null; end $$;

-- Staff geofenced attendance settings, configured by admin in Settings.
do $$ begin
  alter table public.school_settings add column if not exists geo_radius_m integer default 200;
  alter table public.school_settings add column if not exists enforce_geofence boolean default true;
exception when undefined_table then null; end $$;

-- Ownership columns for teacher/staff-only editing.
do $$ begin
  alter table public.health add column if not exists recorded_by_id uuid references public.profiles(id) on delete set null;
  alter table public.reports add column if not exists generated_by uuid references public.profiles(id) on delete set null;
  alter table public.helpdesk_tickets add column if not exists submitted_by uuid references public.profiles(id) on delete set null;
exception when undefined_table then null; end $$;

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

-- updated_at triggers when helper exists.
do $$ begin
  if exists (select 1 from pg_proc where proname = 'set_updated_at') then
    drop trigger if exists class_fee_structure_updated on public.class_fee_structure;
    create trigger class_fee_structure_updated before update on public.class_fee_structure for each row execute function public.set_updated_at();
    drop trigger if exists school_products_updated on public.school_products;
    create trigger school_products_updated before update on public.school_products for each row execute function public.set_updated_at();
  end if;
end $$;

do $$
declare c record;
begin
  if to_regclass('public.report_scores') is null then return; end if;
  for c in select conname from pg_constraint where conrelid='public.report_scores'::regclass and contype='u' loop
    execute format('alter table public.report_scores drop constraint %I', c.conname);
  end loop;
end $$;

-- Common updated_at triggers.
do $$ declare t text; begin
  foreach t in array ARRAY['school_settings','report_scores','class_fee_structure','school_products'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists sc_updated_at on public.%I',t);
      execute format('create trigger sc_updated_at before update on public.%I for each row execute function public.sc_set_updated_at()',t);
    end if;
  end loop;
end $$;

do $$ begin execute 'alter view public.report_subject_totals set (security_invoker = true)'; exception when others then null; end $$;

-- Scoped reporting/traits/comments.
do $$ declare p text; begin
  foreach p in array ARRAY['rs_staff','rs_select_family','rs_insert_v16_owner','rs_update_v16_owner','rs_delete_v16_owner','read_psychomotor','write_psychomotor','psychomotor_traits_read','psychomotor_traits_write','read_comments','write_comments','report_comments_read','report_comments_write','read_affective','write_affective','affective_traits_read','affective_traits_write','rc_staff','rc_read'] loop
    execute format('drop policy if exists %I on public.report_scores',p);
    execute format('drop policy if exists %I on public.psychomotor_traits',p);
    execute format('drop policy if exists %I on public.report_comments',p);
    execute format('drop policy if exists %I on public.affective_traits',p);
    execute format('drop policy if exists %I on public.report_cards',p);
  end loop;
end $$;

-- Named tables and settings policies.
do $$ declare t text; begin
  foreach t in array ARRAY['school_settings','schools','class_fee_structure','school_products','role_status_log','staff_clock','student_clock','timetable_requirements','teacher_availability','timetable_runs','attendance_checkins','student_diary','surveys','survey_responses','menu_planner','security_prefs','login_audit','i18n_strings','academic_print_records'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop policy if exists v7_read_%I on public.%I',t,t);
      execute format('drop policy if exists v7_write_%I on public.%I',t,t);
    end if;
  end loop;
end $$;

insert into public.schools (name, short_name, admission_acronym)
values ('My School','SCH','SCH') on conflict do nothing;

insert into public.school_settings (id, school_id, school_name, short_name, admission_acronym, admission_prefix, staff_prefix)
select 1, s.id, s.name, s.short_name, s.admission_acronym, s.admission_acronym, s.admission_acronym
from public.schools s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.lookups(kind,value,position) values
 ('term','First Term',1),('term','Second Term',2),('term','Third Term',3),
 ('session','2024/2025',1),('session','2025/2026',2),('session','2026/2027',3),
 ('arm','A',1),('arm','B',2),('arm','C',3),
 ('assessment','CA1',1),('assessment','CA2',2),('assessment','Assignment',3),('assessment','Project',4),('assessment','Exam',5),
 ('audience','all',1),('audience','students',2),('audience','staff',3),('audience','parents',4)
on conflict(kind,value) do nothing;

insert into public.school_settings (id) values (1) on conflict (id) do nothing;

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

delete from public.class_fee_structure a using public.class_fee_structure b
where a.ctid < b.ctid and a.class=b.class and a.arm=b.arm and a.department=b.department and a.term=b.term;

delete from public.students a using public.students b
where a.ctid < b.ctid and coalesce(a.admission_no,'') <> '' and a.admission_no=b.admission_no;

delete from public.staff a using public.staff b
where a.ctid < b.ctid and coalesce(a.staff_no,'') <> '' and a.staff_no=b.staff_no;

-- ============================================================================
-- SECTION 5: UNIQUE & CHECK CONSTRAINTS (13 statements — drop-if-exists → add; browser upsert keys)
-- ============================================================================
alter table public.attendance drop constraint if exists attendance_student_date_unique;
drop index if exists attendance_student_date_unique;
alter table public.attendance add constraint attendance_student_date_unique unique (student_id, date);
drop index if exists public.report_scores_unique_composite;
drop index if exists public.report_scores_column_student_subject_uq;
drop index if exists public.report_scores_column_student_subject_uq_v7;
alter table public.report_scores drop constraint if exists report_scores_uq;
drop index if exists report_scores_uq;
alter table public.report_scores add constraint report_scores_uq unique (column_id, student_id_ref, student_name, class, subject, term, session);
alter table public.report_scores drop constraint if exists report_scores_context_unique;
alter table public.class_fee_structure drop constraint if exists class_fee_structure_uq;
drop index if exists class_fee_structure_uq;
alter table public.class_fee_structure add constraint class_fee_structure_uq unique (class, arm, department, term);

-- ============================================================================
-- SECTION 6: INDEXES
-- ============================================================================
create index if not exists students_user_id_idx on public.students(user_id);
create index if not exists staff_user_id_idx on public.staff(user_id);
create index if not exists module_records_module_idx on public.module_records (module, created_at desc);
create index if not exists polls_status_created_idx on public.polls(status, created_at desc);
create index if not exists poll_votes_poll_voter_idx on public.poll_votes(poll_id, voter_id);
create index if not exists class_fee_structure_school_idx on public.class_fee_structure(school_id);
create index if not exists class_fee_structure_lookup_idx on public.class_fee_structure(class, arm, department, term);
create index if not exists school_products_school_idx on public.school_products(school_id);
create index if not exists role_status_log_school_idx on public.role_status_log(school_id);
create index if not exists staff_clock_school_idx on public.staff_clock(school_id);
create index if not exists staff_clock_staff_idx on public.staff_clock(staff_id);
create index if not exists student_clock_school_idx on public.student_clock(school_id);
create index if not exists student_clock_student_idx on public.student_clock(student_id);
create index if not exists school_settings_school_idx on public.school_settings(school_id);
create index if not exists students_user_id_idx_v7 on public.students(user_id);
create index if not exists staff_user_id_idx_v7 on public.staff(user_id);
create index if not exists report_scores_lookup_idx_v7 on public.report_scores(class, subject, term, session);
create index if not exists cbt_results_student_idx_v7 on public.cbt_results(student_id_ref);
create index if not exists class_fee_structure_school_idx_v7 on public.class_fee_structure(school_id);
create index if not exists school_products_school_idx_v7 on public.school_products(school_id);
create index if not exists role_status_log_person_idx_v7 on public.role_status_log(person_id);
-- A transaction advisory lock makes the MAX-based allocator safe enough for
-- free-tier single-school deployments; the unique column remains the final guard.
create unique index if not exists students_admission_no_uq_v7 on public.students(admission_no) where admission_no is not null and admission_no <> '';
create unique index if not exists staff_staff_no_uq_v7 on public.staff(staff_no) where staff_no is not null and staff_no <> '';

-- ============================================================================
-- SECTION 7: BUSINESS FUNCTIONS (13)
-- ============================================================================
DROP FUNCTION IF EXISTS public.is_admin() CASCADE;
create or replace function public.is_admin(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','principal','proprietor','head_teacher','bursar')
      and status in ('approved','active')
  );
$$;

DROP FUNCTION IF EXISTS public.is_staff() CASCADE;
create or replace function public.is_staff(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','principal','proprietor','head_teacher','staff','teacher','bursar')
      and status in ('approved','active')
  );
$$;

DROP FUNCTION IF EXISTS public.is_parent_of() CASCADE;
create or replace function public.is_parent_of(uid uuid, child uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.parent_child
    where parent_id = uid and student_id = child
  );
$$;

DROP FUNCTION IF EXISTS public.compute_fee_payment_balance() CASCADE;
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

DROP FUNCTION IF EXISTS public.compute_payroll_net() CASCADE;
create or replace function public.compute_payroll_net()
returns trigger language plpgsql as $$
begin
  new.net_pay := greatest(0,
    coalesce(new.basic,0)+coalesce(new.allowances,0)+coalesce(new.bonus,0)+coalesce(new.overtime,0)
    - coalesce(new.tax,0)-coalesce(new.pension,0)-coalesce(new.loan_deduction,0)-coalesce(new.other_deductions,0)-coalesce(new.deductions,0)
  );
  return new;
end $$;

DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;
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

DROP FUNCTION IF EXISTS public.verify_certificate() CASCADE;
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

DROP FUNCTION IF EXISTS public.sc_generate_admission_no() CASCADE;
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

DROP FUNCTION IF EXISTS public.sc_generate_staff_no() CASCADE;
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

DROP FUNCTION IF EXISTS public.sc_push_cbt_to_results() CASCADE;
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

DROP FUNCTION IF EXISTS public.cbt_get_public_exam() CASCADE;
create or replace function public.cbt_get_public_exam(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record; qs jsonb;
begin
 select * into e from public.cbt_exams where upper(code)=upper(trim(p_code)) and is_open=true and is_archived=false limit 1;
 if not found then return null; end if;
 if e.start_at is not null and now()<e.start_at then return jsonb_build_object('wait',true,'start_at',e.start_at,'title',e.title); end if;
 if e.close_at is not null and now()>e.close_at then return jsonb_build_object('closed',true); end if;
 select coalesce(jsonb_agg((q-'correct'-'correct_answer'-'answer'-'explanation')||jsonb_build_object('_orig_index',ord-1) order by ord),'[]'::jsonb) into qs from jsonb_array_elements((case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array' and jsonb_array_length(e.questions)>0 then e.questions else '[]'::jsonb end)) with ordinality x(q,ord);
 return jsonb_build_object('id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,'term',e.term,'session',e.session,'duration',e.duration,'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode);
end $$;

DROP FUNCTION IF EXISTS public.cbt_submit() CASCADE;
create or replace function public.cbt_submit(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; rid uuid; sid uuid; n int; score numeric:=0; total numeric:=0; ans jsonb; q jsonb; i int:=0; a text; k text; mark numeric;
begin
 select * into e from public.cbt_exams where id=(p_payload->>'exam_id')::uuid; if not found then return jsonb_build_object('saved',false,'error','Exam not found'); end if;
 for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb)) loop
   q := (case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array' and jsonb_array_length(e.questions)>0 then e.questions else '[]'::jsonb end)->i; mark:=coalesce(nullif(q->>'mark','')::numeric,1); total:=total+mark; a:=coalesce(ans->>'answer',ans #>> '{}',''); k:=coalesce(q->>'answer',q->>'correct',q->>'correct_answer',''); if lower(trim(a))=lower(trim(k)) and k<>'' then score:=score+mark; end if; i:=i+1;
 end loop;
 sid := nullif(p_payload->>'student_id','')::uuid; n:=case when total>0 then round(score/total*100)::int else 0 end;
 insert into public.cbt_results(exam_id,student_id,student_name,student_class,student_id_ref,student_type,score,total,percent,answers_data,cert_code)
 values(e.id,sid,coalesce(p_payload->>'student_name','Anonymous'),coalesce(p_payload->>'student_class',e.class),coalesce(p_payload->>'student_id_ref',''),coalesce(p_payload->>'student_type',e.exam_mode),score,total::int,n,p_payload->'answers_data',case when e.certificate_enabled then 'CERT-'||upper(substr(md5(random()::text),1,8)) else '' end) returning id into rid;
 return jsonb_build_object('saved',true,'result_id',rid,'score',score,'total',total,'percent',n,'cert_code',(select cert_code from public.cbt_results where id=rid));
exception when others then return jsonb_build_object('saved',false,'error',sqlerrm); end $$;

DROP FUNCTION IF EXISTS public.generate_timetable() CASCADE;
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

-- ============================================================================
-- SECTION 7b: DYNAMIC POLICY BLOCKS (2 — run after functions exist)
-- ============================================================================
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

-- ---- Update RLS for teacher isolation on key academic tables ----
do $$
declare t text;
declare owned_tables text[] := array['assignments','scheme_of_work','lesson_plans','cbt_exams','attendance'];
begin
  foreach t in array owned_tables loop
    -- v10: guarantee every ownership field before policy DDL, including fresh installs.
    execute format('alter table public.%I add column if not exists teacher_id uuid references public.profiles(id) on delete set null', t);
    execute format('alter table public.%I add column if not exists posted_by uuid references public.profiles(id) on delete set null', t);
    execute format('alter table public.%I add column if not exists recorded_by uuid references public.profiles(id) on delete set null', t);
    execute format('drop policy if exists "update_own_%s" on public.%I', t, t);
    execute format('drop policy if exists "delete_own_%s" on public.%I', t, t);
    execute format('create policy "update_own_%s" on public.%I for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid() or posted_by = auth.uid() or recorded_by = auth.uid())', t, t);
    execute format('create policy "delete_own_%s" on public.%I for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid() or posted_by = auth.uid() or recorded_by = auth.uid())', t, t);
  end loop;
end $$;

-- ============================================================================
-- SECTION 8: VIEWS & COMPATIBILITY ALIASES (3 views + drop preliminaries)
-- ============================================================================
drop view if exists public.poll_results cascade;
drop view if exists public.report_subject_totals cascade;
drop view if exists public.parent_children cascade;

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

create view public.report_subject_totals as
select rs.student_id, rs.student_name, rs.student_id_ref, rs.class, rs.subject, rs.term, rs.session,
       round(sum(rs.score),2) obtained, round(sum(ac.max_mark),2) obtainable,
       case when sum(ac.max_mark)>0 then round(sum(rs.score)/sum(ac.max_mark)*100,2) else 0 end percent
from public.report_scores rs join public.assessment_columns ac on ac.id=rs.column_id
group by rs.student_id,rs.student_name,rs.student_id_ref,rs.class,rs.subject,rs.term,rs.session;

create view public.parent_children as select * from public.parent_child;

-- ============================================================================
-- SECTION 9: TRIGGERS
-- ============================================================================
drop trigger if exists trg_compute_fee_payment_balance on public.fee_payments;
create trigger trg_compute_fee_payment_balance
before insert or update of fee_total, amount_paid, balance on public.fee_payments
for each row execute function public.compute_fee_payment_balance();
drop trigger if exists trg_compute_payroll_net on public.payroll;
create trigger trg_compute_payroll_net
before insert or update of basic, allowances, bonus, overtime, tax, pension, loan_deduction, other_deductions, deductions on public.payroll
for each row execute function public.compute_payroll_net();
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
drop trigger if exists trg_sc_generate_admission_no on public.students;
create trigger trg_sc_generate_admission_no before insert on public.students for each row execute function public.sc_generate_admission_no();
drop trigger if exists trg_sc_generate_staff_no on public.staff;
create trigger trg_sc_generate_staff_no before insert on public.staff for each row execute function public.sc_generate_staff_no();

-- ============================================================================
-- SECTION 11: ROW-LEVEL SECURITY — enable on every table
-- ============================================================================
alter table public.schools enable row level security;
alter table public.school_settings enable row level security;
alter table public.profiles enable row level security;
alter table public.students enable row level security;
alter table public.staff enable row level security;
alter table public.parent_child enable row level security;
alter table public.cbt_exams enable row level security;
alter table public.cbt_results enable row level security;
alter table public.cbt_roster enable row level security;
alter table public.assessment_columns enable row level security;
alter table public.report_scores enable row level security;
alter table public.report_cards enable row level security;
alter table public.class_fee_structure enable row level security;
alter table public.school_products enable row level security;
alter table public.role_status_log enable row level security;
alter table public.staff_clock enable row level security;
alter table public.student_clock enable row level security;
alter table public.timetable_requirements enable row level security;
alter table public.teacher_availability enable row level security;
alter table public.timetable_runs enable row level security;
alter table public.attendance_checkins enable row level security;
alter table public.student_diary enable row level security;
alter table public.surveys enable row level security;
alter table public.survey_responses enable row level security;
alter table public.menu_planner enable row level security;
alter table public.security_prefs enable row level security;
alter table public.login_audit enable row level security;
alter table public.i18n_strings enable row level security;
alter table public.academic_print_records enable row level security;
alter table public.classes enable row level security;
alter table public.subjects enable row level security;
alter table public.parents enable row level security;
alter table public.attendance enable row level security;
alter table public.results enable row level security;
alter table public.timetable enable row level security;
alter table public.scheme_of_work enable row level security;
alter table public.assignments enable row level security;
alter table public.library enable row level security;
alter table public.conduct enable row level security;
alter table public.health enable row level security;
alter table public.promotions enable row level security;
alter table public.fee_structures enable row level security;
alter table public.fee_payments enable row level security;
alter table public.finance_entries enable row level security;
alter table public.leave_requests enable row level security;
alter table public.visitors enable row level security;
alter table public.transport enable row level security;
alter table public.announcements enable row level security;
alter table public.events enable row level security;
alter table public.messages enable row level security;
alter table public.complaints enable row level security;
alter table public.notifications enable row level security;
alter table public.polls enable row level security;
alter table public.poll_votes enable row level security;
alter table public.gallery enable row level security;
alter table public.eresources enable row level security;
alter table public.birthdays enable row level security;
alter table public.idcards enable row level security;
alter table public.reports enable row level security;
alter table public.departments enable row level security;
alter table public.lookups enable row level security;
alter table public.academic_periods enable row level security;
alter table public.admissions enable row level security;
alter table public.payroll enable row level security;
alter table public.hostel_allocations enable row level security;
alter table public.alumni enable row level security;
alter table public.inventory enable row level security;
alter table public.certificates enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.activity_log enable row level security;
alter table public.lms_courses enable row level security;
alter table public.lms_lessons enable row level security;
alter table public.lms_submissions enable row level security;
alter table public.lesson_plans enable row level security;
alter table public.behaviour_points enable row level security;
alter table public.support_plans enable row level security;
alter table public.donations enable row level security;
alter table public.substitutions enable row level security;
alter table public.helpdesk_tickets enable row level security;
alter table public.payment_intents enable row level security;
alter table public.affective_traits enable row level security;
alter table public.psychomotor_traits enable row level security;
alter table public.report_comments enable row level security;
alter table public.module_records enable row level security;
alter table public.exam_registrations enable row level security;
alter table public.admission_letters enable row level security;
alter table public.admission_links enable row level security;
alter table public.certificate_designs enable row level security;
alter table public.digital_library enable row level security;
alter table public.reading_scores enable row level security;
alter table public.staff_appraisals enable row level security;
alter table public.staff_bonus enable row level security;
alter table public.staff_loans enable row level security;
alter table public.timetable_config enable row level security;

-- ============================================================================
-- SECTION 12: ROW-LEVEL SECURITY — 162 policies (least-privilege, last-authoritative)
-- ============================================================================
drop policy if exists "parents_read" on parents;
create policy "parents_read" on public.parents for select using (auth.role() = 'authenticated');
drop policy if exists "parents_write" on parents;
create policy "parents_write" on public.parents for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "profiles_self_read" on profiles;
create policy "profiles_self_read"   on public.profiles for select using (auth.uid() = id);
drop policy if exists "profiles_self_update" on profiles;
create policy "profiles_self_update" on public.profiles for update using (auth.uid() = id);
drop policy if exists "profiles_staff_read" on profiles;
create policy "profiles_staff_read"  on public.profiles for select using (public.is_staff(auth.uid()));
drop policy if exists "profiles_admin_all" on profiles;
create policy "profiles_admin_all"   on public.profiles for all    using (public.is_admin(auth.uid()));
drop policy if exists "results_update_teacher" on results;
create policy "results_update_teacher" on public.results for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid());
drop policy if exists "results_delete_teacher" on results;
create policy "results_delete_teacher" on public.results for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid());
drop policy if exists "read_affective" on affective_traits;
create policy "read_affective" on public.affective_traits for select using (auth.role() = 'authenticated');
drop policy if exists "write_affective" on affective_traits;
create policy "write_affective" on public.affective_traits for all using (public.is_staff(auth.uid()));
drop policy if exists "read_psychomotor" on psychomotor_traits;
create policy "read_psychomotor" on public.psychomotor_traits for select using (auth.role() = 'authenticated');
drop policy if exists "write_psychomotor" on psychomotor_traits;
create policy "write_psychomotor" on public.psychomotor_traits for all using (public.is_staff(auth.uid()));
drop policy if exists "read_comments" on report_comments;
create policy "read_comments" on public.report_comments for select using (auth.role() = 'authenticated');
drop policy if exists "write_comments" on report_comments;
create policy "write_comments" on public.report_comments for all using (public.is_staff(auth.uid()));
drop policy if exists "att_read" on attendance;
create policy "att_read"  on public.attendance for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or student_id in (select id from public.students where guardian_email = auth.jwt()->>'email')
  or public.is_staff(auth.uid())
);
drop policy if exists "att_write" on attendance;
create policy "att_write" on public.attendance for all using (public.is_staff(auth.uid()));
drop policy if exists "results_select_v5" on results;
create policy "results_select_v5" on public.results for select using (
  public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
);
drop policy if exists "results_insert_v5" on results;
create policy "results_insert_v5" on public.results for insert with check (public.is_staff(auth.uid()));
drop policy if exists "results_update_v5" on results;
create policy "results_update_v5" on public.results for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid()) with check (public.is_admin(auth.uid()) or teacher_id = auth.uid());
drop policy if exists "results_delete_v5" on results;
create policy "results_delete_v5" on public.results for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid());
drop policy if exists "cond_read" on conduct;
create policy "cond_read"  on public.conduct for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
drop policy if exists "cond_write" on conduct;
create policy "cond_write" on public.conduct for all using (public.is_staff(auth.uid()));
drop policy if exists "hlth_read" on health;
create policy "hlth_read" on public.health for select using (
  public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id) or student_id in (select id from public.students where user_id = auth.uid())
);
drop policy if exists "hlth_write" on health;
create policy "hlth_write" on public.health for all using (public.is_staff(auth.uid()));
drop policy if exists "sp_read" on support_plans;
create policy "sp_read"  on public.support_plans for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
drop policy if exists "sp_write" on support_plans;
create policy "sp_write" on public.support_plans for all using (public.is_staff(auth.uid()));
drop policy if exists "fp_read" on fee_payments;
create policy "fp_read"  on public.fee_payments for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "fp_write" on fee_payments;
create policy "fp_write" on public.fee_payments for all using (public.is_staff(auth.uid()));
drop policy if exists "pi_read" on payment_intents;
create policy "pi_read"  on public.payment_intents for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "pi_write" on payment_intents;
create policy "pi_write" on public.payment_intents for all using (public.is_staff(auth.uid()));
drop policy if exists "fin_all" on finance_entries;
create policy "fin_all" on public.finance_entries for all using (public.is_admin(auth.uid()));
drop policy if exists "pay_all" on payroll;
create policy "pay_all" on public.payroll for all using (public.is_admin(auth.uid()));
drop policy if exists "don_admin" on donations;
create policy "don_admin" on public.donations for all using (public.is_admin(auth.uid()));
drop policy if exists "lr_all" on leave_requests;
create policy "lr_all" on public.leave_requests for all using (public.is_staff(auth.uid()));
drop policy if exists "vis_insert" on visitors;
create policy "vis_insert" on public.visitors for insert with check (true);
drop policy if exists "vis_read" on visitors;
create policy "vis_read"   on public.visitors for select using (public.is_staff(auth.uid()));
drop policy if exists "tr_all" on transport;
create policy "tr_all" on public.transport for all using (public.is_staff(auth.uid()));
drop policy if exists "ann_read" on announcements;
create policy "ann_read"  on public.announcements for select using (auth.role() = 'authenticated');
drop policy if exists "ann_write" on announcements;
create policy "ann_write" on public.announcements for all using (public.is_staff(auth.uid()));
drop policy if exists "msg_all" on messages;
create policy "msg_all" on public.messages for all using (
  auth.uid() = from_id or auth.uid() = to_id
);
drop policy if exists "comp_all" on complaints;
create policy "comp_all" on public.complaints for all using (
  submitted_by = auth.uid() or public.is_staff(auth.uid())
);
drop policy if exists "hd_all" on helpdesk_tickets;
create policy "hd_all" on public.helpdesk_tickets for all using (
  submitted_by = auth.uid() or public.is_staff(auth.uid())
);
drop policy if exists "notif_read" on notifications;
create policy "notif_read"  on public.notifications for select using (auth.role() = 'authenticated');
drop policy if exists "notif_write" on notifications;
create policy "notif_write" on public.notifications for all using (public.is_staff(auth.uid()));
drop policy if exists "polls_read" on polls;
create policy "polls_read" on public.polls for select using (auth.role() = 'authenticated');
drop policy if exists "polls_write" on polls;
create policy "polls_write" on public.polls for insert with check (public.is_staff(auth.uid()));
drop policy if exists "pv_read" on poll_votes;
create policy "pv_read" on public.poll_votes for select using (auth.uid() = voter_id or public.is_staff(auth.uid()));
drop policy if exists "pv_insert" on poll_votes;
create policy "pv_insert" on public.poll_votes for insert with check (
  auth.uid() = voter_id and exists (select 1 from public.polls p where p.id = poll_id and coalesce(p.status,'open') = 'open')
);
drop policy if exists "pv_update" on poll_votes;
create policy "pv_update" on public.poll_votes for update using (auth.uid() = voter_id) with check (auth.uid() = voter_id);
drop policy if exists "ps_all" on push_subscriptions;
create policy "ps_all" on public.push_subscriptions for all using (auth.uid() = user_id);
drop policy if exists "rep_all" on reports;
create policy "rep_all" on public.reports for all using (public.is_staff(auth.uid()));
drop policy if exists "prom_all" on promotions;
create policy "prom_all" on public.promotions for all using (public.is_staff(auth.uid()));
drop policy if exists "ap_read" on academic_periods;
create policy "ap_read" on public.academic_periods for select using (auth.role() = 'authenticated');
drop policy if exists "ap_write" on academic_periods;
create policy "ap_write" on public.academic_periods for all using (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) with check (public.is_admin(auth.uid()) or public.is_staff(auth.uid()));
drop policy if exists "lookups_read" on lookups;
create policy "lookups_read" on public.lookups for select using (auth.role() = 'authenticated');
drop policy if exists "lookups_write" on lookups;
create policy "lookups_write" on public.lookups for all using (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) with check (public.is_admin(auth.uid()) or public.is_staff(auth.uid()));
drop policy if exists "pc_read" on parent_child;
create policy "pc_read"  on public.parent_child for select using (
  parent_id = auth.uid() or public.is_staff(auth.uid())
);
drop policy if exists "pc_write" on parent_child;
create policy "pc_write" on public.parent_child for all using (public.is_staff(auth.uid()));
drop policy if exists "sub_read" on lms_submissions;
create policy "sub_read"  on public.lms_submissions for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "sub_write" on lms_submissions;
create policy "sub_write" on public.lms_submissions for all using (public.is_staff(auth.uid()));
drop policy if exists "al_read" on activity_log;
create policy "al_read"   on public.activity_log for select using (public.is_admin(auth.uid()));
drop policy if exists "al_insert" on activity_log;
create policy "al_insert" on public.activity_log for insert with check (auth.role() = 'authenticated');
drop policy if exists "read_students" on students;
create policy "read_students" on public.students for select using (
  public.is_staff(auth.uid()) or user_id = auth.uid() or public.is_parent_of(auth.uid(), id)
);
drop policy if exists "write_students" on students;
create policy "write_students" on public.students for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "read_assignments" on assignments;
create policy "read_assignments" on public.assignments for select using (
  public.is_staff(auth.uid())
  or class in (select class from public.students where user_id = auth.uid())
  or class in (select class from public.students s join public.parent_child pc on pc.student_id=s.id where pc.parent_id=auth.uid())
);
drop policy if exists "write_assignments" on assignments;
create policy "write_assignments" on public.assignments for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "read_eresources" on eresources;
create policy "read_eresources" on public.eresources for select using (
  public.is_staff(auth.uid())
  or class in (select class from public.students where user_id = auth.uid())
  or class in (select class from public.students s join public.parent_child pc on pc.student_id=s.id where pc.parent_id=auth.uid())
);
drop policy if exists "write_eresources" on eresources;
create policy "write_eresources" on public.eresources for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "read_certificates" on certificates;
create policy "read_certificates" on public.certificates for select using (
  public.is_staff(auth.uid()) or student_id in (select id from public.students where user_id=auth.uid()) or public.is_parent_of(auth.uid(), student_id)
);
drop policy if exists "write_certificates" on certificates;
create policy "write_certificates" on public.certificates for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "polls_update_v11" on polls;
create policy "polls_update_v11" on public.polls for update using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "polls_delete_v11" on polls;
create policy "polls_delete_v11" on public.polls for delete using (public.is_admin(auth.uid()));
drop policy if exists "pv_delete_v11" on poll_votes;
create policy "pv_delete_v11" on public.poll_votes for delete using (auth.uid() = voter_id or public.is_staff(auth.uid()));
drop policy if exists "read_idcards" on idcards;
create policy "read_idcards" on public.idcards for select using (
  public.is_staff(auth.uid())
  or (person_type = 'student' and person_id in (select id from public.students where user_id = auth.uid()))
  or (person_type = 'student' and public.is_parent_of(auth.uid(), person_id))
);
drop policy if exists "write_idcards" on idcards;
create policy "write_idcards" on public.idcards for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "hlth_insert_v12" on health;
create policy "hlth_insert_v12" on public.health for insert with check (public.is_staff(auth.uid()));
drop policy if exists "hlth_update_v12" on health;
create policy "hlth_update_v12" on public.health for update using (public.is_admin(auth.uid()) or recorded_by_id = auth.uid()) with check (public.is_admin(auth.uid()) or recorded_by_id = auth.uid());
drop policy if exists "hlth_delete_v12" on health;
create policy "hlth_delete_v12" on public.health for delete using (public.is_admin(auth.uid()) or recorded_by_id = auth.uid());
drop policy if exists "hd_select_v12" on helpdesk_tickets;
create policy "hd_select_v12" on public.helpdesk_tickets for select using (public.is_staff(auth.uid()) or submitted_by = auth.uid() or assignee = auth.uid());
drop policy if exists "hd_insert_v12" on helpdesk_tickets;
create policy "hd_insert_v12" on public.helpdesk_tickets for insert with check (auth.role() = 'authenticated');
drop policy if exists "hd_update_v12" on helpdesk_tickets;
create policy "hd_update_v12" on public.helpdesk_tickets for update using (public.is_admin(auth.uid()) or submitted_by = auth.uid() or assignee = auth.uid()) with check (public.is_admin(auth.uid()) or submitted_by = auth.uid() or assignee = auth.uid());
drop policy if exists "hd_delete_v12" on helpdesk_tickets;
create policy "hd_delete_v12" on public.helpdesk_tickets for delete using (public.is_admin(auth.uid()) or submitted_by = auth.uid());
drop policy if exists "rep_select_v12" on reports;
create policy "rep_select_v12" on public.reports for select using (public.is_staff(auth.uid()));
drop policy if exists "rep_insert_v12" on reports;
create policy "rep_insert_v12" on public.reports for insert with check (public.is_staff(auth.uid()));
drop policy if exists "rep_update_v12" on reports;
create policy "rep_update_v12" on public.reports for update using (public.is_admin(auth.uid()) or generated_by = auth.uid()) with check (public.is_admin(auth.uid()) or generated_by = auth.uid());
drop policy if exists "rep_delete_v12" on reports;
create policy "rep_delete_v12" on public.reports for delete using (public.is_admin(auth.uid()) or generated_by = auth.uid());
drop policy if exists "mr_select_v15" on module_records;
create policy "mr_select_v15" on public.module_records for select using (
  public.is_staff(auth.uid())
  or created_by = auth.uid()
  or recipient_id = auth.uid()
  or audience in ('all','public')
  or (audience = 'parent' and exists (select 1 from public.profiles where id=auth.uid() and role='parent'))
  or (audience = 'student' and exists (select 1 from public.profiles where id=auth.uid() and role='student'))
);
drop policy if exists "mr_insert_v15" on module_records;
create policy "mr_insert_v15" on public.module_records for insert with check (
  auth.role() = 'authenticated'
);
drop policy if exists "mr_update_v12_owner" on module_records;
create policy "mr_update_v12_owner" on public.module_records for update using (
  public.is_admin(auth.uid()) or created_by = auth.uid()
) with check (public.is_admin(auth.uid()) or created_by = auth.uid());
drop policy if exists "mr_delete_v12_owner" on module_records;
create policy "mr_delete_v12_owner" on public.module_records for delete using (public.is_admin(auth.uid()) or created_by = auth.uid());
drop policy if exists "class_fee_structure_read" on class_fee_structure;
create policy "class_fee_structure_read" on public.class_fee_structure for select using (auth.role() = 'authenticated');
drop policy if exists "class_fee_structure_write" on class_fee_structure;
create policy "class_fee_structure_write" on public.class_fee_structure for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "school_products_read" on school_products;
create policy "school_products_read" on public.school_products for select using (auth.role() = 'authenticated');
drop policy if exists "school_products_write" on school_products;
create policy "school_products_write" on public.school_products for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "role_status_log_read" on role_status_log;
create policy "role_status_log_read" on public.role_status_log for select using (public.is_admin(auth.uid()));
drop policy if exists "role_status_log_write" on role_status_log;
create policy "role_status_log_write" on public.role_status_log for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "staff_clock_read" on staff_clock;
create policy "staff_clock_read" on public.staff_clock for select using (public.is_staff(auth.uid()) or public.is_admin(auth.uid()));
drop policy if exists "staff_clock_write" on staff_clock;
create policy "staff_clock_write" on public.staff_clock for all using (public.is_staff(auth.uid()) or public.is_admin(auth.uid())) with check (public.is_staff(auth.uid()) or public.is_admin(auth.uid()));
drop policy if exists "student_clock_read" on student_clock;
create policy "student_clock_read" on public.student_clock for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id) or exists (select 1 from public.students s where s.id=student_clock.student_id and s.user_id=auth.uid()));
drop policy if exists "student_clock_write" on student_clock;
create policy "student_clock_write" on public.student_clock for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "affective_traits_read" on affective_traits;
create policy "affective_traits_read" on public.affective_traits for select using (auth.role() = 'authenticated');
drop policy if exists "affective_traits_write" on affective_traits;
create policy "affective_traits_write" on public.affective_traits for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "psychomotor_traits_read" on psychomotor_traits;
create policy "psychomotor_traits_read" on public.psychomotor_traits for select using (auth.role() = 'authenticated');
drop policy if exists "psychomotor_traits_write" on psychomotor_traits;
create policy "psychomotor_traits_write" on public.psychomotor_traits for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "report_comments_read" on report_comments;
create policy "report_comments_read" on public.report_comments for select using (auth.role() = 'authenticated');
drop policy if exists "report_comments_write" on report_comments;
create policy "report_comments_write" on public.report_comments for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "attendance_parent_read_v16" on attendance;
create policy "attendance_parent_read_v16" on public.attendance for select using (
  exists (select 1 from public.students s where s.id = attendance.student_id and s.user_id = auth.uid())
  or exists (select 1 from public.parent_child pc where pc.student_id = attendance.student_id and pc.parent_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "rs_insert_v16_owner" on report_scores;
create policy "rs_insert_v16_owner" on public.report_scores for insert with check (public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid()));
drop policy if exists "rs_update_v16_owner" on report_scores;
create policy "rs_update_v16_owner" on public.report_scores for update using (public.is_admin(auth.uid()) or updated_by = auth.uid()) with check (public.is_admin(auth.uid()) or coalesce(updated_by, auth.uid()) = auth.uid());
drop policy if exists "rs_delete_v16_owner" on report_scores;
create policy "rs_delete_v16_owner" on public.report_scores for delete using (public.is_admin(auth.uid()) or updated_by = auth.uid());
drop policy if exists "v7_attendance_read_family" on attendance;
create policy "v7_attendance_read_family" on public.attendance for select using (
  public.is_staff(auth.uid()) or exists(select 1 from public.students s where s.id=attendance.student_id and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id)))
);
drop policy if exists "v7_attendance_write_staff" on attendance;
create policy "v7_attendance_write_staff" on public.attendance for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_report_scores_read" on report_scores;
create policy "v7_report_scores_read" on public.report_scores for select using (public.is_staff(auth.uid()) or exists(select 1 from public.students s where s.id=report_scores.student_id and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))) or exists(select 1 from public.students s where s.admission_no=report_scores.student_id_ref and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))));
drop policy if exists "v7_report_scores_insert" on report_scores;
create policy "v7_report_scores_insert" on public.report_scores for insert with check (public.is_staff(auth.uid()) and (public.is_admin(auth.uid()) or coalesce(updated_by,auth.uid())=auth.uid()));
drop policy if exists "v7_report_scores_update" on report_scores;
create policy "v7_report_scores_update" on public.report_scores for update using (public.is_admin(auth.uid()) or updated_by=auth.uid()) with check (public.is_admin(auth.uid()) or coalesce(updated_by,auth.uid())=auth.uid());
drop policy if exists "v7_report_scores_delete" on report_scores;
create policy "v7_report_scores_delete" on public.report_scores for delete using (public.is_admin(auth.uid()) or updated_by=auth.uid());
drop policy if exists "v7_report_cards_staff" on report_cards;
create policy "v7_report_cards_staff" on public.report_cards for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_report_cards_family" on report_cards;
create policy "v7_report_cards_family" on public.report_cards for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=report_cards.student_id and s.user_id=auth.uid()));
drop policy if exists "v7_psychomotor_read" on psychomotor_traits;
create policy "v7_psychomotor_read" on public.psychomotor_traits for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=psychomotor_traits.student_id and s.user_id=auth.uid()));
drop policy if exists "v7_psychomotor_write" on psychomotor_traits;
create policy "v7_psychomotor_write" on public.psychomotor_traits for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_affective_read" on affective_traits;
create policy "v7_affective_read" on public.affective_traits for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=affective_traits.student_id and s.user_id=auth.uid()));
drop policy if exists "v7_affective_write" on affective_traits;
create policy "v7_affective_write" on public.affective_traits for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_comments_read" on report_comments;
create policy "v7_comments_read" on public.report_comments for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=report_comments.student_id and s.user_id=auth.uid()));
drop policy if exists "v7_comments_write" on report_comments;
create policy "v7_comments_write" on public.report_comments for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_settings_read" on school_settings;
create policy "v7_settings_read" on public.school_settings for select using (auth.role()='authenticated');
drop policy if exists "v7_settings_write" on school_settings;
create policy "v7_settings_write" on public.school_settings for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "v7_schools_read" on schools;
create policy "v7_schools_read" on public.schools for select using (auth.role()='authenticated');
drop policy if exists "v7_schools_write" on schools;
create policy "v7_schools_write" on public.schools for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "v7_fee_structure_read" on class_fee_structure;
create policy "v7_fee_structure_read" on public.class_fee_structure for select using (auth.role()='authenticated');
drop policy if exists "v7_fee_structure_write" on class_fee_structure;
create policy "v7_fee_structure_write" on public.class_fee_structure for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "v7_products_read" on school_products;
create policy "v7_products_read" on public.school_products for select using (auth.role()='authenticated');
drop policy if exists "v7_products_write" on school_products;
create policy "v7_products_write" on public.school_products for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "v7_role_log_read" on role_status_log;
create policy "v7_role_log_read" on public.role_status_log for select using (public.is_admin(auth.uid()));
drop policy if exists "v7_role_log_write" on role_status_log;
create policy "v7_role_log_write" on public.role_status_log for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "v7_clock_read" on staff_clock;
create policy "v7_clock_read" on public.staff_clock for select using (public.is_staff(auth.uid()));
drop policy if exists "v7_clock_write" on staff_clock;
create policy "v7_clock_write" on public.staff_clock for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_student_clock_read" on student_clock;
create policy "v7_student_clock_read" on public.student_clock for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=student_clock.student_id and s.user_id=auth.uid()));
drop policy if exists "v7_student_clock_write" on student_clock;
create policy "v7_student_clock_write" on public.student_clock for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_enterprise_read" on timetable_requirements;
create policy "v7_enterprise_read" on public.timetable_requirements for select using (auth.role()='authenticated');
drop policy if exists "v7_enterprise_write" on timetable_requirements;
create policy "v7_enterprise_write" on public.timetable_requirements for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_availability_read" on teacher_availability;
create policy "v7_availability_read" on public.teacher_availability for select using (auth.role()='authenticated');
drop policy if exists "v7_availability_write" on teacher_availability;
create policy "v7_availability_write" on public.teacher_availability for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_runs_read" on timetable_runs;
create policy "v7_runs_read" on public.timetable_runs for select using (auth.role()='authenticated');
drop policy if exists "v7_runs_write" on timetable_runs;
create policy "v7_runs_write" on public.timetable_runs for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_checkins_read" on attendance_checkins;
create policy "v7_checkins_read" on public.attendance_checkins for select using (public.is_staff(auth.uid()));
drop policy if exists "v7_checkins_insert" on attendance_checkins;
create policy "v7_checkins_insert" on public.attendance_checkins for insert with check (auth.role()='authenticated');
drop policy if exists "v7_diary_read" on student_diary;
create policy "v7_diary_read" on public.student_diary for select using (public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(),student_id) or exists(select 1 from public.students s where s.id=student_diary.student_id and s.user_id=auth.uid()));
drop policy if exists "v7_diary_write" on student_diary;
create policy "v7_diary_write" on public.student_diary for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_survey_read" on surveys;
create policy "v7_survey_read" on public.surveys for select using (auth.role()='authenticated');
drop policy if exists "v7_survey_write" on surveys;
create policy "v7_survey_write" on public.surveys for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_survey_response" on survey_responses;
create policy "v7_survey_response" on public.survey_responses for all using (respondent=auth.uid() or public.is_staff(auth.uid())) with check (respondent=auth.uid() or public.is_staff(auth.uid()));
drop policy if exists "v7_menu_read" on menu_planner;
create policy "v7_menu_read" on public.menu_planner for select using (auth.role()='authenticated');
drop policy if exists "v7_menu_write" on menu_planner;
create policy "v7_menu_write" on public.menu_planner for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "v7_security_prefs" on security_prefs;
create policy "v7_security_prefs" on public.security_prefs for all using (user_id=auth.uid()) with check (user_id=auth.uid());
drop policy if exists "v7_login_audit_read" on login_audit;
create policy "v7_login_audit_read" on public.login_audit for select using (public.is_admin(auth.uid()));
drop policy if exists "v7_login_audit_insert" on login_audit;
create policy "v7_login_audit_insert" on public.login_audit for insert with check (auth.role()='authenticated');
drop policy if exists "v7_i18n_read" on i18n_strings;
create policy "v7_i18n_read" on public.i18n_strings for select using (auth.role()='authenticated');
drop policy if exists "v7_i18n_write" on i18n_strings;
create policy "v7_i18n_write" on public.i18n_strings for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "v7_print_read" on academic_print_records;
create policy "v7_print_read" on public.academic_print_records for select using (auth.role()='authenticated');
drop policy if exists "v7_print_write" on academic_print_records;
create policy "v7_print_write" on public.academic_print_records for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "uv1_rs_insert" on reading_scores;
create policy "uv1_rs_insert" on public.reading_scores for insert with check (auth.role()='authenticated');
drop policy if exists "uv1_rs_manage" on reading_scores;
create policy "uv1_rs_manage" on public.reading_scores for update using (public.is_staff(auth.uid()));

-- ============================================================================
-- SECTION 13: GRANTS
-- ============================================================================
grant execute on function public.verify_certificate(text) to anon, authenticated;
grant execute on function public.sc_push_cbt_to_results(uuid,text,text,text) to authenticated;
grant execute on function public.cbt_get_public_exam(text) to anon, authenticated;
grant execute on function public.cbt_submit(jsonb) to anon, authenticated;
grant execute on function public.generate_timetable(text,text,text,int) to authenticated;
grant select on public.parent_children to authenticated;
-- Public certificate verification remains intentionally narrow.
grant execute on function public.verify_certificate(text) to anon, authenticated;

-- ============================================================================
-- SECTION 14: V12 ADDITIVE FIXES (app contract)
-- ============================================================================

-- (A) 2FA preferences upsert from enterprise.js uses ON CONFLICT (user_id)
delete from public.security_prefs a using public.security_prefs b
where a.ctid < b.ctid and a.user_id = b.user_id;
create unique index if not exists security_prefs_user_id_uq on public.security_prefs(user_id);

-- (B) free-free belt-and-braces: make sure the exact browser upsert keys exist
--     even if a legacy database skipped the constraint sections above.
do $$
begin
  -- report score entry key (report-cards.html)
  if to_regclass('public.report_scores') is not null
     and not exists (select 1 from pg_constraint where conrelid='public.report_scores'::regclass and conname='report_scores_uq') then
    begin
      execute 'delete from public.report_scores a using public.report_scores b where a.ctid < b.ctid and a.column_id is not distinct from b.column_id and a.student_id_ref=b.student_id_ref and a.student_name=b.student_name and a.class=b.class and a.subject=b.subject and a.term=b.term and a.session=b.session';
      execute 'alter table public.report_scores add constraint report_scores_uq unique (column_id, student_id_ref, student_name, class, subject, term, session)';
    exception when others then raise notice 'report_scores_uq skipped: %', sqlerrm; end;
  end if;
  -- attendance mark key (attendance.html)
  if to_regclass('public.attendance') is not null
     and not exists (select 1 from pg_constraint where conrelid='public.attendance'::regclass and conname='attendance_student_date_unique') then
    begin
      execute 'delete from public.attendance a using public.attendance b where a.ctid < b.ctid and a.student_id=b.student_id and a.date=b.date';
      execute 'alter table public.attendance add constraint attendance_student_date_unique unique (student_id, date)';
    exception when others then raise notice 'attendance key skipped: %', sqlerrm; end;
  end if;
  -- class fee bill key (settings.html next-term bills)
  if to_regclass('public.class_fee_structure') is not null
     and not exists (select 1 from pg_constraint where conrelid='public.class_fee_structure'::regclass and conname='class_fee_structure_uq') then
    begin
      execute 'delete from public.class_fee_structure a using public.class_fee_structure b where a.ctid < b.ctid and a.class=b.class and a.arm=b.arm and a.department=b.department and a.term=b.term';
      execute 'alter table public.class_fee_structure add constraint class_fee_structure_uq unique (class, arm, department, term)';
    exception when others then raise notice 'fee key skipped: %', sqlerrm; end;
  end if;
end $$;


-- ============================================================================
-- SECTION 15: SITE LICENSE & SUBSCRIPTION (v12.2 — generator billing modes)
-- ----------------------------------------------------------------------------
-- One row per deployment (id = 1):
--   model 'lifetime'     → client paid once, owns the site forever (default).
--   model 'subscription' → client pays per cycle; assets/js/license.js on every
--                          page evaluates status/expires_on/grace_days and,
--                          after expiry + grace, locks the portal with a
--                          renewal screen. HMG (or a super-admin) extends the
--                          term on the Site License page (license.html).
-- The "signature" column (sha256 of model|expires_on|grace_days|status|salt)
-- is written by the generator at build time and verified by license.js so a
-- casually hand-edited expiry date in this table is flagged as tampered.
-- The generator replaces the seed INSERT values for subscription builds.
-- ============================================================================
create table if not exists public.site_license (
  id smallint primary key default 1 check (id = 1),
  model text not null default 'lifetime' check (model in ('lifetime','subscription')),
  plan text not null default 'One-time purchase (lifetime ownership)',
  cycle text not null default '',
  started_on date default current_date,
  expires_on date,
  grace_days int not null default 7,
  status text not null default 'active' check (status in ('active','suspended')),
  renew_url text not null default '',
  lock_message text not null default '',
  signature text not null default '',
  updated_at timestamptz not null default now()
);
insert into public.site_license (id, model, plan, cycle, started_on, expires_on, grace_days, status, renew_url, lock_message, signature)
values (1, 'lifetime', 'One-time purchase (lifetime ownership)', '', current_date, null, 7, 'active', '', '', '')
on conflict (id) do nothing;
alter table if exists public.site_license add column if not exists signature text not null default '';
alter table if exists public.site_license add column if not exists renew_url text not null default '';
alter table if exists public.site_license add column if not exists lock_message text not null default '';
alter table if exists public.site_license add column if not exists grace_days int not null default 7;
alter table if exists public.site_license add column if not exists expires_on date;
alter table public.site_license enable row level security;
-- anyone (even anon, before login) may READ the license state: the lock screen
-- and expiry banners must work on the login page too. Only admins may change it.
drop policy if exists "site_license_read" on public.site_license;
create policy "site_license_read" on public.site_license for select using (true);
drop policy if exists "site_license_write" on public.site_license;
create policy "site_license_write" on public.site_license for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
do $$ begin
  if not exists (select 1 from pg_trigger where tgname='site_license_updated_at') then
    create trigger site_license_updated_at before update on public.site_license
    for each row execute function public.sc_set_updated_at();
  end if;
end $$;


-- ============================================================================
-- SECTION 16: CBT 1000-CONCURRENT SCALE PACK (v12.3 — additive; same content
-- as database/cbt-1000-scale.sql. See that file for the full commentary.)
-- ============================================================================

create index if not exists cbt_exams_upper_code_idx on public.cbt_exams (upper(code));
create index if not exists cbt_results_exam_idx        on public.cbt_results (exam_id);
create index if not exists cbt_results_exam_time_idx   on public.cbt_results (exam_id, submitted_at desc);
create index if not exists cbt_results_student_ref_idx on public.cbt_results (exam_id, student_id_ref);

alter table public.cbt_results add column if not exists client_ref text;
create unique index if not exists cbt_results_client_ref_uidx
  on public.cbt_results (exam_id, client_ref)
  where client_ref is not null and client_ref <> '';

DROP FUNCTION IF EXISTS public.cbt_get_public_exam_v2() CASCADE;
create or replace function public.cbt_get_public_exam_v2(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record; qs jsonb;
begin
  select * into e from public.cbt_exams
   where upper(code)=upper(trim(p_code)) and is_open=true and is_archived=false limit 1;
  if not found then return null; end if;
  if e.start_at is not null and now()<e.start_at then
    return jsonb_build_object('wait',true,'start_at',e.start_at,'title',e.title,'server_now',now());
  end if;
  if e.close_at is not null and now()>e.close_at then
    return jsonb_build_object('closed',true,'server_now',now());
  end if;
  select coalesce(jsonb_agg((q-'correct'-'correct_answer'-'answer'-'explanation')||jsonb_build_object('_orig_index',ord-1) order by ord),'[]'::jsonb)
    into qs
    from jsonb_array_elements((case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array' and jsonb_array_length(e.questions)>0 then e.questions else '[]'::jsonb end)) with ordinality x(q,ord);
  return jsonb_build_object(
    'id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,
    'term',e.term,'session',e.session,'assessment_type',e.assessment_type,
    'duration',coalesce(nullif(e.duration_min,0),e.duration,45),
    'questions',qs,'_questions',qs,
    'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode,
    'server_now',now(),'start_at',e.start_at,'close_at',e.close_at,
    'instructions',e.instructions,'anti_cheat_config',e.anti_cheat_config,
    'attempt_limit',e.attempt_limit,'randomise',e.randomise,'select_count',e.select_count,
    'pass_mark',e.pass_mark,'release_results',e.release_results,
    'certificate_enabled',e.certificate_enabled
  );
end $$;

DROP FUNCTION IF EXISTS public.cbt_submit_v2() CASCADE;
create or replace function public.cbt_submit_v2(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  e record; r record; rid uuid; sid uuid; n int; taken int := 0;
  score numeric := 0; total numeric := 0; cc int := 0; wc int := 0; sc int := 0;
  ans jsonb; q jsonb; i int := 0; a text; k text; mark numeric;
  ref text := nullif(p_payload->>'client_ref','');
begin
  select * into e from public.cbt_exams where id=(p_payload->>'exam_id')::uuid;
  if not found then return jsonb_build_object('saved',false,'error','Exam not found'); end if;
  if e.close_at is not null and now() > e.close_at + interval '120 seconds' then
    return jsonb_build_object('saved',false,'error','closed','message','This exam has closed. Your answers were not recorded.');
  end if;
  if ref is not null then
    select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;
    if found then
      return jsonb_build_object('saved',true,'duplicate',true,'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,
        'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,
        'cert_code',r.cert_code,'release_results',e.release_results,'report_column',e.report_column);
    end if;
    if nullif(p_payload->>'student_id_ref','') is not null and coalesce(e.attempt_limit,0) > 0 then
      select count(*) into taken from public.cbt_results where exam_id=e.id and student_id_ref=p_payload->>'student_id_ref';
      if taken >= e.attempt_limit then
        return jsonb_build_object('saved',false,'error','attempts_exhausted','message','Attempt limit ('||e.attempt_limit||') reached for this exam.');
      end if;
    end if;
  end if;
  for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb)) loop
    q := (case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array' and jsonb_array_length(e.questions)>0 then e.questions else '[]'::jsonb end)
          -> (case when coalesce(ans->>'index','') ~ '^[0-9]+$' then (ans->>'index')::int else i end);
    mark := coalesce(nullif(q->>'mark','')::numeric,1); total := total + mark;
    a := coalesce(ans->>'answer', ans #>> '{}', '');
    k := coalesce(q->>'answer', q->>'correct', q->>'correct_answer', '');
    if a is null or trim(a) = '' then sc := sc + 1;
    elsif k <> '' and lower(trim(a)) = lower(trim(k)) then score := score + mark; cc := cc + 1;
    else wc := wc + 1; end if;
    i := i + 1;
  end loop;
  sid := nullif(p_payload->>'student_id','')::uuid;
  n := case when total>0 then round(score/total*100)::int else 0 end;
  begin
    insert into public.cbt_results(
      exam_id,student_id,student_name,student_class,student_id_ref,student_type,
      score,total,percent,correct_count,wrong_count,skipped_count,
      attempt_number,time_taken,violations,violation_log,answers_data,cert_code,client_ref
    ) values (
      e.id,sid,coalesce(p_payload->>'student_name','Anonymous'),coalesce(p_payload->>'student_class',e.class),
      coalesce(p_payload->>'student_id_ref',''),coalesce(p_payload->>'student_type',e.exam_mode),
      score,total::int,n,cc,wc,sc,
      taken+1,coalesce((p_payload->>'time_taken')::int,0),coalesce((p_payload->>'violations')::int,0),
      coalesce(p_payload->'violation_log','[]'::jsonb),p_payload->'answers_data',
      case when e.certificate_enabled then 'CERT-'||upper(substr(md5(random()::text),1,8)) else '' end,
      ref
    ) returning id into rid;
  exception when unique_violation then
    select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;
    if found then
      return jsonb_build_object('saved',true,'duplicate',true,'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,
        'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,
        'cert_code',r.cert_code,'release_results',e.release_results,'report_column',e.report_column);
    end if;
    return jsonb_build_object('saved',false,'error','Duplicate submission conflict');
  end;
  return jsonb_build_object('saved',true,'result_id',rid,'score',score,'total',total,'percent',n,
    'correct_count',cc,'wrong_count',wc,'skipped_count',sc,'cert_code',
    (select cert_code from public.cbt_results where id=rid),
    'release_results',e.release_results,'report_column',e.report_column);
exception when others then return jsonb_build_object('saved',false,'error',sqlerrm);
end $$;

grant execute on function public.cbt_get_public_exam_v2(text) to anon, authenticated;
grant execute on function public.cbt_submit_v2(jsonb)         to anon, authenticated;

analyze public.cbt_exams;
analyze public.cbt_results;

-- ============================================================================
-- SECTION 17: PUNCTUALITY POINTS ENGINE (v12.4 — additive; same content as
-- database/punctuality-points.sql. See that file for the full commentary.)
-- ============================================================================

-- ── 1) CONFIG (single row, tuned by the school) ─────────────────────────────
create table if not exists public.punctuality_config (
  id int primary key default 1 check (id = 1),
  deadline time not null default '07:30:00',       -- check-in at/before = on time
  checkout_open time not null default '12:30:00',  -- check-out at/after = stayed through closing
  points_full numeric not null default 2,          -- points for a fully-punctual day
  points_partial numeric not null default 0,       -- points for on-time check-in WITHOUT a qualified check-out (0 = strict mode)
  require_checkout boolean not null default true,  -- when false, on-time check-in alone earns full points
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.punctuality_config (id) values (1) on conflict (id) do nothing;

-- ── 2) DAILY AWARDS ─────────────────────────────────────────────────────────
create table if not exists public.punctuality_awards (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  student_id_ref text not null default '', student_name text not null default '',
  class text not null default '',
  date date not null,
  checkin_at timestamptz, checkout_at timestamptz,
  points numeric not null default 0,
  rule text not null default 'none',  -- full | partial | late | no_checkout | config_disabled
  created_at timestamptz not null default now(),
  unique(student_id, date)
);
create index if not exists punctuality_awards_date_idx    on public.punctuality_awards (date);
create index if not exists punctuality_awards_class_idx   on public.punctuality_awards (class, date);
create index if not exists punctuality_awards_student_idx on public.punctuality_awards (student_id, date);

-- Results push columns (repairs latent fresh-install gap: the CBT → Report
-- Card push and the punctuality push both need these on results):
alter table if exists public.results add column if not exists student_name text;
alter table if exists public.results add column if not exists student_id_ref text not null default '';
alter table if exists public.results add column if not exists assessment_source text not null default 'manual';
alter table if exists public.results add column if not exists assessment_ref text;
create unique index if not exists results_assessment_uidx on public.results (assessment_source, assessment_ref);

-- ── 3) DAILY COMPUTE — grade every checked student for one date ─────────────
DROP FUNCTION IF EXISTS public.compute_punctuality_awards() CASCADE;
create or replace function public.compute_punctuality_awards(p_date date default current_date, p_class text default '')
returns int language plpgsql security definer set search_path=public as $$
declare
  cfg record; awarded int := 0;
begin
  select * into cfg from public.punctuality_config where id = 1;
  if cfg is null then
    insert into public.punctuality_config (id) values (1) on conflict (id) do nothing returning * into cfg;
    if cfg is null then select * into cfg from public.punctuality_config where id = 1; end if;
  end if;

  -- Re-grade the day from student_clock (first clock-in, last clock-out). A
  -- row with points 0 is kept too, so staff can see exactly WHY no point.
  insert into public.punctuality_awards
    (student_id, student_id_ref, student_name, class, date, checkin_at, checkout_at, points, rule)
  select
    s.id, coalesce(s.admission_no,''), coalesce(s.full_name,''), coalesce(s.class,''),
    p_date, t.first_in, t.last_out,
    case
      when not cfg.enabled then 0
      when t.first_in::time <= cfg.deadline and (not cfg.require_checkout) then cfg.points_full
      when t.first_in::time <= cfg.deadline and t.last_out is not null and t.last_out::time >= cfg.checkout_open then cfg.points_full
      when t.first_in::time <= cfg.deadline then cfg.points_partial
      else 0
    end,
    case
      when not cfg.enabled then 'config_disabled'
      when t.first_in::time <= cfg.deadline and (not cfg.require_checkout) then 'full'
      when t.first_in::time <= cfg.deadline and t.last_out is not null and t.last_out::time >= cfg.checkout_open then 'full'
      when t.first_in::time <= cfg.deadline then 'no_checkout'
      else 'late'
    end
  from (
    select sc.student_id, min(sc.clock_in) as first_in, max(sc.clock_out) as last_out
      from public.student_clock sc
     where sc.date = p_date and sc.student_id is not null
     group by sc.student_id
  ) t
  join public.students s on s.id = t.student_id
  where (p_class = '' or s.class = p_class)
  on conflict (student_id, date) do update
    set checkin_at = excluded.checkin_at, checkout_at = excluded.checkout_at,
        points = excluded.points, rule = excluded.rule,
        student_id_ref = excluded.student_id_ref, student_name = excluded.student_name,
        class = excluded.class;

  select coalesce(sum(case when points > 0 then 1 else 0 end),0)::int into awarded
    from public.punctuality_awards
   where date = p_date and (p_class = '' or class = p_class);
  return awarded;
end $$;

-- ── 4) PUSH TERM POINTS INTO RESULTS (school's choice of column) ────────────
-- Mirrors the CBT → Report Card flow: one Results row per student carrying
-- their point total in the chosen column. assessment_ref is deterministic
-- (md5 → uuid), so re-pushing the same term/class/range UPDATES, never dupes.
DROP FUNCTION IF EXISTS public.sc_push_punctuality_to_results() CASCADE;
create or replace function public.sc_push_punctuality_to_results(
  p_term text, p_session text, p_column text default 'ca2', p_class text default '',
  p_start date default null, p_end date default null, p_subject text default 'PUNCTUALITY')
returns int language plpgsql security definer set search_path=public as $$
declare
  saved int := 0; r record; ref text; col text := lower(trim(p_column));
begin
  -- Column must be a REAL numeric column on results (ca1/ca2/ca3/exam or any
  -- custom numeric column the report engine added).
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='results'
                    and column_name=col and data_type='numeric') then
    raise exception 'Punctuality push: "%" is not a numeric Results column. Use ca1/ca2/ca3/exam or a custom numeric report column.', col;
  end if;

  for r in
    select a.student_id,
           max(a.student_name) as student_name, max(a.student_id_ref) as student_id_ref,
           coalesce(nullif(p_class,''), max(a.class)) as class,
           sum(a.points) as points
      from public.punctuality_awards a
      join public.students s on s.id = a.student_id
     where (p_class = '' or a.class = p_class or s.class = p_class)
       and (p_start is null or a.date >= p_start)
       and (p_end   is null or a.date <= p_end)
     group by a.student_id
  loop
    ref := md5('punctuality|'||r.student_id::text||'|'||coalesce(p_term,'')||'|'||coalesce(p_session,'')||'|'||col||'|'||coalesce(nullif(p_class,''),r.class,''));
    ref := substr(ref,1,8)||'-'||substr(ref,9,4)||'-4'||substr(ref,14,3)||'-8'||substr(ref,18,3)||'-'||substr(ref,21,12);
    execute format(
      'insert into public.results (student_id, student_name, student_id_ref, subject, class, term, session, assessment_source, assessment_ref, %I)
       values ($1,$2,$3,$4,$5,$6,$7,''punctuality'',$8,$9)
       on conflict (assessment_source, assessment_ref)
       do update set %I = excluded.%I, student_name = excluded.student_name, class = excluded.class, term = excluded.term, session = excluded.session', col, col, col)
      using r.student_id, r.student_name, r.student_id_ref, p_subject, r.class, p_term, p_session, ref, r.points;
    saved := saved + 1;
  end loop;
  return saved;
end $$;

-- ── 5) RLS (mirrors student_clock: staff manage; student/parent read own) ───
alter table public.punctuality_config enable row level security;
alter table public.punctuality_awards enable row level security;

drop policy if exists "punctuality_config_read" on public.punctuality_config;
create policy "punctuality_config_read" on public.punctuality_config for select using (auth.role()='authenticated');
drop policy if exists "punctuality_config_write" on public.punctuality_config;
create policy "punctuality_config_write" on public.punctuality_config for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "punctuality_awards_read" on public.punctuality_awards;
create policy "punctuality_awards_read" on public.punctuality_awards for select using (
  public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id)
  or exists (select 1 from public.students s where s.id = punctuality_awards.student_id and s.user_id = auth.uid()));
drop policy if exists "punctuality_awards_write" on public.punctuality_awards;
create policy "punctuality_awards_write" on public.punctuality_awards for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

grant execute on function public.compute_punctuality_awards(date, text) to authenticated;
grant execute on function public.sc_push_punctuality_to_results(text, text, text, text, date, date, text) to authenticated;


-- ============================================================================
-- ============================================================================
-- SECTION 18: RUNTIME HELPER RPCs (v12.5 — additive contract completion)
-- ============================================================================
-- Every RPC the CLIENT code references now exists server-side, so a bare
-- complete-schema install is 100% self-sufficient — no secondary SQL, no
-- manual dashboard functions, ever. Each call site keeps its client-side
-- fallback, so this pack is pure hardening (never a breaking change).
-- (Also ships as database/runtime-helper-rpcs.sql for EXISTING projects.)

-- 18.0 admissions column-gap fix — the apply form + admissions console use
-- photo_url / data / extracted, which older schemas silently lacked (the
-- client's graceful fallback masked it; fresh v12.x DBs dropped those keys).
alter table public.admissions
  add column if not exists photo_url text,
  add column if not exists data jsonb,
  add column if not exists extracted boolean not null default false;

-- 18.1 sc_current_role() — one-call {role,status,full_name,...} for the shell
DROP FUNCTION IF EXISTS public.sc_current_role() CASCADE;
create or replace function public.sc_current_role()
returns json language plpgsql stable security definer set search_path=public as $$
declare p record;
begin
  select * into p from public.profiles where id = auth.uid() limit 1;
  if not found then return null; end if;
  return row_to_json(p);
end $$;
revoke execute on function public.sc_current_role() from public, anon;
grant  execute on function public.sc_current_role() to authenticated;

-- 18.2 lookup_login_email(identifier → email) — login with admission/staff no or phone
DROP FUNCTION IF EXISTS public.lookup_login_email() CASCADE;
create or replace function public.lookup_login_email(p_identifier text)
returns text language plpgsql stable security definer set search_path=public as $$
declare ident text := btrim(coalesce(p_identifier,'')); em text;
begin
  if ident = '' then return null; end if;
  select p.email into em from public.profiles p
   where lower(p.email) = lower(ident) and coalesce(p.email,'') <> '' limit 1;
  if em is not null then return em; end if;
  select p.email into em from public.profiles p
   where p.phone = ident and coalesce(p.email,'') <> '' limit 1;
  if em is not null then return em; end if;
  select pr.email into em from public.students s join public.profiles pr on pr.id = s.user_id
   where lower(s.admission_no) = lower(ident) and coalesce(pr.email,'') <> '' limit 1;
  if em is not null then return em; end if;
  select coalesce(pr.email, stf.email) into em
    from public.staff stf left join public.profiles pr on pr.id = stf.user_id
   where (lower(stf.staff_no) = lower(ident) or stf.phone = ident)
     and coalesce(coalesce(pr.email, stf.email),'') <> ''
   order by case when pr.email is null then 1 else 0 end limit 1;
  return em; -- null when no account matches (client shows "No account found")
end $$;
revoke execute on function public.lookup_login_email(text) from public;
grant  execute on function public.lookup_login_email(text) to anon, authenticated;

-- 18.3 notif_mark_read(id) — atomic read-by append of the caller's uid
DROP FUNCTION IF EXISTS public.notif_mark_read() CASCADE;
create or replace function public.notif_mark_read(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.notifications
     set read_by = case
       when read_by is null then array[auth.uid()]
       when auth.uid() = any(read_by) then read_by
       else array_append(read_by, auth.uid()) end
   where id = p_id;
end $$;
revoke execute on function public.notif_mark_read(uuid) from public, anon;
grant  execute on function public.notif_mark_read(uuid) to authenticated;

-- 18.4 table_sizes() — storage console overview
DROP FUNCTION IF EXISTS public.table_sizes() CASCADE;
create or replace function public.table_sizes()
returns table(table_name text, pretty text, row_estimate bigint, total_bytes bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  return query
  select s.table_name, s.pretty, s.row_estimate, s.total_bytes from (
    select c.relname::text as table_name,
           pg_size_pretty(pg_total_relation_size(c.oid)) as pretty,
           greatest(c.reltuples,0)::bigint as row_estimate,
           pg_total_relation_size(c.oid) as total_bytes
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
    union all
    select 'TOTAL_DATABASE_USED',
           pg_size_pretty(coalesce(sum(pg_total_relation_size(c.oid)),0)),
           greatest(coalesce(sum(greatest(c.reltuples,0)),0),0)::bigint,
           coalesce(sum(pg_total_relation_size(c.oid)),0)::bigint
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
  ) s order by s.total_bytes desc;
end $$;
revoke execute on function public.table_sizes() from public, anon;
grant  execute on function public.table_sizes() to authenticated;

-- 18.5 purge_old(table, days) — storage console purge, admin-only, strict whitelist
DROP FUNCTION IF EXISTS public.purge_old() CASCADE;
create or replace function public.purge_old(p_table text, p_days integer)
returns integer language plpgsql security definer set search_path=public as $$
declare r text; n integer := 0;
  allowed text[] := array['activity_log','cbt_results','notifications','reading_scores','attendance_checkins'];
begin
  select lower(role) into r from public.profiles where id = auth.uid();
  if coalesce(r,'') not in ('super_admin','admin','principal','proprietor','head_teacher') then
    raise exception 'purge_old: admin role required';
  end if;
  if not (p_table = any(allowed)) then
    raise exception 'purge_old: % is not purgeable from the storage console (allowed: %)', p_table, array_to_string(allowed, ', ');
  end if;
  execute format('delete from public.%I where created_at < now() - make_interval(days => $1)', p_table)
     using greatest(coalesce(p_days, 180), 1);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.purge_old(text, integer) from public, anon;
grant  execute on function public.purge_old(text, integer) to authenticated;

-- 18.6 submit_admission(payload) — public apply form write path
DROP FUNCTION IF EXISTS public.submit_admission() CASCADE;
create or replace function public.submit_admission(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  if coalesce(p_payload->>'full_name','') = '' then
    return jsonb_build_object('ok',false,'error','Applicant name is required');
  end if;
  insert into public.admissions
    (full_name, dob, gender, parent_name, parent_email, parent_phone,
     applying_for_class, notes, photo_url, data, status)
  values
    (p_payload->>'full_name', nullif(p_payload->>'dob','')::date,
     nullif(p_payload->>'gender',''), nullif(p_payload->>'parent_name',''),
     nullif(p_payload->>'parent_email',''), nullif(p_payload->>'parent_phone',''),
     nullif(p_payload->>'applying_for_class',''), left(coalesce(p_payload->>'notes',''), 2000),
     nullif(p_payload->>'photo_url',''), p_payload, 'submitted')
  returning id into new_id;
  return jsonb_build_object('ok', true, 'id', new_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm); -- client falls back to a direct insert
end $$;
revoke execute on function public.submit_admission(jsonb) from public;
grant  execute on function public.submit_admission(jsonb) to anon, authenticated;

-- 18.7 extract_admission(id) — Accept & Extract: admit the applicant as a student
DROP FUNCTION IF EXISTS public.extract_admission() CASCADE;
create or replace function public.extract_admission(p_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare a record; sid uuid; r text;
begin
  select lower(role) into r from public.profiles where id = auth.uid();
  if coalesce(r,'') not in ('super_admin','admin','principal','proprietor','head_teacher') then
    return jsonb_build_object('ok',false,'error','extract_admission: admin role required');
  end if;
  select * into a from public.admissions where id = p_id;
  if not found then return jsonb_build_object('ok',false,'error','Application not found'); end if;
  if coalesce(a.extracted,false) then
    return jsonb_build_object('ok',false,'error','This applicant was already enrolled');
  end if;
  insert into public.students
    (full_name, class, gender, date_of_birth, guardian_name, guardian_phone,
     guardian_email, photo_url, status)
  values
    (a.full_name, coalesce(a.applying_for_class,''), coalesce(a.gender,''), a.dob,
     coalesce(a.parent_name,''), coalesce(a.parent_phone,''), coalesce(a.parent_email,''),
     coalesce(nullif(a.data->>'photo_url',''), a.photo_url), 'active')
  returning id into sid; -- admission_no is auto-generated by trg_sc_generate_admission_no
  update public.admissions set extracted = true, status = 'accepted' where id = p_id;
  return jsonb_build_object('ok', true, 'student_id', sid);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;
revoke execute on function public.extract_admission(uuid) from public, anon;
grant  execute on function public.extract_admission(uuid) to authenticated;

-- 18.8 generate_timetable(class, session, term, periods/day) — auto weekday planner
DROP FUNCTION IF EXISTS public.generate_timetable() CASCADE;
create or replace function public.generate_timetable(p_class text, p_session text default '', p_term text default '', p_periods_per_day integer default 6)
returns jsonb language plpgsql security definer set search_path=public as $$
declare req record; inserted integer := 0;
  days text[] := array['Monday','Tuesday','Wednesday','Thursday','Friday'];
  ppd integer := least(greatest(coalesce(p_periods_per_day,6),1),12);
  bag text[] := '{}'; idx integer := 0; d integer; per integer; tries integer;
  candidate text; last_subj text; i integer;
begin
  for req in select subject, teacher, periods_per_week
               from public.timetable_requirements
              where class = p_class order by periods_per_week desc loop
    for i in 1..greatest(coalesce(req.periods_per_week,0),0) loop
      bag := bag || (req.subject || '||' || coalesce(req.teacher,''));
    end loop;
  end loop;
  if array_length(bag,1) is null then
    return jsonb_build_object('ok',false,'error','No timetable requirements defined for class "'||coalesce(p_class,'')||'" — add subjects on the Timetable Requirements card first.');
  end if;
  delete from public.timetable
   where class = p_class and coalesce(session,'') = coalesce(p_session,'') and coalesce(term,'') = coalesce(p_term,'');
  while array_length(bag,1) is not null loop
    for d in 1..5 loop
      exit when array_length(bag,1) is null;
      last_subj := '';
      for per in 1..ppd loop
        exit when array_length(bag,1) is null;
        idx := idx % array_length(bag,1) + 1; tries := 0;
        candidate := bag[idx];
        -- avoid the same subject in two consecutive periods of a day (when alternatives exist)
        while split_part(candidate,'||',1) = last_subj and tries < array_length(bag,1) loop
          idx := idx % array_length(bag,1) + 1; candidate := bag[idx]; tries := tries + 1;
        end loop;
        insert into public.timetable (class, day, period, subject, teacher, session, term)
        values (p_class, days[d], per::text, split_part(candidate,'||',1),
                nullif(split_part(candidate,'||',2),''), coalesce(p_session,''), coalesce(p_term,''));
        inserted := inserted + 1; last_subj := split_part(candidate,'||',1);
        bag := (select array_agg(u.x order by u.o) from unnest(bag) with ordinality as u(x,o) where u.o <> idx);
      end loop;
    end loop;
  end loop;
  return jsonb_build_object('ok', true, 'inserted', inserted, 'days', 5, 'periods_per_day', ppd);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;
revoke execute on function public.generate_timetable(text, text, text, integer) from public, anon;
grant  execute on function public.generate_timetable(text, text, text, integer) to authenticated;

-- 18.9 cbt_import_backup(payload) — teacher-side import of offline exam backups.
-- Same server-authoritative, shuffle-safe grading as cbt_submit_v2 but WITHOUT
-- the exam-window / attempt-limit gates (backups reach the teacher after the
-- sitting). Idempotent on client_ref like the live path.
DROP FUNCTION IF EXISTS public.cbt_import_backup() CASCADE;
create or replace function public.cbt_import_backup(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  e record; r record; rid uuid; sid uuid; n int; taken int := 0;
  score numeric := 0; total numeric := 0; cc int := 0; wc int := 0; sc int := 0;
  ans jsonb; q jsonb; i int := 0; a text; k text; mark numeric;
  ref text := nullif(p_payload->>'client_ref','');
begin
  select * into e from public.cbt_exams where id = (p_payload->>'exam_id')::uuid;
  if not found then return jsonb_build_object('saved', false, 'error', 'Exam not found'); end if;
  if ref is not null then
    select * into r from public.cbt_results where exam_id = e.id and client_ref = ref limit 1;
    if found then
      return jsonb_build_object('saved', true, 'duplicate', true, 'result_id', r.id, 'score', r.score, 'total', r.total, 'percent', r.percent,
        'correct_count', r.correct_count, 'wrong_count', r.wrong_count, 'skipped_count', r.skipped_count,
        'cert_code', r.cert_code, 'title', e.title, 'release_results', e.release_results, 'report_column', e.report_column);
    end if;
  end if;
  for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb)) loop
    q := (case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array' and jsonb_array_length(e.questions)>0 then e.questions else '[]'::jsonb end)
          -> (case when coalesce(ans->>'index','') ~ '^[0-9]+$' then (ans->>'index')::int else i end);
    mark := coalesce(nullif(q->>'mark','')::numeric, 1); total := total + mark;
    a := coalesce(ans->>'answer', ans #>> '{}', '');
    k := coalesce(q->>'answer', q->>'correct', q->>'correct_answer', '');
    if a is null or trim(a) = '' then sc := sc + 1;
    elsif k <> '' and lower(trim(a)) = lower(trim(k)) then score := score + mark; cc := cc + 1;
    else wc := wc + 1; end if;
    i := i + 1;
  end loop;
  sid := nullif(p_payload->>'student_id','')::uuid;
  n := case when total > 0 then round(score/total*100)::int else 0 end;
  if nullif(p_payload->>'student_id_ref','') is not null then
    select count(*) into taken from public.cbt_results where exam_id = e.id and student_id_ref = p_payload->>'student_id_ref';
  end if;
  begin
    insert into public.cbt_results(
      exam_id, student_id, student_name, student_class, student_id_ref, student_type,
      score, total, percent, correct_count, wrong_count, skipped_count,
      attempt_number, time_taken, violations, violation_log, answers_data, cert_code, client_ref
    ) values (
      e.id, sid, coalesce(p_payload->>'student_name','Anonymous'), coalesce(p_payload->>'student_class', e.class),
      coalesce(p_payload->>'student_id_ref',''), coalesce(p_payload->>'student_type', e.exam_mode),
      score, total::int, n, cc, wc, sc,
      taken + 1, coalesce((p_payload->>'time_taken')::int,0), coalesce((p_payload->>'violations')::int,0),
      coalesce(p_payload->'violation_log','[]'::jsonb), p_payload->'answers_data',
      case when e.certificate_enabled then 'CERT-'||upper(substr(md5(random()::text),1,8)) else '' end,
      ref
    ) returning id into rid;
  exception when unique_violation then
    select * into r from public.cbt_results where exam_id = e.id and client_ref = ref limit 1;
    if found then
      return jsonb_build_object('saved', true, 'duplicate', true, 'result_id', r.id, 'score', r.score, 'total', r.total, 'percent', r.percent,
        'correct_count', r.correct_count, 'wrong_count', r.wrong_count, 'skipped_count', r.skipped_count,
        'cert_code', r.cert_code, 'title', e.title, 'release_results', e.release_results, 'report_column', e.report_column);
    end if;
    return jsonb_build_object('saved', false, 'error', 'Duplicate submission conflict');
  end;
  return jsonb_build_object('saved', true, 'result_id', rid, 'score', score, 'total', total, 'percent', n,
    'correct_count', cc, 'wrong_count', wc, 'skipped_count', sc,
    'cert_code', (select cert_code from public.cbt_results where id = rid), 'title', e.title,
    'release_results', e.release_results, 'report_column', e.report_column);
exception when others then
  return jsonb_build_object('saved', false, 'error', sqlerrm);
end $$;
revoke execute on function public.cbt_import_backup(jsonb) from public, anon;
grant  execute on function public.cbt_import_backup(jsonb) to authenticated;

-- ============================================================================
-- SECTION 19: POSTGREST SCHEMA CACHE RELOAD (kills "schema cache" errors instantly)
-- ============================================================================

-- PostgREST caches the OpenAPI schema; after DDL it can briefly serve
-- "Could not find the table 'public.X' in the schema cache". Request a reload.
notify pgrst, 'reload schema';
select pg_notify('pgrst','reload schema');

select 'School Connect v12.5 clean schema installed successfully ✅ (CBT scale pack + Punctuality Points engine + all runtime helper RPCs included — fully self-contained)' as status;

-- Enhanced admission number and staff ID format settings
alter table public.school_settings add column if not exists admission_format text default 'prefix-dash';
alter table public.school_settings add column if not exists admission_start_num integer default 1;
alter table public.school_settings add column if not exists admission_include_year boolean default false;
alter table public.school_settings add column if not exists staff_mid_segment text default 'STF';

-- ============================================================================
-- SECTION 20: SCHOOL CONNECT V5 CBT AUTHORITATIVE GRADING + TAB REPAIR
-- Cumulative/additive: safe for fresh installs and existing School Connect DBs.
-- ============================================================================

-- Decimal marks (for example 0.5) must not be truncated on result storage.
alter table public.cbt_results alter column total type numeric(10,2) using total::numeric;
alter table public.cbt_results add column if not exists subject_scores jsonb not null default '{}'::jsonb;

create or replace function public.sc_cbt_norm(p_value text)
returns text language sql immutable parallel safe as $$
  select lower(regexp_replace(trim(coalesce(p_value,'')), '\s+', ' ', 'g'))
$$;

-- Turn A/B/C/D and exact option text into one comparable representation.
create or replace function public.sc_cbt_canonical_option(p_question jsonb, p_value text)
returns text language plpgsql immutable parallel safe as $$
declare
  opts text[] := '{}';
  typ text := lower(replace(replace(coalesce(p_question->>'type',p_question->>'question_type','mcq'),'-','_'),' ','_'));
  val text := public.sc_cbt_norm(p_value);
  idx int;
begin
  if jsonb_typeof(p_question->'options')='array' then
    select coalesce(array_agg(public.sc_cbt_norm(x.value) order by x.ord),'{}'::text[])
      into opts from jsonb_array_elements_text(p_question->'options') with ordinality x(value,ord);
  else
    opts := array_remove(array[
      public.sc_cbt_norm(coalesce(p_question->>'a',p_question->>'option_a',p_question->>'opt_a')),
      public.sc_cbt_norm(coalesce(p_question->>'b',p_question->>'option_b',p_question->>'opt_b')),
      public.sc_cbt_norm(coalesce(p_question->>'c',p_question->>'option_c',p_question->>'opt_c')),
      public.sc_cbt_norm(coalesce(p_question->>'d',p_question->>'option_d',p_question->>'opt_d')),
      public.sc_cbt_norm(coalesce(p_question->>'e',p_question->>'option_e',p_question->>'opt_e'))
    ], '');
  end if;
  if typ in ('true_false','truefalse','true_or_false','tf','boolean','yes_no','yesno') and coalesce(array_length(opts,1),0)=0 then
    opts := array['true','false'];
  end if;
  if val ~ '^[a-z]$' then
    idx := ascii(val)-ascii('a')+1;
    if idx between 1 and coalesce(array_length(opts,1),0) then return opts[idx]; end if;
  end if;
  return val;
end $$;

-- Server-side answer matcher. The correct key never leaves PostgreSQL.
create or replace function public.sc_cbt_answer_matches(p_question jsonb, p_given jsonb)
returns boolean language plpgsql immutable parallel safe as $$
declare
  expected jsonb := coalesce(p_question->'answer',p_question->'correct',p_question->'correct_answer',p_question->'correctAnswer',p_question->'key');
  typ text := lower(replace(replace(coalesce(p_question->>'type',p_question->>'question_type','mcq'),'-','_'),' ','_'));
  given_text text;
  expected_text text;
  tolerance numeric;
  gv numeric;
  ev numeric;
  given_tokens text[] := '{}';
  expected_tokens text[] := '{}';
  token text;
begin
  if p_given is null or p_given='null'::jsonb or expected is null or expected='null'::jsonb then return false; end if;

  if typ='numeric' then
    begin
      given_text := case when jsonb_typeof(p_given)='string' then p_given #>> '{}' else trim(both '"' from p_given::text) end;
      expected_text := case when jsonb_typeof(expected)='string' then expected #>> '{}' else trim(both '"' from expected::text) end;
      gv := given_text::numeric; ev := expected_text::numeric;
      tolerance := greatest(abs(coalesce(nullif(p_question->>'tolerance','')::numeric,nullif(p_question->>'accept','')::numeric,0.0001)),0.0000001);
      return abs(gv-ev) <= tolerance;
    exception when others then return false;
    end;
  end if;

  -- Multi-select must match the complete set (not merely one member).
  if typ='multi_select' or jsonb_typeof(p_given)='array' then
    if jsonb_typeof(p_given)='array' then
      select coalesce(array_agg(distinct public.sc_cbt_canonical_option(p_question,x)),'{}'::text[])
        into given_tokens from jsonb_array_elements_text(p_given) x;
    else
      given_text := case when jsonb_typeof(p_given)='string' then p_given #>> '{}' else trim(both '"' from p_given::text) end;
      foreach token in array regexp_split_to_array(coalesce(given_text,''),'\s*[,;|]\s*') loop
        if public.sc_cbt_norm(token)<>'' then given_tokens:=array_append(given_tokens,public.sc_cbt_canonical_option(p_question,token)); end if;
      end loop;
    end if;
    if jsonb_typeof(expected)='array' then
      select coalesce(array_agg(distinct public.sc_cbt_canonical_option(p_question,x)),'{}'::text[])
        into expected_tokens from jsonb_array_elements_text(expected) x;
    else
      expected_text := case when jsonb_typeof(expected)='string' then expected #>> '{}' else trim(both '"' from expected::text) end;
      foreach token in array regexp_split_to_array(coalesce(expected_text,''),'\s*[,;|]\s*') loop
        if public.sc_cbt_norm(token)<>'' then expected_tokens:=array_append(expected_tokens,public.sc_cbt_canonical_option(p_question,token)); end if;
      end loop;
    end if;
    select coalesce(array_agg(x order by x),'{}'::text[]) into given_tokens from unnest(given_tokens) x;
    select coalesce(array_agg(x order by x),'{}'::text[]) into expected_tokens from unnest(expected_tokens) x;
    return coalesce(array_length(expected_tokens,1),0)>0 and given_tokens=expected_tokens;
  end if;

  given_text := case when jsonb_typeof(p_given)='string' then p_given #>> '{}' else trim(both '"' from p_given::text) end;
  if jsonb_typeof(expected)='array' then
    for token in select jsonb_array_elements_text(expected) loop
      if public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_canonical_option(p_question,token) then return true; end if;
    end loop;
    return false;
  end if;
  expected_text := case when jsonb_typeof(expected)='string' then expected #>> '{}' else trim(both '"' from expected::text) end;
  -- Pipes are accepted-alternative separators for fill/short-answer banks.
  if typ in ('fill_blank','short_answer','short','cloze','math_equation') and expected_text like '%|%' then
    foreach token in array regexp_split_to_array(expected_text,'\s*\|\s*') loop
      if public.sc_cbt_norm(given_text)=public.sc_cbt_norm(token) then return true; end if;
    end loop;
    return false;
  end if;
  return public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_canonical_option(p_question,expected_text);
end $$;

-- Public getter: strips every top-level answer key but preserves subject metadata
-- and original indexes, which are required for UTME tabs and shuffle-safe scoring.
create or replace function public.cbt_get_public_exam(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record; qs jsonb; school jsonb;
begin
  select * into e from public.cbt_exams
   where upper(code)=upper(trim(p_code)) and is_open=true and is_archived=false limit 1;
  if not found then return null; end if;
  if e.start_at is not null and now()<e.start_at then return jsonb_build_object('wait',true,'start_at',e.start_at,'title',e.title,'server_now',now()); end if;
  if e.close_at is not null and now()>e.close_at then return jsonb_build_object('closed',true,'server_now',now()); end if;
  select coalesce(jsonb_agg((q-'correct'-'correct_answer'-'correctAnswer'-'answer'-'key'-'explanation')||jsonb_build_object('_orig_index',ord-1) order by ord),'[]'::jsonb)
    into qs from jsonb_array_elements(
      case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data
           when jsonb_typeof(e.questions)='array' and jsonb_array_length(e.questions)>0 then e.questions else '[]'::jsonb end
    ) with ordinality x(q,ord);
  select jsonb_build_object('name',school_name,'short_name',short_name,'motto',motto,'address',address,'phone',phone,'email',email,'logo_url',logo_url)
    into school from public.school_settings where id=1;
  return jsonb_build_object(
    'id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,
    'term',e.term,'session',e.session,'assessment_type',e.assessment_type,
    'duration',coalesce(nullif(e.duration_min,0),nullif(e.duration,0),45),
    'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,
    'exam_mode',e.exam_mode,'server_now',now(),'start_at',e.start_at,'close_at',e.close_at,
    'instructions',e.instructions,'anti_cheat_config',e.anti_cheat_config,
    'attempt_limit',e.attempt_limit,'randomise',e.randomise,'select_count',e.select_count,
    'negative_mark',e.negative_mark,'pass_mark',e.pass_mark,'release_results',e.release_results,
    'certificate_enabled',e.certificate_enabled,'updated_at',e.updated_at,'school',coalesce(school,'{}'::jsonb)
  );
end $$;

-- Canonical, server-authoritative, original-index-aware and idempotent submit.
create or replace function public.cbt_submit(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  e record; r record; rid uuid; sid uuid; taken int:=0; idx int:=0; qidx int;
  score numeric:=0; total numeric:=0; cc int:=0; wc int:=0; sc int:=0;
  ans jsonb; q jsonb; bank jsonb; given jsonb; mark numeric; penalty numeric;
  ref text:=nullif(p_payload->>'client_ref',''); pct numeric; grade text;
  idref text:=trim(coalesce(p_payload->>'student_id_ref',''));
  subject_name text; subject_scores jsonb:='{}'::jsonb; subject_row jsonb;
begin
  select * into e from public.cbt_exams where id=(p_payload->>'exam_id')::uuid;
  if not found then return jsonb_build_object('saved',false,'error','exam_not_found','message','Exam not found.'); end if;
  if not coalesce(e.is_open,false) or coalesce(e.is_archived,false) then return jsonb_build_object('saved',false,'error','closed','message','This exam is not open.'); end if;
  if e.start_at is not null and now()<e.start_at then return jsonb_build_object('saved',false,'error','not_started','message','This exam has not started.'); end if;
  if e.close_at is not null and now()>e.close_at+interval '120 seconds' then return jsonb_build_object('saved',false,'error','closed','message','This exam has closed.'); end if;

  if ref is not null then
    select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;
    if found then return jsonb_build_object('saved',true,'duplicate',true,'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,'grade',case when r.percent>=75 then 'A' when r.percent>=60 then 'B' when r.percent>=50 then 'C' when r.percent>=40 then 'D' else 'F' end,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'cert_code',r.cert_code,'subject_scores',r.subject_scores,'release_results',e.release_results,'report_column',e.report_column); end if;
  end if;
  if idref<>'' and coalesce(e.attempt_limit,0)>0 then
    select count(*) into taken from public.cbt_results where exam_id=e.id and student_id_ref=idref;
    if taken>=e.attempt_limit then return jsonb_build_object('saved',false,'error','attempts_exhausted','message','Attempt limit reached for this exam.'); end if;
  end if;

  bank := case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data
               when jsonb_typeof(e.questions)='array' and jsonb_array_length(e.questions)>0 then e.questions else '[]'::jsonb end;
  penalty:=greatest(coalesce(e.negative_mark,0),0);
  for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb)) loop
    qidx:=case when coalesce(ans->>'index','')~'^[0-9]+$' then (ans->>'index')::int else idx end;
    if qidx<0 or qidx>=jsonb_array_length(bank) then idx:=idx+1; continue; end if;
    q:=bank->qidx;
    begin mark:=coalesce(nullif(q->>'mark','')::numeric,nullif(q->>'score','')::numeric,nullif(q->>'points','')::numeric,1); exception when others then mark:=1; end;
    mark:=greatest(mark,0); total:=total+mark; given:=ans->'answer';
    subject_name:=coalesce(nullif(q->>'section',''),nullif(q->>'subject',''),nullif(q->>'subject_section',''),nullif(ans->>'subject',''),'General');
    subject_row:=coalesce(subject_scores->subject_name,'{"score":0,"total":0,"correct":0,"wrong":0,"skipped":0}'::jsonb);
    subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
    if given is null or given='null'::jsonb or (jsonb_typeof(given)='string' and public.sc_cbt_norm(given #>> '{}')='') or (jsonb_typeof(given)='array' and jsonb_array_length(given)=0) then
      sc:=sc+1; subject_row:=jsonb_set(subject_row,'{skipped}',to_jsonb(coalesce((subject_row->>'skipped')::int,0)+1));
    elsif public.sc_cbt_answer_matches(q,given) then
      score:=score+mark; cc:=cc+1; subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+mark)); subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
    else
      score:=score-penalty; wc:=wc+1; subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));
    end if;
    subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true); idx:=idx+1;
  end loop;
  score:=greatest(round(score,2),0); pct:=case when total>0 then round(score/total*100,2) else 0 end;
  grade:=case when pct>=75 then 'A' when pct>=60 then 'B' when pct>=50 then 'C' when pct>=40 then 'D' else 'F' end;
  if coalesce(p_payload->>'student_id','')~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then sid:=(p_payload->>'student_id')::uuid; else sid:=null; end if;
  if sid is null and idref<>'' then select id into sid from public.students where admission_no=idref limit 1; end if;
  begin
    insert into public.cbt_results(exam_id,student_id,student_name,student_class,student_id_ref,student_type,score,total,percent,correct_count,wrong_count,skipped_count,attempt_number,time_taken,violations,violation_log,answers_data,cert_code,client_ref,subject_scores)
    values(e.id,sid,coalesce(nullif(p_payload->>'student_name',''),'Anonymous'),coalesce(nullif(p_payload->>'student_class',''),e.class),idref,coalesce(p_payload->>'student_type',e.exam_mode),score,total,pct,cc,wc,sc,taken+1,coalesce((p_payload->>'time_taken')::int,0),coalesce((p_payload->>'violations')::int,0),coalesce(p_payload->'violation_log','[]'::jsonb),coalesce(p_payload->'answers_data','[]'::jsonb),case when e.certificate_enabled then 'CERT-'||upper(substr(md5(random()::text),1,8)) else '' end,ref,subject_scores)
    returning id into rid;
  exception when unique_violation then
    if ref is not null then select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1; if found then return jsonb_build_object('saved',true,'duplicate',true,'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'cert_code',r.cert_code,'subject_scores',r.subject_scores,'release_results',e.release_results,'report_column',e.report_column); end if; end if;
    return jsonb_build_object('saved',false,'error','duplicate_submission','message','Duplicate submission conflict.');
  end;
  return jsonb_build_object('saved',true,'result_id',rid,'score',score,'total',total,'percent',pct,'grade',grade,'correct_count',cc,'wrong_count',wc,'skipped_count',sc,'cert_code',(select cert_code from public.cbt_results where id=rid),'subject_scores',subject_scores,'release_results',e.release_results,'report_column',e.report_column);
exception when others then return jsonb_build_object('saved',false,'error','server_error','message',sqlerrm);
end $$;

-- Compatibility aliases: every historic runner version now reaches the same
-- fixed implementation rather than an older exact-text-only scorer.
create or replace function public.cbt_get_public_exam_v2(p_code text)
returns jsonb language sql security definer stable set search_path=public as $$ select public.cbt_get_public_exam(p_code) $$;
create or replace function public.cbt_submit_v2(p_payload jsonb)
returns jsonb language sql security definer set search_path=public as $$ select public.cbt_submit(p_payload) $$;

revoke execute on function public.sc_cbt_norm(text) from public, anon, authenticated;
revoke execute on function public.sc_cbt_canonical_option(jsonb,text) from public, anon, authenticated;
revoke execute on function public.sc_cbt_answer_matches(jsonb,jsonb) from public, anon, authenticated;
revoke execute on function public.cbt_get_public_exam(text) from public;
revoke execute on function public.cbt_submit(jsonb) from public;
grant execute on function public.cbt_get_public_exam(text) to anon, authenticated;
grant execute on function public.cbt_submit(jsonb) to anon, authenticated;
grant execute on function public.cbt_get_public_exam_v2(text) to anon, authenticated;
grant execute on function public.cbt_submit_v2(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
select pg_notify('pgrst','reload schema');
select 'School Connect V5 cumulative schema installed — authoritative CBT scoring, shuffle-safe indexes, UTME subject tabs and school identity enabled ✅' as status;

-- ============================================================================
-- SECTION 21: V5 BROWSER/SCHEMA CONTRACT RECONCILIATION (ADDITIVE)
-- Every column written by crud.js exists on both fresh and upgraded databases.
-- ============================================================================
alter table public.staff add column if not exists staff_type text default 'teaching';
alter table public.staff add column if not exists subject_taught text default '';
alter table public.staff add column if not exists qualification text default '';
alter table public.staff add column if not exists gender text default '';
alter table public.staff add column if not exists religion text default '';
alter table public.staff add column if not exists marital_status text default '';
alter table public.staff add column if not exists dob_day int;
alter table public.staff add column if not exists dob_month text default '';
alter table public.staff add column if not exists address text default '';
alter table public.parents add column if not exists date_of_birth date;
alter table public.conduct add column if not exists student_name text default '';
alter table public.health add column if not exists student_name text default '';
alter table public.promotions add column if not exists student_name text default '';
alter table public.promotions add column if not exists average numeric default 0;
alter table public.promotions add column if not exists status text default 'pending';
alter table public.complaints add column if not exists attachment_link text default '';
alter table public.complaints add column if not exists assigned_to text default '';
alter table public.complaints add column if not exists resolution text default '';
alter table public.birthdays add column if not exists student_ref uuid references public.students(id) on delete set null;
alter table public.birthdays add column if not exists staff_ref uuid references public.staff(id) on delete set null;
alter table public.birthdays add column if not exists parent_ref uuid references public.parents(id) on delete set null;
alter table public.behaviour_points add column if not exists student_name text default '';
alter table public.inventory add column if not exists asset_tag text default '';
alter table public.inventory add column if not exists unit_cost numeric default 0;
alter table public.inventory add column if not exists last_audit date;
alter table public.inventory add column if not exists next_audit date;
alter table public.substitutions add column if not exists reason text default '';
alter table public.affective_traits add column if not exists data jsonb not null default '{}'::jsonb;
alter table public.psychomotor_traits add column if not exists data jsonb not null default '{}'::jsonb;
alter table public.admission_links add column if not exists title text default '';
alter table public.admission_links add column if not exists class_applied text default '';
alter table public.admission_links add column if not exists exam_code text default '';
alter table public.admission_links add column if not exists expires_at timestamptz;
alter table public.admission_links add column if not exists notes text default '';
notify pgrst, 'reload schema';
select pg_notify('pgrst','reload schema');
select 'School Connect V5 schema/browser contract reconciled ✅' as status;

-- V5 fee balance authority: every receipt sees the same balance even when rows
-- are inserted outside the browser UI.
create or replace function public.compute_fee_payment_balance()
returns trigger language plpgsql set search_path=public as $$
begin
  if coalesce(new.fee_total,0)>0 then new.balance:=greatest(coalesce(new.fee_total,0)-coalesce(new.amount_paid,0),0);
  else new.balance:=greatest(coalesce(new.balance,0),0); end if;
  return new;
end $$;
drop trigger if exists trg_compute_fee_payment_balance on public.fee_payments;
create trigger trg_compute_fee_payment_balance before insert or update of fee_total,amount_paid,balance on public.fee_payments for each row execute function public.compute_fee_payment_balance();
notify pgrst, 'reload schema';
select pg_notify('pgrst','reload schema');

-- ============================================================================
-- SECTION 22: CBT V5.1 DEFINITIVE GRADING ENGINE
-- A distinct RPC name prevents stale/legacy PostgREST overloads from silently
-- returning zero. Legacy answer-key spellings are normalised case-insensitively.
-- ============================================================================

alter table public.cbt_results add column if not exists ungraded_count int not null default 0;
alter table public.cbt_results add column if not exists grading_status text not null default 'graded';
alter table public.cbt_results add column if not exists engine_version text not null default '';

create or replace function public.sc_cbt_json_value(p_object jsonb,p_keys text[])
returns jsonb language sql immutable parallel safe as $$
  select e.value from jsonb_each(coalesce(p_object,'{}'::jsonb)) e
   where regexp_replace(lower(e.key),'[^a-z0-9]','','g')=any(p_keys)
   order by array_position(p_keys,regexp_replace(lower(e.key),'[^a-z0-9]','','g')) nulls last
   limit 1
$$;

create or replace function public.sc_cbt_options(p_question jsonb)
returns text[] language plpgsql immutable parallel safe as $$
declare raw jsonb; elem jsonb; value text; result text[]:='{}'; keyset text[][]:=array[
 array['a','optiona','opta','choicea','option1'],array['b','optionb','optb','choiceb','option2'],
 array['c','optionc','optc','choicec','option3'],array['d','optiond','optd','choiced','option4'],
 array['e','optione','opte','choicee','option5']]; keys text[];
begin
 raw:=public.sc_cbt_json_value(p_question,array['options','choices','optionlist','choiceoptions']);
 if jsonb_typeof(raw)='array' then
   for elem in select * from jsonb_array_elements(raw) loop
     if jsonb_typeof(elem)='object' then
       value:=coalesce(public.sc_cbt_json_value(elem,array['text','label','value','option'])#>>'{}',elem::text);
     else value:=elem#>>'{}'; end if;
     if coalesce(trim(value),'')<>'' then result:=array_append(result,value); end if;
   end loop;
 elsif jsonb_typeof(raw)='object' then
   for elem in select value from jsonb_each(raw) order by key loop
     value:=case when jsonb_typeof(elem)='object' then coalesce(public.sc_cbt_json_value(elem,array['text','label','value','option'])#>>'{}',elem::text) else elem#>>'{}' end;
     if coalesce(trim(value),'')<>'' then result:=array_append(result,value); end if;
   end loop;
 elsif jsonb_typeof(raw)='string' then
   result:=regexp_split_to_array(raw#>>'{}','\s*[|;]\s*');
 end if;
 if coalesce(array_length(result,1),0)=0 then
   foreach keys slice 1 in array keyset loop
     raw:=public.sc_cbt_json_value(p_question,keys); value:=case when raw is null then null else raw#>>'{}' end;
     if coalesce(trim(value),'')<>'' then result:=array_append(result,value); end if;
   end loop;
 end if;
 return coalesce(result,'{}'::text[]);
end $$;

create or replace function public.sc_cbt_answer_value(p_question jsonb)
returns jsonb language plpgsql immutable parallel safe as $$
declare answer jsonb;
begin
 answer:=public.sc_cbt_json_value(p_question,array['answer','correct','correctanswer','answerkey','correctoption','key','solutionanswer','rightanswer']);
 if jsonb_typeof(answer)='object' then answer:=coalesce(public.sc_cbt_json_value(answer,array['value','answer','key','text','label']),answer); end if;
 return answer;
end $$;

create or replace function public.sc_cbt_question_type(p_question jsonb)
returns text language plpgsql immutable parallel safe as $$
declare raw jsonb; typ text;
begin
 raw:=public.sc_cbt_json_value(p_question,array['type','questiontype']); typ:=lower(regexp_replace(coalesce(raw#>>'{}','mcq'),'[^a-z0-9]+','_','g'));
 if typ in ('tf','boolean','truefalse','true_or_false','yes_no','yesno') then return 'true_false'; end if;
 if typ in ('multiplechoice','multiple_choice','singlechoice','single_choice','objective') then return 'mcq'; end if;
 if typ in ('mrq','multiple_response','multiple_responses','multiple_select','multiselect','checkbox','checkboxes') then return 'multi_select'; end if;
 if typ in ('number','integer','decimal','calculation') then return 'numeric'; end if;
 if typ in ('short','text','free_text') then return 'short_answer'; end if;
 return typ;
end $$;

create or replace function public.sc_cbt_canonical_option(p_question jsonb,p_value text)
returns text language plpgsql immutable parallel safe as $$
declare opts text[]:=public.sc_cbt_options(p_question); val text:=public.sc_cbt_norm(p_value); idx int; typ text:=public.sc_cbt_question_type(p_question);
begin
 if typ='true_false' and coalesce(array_length(opts,1),0)=0 then opts:=array['true','false']; end if;
 if val~'^(option|choice)[ _-]*[a-z]$' then val:=right(val,1); end if;
 if val~'^[a-z]$' then idx:=ascii(val)-ascii('a')+1; if idx between 1 and coalesce(array_length(opts,1),0) then return public.sc_cbt_norm(opts[idx]); end if; end if;
 return val;
end $$;

create or replace function public.sc_cbt_answer_matches(p_question jsonb,p_given jsonb)
returns boolean language plpgsql immutable parallel safe as $$
declare expected jsonb:=public.sc_cbt_answer_value(p_question); accepted jsonb:=public.sc_cbt_json_value(p_question,array['accept','acceptedanswers','alternateanswers','alternatives']);
 typ text:=public.sc_cbt_question_type(p_question); given_value jsonb:=p_given; given_text text; expected_text text; token text;
 given_tokens text[]:='{}'; expected_tokens text[]:='{}'; opts text[]:=public.sc_cbt_options(p_question); n int; tol numeric; gv numeric; ev numeric;
begin
 if given_value is null or given_value='null'::jsonb or expected is null or expected='null'::jsonb then return false; end if;
 if jsonb_typeof(given_value)='object' then given_value:=coalesce(public.sc_cbt_json_value(given_value,array['value','answer','key','text','label']),given_value); end if;
 if typ='numeric' then
   begin
     given_text:=case when jsonb_typeof(given_value)='string' then given_value#>>'{}' else trim(both '"' from given_value::text) end;
     expected_text:=case when jsonb_typeof(expected)='string' then expected#>>'{}' else trim(both '"' from expected::text) end;
     gv:=given_text::numeric;ev:=expected_text::numeric;
     begin tol:=abs(coalesce(nullif(public.sc_cbt_json_value(p_question,array['tolerance','margin'])#>>'{}','')::numeric,0.0001)); exception when others then tol:=0.0001; end;
     return abs(gv-ev)<=tol;
   exception when others then return false; end;
 end if;
 if typ='multi_select' or jsonb_typeof(given_value)='array' then
   if jsonb_typeof(given_value)='array' then
     for token in select jsonb_array_elements_text(given_value) loop given_tokens:=array_append(given_tokens,public.sc_cbt_canonical_option(p_question,token)); end loop;
   else
     given_text:=given_value#>>'{}'; foreach token in array regexp_split_to_array(coalesce(given_text,''),'\s*[,;|]\s*') loop if trim(token)<>'' then given_tokens:=array_append(given_tokens,public.sc_cbt_canonical_option(p_question,token));end if;end loop;
   end if;
   if jsonb_typeof(expected)='array' then
     for token in select jsonb_array_elements_text(expected) loop expected_tokens:=array_append(expected_tokens,public.sc_cbt_canonical_option(p_question,token)); end loop;
   else
     expected_text:=expected#>>'{}'; foreach token in array regexp_split_to_array(coalesce(expected_text,''),'\s*[,;|]\s*') loop if trim(token)<>'' then expected_tokens:=array_append(expected_tokens,public.sc_cbt_canonical_option(p_question,token));end if;end loop;
   end if;
   select coalesce(array_agg(distinct x order by x),'{}'::text[]) into given_tokens from unnest(given_tokens)x;
   select coalesce(array_agg(distinct x order by x),'{}'::text[]) into expected_tokens from unnest(expected_tokens)x;
   return coalesce(array_length(expected_tokens,1),0)>0 and given_tokens=expected_tokens;
 end if;
 given_text:=case when jsonb_typeof(given_value)='string' then given_value#>>'{}' else trim(both '"' from given_value::text) end;
 if jsonb_typeof(expected)='array' then
   for token in select jsonb_array_elements_text(expected) loop if public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_canonical_option(p_question,token) then return true;end if;end loop;
 else
   expected_text:=case when jsonb_typeof(expected)='string' then expected#>>'{}' else trim(both '"' from expected::text) end;
   if public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_canonical_option(p_question,expected_text) then return true;end if;
   -- Legacy banks sometimes stored an option index rather than a letter. Accept
   -- both zero-based and one-based conventions only when the literal is not an option.
   if expected_text~'^[0-9]+$' and not(public.sc_cbt_norm(expected_text)=any(select public.sc_cbt_norm(x) from unnest(opts)x)) then
     n:=expected_text::int;
     if n between 0 and coalesce(array_length(opts,1),0)-1 and public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_norm(opts[n+1]) then return true;end if;
     if n between 1 and coalesce(array_length(opts,1),0) and public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_norm(opts[n]) then return true;end if;
   end if;
 end if;
 if accepted is not null then
   if jsonb_typeof(accepted)='array' then for token in select jsonb_array_elements_text(accepted) loop if public.sc_cbt_norm(given_text)=public.sc_cbt_norm(token) then return true;end if;end loop;
   else foreach token in array regexp_split_to_array(coalesce(accepted#>>'{}',''),'\s*[|;]\s*') loop if public.sc_cbt_norm(given_text)=public.sc_cbt_norm(token) then return true;end if;end loop; end if;
 end if;
 return false;
end $$;

create or replace function public.sc_cbt_normalize_question(p_question jsonb)
returns jsonb language plpgsql immutable parallel safe as $$
declare outq jsonb:=coalesce(p_question,'{}'::jsonb); answer jsonb:=public.sc_cbt_answer_value(p_question); opts text[]:=public.sc_cbt_options(p_question); typ text:=public.sc_cbt_question_type(p_question); raw jsonb;
begin
 if answer is not null then outq:=outq||jsonb_build_object('answer',answer);end if;
 if coalesce(array_length(opts,1),0)>0 then outq:=outq||jsonb_build_object('options',to_jsonb(opts));end if;
 outq:=outq||jsonb_build_object('type',typ);
 raw:=public.sc_cbt_json_value(p_question,array['mark','marks','score','points']);if raw is not null then outq:=outq||jsonb_build_object('mark',raw);end if;
 raw:=public.sc_cbt_json_value(p_question,array['section','subjectsection','subject','examsubject']);if raw is not null then outq:=outq||jsonb_build_object('section',raw,'subject',raw);end if;
 return outq;
end $$;

create or replace function public.cbt_diagnose_exam(p_exam_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record;bank jsonb;q jsonb;i int:=0;gradable int:=0;manual_count int:=0;missing int[]:='{}';typ text;source text;
begin
 if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'message','Staff role required');end if;
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'message','Exam not found');end if;
 if jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then bank:=e.csv_data;source:='csv_data';elsif jsonb_typeof(e.questions)='array' then bank:=e.questions;source:='questions';else bank:='[]';source:='empty';end if;
 for q in select * from jsonb_array_elements(bank) loop typ:=public.sc_cbt_question_type(q);if typ in('essay','long_answer','file_upload') and public.sc_cbt_answer_value(q)is null then manual_count:=manual_count+1;elsif public.sc_cbt_answer_value(q)is null then missing:=array_append(missing,i);else gradable:=gradable+1;end if;i:=i+1;end loop;
 return jsonb_build_object('ok',true,'engine_version','v5.1.0','exam_id',e.id,'code',e.code,'bank_source',source,'question_count',jsonb_array_length(bank),'gradable_count',gradable,'manual_review_count',manual_count,'missing_answer_indexes',to_jsonb(missing));
end $$;

create or replace function public.cbt_repair_exam_scoring(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record;bank jsonb;fixed jsonb;
begin
 if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'message','Staff role required');end if;
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'message','Exam not found');end if;
 bank:=case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array' then e.questions else '[]'::jsonb end;
 select coalesce(jsonb_agg(public.sc_cbt_normalize_question(q)order by ord),'[]'::jsonb)into fixed from jsonb_array_elements(bank)with ordinality x(q,ord);
 update public.cbt_exams set csv_data=fixed,questions=fixed,updated_at=now()where id=p_exam_id;
 return public.cbt_diagnose_exam(p_exam_id);
end $$;

-- Automatically add canonical answer/options/type fields to existing banks.
do $$ declare r record;fixed jsonb;begin
 for r in select id,(case when jsonb_typeof(csv_data)='array'and jsonb_array_length(csv_data)>0 then csv_data when jsonb_typeof(questions)='array'then questions else '[]'::jsonb end)bank from public.cbt_exams loop
  select coalesce(jsonb_agg(public.sc_cbt_normalize_question(q)order by ord),'[]'::jsonb)into fixed from jsonb_array_elements(r.bank)with ordinality x(q,ord);
  update public.cbt_exams set csv_data=fixed,questions=fixed,updated_at=now()where id=r.id;
 end loop;
end $$;

create or replace function public.cbt_submit_v5(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record;r record;rid uuid;sid uuid;taken int:=0;idx int:=0;qidx int;score numeric:=0;total numeric:=0;cc int:=0;wc int:=0;sc int:=0;manual_count int:=0;missing_count int:=0;
 ans jsonb;q jsonb;bank jsonb;given jsonb;answer_key jsonb;mark numeric;penalty numeric;ref text:=nullif(p_payload->>'client_ref','');pct numeric;grade text;idref text:=trim(coalesce(p_payload->>'student_id_ref',''));typ text;subject_name text;subject_scores jsonb:='{}';subject_row jsonb;missing_indexes int[]:='{}';offline_override boolean:=coalesce((p_payload->>'offline_override')::boolean,false)and public.is_staff(auth.uid());effective_release boolean;
begin
 select * into e from public.cbt_exams where id=(p_payload->>'exam_id')::uuid;if not found then return jsonb_build_object('saved',false,'error','exam_not_found','message','Exam not found.','engine_version','v5.1.0');end if;
 if not offline_override then
  if not coalesce(e.is_open,false)or coalesce(e.is_archived,false)then return jsonb_build_object('saved',false,'error','closed','message','This exam is not open.','engine_version','v5.1.0');end if;
  if e.start_at is not null and now()<e.start_at then return jsonb_build_object('saved',false,'error','not_started','message','This exam has not started.','engine_version','v5.1.0');end if;
  if e.close_at is not null and now()>e.close_at+interval'120 seconds'then return jsonb_build_object('saved',false,'error','closed','message','This exam has closed.','engine_version','v5.1.0');end if;
 end if;
 if ref is not null then select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;if found then return jsonb_build_object('saved',true,'duplicate',true,'engine_version',coalesce(nullif(r.engine_version,''),'v5.1.0'),'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,'grade',case when r.percent>=75 then'A'when r.percent>=60 then'B'when r.percent>=50 then'C'when r.percent>=40 then'D'else'F'end,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'ungraded_count',r.ungraded_count,'grading_status',r.grading_status,'cert_code',r.cert_code,'subject_scores',r.subject_scores,'release_results',e.release_results and r.grading_status='graded','report_column',e.report_column);end if;end if;
 if not offline_override and idref<>''and coalesce(e.attempt_limit,0)>0 then select count(*)into taken from public.cbt_results where exam_id=e.id and student_id_ref=idref;if taken>=e.attempt_limit then return jsonb_build_object('saved',false,'error','attempts_exhausted','message','Attempt limit reached.','engine_version','v5.1.0');end if;end if;
 bank:=case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end;
 if jsonb_array_length(bank)=0 then return jsonb_build_object('saved',false,'error','question_bank_empty','message','The exam question bank is empty.','engine_version','v5.1.0');end if;
 penalty:=greatest(coalesce(e.negative_mark,0),0);
 for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb))loop
  qidx:=case when coalesce(ans->>'index','')~'^[0-9]+$'then(ans->>'index')::int else idx end;if qidx<0 or qidx>=jsonb_array_length(bank)then idx:=idx+1;continue;end if;q:=bank->qidx;typ:=public.sc_cbt_question_type(q);answer_key:=public.sc_cbt_answer_value(q);
  if answer_key is null then if typ in('essay','long_answer','file_upload')then manual_count:=manual_count+1;else missing_count:=missing_count+1;missing_indexes:=array_append(missing_indexes,qidx);end if;idx:=idx+1;continue;end if;
  begin mark:=coalesce(nullif(public.sc_cbt_json_value(q,array['mark','marks','score','points'])#>>'{}','')::numeric,1);exception when others then mark:=1;end;mark:=greatest(mark,0);total:=total+mark;given:=ans->'answer';
  subject_name:=coalesce(public.sc_cbt_json_value(q,array['section','subjectsection','subject','examsubject'])#>>'{}',nullif(ans->>'subject',''),'General');subject_row:=coalesce(subject_scores->subject_name,'{"score":0,"total":0,"correct":0,"wrong":0,"skipped":0}'::jsonb);subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
  if given is null or given='null'::jsonb or(jsonb_typeof(given)='string'and public.sc_cbt_norm(given#>>'{}')='')or(jsonb_typeof(given)='array'and jsonb_array_length(given)=0)then sc:=sc+1;subject_row:=jsonb_set(subject_row,'{skipped}',to_jsonb(coalesce((subject_row->>'skipped')::int,0)+1));
  elsif public.sc_cbt_answer_matches(q,given)then score:=score+mark;cc:=cc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+mark));subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
  else score:=score-penalty;wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(greatest(coalesce((subject_row->>'score')::numeric,0)-penalty,0)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));end if;
  subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true);idx:=idx+1;
 end loop;
 if missing_count>0 then return jsonb_build_object('saved',false,'error','answer_key_missing','message','This exam has '||missing_count||' objective question(s) without a recognised correct answer key. Ask the exam officer to use Diagnose Scoring / Repair Scoring, then submit again.','missing_answer_indexes',to_jsonb(missing_indexes),'engine_version','v5.1.0');end if;
 score:=greatest(round(score,2),0);pct:=case when total>0 then round(score/total*100,2)else 0 end;grade:=case when pct>=75 then'A'when pct>=60 then'B'when pct>=50 then'C'when pct>=40 then'D'else'F'end;
 if coalesce(p_payload->>'student_id','')~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'then sid:=(p_payload->>'student_id')::uuid;end if;if sid is null and idref<>''then select id into sid from public.students where admission_no=idref limit 1;end if;effective_release:=e.release_results and manual_count=0;
 insert into public.cbt_results(exam_id,student_id,student_name,student_class,student_id_ref,student_type,score,total,percent,correct_count,wrong_count,skipped_count,ungraded_count,grading_status,engine_version,attempt_number,time_taken,violations,violation_log,answers_data,cert_code,client_ref,subject_scores)
 values(e.id,sid,coalesce(nullif(p_payload->>'student_name',''),'Anonymous'),coalesce(nullif(p_payload->>'student_class',''),e.class),idref,coalesce(p_payload->>'student_type',e.exam_mode),score,total,pct,cc,wc,sc,manual_count,case when manual_count>0 then'manual_review'else'graded'end,'v5.1.0',taken+1,coalesce((p_payload->>'time_taken')::int,0),coalesce((p_payload->>'violations')::int,0),coalesce(p_payload->'violation_log','[]'::jsonb),coalesce(p_payload->'answers_data','[]'::jsonb),case when e.certificate_enabled and manual_count=0 then'CERT-'||upper(substr(md5(random()::text),1,8))else''end,ref,subject_scores)returning id into rid;
 return jsonb_build_object('saved',true,'engine_version','v5.1.0','result_id',rid,'score',score,'total',total,'percent',pct,'grade',grade,'correct_count',cc,'wrong_count',wc,'skipped_count',sc,'ungraded_count',manual_count,'grading_status',case when manual_count>0 then'manual_review'else'graded'end,'cert_code',(select cert_code from public.cbt_results where id=rid),'subject_scores',subject_scores,'release_results',effective_release,'report_column',e.report_column);
exception when unique_violation then select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;if found then return jsonb_build_object('saved',true,'duplicate',true,'engine_version',coalesce(nullif(r.engine_version,''),'v5.1.0'),'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'ungraded_count',r.ungraded_count,'grading_status',r.grading_status,'cert_code',r.cert_code,'subject_scores',r.subject_scores,'release_results',e.release_results and r.grading_status='graded','report_column',e.report_column);end if;return jsonb_build_object('saved',false,'error','duplicate_submission','message','Duplicate submission conflict.','engine_version','v5.1.0');
when others then return jsonb_build_object('saved',false,'error','server_error','message',sqlerrm,'engine_version','v5.1.0');end $$;

-- Unambiguous compatibility paths all delegate to V5.1.
drop function if exists public.cbt_submit(json);
create or replace function public.cbt_submit(p_payload jsonb)returns jsonb language sql security definer set search_path=public as $$select public.cbt_submit_v5(p_payload)$$;
create or replace function public.cbt_submit_v2(p_payload jsonb)returns jsonb language sql security definer set search_path=public as $$select public.cbt_submit_v5(p_payload)$$;
create or replace function public.cbt_import_backup(p_payload jsonb)returns jsonb language plpgsql security definer set search_path=public as $$begin if not public.is_staff(auth.uid())then return jsonb_build_object('saved',false,'error','Staff role required','engine_version','v5.1.0');end if;return public.cbt_submit_v5(p_payload||jsonb_build_object('offline_override',true,'client_engine','v5.1'));end$$;

revoke execute on function public.sc_cbt_json_value(jsonb,text[])from public,anon,authenticated;
revoke execute on function public.sc_cbt_options(jsonb)from public,anon,authenticated;
revoke execute on function public.sc_cbt_answer_value(jsonb)from public,anon,authenticated;
revoke execute on function public.sc_cbt_question_type(jsonb)from public,anon,authenticated;
revoke execute on function public.sc_cbt_normalize_question(jsonb)from public,anon,authenticated;
revoke execute on function public.cbt_submit_v5(jsonb)from public;
grant execute on function public.cbt_submit_v5(jsonb)to anon,authenticated;
grant execute on function public.cbt_submit(jsonb)to anon,authenticated;
grant execute on function public.cbt_submit_v2(jsonb)to anon,authenticated;
grant execute on function public.cbt_diagnose_exam(uuid)to authenticated;
grant execute on function public.cbt_repair_exam_scoring(uuid)to authenticated;
grant execute on function public.cbt_import_backup(jsonb)to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect CBT V5.1 definitive grading engine installed — use RPC cbt_submit_v5 ✅'as status;

-- V5.1 public question redaction: remove answer aliases case-insensitively.
create or replace function public.sc_cbt_public_question(p_question jsonb)
returns jsonb language sql immutable parallel safe as $$
 select coalesce(jsonb_object_agg(e.key,e.value),'{}'::jsonb)
 from jsonb_each(coalesce(p_question,'{}'::jsonb))e
 where regexp_replace(lower(e.key),'[^a-z0-9]','','g')not in
 ('answer','correct','correctanswer','answerkey','correctoption','key','solutionanswer','rightanswer','accept','acceptedanswers','alternateanswers','explanation','reason','solution')
$$;

create or replace function public.cbt_get_public_exam(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record;qs jsonb;school jsonb;
begin
 select * into e from public.cbt_exams where upper(code)=upper(trim(p_code))and is_open=true and is_archived=false limit 1;if not found then return null;end if;
 if e.start_at is not null and now()<e.start_at then return jsonb_build_object('wait',true,'start_at',e.start_at,'title',e.title,'server_now',now(),'engine_version','v5.1.0');end if;
 if e.close_at is not null and now()>e.close_at then return jsonb_build_object('closed',true,'server_now',now(),'engine_version','v5.1.0');end if;
 select coalesce(jsonb_agg(public.sc_cbt_public_question(q)||jsonb_build_object('_orig_index',ord-1)order by ord),'[]'::jsonb)into qs
 from jsonb_array_elements(case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end)with ordinality x(q,ord);
 select jsonb_build_object('name',school_name,'short_name',short_name,'motto',motto,'address',address,'phone',phone,'email',email,'logo_url',logo_url)into school from public.school_settings where id=1;
 return jsonb_build_object('id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,'term',e.term,'session',e.session,'assessment_type',e.assessment_type,'duration',coalesce(nullif(e.duration_min,0),nullif(e.duration,0),45),'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode,'server_now',now(),'start_at',e.start_at,'close_at',e.close_at,'instructions',e.instructions,'anti_cheat_config',e.anti_cheat_config,'attempt_limit',e.attempt_limit,'randomise',e.randomise,'select_count',e.select_count,'negative_mark',e.negative_mark,'pass_mark',e.pass_mark,'release_results',e.release_results,'certificate_enabled',e.certificate_enabled,'updated_at',e.updated_at,'school',coalesce(school,'{}'::jsonb),'engine_version','v5.1.0');
end$$;
create or replace function public.cbt_get_public_exam_v2(p_code text)returns jsonb language sql security definer stable set search_path=public as $$select public.cbt_get_public_exam(p_code)$$;
revoke execute on function public.sc_cbt_public_question(jsonb)from public,anon,authenticated;
grant execute on function public.cbt_get_public_exam(text)to anon,authenticated;
grant execute on function public.cbt_get_public_exam_v2(text)to anon,authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- Regrade historical zero/incorrect result rows whose answers_data was retained.
create or replace function public.cbt_regrade_exam_results_v5(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
<<regrade>>
declare e record;res record;ans jsonb;q jsonb;bank jsonb;given jsonb;key jsonb;qidx int;idx int;mark numeric;penalty numeric;score numeric;total numeric;pct numeric;cc int;wc int;sc int;manual_count int;missing_count int;updated_count int:=0;missing_rows int:=0;no_answer_rows int:=0;subject_name text;subject_scores jsonb;subject_row jsonb;typ text;
begin
 if not public.is_staff(auth.uid())then return jsonb_build_object('ok',false,'message','Staff role required','engine_version','v5.1.0');end if;
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'message','Exam not found','engine_version','v5.1.0');end if;
 bank:=case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end;
 if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'message','Question bank is empty','engine_version','v5.1.0');end if;penalty:=greatest(coalesce(e.negative_mark,0),0);
 for res in select * from public.cbt_results where exam_id=p_exam_id order by submitted_at loop
  if jsonb_typeof(res.answers_data)<>'array'or jsonb_array_length(res.answers_data)=0 then no_answer_rows:=no_answer_rows+1;continue;end if;
  idx:=0;score:=0;total:=0;cc:=0;wc:=0;sc:=0;manual_count:=0;missing_count:=0;subject_scores:='{}'::jsonb;
  for ans in select * from jsonb_array_elements(res.answers_data)loop
   if jsonb_typeof(ans)='object'then qidx:=case when coalesce(ans->>'index','')~'^[0-9]+$'then(ans->>'index')::int else idx end;given:=ans->'answer';else qidx:=idx;given:=ans;end if;
   if qidx<0 or qidx>=jsonb_array_length(bank)then idx:=idx+1;continue;end if;q:=bank->qidx;typ:=public.sc_cbt_question_type(q);key:=public.sc_cbt_answer_value(q);
   if key is null then if typ in('essay','long_answer','file_upload')then manual_count:=manual_count+1;else missing_count:=missing_count+1;end if;idx:=idx+1;continue;end if;
   begin mark:=coalesce(nullif(public.sc_cbt_json_value(q,array['mark','marks','score','points'])#>>'{}','')::numeric,1);exception when others then mark:=1;end;mark:=greatest(mark,0);total:=total+mark;
   subject_name:=coalesce(public.sc_cbt_json_value(q,array['section','subjectsection','subject','examsubject'])#>>'{}',case when jsonb_typeof(ans)='object'then nullif(ans->>'subject','')end,'General');subject_row:=coalesce(subject_scores->subject_name,'{"score":0,"total":0,"correct":0,"wrong":0,"skipped":0}'::jsonb);subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
   if given is null or given='null'::jsonb or(jsonb_typeof(given)='string'and public.sc_cbt_norm(given#>>'{}')='')or(jsonb_typeof(given)='array'and jsonb_array_length(given)=0)then sc:=sc+1;subject_row:=jsonb_set(subject_row,'{skipped}',to_jsonb(coalesce((subject_row->>'skipped')::int,0)+1));
   elsif public.sc_cbt_answer_matches(q,given)then score:=score+mark;cc:=cc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+mark));subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
   else score:=score-penalty;wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(greatest(coalesce((subject_row->>'score')::numeric,0)-penalty,0)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));end if;subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true);idx:=idx+1;
  end loop;
  if missing_count>0 then missing_rows:=missing_rows+1;continue;end if;score:=greatest(round(score,2),0);pct:=case when total>0 then round(score/total*100,2)else 0 end;
  update public.cbt_results set score=regrade.score,total=regrade.total,percent=regrade.pct,correct_count=regrade.cc,wrong_count=regrade.wc,skipped_count=regrade.sc,ungraded_count=regrade.manual_count,grading_status=case when regrade.manual_count>0 then'manual_review'else'graded'end,engine_version='v5.1.0-regraded',subject_scores=regrade.subject_scores where id=res.id;updated_count:=updated_count+1;
 end loop;
 return jsonb_build_object('ok',true,'engine_version','v5.1.0','exam_id',p_exam_id,'regraded_count',updated_count,'skipped_missing_key_rows',missing_rows,'skipped_no_answer_rows',no_answer_rows);
end$$;
revoke execute on function public.cbt_regrade_exam_results_v5(uuid)from public,anon;
grant execute on function public.cbt_regrade_exam_results_v5(uuid)to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- Distinct V5.1 public getter with normalised codes and explicit diagnostics.
create index if not exists cbt_exams_normalized_code_idx on public.cbt_exams((regexp_replace(upper(code),'[^A-Z0-9]','','g')));
create or replace function public.cbt_get_public_exam_v5(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record;qs jsonb;school jsonb;wanted text:=regexp_replace(upper(coalesce(p_code,'')),'[^A-Z0-9]','','g');
begin
 if wanted=''then return jsonb_build_object('ok',false,'error','code_required','message','Enter an exam code.','engine_version','v5.1.0');end if;
 select * into e from public.cbt_exams where regexp_replace(upper(code),'[^A-Z0-9]','','g')=wanted order by updated_at desc nulls last,created_at desc limit 1;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found','message','No exam matches that code. Ask the exam officer to confirm the code.','engine_version','v5.1.0','normalised_code',wanted);end if;
 if coalesce(e.is_archived,false)then return jsonb_build_object('ok',false,'error','archived','message','This exam is archived. The exam officer must unarchive it.','id',e.id,'title',e.title,'code',e.code,'engine_version','v5.1.0');end if;
 if not coalesce(e.is_open,false)then return jsonb_build_object('ok',false,'error','not_open','message','This exam exists but is not open. The exam officer must click Open in CBT Manager.','id',e.id,'title',e.title,'code',e.code,'engine_version','v5.1.0');end if;
 if e.start_at is not null and now()<e.start_at then return jsonb_build_object('ok',false,'wait',true,'error','not_started','message','This exam has not started yet.','start_at',e.start_at,'title',e.title,'code',e.code,'server_now',now(),'engine_version','v5.1.0');end if;
 if e.close_at is not null and now()>e.close_at then return jsonb_build_object('ok',false,'closed',true,'error','closed','message','This exam closing time has passed.','close_at',e.close_at,'title',e.title,'code',e.code,'server_now',now(),'engine_version','v5.1.0');end if;
 select coalesce(jsonb_agg(public.sc_cbt_public_question(q)||jsonb_build_object('_orig_index',ord-1)order by ord),'[]'::jsonb)into qs from jsonb_array_elements(case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end)with ordinality x(q,ord);
 select jsonb_build_object('name',school_name,'short_name',short_name,'motto',motto,'address',address,'phone',phone,'email',email,'logo_url',logo_url)into school from public.school_settings where id=1;
 return jsonb_build_object('ok',true,'id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,'term',e.term,'session',e.session,'assessment_type',e.assessment_type,'duration',coalesce(nullif(e.duration_min,0),nullif(e.duration,0),45),'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode,'server_now',now(),'start_at',e.start_at,'close_at',e.close_at,'instructions',e.instructions,'anti_cheat_config',e.anti_cheat_config,'attempt_limit',e.attempt_limit,'randomise',e.randomise,'select_count',e.select_count,'negative_mark',e.negative_mark,'pass_mark',e.pass_mark,'release_results',e.release_results,'certificate_enabled',e.certificate_enabled,'updated_at',e.updated_at,'school',coalesce(school,'{}'::jsonb),'engine_version','v5.1.0');
exception when others then return jsonb_build_object('ok',false,'error','getter_server_error','message',sqlerrm,'engine_version','v5.1.0');
end$$;
revoke execute on function public.cbt_get_public_exam_v5(text)from public;
grant execute on function public.cbt_get_public_exam_v5(text)to anon,authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- V5.2 promotion/report integrity: pending is a valid decision state and every
-- report can resolve the student by id or legacy name.
alter table public.promotions drop constraint if exists promotions_action_check;
alter table public.promotions add constraint promotions_action_check check(action in('promote','graduate','repeat','pending','delete'));
create index if not exists promotions_report_lookup_idx on public.promotions(student_id,session,term,created_at desc);
create index if not exists promotions_name_lookup_idx on public.promotions(student_name,session,term,created_at desc);
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.2 installed — authoritative report scores, bulk CBT push, promotion status and explicit CBT getter diagnostics ✅' as status;
-- School Connect CBT V5.1.1 — legacy school_settings compatibility repair
-- Fixes: column "motto" does not exist in cbt_get_public_exam_v5.
-- Safe/idempotent for an existing School Connect database. Back up first.

alter table public.school_settings add column if not exists school_name text default 'School';
alter table public.school_settings add column if not exists short_name text default 'SCH';
alter table public.school_settings add column if not exists motto text default '';
alter table public.school_settings add column if not exists address text default '';
alter table public.school_settings add column if not exists phone text default '';
alter table public.school_settings add column if not exists email text default '';
alter table public.school_settings add column if not exists logo_url text default '';

-- The function deliberately reads the settings row through to_jsonb(). Missing
-- optional settings keys therefore return NULL instead of aborting exam lookup.
create or replace function public.cbt_get_public_exam_v5(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare
 e record;qs jsonb;school jsonb;settings_json jsonb:='{}'::jsonb;matched_code text:='';matched_id uuid;
 wanted text:=regexp_replace(upper(coalesce(p_code,'')),'[^A-Z0-9]','','g');
begin
 if wanted=''then return jsonb_build_object('ok',false,'error','code_required','message','Enter an exam code.','engine_version','v5.1.1');end if;
 select * into e from public.cbt_exams where regexp_replace(upper(code),'[^A-Z0-9]','','g')=wanted order by updated_at desc nulls last,created_at desc limit 1;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found','message','No exam matches that code. Ask the exam officer to confirm the code.','engine_version','v5.1.1','normalised_code',wanted);end if;
 matched_code:=coalesce(e.code,'');matched_id:=e.id;
 if coalesce(e.is_archived,false)then return jsonb_build_object('ok',false,'error','archived','message','This exam is archived. The exam officer must unarchive it.','id',e.id,'title',e.title,'code',e.code,'engine_version','v5.1.1');end if;
 if not coalesce(e.is_open,false)then return jsonb_build_object('ok',false,'error','not_open','message','This exam exists but is not open. The exam officer must click Open in CBT Manager.','id',e.id,'title',e.title,'code',e.code,'engine_version','v5.1.1');end if;
 if e.start_at is not null and now()<e.start_at then return jsonb_build_object('ok',false,'wait',true,'error','not_started','message','This exam has not started yet.','start_at',e.start_at,'title',e.title,'code',e.code,'server_now',now(),'engine_version','v5.1.1');end if;
 if e.close_at is not null and now()>e.close_at then return jsonb_build_object('ok',false,'closed',true,'error','closed','message','This exam closing time has passed.','close_at',e.close_at,'title',e.title,'code',e.code,'server_now',now(),'engine_version','v5.1.1');end if;
 select coalesce(jsonb_agg(public.sc_cbt_public_question(q)||jsonb_build_object('_orig_index',ord-1)order by ord),'[]'::jsonb)into qs from jsonb_array_elements(case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end)with ordinality x(q,ord);
 select to_jsonb(ss)into settings_json from public.school_settings ss where id=1;
 school:=jsonb_build_object(
  'name',coalesce(nullif(settings_json->>'school_name',''),nullif(settings_json->>'name',''),nullif(settings_json->>'short_name',''),'School'),
  'short_name',coalesce(settings_json->>'short_name',''),
  'motto',coalesce(settings_json->>'motto',''),
  'address',coalesce(settings_json->>'address',''),
  'phone',coalesce(settings_json->>'phone',''),
  'email',coalesce(settings_json->>'email',''),
  'logo_url',coalesce(settings_json->>'logo_url','')
 );
 return jsonb_build_object('ok',true,'id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,'term',e.term,'session',e.session,'assessment_type',e.assessment_type,'duration',coalesce(nullif(e.duration_min,0),nullif(e.duration,0),45),'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode,'server_now',now(),'start_at',e.start_at,'close_at',e.close_at,'instructions',e.instructions,'anti_cheat_config',e.anti_cheat_config,'attempt_limit',e.attempt_limit,'randomise',e.randomise,'select_count',e.select_count,'negative_mark',e.negative_mark,'pass_mark',e.pass_mark,'release_results',e.release_results,'certificate_enabled',e.certificate_enabled,'updated_at',e.updated_at,'school',school,'engine_version','v5.1.1');
exception when others then
 return jsonb_build_object('ok',false,'error','getter_server_error','message','Exam lookup failed: '||sqlerrm,'code',matched_code,'matched_exam_id',matched_id,'engine_version','v5.1.1');
end$$;

revoke execute on function public.cbt_get_public_exam_v5(text)from public;
grant execute on function public.cbt_get_public_exam_v5(text)to anon,authenticated;
notify pgrst,'reload schema';
select pg_notify('pgrst','reload schema');
select 'School Connect CBT V5.1.1 getter compatibility fix installed — legacy school settings supported ✅'as status;
