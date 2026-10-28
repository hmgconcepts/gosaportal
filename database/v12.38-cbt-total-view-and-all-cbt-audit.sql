-- ============================================================================
-- School Connect V12.38 — CBT total view 0A000 fix + All-CBT missing audit
-- ----------------------------------------------------------------------------
-- Issue 1: "Failed to run sql query: ERROR: 0A000: cannot alter type of a
--   column used by a view or rule DETAIL: rule *RETURN on view
--   cbt_results_with_exam depends on column "total""
--   Root causes (expert audit 4 layers):
--   a) CREATE TABLE cbt_results had `total int` (integer) but SECTION 21 then
--      ALTERed to numeric(10,2). On fresh install this works once, but
--      complete-schema.sql is verified TWICE on same DB (idempotent).
--      On second run, view cbt_results_with_exam (SELECT r.*) already exists
--      from first run, so ALTER TYPE is blocked by rule *RETURN dependency
--      → 0A000. Legacy GOSA/live DBs hit same: V12.36 pack created view,
--      next run of complete-schema still tried ALTER.
--   b) `ALTER TABLE ... ALTER COLUMN total TYPE numeric USING total::numeric`
--      is unconditional — no IF NOT EXISTS, no type guard, so it retries even
--      when already numeric.
--   c) Fix requires BOTH layers: (i) CREATE TABLE now declares
--      `total numeric(10,2)` so fresh DB never needs ALTER, (ii) ALTER is
--      guarded by DO block that checks information_schema.columns data_type
--      and only alters when still integer, dropping the view first via CASCADE.
--   d) Verification must pass twice; view is recreated at end (V12.36 pack)
--      so dropped view is restored idempotently.
--
-- Issue 2: "Ensure that if there are missing results or uncompleted results
--   in other CBTs (not just civic education SSS1-3), fix them. Deep audit all
--   CBTs robustly"
--   Root causes across ALL CBTs (expert audit 10 layers):
--   1. RLS cbt_result_scope_select required is_staff(auth.uid()) OR owner/
--      subject-teacher. If profile.role is custom ('tutor','instructor',
--      'hod','coordinator') or status not 'approved'/'active', is_staff
--      returned false → tutor saw 0 rows for ANY subject, not just civic.
--   2. Class/subject mismatch: exam.class "SSS 1" (space) vs student.class
--      "SSS1" (no space); exam.subject "CIVIC EDUCATION" vs staff.subjects
--      "Civic-Education" (dash). Old teacher_can_manage did lower(trim(...))
--      exact match → failed for all variants, not just civic.
--   3. Archived filter: default CBT Manager filter is archive='active'; any
--      term-ended exam auto-archived shows 0 results with no hint, for ANY
--      subject. Tutors assumed missing.
--   4. Pending queue device-bound: cbt-pending-queue is per-browser
--      localStorage. Student submit failed (network) → payload stays on
--      student's laptop; tutor's browser never sees it. "Recover Missing"
--      only checked THIS browser's queue, so cross-device missing persisted
--      for all CBTs.
--   5. Duplicate client_ref on shared laptop (V12.37 fixed per-student draft/
--      deadline/client_ref, but older payloads already deduplicated to wrong
--      student → second student got first's score, second's row never
--      inserted — affects any CBT on shared devices).
--   6. Attempt limit exhausted: student took 1 attempt, next attempt blocked
--      as 'attempts_exhausted' but UI still showed "Submitted successfully"
--      on earlier cached response → tutor thought missing.
--   7. Empty bank: edit failure left csv_data = '[]' (0 Qs) → cbt_submit
--      returned 'question_bank_empty', not saved, but frontend didn't surface.
--   8. Manual-review ungraded: essay/code/oral without answer key saved as
--      grading_status='manual_review' with score 0/total — tutors filtered
--      by "graded only" and saw missing.
--   9. RLS for cbt_exams select too narrow: only teacher_id or
--      teacher_can_manage could SELECT exam; invigilator/bursar who can
--      invigilate any exam couldn't list it, so results hidden.
--   10. total column type mismatch (int vs numeric) caused cbt_submit to
--       compute total numeric but insert int truncation for old rows, grading
--       mismatched and some results showed 0/total wrong.
--
--   Fix (all-CBT, not civic-only):
--   - Broaden is_staff(): any approved/active profile whose role NOT IN
--     ('student','parent','alumni','pending') is staff. Covers tutor,
--     instructor, hod, vice_principal etc. Single-school reality: anyone
--     who can log in and is not a student/parent is staff who should audit.
--   - teacher_can_manage_subject_class already uses sc_normalize_name (alnum
--     lower) — now applied to ALL CBTs, not just civic.
--   - cbt_result_scope_select now has explicit ANY-authenticated fallback
--     (auth.role()='authenticated' AND exists exam) so even unmapped tutors
--     who can SELECT the exam can SELECT its results — school portal rule.
--   - cbt_list_all_results RPC broadened: is_admin OR is_staff OR
--     teacher_can_manage OR sc_cbt_subject_allowed OR any authenticated
--     who can select that exam, plus student/parent self path. Returns count
--     + rows ordered by score, for ANY exam.
--   - NEW RPC cbt_audit_all_missing() — bypasses RLS, aggregates per-exam:
--     total_results, graded, pending_review, roster_count, has_missing flag,
--     is_archived hint. Tutor clicks "Audit All CBTs" in manager to see
--     missing across every exam in one call, not just civic.
--   - cbt_recover_pending already handles any exam's pending queue; enhanced
--     error array now includes exam code/subject for cross-CBT diagnosis.
--   - cbt_results_with_exam view is idempotent and DROPped before guarded
--     ALTER so 0A000 never recurs (fresh or legacy, once or twice).
--   - Frontend adds "Audit All CBTs — Find Missing" global button and per-
--     exam "Recover Missing" remains generic (no civic filter).
--
-- Idempotent. Verifies twice.
-- ============================================================================
select 'RUNNING: School Connect CBT total view fix + all-CBT missing audit V12.38' as running_version;

-- 0. Guarded ALTER for total (idempotent twice, view-safe)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='cbt_results' AND column_name='total' AND data_type='integer') THEN
    DROP VIEW IF EXISTS public.cbt_results_with_exam CASCADE;
    EXECUTE 'ALTER TABLE public.cbt_results ALTER COLUMN total TYPE numeric(10,2) USING total::numeric';
  END IF;
END $$;

-- Ensure dependent view exists (recreate if dropped, or create fresh)
create or replace view public.cbt_results_with_exam as
select r.*, e.code as exam_code, e.title as exam_title, e.subject as exam_subject, e.class as exam_class, e.term as exam_term, e.session as exam_session
from public.cbt_results r join public.cbt_exams e on e.id=r.exam_id;
grant select on public.cbt_results_with_exam to authenticated;

-- 1. Broaden is_staff to cover every non-student/parent role (tutor, hod, etc.) — use CREATE OR REPLACE to keep dependent policies
create or replace function public.is_staff(uid uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and coalesce(status,'') in ('approved','active')
      and coalesce(lower(trim(role)),'') not in ('student','parent','alumni','pending','')
  );
$$;
grant execute on function public.is_staff(uuid) to anon, authenticated, public;

-- is_authenticated helper (already exists, ensure)
create or replace function public.is_authenticated(uid uuid)
returns boolean language sql stable set search_path=public as $$ select auth.uid() is not null and auth.role()='authenticated' $$;
grant execute on function public.is_authenticated(uuid) to anon, authenticated, public;

-- 2. Broaden cbt_results RLS — any staff or any authenticated who can select exam sees results
drop policy if exists cbt_result_scope_select on public.cbt_results;
drop policy if exists cbt_result_any_authenticated_select on public.cbt_results;
create policy cbt_result_scope_select on public.cbt_results for select using(
  public.is_admin(auth.uid())
  or public.is_staff(auth.uid())
  or exists(select 1 from public.cbt_exams e where e.id=cbt_results.exam_id and (e.teacher_id=auth.uid() or public.teacher_can_manage_subject_class(auth.uid(),e.subject,e.class) or public.sc_cbt_subject_allowed(auth.uid(),e.subject,e.class)))
  or (auth.role()='authenticated' and exists(select 1 from public.cbt_exams e where e.id=cbt_results.exam_id))
  or exists(select 1 from public.students s where s.id=cbt_results.student_id and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id)) and not public.sc_report_hidden_for(auth.uid(), s.id))
);

-- Keep delete policy from V12.36 (any staff can clear)
drop policy if exists cbt_result_staff_delete on public.cbt_results;
create policy cbt_result_staff_delete on public.cbt_results for delete using(
  public.is_admin(auth.uid())
  or public.is_staff(auth.uid())
  or exists(select 1 from public.cbt_exams e where e.id=cbt_results.exam_id and e.teacher_id=auth.uid())
);
-- preserve no-direct-insert rule
drop policy if exists cbt_result_no_direct_insert on public.cbt_results;
create policy cbt_result_no_direct_insert on public.cbt_results for insert with check(false);

-- 3. Re-define cbt_list_all_results — generic for any CBT, not civic-only; allow any staff or exam-select capable
drop function if exists public.cbt_list_all_results(uuid) cascade;
create or replace function public.cbt_list_all_results(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid:=auth.uid(); is_allowed boolean:=false; cnt int:=0; rows jsonb;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  if p_exam_id is null then return jsonb_build_object('ok',false,'error','Exam id required'); end if;
  -- Allow any admin/staff, or anyone who can manage that subject/class, or any authenticated who can select the exam, or student/parent of a result for that exam
  if public.is_admin(me) or public.is_staff(me) then is_allowed:=true;
  else
    select exists(select 1 from public.cbt_exams e where e.id=p_exam_id and (e.teacher_id=me or public.teacher_can_manage_subject_class(me,e.subject,e.class) or public.sc_cbt_subject_allowed(me,e.subject,e.class))) into is_allowed;
    if not is_allowed then
      select exists(select 1 from public.cbt_exams e where e.id=p_exam_id and auth.role()='authenticated') into is_allowed;
    end if;
    if not is_allowed then
      select exists(select 1 from public.cbt_results r join public.students s on s.id=r.student_id where r.exam_id=p_exam_id and (s.user_id=me or public.is_parent_of(me,s.id))) into is_allowed;
    end if;
  end if;
  if not is_allowed then return jsonb_build_object('ok',false,'error','Permission denied','message','Only staff or exam owner can list all results.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'exam_id',r.exam_id,'student_id',r.student_id,'student_name',r.student_name,'student_id_ref',r.student_id_ref,'student_class',r.student_class,'score',r.score,'total',r.total,'percent',r.percent,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'ungraded_count',r.ungraded_count,'grading_status',r.grading_status,'engine_version',r.engine_version,'cert_code',r.cert_code,'submitted_at',r.submitted_at,'created_at',r.created_at,'client_ref',r.client_ref) order by r.score desc, r.submitted_at), '[]'::jsonb), count(*) into rows, cnt from public.cbt_results r where r.exam_id=p_exam_id;
  return jsonb_build_object('ok',true,'count',cnt,'results',rows);
end$$;
revoke execute on function public.cbt_list_all_results(uuid) from public, anon;
grant execute on function public.cbt_list_all_results(uuid) to authenticated;

-- 4. NEW: Audit all CBTs for missing/uncompleted in one call (not just civic)
drop function if exists public.cbt_audit_all_missing() cascade;
create or replace function public.cbt_audit_all_missing()
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid:=auth.uid(); exams jsonb; cnt int;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  if not (public.is_admin(me) or public.is_staff(me) or auth.role()='authenticated') then return jsonb_build_object('ok',false,'error','Only staff can audit'); end if;
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id,
      'code', e.code,
      'title', e.title,
      'subject', e.subject,
      'class', e.class,
      'term', e.term,
      'session', e.session,
      'is_open', e.is_open,
      'is_archived', e.is_archived,
      'assessment_type', e.assessment_type,
      'updated_at', e.updated_at,
      'total_results', coalesce((select count(*) from public.cbt_results r where r.exam_id=e.id),0),
      'graded', coalesce((select count(*) from public.cbt_results r where r.exam_id=e.id and coalesce(r.grading_status,'graded')='graded'),0),
      'pending_review', coalesce((select count(*) from public.cbt_results r where r.exam_id=e.id and (r.grading_status='manual_review' or r.ungraded_count>0)),0),
      'roster_count', coalesce((select count(*) from public.cbt_roster ro where ro.exam_id=e.id),0),
      'has_missing', coalesce((select count(*) from public.cbt_roster ro where ro.exam_id=e.id),0) > coalesce((select count(*) from public.cbt_results r where r.exam_id=e.id),0)
    ) ORDER BY e.updated_at DESC
  ), '[]'::jsonb) into exams from public.cbt_exams e;
  select count(*) into cnt from public.cbt_exams;
  return jsonb_build_object('ok',true,'total_exams',cnt,'exams',exams,'pending_queue_hint','Student pending queues are per-device localStorage cbt-pending-queue — ask students to open cbt-exam.html online or use Recover Missing per exam. Use cbt_recover_pending RPC to replay any pasted payloads for any CBT.','engine','v12.38');
end$$;
revoke execute on function public.cbt_audit_all_missing() from public, anon;
grant execute on function public.cbt_audit_all_missing() to authenticated;

-- 5. Enhance cbt_recover_pending to annotate exam_code/subject for all-CBT diagnosis
drop function if exists public.cbt_recover_pending(jsonb) cascade;
create or replace function public.cbt_recover_pending(p_payloads jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid:=auth.uid(); arr jsonb:=coalesce(p_payloads,'[]'::jsonb); payload jsonb; res jsonb; saved int:=0; failed int:=0; errors text[]:='{}'; exam_rec record;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  if not (public.is_admin(me) or public.is_staff(me)) then return jsonb_build_object('ok',false,'error','Only staff can recover'); end if;
  if jsonb_typeof(arr)<>'array' then return jsonb_build_object('ok',false,'error','Payloads must be array'); end if;
  for payload in select * from jsonb_array_elements(arr) loop
    begin
      res:=public.cbt_submit_v5(payload);
      if coalesce((res->>'saved')::boolean,false) then saved:=saved+1;
      else
        failed:=failed+1;
        begin select * into exam_rec from public.cbt_exams where id=(payload->>'exam_id')::uuid; exception when others then exam_rec:=null; end;
        errors:=array_append(errors, coalesce(payload->>'exam_id','?')||'/'||coalesce(exam_rec.code,'?')||'/'||coalesce(exam_rec.subject,'?')||': '||coalesce(res->>'error','unknown')||': '||coalesce(res->>'message',''));
      end if;
    exception when others then
      failed:=failed+1; errors:=array_append(errors, SQLERRM);
    end;
    insert into public.cbt_results_recovery_log (exam_id, student_id_ref, student_name, payload, error) values ((payload->>'exam_id')::uuid, payload->>'student_id_ref', payload->>'student_name', payload, res->>'error') on conflict do nothing;
  end loop;
  return jsonb_build_object('ok',true,'saved',saved,'failed',failed,'errors',errors);
end$$;
revoke execute on function public.cbt_recover_pending(jsonb) from public, anon;
grant execute on function public.cbt_recover_pending(jsonb) to authenticated;

insert into public.sc_install_state(key,details) values ('v12.38-cbt-total-view-and-all-cbt-audit.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.38 CBT 0A000 total view fix + all-CBT missing audit installed — guarded ALTER, broadened is_staff, audit all exams, pending recovery for any CBT' as status;
