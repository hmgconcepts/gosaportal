-- ============================================================
-- SUPABASE FREE-TIER KEEP-ALIVE (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Supabase pauses free-tier projects after ~7 days without
-- DATABASE activity. This installs a tiny heartbeat table and
-- a public RPC that performs a real write. It is called
-- automatically by:
--   1. assets/js/app.js       (once per visitor per 24h)
--   2. .github/workflows/keep-supabase-alive.yml (Mon & Thu)
--   3. supabase/functions/ping (UptimeRobot / Vercel cron)
--   4. pg_cron (internal DB scheduler, if available)
-- This file is ALREADY included inside complete-schema.sql;
-- run it standalone only on databases installed before this
-- feature existed.
-- ============================================================

create table if not exists public.sc_heartbeat (
  id          integer primary key,
  last_ping   timestamptz not null default now(),
  last_source text,
  ping_count  bigint not null default 0
);

alter table public.sc_heartbeat enable row level security;
-- No direct table policies: the table is only reachable through the RPC below.
revoke all on table public.sc_heartbeat from anon, authenticated;

insert into public.sc_heartbeat (id) values (1) on conflict (id) do nothing;

create or replace function public.sc_keep_alive(src text default 'unknown')
returns timestamptz
language sql
security definer
set search_path = public
as $keepalive$
  update public.sc_heartbeat
     set last_ping   = now(),
         last_source = left(coalesce(src, 'unknown'), 40),
         ping_count  = ping_count + 1
   where id = 1
  returning last_ping;
$keepalive$;

grant execute on function public.sc_keep_alive(text) to anon, authenticated;

-- ------------------------------------------------------------
-- Layer 4 (fully internal): pg_cron heartbeat every 2 days.
-- pg_cron is available on Supabase; internal scheduled queries
-- also count as database activity. Wrapped so installation
-- never fails on databases where pg_cron is unavailable.
-- ------------------------------------------------------------
do $cronsetup$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron;
      perform cron.unschedule(jobid) from cron.job where jobname = 'sc-keep-alive';
      perform cron.schedule('sc-keep-alive', '23 5 */2 * *', $job$select public.sc_keep_alive('pg_cron')$job$);
      raise notice 'sc-keep-alive pg_cron job scheduled (every 2 days at 05:23 UTC).';
    exception when others then
      raise notice 'pg_cron keep-alive not scheduled (%). External heartbeats still protect the project.', sqlerrm;
    end;
  else
    raise notice 'pg_cron extension not available; relying on site-visit + GitHub Actions + UptimeRobot heartbeats.';
  end if;
end
$cronsetup$;

select 'Supabase keep-alive heartbeat installed ✅' as status;
