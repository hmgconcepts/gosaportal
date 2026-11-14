-- ============================================================================
-- School Connect V9.0 — User lifecycle: safe directory deletes + full account
-- removal + orphaned-login repair
-- ============================================================================
-- Fixes two live bugs:
--  1. "update or delete on table profiles violates foreign key constraint
--     activity_log_actor_id_fkey" — many audit/author columns (activity_log,
--     recorded_by, posted_by, …) reference profiles(id) with NO on-delete
--     action, so Postgres blocks deleting any person who ever wrote a row.
--     → every such FK is retargeted to ON DELETE SET NULL (audit rows are
--       kept — only the dangling pointer is cleared; actor_email remains).
--  2. "user already registered" when re-signing-up someone who was deleted
--     through the Directory — the old delete removed only the profiles row,
--     leaving a GHOST login in auth.users that blocks the email forever.
--     → sc_delete_user() now removes the whole account (auth.users row
--       included; profiles follows by cascade), and existing ghosts are
--       adopted back into profiles so the admin can see and delete them.
-- Idempotent — safe to run repeatedly.
select 'RUNNING: School Connect user-lifecycle pack V9.0' as running_version;

-- ---------------------------------------------------------------------------
-- 1. Retarget every blocking FK that references public.profiles.
--    Walks the catalog, so it also fixes columns added by older installs.
--    nullable column + NO ACTION/RESTRICT  → ON DELETE SET NULL
--    not-null column                       → left alone, reported via NOTICE
-- ---------------------------------------------------------------------------
do $$
declare c record; nullable boolean;
begin
  for c in
    select con.oid, con.conname, con.conrelid::regclass::text as tbl,
           (select attname from pg_attribute
             where attrelid = con.conrelid and attnum = con.conkey[1]) as col
      from pg_constraint con
     where con.contype = 'f'
       and con.confrelid = 'public.profiles'::regclass
       and con.confdeltype in ('a','r')          -- NO ACTION / RESTRICT only
       and array_length(con.conkey,1) = 1        -- single-column FKs (all of ours)
  loop
    select not attnotnull into nullable
      from pg_attribute a join pg_constraint k on k.conrelid = a.attrelid
     where k.oid = c.oid and a.attnum = k.conkey[1];
    if coalesce(nullable,false) then
      begin
        execute format('alter table %s drop constraint %I', c.tbl, c.conname);
        execute format('alter table %s add constraint %I foreign key (%I) references public.profiles(id) on delete set null',
                       c.tbl, c.conname, c.col);
        raise notice 'FK % on %.% → ON DELETE SET NULL', c.conname, c.tbl, c.col;
      exception when others then
        raise notice 'Could not retarget FK % on % (%). Skipped.', c.conname, c.tbl, sqlerrm;
      end;
    else
      raise notice 'FK % on %.% is NOT NULL — left unchanged (delete the child rows first if it ever blocks).', c.conname, c.tbl, c.col;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. sc_delete_user(p_user) — FULL account removal (admin-only RPC).
--    Deletes the auth.users row; profiles follows via its ON DELETE CASCADE
--    FK, and every author/actor column clears to NULL thanks to step 1.
--    The email becomes immediately re-registrable.
--    Safety rails: admin-only · cannot delete yourself · cannot delete the
--    last remaining admin-tier account.
-- ---------------------------------------------------------------------------
create or replace function public.sc_delete_user(p_user uuid)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_role text; v_admins int;
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'Only an admin can delete accounts.';
  end if;
  if p_user = auth.uid() then
    raise exception 'You cannot delete your own account while logged into it.';
  end if;
  select role into v_role from public.profiles where id = p_user;
  if v_role in ('super_admin','admin','principal','proprietor','head_teacher','bursar') then
    select count(*) into v_admins from public.profiles
     where role in ('super_admin','admin','principal','proprietor','head_teacher','bursar')
       and status = 'approved' and id <> p_user;
    if v_admins = 0 then
      raise exception 'Refused: this is the last admin-tier account. Create another admin first.';
    end if;
  end if;
  -- Whole account: auth login + profile (cascade) + author pointers (set null).
  delete from auth.users where id = p_user;
  if not found then
    -- No login exists (profile-only row) — remove the profile directly.
    delete from public.profiles where id = p_user;
    if not found then return 'Nothing to delete — no account or profile with that id.'; end if;
    return 'Profile deleted (no login account existed).';
  end if;
  return 'Account fully deleted — login removed, profile removed, email freed for re-registration.';
end $$;
revoke all on function public.sc_delete_user(uuid) from public, anon;
grant execute on function public.sc_delete_user(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Ghost-login repair: adopt orphaned auth.users rows back into profiles.
--    (People deleted through the OLD directory delete still have a login but
--    no profile — invisible in the app yet blocking their email.)
--    They reappear in the Directory as status 'pending', so the admin can
--    either APPROVE them (they log in with their old password / use "Forgot
--    password") or DELETE them with the new full delete (freeing the email).
-- ---------------------------------------------------------------------------
create or replace function public.sc_adopt_orphan_auth_users()
returns int
language plpgsql
security definer
set search_path = public, auth
as $$
declare n int;
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'Only an admin can repair orphaned accounts.';
  end if;
  insert into public.profiles (id, email, full_name, role, status)
  select u.id, u.email,
         coalesce(nullif(u.raw_user_meta_data->>'full_name',''), split_part(u.email,'@',1)),
         coalesce(nullif(u.raw_user_meta_data->>'role',''), 'student'),
         'pending'
    from auth.users u
    left join public.profiles p on p.id = u.id
   where p.id is null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.sc_adopt_orphan_auth_users() from public, anon;
grant execute on function public.sc_adopt_orphan_auth_users() to authenticated;

-- One-time repair during installation (runs as the SQL-editor superuser, so
-- no admin check is needed here; the function above is for the UI later).
do $$
declare n int;
begin
  insert into public.profiles (id, email, full_name, role, status)
  select u.id, u.email,
         coalesce(nullif(u.raw_user_meta_data->>'full_name',''), split_part(u.email,'@',1)),
         coalesce(nullif(u.raw_user_meta_data->>'role',''), 'student'),
         'pending'
    from auth.users u
    left join public.profiles p on p.id = u.id
   where p.id is null;
  get diagnostics n = row_count;
  if n > 0 then
    raise notice 'Adopted % orphaned login(s) back into profiles (status=pending) — approve or fully delete them in the Directory.', n;
  end if;
exception when undefined_table then
  raise notice 'auth.users not reachable in this environment — orphan adoption skipped.';
end $$;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V9.0 user lifecycle installed — directory deletes are FK-safe, full account removal + ghost-login repair active' as status;
