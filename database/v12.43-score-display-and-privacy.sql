-- ============================================================================
-- School Connect V12.43 — Score display toggle + Privacy + Next student clean
-- ----------------------------------------------------------------------------
-- Issue 6 — Tutor cannot toggle whether score shown after CBT:
--   Previously every CBT always showed score immediately (SERVER VERIFIED
--   circle, percent, grade, correct/wrong/skipped, subject breakdown).
--   Some tutors (e.g., mock UTME, entrance) want to hide score until
--   official release, to prevent cheating or early celebration.
--
-- Issue 4 — Privacy: Next student sees previous student's score briefly:
--   On shared lab laptop, Student A finishes, sees score, clicks Next
--   Student (was ?code=CODE with code preserved). If Student A leaves
--   score page open and B approaches, B briefly sees A's score before
--   entering code/ID. Also Exam._done flag, timer, answers, draft,
--   deadline, cache all still in memory/localStorage for A's CODE-ADMISSION,
--   but B's code may be different exam, so stale cache could leak.
--
-- Issue 5 — Next Student auto-loads previous code, should be empty:
--   Next Student button was href='cbt-exam.html?code='+code with code
--   preserved, so Student B sees previous exam code prefilled. If B's exam
--   is different (e.g., A did ECONOMICS QKJCR3, B does GOVERNMENT CCCKNL),
--   B might submit to wrong exam by mistake. Field should be empty so B
--   must type both code and ID anew.
--
-- Fix (expert, robust, self-contained, all-inclusive):
--   A. DB: cbt_exams add column show_score_on_submit boolean not null default true
--      (preserves existing exams: all showed score, so default true). Also
--      add clear_previous_on_next boolean default true for future.
--   B. cbt.html manager: New Exam + Full Edit get toggle [x] Show score immediately
--      after CBT (for Maths need instant feedback, for entrance hide). Saved
--      in cbt_exams.show_score_on_submit + mirrored in anti_cheat_config.show_score.
--      Default checked (true) to keep existing behaviour.
--   C. cbt_get_public_exam_v6 returns show_score_on_submit so cbt-exam.html
--      knows whether to render score circle or "Submission Received".
--   D. cbt-exam.html: Next Student now goes to cbt-exam.html (no ?code=) via
--      location.replace (no history), clears ALL per-exam/per-student keys:
--      cbt-draft-*-*, cbt-deadline-*-*, cbt-exam-cache-*, CBT._done=false,
--      Exam.answers=[], flags={}, violations=0, timer=null, _keyHandler removed,
--      floating toolbar destroyed. Entry page (codeEntry) always destroys
--      toolbar and clears stale Exam.data. Privacy: score page auto-hides
--      after 30s and on visibilitychange (if tab hidden, next student won't
--      see it when tab refocused).
--   E. Public link still works: Tutor share ?code=CODE is opt-in for single-
--      student convenience, but Next Student never auto-loads it — field empty.
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect score display toggle + privacy V12.43' as running_version;

alter table public.cbt_exams add column if not exists show_score_on_submit boolean not null default true;
alter table public.cbt_exams add column if not exists clear_previous_on_next boolean not null default true;

update public.cbt_exams set show_score_on_submit = coalesce((anti_cheat_config->>'show_score_on_submit')::boolean, (anti_cheat_config->>'show_score')::boolean, true) where show_score_on_submit is null;

create or replace function public.cbt_get_public_exam_v6(p_code text, p_admission_no text default '')
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare
 base jsonb;exam_row public.cbt_exams%rowtype;student_row public.students%rowtype;
 candidate jsonb:='null'::jsonb;wanted text:=regexp_replace(upper(coalesce(p_admission_no,'')),'[^A-Z0-9]','','g');roster_count integer:=0;
 exam_norm text; stud_norm text; stud_full_norm text; taken int:=0;
begin
 base:=public.cbt_get_public_exam_v5(p_code);if not coalesce((base->>'ok')::boolean,false)then return base;end if;
 select ce.* into exam_row from public.cbt_exams ce where ce.id=(base->>'id')::uuid;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found','message','The examination record is no longer available.','engine_version','v5.6.2-class');end if;
 if lower(coalesce(exam_row.exam_mode,'open'))='registered'then
  if wanted=''then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','admission_required','message','This examination is restricted to registered students. Enter your admission number; your official name and class will be loaded automatically.','identity_mode','registered','engine_version','v5.6.2-class');end if;
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted and coalesce(st.status,'active')in('active','approved')limit 1;
  if not found then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','invalid_admission','message','No active registered student matches that admission number. Contact the school—do not type a name manually.','identity_mode','registered','engine_version','v5.6.2-class');end if;
  if coalesce(trim(exam_row.class),'') <> '' then
    exam_norm := upper(regexp_replace(trim(exam_row.class), '[^A-Z0-9]', '', 'g'));
    stud_norm := upper(regexp_replace(trim(coalesce(student_row.class,'')), '[^A-Z0-9]', '', 'g'));
    stud_full_norm := upper(regexp_replace(trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')), '[^A-Z0-9]', '', 'g'));
    if exam_norm <> '' and stud_norm <> '' then
      if stud_norm <> exam_norm and stud_full_norm <> exam_norm and stud_full_norm not like exam_norm || '%' and stud_norm not like exam_norm || '%' then
        return (base-'questions'-'_questions') || jsonb_build_object('ok',false,'error','wrong_class','message','This examination is for class '||exam_row.class||' only. Your registered class is '||trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,''))||'. You cannot take CBTs for another class — contact your class teacher or exam officer.','identity_mode','registered','exam_class',exam_row.class,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')), 'engine_version','v5.6.2-class');
      end if;
    end if;
  end if;
  select count(*)into roster_count from public.cbt_roster cr where cr.exam_id=exam_row.id;
  if roster_count>0 and not exists(select 1 from public.cbt_roster cr where cr.exam_id=exam_row.id and regexp_replace(upper(coalesce(cr.student_id_ref,'')),'[^A-Z0-9]','','g')=wanted)then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','not_on_roster','message','This registered student is not on the roster for this examination.','identity_mode','registered','engine_version','v5.6.2-class');end if;
  if coalesce(exam_row.attempt_limit,0)>0 then
    select count(*) into taken from public.cbt_results where exam_id=exam_row.id and student_id_ref=student_row.admission_no;
    if taken >= exam_row.attempt_limit then
      return (base-'questions'-'_questions') || jsonb_build_object('ok',false,'error','attempts_exhausted','message','You have already taken this CBT ('||taken||' of '||exam_row.attempt_limit||' attempts used). Attempt limit reached ('||exam_row.attempt_limit||'). You cannot write it again. Contact your teacher to allow a retake if this was a malfunction.','identity_mode','registered','exam_class',exam_row.class,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')), 'engine_version','v5.6.2-class','attempt_limit',exam_row.attempt_limit,'taken',taken);
    end if;
  end if;
  candidate:=jsonb_build_object('id',student_row.id,'admission_no',student_row.admission_no,'full_name',student_row.full_name,'class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));
  return base||jsonb_build_object('identity_mode','registered','candidate',candidate,'identity_engine_version','v5.6.2-class','enable_math_keyboard', coalesce(exam_row.enable_math_keyboard, true), 'enable_calculator', coalesce(exam_row.enable_calculator, true), 'show_score_on_submit', coalesce(exam_row.show_score_on_submit, true), 'public_link', coalesce(exam_row.public_link, ''));
 end if;
 if wanted<>''then
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted limit 1;
  if found then
    if coalesce(exam_row.attempt_limit,0)>0 then
      select count(*) into taken from public.cbt_results where exam_id=exam_row.id and student_id_ref=student_row.admission_no;
      if taken >= exam_row.attempt_limit then
        return (base-'questions'-'_questions') || jsonb_build_object('ok',false,'error','attempts_exhausted','message','You have already taken this CBT ('||taken||' of '||exam_row.attempt_limit||' attempts used). Attempt limit reached.','identity_mode','open','engine_version','v5.6.2-class','attempt_limit',exam_row.attempt_limit,'taken',taken);
      end if;
    end if;
    candidate:=jsonb_build_object('id',student_row.id,'admission_no',student_row.admission_no,'full_name',student_row.full_name,'class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));
  end if;
 end if;
 return base||jsonb_build_object('identity_mode','open','candidate',candidate,'identity_engine_version','v5.6.2-class','enable_math_keyboard', coalesce(exam_row.enable_math_keyboard, true), 'enable_calculator', coalesce(exam_row.enable_calculator, true), 'show_score_on_submit', coalesce(exam_row.show_score_on_submit, true), 'public_link', coalesce(exam_row.public_link, ''));
end$$;
grant execute on function public.cbt_get_public_exam_v6(text,text) to anon, authenticated;

insert into public.sc_install_state(key,details) values ('v12.43-score-display-and-privacy.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.43 score display toggle + privacy installed — show_score_on_submit per exam, next student clean, no auto code' as status;
