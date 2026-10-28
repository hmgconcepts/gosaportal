-- ============================================================================
-- School Connect V12.15 — TERM SHEET + PERMISSIONS + STUDENT AUTO-FILL ROBUST (pass 90)
-- ----------------------------------------------------------------------------
-- Fixes:
-- 1. Report Cards student auto-fill on landing — robust, all-inclusive, self-contained, seamless
--    - fillStudentPicker respects family mode (student only own, parent only kids)
--    - _initFamilyMode immediate auto-fill from cached profile + DB verified + interval ensuring
--    - rc-student readonly, datalist only own, no access to others
-- 2. Multi-subject CBT assignment term score sheet not showing — robust fix
--    - assignment_scores per subject now collated cumulatively per subject
--    - AP.totals and AP.matrix now fetch all for class, client filter by subject containment (includes) + term/session null allowed
--    - saveCBTScores uses current period term/session (curTerm/curSession) to ensure scores appear in current term sheet
--    - Matrix groups by cbt_exam_id|subject separate columns for multi-subject
--    - Push totals → Assignment column scaled to column max (cumulative % * max)
-- 3. Multi-subject CBT for exams/mid-term still works — report-engine pushOneCBTExam handles subject_scores breakdown
-- 4. Teacher permission for assignments — RLS already enforces posted_by=auth.uid() for write, UI shows 🔒 for other teacher's rows
--    - crud.js assignments Edit/Delete shows locked badge for other teacher's record
--    - AP.scoreModal checks posted_by and refuses if not owner and not admin
-- 5. Duplicate of 2 — term sheet collation fixed
--
-- Idempotent — ensures subject-inclusive index and RLS policies remain
-- ============================================================================
select 'RUNNING: School Connect term sheet + permissions + student auto-fill robust pack V12.15' as running_version;

-- Ensure subject-inclusive unique index exists (allows per-subject rows for multi-subject)
drop index if exists assignment_scores_cbt_subject_unique;
create unique index if not exists assignment_scores_cbt_subject_unique on public.assignment_scores(cbt_exam_id, student_id, subject) where cbt_exam_id is not null;
drop index if exists assignment_scores_cbt_unique;

-- Ensure assignments RLS write policy enforces owner (teacher can only edit own)
drop policy if exists assignments_scope_write on public.assignments;
create policy assignments_scope_write on public.assignments for all using(public.is_admin(auth.uid())or((posted_by=auth.uid()or posted_by is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(posted_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));

-- Ensure assignments select policy includes class-based + owner
drop policy if exists assignments_scope_select on public.assignments;
create policy assignments_scope_select on public.assignments for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))and s.class=assignments.class));

-- Marker
insert into public.sc_install_state(key,details) values ('v12.15-term-sheet-and-permissions.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.15 term sheet + permissions + student auto-fill robust pack installed' as status;
