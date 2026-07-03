-- =====================================================================
-- SCHOOL CONNECT — UPDATE V2 SCHEMA  (additive, idempotent, free-tier safe)
-- Run LAST, AFTER all the other schema files (including update-v1-schema.sql),
-- in the Supabase SQL editor. Safe to re-run any number of times. Adds:
--   • Staff DOB privacy: day & month only (issue 6)
--   • Super-admin / proprietor role support (issue 17)
--   • Storage-pressure helper: table sizes + cleanup RPC (issue 12)
--   • Entrance/assessment + admission-letter support (issue 5)
--   • Student/parent 360 dashboard view (issues 15 & 16)
--   • Developer/brand footer settings (issue 4)
--   • Helper indexes
-- =====================================================================

create extension if not exists "uuid-ossp";

-- Fallback is_staff()/is_admin() (created in other files; redefined safely here)
create or replace function public.is_staff(uid uuid)
returns boolean language sql stable security definer as $$
  select exists(select 1 from public.profiles p where p.id=uid
    and p.role in ('staff','head_teacher','bursar','principal','proprietor','admin','super_admin')
    and coalesce(p.status,'approved')='approved');
$$;
create or replace function public.is_admin(uid uuid)
returns boolean language sql stable security definer as $$
  select exists(select 1 from public.profiles p where p.id=uid
    and p.role in ('admin','principal','proprietor','super_admin')
    and coalesce(p.status,'approved')='approved');
$$;

-- ---------------------------------------------------------------------
-- 1. STAFF DOB PRIVACY — store day & month only (issue 6)
-- ---------------------------------------------------------------------
alter table public.staff add column if not exists dob_day   int;   -- 1..31
alter table public.staff add column if not exists dob_month text;  -- 'January'..'December'

-- ---------------------------------------------------------------------
-- 2. SUPER-ADMIN / PROPRIETOR ROLE (issue 17)
-- The proprietor/proprietress is the super-admin: full access to everything,
-- can manage admins, see all dashboards, and control storage. We extend the
-- is_super_admin() helper and a one-click promotion RPC.
-- ---------------------------------------------------------------------
create or replace function public.is_super_admin(uid uuid)
returns boolean language sql stable security definer as $$
  select exists(select 1 from public.profiles p where p.id=uid
    and p.role in ('proprietor','super_admin')
    and coalesce(p.status,'approved')='approved');
$$;

-- Promote a profile to super_admin (callable by an existing super_admin only)
create or replace function public.set_super_admin(p_target uuid)
returns void language plpgsql security definer as $$
begin
  if not public.is_super_admin(auth.uid()) then
    raise exception 'Only a super-admin may assign super-admin.';
  end if;
  update public.profiles set role='super_admin', status='approved' where id=p_target;
end; $$;
grant execute on function public.set_super_admin(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. STORAGE-PRESSURE HELPERS (issue 12)
-- Show how big each table is, and a safe RPC to purge old, low-value rows
-- (activity logs, old CBT results, read notifications) to free space.
-- ---------------------------------------------------------------------
create or replace function public.table_sizes()
returns table(table_name text, total_bytes bigint, pretty text, row_estimate bigint)
language sql security definer as $$
  with sizes as (
    select c.relname::text as table_name,
           pg_total_relation_size(c.oid)::bigint as total_bytes,
           pg_size_pretty(pg_total_relation_size(c.oid)) as pretty,
           greatest(c.reltuples,0)::bigint as row_estimate
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r'
  )
  select * from sizes
  union all
  select 'TOTAL_DATABASE_USED'::text, coalesce(sum(total_bytes),0)::bigint,
         pg_size_pretty(coalesce(sum(total_bytes),0)::bigint), coalesce(sum(row_estimate),0)::bigint
  from sizes
  order by total_bytes desc;
$$;
grant execute on function public.table_sizes() to authenticated;

-- Purge old rows older than N days from a safe-list of tables. Admin only.
create or replace function public.purge_old(p_table text, p_days int)
returns int language plpgsql security definer as $$
declare n int; allowed text[] := array['activity_log','cbt_results','notifications','reading_scores','attendance_checkins'];
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admins only.'; end if;
  if not (p_table = any(allowed)) then raise exception 'Table % is not purgeable.', p_table; end if;
  execute format('delete from public.%I where created_at < now() - ($1 || '' days'')::interval', p_table) using p_days::text;
  get diagnostics n = row_count;
  return n;
end; $$;
grant execute on function public.purge_old(text,int) to authenticated;

-- ---------------------------------------------------------------------
-- 4. ENTRANCE / ASSESSMENT + ADMISSION LETTERS (issue 5)
-- Anonymous candidates sit a CBT entrance/assessment exam (handled by the
-- existing cbt_* tables). We add an admission-letters log so the school can
-- generate/print instant results, certificates and admission letters per
-- candidate or in bulk from the assessment results.
-- ---------------------------------------------------------------------
create table if not exists public.admission_letters (
  id uuid primary key default uuid_generate_v4(),
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
alter table public.admission_letters enable row level security;

-- Mark a CBT exam as an "entrance/assessment" (open to anonymous candidates)
alter table public.cbt_exams add column if not exists is_entrance boolean default false;
alter table public.cbt_exams add column if not exists pass_mark numeric(6,2) default 50;

-- ---------------------------------------------------------------------
-- 5. STUDENT/PARENT 360 DASHBOARD VIEW (issues 15 & 16)
-- A single view that gathers each student's key facts so a dashboard (and the
-- admin "view any dashboard") can read one place. Uses left joins so missing
-- modules don't break it.
-- ---------------------------------------------------------------------
drop view if exists public.student_overview cascade;
create view public.student_overview as
select
  s.id,
  s.full_name,
  s.admission_no,
  s.class,
  s.arm,
  s.gender,
  s.date_of_birth,
  s.guardian_name,
  s.guardian_phone,
  s.guardian_email,
  s.status,
  s.photo_url,
  coalesce((select sum(fp.amount_paid) from public.fee_payments fp where fp.student_name = s.full_name),0) as fees_paid,
  (select count(*) from public.results r where r.student_name = s.full_name) as result_count,
  (select count(*) from public.attendance a where a.student_name = s.full_name and a.status='present') as days_present,
  (select count(*) from public.behaviour_points bp where bp.student_name = s.full_name) as award_count
from public.students s;

-- Admin/staff read all; (RLS on base tables still applies for direct queries)
grant select on public.student_overview to authenticated;

-- Staff salary overview (issue 16) — read from payroll if present
do $$
begin
  if to_regclass('public.payroll') is not null and to_regclass('public.staff') is not null then
    execute 'drop view if exists public.staff_salary_overview cascade';
    -- payroll has no direct staff link in base schema; expose the payroll rows as-is
    execute 'create view public.staff_salary_overview as select * from public.payroll';
    execute 'grant select on public.staff_salary_overview to authenticated';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. DEVELOPER / BRAND FOOTER (issue 4) — stored in school_settings
-- ---------------------------------------------------------------------
alter table public.school_settings add column if not exists developer_name  text default 'Adewale Samson Adeagbo';
alter table public.school_settings add column if not exists developer_brand text default 'HMG Concepts';
alter table public.school_settings add column if not exists developer_url   text default 'https://hmgconcepts.pages.dev';

-- ---------------------------------------------------------------------
-- 7. RLS POLICIES
-- ---------------------------------------------------------------------
do $$
declare t text; declare staff_rw text[] := array['admission_letters'];
begin
  foreach t in array staff_rw loop
    execute format('drop policy if exists "uv2_read_%s"  on public.%I', t, t);
    execute format('drop policy if exists "uv2_write_%s" on public.%I', t, t);
    execute format('create policy "uv2_read_%s"  on public.%I for select using (auth.role()=''authenticated'')', t, t);
    execute format('create policy "uv2_write_%s" on public.%I for all    using (public.is_staff(auth.uid()))', t, t);
  end loop;
end $$;

select 'School Connect — Update v2 schema installed ✅' as status;
