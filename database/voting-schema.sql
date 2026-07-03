-- =====================================================================
-- School Connect — Voting Schema (Gen v8) — STAND-ALONE & SELF-CONTAINED
-- =====================================================================
-- Run this file on its own to add ONLY the voting/polls feature to an
-- existing Supabase project, OR run the full database/schema.sql which
-- already includes everything below.
--
-- ⚠️  Why v7's voting query failed with:
--        ERROR: 42P01: relation "public.profiles" does not exist
--     The old voting file referenced public.profiles and the is_staff()
--     function WITHOUT guaranteeing they exist first. If you ran the
--     voting file before (or instead of) the main schema, those objects
--     were missing and Postgres aborted on the very first reference.
--
-- ✅  This version creates the minimum dependencies (profiles table +
--     is_staff helper) ONLY IF they are missing, so it can never throw
--     42P01 again — whether run first, last, or on its own.
--
-- Idempotent: safe to re-run any number of times.
-- =====================================================================


-- ========================================================
-- 0. EXTENSIONS
-- ========================================================
create extension if not exists "uuid-ossp";


-- ========================================================
-- 1. DEPENDENCIES (created only if they don't already exist)
--    The voting policies reference public.profiles and is_staff().
-- ========================================================

-- 1a. profiles — minimal version. If you already ran schema.sql this is
--     a no-op because of "if not exists".
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

-- 1b. is_staff() helper — created AFTER profiles exists, so no 42P01.
create or replace function public.is_staff(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','principal','proprietor','head_teacher','staff','teacher','bursar')
      and status in ('approved','active')
  );
$$;


-- ========================================================
-- 2. VOTING TABLES
-- ========================================================
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

-- Column backfill (idempotent) — guarantees columns the RLS policies need
-- exist even if poll_votes/polls were created by an OLDER schema version.
-- Prevents: ERROR: column "voter_id" does not exist.
do $$ begin
  alter table public.poll_votes add column if not exists voter_id uuid;
  alter table public.poll_votes add column if not exists candidate_id text;
  alter table public.poll_votes add column if not exists poll_id uuid;
  alter table public.polls      add column if not exists status text default 'open';
exception when undefined_table then null; end $$;


-- ========================================================
-- 3. RLS POLICIES
-- ========================================================
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


-- ========================================================
-- 4. LIVE-RESULTS VIEW (fixed aggregate — counts votes correctly)
-- ========================================================
-- Drop first so re-runs never hit 42P16 "cannot drop columns from view".
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
-- DONE ✅  Voting schema ready — no 42P01 errors, run standalone or after main schema.
-- =====================================================================
select 'Voting schema v8 ready ✅' as status;
