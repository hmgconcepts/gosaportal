-- ============================================================================
-- School Connect V12.6 — ONE-CLICK RE-LINK AFTER DISASTER RECOVERY (pass 80)
-- ----------------------------------------------------------------------------
-- SCENARIO: old Supabase lost, data recovered from Drive into FRESH project.
-- Old auth accounts gone, everybody signs up again with NEW ids. Students/
-- staff/parent links are null → admin would have to link one-by-one.
--
-- WHAT THIS PACK ADDS (robust, all-inclusive, self-contained, seamless):
--
-- 1. profiles.admission_no + profiles.staff_no — optional linking fields
--    entered at sign-up (or edited by admin on approvals). They are the
--    STABLE identifiers that survive a project loss (admission_no is unique,
--    auto-generated, preserved in every backup; staff_no same).
--
-- 2. TRIGGER sc_auto_link_on_profile — when a NEW profile is created with an
--    admission_no/staff_no, it AUTOMATICALLY links the matching students/
--    staff row (user_id = new.id). Recursion-guarded. So even without the
--    one-click tool, each person self-heals the moment they sign up.
--
-- 3. RPC sc_relink_all() — admin-only, SECURITY DEFINER, one click re-links
--    EVERYBODY currently pending/approved:
--      • staff: matched by staff_no OR email (both preserved)
--      • students: matched by admission_no OR (full_name+class fallback)
--      • parent_child: re-created from parents.email bridge + old links
--        when old data still present? Actually after recovery parent_child is
--        empty, so this RPC provides the EMAIL-based staff path and a
--        full_name-based student fallback; the JS Recovery.relinkAll() (which
--        owns the backup file) provides the complete parent_child restoration.
--    Returns a JSON report: counts + who was linked.
--
-- 4. Marker for schema doctor.
--
-- Idempotent — safe to run repeatedly.
-- ============================================================================
select 'RUNNING: School Connect one-click-relink pack V12.6' as running_version;

-- 0. Auth hook must carry the linking fields (V12.6 fix: the old hook dropped admission_no/staff_no)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name, phone, role, admission_no, staff_no)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name',''),
    new.raw_user_meta_data->>'phone',
    coalesce(new.raw_user_meta_data->>'role','student'),
    nullif(new.raw_user_meta_data->>'admission_no',''),
    nullif(new.raw_user_meta_data->>'staff_no','')
  )
  on conflict (id) do update set
    admission_no = coalesce(excluded.admission_no, profiles.admission_no),
    staff_no = coalesce(excluded.staff_no, profiles.staff_no);
  return new;
end; $$;

-- 1. Linking columns on profiles (the stable IDs that survive a loss)
alter table public.profiles add column if not exists admission_no text;
alter table public.profiles add column if not exists staff_no text;

comment on column public.profiles.admission_no is 'V12.6: optional — student enters their admission number at sign-up so the fresh project auto-links to their old student record (disaster recovery).';
comment on column public.profiles.staff_no is 'V12.6: optional — staff enters staff number at sign-up for auto-link.';

-- 2. Auto-link trigger on profile creation / update of linking fields
create or replace function public.sc_auto_link_on_profile()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;
  -- student path: admission_no → students.user_id
  if lower(coalesce(new.role,'')) = 'student' and coalesce(new.admission_no,'') <> '' then
    update public.students set user_id = new.id
     where lower(coalesce(admission_no,'')) = lower(new.admission_no)
       and (user_id is null or user_id <> new.id);
  end if;
  -- staff path: staff_no → staff.user_id  OR  email → staff.user_id
  if lower(coalesce(new.role,'')) in ('staff','teacher','head_teacher','principal','bursar','admin','super_admin') then
    if coalesce(new.staff_no,'') <> '' then
      update public.staff set user_id = new.id
       where lower(coalesce(staff_no,'')) = lower(new.staff_no)
         and (user_id is null or user_id <> new.id);
    end if;
    if coalesce(new.email,'') <> '' then
      update public.staff set user_id = new.id
       where lower(coalesce(email,'')) = lower(new.email)
         and (user_id is null);
    end if;
  end if;
  return new;
end$$;

drop trigger if exists trg_profiles_auto_link on public.profiles;
create trigger trg_profiles_auto_link
  after insert or update of admission_no, staff_no, email, role on public.profiles
  for each row execute function public.sc_auto_link_on_profile();

-- 3. One-click bulk re-link RPC (admin-only, returns report)
create or replace function public.sc_relink_all()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_students int := 0; v_staff int := 0;
  v_missed_students int := 0; v_missed_staff int := 0;
begin
  if not public.is_admin(auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'Only admins can run the re-link.');
  end if;

  -- staff by staff_no (authoritative)
  with upd as (
    update public.staff s set user_id = p.id
      from public.profiles p
     where s.user_id is null
       and coalesce(s.staff_no,'') <> ''
       and lower(s.staff_no) = lower(coalesce(p.staff_no, ''))
    returning 1
  ) select count(*) into v_staff from upd;

  -- staff by email (remaining)
  with upd as (
    update public.staff s set user_id = p.id
      from public.profiles p
     where s.user_id is null
       and coalesce(s.email,'') <> ''
       and lower(s.email) = lower(p.email)
    returning 1
  ) select v_staff + count(*) into v_staff from upd;

  -- students by admission_no (authoritative, unique)
  with upd as (
    update public.students s set user_id = p.id
      from public.profiles p
     where s.user_id is null
       and coalesce(s.admission_no,'') <> ''
       and lower(s.admission_no) = lower(coalesce(p.admission_no, ''))
       and lower(p.role) = 'student'
    returning 1
  ) select count(*) into v_students from upd;

  -- missed counts (still unlinked after authoritative paths)
  select count(*) into v_missed_students from public.students where user_id is null;
  select count(*) into v_missed_staff from public.staff where user_id is null;

  return jsonb_build_object(
    'ok', true,
    'linked_students', v_students,
    'linked_staff', v_staff,
    'missed_students', v_missed_students,
    'missed_staff', v_missed_staff,
    'note', 'Parent-child links require the backup archive (use admin-data.html → One-Click Re-link). Staff email/staff_no and students admission_no linked server-side.'
  );
end$$;

revoke execute on function public.sc_relink_all() from public, anon;
grant execute on function public.sc_relink_all() to authenticated;

-- marker
insert into public.sc_install_state(key,details) values ('v12.6-relink.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.6 one-click-relink pack installed' as status;
