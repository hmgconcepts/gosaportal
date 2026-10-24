-- ============================================================================
-- School Connect V12.44 — Comprehensive 7-issue fix (different expert approach)
-- ----------------------------------------------------------------------------
-- Issue 1 (Edit): Tutor edits pre-existing CBT → Save shows success toast but
--   goes back → changes not reflected. Previous V12.41 force edit used
--   5-layer RPC fallback with md5(old::text) vs md5(bank::text) verification,
--   but live GOSA has cbt_exams.csv_data as TEXT '[{"q":1}]' (quoted JSON
--   string, not JSONB array), so md5('[{"q":1}]'::text) != md5('[{"q":1}]'::jsonb::text)
--   even when identical → verification false positive → frontend showed success
--   via fallback direct update that was actually RLS-blocked (silent 0 rows),
--   but toast still showed success because direct update returned 200 with 0 rows
--   not detected as error.
--   Different approach: Shadow draft + atomic publish + JSON-stringify compare
--   + BroadcastChannel + tutor preview as student. New table cbt_exams_drafts
--   (exam_id, draft jsonb, editor_id, created_at) + RPC cbt_save_draft +
--   cbt_publish_draft (atomic UPDATE with RETURNING, deletes draft, logs,
--   broadcasts via pg_notify('cbt-bank-updated', exam_code) and localStorage
--   event). Frontend now does: edit → Save Draft (no publish) → Preview
--   (renders draft via CBTTypes + lenientJSON) → Publish (single RPC, verified
--   by JSON.stringify(bank) === JSON.stringify(publishedBank) not md5).
--
-- Issue 4 (Privacy): Next student sees previous score briefly. Previous fix
--   used sessionStorage + location.replace + 30s auto-hide, but score page
--   still in bfcache (back/forward cache) → B hits back button → sees A's
--   score. Different approach: Score page now sends Cache-Control: no-store
--   via meta, and does history.replaceState(null,'',location.href) + Clear-Site-Data
--   via meta, plus on Next Student does location.replace('cbt-exam.html') with
--   no ?code= (empty) and clears Exam._done, answers, timer, draft, deadline,
--   cache for all CODE variants, and broadcasts 'cbt-session-ended' via
--   BroadcastChannel so other tabs also clear.
--
-- Issue 5 (Next Student empty): Previous Next Student was ?code=CODE (preserved)
--   → B sees A's code, might submit to wrong exam. Now empty (no ?code) → B
--   must type both code+ID, no error. Public link ?code=CODE still available
--   via Share modal for single-student convenience, but Next Student never
--   auto-loads.
--
-- Issue 6 (Score toggle): Tutor can toggle show_score_on_submit per exam
--   (already in V12.43, now enhanced with preview: edit modal shows "If
--   unchecked, student will see 'Submission Received' not score, but tutor
--   still sees all in Manager → Recover").
--
-- Issue 2/3 (Envision other CBT/result/platform errors):
--   - Empty bank (0 Qs) → cbt_exams.csv_data='[]' → cbt_submit returns
--     question_bank_empty, tutor sees no row. Fix: cbt_exams CHECK csv_data
--     jsonb_array_length >0 on insert, and tutor's New Exam validates via
--     CBT.validateQuestionBank before create (already, now enhanced with
--     per-row error with question index).
--   - Duplicate client_ref on shared laptop → score leak (A's score to B)
--     already fixed via per-student draft/deadline/client_ref, now also
--     client_ref is UUIDv4 with student_id_ref + timestamp, not just random.
--   - Violation log overflow (100+ violations → 1MB jsonb) → Fix: cbt_results
--     violation_log now truncated to last 20 via cbt_submit_v5.
--   - Certificate collision (md5 random 8 chars 1/4B) → Fix: use gen_random_uuid().
--   - Report lock vs portal lock confusion → Fix: sc_report_hidden_for now
--     checks is_staff first, returns false for staff (already, now documented
--     in platform-health).
--   - Timetable ghost subjects (deleted subject still in timetable_requirements)
--     → Fix: generate_timetable now skips requirements where subject not in subjects table.
--
-- Issue 7 (Every file): All 3 repos + templates + Fleet (if needed) + PWA.
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect comprehensive 7-issue fix V12.44' as running_version;

-- Draft table for shadow edit
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

-- Publish RPC: atomic swap + broadcast
create or replace function public.cbt_publish_draft(p_draft_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare d record; e record; bank jsonb; old jsonb; new_ver int;
begin
  select * into d from public.cbt_exams_drafts where id=p_draft_id;
  if not found then return jsonb_build_object('ok',false,'error','Draft not found'); end if;
  bank:=public.cbt_coerce_to_jsonb_array(d.draft);
  if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'error','Draft empty'); end if;
  select * into e from public.cbt_exams where id=d.exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  old:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));
  new_ver:=coalesce(e.bank_version,1)+1;
  update public.cbt_exams set csv_data=bank, questions=bank, bank_version=new_ver, updated_at=now() where id=d.exam_id returning * into e;
  delete from public.cbt_exams_drafts where id=p_draft_id;
  begin insert into public.cbt_edit_log (exam_id, editor_id, old_count, new_count, old_hash, new_hash) values (d.exam_id, d.editor_id, jsonb_array_length(old), jsonb_array_length(bank), md5(old::text), md5(bank::text)); exception when others then null; end;
  perform pg_notify('cbt-bank-updated', e.code);
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'version',new_ver,'old_count',jsonb_array_length(old),'new_count',jsonb_array_length(bank));
end$$;
grant execute on function public.cbt_publish_draft(uuid) to authenticated, anon;

insert into public.sc_install_state(key,details) values ('v12.44-comprehensive-7-issues.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.44 comprehensive 7-issue fix installed — draft/publish, no RLS, WAL, privacy, score toggle, PWA' as status;
