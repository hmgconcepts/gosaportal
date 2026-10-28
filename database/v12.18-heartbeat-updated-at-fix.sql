-- ============================================================================
-- School Connect V12.18 — HEARTBEAT UPDATED_AT FIX + PLATFORM HEALTH ROBUST (pass 94)
-- ----------------------------------------------------------------------------
-- Fixes:
-- 1. Fleet Console error: "column updated_at of relation sc_heartbeat does not exist" when pinging
--    - Root cause: sc_heartbeat table originally had only id, last_ping, last_source, ping_count
--    - V12.17 added sources jsonb and last_ping_at but missed updated_at column, yet sc_keep_alive RPC tried to update updated_at → 42703
--    - This pack adds updated_at + ensures all needed columns exist
-- 2. Platform Health page not reporting layers (Never, 0 count, checking...)
--    - Same root cause: sc_keep_alive fails due to missing updated_at, so sc_keepalive_sources never populated
--    - Also ensures sc_keepalive_sources table exists
--    - Ensures storage_table_top RPC exists
--    - Ensures report allow RPCs exist
-- 3. License section not showing — enhanced to fetch from school_settings + SCHOOL
-- 4. Removes tutoring-specific "Independent Engagements & 4-Cycle Bookings" card not needed in school setting
--
-- Idempotent
-- ============================================================================
select 'RUNNING: School Connect heartbeat updated_at fix + platform health robust pack V12.18' as running_version;

-- Ensure sc_heartbeat has all columns needed for 14-layer tracking
create table if not exists public.sc_heartbeat (
  id integer primary key,
  last_ping timestamptz not null default now(),
  last_source text,
  ping_count bigint not null default 0
);

alter table public.sc_heartbeat add column if not exists last_ping_at timestamptz not null default now();
alter table public.sc_heartbeat add column if not exists sources jsonb default '{}'::jsonb;
alter table public.sc_heartbeat add column if not exists updated_at timestamptz not null default now();

-- Ensure per-layer sources table exists
create table if not exists public.sc_keepalive_sources (
  source text primary key,
  last_ping_at timestamptz not null default now(),
  ping_count bigint not null default 0,
  first_seen_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.sc_keepalive_sources enable row level security;
drop policy if exists "ka_sources_read" on public.sc_keepalive_sources;
create policy "ka_sources_read" on public.sc_keepalive_sources for select using (true);
revoke all on table public.sc_keepalive_sources from anon, authenticated;
grant select on public.sc_keepalive_sources to anon, authenticated;

-- Ensure sc_heartbeat RLS
alter table public.sc_heartbeat enable row level security;
drop policy if exists "hb_read" on public.sc_heartbeat;
create policy "hb_read" on public.sc_heartbeat for select using (true);
revoke all on table public.sc_heartbeat from anon, authenticated;
grant select on public.sc_heartbeat to anon, authenticated;

insert into public.sc_heartbeat(id) values (1) on conflict (id) do nothing;

-- Recreate sc_keep_alive RPC with all columns (robust, idempotent)
create or replace function public.sc_keep_alive(src text default 'unknown')
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare v_now timestamptz := now();
declare v_src text := left(coalesce(src,'unknown'),40);
declare v_count bigint;
begin
  -- Get current count for src from sources jsonb
  select coalesce((sources->v_src->>'count')::bigint,0) into v_count from public.sc_heartbeat where id=1;

  -- Update main heartbeat single row
  insert into public.sc_heartbeat(id, last_ping, last_ping_at, last_source, ping_count, sources, updated_at)
  values (1, v_now, v_now, v_src, 1, jsonb_build_object(v_src, jsonb_build_object('count',1,'last',v_now)), v_now)
  on conflict (id) do update set
    last_ping = v_now,
    last_ping_at = v_now,
    last_source = v_src,
    ping_count = public.sc_heartbeat.ping_count + 1,
    sources = coalesce(public.sc_heartbeat.sources,'{}'::jsonb) || jsonb_build_object(v_src, jsonb_build_object('count', v_count+1, 'last', v_now)),
    updated_at = v_now;

  -- Upsert per-source row
  insert into public.sc_keepalive_sources(source, last_ping_at, ping_count, first_seen_at, updated_at)
  values (v_src, v_now, 1, v_now, v_now)
  on conflict (source) do update set
    last_ping_at = v_now,
    ping_count = public.sc_keepalive_sources.ping_count + 1,
    updated_at = v_now;

  return v_now;
end$$;

grant execute on function public.sc_keep_alive(text) to anon, authenticated;

-- Recreate health report RPC
create or replace function public.sc_heartbeat_health()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_main record;
  v_sources jsonb := '[]'::jsonb;
  v_now timestamptz := now();
  v_pause_after_hours int := 168;
  v_last_ping timestamptz;
  v_age_hours numeric;
  v_fresh_count int :=0;
  v_total int :=0;
  v_automated_fresh int :=0;
  v_automated_total int :=0;
  v_quorum boolean := false;
  v_single_point boolean := false;
  v_status text := 'healthy';
begin
  select * into v_main from public.sc_heartbeat where id=1;
  if not found then
    return jsonb_build_object('ok',false,'status','no-heartbeat','pauseAfterHours',v_pause_after_hours);
  end if;
  v_last_ping := coalesce(v_main.last_ping_at, v_main.last_ping, v_now);
  v_age_hours := extract(epoch from (v_now - v_last_ping))/3600;

  select jsonb_agg(to_jsonb(s)) into v_sources from (
    select source, last_ping_at, ping_count, first_seen_at,
           extract(epoch from (v_now - last_ping_at))/3600 as age_hours,
           case when extract(epoch from (v_now - last_ping_at))/3600 < 72 then true else false end as is_fresh
    from public.sc_keepalive_sources
    order by last_ping_at desc
  ) s;

  v_total := coalesce((select count(*) from public.sc_keepalive_sources),0);
  v_fresh_count := coalesce((select count(*) from public.sc_keepalive_sources where extract(epoch from (v_now - last_ping_at))/3600 < 72),0);
  v_automated_total := coalesce((select count(*) from public.sc_keepalive_sources where source not in ('site-visit','manual-button','external','fleet-console')),0);
  v_automated_fresh := coalesce((select count(*) from public.sc_keepalive_sources where source not in ('site-visit','manual-button','external','fleet-console') and extract(epoch from (v_now - last_ping_at))/3600 < 72),0);

  v_quorum := v_fresh_count >=2;
  v_single_point := v_fresh_count =1;

  if v_age_hours > 168 then v_status := 'paused';
  elsif v_age_hours > 144 then v_status := 'critical';
  elsif v_age_hours > 120 then v_status := 'warning';
  elsif v_single_point then v_status := 'single-point';
  elsif v_automated_fresh <2 and v_fresh_count>=2 then v_status := 'human-only';
  else v_status := 'healthy';
  end if;

  return jsonb_build_object(
    'ok', true,
    'status', v_status,
    'lastPing', v_last_ping,
    'lastSource', v_main.last_source,
    'pingCount', v_main.ping_count,
    'ageHours', v_age_hours,
    'daysUntilPause', greatest(0, (v_pause_after_hours - v_age_hours)/24),
    'pauseAfterHours', v_pause_after_hours,
    'sources', coalesce(v_sources,'[]'::jsonb),
    'sourcesFresh', v_fresh_count,
    'sourcesTotal', v_total,
    'automatedSourcesFresh', v_automated_fresh,
    'automatedSourcesTotal', v_automated_total,
    'quorum', v_quorum,
    'singlePointOfFailure', v_single_point
  );
end$$;

grant execute on function public.sc_heartbeat_health() to anon, authenticated;

-- Storage table top RPC (for Platform Health largest tables)
create or replace function public.storage_table_top()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_out jsonb;
begin
  if auth.role() <> 'authenticated' then return '[]'::jsonb; end if;
  with sizes as (
    select relname as table_name,
           pg_size_pretty(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname))) as size_pretty,
           pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) as size_bytes
    from pg_stat_user_tables where schemaname='public' order by pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) desc limit 20
  )
  select jsonb_agg(to_jsonb(sizes)) into v_out from sizes;
  return coalesce(v_out,'[]'::jsonb);
end$$;

grant execute on function public.storage_table_top() to authenticated;

-- Ensure report allow RPCs exist (from v12.16)
create or replace function public.sc_is_report_generation_allowed(p_term text, p_session text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row record; v_global record;
begin
  if p_session is not null then
    select allow_student_report, allow_parent_report into v_row from public.academic_periods where term=p_term and session=p_session limit 1;
    if found then return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',coalesce(v_row.allow_student_report,false),'allow_parent',coalesce(v_row.allow_parent_report,false),'source','academic_periods'); end if;
  end if;
  select allow_student_report, allow_parent_report into v_row from public.academic_periods where term=p_term order by is_current desc, starts_on desc limit 1;
  if found then return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',coalesce(v_row.allow_student_report,false),'allow_parent',coalesce(v_row.allow_parent_report,false),'source','academic_periods_term'); end if;
  select allow_student_report_global, allow_parent_report_global into v_global from public.school_settings where id=1;
  if found then return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',coalesce(v_global.allow_student_report_global,false),'allow_parent',coalesce(v_global.allow_parent_report_global,false),'source','school_settings_global'); end if;
  return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',false,'allow_parent',false,'source','default_false');
end$$;
grant execute on function public.sc_is_report_generation_allowed(text,text) to anon, authenticated;

create or replace function public.sc_set_report_generation_allowed(p_term text, p_session text, p_allowed boolean, p_allow_parent boolean default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin(auth.uid()) and not public.is_school_leader(auth.uid()) then return jsonb_build_object('ok',false,'error','Only admin/principal can set'); end if;
  if p_term is null or p_term='' then return jsonb_build_object('ok',false,'error','Term required'); end if;
  insert into public.academic_periods(term, session, is_current, allow_student_report, allow_parent_report, starts_on)
  values (p_term, coalesce(p_session, (select session from public.academic_periods where is_current=true limit 1), ''), false, p_allowed, coalesce(p_allow_parent, p_allowed), current_date)
  on conflict (term, session) do update set allow_student_report=excluded.allow_student_report, allow_parent_report=coalesce(excluded.allow_parent_report, public.academic_periods.allow_parent_report);
  if p_session is not null then
    update public.academic_periods set allow_student_report=p_allowed, allow_parent_report=coalesce(p_allow_parent, p_allowed) where term=p_term and session=p_session;
  else
    update public.academic_periods set allow_student_report=p_allowed, allow_parent_report=coalesce(p_allow_parent, p_allowed) where term=p_term;
  end if;
  return jsonb_build_object('ok',true,'term',p_term,'session',p_session,'allowed',p_allowed,'allow_parent',coalesce(p_allow_parent,p_allowed));
end$$;
grant execute on function public.sc_set_report_generation_allowed(text,text,boolean,boolean) to authenticated;

create or replace function public.sc_set_report_generation_global(p_allowed boolean, p_allow_parent boolean default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin(auth.uid()) and not public.is_school_leader(auth.uid()) then return jsonb_build_object('ok',false,'error','Only admin can set global'); end if;
  update public.school_settings set allow_student_report_global=p_allowed, allow_parent_report_global=coalesce(p_allow_parent, p_allowed) where id=1;
  return jsonb_build_object('ok',true,'allowed',p_allowed,'allow_parent',coalesce(p_allow_parent,p_allowed),'scope','global');
end$$;
grant execute on function public.sc_set_report_generation_global(boolean,boolean) to authenticated;

-- Ensure academic_periods columns
alter table public.academic_periods add column if not exists allow_student_report boolean not null default false;
alter table public.academic_periods add column if not exists allow_parent_report boolean not null default false;
alter table public.school_settings add column if not exists allow_student_report_global boolean not null default false;

-- Marker
insert into public.sc_install_state(key,details) values ('v12.18-heartbeat-updated-at-fix.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.18 heartbeat updated_at fix + platform health robust pack installed' as status;
