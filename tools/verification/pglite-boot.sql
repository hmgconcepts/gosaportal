create schema if not exists auth;
create table if not exists auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}'::jsonb, raw_app_meta_data jsonb default '{}'::jsonb, created_at timestamptz default now(), email_confirmed_at timestamptz);
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$;
create or replace function auth.role() returns text language sql stable as $$ select 'anon'::text $$;
create schema if not exists storage;
create table if not exists storage.buckets(id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[], created_at timestamptz default now(), updated_at timestamptz default now());
create table if not exists storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid, metadata jsonb, created_at timestamptz default now(), updated_at timestamptz default now());
do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
do $$ begin create role service_role; exception when duplicate_object then null; end $$;
do $$ begin create role supabase_admin; exception when duplicate_object then null; end $$;
do $$ begin create extension if not exists pg_trgm; exception when others then null; end $$;

-- pg_cron stand-in so the complete schema can be loaded verbatim in tests.
-- (The schema guards its cron block with an availability check; this makes the
-- check pass so the block is exercised rather than skipped.)
create schema if not exists cron;
create table if not exists cron.job(jobid bigserial primary key, jobname text, schedule text, command text);
create or replace function cron.schedule(p_name text, p_sched text, p_cmd text) returns bigint
  language sql as $$ insert into cron.job(jobname,schedule,command) values (p_name,p_sched,p_cmd) returning jobid $$;
create or replace function cron.unschedule(p_jobid bigint) returns boolean
  language sql as $$ delete from cron.job where jobid = p_jobid; select true $$;
