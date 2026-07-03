-- =====================================================================
-- SCHOOL CONNECT — UPDATE V4 SCHEMA  (additive, idempotent, free-tier safe)
-- Run LAST, AFTER all the other schema files (schema, voting, cbt, reportcard,
-- enterprise, enhancements, update-v1, update-v2), in the Supabase SQL editor.
-- Safe to re-run any number of times. Adds:
--   • Richer payroll (bonus, overtime, tax, pension, loan, net pay) — issue 5
--   • Staff loans / advances with EMI tracking — issue 5
--   • Staff bonuses / allowance awards — issue 5
--   • Staff appraisals (weighted scoring) — issue 5
--   • Parent<->child convenience: link by profile, both directions — issue 4
--   • Academic transcript view (international standard) — enhancement
-- =====================================================================

create extension if not exists "uuid-ossp";

create or replace function public.is_staff(uid uuid)
returns boolean language sql stable security definer as $$
  select exists(select 1 from public.profiles p where p.id=uid
    and p.role in ('staff','head_teacher','bursar','principal','proprietor','admin','super_admin')
    and coalesce(p.status,'approved')='approved');
$$;

-- ---------------------------------------------------------------------
-- 1. PAYROLL — extend with international payslip components (issue 5)
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.payroll') is null then
    create table public.payroll (
      id uuid primary key default uuid_generate_v4(),
      created_at timestamptz default now()
    );
    alter table public.payroll enable row level security;
  end if;
end $$;
alter table public.payroll add column if not exists staff_name       text;
alter table public.payroll add column if not exists month            text;
alter table public.payroll add column if not exists year             int;
alter table public.payroll add column if not exists basic            numeric default 0;
alter table public.payroll add column if not exists allowances       numeric default 0;
alter table public.payroll add column if not exists bonus            numeric default 0;
alter table public.payroll add column if not exists overtime         numeric default 0;
alter table public.payroll add column if not exists tax              numeric default 0;
alter table public.payroll add column if not exists pension          numeric default 0;
alter table public.payroll add column if not exists loan_deduction   numeric default 0;
alter table public.payroll add column if not exists other_deductions numeric default 0;
alter table public.payroll add column if not exists net_pay          numeric;
alter table public.payroll add column if not exists method           text;
alter table public.payroll add column if not exists status           text default 'draft';

-- Auto-compute net pay if not supplied (DB-side safety net mirroring the UI)
create or replace function public.payroll_net()
returns trigger language plpgsql as $$
begin
  if new.net_pay is null then
    new.net_pay := coalesce(new.basic,0)+coalesce(new.allowances,0)+coalesce(new.bonus,0)+coalesce(new.overtime,0)
                 - coalesce(new.tax,0)-coalesce(new.pension,0)-coalesce(new.loan_deduction,0)-coalesce(new.other_deductions,0);
  end if;
  return new;
end; $$;
drop trigger if exists trg_payroll_net on public.payroll;
create trigger trg_payroll_net before insert or update on public.payroll
  for each row execute function public.payroll_net();

-- ---------------------------------------------------------------------
-- 2. STAFF LOANS / ADVANCES (issue 5)
-- ---------------------------------------------------------------------
create table if not exists public.staff_loans (
  id uuid primary key default uuid_generate_v4(),
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
alter table public.staff_loans enable row level security;
create index if not exists staff_loans_name_idx on public.staff_loans (staff_name);

-- ---------------------------------------------------------------------
-- 3. STAFF BONUSES (issue 5)
-- ---------------------------------------------------------------------
create table if not exists public.staff_bonus (
  id uuid primary key default uuid_generate_v4(),
  staff_name text not null,
  bonus_type text default 'performance',
  amount numeric default 0,
  reason text,
  award_date date,
  status text default 'pending' check (status in ('pending','approved','paid')),
  created_at timestamptz default now()
);
alter table public.staff_bonus enable row level security;

-- ---------------------------------------------------------------------
-- 4. STAFF APPRAISALS (issue 5)
-- ---------------------------------------------------------------------
create table if not exists public.staff_appraisals (
  id uuid primary key default uuid_generate_v4(),
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
alter table public.staff_appraisals enable row level security;

-- ---------------------------------------------------------------------
-- 5. PARENT <-> CHILD convenience (issue 4)
-- parent_child already exists; ensure columns + a reverse helper view so a
-- parent can be found from a child and vice-versa via dropdowns.
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.parent_child') is null then
    create table public.parent_child (
      id uuid primary key default uuid_generate_v4(),
      parent_id uuid,
      student_id uuid,
      relationship text default 'parent',
      created_at timestamptz default now()
    );
    alter table public.parent_child enable row level security;
  end if;
end $$;
alter table public.parent_child add column if not exists relationship text default 'parent';

drop view if exists public.parent_child_view cascade;
create view public.parent_child_view as
  select pc.id, pc.relationship,
         pc.parent_id, pr.full_name as parent_name, pr.email as parent_email,
         pc.student_id, st.full_name as student_name, st.class as student_class
  from public.parent_child pc
  left join public.profiles pr on pr.id = pc.parent_id
  left join public.students st on st.id = pc.student_id;
grant select on public.parent_child_view to authenticated;

-- ---------------------------------------------------------------------
-- 6. ACADEMIC TRANSCRIPT VIEW (international standard enhancement)
-- A per-student, per-subject roll-up of results across terms/sessions.
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.results') is not null then
    execute 'drop view if exists public.transcript_view cascade';
    execute $v$
      create view public.transcript_view as
      select student_name, class, session, term, subject,
             coalesce(ca1,0)+coalesce(ca2,0)+coalesce(ca3,0)+coalesce(exam,0) as total,
             grade
      from public.results
    $v$;
    execute 'grant select on public.transcript_view to authenticated';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. RLS POLICIES (authenticated read; staff write)
-- ---------------------------------------------------------------------
do $$
declare t text; declare staff_rw text[] := array['staff_loans','staff_bonus','staff_appraisals','payroll'];
begin
  foreach t in array staff_rw loop
    execute format('drop policy if exists "uv4_read_%s"  on public.%I', t, t);
    execute format('drop policy if exists "uv4_write_%s" on public.%I', t, t);
    execute format('create policy "uv4_read_%s"  on public.%I for select using (auth.role()=''authenticated'')', t, t);
    execute format('create policy "uv4_write_%s" on public.%I for all    using (public.is_staff(auth.uid()))', t, t);
  end loop;
end $$;

select 'School Connect — Update v4 schema installed ✅' as status;


-- FINAL CUMULATIVE SUBJECT-TEACHER MAPPING REPAIR
-- Safe for fresh and existing databases. Fixes: could not find 'teacher' column of subjects.
alter table if exists public.subjects add column if not exists teacher text;
alter table if exists public.subjects add column if not exists teacher_id uuid references public.profiles(id) on delete set null;


-- Role/page access map controlled from Admin Dashboard → Page Access Manager.
alter table public.school_settings add column if not exists role_access jsonb;

-- Page access manager write-permission map.
alter table public.school_settings add column if not exists role_write jsonb;
