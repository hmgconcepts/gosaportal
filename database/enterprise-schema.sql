
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
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
insert into public.school_settings (id) values (1) on conflict (id) do nothing;

-- =====================================================================
-- School Connect — Enterprise Add-on Schema — FINAL v2
-- =====================================================================
-- New enterprise modules sourced from a deep review of leading platforms
-- (Fedena, OpenEduCat, Kinderpedia, eSchool, Edumerge, Smart School ERP, etc.)
-- All FREE tools, NO AI APIs. Deterministic logic only.
--
-- Adds: timetable generator slots, QR self check-in attendance, student
-- diary, surveys/forms, menu/meal planner, security (2FA prefs / login
-- audit), and an i18n string store.
--
-- ORDERING RULE (prevents 42P01): tables first → helper → policies.
-- Self-contained & idempotent. Run AFTER database/schema.sql (recommended).
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
  admission_no text unique, full_name text not null,
  class text, arm text, guardian_email text,
  created_at timestamptz default now()
);
alter table public.students enable row level security;
alter table public.students add column if not exists user_id uuid references public.profiles(id) on delete set null;
create index if not exists students_user_id_idx on public.students(user_id);

-- =====================================================================
-- 1. TABLES
-- =====================================================================

-- 1a. Timetable generator: subject demand + a generated grid.
-- 'periods_per_week' tells the generator how many slots each subject needs.
create table if not exists public.timetable_requirements (
  id uuid primary key default uuid_generate_v4(),
  class text not null,
  subject text not null,
  teacher text,
  periods_per_week int not null default 1,
  -- ✨ Part-time support: the weekdays this (often part-time) teacher attends.
  -- NULL/empty = available every weekday. e.g. ARRAY['Monday','Wednesday'].
  available_days text[] default null,
  is_part_time boolean default false,
  created_at timestamptz default now(),
  unique(class, subject)
);
-- backfill for older installs (idempotent)
do $$ begin
  alter table public.timetable_requirements add column if not exists available_days text[] default null;
  alter table public.timetable_requirements add column if not exists is_part_time boolean default false;
exception when undefined_table then null; end $$;

-- Optional reusable teacher availability roster (one row per teacher).
create table if not exists public.teacher_availability (
  id uuid primary key default uuid_generate_v4(),
  teacher text not null unique,
  is_part_time boolean default false,
  available_days text[] default null,   -- e.g. ARRAY['Tuesday','Thursday']
  notes text,
  created_at timestamptz default now()
);
alter table public.teacher_availability enable row level security;
alter table public.timetable_requirements enable row level security;

-- The generated, conflict-checked timetable grid lives in the existing
-- public.timetable table (created by schema.sql). This add-on only stores
-- requirements + generation metadata.
create table if not exists public.timetable_runs (
  id uuid primary key default uuid_generate_v4(),
  class text, session text, term text,
  generated_at timestamptz default now(),
  conflicts int default 0,
  notes text
);
alter table public.timetable_runs enable row level security;

-- 1b. QR / code self check-in attendance (free, no biometric hardware).
create table if not exists public.attendance_checkins (
  id uuid primary key default uuid_generate_v4(),
  student_id_ref text not null,         -- scanned from the ID-card QR
  student_name text,
  class text,
  checkin_at timestamptz default now(),
  method text default 'qr' check (method in ('qr','code','manual')),
  device text,
  recorded_by uuid references public.profiles(id)
);
alter table public.attendance_checkins enable row level security;
create index if not exists att_checkin_student_idx on public.attendance_checkins (student_id_ref);

-- 1c. Student diary / daily homework & behaviour log (eSchool parity).
create table if not exists public.student_diary (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid references public.students(id) on delete cascade,
  student_name text, class text, subject text,
  date date default current_date,
  entry_type text default 'homework' check (entry_type in ('homework','classwork','behaviour','note')),
  title text, body text,
  acknowledged boolean default false,   -- parent acknowledgement
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.student_diary enable row level security;
create index if not exists diary_student_idx on public.student_diary (student_id);

-- 1d. Surveys / feedback forms (Kinderpedia "Survey & Polls" parity; distinct
-- from the elections in voting-schema).
create table if not exists public.surveys (
  id uuid primary key default uuid_generate_v4(),
  title text not null, description text,
  audience text default 'all',
  questions jsonb default '[]'::jsonb,  -- [{q,type,options}]
  anonymous boolean default true,
  is_open boolean default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);
alter table public.surveys enable row level security;

create table if not exists public.survey_responses (
  id uuid primary key default uuid_generate_v4(),
  survey_id uuid references public.surveys(id) on delete cascade,
  respondent uuid references public.profiles(id),
  answers jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
alter table public.survey_responses enable row level security;

-- 1e. Menu / meal planner (Kinderpedia "Menu Planner" parity).
create table if not exists public.menu_planner (
  id uuid primary key default uuid_generate_v4(),
  week_start date,
  day text check (day in ('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')),
  meal text check (meal in ('breakfast','snack','lunch','supper')),
  description text, allergens text,
  created_at timestamptz default now()
);
alter table public.menu_planner enable row level security;

-- 1f. Security: 2FA preference + login audit (free Supabase email OTP).
create table if not exists public.security_prefs (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  two_factor boolean default false,
  recovery_email text,
  updated_at timestamptz default now()
);
alter table public.security_prefs enable row level security;

create table if not exists public.login_audit (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references public.profiles(id) on delete set null,
  email text, event text default 'login',
  ip text, user_agent text,
  created_at timestamptz default now()
);
alter table public.login_audit enable row level security;

-- 1g. i18n string store (multi-language UI labels — free, no API).
create table if not exists public.i18n_strings (
  id uuid primary key default uuid_generate_v4(),
  lang text not null default 'en',
  key text not null,
  value text not null,
  unique(lang, key)
);
alter table public.i18n_strings enable row level security;

-- =====================================================================
-- 2. HELPER (no-op if main schema already made it)
-- =====================================================================
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
-- 3. RLS POLICIES
-- =====================================================================
do $$
declare t text;
declare staff_read text[] := array[
  'timetable_requirements','timetable_runs','teacher_availability','student_diary','surveys','menu_planner','i18n_strings'
];
begin
  foreach t in array staff_read loop
    execute format('drop policy if exists "ent_read_%s"  on public.%I', t, t);
    execute format('drop policy if exists "ent_write_%s" on public.%I', t, t);
    execute format('create policy "ent_read_%s"  on public.%I for select using (auth.role() = ''authenticated'')', t, t);
    execute format('create policy "ent_write_%s" on public.%I for all    using (public.is_staff(auth.uid()))', t, t);
  end loop;
end $$;

-- Check-ins: anyone authenticated may insert their own scan; staff read all.
drop policy if exists "ent_checkin_insert" on public.attendance_checkins;
drop policy if exists "ent_checkin_read"   on public.attendance_checkins;
drop policy if exists "ent_checkin_insert" on public.attendance_checkins;
create policy "ent_checkin_insert" on public.attendance_checkins for insert with check (auth.role() = 'authenticated');
drop policy if exists "ent_checkin_read" on public.attendance_checkins;
create policy "ent_checkin_read"   on public.attendance_checkins for select using (public.is_staff(auth.uid()));

-- Survey responses: respondent manages own; staff read all.
drop policy if exists "ent_sr_own"  on public.survey_responses;
drop policy if exists "ent_sr_staff" on public.survey_responses;
drop policy if exists "ent_sr_own" on public.survey_responses;
create policy "ent_sr_own"   on public.survey_responses for all using (respondent = auth.uid());
drop policy if exists "ent_sr_staff" on public.survey_responses;
create policy "ent_sr_staff" on public.survey_responses for select using (public.is_staff(auth.uid()));

-- Security prefs: each user manages own.
drop policy if exists "ent_sec_own" on public.security_prefs;
create policy "ent_sec_own" on public.security_prefs for all using (user_id = auth.uid());

-- Login audit: admin reads; any authenticated inserts.
drop policy if exists "ent_la_read"   on public.login_audit;
drop policy if exists "ent_la_insert" on public.login_audit;
drop policy if exists "ent_la_read" on public.login_audit;
create policy "ent_la_read"   on public.login_audit for select using (public.is_staff(auth.uid()));
drop policy if exists "ent_la_insert" on public.login_audit;
create policy "ent_la_insert" on public.login_audit for insert with check (auth.role() = 'authenticated');

-- =====================================================================
-- 4. TIMETABLE GENERATOR (deterministic, conflict-free, no AI)
--    Greedy slot allocator: fills Mon–Fri × periods, ensuring no class or
--    teacher is double-booked. Writes into public.timetable if it exists.
-- =====================================================================
create or replace function public.generate_timetable(
  p_class text, p_session text default '', p_term text default '',
  p_periods_per_day int default 6
) returns jsonb language plpgsql security definer as $$
declare
  days text[] := array['Monday','Tuesday','Wednesday','Thursday','Friday'];
  d text; p int; r record; placed int := 0; conflicts int := 0;
  v_has_tt boolean;
begin
  -- only run if the timetable table exists (main schema installed)
  select exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='timetable') into v_has_tt;
  if not v_has_tt then
    return jsonb_build_object('ok', false, 'reason', 'timetable table not found; run schema.sql first');
  end if;

  -- clear existing grid for this class/term/session
  execute format('delete from public.timetable where class = %L and coalesce(session,'''') = %L and coalesce(term,'''') = %L',
                 p_class, coalesce(p_session,''), coalesce(p_term,''));

  -- expand requirements into a queue and greedily place them
  declare
    v_days text[];        -- the days THIS teacher may be scheduled on
    v_placed_this int;
    unplaced int := 0;
  begin
  for r in
    select tr.subject, tr.teacher, tr.periods_per_week, tr.available_days, tr.is_part_time
    from public.timetable_requirements tr
    where tr.class = p_class
    order by tr.periods_per_week desc
  loop
    -- ✨ PART-TIME SUPPORT: restrict to the teacher's attending days.
    -- Priority: requirement.available_days → teacher_availability roster → all weekdays.
    v_days := r.available_days;
    if v_days is null or array_length(v_days,1) is null then
      select ta.available_days into v_days
        from public.teacher_availability ta
       where ta.teacher = r.teacher and ta.available_days is not null
       limit 1;
    end if;
    if v_days is null or array_length(v_days,1) is null then
      v_days := days;  -- full-time: every weekday
    end if;

    for i in 1..r.periods_per_week loop
      v_placed_this := 0;
      <<placeloop>>
      for d in select unnest(v_days) loop          -- only days the teacher attends
        for p in 1..p_periods_per_day loop
          -- class free at this slot?
          if exists (select 1 from public.timetable where class=p_class and day=d and period=p::text
                       and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'')) then
            continue;
          end if;
          -- teacher free at this slot (across all classes)?
          if r.teacher is not null and exists (
              select 1 from public.timetable where teacher=r.teacher and day=d and period=p::text
                and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'')) then
            continue;
          end if;
          insert into public.timetable (class, day, period, subject, teacher, session, term)
          values (p_class, d, p::text, r.subject, r.teacher, p_session, p_term);
          placed := placed + 1;
          v_placed_this := 1;
          exit placeloop;
        end loop;
      end loop;
      -- could not fit this period within the teacher's available days/periods
      if v_placed_this = 0 then unplaced := unplaced + 1; end if;
    end loop;
  end loop;

  insert into public.timetable_runs (class, session, term, conflicts, notes)
  values (p_class, p_session, p_term, unplaced,
          'placed '||placed||' periods'||(case when unplaced>0 then '; '||unplaced||' could not fit (check part-time availability/periods-per-day)' else '' end));

  return jsonb_build_object('ok', true, 'placed', placed, 'unplaced', unplaced, 'class', p_class);
  end;
end; $$;

grant execute on function public.generate_timetable(text,text,text,int) to authenticated;

-- =====================================================================
-- DONE ✅  Enterprise add-on installed: timetable generator, QR check-in,
-- student diary, surveys, menu planner, security prefs/audit, i18n.
-- =====================================================================
select 'School Connect Enterprise schema (FINAL v2) installed ✅' as status;

-- =====================================================================
-- FINAL ADDITIVE PATCH: Nigerian/international academic print records
-- Student Record Card, Class Broadsheet, Subject Broadsheet support.
-- =====================================================================
create table if not exists public.academic_print_records (
  id uuid primary key default uuid_generate_v4(),
  record_type text not null check (record_type in ('student_record_card','class_broadsheet','subject_broadsheet')),
  title text not null,
  class text default '',
  subject text default '',
  term text default '',
  session text default '',
  generated_by uuid references public.profiles(id) on delete set null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz default now()
);
alter table public.academic_print_records enable row level security;
drop policy if exists "academic_print_staff" on public.academic_print_records;
create policy "academic_print_staff" on public.academic_print_records for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists "academic_print_read" on public.academic_print_records;
create policy "academic_print_read" on public.academic_print_records for select using (auth.role()='authenticated');


-- FINAL CUMULATIVE SUBJECT-TEACHER MAPPING REPAIR
-- Safe for fresh and existing databases. Fixes: could not find 'teacher' column of subjects.
alter table if exists public.subjects add column if not exists teacher text;
alter table if exists public.subjects add column if not exists teacher_id uuid references public.profiles(id) on delete set null;


-- Role/page access map controlled from Admin Dashboard → Page Access Manager.
alter table public.school_settings add column if not exists role_access jsonb;

-- Page access manager write-permission map.
alter table public.school_settings add column if not exists role_write jsonb;
