-- =====================================================================
-- School Connect — Enhancements Schema (Connect Repair v3)
-- =====================================================================
-- Adds the data foundations for: auto admission/parent IDs, reusable
-- lookups (terms/sessions/subjects/classes), timetable period config,
-- weekly scheme-of-work confirmation, certificate designs, admissions
-- application tokens/links, broadsheets & scoresheets.
-- Free tools, NO AI. Ordering-safe & idempotent (drop-before-create where
-- column/structure may change). Run AFTER schema.sql.
-- =====================================================================
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- minimal deps (no-op if main schema already ran)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text, full_name text, phone text,
  role text not null default 'student', status text not null default 'pending',
  photo_url text, campus text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create table if not exists public.students (
  id uuid primary key default uuid_generate_v4(), admission_no text unique,
  full_name text not null, class text, arm text, gender text,
  date_of_birth date, guardian_name text, guardian_phone text, guardian_email text,
  address text, photo_url text, campus text, status text default 'active',
  created_at timestamptz default now()
);
alter table public.students enable row level security;
alter table public.students add column if not exists user_id uuid references public.profiles(id) on delete set null;
create index if not exists students_user_id_idx on public.students(user_id);

-- ---- column backfills the new features rely on ----
do $$ begin
  alter table public.students add column if not exists parent_id uuid;
  alter table public.profiles add column if not exists member_id text;        -- auto ID for parents/staff
  alter table public.profiles add column if not exists photo_url text;
exception when undefined_table then null; end $$;

-- Denormalised student_name columns so list/CRUD screens can show & filter by
-- name while still keeping the relational student_id link.
do $$ begin
  alter table public.results    add column if not exists student_name text;
  alter table public.attendance add column if not exists student_name text;
  alter table public.conduct    add column if not exists student_name text;
  alter table public.health     add column if not exists student_name text;
  alter table public.fee_payments add column if not exists student_name text;
  alter table public.promotions add column if not exists student_name text;
  alter table public.behaviour_points add column if not exists student_name text;
exception when undefined_table then null; end $$;

-- =====================================================================
-- 1. SCHOOL SETTINGS (single-row config: terms, sessions, ID prefix, etc.)
-- =====================================================================
create table if not exists public.school_settings (
  id int primary key default 1,
  current_session text default '',
  current_term text default 'First Term',
  sessions text[] default array['2024/2025','2025/2026','2026/2027'],
  terms text[] default array['First Term','Second Term','Third Term'],
  admission_prefix text default 'GOSA', -- generator rewrites SCH to the school acronym
  admission_next int default 1,
  parent_prefix text default 'PAR',
  parent_next int default 1,
  staff_prefix text default 'STF',
  staff_next int default 1,
  grading jsonb default '[{"min":70,"grade":"A"},{"min":60,"grade":"B"},{"min":50,"grade":"C"},{"min":45,"grade":"D"},{"min":40,"grade":"E"},{"min":0,"grade":"F"}]'::jsonb,
  signature_url text default '',
  principal_name text default '',
  updated_at timestamptz default now(),
  check (id = 1)
);
alter table public.school_settings enable row level security;
insert into public.school_settings (id) values (1) on conflict (id) do nothing;

-- Reusable lookup lists (subjects/classes already have tables; add a generic
-- key/value lookup for arms, departments-as-options, periods, etc.)
create table if not exists public.lookups (
  id uuid primary key default uuid_generate_v4(),
  kind text not null,         -- 'arm' | 'period' | 'audience' | 'fee_type' | 'grade_label'
  value text not null,
  position int default 0,
  unique(kind, value)
);
alter table public.lookups enable row level security;
-- seed common audiences (issue 9) + arms + periods
insert into public.lookups(kind,value,position) values
 ('audience','all',1),('audience','students',2),('audience','parents',3),('audience','staff',4),('audience','a class',5),
 ('arm','A',1),('arm','B',2),('arm','C',3),('arm','D',4)
on conflict do nothing;

-- =====================================================================
-- 2. AUTO ADMISSION NUMBER (issue 2) — trigger on students insert
-- =====================================================================
create or replace function public.gen_admission_no()
returns trigger language plpgsql security definer as $$
declare s public.school_settings; yr text := to_char(now(),'YYYY');
begin
  if new.admission_no is null or new.admission_no = '' then
    update public.school_settings set admission_next = admission_next + 1, updated_at = now()
      where id = 1 returning * into s;
    if s.id is null then
      insert into public.school_settings(id, admission_next) values (1, 2) returning * into s;
      s.admission_prefix := 'GOSA'; s.admission_next := 1;
    end if;
    new.admission_no := coalesce(s.admission_prefix,'GOSA') || '/' || yr || '/' || lpad((s.admission_next-1)::text, 4, '0');
  end if;
  return new;
end; $$;
drop trigger if exists trg_gen_admission_no on public.students;
create trigger trg_gen_admission_no before insert on public.students
  for each row execute function public.gen_admission_no();

-- =====================================================================
-- 3. AUTO MEMBER ID for parents/staff when approved (issue 2)
-- Call from the app after approving a profile, or it runs on status->approved.
-- =====================================================================
create or replace function public.assign_member_id()
returns trigger language plpgsql security definer as $$
declare s public.school_settings; pfx text; nxt int; yr text := to_char(now(),'YYYY');
begin
  if new.status = 'approved' and (new.member_id is null or new.member_id = '') then
    if new.role = 'parent' then
      update public.school_settings set parent_next = parent_next + 1 where id=1 returning parent_prefix, parent_next into pfx, nxt;
      new.member_id := coalesce(pfx,'PAR') || '/' || yr || '/' || lpad((nxt-1)::text,4,'0');
    elsif new.role in ('staff','head_teacher','bursar','principal','proprietor','admin') then
      update public.school_settings set staff_next = staff_next + 1 where id=1 returning staff_prefix, staff_next into pfx, nxt;
      new.member_id := coalesce(pfx,'STF') || '/' || yr || '/' || lpad((nxt-1)::text,4,'0');
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists trg_assign_member_id on public.profiles;
create trigger trg_assign_member_id before update on public.profiles
  for each row execute function public.assign_member_id();

-- =====================================================================
-- 4. TIMETABLE PERIOD CONFIG (issue 7)
-- =====================================================================
create table if not exists public.timetable_config (
  id uuid primary key default uuid_generate_v4(),
  class text default 'ALL',
  period_no int not null,
  label text not null,          -- 'Period 1' | 'Short Break' | 'Long Break'
  start_time text,              -- '08:00'
  end_time text,                -- '08:40'
  is_break boolean default false,
  position int default 0,
  unique(class, period_no)
);
alter table public.timetable_config enable row level security;

-- =====================================================================
-- 5. SCHEME OF WORK — weekly confirmation (issue 5)
-- (scheme_of_work table already exists; ensure weekly-tracking columns)
-- =====================================================================
do $$ begin
  alter table public.scheme_of_work add column if not exists confirmed boolean default false;
  alter table public.scheme_of_work add column if not exists confirmed_at timestamptz;
  alter table public.scheme_of_work add column if not exists planned_at timestamptz default now();
exception when undefined_table then
  create table public.scheme_of_work (
    id uuid primary key default uuid_generate_v4(),
    subject text, class text, term text, session text,
    week int, topic text, status text default 'pending',
    confirmed boolean default false, confirmed_at timestamptz,
    planned_at timestamptz default now(), covered_at date, teacher text, confirmed boolean default false,
    created_at timestamptz default now()
  );
  alter table public.scheme_of_work enable row level security;
end $$;

-- =====================================================================
-- 6. CERTIFICATE DESIGNS (issue 12) — saved templates with colours/fonts/signature
-- =====================================================================
create table if not exists public.certificate_designs (
  id uuid primary key default uuid_generate_v4(),
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
alter table public.certificate_designs enable row level security;

-- =====================================================================
-- 7. ADMISSIONS APPLICATION LINKS / TOKENS (issue 13)
-- Public applicants fill a tokenised form; admin approves → extract to students.
-- =====================================================================
do $$ begin
  alter table public.admissions add column if not exists token text;
  alter table public.admissions add column if not exists extracted boolean default false;
  alter table public.admissions add column if not exists photo_url text;
  alter table public.admissions add column if not exists session text;
exception when undefined_table then
  create table public.admissions (
    id uuid primary key default uuid_generate_v4(),
    full_name text, dob date, gender text,
    parent_name text, parent_email text, parent_phone text,
    applying_for_class text, status text default 'submitted',
    notes text, token text, extracted boolean default false, photo_url text, session text,
    created_at timestamptz default now()
  );
  alter table public.admissions enable row level security;
end $$;

create table if not exists public.admission_links (
  id uuid primary key default uuid_generate_v4(),
  token text unique not null default replace(gen_random_uuid()::text,'-',''),
  label text,
  applying_for_class text,
  session text,
  active boolean default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.admission_links enable row level security;

-- Public RPC: submit an admission application via a link token (anon allowed)
create or replace function public.submit_admission(p_payload jsonb)
returns jsonb language plpgsql security definer as $$
declare v_link public.admission_links; v_id uuid;
begin
  select * into v_link from public.admission_links where token = p_payload->>'token' and active = true limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'Invalid or closed application link'); end if;
  insert into public.admissions (full_name, dob, gender, parent_name, parent_email, parent_phone,
                                 applying_for_class, session, photo_url, token, status)
  values (p_payload->>'full_name', nullif(p_payload->>'dob','')::date, p_payload->>'gender',
          p_payload->>'parent_name', p_payload->>'parent_email', p_payload->>'parent_phone',
          coalesce(p_payload->>'applying_for_class', v_link.applying_for_class),
          coalesce(p_payload->>'session', v_link.session),
          p_payload->>'photo_url', v_link.token, 'submitted')
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

-- Admin RPC: extract an accepted admission into the students table (issue 13)
create or replace function public.extract_admission(p_id uuid)
returns jsonb language plpgsql security definer as $$
declare a public.admissions; v_sid uuid;
begin
  select * into a from public.admissions where id = p_id limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'Application not found'); end if;
  if a.extracted then return jsonb_build_object('ok', false, 'error', 'Already extracted'); end if;
  insert into public.students (full_name, date_of_birth, gender, class, guardian_name,
                               guardian_email, guardian_phone, photo_url, status)
  values (a.full_name, a.dob, a.gender, a.applying_for_class, a.parent_name,
          a.parent_email, a.parent_phone, a.photo_url, 'active')
  returning id into v_sid;
  update public.admissions set status='enrolled', extracted=true where id = p_id;
  return jsonb_build_object('ok', true, 'student_id', v_sid);
end; $$;

-- =====================================================================
-- 8. BROADSHEET / SCORESHEET helper view (issue 6)
-- =====================================================================
drop view if exists public.broadsheet cascade;
create view public.broadsheet as
select r.class, r.term, r.session, r.student_name, r.subject,
       coalesce(r.ca1,0)+coalesce(r.ca2,0)+coalesce(r.ca3,0)+coalesce(r.exam,0) as total,
       r.grade
from public.results r;

-- =====================================================================
-- 8b. GENERIC MODULE RECORDS (issue 8) — flexible store so every module
-- that lacks a dedicated table still gets a working Add/Edit/Delete screen.
-- Each row belongs to a 'module' and carries its fields in 'data' (jsonb)
-- plus a few common columns for listing/searching.
-- =====================================================================
create table if not exists public.module_records (
  id uuid primary key default uuid_generate_v4(),
  module text not null,                 -- e.g. 'messages','inbox','front_desk','reports'
  title text,                           -- primary display field
  body text,                            -- secondary text
  status text,
  ref_date date,
  amount numeric,
  data jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table public.module_records enable row level security;
create index if not exists module_records_module_idx on public.module_records (module, created_at desc);
alter table public.module_records add column if not exists recipient_id uuid references public.profiles(id) on delete set null;
alter table public.module_records add column if not exists audience text default 'private';

drop policy if exists "mr_read"  on public.module_records;
drop policy if exists "mr_write" on public.module_records;
drop policy if exists "mr_write_staff" on public.module_records;
drop policy if exists "mr_insert_family" on public.module_records;
drop policy if exists "mr_update_family" on public.module_records;
create policy "mr_read" on public.module_records for select using (
  auth.role()='authenticated' and (
    module not in ('inbox','messages')
    or public.is_staff(auth.uid())
    or created_by = auth.uid()
    or recipient_id = auth.uid()
    or coalesce(audience,'') = 'all'
    or coalesce(audience,'') = (select role from public.profiles where id=auth.uid())
  )
);
create policy "mr_write_staff" on public.module_records for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
create policy "mr_insert_family" on public.module_records for insert with check (auth.role()='authenticated' and module in ('inbox','messages','helpdesk','book_request','parent_meeting','lost_found'));
create policy "mr_update_family" on public.module_records for update using (created_by = auth.uid() and module in ('inbox','messages','helpdesk','book_request','parent_meeting','lost_found')) with check (created_by = auth.uid());

-- =====================================================================
-- 9. RLS POLICIES
-- =====================================================================
do $$ declare t text;
declare staff_rw text[] := array['lookups','timetable_config','certificate_designs','admission_links'];
begin
  foreach t in array staff_rw loop
    execute format('drop policy if exists "enh_read_%s"  on public.%I', t, t);
    execute format('drop policy if exists "enh_write_%s" on public.%I', t, t);
    execute format('create policy "enh_read_%s"  on public.%I for select using (auth.role()=''authenticated'')', t, t);
    execute format('create policy "enh_write_%s" on public.%I for all    using (public.is_staff(auth.uid()))', t, t);
  end loop;
end $$;

-- school_settings: everyone authenticated reads; admin writes page-access governance
drop policy if exists "ss_read" on public.school_settings;
drop policy if exists "ss_write" on public.school_settings;
create policy "ss_read"  on public.school_settings for select using (auth.role()='authenticated');
create policy "ss_write" on public.school_settings for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- admission_links readable by anon (so the public form can validate a token via RPC)
grant execute on function public.submit_admission(jsonb) to anon, authenticated;
grant execute on function public.extract_admission(uuid) to authenticated;

select 'School Connect Enhancements schema (Connect Repair v3) installed ✅' as status;


-- FINAL CUMULATIVE SUBJECT-TEACHER MAPPING REPAIR
-- Safe for fresh and existing databases. Fixes: could not find 'teacher' column of subjects.
alter table if exists public.subjects add column if not exists teacher text;
alter table if exists public.subjects add column if not exists teacher_id uuid references public.profiles(id) on delete set null;

alter table public.school_settings add column if not exists signature_url text default '';
alter table public.school_settings add column if not exists principal_name text default '';


-- Role/page access map controlled from Admin Dashboard → Page Access Manager.
alter table public.school_settings add column if not exists role_access jsonb;

-- Page access manager write-permission map.
alter table public.school_settings add column if not exists role_write jsonb;
