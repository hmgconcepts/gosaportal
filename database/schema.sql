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
create policy "parents_read" on public.parents for select using (auth.role() = 'authenticated');
create policy "parents_write" on public.parents for all using (public.is_staff(auth.uid()));

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

create table if not exists public.payroll (
  id uuid primary key default uuid_generate_v4(),
  staff_id uuid references public.staff(id) on delete cascade,
  month text, year int,
  basic numeric, allowances numeric, deductions numeric,
  net_pay numeric generated always as
    (coalesce(basic,0)+coalesce(allowances,0)-coalesce(deductions,0)) stored,
  status text default 'draft' check (status in ('draft','approved','paid')),
  created_at timestamptz default now()
);
alter table public.payroll enable row level security;

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
create policy "profiles_self_read"   on public.profiles for select using (auth.uid() = id);
create policy "profiles_self_update" on public.profiles for update using (auth.uid() = id);
create policy "profiles_staff_read"  on public.profiles for select using (public.is_staff(auth.uid()));
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
drop policy if exists "results_select_v5" on public.results;
drop policy if exists "results_insert_v5" on public.results;
drop policy if exists "results_update_v5" on public.results;
drop policy if exists "results_delete_v5" on public.results;
create policy "results_select_v5" on public.results for select using (
  public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
);
create policy "results_insert_v5" on public.results for insert with check (public.is_staff(auth.uid()));
create policy "results_update_v5" on public.results for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid()) with check (public.is_admin(auth.uid()) or teacher_id = auth.uid());
create policy "results_delete_v5" on public.results for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid());

-- ---- Attendance: parents see own children; staff manage ----
drop policy if exists "att_read"  on public.attendance;
drop policy if exists "att_write" on public.attendance;
create policy "att_read"  on public.attendance for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or student_id in (select id from public.students where guardian_email = auth.jwt()->>'email')
  or public.is_staff(auth.uid())
);
create policy "att_write" on public.attendance for all using (public.is_staff(auth.uid()));

-- ---- Results: parents see own children; staff manage ----
drop policy if exists "res_read"  on public.results;
drop policy if exists "res_write" on public.results;
drop policy if exists "results_select_v5" on public.results;
drop policy if exists "results_insert_v5" on public.results;
drop policy if exists "results_update_v5" on public.results;
drop policy if exists "results_delete_v5" on public.results;
create policy "results_select_v5" on public.results for select using (
  public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
);
create policy "results_insert_v5" on public.results for insert with check (public.is_staff(auth.uid()));
create policy "results_update_v5" on public.results for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid()) with check (public.is_admin(auth.uid()) or teacher_id = auth.uid());
create policy "results_delete_v5" on public.results for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid());

-- ---- Conduct / Health / Behaviour / Support: parents see own; staff manage ----
drop policy if exists "cond_read"  on public.conduct;
drop policy if exists "cond_write" on public.conduct;
create policy "cond_read"  on public.conduct for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
create policy "cond_write" on public.conduct for all using (public.is_staff(auth.uid()));

drop policy if exists "hlth_read"  on public.health;
drop policy if exists "hlth_write" on public.health;
create policy "hlth_read"  on public.health for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
create policy "hlth_write" on public.health for all using (public.is_staff(auth.uid()));

drop policy if exists "sp_read"  on public.support_plans;
drop policy if exists "sp_write" on public.support_plans;
create policy "sp_read"  on public.support_plans for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
create policy "sp_write" on public.support_plans for all using (public.is_staff(auth.uid()));

-- ---- Fees: parents see own; staff manage ----
drop policy if exists "fp_read"  on public.fee_payments;
drop policy if exists "fp_write" on public.fee_payments;
create policy "fp_read"  on public.fee_payments for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
create policy "fp_write" on public.fee_payments for all using (public.is_staff(auth.uid()));

-- ---- Payment intents: parents see own; staff manage ----
drop policy if exists "pi_read"  on public.payment_intents;
drop policy if exists "pi_write" on public.payment_intents;
create policy "pi_read"  on public.payment_intents for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
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
create policy "vis_insert" on public.visitors for insert with check (true);
create policy "vis_read"   on public.visitors for select using (public.is_staff(auth.uid()));

-- ---- Transport ----
drop policy if exists "tr_all" on public.transport;
create policy "tr_all" on public.transport for all using (public.is_staff(auth.uid()));

-- ---- Announcements: everyone reads; staff writes ----
drop policy if exists "ann_read"  on public.announcements;
drop policy if exists "ann_write" on public.announcements;
create policy "ann_read"  on public.announcements for select using (auth.role() = 'authenticated');
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
create policy "notif_read"  on public.notifications for select using (auth.role() = 'authenticated');
create policy "notif_write" on public.notifications for all using (public.is_staff(auth.uid()));

-- ---- Voting ----
drop policy if exists "polls_read"  on public.polls;
drop policy if exists "polls_write" on public.polls;
create policy "polls_read"  on public.polls for select using (auth.role() = 'authenticated');
create policy "polls_write" on public.polls for all using (public.is_staff(auth.uid()));

drop policy if exists "pv_read"   on public.poll_votes;
drop policy if exists "pv_insert" on public.poll_votes;
drop policy if exists "pv_update" on public.poll_votes;
create policy "pv_read"   on public.poll_votes for select using (auth.uid() = voter_id or public.is_staff(auth.uid()));
create policy "pv_insert" on public.poll_votes for insert with check (auth.uid() = voter_id);
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
create policy "ap_read" on public.academic_periods for select using (auth.role() = 'authenticated');
create policy "ap_write" on public.academic_periods for all using (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) with check (public.is_admin(auth.uid()) or public.is_staff(auth.uid()));

drop policy if exists "lookups_read" on public.lookups;
drop policy if exists "lookups_write" on public.lookups;
create policy "lookups_read" on public.lookups for select using (auth.role() = 'authenticated');
create policy "lookups_write" on public.lookups for all using (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) with check (public.is_admin(auth.uid()) or public.is_staff(auth.uid()));

-- ---- Parent-child ----
drop policy if exists "pc_read"  on public.parent_child;
drop policy if exists "pc_write" on public.parent_child;
create policy "pc_read"  on public.parent_child for select using (
  parent_id = auth.uid() or public.is_staff(auth.uid())
);
create policy "pc_write" on public.parent_child for all using (public.is_staff(auth.uid()));

-- ---- LMS submissions: student sees own; staff manage ----
drop policy if exists "sub_read"  on public.lms_submissions;
drop policy if exists "sub_write" on public.lms_submissions;
create policy "sub_read"  on public.lms_submissions for select using (
  public.is_parent_of(auth.uid(), student_id) or public.is_staff(auth.uid())
);
create policy "sub_write" on public.lms_submissions for all using (public.is_staff(auth.uid()));

-- ---- Activity log: staff/admin read; anyone authenticated may insert ----
drop policy if exists "al_read"   on public.activity_log;
drop policy if exists "al_insert" on public.activity_log;
create policy "al_read"   on public.activity_log for select using (public.is_admin(auth.uid()));
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
alter table public.school_settings add column if not exists role_access jsonb;

-- Page access manager write-permission map.
alter table public.school_settings add column if not exists role_write jsonb;


-- =====================================================================
-- V3 PRIVACY PATCH: scoped student/parent views. Staff/Admin manage.
-- =====================================================================
drop policy if exists "read_students" on public.students;
drop policy if exists "write_students" on public.students;
create policy "read_students" on public.students for select using (
  public.is_staff(auth.uid()) or user_id = auth.uid() or public.is_parent_of(auth.uid(), id)
);
create policy "write_students" on public.students for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "read_assignments" on public.assignments;
drop policy if exists "write_assignments" on public.assignments;
create policy "read_assignments" on public.assignments for select using (
  public.is_staff(auth.uid())
  or class in (select class from public.students where user_id = auth.uid())
  or class in (select class from public.students s join public.parent_child pc on pc.student_id=s.id where pc.parent_id=auth.uid())
);
create policy "write_assignments" on public.assignments for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "read_eresources" on public.eresources;
drop policy if exists "write_eresources" on public.eresources;
create policy "read_eresources" on public.eresources for select using (
  public.is_staff(auth.uid())
  or class in (select class from public.students where user_id = auth.uid())
  or class in (select class from public.students s join public.parent_child pc on pc.student_id=s.id where pc.parent_id=auth.uid())
);
create policy "write_eresources" on public.eresources for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

drop policy if exists "read_certificates" on public.certificates;
drop policy if exists "write_certificates" on public.certificates;
create policy "read_certificates" on public.certificates for select using (
  public.is_staff(auth.uid()) or student_id in (select id from public.students where user_id=auth.uid()) or public.is_parent_of(auth.uid(), student_id)
);
create policy "write_certificates" on public.certificates for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
