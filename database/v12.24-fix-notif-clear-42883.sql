-- ============================================================================
-- School Connect V12.24 — FIX 42883 notif_clear does not exist + THEME ROBUST FINAL (pass 101)
-- ----------------------------------------------------------------------------
-- Issue: ERROR 42883: function public.notif_clear(uuid[]) does not exist
--   when running complete-schema.sql
-- Root cause: complete-schema had GRANT/REVOKE for notif_clear(uuid[]) BEFORE
--   its CREATE (early grants). In fresh DB, function doesn't exist yet →
--   GRANT/REVOKE fails with 42883. Also had orphaned begin...end blocks
--   without function header causing syntax error at or near "if".
--
-- Fix:
-- - Remove ALL early GRANT/REVOKE for notif_clear, notif_mark_read,
--   sc_message_*, sc_is_tutor, sc_photo_sync_status, sc_installed_packs,
--   sc_keep_alive, sc_heartbeat_health, storage_table_top that appear BEFORE
--   their final CREATE — keep only last grant/revoke AFTER final CREATE
-- - Ensure DROP FUNCTION IF EXISTS for all functions whose return type
--   changed (notif_mark_read void→jsonb) BEFORE CREATE — fixes 42P13
-- - Ensure complete-schema parses OK via pglast (1993 stmts)
-- - Theme robust final: pre-paint inline script in <head> on every page,
--   floating button bottom-left, command palette Ctrl+K, settings card with
--   12 presets + WCAG guard, topbar buttons 🌙 + 🎨 on every page
--
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect fix 42883 notif_clear + theme robust final pack V12.24' as running_version;

-- 0. Fix 42883: drop functions first (idempotent)
drop function if exists public.notif_mark_read(uuid) cascade;
drop function if exists public.notif_mark_read(text) cascade;
drop function if exists public.notif_mark_read() cascade;
drop function if exists public.notif_clear(uuid[]) cascade;
drop function if exists public.notif_clear() cascade;
drop function if exists public.sc_message_directory() cascade;
drop function if exists public.sc_message_send(uuid, text, text) cascade;
drop function if exists public.sc_message_threads() cascade;
drop function if exists public.sc_message_thread(uuid) cascade;
drop function if exists public.sc_message_unread() cascade;
drop function if exists public.sc_is_tutor(uuid) cascade;
drop function if exists public.sc_photo_sync_status() cascade;
drop function if exists public.sc_installed_packs() cascade;
drop function if exists public.sc_keep_alive(text) cascade;
drop function if exists public.sc_heartbeat_health() cascade;
drop function if exists public.storage_table_top() cascade;

-- 1. notif_mark_read returns jsonb (new)
create or replace function public.notif_mark_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then return jsonb_build_object('ok',false); end if;
  update public.notifications set read_by = array_append(coalesce(read_by,'{}'), v_me) where id=p_id and not (v_me = any(coalesce(read_by,'{}')));
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.notif_mark_read(uuid) to authenticated;
revoke all on function public.notif_mark_read(uuid) from public, anon;

-- 2. notif_clear
create or replace function public.notif_clear(p_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_deleted integer :=0; v_hidden integer :=0;
begin
  if v_me is null then return 0; end if;
  delete from public.notifications where (user_id = v_me or recipient_id = v_me or created_by = v_me) and (p_ids is null or id = any(p_ids));
  get diagnostics v_deleted = row_count;
  update public.notifications set cleared_by = array_append(coalesce(cleared_by, '{}'), v_me)
   where not (v_me = any(coalesce(cleared_by, '{}'))) and (p_ids is null or id = any(p_ids))
     and user_id is distinct from v_me and recipient_id is distinct from v_me and created_by is distinct from v_me;
  get diagnostics v_hidden = row_count;
  return v_deleted + v_hidden;
end $$;
grant execute on function public.notif_clear(uuid[]) to authenticated;
revoke all on function public.notif_clear(uuid[]) from public, anon;

-- 3. sc_installed_packs open
create or replace function public.sc_installed_packs()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_out jsonb;
begin
  select jsonb_agg(to_jsonb(t)) into v_out from (select key, details, installed_at from public.sc_install_state order by installed_at desc) t;
  return coalesce(v_out,'[]'::jsonb);
end$$;
grant execute on function public.sc_installed_packs() to anon, authenticated;

-- 4. sc_photo_sync_status
create or replace function public.sc_photo_sync_status()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_has_fn1 boolean; v_has_fn2 boolean; v_has_fn3 boolean; v_has_trig1 boolean; v_has_trig2 boolean; v_has_trig3 boolean; v_marker boolean;
begin
  v_has_fn1 := to_regprocedure('public.sc_sync_photo_to_profile()') is not null;
  v_has_fn2 := to_regprocedure('public.sc_sync_photo_to_student()') is not null;
  v_has_fn3 := to_regprocedure('public.sc_sync_staff_photo_to_profile()') is not null;
  select exists(select 1 from pg_trigger where tgname='trg_students_photo_sync') into v_has_trig1;
  select exists(select 1 from pg_trigger where tgname='trg_profiles_photo_sync') into v_has_trig2;
  select exists(select 1 from pg_trigger where tgname='trg_staff_photo_sync') into v_has_trig3;
  select exists(select 1 from public.sc_install_state where key='v12.2-photo-sync.sql') into v_marker;
  return jsonb_build_object('ok', v_has_fn1 and v_has_fn2 and v_has_trig1 and v_has_trig2, 'functions', jsonb_build_object('sc_sync_photo_to_profile', v_has_fn1, 'sc_sync_photo_to_student', v_has_fn2, 'sc_sync_staff_photo_to_profile', v_has_fn3), 'triggers', jsonb_build_object('trg_students_photo_sync', v_has_trig1, 'trg_profiles_photo_sync', v_has_trig2, 'trg_staff_photo_sync', v_has_trig3), 'marker_present', v_marker, 'checked_at', now());
end$$;
grant execute on function public.sc_photo_sync_status() to anon, authenticated;

-- 5. sc_keep_alive + heartbeat_health + storage_table_top (ensure no early grants)
create or replace function public.sc_keep_alive(src text default 'unknown')
returns timestamptz language plpgsql security definer set search_path=public as $$
declare v_now timestamptz := now(); v_src text := left(coalesce(src,'unknown'),40); v_count bigint;
begin
  select coalesce((sources->v_src->>'count')::bigint,0) into v_count from public.sc_heartbeat where id=1;
  insert into public.sc_heartbeat(id, last_ping, last_ping_at, last_source, ping_count, sources, updated_at)
  values (1, v_now, v_now, v_src, 1, jsonb_build_object(v_src, jsonb_build_object('count',1,'last',v_now)), v_now)
  on conflict (id) do update set last_ping=v_now, last_ping_at=v_now, last_source=v_src, ping_count=public.sc_heartbeat.ping_count+1, sources=coalesce(public.sc_heartbeat.sources,'{}'::jsonb) || jsonb_build_object(v_src, jsonb_build_object('count', v_count+1, 'last', v_now)), updated_at=v_now;
  insert into public.sc_keepalive_sources(source, last_ping_at, ping_count, first_seen_at, updated_at)
  values (v_src, v_now, 1, v_now, v_now)
  on conflict (source) do update set last_ping_at=v_now, ping_count=public.sc_keepalive_sources.ping_count+1, updated_at=v_now;
  return v_now;
end$$;
grant execute on function public.sc_keep_alive(text) to anon, authenticated;

create or replace function public.sc_heartbeat_health()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_main record; v_sources jsonb := '[]'::jsonb; v_now timestamptz := now(); v_pause_after_hours int := 168; v_last_ping timestamptz; v_age_hours numeric; v_fresh_count int :=0; v_total int :=0; v_automated_fresh int :=0; v_automated_total int :=0; v_quorum boolean := false; v_single_point boolean := false; v_status text := 'healthy';
begin
  select * into v_main from public.sc_heartbeat where id=1;
  if not found then return jsonb_build_object('ok',false,'status','no-heartbeat','pauseAfterHours',v_pause_after_hours); end if;
  v_last_ping := coalesce(v_main.last_ping_at, v_main.last_ping, v_now);
  v_age_hours := extract(epoch from (v_now - v_last_ping))/3600;
  select jsonb_agg(to_jsonb(s)) into v_sources from (select source, last_ping_at, ping_count, first_seen_at, extract(epoch from (v_now - last_ping_at))/3600 as age_hours, case when extract(epoch from (v_now - last_ping_at))/3600 < 72 then true else false end as is_fresh from public.sc_keepalive_sources order by last_ping_at desc) s;
  v_total := coalesce((select count(*) from public.sc_keepalive_sources),0);
  v_fresh_count := coalesce((select count(*) from public.sc_keepalive_sources where extract(epoch from (v_now - last_ping_at))/3600 < 72),0);
  v_automated_total := coalesce((select count(*) from public.sc_keepalive_sources where source not in ('site-visit','manual-button','external','fleet-console')),0);
  v_automated_fresh := coalesce((select count(*) from public.sc_keepalive_sources where source not in ('site-visit','manual-button','external','fleet-console') and extract(epoch from (v_now - last_ping_at))/3600 < 72),0);
  v_quorum := v_fresh_count >=2;
  v_single_point := v_fresh_count =1;
  if v_age_hours > 168 then v_status := 'paused'; elsif v_age_hours > 144 then v_status := 'critical'; elsif v_age_hours > 120 then v_status := 'warning'; elsif v_single_point then v_status := 'single-point'; elsif v_automated_fresh <2 and v_fresh_count>=2 then v_status := 'human-only'; else v_status := 'healthy'; end if;
  return jsonb_build_object('ok', true, 'status', v_status, 'lastPing', v_last_ping, 'lastSource', v_main.last_source, 'pingCount', v_main.ping_count, 'ageHours', v_age_hours, 'daysUntilPause', greatest(0, (v_pause_after_hours - v_age_hours)/24), 'pauseAfterHours', v_pause_after_hours, 'sources', coalesce(v_sources,'[]'::jsonb), 'sourcesFresh', v_fresh_count, 'sourcesTotal', v_total, 'automatedSourcesFresh', v_automated_fresh, 'automatedSourcesTotal', v_automated_total, 'quorum', v_quorum, 'singlePointOfFailure', v_single_point);
end$$;
grant execute on function public.sc_heartbeat_health() to anon, authenticated;

create or replace function public.storage_table_top()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_out jsonb;
begin
  if auth.role() <> 'authenticated' then return '[]'::jsonb; end if;
  with sizes as (select relname as table_name, pg_size_pretty(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname))) as size_pretty, pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) as size_bytes from pg_stat_user_tables where schemaname='public' order by pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) desc limit 20)
  select jsonb_agg(to_jsonb(sizes)) into v_out from sizes;
  return coalesce(v_out,'[]'::jsonb);
end$$;
grant execute on function public.storage_table_top() to authenticated;

-- 6. Messaging RPCs (ensure after DROP)
create or replace function public.sc_is_tutor(uid uuid default null)
returns boolean language sql security definer stable set search_path=public as $$
  select exists (select 1 from public.profiles where id = coalesce(uid, auth.uid()) and role in ('staff','teacher','admin','super_admin','principal','proprietor','head_teacher','bursar') and coalesce(status,'approved') in ('approved','active'));
$$;
grant execute on function public.sc_is_tutor(uuid) to authenticated;

create or replace function public.sc_message_directory()
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); out jsonb; my_role text;
begin
  if me is null then return '[]'::jsonb; end if;
  select role into my_role from public.profiles where id=me;
  if public.is_admin(me) or my_role in ('super_admin','admin','principal','proprietor','head_teacher','bursar') then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'role', x.role) order by x.name), '[]'::jsonb) into out from (select p.id as id, coalesce(p.full_name, p.email, 'Member') as name, p.role as role from public.profiles p where p.id <> me and coalesce(p.status, 'approved') in ('approved','active')) x;
  elsif my_role in ('staff','teacher') then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'role', x.role) order by x.name), '[]'::jsonb) into out from (
        select p.id as id, coalesce(p.full_name, p.email, 'Member') as name, p.role as role from public.profiles p where p.id <> me and p.role in ('super_admin','admin','principal','proprietor','head_teacher','bursar','staff','teacher') and coalesce(p.status, 'approved') in ('approved','active')
        union
        select s.user_id as id, coalesce(s.full_name, p2.full_name, 'Student') as name, 'student' as role from public.students s join public.profiles p2 on p2.id = s.user_id where s.user_id is not null and s.user_id <> me and coalesce(s.status,'active') in ('active','approved')
        union
        select pc.parent_id as id, coalesce(par.full_name, p3.full_name, 'Parent') as name, 'parent' as role from public.parent_child pc join public.parents par on par.id = pc.parent_id join public.profiles p3 on p3.id = par.user_id where par.user_id is not null and par.user_id <> me
      ) x;
  else
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(p.full_name, p.email, 'Staff'), 'role', p.role) order by coalesce(p.full_name, p.email, 'Staff')), '[]'::jsonb) into out from public.profiles p where p.id <> me and p.role in ('super_admin','admin','principal','proprietor','head_teacher','bursar','staff','teacher') and coalesce(p.status, 'approved') in ('approved','active');
  end if;
  return coalesce(out, '[]'::jsonb);
end $$;
grant execute on function public.sc_message_directory() to authenticated;

create or replace function public.sc_message_send(p_to uuid, p_subject text, p_body text)
returns uuid language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); tgt public.profiles%rowtype; mid uuid; myname text; my_role text;
begin
  if me is null then raise exception 'Please sign in first.'; end if;
  if p_to is null or p_to = me then raise exception 'Pick a recipient first.'; end if;
  p_body := coalesce(btrim(p_body), '');
  if length(p_body) < 1 then raise exception 'Write a message first.'; end if;
  if length(p_body) > 5000 then raise exception 'Messages are limited to 5000 characters.'; end if;
  if length(coalesce(p_subject, '')) > 200 then p_subject := left(p_subject, 200); end if;
  select * into tgt from public.profiles where id = p_to;
  if tgt.id is null then raise exception 'That recipient no longer has an account.'; end if;
  select role into my_role from public.profiles where id=me;
  if my_role in ('student','parent') then
    if tgt.role not in ('super_admin','admin','principal','proprietor','head_teacher','bursar','staff','teacher') then raise exception 'You can message your tutors and the admins from here.'; end if;
  end if;
  select coalesce(full_name, email, 'Member') into myname from public.profiles where id = me;
  insert into public.messages (sender, recipient, from_id, to_id, to_role, subject, body, sender_name) values (me, p_to, me, p_to, tgt.role, coalesce(p_subject, ''), p_body, myname) returning id into mid;
  insert into public.notifications (user_id, recipient_id, title, body, url, audience, priority, channels, created_by) values (p_to, p_to, 'New message from ' || myname, left(p_body, 140), 'messages.html', 'private', 'high', '["inapp","push"]'::jsonb, me);
  return mid;
end $$;
grant execute on function public.sc_message_send(uuid, text, text) to authenticated;

create or replace function public.sc_message_threads()
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('other', o.id,'other_name', coalesce(p.full_name, p.email, 'Member'),'role', coalesce(p.role, ''),'unread', o.unread,'last_at', to_char(o.last_at, 'YYYY-MM-DD HH24:MI'),'last_body', left(o.last_body, 90)) order by o.last_at desc), '[]'::jsonb)
  from (select case when m.sender = auth.uid() then m.recipient else m.sender end as id, count(*) filter (where m.recipient = auth.uid() and m.read_at is null) as unread, max(m.created_at) as last_at, (array_agg(m.body order by m.created_at desc))[1] as last_body from public.messages m where m.sender = auth.uid() or m.recipient = auth.uid() group by 1) o left join public.profiles p on p.id = o.id where o.id is not null;
$$;
grant execute on function public.sc_message_threads() to authenticated;

create or replace function public.sc_message_thread(p_other uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); out jsonb;
begin
  if me is null or p_other is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id,'mine', m.sender = me,'sender_name', coalesce(m.sender_name, 'Member'),'subject', coalesce(m.subject, ''),'body', m.body,'at', to_char(m.created_at, 'YYYY-MM-DD HH24:MI'),'read', m.read_at is not null) order by m.created_at), '[]'::jsonb) into out from public.messages m where (m.sender = me and m.recipient = p_other) or (m.sender = p_other and m.recipient = me);
  update public.messages set read_at = now(), read = true where recipient = me and sender = p_other and read_at is null;
  update public.messages set read = true where to_id = me and from_id = p_other and read = false;
  return out;
end $$;
grant execute on function public.sc_message_thread(uuid) to authenticated;

create or replace function public.sc_message_unread()
returns int language sql stable security definer set search_path=public as $$
  select count(*)::int from public.messages where (recipient = auth.uid() or to_id = auth.uid()) and read_at is null and coalesce(read,false) = false;
$$;
grant execute on function public.sc_message_unread() to authenticated;

-- Markers
insert into public.sc_install_state(key,details) values ('v12.24-fix-notif-clear-42883.sql','{"self":true}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.23-fix-notif-mark-read-and-theme.sql','{"self":true,"retro":"v12.24"}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.24 fix 42883 notif_clear + theme robust final pack installed — no early grants, DROP before CREATE' as status;
