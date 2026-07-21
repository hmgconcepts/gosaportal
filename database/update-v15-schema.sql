-- =====================================================================
-- School Connect v1 — Schema Update v15  (HMG CONCEPTS proprietary)
-- =====================================================================
-- Idempotent. Run on top of v1..v14 to add the v1 feature tables:
--   * class_fee_structure  -> per-class / per-arm fees (item 2 / 13)
--   * school_products      -> required school products store (item 14)
--   * role_status_log      -> role & status change audit trail (item 10)
--   * staff_clock          -> staff clock-in / clock-out (item 15)
--   * student_clock        -> student clock-in / clock-out (item 15)
-- All tables are tenant-scoped via school_id and protected by RLS.
-- =====================================================================

-- 1. Per-class / per-arm fee structure ----------------------------------
create table if not exists public.class_fee_structure (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  class text not null,
  arm text default '',
  term text not null default 'Current Term'
        check (term in ('Current Term','Next Term')),
  tuition numeric(12,2) default 0,
  exam_fee numeric(12,2) default 0,
  development numeric(12,2) default 0,
  transport numeric(12,2) default 0,
  boarding numeric(12,2) default 0,
  total numeric(12,2) default 0,
  due_date date,
  discount numeric(12,2) default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists class_fee_structure_school_idx on public.class_fee_structure(school_id);

-- 2. School products store ----------------------------------------------
create table if not exists public.school_products (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  name text not null,
  category text default 'Other'
           check (category in ('Uniform','Textbook','Exercise Book','Stationery','Bag','Other')),
  price numeric(12,2) default 0,
  size_option text default '',
  stock_note text default '',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists school_products_school_idx on public.school_products(school_id);

-- 3. Role & status change audit log -------------------------------------
create table if not exists public.role_status_log (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  person_name text not null,
  current_role text default '',
  new_role text not null,
  action text default 'convert'
          check (action in ('promote','demote','convert','suspend','reactivate','deactivate')),
  reason text default '',
  changed_by text default '',
  changed_at timestamptz default now()
);
create index if not exists role_status_log_school_idx on public.role_status_log(school_id);

-- 4. Staff clock-in / clock-out -----------------------------------------
create table if not exists public.staff_clock (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete cascade,
  clock_in timestamptz,
  clock_out timestamptz,
  date date default current_date,
  note text default '',
  created_at timestamptz default now()
);
create index if not exists staff_clock_school_idx on public.staff_clock(school_id);
create index if not exists staff_clock_staff_idx on public.staff_clock(staff_id);

-- 5. Student clock-in / clock-out ---------------------------------------
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

-- 6. Row Level Security --------------------------------------------------
alter table public.class_fee_structure enable row level security;
alter table public.school_products enable row level security;
alter table public.role_status_log enable row level security;
alter table public.staff_clock enable row level security;
alter table public.student_clock enable row level security;

-- Read: any authenticated member of the school
drop policy if exists "class_fee_structure_school_read" on public.class_fee_structure;
create policy "class_fee_structure_school_read" on public.class_fee_structure for select
  using (public.is_member(school_id));
drop policy if exists "school_products_school_read" on public.school_products;
create policy "school_products_school_read" on public.school_products for select
  using (public.is_member(school_id));
drop policy if exists "role_status_log_school_read" on public.role_status_log;
create policy "role_status_log_school_read" on public.role_status_log for select
  using (public.is_member(school_id));
drop policy if exists "staff_clock_school_read" on public.staff_clock;
create policy "staff_clock_school_read" on public.staff_clock for select
  using (public.is_member(school_id));
drop policy if exists "student_clock_school_read" on public.student_clock;
create policy "student_clock_school_read" on public.student_clock for select
  using (public.is_member(school_id));

-- Write: admin / super-admin only
drop policy if exists "class_fee_structure_admin_write" on public.class_fee_structure;
create policy "class_fee_structure_admin_write" on public.class_fee_structure for all
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "school_products_admin_write" on public.school_products;
create policy "school_products_admin_write" on public.school_products for all
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "role_status_log_admin_write" on public.role_status_log;
create policy "role_status_log_admin_write" on public.role_status_log for all
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "staff_clock_admin_write" on public.staff_clock;
create policy "staff_clock_admin_write" on public.staff_clock for all
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "student_clock_admin_write" on public.student_clock;
create policy "student_clock_admin_write" on public.student_clock for all
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- 7. updated_at trigger (reuse existing helper if present) --------------
do $$
begin
  if exists (select 1 from pg_proc where proname = 'set_updated_at') then
    -- PostgreSQL does not support CREATE TRIGGER IF NOT EXISTS. Drop first so
    -- the migration remains genuinely safe to re-run.
    drop trigger if exists class_fee_structure_updated on public.class_fee_structure;
    create trigger class_fee_structure_updated before update on public.class_fee_structure
      for each row execute function public.set_updated_at();
    drop trigger if exists school_products_updated on public.school_products;
    create trigger school_products_updated before update on public.school_products
      for each row execute function public.set_updated_at();
  end if;
end $$;


-- v15 class_fee_structure final columns (safe re-run)
alter table public.class_fee_structure add column if not exists department text default '';
alter table public.class_fee_structure add column if not exists session text default '';
alter table public.class_fee_structure add column if not exists other_fee numeric(12,2) default 0;
alter table public.class_fee_structure add column if not exists next_term_begins date;
alter table public.class_fee_structure add column if not exists note text default '';
alter table public.class_fee_structure add column if not exists fee_items jsonb default '[]'::jsonb;
alter table public.class_fee_structure add column if not exists active boolean default true;
alter table public.school_settings add column if not exists checkin_deadline time default '08:00';
alter table public.school_settings add column if not exists checkin_grace_minutes int default 0;
notify pgrst, 'reload schema';

create unique index if not exists class_fee_structure_class_arm_department_term_uq on public.class_fee_structure(class, arm, department, term);
