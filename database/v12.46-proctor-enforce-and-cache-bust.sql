-- ============================================================================
-- School Connect V12.46 — Proctor enforce (no bypass) + Cache-bust via hash
-- ----------------------------------------------------------------------------
-- Issue 1 — Proctoring (pictoring) can be bypassed:
--   Previously proctor.js start() did getUserMedia(want) and on NotAllowed
--   just logged proctor_declined and returned {declined:true} — exam continued.
--   Student could deny camera and still do CBT. Need robust, all-inclusive:
--   If tutor enabled camera (anti_cheat_config.camera true), student MUST
--   allow, otherwise BLOCK. Enhance with sophisticated checks: virtual cam
--   (OBS/Virtual/Snap), screen share spoofing, face gate (3 photos before
--   start), liveness (blink), multiple faces, no face, audio loudness +
--   speech pattern, tab/app switch, watermark, snapshots to storage (proctor
--   bucket, 1GB file, not 500MB DB), teacher review.
--
-- Issue 2 — Edit still persisting (tutor saves, back, not reflected):
--   Previous V12.45 draft/publish used md5(old::text) vs md5(bank::text) but
--   live GOSA has cbt_exams.csv_data as TEXT '[{"q":1}]' not JSONB, so
--   md5('[{"q":1}]'::text) != md5('[{"q":1}]'::jsonb::text) even when identical
--   → false positive concurrent_edit, and cbt_exams_drafts draft as JSONB
--   but csv_data as TEXT, so publish did UPDATE with JSONB bank into TEXT
--   column? Actually cbt_exams.csv_data is JSONB not TEXT, but old rows have
--   TEXT due to legacy import. Different approach: Use bank_hash (md5 of
--   normalized JSON.stringify) stored in cbt_exams.bank_hash, and frontend
--   does JSON.stringify(bank) compare, not md5(::text). Also use versioned
--   cache key cbt-exam-cache-CODE-VERSION where VERSION is bank_hash slice,
--   so any edit automatically makes old cache key stale (no need to manually
--   clear all variants). Student's cbt-exam.html on load does
--   cbt_get_public_exam_v6 with cache: no-store, compares bank_hash with
--   localStorage cache key, and if mismatch, invalidates.
--
-- Fix:
--   A. DB: cbt_exams add column bank_hash text default '', proctor_required
--      boolean generated as (anti_cheat_config->>'camera')::boolean (for index)
--   B. proctor.js: Enhanced start() with 2 attempts, virtual cam detection,
--      face gate, liveness, etc., and returns blocked:true with reason if
--      isRequired and denied.
--   C. cbt-exam.html: Exam.beginMonitor now async, checks proctorRes.blocked
--      and shows blocking modal (Camera Required) with Retry, does not start
--      timer/monitor if blocked.
--   D. cbt.html: saveQuestions now uses cbt_publish_draft with JSON.stringify
--      compare, not md5(::text), and broadcasts via localStorage + BroadcastChannel
--      with bank_hash.
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect proctor enforce + cache-bust V12.46' as running_version;

alter table public.cbt_exams add column if not exists bank_hash text not null default '';
alter table public.cbt_exams add column if not exists proctor_required boolean generated always as (coalesce((anti_cheat_config->>'camera')::boolean,false)) stored;
create index if not exists cbt_exams_proctor_required_idx on public.cbt_exams(proctor_required) where proctor_required=true;
create index if not exists cbt_exams_bank_hash_idx on public.cbt_exams(bank_hash);

-- Backfill bank_hash for existing rows
update public.cbt_exams set bank_hash = md5(coalesce(csv_data,'[]'::jsonb)::text) where bank_hash='' or bank_hash is null;

create or replace function public.cbt_force_replace_bank_v2(p_exam_id uuid, p_bank jsonb, p_expected_hash text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; bank jsonb; old_hash text; new_hash text; new_ver int;
begin
  bank:=public.cbt_coerce_to_jsonb_array(p_bank);
  if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'error','Bank empty'); end if;
  select * into e from public.cbt_exams where id=p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  old_hash:=coalesce(e.bank_hash, md5(coalesce(e.csv_data,'[]'::jsonb)::text));
  new_hash:=md5(bank::text);
  if p_expected_hash is not null and p_expected_hash<>old_hash then
    return jsonb_build_object('ok',false,'error','concurrent_edit','message','Another tutor edited (hash '||substring(old_hash,1,8)||' vs expected '||substring(p_expected_hash,1,8)||'). Refresh and retry.','current_hash',old_hash);
  end if;
  if old_hash=new_hash then return jsonb_build_object('ok',true,'message','No changes','exam_id',p_exam_id,'version',coalesce(e.bank_version,1),'hash',old_hash); end if;
  new_ver:=coalesce(e.bank_version,1)+1;
  update public.cbt_exams set csv_data=bank, questions=bank, bank_version=new_ver, bank_hash=new_hash, updated_at=now() where id=p_exam_id;
  begin insert into public.cbt_edit_log (exam_id, editor_id, old_count, new_count, old_hash, new_hash) values (p_exam_id, coalesce(auth.uid(),'00000000-0000-0000-0000-000000000000'::uuid), jsonb_array_length(public.cbt_coerce_to_jsonb_array(e.csv_data)), jsonb_array_length(bank), old_hash, new_hash); exception when others then null; end;
  perform pg_notify('cbt-bank-updated', e.code);
  return jsonb_build_object('ok',true,'exam_id',p_exam_id,'code',e.code,'version',new_ver,'hash',new_hash,'old_hash',old_hash);
end$$;
grant execute on function public.cbt_force_replace_bank_v2(uuid,jsonb,text) to authenticated, anon;

insert into public.sc_install_state(key,details) values ('v12.46-proctor-enforce-and-cache-bust.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.46 proctor enforce + cache-bust installed — camera required blocks, bank_hash versioned cache' as status;
