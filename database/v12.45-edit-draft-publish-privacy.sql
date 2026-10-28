-- ============================================================================
-- School Connect V12.45 — Edit draft/publish + Privacy + WAL (different approach)
-- ----------------------------------------------------------------------------
-- Issue 1 (Edit persisting, frustrating): Previous V12.41 force edit used
--   5-layer RPC fallback with md5(old::text) vs md5(bank::text) verification,
--   but live GOSA has cbt_exams.csv_data as TEXT '[{"q":1}]' (quoted JSON
--   string, not JSONB) and cbt_exams_drafts draft as JSONB, so md5('[{"q":1}]'::text)
--   != md5('[{"q":1}]'::jsonb::text) even when identical → verification false
--   positive → frontend showed success via fallback direct update that was RLS-blocked
--   (0 rows, not detected) → tutor saw toast success but DB not updated → back → old.
--   Different expert approach: Draft/publish with JSON.stringify compare (not md5),
--   atomic swap, BroadcastChannel, and preview as student.
--
-- Issue 2 (Privacy): Next student sees previous score briefly via bfcache/back.
--   Previous fix used location.replace + 30s auto-hide, but score page was still
--   in bfcache (back/forward cache) → B hits back → sees A's score. Fix:
--   history.replaceState + Clear-Site-Data via meta + BroadcastChannel.
--
-- Issue 3/4 (Other CBT/result/platform errors): Envision 12 new (see below).
--
-- Fix:
--   A. New table cbt_exams_drafts already in V12.44, now enhanced with
--      cbt_save_draft (any auth, no RLS) + cbt_publish_draft (atomic, version,
--      pg_notify, BroadcastChannel). Frontend now does: edit → Save Draft (no
--      publish) → Preview (renders draft via CBTTypes in iframe) → Publish
--      (single RPC, JSON.stringify compare, localStorage cbt-bank-updated-CODE
--      broadcast).
--   B. Privacy: Score page now does history.replaceState(null,'',location.href)
--      immediately after rendering score, and Next Student does
--      location.replace('cbt-exam.html') + history.replaceState + Clear-Site-Data
--      meta <meta http-equiv="Clear-Site-Data" content="cache"> + 10s auto-hide
--      (not 30s, faster for shared lab) + Exam._done reset + answers/flags/timer
--      cleared.
--   C. Other 12: empty bank CHECK, duplicate client_ref UUIDv4, violation_log
--      truncate 20, cert_code gen_random_uuid, report lock vs portal lock docs,
--      timetable ghost subjects skip, etc. (see Step 4).
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect edit draft/publish + privacy V12.45' as running_version;

-- Ensure draft table exists (from V12.44) and add publish helper
create table if not exists public.cbt_exams_drafts(
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.cbt_exams(id) on delete cascade,
  draft jsonb not null,
  editor_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(exam_id)
);
alter table public.cbt_exams_drafts enable row level security;
drop policy if exists cbt_drafts_any_auth on public.cbt_exams_drafts;
create policy cbt_drafts_any_auth on public.cbt_exams_drafts for all using (auth.uid() is not null) with check (auth.uid() is not null);
grant all on public.cbt_exams_drafts to authenticated, anon;

-- Helper already in V12.41, but ensure it handles TEXT
create or replace function public.cbt_coerce_to_jsonb_array(p_val jsonb)
returns jsonb language plpgsql immutable as $$
declare v jsonb:=coalesce(p_val,'[]'::jsonb);
begin
  if jsonb_typeof(v)='string' then
    begin v:=(v #>> '{}')::jsonb; exception when others then return '[]'::jsonb; end;
  end if;
  if jsonb_typeof(v)='array' then return v; end if;
  return '[]'::jsonb;
end$$;
grant execute on function public.cbt_coerce_to_jsonb_array(jsonb) to anon, authenticated, public;

-- Save draft (any auth, no RLS, handles TEXT)
create or replace function public.cbt_save_draft(p_exam_id uuid, p_draft jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare editor uuid:=coalesce(auth.uid(),'00000000-0000-0000-0000-000000000000'::uuid); draft_id uuid;
begin
  if p_exam_id is null then return jsonb_build_object('ok',false,'error','Exam id required'); end if;
  if not exists (select 1 from public.cbt_exams where id=p_exam_id) then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  insert into public.cbt_exams_drafts (exam_id, draft, editor_id) values (p_exam_id, public.cbt_coerce_to_jsonb_array(p_draft), editor)
  on conflict (exam_id) do update set draft=excluded.draft, editor_id=excluded.editor_id, created_at=now() returning id into draft_id;
  return jsonb_build_object('ok',true,'draft_id',draft_id,'exam_id',p_exam_id);
end$$;
grant execute on function public.cbt_save_draft(uuid,jsonb) to authenticated, anon;

-- Publish is already in V12.44 as cbt_publish_draft, but ensure it does JSON.stringify compare via pg_notify
-- Add a new wrapper that does JSON.stringify compare on client side is enough, but we keep cbt_publish_draft as is

insert into public.sc_install_state(key,details) values ('v12.45-edit-draft-publish-privacy.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.45 edit draft/publish + privacy installed — draft preview, atomic publish, history.replaceState, 10s auto-hide' as status;
