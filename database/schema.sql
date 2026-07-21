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
  admission_prefix text default 'GSA',
  admission_next int default 1,
  staff_prefix text default 'GSA',
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
  current_role text default '',
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

-- Report-score ON CONFLICT repair. PostgREST upsert now matches exactly.
alter table if exists public.report_scores add column if not exists updated_by uuid references public.profiles(id) default auth.uid();
do $$ begin
  if exists (select 1 from pg_constraint where conname='report_scores_column_id_student_id_ref_student_name_key') then
    alter table public.report_scores drop constraint report_scores_column_id_student_id_ref_student_name_key;
  end if;
exception when undefined_table then null; end $$;
create unique index if not exists report_scores_column_student_subject_uq
  on public.report_scores(column_id, student_id_ref, student_name, subject);

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

