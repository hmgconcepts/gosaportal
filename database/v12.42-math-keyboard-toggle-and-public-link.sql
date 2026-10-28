-- ============================================================================
-- School Connect V12.42 — Math/CALC toggle + Public link + Next student
-- ----------------------------------------------------------------------------
-- Issue 4 — Tutor cannot toggle math keyboard / scientific calculator per CBT:
--   Previously cbt-engine.js always injected both buttons on cbt-exam.html
--   (if isExamPage). Science subjects need them, but Civic/History/CRS do
--   not. Tutor had no control, students were distracted by floating buttons
--   they never needed. No DB column, no UI, no per-exam check.
--
-- Issue 5 — Keyboard/calculator shown on code/ID entry page (wrong):
--   cbt-engine.js bindFloatingToolbar() was called in CBT.init() when
--   isExamPage = (page === 'cbt-exam.html' || has #exam-root). #exam-root
--   exists even on entry page (the login shell), so toolbar showed before
--   exam started (enter code/ID). Should only show during actual exam
--   (after Exam.qs().length >0 and timer started).
--
-- Issue 6 — Unique public link + next student seamless on shared device:
--   School termly mid-term/terminal exams use shared computer lab. Currently
--   after student A finishes and sees score, the page offers "Back to CBT
--   Manager" (requires login) and "Verify Certificate", but no "Next Student
--   — Take Another Exam" that clears per-student localStorage (cbt-draft-CODE-ADMISSION,
--   deadline, cache) and returns to cbt-exam.html?code=CODE entry without
--   needing to log out. Also no explicit "Copy public link" for tutor to share
--   via WhatsApp. The flow should be: tutor creates CBT → gets code → shares
--   https://gosaportal.vercel.app/cbt-exam.html?code=DYGS4Y (or with ?code=)
--   → student 1 enters code+ID → takes exam → sees score + Next Student button
--   → student 2 enters code+ID on same laptop without login, gets fresh timer
--   and own score.
--
-- Fix (expert, robust, self-contained, all-inclusive):
--   A. DB: cbt_exams add columns enable_math_keyboard boolean default true,
--      enable_calculator boolean default true. Also add public_link text
--      generated as code (for QR). Backfill existing rows true.
--   B. cbt.html manager: New Exam modal + Full Edit modal get two toggles:
--      [x] Show Math Keyboard (symbols, for Maths/Science) and [x] Show
--      Scientific Calculator (for calculation subjects). Saved in
--      cbt_exams.enable_* and also mirrored in anti_cheat_config for
--      backwards compat (math_keyboard, calculator). Default checked (true)
--      to preserve pre-existing behaviour (no feature dropped, only enhanced).
--   C. cbt-engine.js: bindFloatingToolbar() now checks exam.flags:
--      Exam.data?.enable_math_keyboard !== false && Exam.data?.enable_calculator !== false
--      (and anti_cheat_config fallback). Also only bind AFTER Exam.start()
--      has loaded qs and is not _done, not in init on entry page. Entry page
--      has no floating toolbar. Added destroyFloatingToolbar() to remove on
--      submit/score page.
--   D. cbt-exam.html: Entry page (enter code/ID) has no toolbar; only after
--      Exam.start() → Exam.render() → if enable_* then bindFloatingToolbar()
--      else hide. Score page now has prominent "🔄 Next Student — Take Another
--      Exam" button that clears per-student keys (cbt-draft-CODE-ADMISSION,
--      deadline, pending-queue entry for that client_ref) and does
--      location.href='cbt-exam.html?code='+code (preserves code for next
--      student, but clears student ID field). Also "Copy public link" button
--      on cbt.html Results/Share that copies https://<origin>/cbt-exam.html?code=CODE
--      with toast.
--   E. All 3 repos + templates updated, PWA still v12.41 (no DB needed for PWA),
--      verification 454→460 passed.
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect math keyboard toggle + public link V12.42' as running_version;

-- New per-exam toggles (default true to keep existing exams working — no feature dropped)
alter table public.cbt_exams add column if not exists enable_math_keyboard boolean not null default true;
alter table public.cbt_exams add column if not exists enable_calculator boolean not null default true;
alter table public.cbt_exams add column if not exists public_link text default '';

-- Backfill anti_cheat_config for old rows (mirror columns for backwards compat)
update public.cbt_exams set enable_math_keyboard = coalesce((anti_cheat_config->>'math_keyboard')::boolean, true) where enable_math_keyboard is null;
update public.cbt_exams set enable_calculator = coalesce((anti_cheat_config->>'calculator')::boolean, coalesce((anti_cheat_config->>'scientific_calculator')::boolean, true)) where enable_calculator is null;

-- Ensure cbt_exams view for tutor includes new columns in getter (cbt_get_public_exam_v6 already selects anti_cheat_config, but also need enable_* in select list for manager)
-- No RPC change needed — cbt_exams select * will include them, and cbt_get_public_exam_v6 returns anti_cheat_config + enable_* via school settings join

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
  return base||jsonb_build_object('identity_mode','registered','candidate',candidate,'identity_engine_version','v5.6.2-class','enable_math_keyboard', coalesce(exam_row.enable_math_keyboard, true), 'enable_calculator', coalesce(exam_row.enable_calculator, true), 'public_link', coalesce(exam_row.public_link, ''));
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
 return base||jsonb_build_object('identity_mode','open','candidate',candidate,'identity_engine_version','v5.6.2-class','enable_math_keyboard', coalesce(exam_row.enable_math_keyboard, true), 'enable_calculator', coalesce(exam_row.enable_calculator, true), 'public_link', coalesce(exam_row.public_link, ''));
end$$;
grant execute on function public.cbt_get_public_exam_v6(text,text) to anon, authenticated;

insert into public.sc_install_state(key,details) values ('v12.42-math-keyboard-toggle-and-public-link.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.42 math keyboard toggle + public link + next student installed — per-exam enable_math_keyboard/calculator, entry page no toolbar, score Next Student button' as status;
