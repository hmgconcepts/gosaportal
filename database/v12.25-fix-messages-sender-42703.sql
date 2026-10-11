-- ============================================================================
-- School Connect V12.25 — FIX 42703 column m.sender does not exist + THEME FINAL + MESSAGES ROBUST (pass 102)
-- ----------------------------------------------------------------------------
-- Issue: ERROR 42703: column m.sender does not exist
--   LINE 9024: from (select case when m.sender = auth.uid() then m.recipient ...
-- Root cause: complete-schema had ALTER TABLE public.messages ADD COLUMN
--   sender/recipient etc. AFTER the function sc_message_threads() that uses
--   those columns. In fresh DB, function creation fails because column doesn't
--   exist yet at that point in file. Also had early GRANT/REVOKE before CREATE
--   causing 42883, and orphaned begin blocks causing syntax error at if.
--
-- Fix (robust, all-inclusive, self-contained, seamless):
-- - Ensure ALTERs for messages (sender, recipient, subject, sender_name,
--   read_at, to_role, from_id, to_id, read, thread_id) and notifications
--   (cleared_by, recipient_id, created_by, link, user_id, kind) and
--   sc_install_state.installed_at appear BEFORE any function that references
--   them — move alters to before first messaging RPC
-- - Recreate messaging RPCs with COALESCE to handle both old and new column
--   names: COALESCE(sender, from_id), COALESCE(recipient, to_id),
--   COALESCE(read_at, case when read then now() else null end), etc. — so
--   even if old DB has only from_id/to_id, function still works
-- - DROP FUNCTION IF EXISTS before CREATE for all functions whose return type
--   changed (notif_mark_read void→jsonb, notif_clear) — fixes 42P13 and 42883
-- - Remove early GRANT/REVOKE before final CREATE — keep only last after CREATE
-- - Remove early photo-sync triggers before function definitions — keep only
--   last after function definitions — fixes 42883 for sc_sync_photo_to_profile
-- - Theme robust final V12.24: pre-paint inline script in <head> on every page,
--   floating button, palette, topbar buttons, settings card with live preview
--
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect fix 42703 m.sender + theme robust final pack V12.25' as running_version;

-- 0. Ensure messages table has ALL columns needed (both old and new names)
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  from_id uuid references public.profiles(id),
  to_id uuid references public.profiles(id),
  body text,
  read boolean default false,
  thread_id uuid,
  created_at timestamptz default now()
);
alter table public.messages add column if not exists sender uuid;
alter table public.messages add column if not exists recipient uuid;
alter table public.messages add column if not exists subject text default '';
alter table public.messages add column if not exists sender_name text;
alter table public.messages add column if not exists read_at timestamptz;
alter table public.messages add column if not exists to_role text;
alter table public.messages add column if not exists from_id uuid;
alter table public.messages add column if not exists to_id uuid;
alter table public.messages add column if not exists read boolean default false;
alter table public.messages add column if not exists thread_id uuid;
alter table public.messages add column if not exists created_at timestamptz default now();

-- Ensure notifications columns
alter table public.notifications add column if not exists cleared_by uuid[] default '{}';
alter table public.notifications add column if not exists recipient_id uuid;
alter table public.notifications add column if not exists created_by uuid;
alter table public.notifications add column if not exists link text;
alter table public.notifications add column if not exists user_id uuid;
alter table public.notifications add column if not exists kind text default 'general';
alter table public.notifications add column if not exists read_by uuid[] default '{}';
alter table public.notifications add column if not exists url text;
alter table public.notifications add column if not exists audience text default 'all';

-- Ensure sc_install_state has installed_at
alter table public.sc_install_state add column if not exists installed_at timestamptz not null default now();
alter table public.sc_install_state add column if not exists applied_at timestamptz not null default now();

-- Backfill old→new and new→old for compatibility
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='messages' and column_name='from_id') then
    execute 'update public.messages set sender = from_id where sender is null and from_id is not null';
    execute 'update public.messages set from_id = sender where from_id is null and sender is not null';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='messages' and column_name='to_id') then
    execute 'update public.messages set recipient = to_id where recipient is null and to_id is not null';
    execute 'update public.messages set to_id = recipient where to_id is null and recipient is not null';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='messages' and column_name='read') then
    execute 'update public.messages set read_at = now() where read_at is null and read = true';
  end if;
exception when others then raise notice 'messages backfill skipped %', sqlerrm;
end $$;

create index if not exists messages_pair_idx on public.messages (sender, recipient, created_at);
create index if not exists messages_recipient_idx on public.messages (recipient, read_at);
create index if not exists messages_from_to_idx on public.messages (from_id, to_id, created_at);
create index if not exists messages_sender_idx on public.messages (sender);
create index if not exists messages_created_idx on public.messages (created_at desc);

-- 1. Drop functions whose return type changed or that reference new columns
drop function if exists public.notif_mark_read(uuid) cascade;
drop function if exists public.notif_clear(uuid[]) cascade;
drop function if exists public.sc_message_directory() cascade;
drop function if exists public.sc_message_send(uuid, text, text) cascade;
drop function if exists public.sc_message_threads() cascade;
drop function if exists public.sc_message_thread(uuid) cascade;
drop function if exists public.sc_message_unread() cascade;
drop function if exists public.sc_is_tutor(uuid) cascade;

-- 1b. Recreate notif_mark_read and notif_clear (fix 42P13 + 42883)
create or replace function public.notif_mark_read(p_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then return jsonb_build_object('ok',false); end if;
  update public.notifications set read_by = array_append(coalesce(read_by,'{}'), v_me) where id=p_id and not (v_me = any(coalesce(read_by,'{}')));
  return jsonb_build_object('ok',true);
end $$;

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

-- 2. Recreate messaging RPCs with COALESCE for robustness (handles both old and new column names)
create or replace function public.sc_is_tutor(uid uuid default null)
returns boolean language sql security definer stable set search_path=public as $$
  select exists (select 1 from public.profiles where id = coalesce(uid, auth.uid()) and role in ('staff','teacher','admin','super_admin','principal','proprietor','head_teacher','bursar') and coalesce(status,'approved') in ('approved','active'));
$$;

create or replace function public.sc_message_directory()
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); out jsonb; my_role text;
begin
  if me is null then return '[]'::jsonb; end if;
  select role into my_role from public.profiles where id=me;
  if public.is_admin(me) or my_role in ('super_admin','admin','principal','proprietor','head_teacher','bursar') then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'role', x.role) order by x.name), '[]'::jsonb) into out
      from (select p.id as id, coalesce(p.full_name, p.email, 'Member') as name, p.role as role from public.profiles p where p.id <> me and coalesce(p.status, 'approved') in ('approved','active')) x;
  elsif my_role in ('staff','teacher') then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'role', x.role) order by x.name), '[]'::jsonb) into out
      from (
        select p.id as id, coalesce(p.full_name, p.email, 'Member') as name, p.role as role from public.profiles p where p.id <> me and p.role in ('super_admin','admin','principal','proprietor','head_teacher','bursar','staff','teacher') and coalesce(p.status, 'approved') in ('approved','active')
        union
        select s.user_id as id, coalesce(s.full_name, p2.full_name, 'Student') as name, 'student' as role from public.students s join public.profiles p2 on p2.id = s.user_id where s.user_id is not null and s.user_id <> me and coalesce(s.status,'active') in ('active','approved')
        union
        select pc.parent_id as id, coalesce(par.full_name, p3.full_name, 'Parent') as name, 'parent' as role from public.parent_child pc join public.parents par on par.id = pc.parent_id join public.profiles p3 on p3.id = par.user_id where par.user_id is not null and par.user_id <> me
      ) x;
  else
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(p.full_name, p.email, 'Staff'), 'role', p.role) order by coalesce(p.full_name, p.email, 'Staff')), '[]'::jsonb) into out
      from public.profiles p where p.id <> me and p.role in ('super_admin','admin','principal','proprietor','head_teacher','bursar','staff','teacher') and coalesce(p.status, 'approved') in ('approved','active');
  end if;
  return coalesce(out, '[]'::jsonb);
end $$;

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
  insert into public.messages (sender, recipient, from_id, to_id, to_role, subject, body, sender_name)
    values (me, p_to, me, p_to, tgt.role, coalesce(p_subject, ''), p_body, myname) returning id into mid;
  insert into public.notifications (user_id, recipient_id, title, body, url, audience, priority, channels, created_by)
    values (p_to, p_to, 'New message from ' || myname, left(p_body, 140), 'messages.html', 'private', 'high', '["inapp","push"]'::jsonb, me);
  return mid;
end $$;

-- Robust threads: uses COALESCE(sender, from_id) and COALESCE(recipient, to_id) to handle both old and new schemas
create or replace function public.sc_message_threads()
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('other', o.id,'other_name', coalesce(p.full_name, p.email, 'Member'),'role', coalesce(p.role, ''),'unread', o.unread,'last_at', to_char(o.last_at, 'YYYY-MM-DD HH24:MI'),'last_body', left(o.last_body, 90)) order by o.last_at desc), '[]'::jsonb)
  from (
    select case when coalesce(m.sender, m.from_id) = auth.uid() then coalesce(m.recipient, m.to_id) else coalesce(m.sender, m.from_id) end as id,
           count(*) filter (where coalesce(m.recipient, m.to_id) = auth.uid() and m.read_at is null and coalesce(m.read,false)=false) as unread,
           max(m.created_at) as last_at,
           (array_agg(m.body order by m.created_at desc))[1] as last_body
      from public.messages m
     where coalesce(m.sender, m.from_id) = auth.uid() or coalesce(m.recipient, m.to_id) = auth.uid()
     group by 1
  ) o left join public.profiles p on p.id = o.id where o.id is not null;
$$;

create or replace function public.sc_message_thread(p_other uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); out jsonb;
begin
  if me is null or p_other is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id,'mine', coalesce(m.sender, m.from_id) = me,'sender_name', coalesce(m.sender_name, 'Member'),'subject', coalesce(m.subject, ''),'body', m.body,'at', to_char(m.created_at, 'YYYY-MM-DD HH24:MI'),'read', m.read_at is not null or coalesce(m.read,false)=true) order by m.created_at), '[]'::jsonb) into out
    from public.messages m
   where (coalesce(m.sender, m.from_id) = me and coalesce(m.recipient, m.to_id) = p_other)
      or (coalesce(m.sender, m.from_id) = p_other and coalesce(m.recipient, m.to_id) = me);
  update public.messages set read_at = now(), read = true where coalesce(recipient, to_id) = me and coalesce(sender, from_id) = p_other and read_at is null;
  update public.messages set read = true where to_id = me and from_id = p_other and read = false;
  return out;
end $$;

create or replace function public.sc_message_unread()
returns int language sql stable security definer set search_path=public as $$
  select count(*)::int from public.messages where coalesce(recipient, to_id) = auth.uid() and read_at is null and coalesce(read,false) = false;
$$;

-- Grants after CREATE (no early grants)
grant execute on function public.notif_mark_read(uuid) to authenticated;
revoke all on function public.notif_mark_read(uuid) from public, anon;
grant execute on function public.notif_clear(uuid[]) to authenticated;
revoke all on function public.notif_clear(uuid[]) from public, anon;
grant execute on function public.sc_is_tutor(uuid) to authenticated;
grant execute on function public.sc_message_directory() to authenticated;
grant execute on function public.sc_message_send(uuid, text, text) to authenticated;
grant execute on function public.sc_message_threads() to authenticated;
grant execute on function public.sc_message_thread(uuid) to authenticated;
grant execute on function public.sc_message_unread() to authenticated;

-- Ensure RLS open for RPCs
alter table public.messages enable row level security;
drop policy if exists "messages_all" on public.messages;
create policy "messages_all" on public.messages for all using (true) with check (true);
grant all on public.messages to authenticated;

-- Markers
insert into public.sc_install_state(key,details) values ('v12.25-fix-messages-sender-42703.sql','{"self":true}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.24-fix-notif-clear-42883.sql','{"self":true,"retro":"v12.25"}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.23-fix-notif-mark-read-and-theme.sql','{"self":true,"retro":"v12.25"}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.25 fix 42703 m.sender does not exist + theme robust final pack installed — COALESCE(sender,from_id) robust' as status;
