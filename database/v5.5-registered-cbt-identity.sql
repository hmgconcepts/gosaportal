-- School Connect V5.5 focused registered CBT identity upgrade. Back up first.
-- V5.5 registered-exam identity: admission number resolves the official student.
create or replace function public.cbt_get_public_exam_v6(p_code text,p_admission_no text default '')
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare
 base jsonb;exam_row public.cbt_exams%rowtype;student_row public.students%rowtype;
 candidate jsonb:='null'::jsonb;wanted text:=regexp_replace(upper(coalesce(p_admission_no,'')),'[^A-Z0-9]','','g');roster_count integer:=0;
begin
 base:=public.cbt_get_public_exam_v5(p_code);if not coalesce((base->>'ok')::boolean,false)then return base;end if;
 select ce.* into exam_row from public.cbt_exams ce where ce.id=(base->>'id')::uuid;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found','message','The examination record is no longer available.','engine_version','v5.6.1');end if;
 if lower(coalesce(exam_row.exam_mode,'open'))='registered'then
  if wanted=''then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','admission_required','message','This examination is restricted to registered students. Enter your admission number; your official name and class will be loaded automatically.','identity_mode','registered');end if;
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted and coalesce(st.status,'active')in('active','approved')limit 1;
  if not found then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','invalid_admission','message','No active registered student matches that admission number. Contact the school—do not type a name manually.','identity_mode','registered');end if;
  select count(*)into roster_count from public.cbt_roster cr where cr.exam_id=exam_row.id;
  if roster_count>0 and not exists(select 1 from public.cbt_roster cr where cr.exam_id=exam_row.id and regexp_replace(upper(coalesce(cr.student_id_ref,'')),'[^A-Z0-9]','','g')=wanted)then return(base-'questions'-'_questions')||jsonb_build_object('ok',false,'error','not_on_roster','message','This registered student is not on the roster for this examination.','identity_mode','registered');end if;
  candidate:=jsonb_build_object('id',student_row.id,'admission_no',student_row.admission_no,'full_name',student_row.full_name,'class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));
  return base||jsonb_build_object('identity_mode','registered','candidate',candidate,'identity_engine_version','v5.6.1');
 end if;
 -- Open/multi-subject exams may start without admission. Never read an unassigned record.
 if wanted<>''then
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted limit 1;
  if found then candidate:=jsonb_build_object('id',student_row.id,'admission_no',student_row.admission_no,'full_name',student_row.full_name,'class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));end if;
 end if;
 return base||jsonb_build_object('identity_mode','open','candidate',candidate,'identity_engine_version','v5.6.1');
end$$;

create or replace function public.cbt_submit_v6(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare exam_row public.cbt_exams%rowtype;student_row public.students%rowtype;wanted text:='';roster_count integer:=0;payload jsonb:=coalesce(p_payload,'{}'::jsonb);
begin
 select ce.* into exam_row from public.cbt_exams ce where ce.id=(p_payload->>'exam_id')::uuid;
 if not found then return jsonb_build_object('saved',false,'error','exam_not_found','message','Exam not found.','engine_version','v5.6.1');end if;
 if lower(coalesce(exam_row.exam_mode,'open'))='registered'then
  wanted:=regexp_replace(upper(coalesce(p_payload->>'student_id_ref','')),'[^A-Z0-9]','','g');if wanted=''then return jsonb_build_object('saved',false,'error','admission_required','message','Admission number is required.','engine_version','v5.6.1');end if;
  select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted and coalesce(st.status,'active')in('active','approved')limit 1;
  if not found then return jsonb_build_object('saved',false,'error','invalid_admission','message','Registered student not found.','engine_version','v5.6.1');end if;
  select count(*)into roster_count from public.cbt_roster cr where cr.exam_id=exam_row.id;
  if roster_count>0 and not exists(select 1 from public.cbt_roster cr where cr.exam_id=exam_row.id and regexp_replace(upper(coalesce(cr.student_id_ref,'')),'[^A-Z0-9]','','g')=wanted)then return jsonb_build_object('saved',false,'error','not_on_roster','message','Student is not on this exam roster.','engine_version','v5.6.1');end if;
  payload:=payload||jsonb_build_object('student_id',student_row.id,'student_id_ref',student_row.admission_no,'student_name',student_row.full_name,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')),'student_type','registered');
 elsif coalesce(p_payload->>'student_id_ref','')<>''then
  wanted:=regexp_replace(upper(p_payload->>'student_id_ref'),'[^A-Z0-9]','','g');select st.* into student_row from public.students st where regexp_replace(upper(coalesce(st.admission_no,'')),'[^A-Z0-9]','','g')=wanted limit 1;
  if found then payload:=payload||jsonb_build_object('student_id',student_row.id,'student_id_ref',student_row.admission_no,'student_name',student_row.full_name,'student_class',trim(coalesce(student_row.class,'')||' '||coalesce(student_row.arm,'')));end if;
 end if;
 return public.cbt_submit_v5(payload);
exception when invalid_text_representation then return jsonb_build_object('saved',false,'error','invalid_exam_id','message','The exam identifier is invalid. Reload the exam and try again.','engine_version','v5.6.1');
end$$;
revoke execute on function public.cbt_get_public_exam_v6(text,text)from public;grant execute on function public.cbt_get_public_exam_v6(text,text)to anon,authenticated;
revoke execute on function public.cbt_submit_v6(jsonb)from public;grant execute on function public.cbt_submit_v6(jsonb)to anon,authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.5 registered CBT identity installed ✅'as status;
