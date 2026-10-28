-- ============================================================================
-- School Connect V12.14 — ROBUST FIXES: Edit/Delete restored + Student auto-fill on landing + Multi-subject per subject (pass 89)
-- ----------------------------------------------------------------------------
-- Fixes:
-- 1. Edit/Delete buttons restored on assignment page for admin/tutor (never drop pre-existing features)
--    - crud.js now shows Edit + Delete + badge + Score hint for writable assignments
--    - Student/parent portal still shows Take Assignment beside every CBT assignment
-- 2. Report Cards student auto-fill on landing — field auto-fills without typing, already has details when landing
--    - report-cards.html _initFamilyMode immediate auto-fill from cached profile + DB verified
--    - rc-student readonly, datalist cleared, only own result, previous/current term clickable
-- 3. Multi-subject CBT assignments: Score class auto-fills per subject, push fills each subject Assignment column
--    - assignment-cbt.js listCBTAssignments includes MULTI-SUBJECT containing subject via client-side filtering
--    - uiScoreCBT detects multi and delegates to uiScoreMultiCBT
--    - saveCBTScores handles isMulti with subject-inclusive unique index assignment_scores_cbt_subject_unique
--    - Works for pre-existing multi-subject CBT assignments (fallback uses overall %)
-- 4. Audit every page for dropped features — restored Edit/Delete, ensured Take button beside every CBT assignment
--
-- Idempotent — marker only, no schema change needed (v12.13 already has subject-inclusive index)
-- ============================================================================
select 'RUNNING: School Connect robust fixes pack V12.14 — Edit/Delete + Student auto-fill + Multi-subject per subject' as running_version;

-- Ensure subject-inclusive unique index exists (from V12.13)
drop index if exists assignment_scores_cbt_subject_unique;
create unique index if not exists assignment_scores_cbt_subject_unique on public.assignment_scores(cbt_exam_id, student_id, subject) where cbt_exam_id is not null;
drop index if exists assignment_scores_cbt_unique;

-- Marker for schema doctor
insert into public.sc_install_state(key,details) values ('v12.14-robust-fixes.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.14 robust fixes pack installed — Edit/Delete restored + Student auto-fill on landing + Multi-subject per subject' as status;
