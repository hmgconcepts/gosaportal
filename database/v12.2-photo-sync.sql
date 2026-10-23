-- ============================================================================
-- School Connect V12.2 — TWO-WAY PHOTO SYNC (pass 70)
-- ----------------------------------------------------------------------------
-- SYMPTOM: a photo entered on My Profile (profiles.photo_url) showed on the
-- student's ID card everywhere, but a photo entered by staff on the Students
-- page (students.photo_url) did not show on the student-portal card.
-- ROOT CAUSE: the two photo columns were only bridged one way, in one client
-- (the ID-card page's fillPhotos enrichment), leaving every OTHER consumer
-- (top-bar avatar, student profile page, future pages) inconsistent — and any
-- client-side bridge depends on page code being loaded.
-- FIX: sync at the DATABASE — wherever the photo is entered, both columns
-- carry it within the same transaction. Every consumer everywhere is correct
-- by construction. Last write wins (natural semantics for a photo).
-- Recursion-guarded with pg_trigger_depth(); idempotent.
-- ============================================================================
select 'RUNNING: School Connect photo-sync pack V12.2' as running_version;

-- students.photo_url → profiles.photo_url (staff enters on the Students page)
create or replace function public.sc_sync_photo_to_profile()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if new.user_id is not null
     and coalesce(new.photo_url,'') is distinct from coalesce(old.photo_url,'') then
    update public.profiles set photo_url = new.photo_url
     where id = new.user_id
       and coalesce(photo_url,'') is distinct from coalesce(new.photo_url,'');
  end if;
  return new;
end$$;

drop trigger if exists trg_students_photo_sync on public.students;
create trigger trg_students_photo_sync
  after insert or update of photo_url, user_id on public.students
  for each row execute function public.sc_sync_photo_to_profile();

-- profiles.photo_url → students.photo_url (student enters on My Profile)
create or replace function public.sc_sync_photo_to_student()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if coalesce(new.photo_url,'') is distinct from coalesce(old.photo_url,'') then
    update public.students set photo_url = new.photo_url
     where user_id = new.id
       and coalesce(photo_url,'') is distinct from coalesce(new.photo_url,'');
    -- staff photos flow the same way
    update public.staff set photo_url = new.photo_url
     where user_id = new.id
       and coalesce(photo_url,'') is distinct from coalesce(new.photo_url,'');
  end if;
  return new;
end$$;

drop trigger if exists trg_profiles_photo_sync on public.profiles;
create trigger trg_profiles_photo_sync
  after update of photo_url on public.profiles
  for each row execute function public.sc_sync_photo_to_student();

-- staff.photo_url → profiles.photo_url (admin enters on the Staff page)
create or replace function public.sc_sync_staff_photo_to_profile()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if new.user_id is not null
     and coalesce(new.photo_url,'') is distinct from coalesce(old.photo_url,'') then
    update public.profiles set photo_url = new.photo_url
     where id = new.user_id
       and coalesce(photo_url,'') is distinct from coalesce(new.photo_url,'');
  end if;
  return new;
end$$;

drop trigger if exists trg_staff_photo_sync on public.staff;
create trigger trg_staff_photo_sync
  after insert or update of photo_url, user_id on public.staff
  for each row execute function public.sc_sync_staff_photo_to_profile();

-- ONE-TIME BACKFILL: heal existing records both ways (student/staff rows that
-- already carry a photo push it to the empty profile, and vice versa).
update public.profiles p set photo_url = s.photo_url
  from public.students s
 where s.user_id = p.id and coalesce(p.photo_url,'') = '' and coalesce(s.photo_url,'') <> '';
update public.students s set photo_url = p.photo_url
  from public.profiles p
 where s.user_id = p.id and coalesce(s.photo_url,'') = '' and coalesce(p.photo_url,'') <> '';
update public.profiles p set photo_url = st.photo_url
  from public.staff st
 where st.user_id = p.id and coalesce(p.photo_url,'') = '' and coalesce(st.photo_url,'') <> '';
update public.staff st set photo_url = p.photo_url
  from public.profiles p
 where st.user_id = p.id and coalesce(st.photo_url,'') = '' and coalesce(p.photo_url,'') <> '';

-- Marker for schema doctor (self-contained — fixes false alarm when only this file run)
create table if not exists public.sc_install_state(key text primary key,applied_at timestamptz not null default now(),details jsonb default '{}'::jsonb);
insert into public.sc_install_state(key,details) values ('v12.2-photo-sync.sql','{"self":true}') on conflict (key) do nothing;

-- Verifiable probe RPC for Schema Doctor (normal function, not trigger — callable via PostgREST)
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

select 'V12.2 photo-sync pack installed (triggers + backfill + marker + probe)' as status;
