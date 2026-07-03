-- =====================================================================
-- SCHOOL CONNECT — UPDATE V1 SCHEMA  (additive, idempotent, free-tier safe)
-- Run LAST, AFTER all the other schema files, in the Supabase SQL editor.
-- Safe to re-run any number of times. Adds / enhances:
--   • Staff details fields + AUTO staff number (issue 4 & 5)
--   • Teacher sign-up -> auto-extract into Staff on approval (issue 4)
--   • Promotions: term-average column for automated promotion (issue 10)
--   • Digital library + reading scores that count toward grades (issue 9)
--   • Helpful indexes
-- Depends on tables created by schema.sql / enhancements-schema.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Safety: make sure prerequisite objects exist (no-ops if present)
-- ---------------------------------------------------------------------
create extension if not exists "uuid-ossp";

-- is_staff() helper is created in the other schema files; create a fallback
-- so this file is also runnable standalone in a fresh database.
create or replace function public.is_staff(uid uuid)
returns boolean language sql stable security definer as $$
  select exists(
    select 1 from public.profiles p
    where p.id = uid
      and p.role in ('staff','head_teacher','bursar','principal','proprietor','admin')
      and coalesce(p.status,'approved') = 'approved'
  );
$$;

-- ---------------------------------------------------------------------
-- 1. STAFF — richer details (issue 4) + auto staff number (issue 5)
-- ---------------------------------------------------------------------
alter table public.staff add column if not exists staff_no       text;
alter table public.staff add column if not exists staff_type     text default 'teaching';   -- teaching | non-teaching
alter table public.staff add column if not exists subject_taught text;
alter table public.staff add column if not exists qualification  text;
alter table public.staff add column if not exists religion       text;
alter table public.staff add column if not exists marital_status text;
alter table public.staff add column if not exists gender         text;
alter table public.staff add column if not exists date_of_birth  date;
alter table public.staff add column if not exists address        text;
alter table public.staff add column if not exists profile_id     uuid;   -- links to the auth profile (issue 4)

create unique index if not exists staff_no_uniq on public.staff (staff_no) where staff_no is not null;

-- Auto-generate STF/<year>/0001 on insert when blank (issue 5)
create or replace function public.gen_staff_no()
returns trigger language plpgsql security definer as $$
declare s public.school_settings; pfx text; nxt int; yr text := to_char(now(),'YYYY');
begin
  if new.staff_no is null or new.staff_no = '' then
    update public.school_settings set staff_next = staff_next + 1, updated_at = now()
      where id = 1 returning staff_prefix, staff_next into pfx, nxt;
    if pfx is null then
      insert into public.school_settings(id, staff_next) values (1, 2)
        on conflict (id) do update set staff_next = public.school_settings.staff_next + 1
        returning staff_prefix, staff_next into pfx, nxt;
    end if;
    new.staff_no := coalesce(pfx,'STF') || '/' || yr || '/' || lpad((nxt-1)::text, 4, '0');
  end if;
  return new;
end; $$;
drop trigger if exists trg_gen_staff_no on public.staff;
create trigger trg_gen_staff_no before insert on public.staff
  for each row execute function public.gen_staff_no();

-- ---------------------------------------------------------------------
-- 2. TEACHER / STAFF SIGN-UP -> AUTO-EXTRACT INTO STAFF (issue 4)
-- When a profile with a staff-type role is APPROVED, automatically create a
-- matching row in public.staff (if one does not already exist). The admin can
-- then enrich the record. Updating to non-staff role does nothing.
-- ---------------------------------------------------------------------
create or replace function public.extract_staff_from_profile()
returns trigger language plpgsql security definer as $$
declare is_teaching boolean;
begin
  if new.status = 'approved'
     and new.role in ('staff','head_teacher','bursar','principal','proprietor','teacher')
     and not exists (select 1 from public.staff st where st.profile_id = new.id
                       or (new.email is not null and st.email = new.email)) then
    is_teaching := new.role in ('staff','head_teacher','principal','teacher');
    insert into public.staff (full_name, email, role, staff_type, status, profile_id)
    values (coalesce(new.full_name, split_part(new.email,'@',1)),
            new.email,
            new.role,
            case when new.role in ('bursar','proprietor') then 'non-teaching' else 'teaching' end,
            'active',
            new.id);
  end if;
  return new;
end; $$;
drop trigger if exists trg_extract_staff_from_profile on public.profiles;
create trigger trg_extract_staff_from_profile after update on public.profiles
  for each row execute function public.extract_staff_from_profile();

-- ---------------------------------------------------------------------
-- 3. PROMOTIONS — term-average column for AUTOMATED promotion (issue 10)
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.promotions') is not null then
    alter table public.promotions add column if not exists average numeric;
    alter table public.promotions add column if not exists status  text default 'draft';
  else
    create table public.promotions (
      id uuid primary key default uuid_generate_v4(),
      student_name text,
      from_class text,
      to_class text,
      action text default 'promote',
      average numeric,
      status text default 'draft',
      session text,
      term text,
      created_at timestamptz default now()
    );
    alter table public.promotions enable row level security;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. DIGITAL LIBRARY (issue 9)
-- Teachers post an online book/link with optional comprehension questions.
-- Students read it, optionally answer questions; the auto-marked score is
-- written to reading_scores and can be pushed into results as CA.
-- ---------------------------------------------------------------------
create table if not exists public.digital_library (
  id uuid primary key default uuid_generate_v4(),
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
alter table public.digital_library enable row level security;
create index if not exists digital_library_class_idx on public.digital_library (class);

create table if not exists public.reading_scores (
  id uuid primary key default uuid_generate_v4(),
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
alter table public.reading_scores enable row level security;
create index if not exists reading_scores_student_idx on public.reading_scores (student_name);

-- ---------------------------------------------------------------------
-- 5. RLS POLICIES (authenticated read; staff write; reading scores writable
--    by any authenticated student so they can submit their own quiz result)
-- ---------------------------------------------------------------------
do $$
declare t text;
declare staff_rw text[] := array['digital_library'];
begin
  foreach t in array staff_rw loop
    execute format('drop policy if exists "uv1_read_%s"  on public.%I', t, t);
    execute format('drop policy if exists "uv1_write_%s" on public.%I', t, t);
    execute format('create policy "uv1_read_%s"  on public.%I for select using (auth.role()=''authenticated'')', t, t);
    execute format('create policy "uv1_write_%s" on public.%I for all    using (public.is_staff(auth.uid()))', t, t);
  end loop;
end $$;

drop policy if exists "uv1_rs_read"   on public.reading_scores;
drop policy if exists "uv1_rs_insert" on public.reading_scores;
drop policy if exists "uv1_rs_manage" on public.reading_scores;
create policy "uv1_rs_read"   on public.reading_scores for select using (auth.role()='authenticated');
create policy "uv1_rs_insert" on public.reading_scores for insert with check (auth.role()='authenticated');
create policy "uv1_rs_manage" on public.reading_scores for update using (public.is_staff(auth.uid()));

-- promotions policies (idempotent)
drop policy if exists "uv1_prom_read"  on public.promotions;
drop policy if exists "uv1_prom_write" on public.promotions;
create policy "uv1_prom_read"  on public.promotions for select using (auth.role()='authenticated');
create policy "uv1_prom_write" on public.promotions for all    using (public.is_staff(auth.uid()));

select 'School Connect — Update v1 schema installed ✅' as status;
