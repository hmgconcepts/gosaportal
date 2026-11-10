-- =====================================================================
--  A0. SELF-CONTAINMENT PRELUDE
--
--  The complete schema must be the ONLY script a school ever runs. On Supabase
--  everything below already exists; on a bare Postgres (a data-centre install,
--  a laptop, a test runner) it does not, and the schema would fail on its first
--  `references auth.users(id)`. This block installs the prerequisites if they
--  are missing and does nothing if they are present, so one file works on both.
-- =====================================================================

-- 1. the API roles that every grant and policy names
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    -- only referenced by a couple of ownership statements; absent is fine
    null;
  end if;
end $$;

-- 2. extensions (guarded: a restricted install may not be allowed to add them)
/* Extensions are optional. gen_random_uuid() is core in Postgres 13+, so
   pgcrypto is a safety net for older servers; the other two are nice-to-have.
   Each is attempted independently and a refusal is swallowed, so a restricted
   install that forbids CREATE EXTENSION still boots.
   NOTE: this is the ONLY place in the file that says CREATE EXTENSION, and it
   is deliberately *not* at top level — some driver-level loaders rewrite a
   top-level CREATE EXTENSION into a bare SELECT, which then breaks a
   multi-statement paste. */
do $$ begin
  begin create extension if not exists pgcrypto;    exception when others then null; end;
  begin create extension if not exists "uuid-ossp"; exception when others then null; end;
  begin create extension if not exists pg_trgm;     exception when others then null; end;
end $$;

-- 3. the auth schema, the users table and auth.uid()
--    On Supabase these belong to GoTrue. Here they are created only if absent,
--    and auth.uid() is only defined if it does not already exist — a real
--    Supabase project keeps its own implementation untouched.
do $$ begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'auth') then
    create schema auth;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'auth' and table_name = 'users') then
    create table auth.users (
      id uuid primary key default gen_random_uuid(),
      email text unique,
      encrypted_password text,
      email_confirmed_at timestamptz,
      raw_user_meta_data jsonb default '{}'::jsonb,
      created_at timestamptz default now(),
      updated_at timestamptz default now()
    );
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'auth' and p.proname = 'uid') then
    /* format() keeps the nested dollar-quote unambiguous */
    execute format($fmt$create function auth.uid() returns uuid language sql stable as %s
                     select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
                   %s$fmt$, chr(36)||chr(36), chr(36)||chr(36));
  end if;
end $$;

-- 4. storage schema — a few policies reference storage.objects on Supabase.
--    Created empty only so the references resolve on a bare install.
do $$ begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    create schema storage;
  end if;
end $$;

-- 5. the rest of the GoTrue helper surface the policies reference
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'auth' and p.proname = 'role') then
    create function auth.role() returns text language sql stable as
      $aid$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $aid$;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'auth' and p.proname = 'jwt') then
    create function auth.jwt() returns jsonb language sql stable as
      $aid$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $aid$;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'auth' and p.proname = 'email') then
    create function auth.email() returns text language sql stable as
      $aid$ select coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), '') $aid$;
  end if;
end $$;

-- 6. storage.objects, referenced by a handful of media policies
do $$ begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'storage' and table_name = 'objects') then
    create table storage.objects (
      id uuid primary key default gen_random_uuid(),
      bucket_id text, name text, owner uuid,
      metadata jsonb, created_at timestamptz default now(), updated_at timestamptz default now()
    );
  end if;
end $$;

do $$ begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'storage' and table_name = 'buckets') then
    create table storage.buckets (
      id text primary key, name text, public boolean default false,
      file_size_limit bigint, allowed_mime_types text[],
      created_at timestamptz default now(), updated_at timestamptz default now()
    );
  end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;
