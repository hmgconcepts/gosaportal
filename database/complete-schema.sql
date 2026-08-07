-- ============================================================================
-- SCHOOL CONNECT V5.8 — COMPLETE CUMULATIVE PRODUCTION SCHEMA
-- ============================================================================
-- The ONLY production SQL to run. Includes every V5.1–V5.6.1 table, column,
-- repair, constraint, index, trigger, view, RLS policy, grant and client RPC.
-- Safe for new or existing School Connect projects and safe to run repeatedly.
-- Automated verification executes this whole file twice on the same database.
-- demo-users.sql and demo-seed.sql are the only exceptions and are DEMO-ONLY.
-- Do not run any focused/versioned SQL after this complete schema.
-- Back up Supabase, run this file, wait for the final V5.6.1 success row,
-- deploy matching frontend files, then close old tabs and hard-refresh.
-- ============================================================================
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";


-- ============================================================================
-- SECTION 1: UTILITY FUNCTION (updated_at trigger helper)
-- ============================================================================
create or replace function public.sc_set_updated_at()
returns trigger language plpgsql security invoker as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- SECTION 2: CORE + FEATURE TABLES (98 tables, dependency-ordered, full columns)
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
  period_no numeric not null,
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

insert into public.schools(name,short_name,admission_acronym)
select 'My School','SCH','SCH' where not exists(select 1 from public.schools);

insert into public.school_settings (id, school_id, school_name, short_name, admission_acronym, admission_prefix, staff_prefix)
select 1, s.id, s.name, s.short_name, s.admission_acronym, s.admission_acronym, s.admission_acronym
from public.schools s order by s.created_at limit 1
on conflict (id) do nothing;

-- Bootstrap defaults only on a genuinely empty first installation. Earlier
-- releases reinserted deleted sessions on every schema rerun (data resurrection).
create table if not exists public.sc_install_state(key text primary key,applied_at timestamptz not null default now(),details jsonb default '{}'::jsonb);
alter table public.sc_install_state enable row level security;
do $$begin
 if not exists(select 1 from public.sc_install_state where key='core_lookup_defaults_v1')then
  if not exists(select 1 from public.lookups)then
   insert into public.lookups(kind,value,position)values
    ('term','First Term',1),('term','Second Term',2),('term','Third Term',3),
    ('session','2024/2025',1),('session','2025/2026',2),('session','2026/2027',3),
    ('arm','A',1),('arm','B',2),('arm','C',3),
    ('assessment','CA1',1),('assessment','CA2',2),('assessment','Assignment',3),('assessment','Project',4),('assessment','Exam',5),
    ('audience','all',1),('audience','students',2),('audience','staff',3),('audience','parents',4)
   on conflict(kind,value)do nothing;
  end if;
  insert into public.sc_install_state(key,details)values('core_lookup_defaults_v1',jsonb_build_object('seeded_only_when_empty',true))on conflict(key)do nothing;
 end if;
end$$;

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

create or replace function public.compute_fee_payment_balance()
returns trigger language plpgsql set search_path=public as $$
begin if coalesce(new.fee_total,0)>0 then new.balance:=greatest(coalesce(new.fee_total,0)-coalesce(new.amount_paid,0),0);else new.balance:=greatest(coalesce(new.balance,0),0);end if;return new;end$$;

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
declare cfg record;pfx text;fmt text;yr text;n int;start_n int;
begin
 if coalesce(trim(new.admission_no),'')<>''then return new;end if;
 select * into cfg from public.school_settings where id=1;
 pfx:=upper(regexp_replace(coalesce(nullif(cfg.admission_prefix,''),nullif(cfg.admission_acronym,''),nullif(cfg.short_name,''),'SCH'),'[^A-Z0-9]','','g'));
 fmt:=coalesce(nullif(cfg.admission_format,''),'prefix-dash');start_n:=greatest(coalesce(cfg.admission_start_num,1),1);yr:=extract(year from current_date)::int::text;
 perform pg_advisory_xact_lock(hashtext('ADMISSION:'||pfx));
 select greatest(start_n,coalesce(max((regexp_match(admission_no,'([0-9]+)$'))[1]::int),start_n-1)+1)into n from public.students where upper(coalesce(admission_no,''))like pfx||'%';
 if fmt='prefix-slash'or coalesce(cfg.admission_include_year,false)then new.admission_no:=pfx||'/'||yr||'/'||lpad(n::text,4,'0');
 elsif fmt='prefix-only'then new.admission_no:=pfx||lpad(n::text,5,'0');
 else new.admission_no:=pfx||'-'||lpad(n::text,5,'0');end if;
 return new;
end$$;

DROP FUNCTION IF EXISTS public.sc_generate_staff_no() CASCADE;
create or replace function public.sc_generate_staff_no()
returns trigger language plpgsql security definer set search_path=public as $$
declare cfg record;pfx text;mid text;base text;n int;
begin
 if coalesce(trim(new.staff_no),'')<>''then return new;end if;
 select * into cfg from public.school_settings where id=1;
 pfx:=upper(regexp_replace(coalesce(nullif(cfg.staff_prefix,''),nullif(cfg.admission_prefix,''),nullif(cfg.short_name,''),'SCH'),'[^A-Z0-9-]','','g'));mid:=upper(regexp_replace(coalesce(cfg.staff_mid_segment,'STF'),'[^A-Z0-9]','','g'));
 base:=case when mid=''then trim(both'-'from pfx)when right(pfx,length(mid)+1)='-'||mid then pfx else trim(both'-'from pfx)||'-'||mid end;
 perform pg_advisory_xact_lock(hashtext('STAFF:'||base));
 select greatest(1,coalesce(max((regexp_match(staff_no,'([0-9]+)$'))[1]::int),0)+1)into n from public.staff where upper(coalesce(staff_no,''))like trim(both'-'from pfx)||'%';
 new.staff_no:=base||'-'||lpad(n::text,5,'0');return new;
end$$;

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

-- CBT getter/submission/import RPCs are installed once in the definitive CBT section.

-- V7.9: flexible-timetable structures (used by the generator below)
alter table public.teacher_availability   add column if not exists available_periods jsonb;
alter table public.timetable_requirements add column if not exists available_periods jsonb;
create table if not exists public.timetable_blocks (
  id uuid primary key default gen_random_uuid(),
  class text not null default 'ALL',
  day text not null,
  period int not null,
  label text default 'Free period',
  created_at timestamptz default now(),
  unique(class, day, period)
);
-- Conflict-aware timetable generator (single authoritative definition).
alter table public.timetable_config alter column period_no type numeric using period_no::numeric;
drop function if exists public.generate_timetable(text,text,text,integer);
create or replace function public.generate_timetable(
  p_class text, p_session text default '', p_term text default '',
  p_periods_per_day integer default 6, p_day_periods jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare req record; blk record; occ int; placed int:=0; unplaced int:=0;
        ppd int:=least(greatest(coalesce(p_periods_per_day,6),1),12);
        chosen_day text; chosen_period int;
        allowed text[]; allowed_p jsonb;
        unplaced_items jsonb:='[]'::jsonb; required_total int:=0; capacity int:=0;
        d text; dp int;
begin
 if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'error','Staff/admin role required.'); end if;
 if coalesce(trim(p_class),'')='' then return jsonb_build_object('ok',false,'error','Select a class.'); end if;
 select coalesce(sum(greatest(periods_per_week,0)),0) into required_total from public.timetable_requirements where class=p_class;
 if required_total=0 then return jsonb_build_object('ok',false,'error','No subject demand exists for '||p_class||'. Add each subject, teacher and periods/week first.'); end if;

 -- weekly capacity honours per-day period counts and blocked slots
 foreach d in array array['Monday','Tuesday','Wednesday','Thursday','Friday'] loop
   dp := least(greatest(coalesce((p_day_periods->>d)::int, ppd),0),12);
   capacity := capacity + dp
     - (select count(*) from public.timetable_blocks b
         where (b.class=p_class or b.class='ALL') and b.day=d and b.period<=dp);
 end loop;

 delete from public.timetable where class=p_class
   and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'');

 -- write blocked slots into the grid FIRST: they display everywhere and the
 -- free-slot check below then avoids them automatically.
 for blk in select * from public.timetable_blocks b
             where (b.class=p_class or b.class='ALL')
               and b.period <= least(greatest(coalesce((p_day_periods->>b.day)::int, ppd),0),12) loop
   insert into public.timetable(class,day,period,subject,teacher,session,term)
   values (p_class, blk.day, blk.period::text, '⛔ '||coalesce(nullif(blk.label,''),'Free period'), null,
           coalesce(p_session,''), coalesce(p_term,''));
 end loop;

 for req in select * from public.timetable_requirements where class=p_class
             order by periods_per_week desc, subject loop
  allowed := req.available_days;
  allowed_p := req.available_periods;
  if (allowed is null or array_length(allowed,1) is null)
     and (allowed_p is null) and coalesce(req.teacher,'')<>'' then
    select available_days, available_periods into allowed, allowed_p
      from public.teacher_availability
     where lower(trim(teacher))=lower(trim(req.teacher)) limit 1;
  end if;
  for occ in 1..greatest(coalesce(req.periods_per_week,0),0) loop
   chosen_day:=null; chosen_period:=null;
   select dd.day, p.per into chosen_day, chosen_period
   from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
   cross join generate_series(1,12) p(per)
   where p.per <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
     -- day allowed: period-map keys win; else available_days; else any day
     and ( (allowed_p is not null and allowed_p ? dd.day)
        or (allowed_p is null and (allowed is null or array_length(allowed,1) is null
             or exists(select 1 from unnest(allowed) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))) )
     -- period allowed for that day when a period-map exists
     and ( allowed_p is null or not (allowed_p ? dd.day)
        or exists(select 1 from jsonb_array_elements_text(allowed_p->dd.day) e(v) where e.v::int = p.per) )
     -- class slot free (blocked slots already occupy their cells)
     and not exists(select 1 from public.timetable t
                     where t.class=p_class and t.day=dd.day and t.period=p.per::text
                       and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,''))
     -- teacher free across ALL classes this term/session
     and (coalesce(req.teacher,'')='' or not exists(
            select 1 from public.timetable t
             where lower(trim(coalesce(t.teacher,'')))=lower(trim(req.teacher))
               and t.day=dd.day and t.period=p.per::text
               and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')))
   order by
            -- V8.0 (a): spread a subject across DIFFERENT days first
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day and t.subject=req.subject
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            -- V8.0 (b): NEVER repeat the same period number for this subject on
            -- other days when an alternative exists (no more "Maths always 1st")
            (select count(*) from public.timetable t where t.class=p_class and t.period=p.per::text and t.subject=req.subject
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            -- V8.0 (c): balance the load across days
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            -- V8.0 (d): RANDOMISE among equally-good slots — every regenerate
            -- produces a fresh arrangement
            random()
   limit 1;
   if chosen_day is null then
     unplaced:=unplaced+1;
     unplaced_items:=unplaced_items||jsonb_build_array(jsonb_build_object('subject',req.subject,'teacher',req.teacher,'occurrence',occ,'reason','No free slot on an allowed day/period'));
   else
     insert into public.timetable(class,day,period,subject,teacher,session,term)
     values(p_class,chosen_day,chosen_period::text,req.subject,nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
     placed:=placed+1;
   end if;
  end loop;
 end loop;
 insert into public.timetable_runs(class,session,term,generated_at,conflicts,notes)
 values(p_class,p_session,p_term,now(),unplaced,'Placed '||placed||' of '||required_total||' requested periods');
 return jsonb_build_object('ok',true,'placed',placed,'unplaced',unplaced,'requested',required_total,
   'capacity',capacity,'periods_per_day',ppd,'day_periods',coalesce(p_day_periods,'{}'::jsonb),
   'unplaced_items',unplaced_items,
   'message',case when unplaced=0 then 'Conflict-free timetable generated.'
     else 'Generated with '||unplaced||' unplaced demand(s). Review teacher days/periods, blocked slots or increase periods/day.' end);
exception when others then return jsonb_build_object('ok',false,'error',sqlerrm);
end$$;
revoke execute on function public.generate_timetable(text,text,text,integer,jsonb) from public, anon;
grant execute on function public.generate_timetable(text,text,text,integer,jsonb) to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

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
grant execute on function public.generate_timetable(text,text,text,int,jsonb) to authenticated;
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

-- Getter/submission implementations are defined once in the definitive CBT section.

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
-- SECTION 18: RUNTIME HELPER RPCs (self-contained application contract)
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
  if not public.is_owner(auth.uid()) then raise exception 'Owner role required'; end if;
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

-- 18.5 purge_old is installed once in the V5.8 retention section.

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

-- Timetable and CBT import are installed by their single authoritative sections.

-- ============================================================================
-- SECTION 19: POSTGREST SCHEMA CACHE RELOAD (kills "schema cache" errors instantly)
-- ============================================================================

-- PostgREST caches the OpenAPI schema; after DDL it can briefly serve
-- "Could not find the table 'public.X' in the schema cache". Request a reload.
notify pgrst, 'reload schema';
select pg_notify('pgrst','reload schema');

select 'School Connect cumulative core installed; applying final V5.6.1 contracts…' as status;

-- Enhanced admission number and staff ID format settings
alter table public.school_settings add column if not exists admission_format text default 'prefix-dash';
alter table public.school_settings add column if not exists admission_start_num integer default 1;
alter table public.school_settings add column if not exists admission_include_year boolean default false;
alter table public.school_settings add column if not exists staff_mid_segment text default 'STF';

-- ============================================================================
-- SECTION 20: BROWSER/SCHEMA CONTRACT RECONCILIATION (ADDITIVE)
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

-- ============================================================================
-- SECTION 21: DEFINITIVE CBT GRADING, IDENTITY AND MULTI-SUBJECT ENGINE
-- A distinct RPC name prevents stale/legacy PostgREST overloads from silently
-- returning zero. Legacy answer-key spellings are normalised case-insensitively.
-- ============================================================================

alter table public.cbt_results alter column total type numeric(10,2) using total::numeric;
alter table public.cbt_results add column if not exists subject_scores jsonb not null default '{}'::jsonb;
alter table public.cbt_results add column if not exists ungraded_count int not null default 0;
alter table public.cbt_results add column if not exists grading_status text not null default 'graded';
alter table public.cbt_results add column if not exists engine_version text not null default '';
create index if not exists cbt_exams_normalized_code_idx on public.cbt_exams((regexp_replace(upper(code),'[^A-Z0-9]','','g')));

create or replace function public.sc_cbt_norm(p_value text)returns text language sql immutable parallel safe as $$select lower(regexp_replace(trim(coalesce(p_value,'')),'\s+',' ','g'))$$;

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

-- V5.3 teacher-owned signatures for class report cards.
alter table public.profiles add column if not exists signature_url text default '';
alter table public.staff add column if not exists signature_url text default '';

create or replace function public.get_class_teacher_identity(p_class text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare c record;s record;p record;teacher_name text:='';sig text:='';
begin
 select * into c from public.classes where lower(trim(name))=lower(trim(coalesce(p_class,''))) limit 1;
 if not found then return jsonb_build_object('name','Class Teacher','signature_url','','linked',false);end if;
 teacher_name:=coalesce(c.class_teacher,'');
 select * into s from public.staff where lower(trim(full_name))=lower(trim(teacher_name)) limit 1;
 if found then
   teacher_name:=coalesce(nullif(s.full_name,''),teacher_name);
   sig:=coalesce(nullif(s.signature_url,''),'');
   if s.user_id is not null then select * into p from public.profiles where id=s.user_id limit 1;if found then sig:=coalesce(nullif(p.signature_url,''),sig);teacher_name:=coalesce(nullif(p.full_name,''),teacher_name);end if;end if;
 end if;
 return jsonb_build_object('name',coalesce(nullif(teacher_name,''),'Class Teacher'),'signature_url',coalesce(sig,''),'linked',coalesce(s.user_id is not null,false));
end$$;
revoke execute on function public.get_class_teacher_identity(text)from public,anon;
grant execute on function public.get_class_teacher_identity(text)to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.3 teacher signature and class-report identity installed ✅'as status;

-- V5.4 beginning-of-term student physical/health metrics printed on reports.
create table if not exists public.student_term_metrics(
 id uuid primary key default gen_random_uuid(),student_id uuid references public.students(id)on delete cascade,
 student_id_ref text not null default '',student_name text not null default '',class text not null default '',
 term text not null default '',session text not null default '',height_cm numeric(6,2),weight_kg numeric(6,2),
 blood_pressure text default '',vision text default '',genotype text default '',blood_group text default '',
 medical_note text default '',recorded_by uuid references public.profiles(id)on delete set null,
 measured_on date default current_date,created_at timestamptz default now(),updated_at timestamptz default now(),
 unique(student_id_ref,student_name,class,term,session)
);
alter table public.student_term_metrics enable row level security;
drop policy if exists metrics_staff_all on public.student_term_metrics;
create policy metrics_staff_all on public.student_term_metrics for all using(public.is_staff(auth.uid()))with check(public.is_staff(auth.uid()));
drop policy if exists metrics_family_read on public.student_term_metrics;
create policy metrics_family_read on public.student_term_metrics for select using(exists(select 1 from public.students s where s.id=student_term_metrics.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create index if not exists student_term_metrics_lookup_idx on public.student_term_metrics(student_id,class,term,session);
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.4 portable archives, CBT organization and student metrics installed ✅'as status;

-- V5.5 registered-exam identity: admission number resolves the official student.
create or replace function public.cbt_get_public_exam_v6(p_code text,p_admission_no text default '')
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare
 base jsonb;exam_row public.cbt_exams%rowtype;student_row public.students%rowtype;
 candidate jsonb:='null'::jsonb;wanted text:=regexp_replace(upper(coalesce(p_admission_no,'')),'[^A-Z0-9]','','g');roster_count integer:=0;
begin
 base:=public.cbt_get_public_exam_v5(p_code);if not coalesce((base->>'ok')::boolean,false)then return base;end if;
 select ce.* into exam_row from public.cbt_exams ce where ce.id=(base->>'id')::uuid;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found','message','The examination record is no longer available.','engine_version','v5.6.1');end if;
 if lower(coalesce(exam_row.exam_mode,'open'))='registered'then
  if wanted=''then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','admission_required','message','This examination is restricted to registered students. Enter your admission number; your official name and class will be loaded automatically.','identity_mode','registered');end if;
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted and coalesce(st.status,'active')in('active','approved')limit 1;
  if not found then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','invalid_admission','message','No active registered student matches that admission number. Contact the school—do not type a name manually.','identity_mode','registered');end if;
  select count(*)into roster_count from public.cbt_roster cr where cr.exam_id=exam_row.id;
  if roster_count>0 and not exists(select 1 from public.cbt_roster cr where cr.exam_id=exam_row.id and regexp_replace(upper(coalesce(cr.student_id_ref,'')),'[^A-Z0-9]','','g')=wanted)then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','not_on_roster','message','This registered student is not on the roster for this examination.','identity_mode','registered');end if;
  candidate:=jsonb_build_object('id',student_row.id,'admission_no',student_row.admission_no,'full_name',student_row.full_name,'class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));
  return base||jsonb_build_object('identity_mode','registered','candidate',candidate,'identity_engine_version','v5.6.1');
 end if;
 -- Open/multi-subject exams may start without admission. Never read an unassigned record.
 if wanted<>''then
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted limit 1;
  if found then candidate:=jsonb_build_object('id',student_row.id,'admission_no',student_row.admission_no,'full_name',student_row.full_name,'class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));end if;
 end if;
 return base||jsonb_build_object('identity_mode','open','candidate',candidate,'identity_engine_version','v5.6.1');
end$$;

create or replace function public.cbt_submit_v6(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare exam_row public.cbt_exams%rowtype;student_row public.students%rowtype;wanted text:='';roster_count integer:=0;payload jsonb:=coalesce(p_payload,'{}'::jsonb);
begin
 select ce.* into exam_row from public.cbt_exams ce where ce.id=(p_payload->>'exam_id')::uuid;
 if not found then return jsonb_build_object('saved',false,'error','exam_not_found','message','Exam not found.','engine_version','v5.6.1');end if;
 if lower(coalesce(exam_row.exam_mode,'open'))='registered'then
  wanted:=regexp_replace(upper(coalesce(p_payload->>'student_id_ref','')),'[^A-Z0-9]','','g');if wanted=''then return jsonb_build_object('saved',false,'error','admission_required','message','Admission number is required.','engine_version','v5.6.1');end if;
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted and coalesce(st.status,'active')in('active','approved')limit 1;
  if not found then return jsonb_build_object('saved',false,'error','invalid_admission','message','Registered student not found.','engine_version','v5.6.1');end if;
  select count(*)into roster_count from public.cbt_roster cr where cr.exam_id=exam_row.id;
  if roster_count>0 and not exists(select 1 from public.cbt_roster cr where cr.exam_id=exam_row.id and regexp_replace(upper(coalesce(cr.student_id_ref,'')),'[^A-Z0-9]','','g')=wanted)then return jsonb_build_object('saved',false,'error','not_on_roster','message','Student is not on this exam roster.','engine_version','v5.6.1');end if;
  payload:=payload||jsonb_build_object('student_id',student_row.id,'student_id_ref',student_row.admission_no,'student_name',student_row.full_name,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')),'student_type','registered');
 elsif coalesce(p_payload->>'student_id_ref','')<>''then
  wanted:=regexp_replace(upper(p_payload->>'student_id_ref'),'[^A-Z0-9]','','g');select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted limit 1;
  if found then payload:=payload||jsonb_build_object('student_id',student_row.id,'student_id_ref',student_row.admission_no,'student_name',student_row.full_name,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));end if;
 end if;
 return public.cbt_submit_v5(payload);
exception when invalid_text_representation then return jsonb_build_object('saved',false,'error','invalid_exam_id','message','The exam identifier is invalid. Reload the exam and try again.','engine_version','v5.6.1');
end$$;
revoke execute on function public.cbt_get_public_exam_v6(text,text)from public;grant execute on function public.cbt_get_public_exam_v6(text,text)to anon,authenticated;
revoke execute on function public.cbt_submit_v6(jsonb)from public;grant execute on function public.cbt_submit_v6(jsonb)to anon,authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.5 registered CBT identity installed ✅'as status;
select 'School Connect V5.5 installed — flexible report headings, registered CBT identity, recovery-ready auth and academic insights ✅'as status;

-- V5.6 daily fee collection authority (Africa/Lagos school date).
alter table public.fee_payments add column if not exists payment_date date default ((now() at time zone 'Africa/Lagos')::date);
alter table public.fee_payments add column if not exists received_by_name text default '';
update public.fee_payments set payment_date=(created_at at time zone 'Africa/Lagos')::date where payment_date is null;
create index if not exists fee_payments_daily_idx on public.fee_payments(payment_date,created_at desc);
create index if not exists fee_payments_method_daily_idx on public.fee_payments(payment_date,method);
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.6 daily fee collection fields installed ✅'as status;

-- V5.6 controlled CBT result reset for exam reuse.
create or replace function public.cbt_clear_exam_results(p_exam_id uuid,p_confirm_code text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record;n int:=0;
begin
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'error','Exam not found');end if;
 if not(public.is_admin(auth.uid())or e.teacher_id=auth.uid())then return jsonb_build_object('ok',false,'error','Only an admin or the teacher who created this exam can clear its results.');end if;
 if upper(trim(coalesce(p_confirm_code,'')))<>upper(trim(e.code))then return jsonb_build_object('ok',false,'error','Confirmation code does not match.');end if;
 select count(*)into n from public.cbt_results where exam_id=p_exam_id;delete from public.cbt_results where exam_id=p_exam_id;
 return jsonb_build_object('ok',true,'deleted',n,'exam_id',p_exam_id,'code',e.code,'message','Results cleared. The exam can now collect a fresh set of attempts. Previously pushed report_scores are unchanged and should be audited separately if necessary.');
end$$;
revoke execute on function public.cbt_clear_exam_results(uuid,text)from public,anon;
grant execute on function public.cbt_clear_exam_results(uuid,text)to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.6 controlled CBT result reset installed ✅'as status;

-- V5.6 strict teacher subject/class isolation. Admin roles retain full control.
create or replace function public.teacher_can_manage_subject_class(p_uid uuid,p_subject text default '',p_class text default '')
returns boolean language plpgsql security definer stable set search_path=public as $$
declare pname text:='';srec record;subject_ok boolean:=false;class_ok boolean:=false;
begin
 if public.is_admin(p_uid)then return true;end if;
 select full_name into pname from public.profiles where id=p_uid and role in('teacher','staff')and status in('approved','active');if not found then return false;end if;
 select * into srec from public.staff where user_id=p_uid and coalesce(status,'active')='active'limit 1;
 if coalesce(trim(p_subject),'')<>''then
  subject_ok:=exists(select 1 from public.subjects su where lower(trim(su.name))=lower(trim(p_subject))and(su.teacher_id=p_uid or lower(trim(coalesce(su.teacher,'')))=lower(trim(pname))or(srec.id is not null and lower(trim(coalesce(su.teacher,'')))=lower(trim(srec.full_name)))or(srec.id is not null and p_subject=any(coalesce(srec.subjects,'{}'::text[])))));
 end if;
 if coalesce(trim(p_class),'')<>''then class_ok:=exists(select 1 from public.classes c where lower(trim(c.name))=lower(trim(p_class))and(lower(trim(coalesce(c.class_teacher,'')))=lower(trim(pname))or(srec.id is not null and lower(trim(coalesce(c.class_teacher,'')))=lower(trim(srec.full_name)))));end if;
 return subject_ok or class_ok;
end$$;
create or replace function public.teacher_can_manage_student(p_uid uuid,p_student uuid)
returns boolean language sql security definer stable set search_path=public as $$select public.is_admin(p_uid)or exists(select 1 from public.students s where s.id=p_student and public.teacher_can_manage_subject_class(p_uid,'',s.class))$$;
revoke execute on function public.teacher_can_manage_subject_class(uuid,text,text)from public,anon;grant execute on function public.teacher_can_manage_subject_class(uuid,text,text)to authenticated;
revoke execute on function public.teacher_can_manage_student(uuid,uuid)from public,anon;grant execute on function public.teacher_can_manage_student(uuid,uuid)to authenticated;

-- Remove accumulated overlapping policies on academic write tables, then install one clear contract.
do $$declare t text;p record;begin
 foreach t in array array['results','attendance','assignments','scheme_of_work','lesson_plans','cbt_exams','cbt_results','report_scores','affective_traits','psychomotor_traits','report_comments']loop
  for p in select policyname from pg_policies where schemaname='public'and tablename=t loop execute format('drop policy if exists %I on public.%I',p.policyname,t);end loop;
 end loop;
end$$;

create policy results_scope_select on public.results for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where s.id=results.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy results_scope_insert on public.results for insert with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy results_scope_update on public.results for update using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy results_scope_delete on public.results for delete using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));

create policy attendance_scope_select on public.attendance for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),'',class)or exists(select 1 from public.students s where s.id=attendance.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy attendance_scope_insert on public.attendance for insert with check(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)));
create policy attendance_scope_update on public.attendance for update using(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)))with check(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)));
create policy attendance_scope_delete on public.attendance for delete using(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)));

create policy assignments_scope_select on public.assignments for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))and s.class=assignments.class));
create policy assignments_scope_write on public.assignments for all using(public.is_admin(auth.uid())or(posted_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(posted_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy sow_scope_select on public.scheme_of_work for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))and s.class=scheme_of_work.class));
create policy sow_scope_write on public.scheme_of_work for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy lesson_scope_select on public.lesson_plans for select using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy lesson_scope_write on public.lesson_plans for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));

create policy cbt_exam_scope_select on public.cbt_exams for select using(public.is_admin(auth.uid())or teacher_id=auth.uid()or public.teacher_can_manage_subject_class(auth.uid(),subject,class));
create policy cbt_exam_scope_insert on public.cbt_exams for insert with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy cbt_exam_scope_update on public.cbt_exams for update using(public.is_admin(auth.uid())or teacher_id=auth.uid())with check(public.is_admin(auth.uid())or teacher_id=auth.uid());
create policy cbt_exam_scope_delete on public.cbt_exams for delete using(public.is_admin(auth.uid())or teacher_id=auth.uid());
create policy cbt_result_scope_select on public.cbt_results for select using(public.is_admin(auth.uid())or exists(select 1 from public.cbt_exams e where e.id=cbt_results.exam_id and(e.teacher_id=auth.uid()or public.teacher_can_manage_subject_class(auth.uid(),e.subject,e.class)))or exists(select 1 from public.students s where s.id=cbt_results.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy cbt_result_no_direct_insert on public.cbt_results for insert with check(false);
create policy cbt_result_owner_delete on public.cbt_results for delete using(public.is_admin(auth.uid())or exists(select 1 from public.cbt_exams e where e.id=cbt_results.exam_id and e.teacher_id=auth.uid()));

create policy report_score_scope_select on public.report_scores for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where(s.id=report_scores.student_id or s.admission_no=report_scores.student_id_ref)and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy report_score_scope_insert on public.report_scores for insert with check(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy report_score_scope_update on public.report_scores for update using(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy report_score_scope_delete on public.report_scores for delete using(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));

create policy affective_scope_select on public.affective_traits for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=affective_traits.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy affective_scope_write on public.affective_traits for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
create policy psychomotor_scope_select on public.psychomotor_traits for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=psychomotor_traits.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy psychomotor_scope_write on public.psychomotor_traits for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
alter table public.report_comments add column if not exists teacher_id uuid references public.profiles(id)on delete set null;
create policy comments_scope_select on public.report_comments for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=report_comments.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy comments_scope_write on public.report_comments for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));

-- School structure is admin-managed; teachers read it through existing select policies.
do $$declare t text;p record;begin foreach t in array array['classes','subjects','departments','timetable_requirements','teacher_availability']loop for p in select policyname from pg_policies where schemaname='public'and tablename=t and cmd<>'SELECT'loop execute format('drop policy if exists %I on public.%I',p.policyname,t);end loop;execute format('create policy %I on public.%I for all using(public.is_admin(auth.uid()))with check(public.is_admin(auth.uid()))','admin_manage_'||t,t);end loop;end$$;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.6 strict teacher subject/class isolation installed ✅'as status;
drop policy if exists authenticated_read_classes on public.classes;create policy authenticated_read_classes on public.classes for select using(auth.role()='authenticated');
drop policy if exists authenticated_read_subjects on public.subjects;create policy authenticated_read_subjects on public.subjects for select using(auth.role()='authenticated');
drop policy if exists authenticated_read_departments on public.departments;create policy authenticated_read_departments on public.departments for select using(auth.role()='authenticated');
drop policy if exists scoped_read_timetable_requirements on public.timetable_requirements;create policy scoped_read_timetable_requirements on public.timetable_requirements for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class));
drop policy if exists scoped_read_teacher_availability on public.teacher_availability;create policy scoped_read_teacher_availability on public.teacher_availability for select using(public.is_admin(auth.uid())or lower(trim(teacher))=lower(trim(coalesce((select full_name from public.profiles where id=auth.uid()),''))));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- Additional teacher-owned/class-scoped operational records.
alter table public.digital_library add column if not exists teacher_id uuid references public.profiles(id)on delete set null;
alter table public.conduct add column if not exists recorded_by_id uuid references public.profiles(id)on delete set null;
alter table public.support_plans add column if not exists created_by uuid references public.profiles(id)on delete set null;
do $$declare t text;p record;begin foreach t in array array['digital_library','eresources','conduct','behaviour_points','support_plans','student_diary','student_term_metrics']loop for p in select policyname from pg_policies where schemaname='public'and tablename=t and cmd<>'SELECT'loop execute format('drop policy if exists %I on public.%I',p.policyname,t);end loop;end loop;end$$;
create policy dl_teacher_write on public.digital_library for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy er_teacher_write on public.eresources for all using(public.is_admin(auth.uid())or(uploaded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(uploaded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy conduct_teacher_write on public.conduct for all using(public.is_admin(auth.uid())or(recorded_by_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(recorded_by_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
create policy behaviour_teacher_write on public.behaviour_points for all using(public.is_admin(auth.uid())or(awarded_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(awarded_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
create policy support_teacher_write on public.support_plans for all using(public.is_admin(auth.uid())or(created_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(created_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
create policy diary_teacher_write on public.student_diary for all using(public.is_admin(auth.uid())or(created_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(created_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists metrics_staff_all on public.student_term_metrics;create policy metrics_teacher_write on public.student_term_metrics for all using(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.6 extended teacher ownership installed ✅'as status;
drop policy if exists dl_scope_read on public.digital_library;create policy dl_scope_read on public.digital_library for select using(auth.role()='authenticated');
drop policy if exists er_scope_read on public.eresources;create policy er_scope_read on public.eresources for select using(auth.role()='authenticated');
drop policy if exists conduct_scope_read on public.conduct;create policy conduct_scope_read on public.conduct for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=conduct.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
drop policy if exists behaviour_scope_read on public.behaviour_points;create policy behaviour_scope_read on public.behaviour_points for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=behaviour_points.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
drop policy if exists support_scope_read on public.support_plans;create policy support_scope_read on public.support_plans for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=support_plans.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
drop policy if exists diary_scope_read on public.student_diary;create policy diary_scope_read on public.student_diary for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where s.id=student_diary.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- V5.6 legacy-row claim rule: assigned teachers may claim an unowned row once;
-- owned rows remain editable/deletable only by that owner or admin.
drop policy if exists results_scope_update on public.results;create policy results_scope_update on public.results for update using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists results_scope_delete on public.results;create policy results_scope_delete on public.results for delete using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists attendance_scope_update on public.attendance;create policy attendance_scope_update on public.attendance for update using(public.is_admin(auth.uid())or((recorded_by=auth.uid()or recorded_by is null)and public.teacher_can_manage_subject_class(auth.uid(),'',class)))with check(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)));
drop policy if exists attendance_scope_delete on public.attendance;create policy attendance_scope_delete on public.attendance for delete using(public.is_admin(auth.uid())or((recorded_by=auth.uid()or recorded_by is null)and public.teacher_can_manage_subject_class(auth.uid(),'',class)));
drop policy if exists assignments_scope_write on public.assignments;create policy assignments_scope_write on public.assignments for all using(public.is_admin(auth.uid())or((posted_by=auth.uid()or posted_by is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(posted_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists sow_scope_write on public.scheme_of_work;create policy sow_scope_write on public.scheme_of_work for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists lesson_scope_write on public.lesson_plans;create policy lesson_scope_write on public.lesson_plans for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists cbt_exam_scope_update on public.cbt_exams;create policy cbt_exam_scope_update on public.cbt_exams for update using(public.is_admin(auth.uid())or teacher_id=auth.uid()or(teacher_id is null and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or teacher_id=auth.uid());
drop policy if exists cbt_exam_scope_delete on public.cbt_exams;create policy cbt_exam_scope_delete on public.cbt_exams for delete using(public.is_admin(auth.uid())or teacher_id=auth.uid());
drop policy if exists report_score_scope_update on public.report_scores;create policy report_score_scope_update on public.report_scores for update using(public.is_admin(auth.uid())or((updated_by=auth.uid()or updated_by is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists report_score_scope_delete on public.report_scores;create policy report_score_scope_delete on public.report_scores for delete using(public.is_admin(auth.uid())or((updated_by=auth.uid()or updated_by is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists affective_scope_write on public.affective_traits;create policy affective_scope_write on public.affective_traits for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
drop policy if exists psychomotor_scope_write on public.psychomotor_traits;create policy psychomotor_scope_write on public.psychomotor_traits for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
drop policy if exists comments_scope_write on public.report_comments;create policy comments_scope_write on public.report_comments for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- ============================================================================
-- V5.7 FINAL PROFESSIONAL AUDIT ENHANCEMENTS
-- ============================================================================
alter table public.school_settings add column if not exists principal_signature_bg_removed boolean not null default true;
alter table public.school_settings add column if not exists proprietor_name text default '';
alter table public.school_settings add column if not exists proprietor_signature_url text default '';
alter table public.school_settings add column if not exists proprietor_signature_bg_removed boolean not null default true;
alter table public.school_settings add column if not exists examination_officer_name text default '';
alter table public.school_settings add column if not exists examination_officer_signature_url text default '';
alter table public.school_settings add column if not exists examination_officer_signature_bg_removed boolean not null default true;
create or replace function public.is_owner(p_uid uuid)returns boolean language sql security definer stable set search_path=public as $$select exists(select 1 from profiles where id=p_uid and role in('super_admin','admin','proprietor')and status in('approved','active'))$$;
create or replace function public.is_school_leader(p_uid uuid)returns boolean language sql security definer stable set search_path=public as $$select exists(select 1 from profiles where id=p_uid and role in('super_admin','admin','proprietor','principal','head_teacher')and status in('approved','active'))$$;
revoke execute on function public.is_owner(uuid)from public,anon;grant execute on function public.is_owner(uuid)to authenticated;
revoke execute on function public.is_school_leader(uuid)from public,anon;grant execute on function public.is_school_leader(uuid)to authenticated;
create table if not exists public.exam_registration_links(id uuid primary key default gen_random_uuid(),token text not null unique default upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),title text not null,intro text default '',exam_types text[]not null default '{}',session text default '',term text default '',registration_deadline timestamptz,exam_date date,venue text default '',fee_note text default '',requirements text default '',instructions text default '',contact_name text default '',contact_phone text default '',contact_email text default '',consent_text text default '',success_message text default '',hidden_fields text[]not null default '{}',active boolean not null default true,created_by uuid references profiles(id)on delete set null,created_at timestamptz default now(),updated_at timestamptz default now());
alter table public.exam_registrations add column if not exists registration_link_id uuid references public.exam_registration_links(id)on delete set null;
alter table public.exam_registrations add column if not exists reg_code text default '';
alter table public.exam_registrations add column if not exists candidate_name text default '';
alter table public.exam_registrations add column if not exists email text default '';
alter table public.exam_registrations add column if not exists phone text default '';
alter table public.exam_registrations add column if not exists updated_at timestamptz default now();
create index if not exists exam_registration_links_active_idx on exam_registration_links(active,registration_deadline);create index if not exists exam_registrations_link_idx on exam_registrations(registration_link_id,created_at desc);
alter table exam_registration_links enable row level security;
drop policy if exists exam_links_staff_read on exam_registration_links;create policy exam_links_staff_read on exam_registration_links for select using(is_staff(auth.uid()));
drop policy if exists exam_links_leader_manage on exam_registration_links;create policy exam_links_leader_manage on exam_registration_links for all using(is_school_leader(auth.uid()))with check(is_school_leader(auth.uid()));
drop policy if exists exam_regs_staff_read on exam_registrations;create policy exam_regs_staff_read on exam_registrations for select using(is_staff(auth.uid()));
drop policy if exists exam_regs_leader_manage on exam_registrations;create policy exam_regs_leader_manage on exam_registrations for update using(is_school_leader(auth.uid()))with check(is_school_leader(auth.uid()));
drop policy if exists exam_regs_leader_delete on exam_registrations;create policy exam_regs_leader_delete on exam_registrations for delete using(is_school_leader(auth.uid()));
create or replace function public.get_exam_registration_link(p_token text)returns jsonb language plpgsql security definer stable set search_path=public as $$declare x exam_registration_links%rowtype;begin select*into x from exam_registration_links where upper(token)=upper(trim(coalesce(p_token,'')))and active limit 1;if not found then return jsonb_build_object('ok',false,'error','link_not_found','message','This registration link is invalid, inactive or removed.');end if;if x.registration_deadline is not null and now()>x.registration_deadline then return jsonb_build_object('ok',false,'error','registration_closed','message','Registration has closed.','title',x.title);end if;return to_jsonb(x)-'created_by'||jsonb_build_object('ok',true);end$$;
revoke execute on function public.get_exam_registration_link(text)from public;grant execute on function public.get_exam_registration_link(text)to anon,authenticated;
create or replace function public.submit_exam_registration(p_token text,p_payload jsonb)returns jsonb language plpgsql security definer set search_path=public as $$declare l exam_registration_links%rowtype;rid uuid;link_id uuid;success_text text:='';tok text:=upper(trim(coalesce(p_token,'')));begin if tok<>''then select*into l from exam_registration_links where upper(token)=tok and active limit 1;if not found then return jsonb_build_object('ok',false,'error','link_not_found','message','This registration link is invalid, inactive or removed.');end if;if l.registration_deadline is not null and now()>l.registration_deadline then return jsonb_build_object('ok',false,'error','registration_closed','message','Registration has closed.');end if;link_id:=l.id;success_text:=l.success_message;end if;if trim(coalesce(p_payload->>'candidate_name',''))=''or trim(coalesce(p_payload->>'exam_type',''))=''then return jsonb_build_object('ok',false,'error','required_fields','message','Candidate name and examination type are required.');end if;insert into exam_registrations(registration_link_id,reg_code,candidate_name,student_name,class,exam_type,exam_year,email,phone,status,payload,created_at,updated_at)values(link_id,tok,p_payload->>'candidate_name',p_payload->>'candidate_name',p_payload->>'class',p_payload->>'exam_type',nullif(p_payload->>'exam_year','')::int,p_payload->>'email',p_payload->>'phone','pending',p_payload,now(),now())returning id into rid;return jsonb_build_object('ok',true,'id',rid,'reference','EXREG-'||upper(substr(replace(rid::text,'-',''),1,10)),'message',coalesce(nullif(success_text,''),'Registration received. The examination office will contact you.'));exception when others then return jsonb_build_object('ok',false,'error','server_error','message',sqlerrm);end$$;
revoke execute on function public.submit_exam_registration(text,jsonb)from public;grant execute on function public.submit_exam_registration(text,jsonb)to anon,authenticated;
create or replace function public.delete_exam_registration_link(p_id uuid)returns jsonb language plpgsql security definer set search_path=public as $$declare n int;begin if not is_school_leader(auth.uid())then return jsonb_build_object('ok',false,'error','permission_denied');end if;update exam_registrations set registration_link_id=null where registration_link_id=p_id;delete from exam_registration_links where id=p_id;get diagnostics n=row_count;return jsonb_build_object('ok',n=1,'deleted',n);end$$;
revoke execute on function public.delete_exam_registration_link(uuid)from public,anon;grant execute on function public.delete_exam_registration_link(uuid)to authenticated;
create table if not exists public.report_comment_bands(id uuid primary key default gen_random_uuid(),label text not null,min_percent numeric(5,2)not null,max_percent numeric(5,2)not null,class text not null default '*',term text not null default '*',session text not null default '*',class_teacher_comment text not null,principal_comment text not null default '',priority int not null default 0,active boolean not null default true,created_by uuid references profiles(id)on delete set null,created_at timestamptz default now(),updated_at timestamptz default now(),check(min_percent>=0 and max_percent<=100 and min_percent<=max_percent));
create index if not exists report_comment_bands_context_idx on report_comment_bands(class,term,session,active,min_percent,max_percent,priority desc);alter table report_comment_bands enable row level security;
alter table report_comments add column if not exists comment_source text not null default 'manual';alter table report_comments add column if not exists comment_band_id uuid references report_comment_bands(id)on delete set null;alter table report_comments add column if not exists applied_percent numeric(5,2);alter table report_comments add column if not exists comment_locked boolean not null default false;alter table report_comments add column if not exists updated_at timestamptz default now();
drop policy if exists comment_bands_staff_read on report_comment_bands;create policy comment_bands_staff_read on report_comment_bands for select using(is_staff(auth.uid()));drop policy if exists comment_bands_leader_manage on report_comment_bands;create policy comment_bands_leader_manage on report_comment_bands for all using(is_school_leader(auth.uid()))with check(is_school_leader(auth.uid()));
drop policy if exists site_license_write on site_license;create policy site_license_write on site_license for all using(is_owner(auth.uid()))with check(is_owner(auth.uid()));drop policy if exists v7_settings_write on school_settings;create policy v7_settings_write on school_settings for all using(is_school_leader(auth.uid()))with check(is_school_leader(auth.uid()));drop policy if exists role_status_log_write on role_status_log;drop policy if exists v7_role_log_write on role_status_log;create policy v7_role_log_write on role_status_log for all using(is_owner(auth.uid()))with check(is_owner(auth.uid()));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');select 'School Connect V5.7 professional audit enhancements installed ✅'as status;

-- ============================================================================
-- V5.8 VERIFIED DELETION, ID AUTHORITY AND FREE-TIER DATA EFFICIENCY
-- ============================================================================
create table if not exists public.data_retention_settings(
 id smallint primary key default 1 check(id=1),quota_mb numeric not null default 500,
 warning_percent numeric not null default 75,critical_percent numeric not null default 90,
 activity_log_days int not null default 365,login_audit_days int not null default 180,
 notification_days int not null default 180,checkin_days int not null default 365,
 clock_days int not null default 730,cbt_result_days int not null default 730,
 reading_score_days int not null default 730,updated_by uuid references public.profiles(id)on delete set null,
 updated_at timestamptz not null default now());
insert into public.data_retention_settings(id)values(1)on conflict(id)do nothing;
alter table public.data_retention_settings enable row level security;
drop policy if exists retention_owner_read on public.data_retention_settings;create policy retention_owner_read on public.data_retention_settings for select using(public.is_owner(auth.uid()));
drop policy if exists retention_owner_write on public.data_retention_settings;create policy retention_owner_write on public.data_retention_settings for all using(public.is_owner(auth.uid()))with check(public.is_owner(auth.uid()));
alter table public.certificate_designs add column if not exists signature_url text default '';

create or replace function public.storage_health()
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare used_bytes bigint:=0;cfg public.data_retention_settings%rowtype;embedded bigint:=0;begin
 if not public.is_owner(auth.uid())then raise exception 'Owner role required';end if;
 select coalesce(sum(pg_total_relation_size(c.oid)),0)::bigint into used_bytes from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'and c.relkind='r';select*into cfg from data_retention_settings where id=1;
 select coalesce(sum(n),0)into embedded from(
  select count(*)n from school_settings where coalesce(signature_url,'')like'data:%'or coalesce(proprietor_signature_url,'')like'data:%'or coalesce(examination_officer_signature_url,'')like'data:%'
  union all select count(*)from profiles where coalesce(photo_url,'')like'data:%'or coalesce(signature_url,'')like'data:%'
  union all select count(*)from staff where coalesce(photo_url,'')like'data:%'or coalesce(signature_url,'')like'data:%'
  union all select count(*)from students where coalesce(photo_url,'')like'data:%'
  union all select count(*)from certificate_designs where coalesce(signature_data,'')like'data:%'or coalesce(signature_url,'')like'data:%')q;
 return jsonb_build_object('used_bytes',used_bytes,'used_pretty',pg_size_pretty(used_bytes),'quota_mb',cfg.quota_mb,'quota_bytes',(cfg.quota_mb*1024*1024)::bigint,'percent',round(used_bytes/greatest(cfg.quota_mb*1024*1024,1)*100,2),'status',case when used_bytes>=cfg.quota_mb*1024*1024*cfg.critical_percent/100 then'critical'when used_bytes>=cfg.quota_mb*1024*1024*cfg.warning_percent/100 then'warning'else'healthy'end,'embedded_media_rows',embedded,'media_policy','external-links-only');
end$$;
revoke execute on function public.storage_health()from public,anon,authenticated;grant execute on function public.storage_health()to authenticated;

create or replace function public.retention_candidates()
returns table(table_name text,date_column text,keep_days int,eligible_rows bigint)language plpgsql security definer stable set search_path=public as $$
declare cfg data_retention_settings%rowtype;r record;n bigint;begin
 if not is_owner(auth.uid())then raise exception 'Owner role required';end if;select*into cfg from data_retention_settings where id=1;
 for r in select*from(values('activity_log','created_at',cfg.activity_log_days),('login_audit','created_at',cfg.login_audit_days),('notifications','created_at',cfg.notification_days),('attendance_checkins','checkin_at',cfg.checkin_days),('staff_clock','created_at',cfg.clock_days),('student_clock','created_at',cfg.clock_days),('cbt_results','created_at',cfg.cbt_result_days),('reading_scores','created_at',cfg.reading_score_days))v(t,c,d)loop execute format('select count(*) from public.%I where %I < now()-make_interval(days=>$1)',r.t,r.c)into n using r.d;table_name:=r.t;date_column:=r.c;keep_days:=r.d;eligible_rows:=n;return next;end loop;
end$$;
revoke execute on function public.retention_candidates()from public,anon,authenticated;grant execute on function public.retention_candidates()to authenticated;

create or replace function public.purge_old(p_table text,p_days integer)
returns integer language plpgsql security definer set search_path=public as $$declare col text;n int;begin
 if not is_owner(auth.uid())then raise exception 'Owner role required';end if;
 col:=case p_table when'attendance_checkins'then'checkin_at'when'activity_log'then'created_at'when'login_audit'then'created_at'when'notifications'then'created_at'when'staff_clock'then'created_at'when'student_clock'then'created_at'when'cbt_results'then'created_at'when'reading_scores'then'created_at'else null end;if col is null then raise exception 'Table is not retention-purgeable';end if;
 execute format('delete from public.%I where %I < now()-make_interval(days=>$1)',p_table,col)using greatest(coalesce(p_days,180),1);get diagnostics n=row_count;return n;
end$$;
revoke execute on function public.purge_old(text,integer)from public,anon;grant execute on function public.purge_old(text,integer)to authenticated;

create or replace function public.sc_prevent_embedded_media()
returns trigger language plpgsql set search_path=public as $$declare j jsonb:=to_jsonb(new);oldj jsonb:=case when tg_op='UPDATE'then to_jsonb(old)else'{}'::jsonb end;r record;begin
 for r in select key,value from jsonb_each_text(j)where key~'(_url|_link|signature_data)$'loop
  if(length(r.value)>4096 or r.value~*'^data:(image|video|audio|application)/'or r.value~*'^base64,')and(tg_op='INSERT'or coalesce(oldj->>r.key,'')is distinct from r.value)then raise exception 'Embedded file data is not allowed in %.%. Paste a public Google Drive/external URL instead.',tg_table_name,r.key;end if;
 end loop;return new;
end$$;
do $$declare t text;begin foreach t in array array['school_settings','profiles','students','staff','parents','admissions','gallery','eresources','digital_library','certificate_designs','certificates']loop if to_regclass('public.'||t)is not null then execute format('drop trigger if exists sc_external_media_only on public.%I',t);execute format('create trigger sc_external_media_only before insert or update on public.%I for each row execute function public.sc_prevent_embedded_media()',t);end if;end loop;end$$;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.8 deletion, ID-format and free-tier efficiency safeguards installed ✅'as status;

-- ============================================================================
-- FINAL V5.8 SELF-SUFFICIENCY CHECK AND POSTGREST RELOAD
-- ============================================================================
do $$declare missing text[]:='{}';begin
 if to_regclass('public.cbt_exams')is null then missing:=array_append(missing,'table:cbt_exams');end if;
 if to_regclass('public.cbt_results')is null then missing:=array_append(missing,'table:cbt_results');end if;
 if to_regclass('public.cbt_roster')is null then missing:=array_append(missing,'table:cbt_roster');end if;
 if to_regclass('public.fee_payments')is null then missing:=array_append(missing,'table:fee_payments');end if;
 if to_regclass('public.student_term_metrics')is null then missing:=array_append(missing,'table:student_term_metrics');end if;
 if to_regclass('public.exam_registration_links')is null then missing:=array_append(missing,'table:exam_registration_links');end if;
 if to_regclass('public.report_comment_bands')is null then missing:=array_append(missing,'table:report_comment_bands');end if;
 if to_regclass('public.data_retention_settings')is null then missing:=array_append(missing,'table:data_retention_settings');end if;
 if to_regclass('public.sc_install_state')is null then missing:=array_append(missing,'table:sc_install_state');end if;
 if to_regprocedure('public.storage_health()')is null then missing:=array_append(missing,'rpc:storage_health');end if;
 if to_regprocedure('public.retention_candidates()')is null then missing:=array_append(missing,'rpc:retention_candidates');end if;
 if to_regprocedure('public.cbt_get_public_exam_v6(text,text)')is null then missing:=array_append(missing,'rpc:cbt_get_public_exam_v6');end if;
 if to_regprocedure('public.cbt_submit_v6(jsonb)')is null then missing:=array_append(missing,'rpc:cbt_submit_v6');end if;
 if to_regprocedure('public.cbt_clear_exam_results(uuid,text)')is null then missing:=array_append(missing,'rpc:cbt_clear_exam_results');end if;
 if to_regprocedure('public.teacher_can_manage_subject_class(uuid,text,text)')is null then missing:=array_append(missing,'rpc:teacher_can_manage_subject_class');end if;
 if to_regprocedure('public.teacher_can_manage_student(uuid,uuid)')is null then missing:=array_append(missing,'rpc:teacher_can_manage_student');end if;
 if to_regprocedure('public.generate_timetable(text,text,text,integer,jsonb)')is null then missing:=array_append(missing,'rpc:generate_timetable');end if;
 if coalesce(array_length(missing,1),0)>0 then raise exception 'School Connect V5.8 incomplete installation: %',array_to_string(missing,', ');end if;
end$$;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- =============== SUPABASE FREE-TIER KEEP-ALIVE (auto-installed) ===============
-- ============================================================
-- SUPABASE FREE-TIER KEEP-ALIVE (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Supabase pauses free-tier projects after ~7 days without
-- DATABASE activity. This installs a tiny heartbeat table and
-- a public RPC that performs a real write. It is called
-- automatically by:
--   1. assets/js/app.js       (once per visitor per 24h)
--   2. .github/workflows/keep-supabase-alive.yml (Mon & Thu)
--   3. supabase/functions/ping (UptimeRobot / Vercel cron)
--   4. pg_cron (internal DB scheduler, if available)
-- This file is ALREADY included inside complete-schema.sql;
-- run it standalone only on databases installed before this
-- feature existed.
-- ============================================================

create table if not exists public.sc_heartbeat (
  id          integer primary key,
  last_ping   timestamptz not null default now(),
  last_source text,
  ping_count  bigint not null default 0
);

alter table public.sc_heartbeat enable row level security;
-- No direct table policies: the table is only reachable through the RPC below.
revoke all on table public.sc_heartbeat from anon, authenticated;

insert into public.sc_heartbeat (id) values (1) on conflict (id) do nothing;

create or replace function public.sc_keep_alive(src text default 'unknown')
returns timestamptz
language sql
security definer
set search_path = public
as $keepalive$
  update public.sc_heartbeat
     set last_ping   = now(),
         last_source = left(coalesce(src, 'unknown'), 40),
         ping_count  = ping_count + 1
   where id = 1
  returning last_ping;
$keepalive$;

grant execute on function public.sc_keep_alive(text) to anon, authenticated;

-- ------------------------------------------------------------
-- Layer 4 (fully internal): pg_cron heartbeat every 2 days.
-- pg_cron is available on Supabase; internal scheduled queries
-- also count as database activity. Wrapped so installation
-- never fails on databases where pg_cron is unavailable.
-- ------------------------------------------------------------
do $cronsetup$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron;
      perform cron.unschedule(jobid) from cron.job where jobname = 'sc-keep-alive';
      perform cron.schedule('sc-keep-alive', '23 5 */2 * *', $job$select public.sc_keep_alive('pg_cron')$job$);
      raise notice 'sc-keep-alive pg_cron job scheduled (every 2 days at 05:23 UTC).';
    exception when others then
      raise notice 'pg_cron keep-alive not scheduled (%). External heartbeats still protect the project.', sqlerrm;
    end;
  else
    raise notice 'pg_cron extension not available; relying on site-visit + GitHub Actions + UptimeRobot heartbeats.';
  end if;
end
$cronsetup$;

-- (keep-alive heartbeat installed)


-- =============== FILE-STORAGE ARCHIVE VAULT (auto-installed) ===============
-- ============================================================
-- FILE-STORAGE ARCHIVE VAULT (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Purpose: keep the limited 500 MB FREE-TIER DATABASE small by
-- moving OLD/COLD rows (audit logs, old CBT attempts, read
-- notifications, old check-ins…) into the SEPARATE 1 GB Supabase
-- FILE STORAGE as portable JSON archives, then purging them from
-- the database. Archives can be listed, downloaded and RESTORED
-- back into the database at any time from the Storage Manager page.
--
-- This creates a PRIVATE bucket called `archives` that only
-- owner-level admins (super_admin / admin / proprietor) can use.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this feature.
-- ============================================================
do $offload$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema not present (local test database) — archive bucket skipped.';
    return;
  end if;

  -- 1. Private bucket (50 MB per single archive file is far more than needed)
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('archives', 'archives', false, 52428800, array['application/json'])
  on conflict (id) do nothing;

  -- 2. Owner-only policies on storage.objects for this bucket
  execute 'drop policy if exists "sc archives owner select" on storage.objects';
  execute 'create policy "sc archives owner select" on storage.objects for select to authenticated using (bucket_id=''archives'' and public.is_owner(auth.uid()))';
  execute 'drop policy if exists "sc archives owner insert" on storage.objects';
  execute 'create policy "sc archives owner insert" on storage.objects for insert to authenticated with check (bucket_id=''archives'' and public.is_owner(auth.uid()))';
  execute 'drop policy if exists "sc archives owner update" on storage.objects';
  execute 'create policy "sc archives owner update" on storage.objects for update to authenticated using (bucket_id=''archives'' and public.is_owner(auth.uid())) with check (bucket_id=''archives'' and public.is_owner(auth.uid()))';
  execute 'drop policy if exists "sc archives owner delete" on storage.objects';
  execute 'create policy "sc archives owner delete" on storage.objects for delete to authenticated using (bucket_id=''archives'' and public.is_owner(auth.uid()))';

  raise notice 'File-storage archive vault ready: private bucket "archives" (owner-only).';
exception when others then
  raise notice 'Archive bucket setup skipped (%). You can create a private bucket named "archives" from Dashboard → Storage instead.', sqlerrm;
end
$offload$;

-- (archive vault installed)


-- =============== GOOGLE DRIVE BACKUP & SYNC SETTINGS (auto-installed) ===============
-- ============================================================
-- GOOGLE DRIVE BACKUP & SYNC SETTINGS (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Stores the school's Google OAuth Client ID and the automatic
-- backup schedule so every admin device shares one configuration.
-- The Client ID is PUBLIC by design (it is not a secret); backups
-- themselves go to the school's own Google Drive via the
-- drive.file scope and never touch Supabase.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this feature.
-- ============================================================
alter table if exists public.school_settings add column if not exists drive_client_id text default '';
alter table if exists public.school_settings add column if not exists drive_sync_enabled boolean not null default false;
alter table if exists public.school_settings add column if not exists drive_sync_days int not null default 7;
alter table if exists public.school_settings add column if not exists drive_folder_id text default '';
alter table if exists public.school_settings add column if not exists drive_last_backup timestamptz;

-- (drive sync settings installed)


-- =============== SECURITY HARDENING SETTINGS (auto-installed) ===============
-- ============================================================
-- SECURITY HARDENING SETTINGS — V6.0 (idempotent, safe to re-run)
-- ------------------------------------------------------------
-- Powers assets/js/security-guard.js:
--   • idle_lock_minutes : auto sign-out after N idle minutes (0 = off)
--   • lockdown_mode     : emergency switch — locks the portal for all
--                         non-admin roles instantly
--   • lockdown_message  : friendly notice shown to locked-out users
-- Managed from the Platform Health Console (health-check.html).
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this feature.
-- ============================================================
alter table if exists public.school_settings add column if not exists idle_lock_minutes int not null default 30;
alter table if exists public.school_settings add column if not exists lockdown_mode boolean not null default false;
alter table if exists public.school_settings add column if not exists lockdown_message text default '';

-- (security hardening installed)


-- =============== V6.3 ROLE-ACCESS & WORKFLOW FIXES (auto-installed) ===============
-- ============================================================
-- V6.3 ROLE-ACCESS & WORKFLOW FIXES (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Fixes reported on the live sites:
--  1. "new row violates row-level security policy for table report_scores"
--     when a teacher saves scores in the subject broadsheet.
--  6. Leave management: staff request; ONLY admin approves/rejects.
--  8. Assessment columns: ONLY admin creates/edits/deletes report-card
--     columns; teachers only enter scores.
-- 10. Affective/Psychomotor/Report-comments: every staff/teacher gets
--     read/write (own rows), admin full control.
-- 11. Substitutions: staff read-only; admin writes.
-- 21. Private "proctor" storage bucket for CBT snapshot monitoring.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this release.
-- ============================================================

-- ---------- 1. report_scores: teachers save scores without RLS rejection ----
-- Root cause: the old insert policy demanded teacher_can_manage_subject_class(),
-- which returns false whenever the subject/class assignment mapping is
-- incomplete (very common in real schools: subjects registered without a
-- teacher, teacher name spelled differently in staff vs subjects, etc.).
-- New contract: any approved staff/teacher may INSERT scores they author
-- (updated_by = themselves). UPDATE/DELETE stay owner-or-admin, with the
-- assignment check as an OR (not a hard gate) so class/subject teachers
-- can still claim legacy unowned rows.
drop policy if exists report_score_scope_insert on public.report_scores;
create policy report_score_scope_insert on public.report_scores
for insert with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid())
);
drop policy if exists report_score_scope_update on public.report_scores;
create policy report_score_scope_update on public.report_scores
for update using (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and (updated_by = auth.uid()
      or (updated_by is null and public.teacher_can_manage_subject_class(auth.uid(),subject,class))))
) with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid())
);
drop policy if exists report_score_scope_delete on public.report_scores;
create policy report_score_scope_delete on public.report_scores
for delete using (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and (updated_by = auth.uid()
      or (updated_by is null and public.teacher_can_manage_subject_class(auth.uid(),subject,class))))
);

-- ---------- 8. assessment_columns: ADMIN-ONLY structure control -------------
alter table public.assessment_columns enable row level security;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='assessment_columns' loop
    execute format('drop policy if exists %I on public.assessment_columns', p.policyname);
  end loop;
end $$;
create policy ac_read_all on public.assessment_columns
for select using (auth.role() = 'authenticated');
create policy ac_admin_write on public.assessment_columns
for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- 6. leave_requests: staff request, ONLY admin approves -----------
alter table public.leave_requests add column if not exists requested_by uuid references public.profiles(id) on delete set null;
alter table public.leave_requests add column if not exists decided_by uuid references public.profiles(id) on delete set null;
alter table public.leave_requests add column if not exists decided_at timestamptz;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='leave_requests' loop
    execute format('drop policy if exists %I on public.leave_requests', p.policyname);
  end loop;
end $$;
-- Staff see their own requests; admins see all.
create policy lr_read on public.leave_requests
for select using (
  public.is_admin(auth.uid())
  or requested_by = auth.uid()
  or staff_id in (select id from public.staff where user_id = auth.uid())
);
-- Staff submit ONLY pending requests, stamped as their own.
create policy lr_insert on public.leave_requests
for insert with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid())
      and coalesce(requested_by, auth.uid()) = auth.uid()
      and coalesce(status,'pending') = 'pending')
);
-- Staff may edit their OWN request only while it is still pending —
-- and can never flip the status themselves. Admin has full control.
create policy lr_update_own_pending on public.leave_requests
for update using (
  requested_by = auth.uid() and status = 'pending' and not public.is_admin(auth.uid())
) with check (
  requested_by = auth.uid() and status = 'pending'
);
create policy lr_admin_all on public.leave_requests
for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
-- Approval stamp: whenever status changes, record who decided and when.
create or replace function public.lr_stamp_decision()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status is distinct from old.status and new.status in ('approved','rejected') then
    if not public.is_admin(auth.uid()) then
      raise exception 'Only an administrator can approve or reject leave requests.';
    end if;
    new.decided_by := auth.uid(); new.decided_at := now();
  end if;
  return new;
end $$;
drop trigger if exists trg_lr_stamp on public.leave_requests;
create trigger trg_lr_stamp before update on public.leave_requests
for each row execute function public.lr_stamp_decision();

-- ---------- 10. traits & comments: every staff/teacher can read/write -------
-- (own rows; admin overrides). The old policy hard-required the
-- teacher↔student assignment mapping, silently locking out legitimate staff.
drop policy if exists affective_scope_write on public.affective_traits;
create policy affective_scope_write on public.affective_traits
for all using (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and (teacher_id = auth.uid() or teacher_id is null))
) with check (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and coalesce(teacher_id, auth.uid()) = auth.uid())
);
drop policy if exists psychomotor_scope_write on public.psychomotor_traits;
create policy psychomotor_scope_write on public.psychomotor_traits
for all using (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and (teacher_id = auth.uid() or teacher_id is null))
) with check (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and coalesce(teacher_id, auth.uid()) = auth.uid())
);
drop policy if exists comments_scope_write on public.report_comments;
create policy comments_scope_write on public.report_comments
for all using (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and (teacher_id = auth.uid() or teacher_id is null))
) with check (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and coalesce(teacher_id, auth.uid()) = auth.uid())
);

-- ---------- 11. substitutions: staff READ, admin WRITE ----------------------
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='substitutions' loop
    execute format('drop policy if exists %I on public.substitutions', p.policyname);
  end loop;
end $$;
create policy subs_staff_read on public.substitutions
for select using (public.is_staff(auth.uid()));
create policy subs_admin_write on public.substitutions
for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- 9/17. fee_payments: re-assert the family-safe contract ----------
-- Students see ONLY their own payments; parents only their children's;
-- bursar (inside is_staff/is_admin) keeps full read/write.
drop policy if exists "fp_read" on fee_payments;
create policy "fp_read" on public.fee_payments for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "fp_write" on fee_payments;
create policy "fp_write" on public.fee_payments for all
using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------- 21. CBT proctoring media bucket (snapshots → File Storage) ------
do $proctor$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema not present (local test database) — proctor bucket skipped.';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('proctor', 'proctor', false, 512000, array['image/jpeg','image/webp'])
  on conflict (id) do nothing;
  -- Students (any authenticated exam-taker) may UPLOAD snapshots only;
  -- they can never list, view or delete them. Staff/teachers review and
  -- delete; admins keep full control.
  execute 'drop policy if exists "sc proctor upload" on storage.objects';
  execute 'create policy "sc proctor upload" on storage.objects for insert to authenticated with check (bucket_id=''proctor'')';
  execute 'drop policy if exists "sc proctor staff read" on storage.objects';
  execute 'create policy "sc proctor staff read" on storage.objects for select to authenticated using (bucket_id=''proctor'' and public.is_staff(auth.uid()))';
  execute 'drop policy if exists "sc proctor staff delete" on storage.objects';
  execute 'create policy "sc proctor staff delete" on storage.objects for delete to authenticated using (bucket_id=''proctor'' and public.is_staff(auth.uid()))';
  raise notice 'CBT proctoring bucket ready: private "proctor" (student upload-only, staff review/delete).';
exception when others then
  raise notice 'Proctor bucket setup skipped (%). Create a private bucket named "proctor" from Dashboard -> Storage instead.', sqlerrm;
end
$proctor$;

notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
-- (v6.3 role-access fixes installed)


-- =============== V6.4 HARD-SCOPE FIXES (auto-installed) ===============
-- ============================================================
-- V6.4 HARD-SCOPE FIXES (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- 4. fee_payments: drop EVERY policy (including legacy permissive
--    ones from old installs) and re-create exactly two:
--    family-scoped read + staff write. Guarantees a student can
--    NEVER read another student's payments at database level.
-- 2. Punctuality → report card: new RPC that writes the summed
--    points into REPORT_SCORES against an ADMIN-CREATED assessment
--    column (column_id), so the push uses the school's own report
--    template — never a hard-coded ca1/ca2 list.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this release.
-- ============================================================

-- ---------- 4. fee_payments total policy reset ----------
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='fee_payments' loop
    execute format('drop policy if exists %I on public.fee_payments', p.policyname);
  end loop;
end $$;
create policy "fp_read" on public.fee_payments for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
create policy "fp_write" on public.fee_payments for all
using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- Same total reset for payment_intents (online payment references).
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='payment_intents' loop
    execute format('drop policy if exists %I on public.payment_intents', p.policyname);
  end loop;
end $$;
create policy "pi_read" on public.payment_intents for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
create policy "pi_write" on public.payment_intents for all
using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------- 2. punctuality → ADMIN-CREATED report column ----------
-- Sums each student's punctuality points in the window and UPSERTS them into
-- report_scores under the admin-created assessment column (p_column_id).
-- Re-pushing the same scope updates the same rows (report_scores_uq).
create or replace function public.sc_push_punctuality_to_report(
  p_column_id uuid, p_term text, p_session text,
  p_class text default '', p_start date default null, p_end date default null,
  p_subject text default 'PUNCTUALITY')
returns int language plpgsql security definer set search_path=public as $$
declare saved int := 0; r record; colrec record;
begin
  if not public.is_staff(auth.uid()) then
    raise exception 'Staff/admin role required.';
  end if;
  select id, name, max_mark into colrec from public.assessment_columns where id = p_column_id;
  if not found then
    raise exception 'That report-card column no longer exists. Ask the admin to create columns on the Report Cards page first.';
  end if;
  for r in
    select a.student_id,
           max(a.student_name) as student_name, max(coalesce(a.student_id_ref,'')) as student_id_ref,
           coalesce(nullif(p_class,''), max(a.class)) as class,
           sum(a.points) as points
      from public.punctuality_awards a
      join public.students s on s.id = a.student_id
     where (p_class = '' or a.class = p_class or s.class = p_class)
       and (p_start is null or a.date >= p_start)
       and (p_end   is null or a.date <= p_end)
     group by a.student_id
  loop
    insert into public.report_scores
      (column_id, student_id, student_id_ref, student_name, class, subject, term, session, score, source, updated_by, updated_at)
    values
      (p_column_id, r.student_id, r.student_id_ref, coalesce(r.student_name,'Student'),
       coalesce(r.class,''), p_subject, coalesce(p_term,''), coalesce(p_session,''),
       r.points, 'punctuality', auth.uid(), now())
    on conflict (column_id, student_id_ref, student_name, class, subject, term, session)
    do update set score = excluded.score, updated_by = excluded.updated_by, updated_at = now(), source = 'punctuality';
    saved := saved + 1;
  end loop;
  return saved;
end $$;
revoke execute on function public.sc_push_punctuality_to_report(uuid,text,text,text,date,date,text) from public, anon;
grant  execute on function public.sc_push_punctuality_to_report(uuid,text,text,text,date,date,text) to authenticated;

notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
-- (v6.4 hard-scope fixes installed)


-- =============== BRANDING BUCKET (auto-installed) ===============
-- ============================================================
-- BRANDING BUCKET — signatures, stamps & logos in File Storage
-- (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Tiny branding images (drawn signatures ~5–20 KB, stamps, logos)
-- now live in the SEPARATE 1 GB File Storage — not the 500 MB
-- database and no Google Drive round-trip needed. The bucket is
-- PUBLIC-READ (report cards and e-receipts embed the images by
-- URL when printing) but only admin-tier roles can upload,
-- replace or delete files. 200 KB per-file cap keeps it light.
-- This file is ALREADY embedded inside complete-schema.sql; run
-- it standalone only on databases installed before this release.
-- ============================================================
do $branding$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema not present (local test database) — branding bucket skipped.';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('branding', 'branding', true, 204800, array['image/png','image/jpeg','image/webp','image/svg+xml'])
  on conflict (id) do nothing;
  execute 'drop policy if exists "sc branding public read" on storage.objects';
  execute 'create policy "sc branding public read" on storage.objects for select using (bucket_id=''branding'')';
  execute 'drop policy if exists "sc branding admin write" on storage.objects';
  execute 'create policy "sc branding admin write" on storage.objects for insert to authenticated with check (bucket_id=''branding'' and public.is_admin(auth.uid()))';
  execute 'drop policy if exists "sc branding admin update" on storage.objects';
  execute 'create policy "sc branding admin update" on storage.objects for update to authenticated using (bucket_id=''branding'' and public.is_admin(auth.uid())) with check (bucket_id=''branding'' and public.is_admin(auth.uid()))';
  execute 'drop policy if exists "sc branding admin delete" on storage.objects';
  execute 'create policy "sc branding admin delete" on storage.objects for delete to authenticated using (bucket_id=''branding'' and public.is_admin(auth.uid()))';
  raise notice 'Branding bucket ready: public-read "branding" (admin-only writes, 200KB cap).';
exception when others then
  raise notice 'Branding bucket setup skipped (%). Create a public bucket named "branding" from Dashboard -> Storage instead.', sqlerrm;
end
$branding$;
-- (branding bucket installed)


-- =============== V6.9 BULLETPROOF SCORE SAVING (auto-installed, must stay LAST) ===============
-- ============================================================
-- V6.9 — BULLETPROOF SCORE SAVING (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Fixes the persistent "new row violates row-level security policy
-- for table report_scores" seen by teachers on the subject broadsheet.
--
-- WHY IT KEPT FAILING (expert diagnosis):
--  1. The page uses UPSERT. Under Postgres RLS an upsert must pass
--     THREE policies at once (SELECT on the conflicting row, then
--     INSERT's WITH CHECK or UPDATE's USING+WITH CHECK). The old
--     SELECT policy still hard-required teacher_can_manage_subject_class(),
--     so a teacher whose subject↔teacher mapping is imperfect could not
--     even "see" the conflicting row — the upsert then exploded with the
--     generic RLS message no matter what the INSERT policy said.
--  2. SQL-file ordering traps: running an older complete-schema.sql AFTER
--     v6.3-role-access-fixes.sql silently re-installed the restrictive
--     policies. Any run order left some installs broken.
--
-- THE FIX — remove the fragility class entirely:
--  A. A SECURITY-DEFINER RPC (sc_save_report_score) now performs the save
--     server-side. RLS/upsert mechanics can no longer produce the error;
--     the permission contract is enforced INSIDE the function:
--       • caller must be approved staff/teacher/admin;
--       • a row already entered by ANOTHER teacher is locked (skipped with
--         a clear per-row message) unless the caller is admin-tier;
--       • updated_by is stamped server-side from auth.uid() — a slow
--         profile load can never send updated_by=null again.
--  B. The SELECT policy is relaxed so every approved staff member can READ
--     report scores (teachers must see class broadsheets anyway); students/
--     parents still only see their own rows.
--  C. The v6.3 write policies are re-asserted LAST so they win regardless
--     of which files were run in which order.
-- This file is ALREADY embedded inside complete-schema.sql (at the end, so
-- it always wins). Run it standalone on any database installed earlier.
-- ============================================================

-- ---------- B. staff-wide read (family rows stay scoped) ----------
drop policy if exists report_score_scope_select on public.report_scores;
create policy report_score_scope_select on public.report_scores
for select using (
  public.is_staff(auth.uid())
  or exists (select 1 from public.students s
              where (s.id = report_scores.student_id or s.admission_no = report_scores.student_id_ref)
                and (s.user_id = auth.uid() or public.is_parent_of(auth.uid(), s.id)))
);

-- ---------- C. re-assert the v6.3 write contract (order-proof) ----------
drop policy if exists report_score_scope_insert on public.report_scores;
create policy report_score_scope_insert on public.report_scores
for insert with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid())
);
drop policy if exists report_score_scope_update on public.report_scores;
create policy report_score_scope_update on public.report_scores
for update using (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and (updated_by = auth.uid() or updated_by is null))
) with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid())
);
drop policy if exists report_score_scope_delete on public.report_scores;
create policy report_score_scope_delete on public.report_scores
for delete using (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and (updated_by = auth.uid() or updated_by is null))
);

-- ---------- A. the bulletproof save RPC ----------
create or replace function public.sc_save_report_score(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r jsonb; saved int := 0; blocked int := 0; errs text[] := '{}';
  existing public.report_scores%rowtype; uid uuid := auth.uid();
begin
  if uid is null or not public.is_staff(uid) then
    return jsonb_build_object('ok', false, 'error',
      'Staff/admin role required. If you just signed up, an admin must approve your account first (Approvals page).');
  end if;
  for r in select * from jsonb_array_elements(
             case when jsonb_typeof(p_rows) = 'array' then p_rows else jsonb_build_array(p_rows) end)
  loop
    begin
      if coalesce(r->>'column_id','') = '' then
        blocked := blocked + 1; errs := array_append(errs, 'row without column_id skipped'); continue;
      end if;
      select * into existing from public.report_scores
       where column_id = (r->>'column_id')::uuid
         and student_id_ref = coalesce(r->>'student_id_ref','')
         and student_name   = coalesce(r->>'student_name','')
         and class          = coalesce(r->>'class','')
         and subject        = coalesce(r->>'subject','')
         and term           = coalesce(r->>'term','')
         and session        = coalesce(r->>'session','')
       limit 1;
      if found and not public.is_admin(uid)
         and existing.updated_by is not null and existing.updated_by <> uid then
        blocked := blocked + 1;
        errs := array_append(errs, coalesce(nullif(r->>'student_name',''),'A row')
          || ' — locked: this score was entered by another teacher. Ask an administrator to change it.');
        continue;
      end if;
      insert into public.report_scores
        (column_id, student_id, student_id_ref, student_name, class, subject, term, session,
         score, source, updated_by, updated_at)
      values
        ((r->>'column_id')::uuid,
         nullif(r->>'student_id','')::uuid,
         coalesce(r->>'student_id_ref',''), coalesce(r->>'student_name',''),
         coalesce(r->>'class',''), coalesce(r->>'subject',''),
         coalesce(r->>'term',''), coalesce(r->>'session',''),
         coalesce((r->>'score')::numeric, 0), coalesce(nullif(r->>'source',''),'manual'),
         uid, now())
      on conflict (column_id, student_id_ref, student_name, class, subject, term, session)
      do update set score = excluded.score, updated_by = uid, updated_at = now(),
                    source = excluded.source,
                    student_id = coalesce(excluded.student_id, report_scores.student_id);
      saved := saved + 1;
    exception when others then
      blocked := blocked + 1; errs := array_append(errs, sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'saved', saved, 'blocked', blocked, 'errors', to_jsonb(errs));
end $$;
revoke execute on function public.sc_save_report_score(jsonb) from public, anon;
grant  execute on function public.sc_save_report_score(jsonb) to authenticated;

notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
-- (v6.9 score saving installed)


-- =============== V7.0 CLEAN DATA LIFECYCLE (auto-installed) ===============
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
-- (v7.0 lifecycle installed)


-- =============== V7.3 MISSING POLICIES + PROMOTION FINALISER (auto-installed) ===============
-- ============================================================
-- V7.3 — MISSING POLICIES + PROMOTION FINALISER (idempotent)
-- ------------------------------------------------------------
-- Root-cause fixes:
--  A. admission_links & staff_bonus had RLS ENABLED but NO policies
--     → default deny for everyone (even admins). This is why those
--     pages stayed empty and every sample-data loader silently
--     failed on them. Proper policies installed.
--  B. sc_finalise_promotions(): server-side "Apply promotions" —
--     moves students by id, stamps status='applied' + the current
--     period, and marks graduates; returns per-action counts. The
--     page keeps its preview and calls this one RPC (fallback to
--     the old loop when the RPC is missing).
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this release.
-- ============================================================

-- ---------- A. admission_links ----------
drop policy if exists adl_read on public.admission_links;
create policy adl_read on public.admission_links for select using (true); -- tokens are public application URLs
drop policy if exists adl_admin_write on public.admission_links;
create policy adl_admin_write on public.admission_links for all
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- A2. staff_bonus ----------
drop policy if exists sbn_staff_read on public.staff_bonus;
create policy sbn_staff_read on public.staff_bonus for select using (public.is_staff(auth.uid()));
drop policy if exists sbn_admin_write on public.staff_bonus;
create policy sbn_admin_write on public.staff_bonus for all
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- B. one-call promotion finaliser ----------
-- (sc_finalise_promotions is defined ONCE in the embedded v7.6 pack below —
--  graduate-to-alumni pipeline included; the older body was removed so the
--  schema keeps one authoritative definition per function.)


notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
-- (v7.3 installed)


-- ============================================================================
-- EMBEDDED: database/v7.5-rls-gap-and-self-service.sql (last wins)
-- ============================================================================
-- ============================================================================
-- School Connect V7.5 — RLS gap closure + staff self-service reads
-- ============================================================================
-- ROOT CAUSE (same family as the v7.3 admission_links fix, found by a live
-- REST audit of every table): these tables had ROW LEVEL SECURITY *enabled*
-- but ZERO policies, which in PostgreSQL means DEFAULT-DENY FOR EVERYONE —
-- including the admin. Confirmed live symptoms:
--   • staff_loans / staff_appraisals  → admin INSERT returns 403 (pages unusable)
--   • certificate_designs             → designs never save; page always empty
--   • timetable_config                → period/break structure can't be stored
--   • cbt_roster                      → entrance-exam rosters unreadable
--   • admission_letters               → generated letters invisible
--   • sc_install_state                → install bookkeeping unreadable to admin
--   • sc_heartbeat                    → "permission denied" on the Platform
--                                        Health heartbeat tile (missing GRANT)
-- PLUS one enterprise self-service gap: ordinary staff could not see even
-- their OWN payslips, loans or appraisals (admin-only policies). HR pages
-- looked "empty / no sample data" to every non-admin guest in the demo.
--
-- Idempotent: safe to run any number of times, on any School Connect database.
-- ============================================================================

-- ---------- helper-safe grants (RLS still filters rows) ---------------------
grant select on public.sc_heartbeat to authenticated;
grant select on public.sc_heartbeat to anon;

-- ---------- sc_heartbeat: world-readable single status row ------------------
alter table public.sc_heartbeat enable row level security;
drop policy if exists "hb_read" on sc_heartbeat;
create policy "hb_read" on public.sc_heartbeat for select using (true);
-- writes stay exclusively inside the SECURITY DEFINER RPC sc_keep_alive().

-- ---------- sc_install_state: admin visibility only --------------------------
alter table public.sc_install_state enable row level security;
drop policy if exists "sis_admin_read" on sc_install_state;
create policy "sis_admin_read" on public.sc_install_state
  for select using (public.is_admin(auth.uid()));

-- ---------- certificate_designs: everyone reads, admin manages ---------------
alter table public.certificate_designs enable row level security;
drop policy if exists "cd_read" on certificate_designs;
create policy "cd_read" on public.certificate_designs
  for select using (auth.role() = 'authenticated');
drop policy if exists "cd_admin_write" on certificate_designs;
create policy "cd_admin_write" on public.certificate_designs
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- timetable_config: everyone reads the bell schedule, admin edits --
alter table public.timetable_config enable row level security;
drop policy if exists "tc_read" on timetable_config;
create policy "tc_read" on public.timetable_config
  for select using (auth.role() = 'authenticated');
drop policy if exists "tc_admin_write" on timetable_config;
create policy "tc_admin_write" on public.timetable_config
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- cbt_roster: candidates check themselves in, staff manage ---------
alter table public.cbt_roster enable row level security;
drop policy if exists "cr_read" on cbt_roster;
create policy "cr_read" on public.cbt_roster for select using (true);
drop policy if exists "cr_staff_write" on cbt_roster;
create policy "cr_staff_write" on public.cbt_roster
  for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------- admission_letters: public verification read, admin manages -------
alter table public.admission_letters enable row level security;
drop policy if exists "al_read" on admission_letters;
create policy "al_read" on public.admission_letters for select using (true);
drop policy if exists "al_admin_write" on admission_letters;
create policy "al_admin_write" on public.admission_letters
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- staff_loans: admin manages, staff read their own -----------------
alter table public.staff_loans enable row level security;
drop policy if exists "sl_admin_all" on staff_loans;
create policy "sl_admin_all" on public.staff_loans
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "sl_self_read" on staff_loans;
create policy "sl_self_read" on public.staff_loans
  for select using (exists (
    select 1 from public.staff s
    where s.user_id = auth.uid()
      and lower(s.full_name) = lower(staff_loans.staff_name)));

-- ---------- staff_appraisals: admin manages, staff read their own ------------
alter table public.staff_appraisals enable row level security;
drop policy if exists "sa_admin_all" on staff_appraisals;
create policy "sa_admin_all" on public.staff_appraisals
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "sa_self_read" on staff_appraisals;
create policy "sa_self_read" on public.staff_appraisals
  for select using (exists (
    select 1 from public.staff s
    where s.user_id = auth.uid()
      and lower(s.full_name) = lower(staff_appraisals.staff_name)));

-- ---------- payroll: staff can read (only) their OWN payslips ----------------
-- Admin keeps full read/write via the existing pay_all policy; this ADDS a
-- narrow self-read so a teacher's payslip page is no longer blank.
drop policy if exists "pay_self_read" on payroll;
create policy "pay_self_read" on public.payroll
  for select using (exists (
    select 1 from public.staff s
    where s.user_id = auth.uid()
      and (s.id = payroll.staff_id or lower(s.full_name) = lower(coalesce(payroll.staff_name,''))))); 

select 'V7.5 RLS gap closure + staff self-service installed' as status;


-- ============================================================================
-- EMBEDDED: database/v7.6-history-and-alumni.sql (last wins)
-- ============================================================================
-- ============================================================================
-- School Connect V7.6 — Term-History Access + Graduate→Alumni pipeline
-- ============================================================================
-- Issue (educator workflow): in a NEW term the admin could no longer regenerate
-- PREVIOUS terms' records. The client-side root cause (report-engine roster
-- gate matching only the CURRENT class roster, so promoted/graduated students'
-- old scores vanished) is fixed in assets/js/report-engine.js + report-cards.
-- This pack adds the database side:
--   1. History indexes — term/session/class lookups on the four "history"
--      tables stay fast as years of data accumulate (free-tier friendly).
--   2. Graduate→Alumni pipeline — "Apply promotions" now files every
--      graduating student into the Alumni register automatically (name,
--      last class, graduation year from the session), so records survive
--      even after the student later leaves the active register.
-- Idempotent: safe to run repeatedly on any School Connect database.
-- ============================================================================

-- ---------- 1. history indexes ----------------------------------------------
create index if not exists idx_results_hist       on public.results       (session, term, class);
create index if not exists idx_report_scores_hist on public.report_scores (session, term, class);
create index if not exists idx_fee_payments_hist  on public.fee_payments  (session, term);
create index if not exists idx_attendance_hist    on public.attendance    (class, date);
create index if not exists idx_promotions_hist    on public.promotions    (session, term, status);

-- ---------- 2. finalise promotions: graduates flow into alumni ---------------
create or replace function public.sc_finalise_promotions()
returns jsonb language plpgsql security definer set search_path=public as $$
declare r record; moved int:=0; grads int:=0; repeats int:=0; failed int:=0;
        cur_term text:=''; cur_session text:=''; grad_year int; s record;
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admin role required.'; end if;
  select term, session into cur_term, cur_session from public.academic_periods where is_current = true limit 1;
  -- graduation year = second half of the session ("2025/2026" -> 2026); fallback: this year
  grad_year := coalesce(nullif(split_part(coalesce(cur_session,''), '/', 2), '')::int,
                        extract(year from now())::int);
  for r in select * from public.promotions where status in ('draft','approved')
             and lower(coalesce(action,'')) in ('promote','graduate','repeat')
  loop
    begin
      if r.action = 'promote' then
        if r.student_id is not null then
          update public.students set class = r.to_class where id = r.student_id;
        else
          update public.students set class = r.to_class where lower(full_name) = lower(r.student_name);
        end if;
        if not found then failed := failed + 1; continue; end if;
        moved := moved + 1;
      elsif r.action = 'graduate' then
        if r.student_id is not null then
          select id, full_name, class into s from public.students where id = r.student_id;
          update public.students set status = 'graduated' where id = r.student_id;
        else
          select id, full_name, class into s from public.students where lower(full_name) = lower(r.student_name) limit 1;
          update public.students set status = 'graduated' where lower(full_name) = lower(r.student_name);
        end if;
        if not found then failed := failed + 1; continue; end if;
        grads := grads + 1;
        -- V7.6: automatic Alumni record (skip when an equivalent row exists)
        if s.full_name is not null and not exists (
             select 1 from public.alumni a
              where lower(a.full_name) = lower(s.full_name)
                and coalesce(a.graduation_year,0) = grad_year) then
          insert into public.alumni (full_name, graduation_year, last_class, current_occupation)
          values (s.full_name, grad_year, coalesce(s.class, r.from_class), '');
        end if;
      else
        repeats := repeats + 1;
      end if;
      update public.promotions
         set status = 'applied',
             term    = coalesce(nullif(term,''), cur_term, ''),
             session = coalesce(nullif(session,''), cur_session, '')
       where id = r.id;
    exception when others then failed := failed + 1;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'promoted', moved, 'graduated', grads,
                            'repeated', repeats, 'failed', failed,
                            'term', cur_term, 'session', cur_session,
                            'alumni_year', grad_year);
end$$;
revoke execute on function public.sc_finalise_promotions() from public, anon;
grant execute on function public.sc_finalise_promotions() to authenticated;

select 'V7.6 history indexes + graduate-to-alumni pipeline installed' as status;


-- ============================================================================
-- EMBEDDED: database/v7.7-promotion-department.sql (last wins)
-- ============================================================================
-- ============================================================================
-- School Connect V7.7 — Promotion department + outputs history support
-- ============================================================================
-- 1. promotions.department — lets the admin filter/report promotion decisions
--    by department (Science/Arts/Commercial…), auto-filled from the student.
-- 2. Backfill: existing promotion rows inherit their student's department.
-- Idempotent — safe to run repeatedly.
-- ============================================================================
alter table public.promotions add column if not exists department text default '';
update public.promotions p
   set department = coalesce(s.department,'')
  from public.students s
 where (p.student_id = s.id or lower(p.student_name) = lower(s.full_name))
   and coalesce(p.department,'') = '';
create index if not exists idx_promotions_dept on public.promotions (department);
select 'V7.7 promotion department installed' as status;


-- ============================================================================
-- EMBEDDED: database/v7.9-timetable-flex-and-class-scope.sql (last wins)
-- ============================================================================
-- ============================================================================
-- School Connect V7.9 — Flexible Timetable Engine + Assignment Class-Scope Reset
-- ============================================================================
-- PART 1 — TIMETABLE FLEXIBILITY (educator requirements):
--   • PERIOD-LEVEL part-time availability: a part-timer can be "Monday periods
--     1–3 and Thursday periods 4–6", not just "Monday and Thursday".
--   • BLOCKED SLOTS: free periods / clubs / games / assembly per class (or ALL
--     classes) on chosen day+period. The generator writes them into the grid
--     (e.g. "⛔ Sports & Clubs") and never schedules over them.
--   • PER-DAY PERIOD COUNTS: Friday (or any day) can have fewer periods than
--     Monday–Thursday via the new p_day_periods parameter, e.g. {"Friday":4}.
--   • Cross-class teacher conflicts remain checked (a teacher is never in two
--     classes at the same time, across every generated class).
-- PART 2 — ASSIGNMENT CLASS-SCOPE HARD RESET:
--   Old installs may still carry the permissive "read_assignments …
--   authenticated" policy from early schema versions, which let students see
--   other classes' homework. This pack force-drops EVERY select policy on
--   assignments and installs the single scoped contract (idempotent).
-- Idempotent: safe to run repeatedly on any School Connect database.
-- ============================================================================

-- ---------- 1a. schema additions ---------------------------------------------
alter table public.teacher_availability   add column if not exists available_periods jsonb;
alter table public.timetable_requirements add column if not exists available_periods jsonb;
comment on column public.timetable_requirements.available_periods is
  'Period-level availability, e.g. {"Monday":[1,2,3],"Thursday":[4,5,6]}. When set, its KEYS are the allowed days and the arrays the allowed periods. Null = use available_days / any period.';

create table if not exists public.timetable_blocks (
  id uuid primary key default gen_random_uuid(),
  class text not null default 'ALL',            -- 'ALL' or an exact class name
  day text not null,
  period int not null,
  label text default 'Free period',              -- e.g. Sports & Clubs, Assembly
  created_at timestamptz default now(),
  unique(class, day, period)
);
alter table public.timetable_blocks enable row level security;
drop policy if exists tb_read on timetable_blocks;
create policy tb_read on public.timetable_blocks
  for select using (auth.role() = 'authenticated');
drop policy if exists tb_staff_write on timetable_blocks;
create policy tb_staff_write on public.timetable_blocks
  for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------- 1b. the upgraded generator ---------------------------------------
-- (function body lives ONCE in Section 5 above — the schema keeps a single
--  authoritative definition per function; the standalone v7.9 file carries it
--  for existing databases.)

-- ---------- 2. assignments class-scope HARD RESET -----------------------------
-- Drop every historic SELECT policy (any name), then install the single scoped
-- contract: admins & subject/class teachers see all they manage; students and
-- parents see ONLY their own class's assignments.
do $$ declare p record; begin
  for p in select policyname from pg_policies
            where schemaname='public' and tablename='assignments' and cmd='SELECT' loop
    execute format('drop policy if exists %I on public.assignments', p.policyname);
  end loop;
end $$;
create policy assignments_scope_select on public.assignments for select using(
  public.is_admin(auth.uid())
  or public.teacher_can_manage_subject_class(auth.uid(),subject,class)
  or exists(select 1 from public.students s
             where (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))
               and lower(regexp_replace(coalesce(s.class,''),'\s+','','g'))
                 = lower(regexp_replace(coalesce(assignments.class,''),'\s+','','g')))
);

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V7.9 flexible timetable + assignment class-scope installed' as status;

select 'School Connect V5.8 complete cumulative schema installed successfully ✅ — no other production SQL is required'as status;
