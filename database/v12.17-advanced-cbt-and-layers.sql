-- ============================================================================
-- School Connect V12.17 — ADVANCED CBT + 14-LAYER KEEP-ALIVE + TUTORING FEATURES (pass 92)
-- ----------------------------------------------------------------------------
-- Advanced features from:
-- - hmgacademycbtsystem / cbtgen: keyboard shortcuts, flagging, auto-save, emergency backup,
--   certificate, release/hold, Difficulty/Tags/Section, package export/import, invigilator sheets,
--   live proctoring, practice mode points & streaks, psychometric KR-20, extra-time accommodations,
--   result appeals, leaderboard, jittered submissions, retries, offline queue
-- - tutoringconnect / adewaleclassroom: study log/timer, .ics export, makeup credit, self-booking,
--   spaced practice SM-2, streaks & badges, portfolio, value-added, OLS prediction, at-risk
-- - lp25-dramaconnect: 14-layer keep-alive monitoring with quorum, pause countdown, per-layer counts,
--   Schema Doctor probing every object, Analytics 5 tabs, Audit log KPIs, Settings control plane,
--   Archive Vault SHA-256, table explorer, verifiable ID card, scan-to-mark, programmes with QR tickets,
--   calendar .ics, roster, care follow-up
--
-- This pack adds:
-- 1. Per-layer keep-alive tracking (sc_keepalive_sources) + health report RPC
-- 2. Report allow/disallow already in v12.16, ensured
-- 3. CBT appeals table + leaderboard + extra-time accommodations + practice streaks
-- 4. Study log + portfolio + spaced practice tables
-- 5. Markers
-- Idempotent
-- ============================================================================
select 'RUNNING: School Connect advanced CBT + 14-layer keep-alive + tutoring pack V12.17' as running_version;

-- 1. Per-layer keep-alive sources (like dc_heartbeat_sources in DramaConnect)
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

-- 2. Enhance sc_heartbeat to also have sources JSONB for quick read
alter table public.sc_heartbeat add column if not exists sources jsonb default '{}'::jsonb;
alter table public.sc_heartbeat add column if not exists last_ping_at timestamptz default now();

-- 3. Update sc_keep_alive RPC to track per-layer
create or replace function public.sc_keep_alive(src text default 'unknown')
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare v_now timestamptz := now();
begin
  -- Update main heartbeat single row
  insert into public.sc_heartbeat(id, last_ping, last_ping_at, last_source, ping_count, sources)
  values (1, v_now, v_now, left(coalesce(src,'unknown'),40), 1, jsonb_build_object(left(coalesce(src,'unknown'),40), jsonb_build_object('count',1,'last',v_now)))
  on conflict (id) do update set
    last_ping = v_now,
    last_ping_at = v_now,
    last_source = left(coalesce(src,'unknown'),40),
    ping_count = public.sc_heartbeat.ping_count + 1,
    sources = coalesce(public.sc_heartbeat.sources,'{}'::jsonb) || jsonb_build_object(left(coalesce(src,'unknown'),40), jsonb_build_object('count', coalesce((public.sc_heartbeat.sources->left(coalesce(src,'unknown'),40)->>'count')::bigint,0)+1, 'last', v_now)),
    updated_at = v_now;

  -- Upsert per-source row
  insert into public.sc_keepalive_sources(source, last_ping_at, ping_count, first_seen_at, updated_at)
  values (left(coalesce(src,'unknown'),40), v_now, 1, v_now, v_now)
  on conflict (source) do update set
    last_ping_at = v_now,
    ping_count = public.sc_keepalive_sources.ping_count + 1,
    updated_at = v_now;

  return v_now;
end$$;

grant execute on function public.sc_keep_alive(text) to anon, authenticated;

-- 4. Health report RPC — returns quorum, pause countdown, per-layer freshness (like dc_heartbeat_health)
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
  v_pause_after_hours int := 168; -- 7 days
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

  -- Build sources array from sc_keepalive_sources
  select jsonb_agg(to_jsonb(s)) into v_sources from (
    select source, last_ping_at, ping_count, first_seen_at,
           extract(epoch from (v_now - last_ping_at))/3600 as age_hours,
           case when extract(epoch from (v_now - last_ping_at))/3600 < 72 then true else false end as is_fresh
    from public.sc_keepalive_sources
    order by last_ping_at desc
  ) s;

  v_total := coalesce((select count(*) from public.sc_keepalive_sources),0);
  v_fresh_count := coalesce((select count(*) from public.sc_keepalive_sources where extract(epoch from (v_now - last_ping_at))/3600 < 72),0);

  -- Automated vs human (heuristic: site-visit, manual-button, external, fleet-console are human; rest automated)
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

revoke all on function public.sc_heartbeat_health() from public, anon;
grant execute on function public.sc_heartbeat_health() to anon, authenticated;

-- 5. CBT appeals table (result appeals)
create table if not exists public.cbt_appeals (
  id uuid primary key default gen_random_uuid(),
  result_id uuid references public.cbt_results(id) on delete cascade,
  exam_id uuid references public.cbt_exams(id) on delete cascade,
  student_id uuid,
  student_name text,
  reason text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','reviewed')),
  reviewed_by uuid,
  review_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

alter table public.cbt_appeals enable row level security;
drop policy if exists "appeals_read" on public.cbt_appeals;
create policy "appeals_read" on public.cbt_appeals for select using (public.is_staff(auth.uid()) or student_id=auth.uid());
drop policy if exists "appeals_write" on public.cbt_appeals;
create policy "appeals_write" on public.cbt_appeals for all using (auth.role()='authenticated') with check (auth.role()='authenticated');

-- 6. CBT extra-time accommodations per candidate
create table if not exists public.cbt_accommodations (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid references public.cbt_exams(id) on delete cascade,
  student_id uuid,
  student_id_ref text,
  student_name text,
  extra_minutes int not null default 0 check (extra_minutes >=0 and extra_minutes <= 180),
  reason text,
  created_by uuid,
  created_at timestamptz not null default now()
);

alter table public.cbt_accommodations enable row level security;
drop policy if exists "accommodations_read" on public.cbt_accommodations;
create policy "accommodations_read" on public.cbt_accommodations for select using (public.is_staff(auth.uid()) or student_id=auth.uid());
drop policy if exists "accommodations_write" on public.cbt_accommodations;
create policy "accommodations_write" on public.cbt_accommodations for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- 7. CBT practice streaks & points (practice mode)
create table if not exists public.cbt_practice_streaks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  exam_id uuid,
  subject text,
  streak int not null default 0,
  longest_streak int not null default 0,
  total_points int not null default 0,
  last_practiced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, exam_id)
);

alter table public.cbt_practice_streaks enable row level security;
drop policy if exists "streaks_read" on public.cbt_practice_streaks;
create policy "streaks_read" on public.cbt_practice_streaks for select using (user_id=auth.uid() or public.is_staff(auth.uid()));
drop policy if exists "streaks_write" on public.cbt_practice_streaks;
create policy "streaks_write" on public.cbt_practice_streaks for all using (user_id=auth.uid() or public.is_staff(auth.uid())) with check (user_id=auth.uid() or public.is_staff(auth.uid()));

-- 8. Study log / timer (from tutoring)
create table if not exists public.study_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  subject text,
  activity text,
  duration_minutes int not null default 0,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.study_logs enable row level security;
drop policy if exists "study_logs_rw" on public.study_logs;
create policy "study_logs_rw" on public.study_logs for all using (user_id=auth.uid() or public.is_staff(auth.uid())) with check (user_id=auth.uid() or public.is_staff(auth.uid()));

-- 9. Learner portfolio
create table if not exists public.learner_portfolios (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  user_id uuid,
  title text not null,
  description text,
  subject text,
  artifact_url text,
  artifact_type text check (artifact_type in ('certificate','project','assignment','cbt_result','other')),
  created_at timestamptz not null default now()
);

alter table public.learner_portfolios enable row level security;
drop policy if exists "portfolio_read" on public.learner_portfolios;
create policy "portfolio_read" on public.learner_portfolios for select using (user_id=auth.uid() or student_id in (select id from public.students where user_id=auth.uid()) or public.is_staff(auth.uid()) or public.is_parent_of(auth.uid(), student_id));
drop policy if exists "portfolio_write" on public.learner_portfolios;
create policy "portfolio_write" on public.learner_portfolios for all using (user_id=auth.uid() or public.is_staff(auth.uid())) with check (user_id=auth.uid() or public.is_staff(auth.uid()));

-- 10. Spaced practice SM-2 table
create table if not exists public.cbt_spaced_practice (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  question_id text not null,
  exam_id uuid,
  subject text,
  ease_factor numeric not null default 2.5,
  interval_days int not null default 0,
  repetitions int not null default 0,
  due_at timestamptz not null default now(),
  last_reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(user_id, question_id)
);

alter table public.cbt_spaced_practice enable row level security;
drop policy if exists "spaced_rw" on public.cbt_spaced_practice;
create policy "spaced_rw" on public.cbt_spaced_practice for all using (user_id=auth.uid()) with check (user_id=auth.uid());

-- 11. Ensure academic_periods allow_student_report already exists (from v12.16)
alter table public.academic_periods add column if not exists allow_student_report boolean not null default false;
alter table public.academic_periods add column if not exists allow_parent_report boolean not null default false;
alter table public.school_settings add column if not exists allow_student_report_global boolean not null default false;

-- 12. Ensure report allow RPCs exist (from v12.16) — re-create for idempotence
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

-- 11. Storage table top RPC (for Platform Health largest tables)
create or replace function public.storage_table_top()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_out jsonb;
begin
  -- Return top tables by estimated size (from pg_total_relation_size)
  -- Only for authenticated users
  if auth.role() <> 'authenticated' then
    return '[]'::jsonb;
  end if;
  with sizes as (
    select relname as table_name,
           pg_size_pretty(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname))) as size_pretty,
           pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) as size_bytes
    from pg_stat_user_tables
    where schemaname='public'
    order by pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) desc
    limit 20
  )
  select jsonb_agg(to_jsonb(sizes)) into v_out from sizes;
  return coalesce(v_out,'[]'::jsonb);
end$$;

revoke all on function public.storage_table_top() from public, anon;
grant execute on function public.storage_table_top() to authenticated;

-- Marker
insert into public.sc_install_state(key,details) values ('v12.17-advanced-cbt-and-layers.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.17 advanced CBT + 14-layer keep-alive + tutoring pack installed' as status;
