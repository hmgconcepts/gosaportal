-- ============================================================================
-- School Connect V12.32 — CBT EDIT PERSISTENCE + CLASS-SCOPED REGISTERED EXAMS
-- ----------------------------------------------------------------------------
-- Issue 1: When a tutor selects a pre-existing CBT and clicks on edit to edit
--   either the questions, options, correct options, etc and click save changes,
--   when tutor goes back to that CBT, changes didn't reflect.
--
-- Deep expert audit (all layers):
--   Layer A — RLS too strict: cbt_exams update policy was
--     `using (is_admin or teacher_id=auth.uid()) with check (is_admin or teacher_id=auth.uid())`
--     Only admin/owner could UPDATE. If exam was created by admin or another
--     teacher, subject/class teacher editing questions/metadata was blocked via
--     RLS — direct update returned 0 rows with no error, so frontend toasted
--     success but nothing persisted (saveQuestions only checked error, not rows).
--   Layer B — saveQuestions never verified rows: `update({csv_data:bank,questions:bank}).eq(id)`
--     without .select() — RLS block returned no error, so "✅ saved" was false.
--     saveEdit DID check data via .select().maybeSingle() and showed not confirmed,
--     but saveQuestions didn't, so tutor saw success but DB unchanged.
--   Layer C — UX confusion: Edit (metadata) vs Questions (bank) are two separate
--     modals; tutor expected Edit to include question editing. Edit modal had no
--     link to Questions, and saveQuestions draft toast was subtle.
--   Layer D — No server-side fallback: direct table update depends on PostgREST
--     RLS cache; if policy stale (after schema change) or role mismatch, blocked.
--
-- Issue 2: Ensure registered student is not allowed to do registered CBTs that
--   belong to another class. For every registered CBT, only students in that
--   class should be able to do it; others receive warning and blocked.
--
-- Deep audit:
--   Before V12.32, cbt_get_public_exam_v6 and cbt_submit_v6 checked:
--     - admission_required, invalid_admission, not_on_roster
--   but NOT class match. So JSS 1 student could take SSS 2 exam by guessing
--   code, or JSS 2 student could take JSS 1 exam — against school policy.
--   No frontend or backend class gate existed.
--
-- Fix (robust, all-inclusive, self-contained, seamless):
-- A. SQL: Broaden cbt_exams update policy to allow admin/owner OR subject/class
--    teacher (teacher_can_manage_subject_class / sc_cbt_subject_allowed). This
--    matches insert/select permissiveness and school reality where any teacher
--    of that subject/class should manage exams.
-- B. SQL: New RPC cbt_set_question_bank(p_exam_id uuid, p_bank jsonb) SECURITY
--    DEFINER with internal permission check (admin/owner/subject teacher).
--    Frontend tries RPC first (bypasses RLS reliably), falls back to direct
--    update with .select() verification + legible RLS error translation.
-- C. SQL: Overwrite cbt_get_public_exam_v6 and cbt_submit_v6 (V12.32, engine
--    v5.6.2-class) to add class enforcement for registered mode:
--      if exam.class non-empty, compare normalized exam_class (upper alnum only)
--      vs student.class and student full (class+arm). Allow only if student
--      class equals exam class OR full class starts with exam class (covers arms
--      like JSS 1 exam allowing JSS 1 A/B). Otherwise return wrong_class error
--      with clear message naming both classes and blocking exam start/submit.
--    Roster check remains additional (if roster non-empty).
-- D. JS: Enhance cbt.html saveQuestions to show progress, validate bank,
--    call cbt_set_question_bank RPC, handle RLS/permission errors legibly,
--    verify rows, toast success with count, then refresh list. Enhance edit()
--    modal to include explicit "Edit Questions" guidance card with button to
--    open question editor. Enhance cbt-exam.html identityEntry/load to handle
--    wrong_class error (show notice + block, allow change code).
-- E. Markers + grants + complete-schema embed.
--
-- Idempotent. No paid AI APIs.
-- ============================================================================
select 'RUNNING: School Connect CBT edit persistence + class-scoped registered exams pack V12.32' as running_version;

-- 0. Ensure columns exist (idempotent)
alter table public.cbt_exams add column if not exists teacher_id uuid references public.profiles(id) on delete set null;
alter table public.cbt_exams add column if not exists code text;
alter table public.cbt_exams add column if not exists csv_data jsonb default '[]'::jsonb;
alter table public.cbt_exams add column if not exists questions jsonb default '[]'::jsonb;

-- 1. Broaden CBT update policy: admin/owner OR subject/class teacher can edit
drop policy if exists cbt_exam_scope_update on public.cbt_exams;
create policy cbt_exam_scope_update on public.cbt_exams for update
  using (
    public.is_admin(auth.uid())
    or teacher_id = auth.uid()
    or public.teacher_can_manage_subject_class(auth.uid(), subject, class)
    or public.sc_cbt_subject_allowed(auth.uid(), subject, class)
  )
  with check (
    public.is_admin(auth.uid())
    or teacher_id = auth.uid()
    or public.teacher_can_manage_subject_class(auth.uid(), subject, class)
    or public.sc_cbt_subject_allowed(auth.uid(), subject, class)
  );

-- 2. Helper: class match (used by both v6 functions) — kept inline for self-containment,
--    but also create a reusable function for future use
create or replace function public.cbt_is_class_match(p_exam_class text, p_student_class text, p_student_arm text default '')
returns boolean language sql stable set search_path=public as $$
  select
    coalesce(trim(p_exam_class),'') = ''
    or (
      upper(regexp_replace(trim(coalesce(p_exam_class,'')), '[^A-Z0-9]', '', 'g'))
      =
      upper(regexp_replace(trim(coalesce(p_student_class,'')), '[^A-Z0-9]', '', 'g'))
    )
    or (
      upper(regexp_replace(trim(coalesce(p_student_class,'')||' '||coalesce(p_student_arm,'')), '[^A-Z0-9]', '', 'g'))
      =
      upper(regexp_replace(trim(coalesce(p_exam_class,'')), '[^A-Z0-9]', '', 'g'))
    )
    or (
      upper(regexp_replace(trim(coalesce(p_student_class,'')||' '||coalesce(p_student_arm,'')), '[^A-Z0-9]', '', 'g'))
      like
      upper(regexp_replace(trim(coalesce(p_exam_class,'')), '[^A-Z0-9]', '', 'g')) || '%'
    )
    or (
      upper(regexp_replace(trim(coalesce(p_student_class,'')), '[^A-Z0-9]', '', 'g'))
      like
      upper(regexp_replace(trim(coalesce(p_exam_class,'')), '[^A-Z0-9]', '', 'g')) || '%'
    );
$$;
grant execute on function public.cbt_is_class_match(text,text,text) to anon, authenticated;

-- 3. RPC: robust question-bank update (bypasses RLS with internal check)
drop function if exists public.cbt_set_question_bank(uuid, jsonb) cascade;
create or replace function public.cbt_set_question_bank(p_exam_id uuid, p_bank jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  e record;
  me uuid := auth.uid();
  is_allowed boolean := false;
  bank jsonb := coalesce(p_bank, '[]'::jsonb);
begin
  if me is null then
    return jsonb_build_object('ok',false,'error','Not authenticated','message','You must be logged in as the teacher who created this exam or an admin. Run the login, then retry.');
  end if;
  if p_exam_id is null then return jsonb_build_object('ok',false,'error','Exam id required','message','Exam identifier is missing.'); end if;
  if jsonb_typeof(bank) <> 'array' then return jsonb_build_object('ok',false,'error','Question bank must be a JSON array','message','The question bank must be a JSON array.'); end if;
  if jsonb_array_length(bank) = 0 then return jsonb_build_object('ok',false,'error','Question bank cannot be empty','message','Question bank cannot be empty — add at least one question.'); end if;
  select * into e from public.cbt_exams where id = p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found','message','No exam matches that id. Refresh the list and try again.'); end if;
  if public.is_admin(me) then is_allowed := true;
  elsif e.teacher_id = me then is_allowed := true;
  elsif public.teacher_can_manage_subject_class(me, e.subject, e.class) then is_allowed := true;
  elsif public.sc_cbt_subject_allowed(me, e.subject, e.class) then is_allowed := true;
  end if;
  if not is_allowed then
    return jsonb_build_object('ok',false,'error','Permission denied','message','Only an admin, the exam owner, or a teacher of '||coalesce(e.subject,'this subject')||' / '||coalesce(e.class,'this class')||' can edit these questions. Ask an admin to assign you to this subject/class.');
  end if;
  update public.cbt_exams set csv_data = bank, questions = bank, updated_at = now() where id = p_exam_id;
  return jsonb_build_object('ok',true,'message','Question bank updated ('||jsonb_array_length(bank)||' questions)','exam_id',p_exam_id,'count',jsonb_array_length(bank),'engine_version','v5.6.2-class');
end$$;
revoke execute on function public.cbt_set_question_bank(uuid, jsonb) from public, anon;
grant execute on function public.cbt_set_question_bank(uuid, jsonb) to authenticated;
grant execute on function public.cbt_set_question_bank(uuid, jsonb) to anon;

-- 4. Overwrite cbt_get_public_exam_v6 with class enforcement (registered mode only)
create or replace function public.cbt_get_public_exam_v6(p_code text,p_admission_no text default '')
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare
 base jsonb;exam_row public.cbt_exams%rowtype;student_row public.students%rowtype;
 candidate jsonb:='null'::jsonb;wanted text:=regexp_replace(upper(coalesce(p_admission_no,'')),'[^A-Z0-9]','','g');roster_count integer:=0;
 exam_norm text; stud_norm text; stud_full_norm text;
begin
 base:=public.cbt_get_public_exam_v5(p_code);if not coalesce((base->>'ok')::boolean,false)then return base;end if;
 select ce.* into exam_row from public.cbt_exams ce where ce.id=(base->>'id')::uuid;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found','message','The examination record is no longer available.','engine_version','v5.6.2-class');end if;
 if lower(coalesce(exam_row.exam_mode,'open'))='registered'then
  if wanted=''then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','admission_required','message','This examination is restricted to registered students. Enter your admission number; your official name and class will be loaded automatically.','identity_mode','registered','engine_version','v5.6.2-class');end if;
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted and coalesce(st.status,'active')in('active','approved')limit 1;
  if not found then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','invalid_admission','message','No active registered student matches that admission number. Contact the school—do not type a name manually.','identity_mode','registered','engine_version','v5.6.2-class');end if;
  -- V12.32: class-scoped gate — only students in exam's class may sit this registered exam
  if coalesce(trim(exam_row.class),'') <> '' then
    exam_norm := upper(regexp_replace(trim(exam_row.class), '[^A-Z0-9]', '', 'g'));
    stud_norm := upper(regexp_replace(trim(coalesce(student_row.class,'')), '[^A-Z0-9]', '', 'g'));
    stud_full_norm := upper(regexp_replace(trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')), '[^A-Z0-9]', '', 'g'));
    if exam_norm <> '' and stud_norm <> '' then
      if stud_norm <> exam_norm and stud_full_norm <> exam_norm and stud_full_norm not like exam_norm || '%' and stud_norm not like exam_norm || '%' then
        return (base-'questions'-'_questions') || jsonb_build_object(
          'ok',false,
          'error','wrong_class',
          'message','This examination is for class '||exam_row.class||' only. Your registered class is '||trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,''))||'. You cannot take CBTs for another class — contact your class teacher or exam officer.',
          'identity_mode','registered',
          'exam_class',exam_row.class,
          'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')),
          'engine_version','v5.6.2-class'
        );
      end if;
    end if;
  end if;
  select count(*)into roster_count from public.cbt_roster cr where cr.exam_id=exam_row.id;
  if roster_count>0 and not exists(select 1 from public.cbt_roster cr where cr.exam_id=exam_row.id and regexp_replace(upper(coalesce(cr.student_id_ref,'')),'[^A-Z0-9]','','g')=wanted)then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','not_on_roster','message','This registered student is not on the roster for this examination.','identity_mode','registered','engine_version','v5.6.2-class');end if;
  candidate:=jsonb_build_object('id',student_row.id,'admission_no',student_row.admission_no,'full_name',student_row.full_name,'class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));
  return base||jsonb_build_object('identity_mode','registered','candidate',candidate,'identity_engine_version','v5.6.2-class');
 end if;
 -- Open/multi-subject exams may start without admission. Never read an unassigned record.
 if wanted<>''then
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted limit 1;
  if found then candidate:=jsonb_build_object('id',student_row.id,'admission_no',student_row.admission_no,'full_name',student_row.full_name,'class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));end if;
 end if;
 return base||jsonb_build_object('identity_mode','open','candidate',candidate,'identity_engine_version','v5.6.2-class');
end$$;
revoke execute on function public.cbt_get_public_exam_v6(text,text) from public;
grant execute on function public.cbt_get_public_exam_v6(text,text) to anon, authenticated;

-- 5. Overwrite cbt_submit_v6 with same class gate
create or replace function public.cbt_submit_v6(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare exam_row public.cbt_exams%rowtype;student_row public.students%rowtype;wanted text:='';roster_count integer:=0;payload jsonb:=coalesce(p_payload,'{}'::jsonb);
 exam_norm text; stud_norm text; stud_full_norm text;
begin
 select ce.* into exam_row from public.cbt_exams ce where ce.id=(p_payload->>'exam_id')::uuid;
 if not found then return jsonb_build_object('saved',false,'error','exam_not_found','message','Exam not found.','engine_version','v5.6.2-class');end if;
 if lower(coalesce(exam_row.exam_mode,'open'))='registered'then
  wanted:=regexp_replace(upper(coalesce(p_payload->>'student_id_ref','')),'[^A-Z0-9]','','g');if wanted=''then return jsonb_build_object('saved',false,'error','admission_required','message','Admission number is required.','engine_version','v5.6.2-class');end if;
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted and coalesce(st.status,'active')in('active','approved')limit 1;
  if not found then return jsonb_build_object('saved',false,'error','invalid_admission','message','Registered student not found.','engine_version','v5.6.2-class');end if;
  -- V12.32: class gate at submit (defence in depth)
  if coalesce(trim(exam_row.class),'') <> '' then
    exam_norm := upper(regexp_replace(trim(exam_row.class), '[^A-Z0-9]', '', 'g'));
    stud_norm := upper(regexp_replace(trim(coalesce(student_row.class,'')), '[^A-Z0-9]', '', 'g'));
    stud_full_norm := upper(regexp_replace(trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')), '[^A-Z0-9]', '', 'g'));
    if exam_norm <> '' and stud_norm <> '' then
      if stud_norm <> exam_norm and stud_full_norm <> exam_norm and stud_full_norm not like exam_norm || '%' and stud_norm not like exam_norm || '%' then
        return jsonb_build_object('saved',false,'error','wrong_class','message','This examination is for class '||exam_row.class||' only. Your registered class is '||trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,''))||'. Submission blocked — you cannot take CBTs for another class.','engine_version','v5.6.2-class','exam_class',exam_row.class,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));
      end if;
    end if;
  end if;
  select count(*)into roster_count from public.cbt_roster cr where cr.exam_id=exam_row.id;
  if roster_count>0 and not exists(select 1 from public.cbt_roster cr where cr.exam_id=exam_row.id and regexp_replace(upper(coalesce(cr.student_id_ref,'')),'[^A-Z0-9]','','g')=wanted)then return jsonb_build_object('saved',false,'error','not_on_roster','message','Student is not on this exam roster.','engine_version','v5.6.2-class');end if;
  payload:=payload||jsonb_build_object('student_id',student_row.id,'student_id_ref',student_row.admission_no,'student_name',student_row.full_name,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')),'student_type','registered');
 elsif coalesce(p_payload->>'student_id_ref','')<>''then
  wanted:=regexp_replace(upper(p_payload->>'student_id_ref'),'[^A-Z0-9]','','g');select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted limit 1;
  if found then payload:=payload||jsonb_build_object('student_id',student_row.id,'student_id_ref',student_row.admission_no,'student_name',student_row.full_name,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));end if;
 end if;
 return public.cbt_submit_v5(payload);
exception when invalid_text_representation then return jsonb_build_object('saved',false,'error','invalid_exam_id','message','The exam identifier is invalid. Reload the exam and try again.','engine_version','v5.6.2-class');
end$$;
revoke execute on function public.cbt_submit_v6(jsonb) from public;
grant execute on function public.cbt_submit_v6(jsonb) to anon, authenticated;

-- Markers
insert into public.sc_install_state(key,details) values ('v12.32-cbt-edit-and-class-fix.sql','{"self":true}') on conflict (key) do nothing;
insert into public.sc_install_state(key,details) values ('v12.31-cbt-retake-robust.sql','{"self":true,"retro":"v12.32"}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.32 CBT edit persistence + class-scoped registered exams pack installed — questions now persist and registered CBTs are class-restricted' as status;
