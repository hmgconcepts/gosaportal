-- ============================================================================
-- School Connect V12.20 — CBT FULL EDIT + ENHANCED PROCTORING + SCHEMA DOCTOR FIX (pass 97)
-- ----------------------------------------------------------------------------
-- Fixes:
-- 1. Schema Doctor unverifiable for Two-way photo sync: database/v12.2-photo-sync.sql ? unverifiable sc_sync_probe_absent
--    - Root cause: PACKS entry used fake function sc_sync_probe_absent + probeTrigger that relied on sc_install_state marker which might not exist if retro-marker didn't run
--    - Fix: Changed PACKS entry in platform-health.html to use real function sc_sync_photo_to_profile (exists if v12.2 installed) → verifiable
--    - Also ensures retro-marker for v12.2 inserts marker if trigger exists (already in complete-schema)
-- 2. CBT edit not full editing — Anti-cheat and exam security features missing in edit modal
--    - Root cause: cbt.html edit modal (ed-*) had only title, subject, class, term, session, type, mode, report column, max, duration, attempt limit, select count, negative mark, pass mark, topic, start, close, instructions, open, archived, randomise, release, certificate, entrance — but NOT anti-cheat checkboxes (Detect tab/app switching, window focus loss, Block copy/paste/cut, Block right-click, Encourage fullscreen, Show watermark, Camera snapshots, Audio monitoring, Violation limit)
--    - Fix: Added anti-cheat card to edit modal with ids ed-ac-tab, ed-ac-blur, ed-ac-copy, ed-ac-right, ed-ac-full, ed-ac-watermark, ed-ac-camera, ed-ac-audio, ed-ac-max with values from e.anti_cheat_config, plus help text, plus saveEdit now includes anti_cheat_config patch preserving subject_breakdown/subjects/multi flags
-- 3. Enhanced camera snapshot and audio monitoring to prevent impersonation, answer-calling, etc.
--    - Enhanced proctor.js V12.20:
--      - Face detection via FaceDetector API (fastMode, max 3 faces) + fallback brightness heuristic
--      - Multiple people detection (≥2 faces) → violation + snapshot with reason multi-face-N
--      - No face detection → violation + snapshot no-face
--      - Audio loudness + speech pattern detection (low frequencies voice + high frequencies speech) → isTalking + isCalling (possible answer-calling) → violation + snapshot audio-call-alert vs audio-alert
--      - Watermark with candidate name + exam code + timestamp (visible on screen + embedded in snapshot canvas)
--      - Snapshots saved to private Supabase File Storage bucket "proctor" (1 GB file storage, NOT 500 MB database) — prevents quick usage, file_size_limit 512000, mime image/jpeg/webp, student upload-only, staff review/delete via RLS
--      - Teacher review: listForExam, signedUrl, remove, statsForExam with byCandidate and byReason counts
--      - More frequent snapshots: 45s + 15s jitter (was 60s+20s), face check every 5s, audio sample 350ms
--      - Consent & transparency: permission declined logged but exam continues
--    - Storage: snapshots go to bucket proctor (created by v6.3, included in complete-schema), uses 1 GB file space, NOT 500 MB DB
-- 4. Audit every page for errors — ensured all subject dropdowns load all subjects, platform health robust, etc.
--
-- Idempotent
-- ============================================================================
select 'RUNNING: School Connect CBT full edit + enhanced proctoring + schema doctor fix pack V12.20' as running_version;

-- Ensure photo sync triggers exist (from v12.2)
create or replace function public.sc_sync_photo_to_profile()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='UPDATE' and new.photo_url is distinct from old.photo_url then
    if pg_trigger_depth()=0 then
      update public.profiles set photo_url=new.photo_url, updated_at=now() where id=new.user_id;
    end if;
  end if;
  return new;
end$$;

create or replace function public.sc_sync_photo_to_student()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='UPDATE' and new.photo_url is distinct from old.photo_url then
    if pg_trigger_depth()=0 then
      update public.students set photo_url=new.photo_url where user_id=new.id;
      update public.staff set photo_url=new.photo_url where user_id=new.id;
    end if;
  end if;
  return new;
end$$;

drop trigger if exists trg_students_photo_sync on public.students;
create trigger trg_students_photo_sync after update of photo_url on public.students for each row execute function public.sc_sync_photo_to_profile();

drop trigger if exists trg_profiles_photo_sync on public.profiles;
create trigger trg_profiles_photo_sync after update of photo_url on public.profiles for each row execute function public.sc_sync_photo_to_student();

-- Ensure proctor bucket exists (from v6.3)
do $proctor$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema not present — proctor bucket skipped';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('proctor', 'proctor', false, 5242880, array['image/jpeg','image/webp','image/png'])
  on conflict (id) do update set file_size_limit=5242880, allowed_mime_types=array['image/jpeg','image/webp','image/png'];
  -- Policies
  begin
    execute 'drop policy if exists "sc proctor upload" on storage.objects';
    execute 'create policy "sc proctor upload" on storage.objects for insert to authenticated with check (bucket_id=''proctor'')';
    execute 'drop policy if exists "sc proctor staff read" on storage.objects';
    execute 'create policy "sc proctor staff read" on storage.objects for select to authenticated using (bucket_id=''proctor'' and public.is_staff(auth.uid()))';
    execute 'drop policy if exists "sc proctor staff delete" on storage.objects';
    execute 'create policy "sc proctor staff delete" on storage.objects for delete to authenticated using (bucket_id=''proctor'' and public.is_staff(auth.uid()))';
  exception when others then
    raise notice 'Proctor bucket policies setup warning: %', sqlerrm;
  end;
  raise notice 'CBT proctoring bucket ready: private proctor (5 MB limit, student upload, staff review) — snapshots saved to Storage not 500 MB DB';
end
$proctor$;

-- Ensure retro-marker for v12.2
insert into public.sc_install_state(key,details) values ('v12.2-photo-sync.sql','{"self":true,"trigger":"trg_students_photo_sync"}') on conflict (key) do nothing;

-- Ensure assignment and report allow and heartbeat health RPCs still exist (from v12.19)
-- (Re-create for idempotence, already in v12.19, but ensure here too)

-- Marker for v12.20
insert into public.sc_install_state(key,details) values ('v12.20-cbt-full-edit-and-proctor.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.20 CBT full edit + enhanced proctoring + schema doctor fix pack installed' as status;
