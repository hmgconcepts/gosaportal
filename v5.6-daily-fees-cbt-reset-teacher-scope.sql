-- School Connect V5.6 focused upgrade. Back up Supabase first.
-- V5.6 daily fee collection authority (Africa/Lagos school date).
alter table public.fee_payments add column if not exists payment_date date default ((now() at time zone 'Africa/Lagos')::date);
alter table public.fee_payments add column if not exists received_by_name text default '';
update public.fee_payments set payment_date=(created_at at time zone 'Africa/Lagos')::date where payment_date is null;
create index if not exists fee_payments_daily_idx on public.fee_payments(payment_date,created_at desc);
create index if not exists fee_payments_method_daily_idx on public.fee_payments(payment_date,method);
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.6 daily fee collection fields installed ✅'as status;

-- V5.6 controlled CBT result reset for exam reuse.
create or replace function public.cbt_clear_exam_results(p_exam_id uuid,p_confirm_code text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record;n int:=0;
begin
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'error','Exam not found');end if;
 if not(public.is_admin(auth.uid())or e.teacher_id=auth.uid())then return jsonb_build_object('ok',false,'error','Only an admin or the teacher who created this exam can clear its results.');end if;
 if upper(trim(coalesce(p_confirm_code,'')))<>upper(trim(e.code))then return jsonb_build_object('ok',false,'error','Confirmation code does not match.');end if;
 select count(*)into n from public.cbt_results where exam_id=p_exam_id;delete from public.cbt_results where exam_id=p_exam_id;
 return jsonb_build_object('ok',true,'deleted',n,'exam_id',p_exam_id,'code',e.code,'message','Results cleared. The exam can now collect a fresh set of attempts. Previously pushed report_scores are unchanged and should be audited separately if necessary.');
end$$;
revoke execute on function public.cbt_clear_exam_results(uuid,text)from public,anon;
grant execute on function public.cbt_clear_exam_results(uuid,text)to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.6 controlled CBT result reset installed ✅'as status;

-- V5.6 strict teacher subject/class isolation. Admin roles retain full control.
create or replace function public.teacher_can_manage_subject_class(p_uid uuid,p_subject text default '',p_class text default '')
returns boolean language plpgsql security definer stable set search_path=public as $$
declare pname text:='';srec record;subject_ok boolean:=false;class_ok boolean:=false;
begin
 if public.is_admin(p_uid)then return true;end if;
 select full_name into pname from public.profiles where id=p_uid and role in('teacher','staff')and status in('approved','active');if not found then return false;end if;
 select * into srec from public.staff where user_id=p_uid and coalesce(status,'active')='active'limit 1;
 if coalesce(trim(p_subject),'')<>''then
  subject_ok:=exists(select 1 from public.subjects su where lower(trim(su.name))=lower(trim(p_subject))and(su.teacher_id=p_uid or lower(trim(coalesce(su.teacher,'')))=lower(trim(pname))or(srec.id is not null and lower(trim(coalesce(su.teacher,'')))=lower(trim(srec.full_name)))or(srec.id is not null and p_subject=any(coalesce(srec.subjects,'{}'::text[])))));
 end if;
 if coalesce(trim(p_class),'')<>''then class_ok:=exists(select 1 from public.classes c where lower(trim(c.name))=lower(trim(p_class))and(lower(trim(coalesce(c.class_teacher,'')))=lower(trim(pname))or(srec.id is not null and lower(trim(coalesce(c.class_teacher,'')))=lower(trim(srec.full_name)))));end if;
 return subject_ok or class_ok;
end$$;
create or replace function public.teacher_can_manage_student(p_uid uuid,p_student uuid)
returns boolean language sql security definer stable set search_path=public as $$select public.is_admin(p_uid)or exists(select 1 from public.students s where s.id=p_student and public.teacher_can_manage_subject_class(p_uid,'',s.class))$$;
revoke execute on function public.teacher_can_manage_subject_class(uuid,text,text)from public,anon;grant execute on function public.teacher_can_manage_subject_class(uuid,text,text)to authenticated;
revoke execute on function public.teacher_can_manage_student(uuid,uuid)from public,anon;grant execute on function public.teacher_can_manage_student(uuid,uuid)to authenticated;

-- Remove accumulated overlapping policies on academic write tables, then install one clear contract.
do $$declare t text;p record;begin
 foreach t in array array['results','attendance','assignments','scheme_of_work','lesson_plans','cbt_exams','cbt_results','report_scores','affective_traits','psychomotor_traits','report_comments']loop
  for p in select policyname from pg_policies where schemaname='public'and tablename=t loop execute format('drop policy if exists %I on public.%I',p.policyname,t);end loop;
 end loop;
end$$;

create policy results_scope_select on public.results for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where s.id=results.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy results_scope_insert on public.results for insert with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy results_scope_update on public.results for update using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy results_scope_delete on public.results for delete using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));

create policy attendance_scope_select on public.attendance for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),'',class)or exists(select 1 from public.students s where s.id=attendance.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy attendance_scope_insert on public.attendance for insert with check(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)));
create policy attendance_scope_update on public.attendance for update using(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)))with check(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)));
create policy attendance_scope_delete on public.attendance for delete using(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)));

create policy assignments_scope_select on public.assignments for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))and s.class=assignments.class));
create policy assignments_scope_write on public.assignments for all using(public.is_admin(auth.uid())or(posted_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(posted_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy sow_scope_select on public.scheme_of_work for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))and s.class=scheme_of_work.class));
create policy sow_scope_write on public.scheme_of_work for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy lesson_scope_select on public.lesson_plans for select using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy lesson_scope_write on public.lesson_plans for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));

create policy cbt_exam_scope_select on public.cbt_exams for select using(public.is_admin(auth.uid())or teacher_id=auth.uid()or public.teacher_can_manage_subject_class(auth.uid(),subject,class));
create policy cbt_exam_scope_insert on public.cbt_exams for insert with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy cbt_exam_scope_update on public.cbt_exams for update using(public.is_admin(auth.uid())or teacher_id=auth.uid())with check(public.is_admin(auth.uid())or teacher_id=auth.uid());
create policy cbt_exam_scope_delete on public.cbt_exams for delete using(public.is_admin(auth.uid())or teacher_id=auth.uid());
create policy cbt_result_scope_select on public.cbt_results for select using(public.is_admin(auth.uid())or exists(select 1 from public.cbt_exams e where e.id=cbt_results.exam_id and(e.teacher_id=auth.uid()or public.teacher_can_manage_subject_class(auth.uid(),e.subject,e.class)))or exists(select 1 from public.students s where s.id=cbt_results.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy cbt_result_no_direct_insert on public.cbt_results for insert with check(false);
create policy cbt_result_owner_delete on public.cbt_results for delete using(public.is_admin(auth.uid())or exists(select 1 from public.cbt_exams e where e.id=cbt_results.exam_id and e.teacher_id=auth.uid()));

create policy report_score_scope_select on public.report_scores for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where(s.id=report_scores.student_id or s.admission_no=report_scores.student_id_ref)and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy report_score_scope_insert on public.report_scores for insert with check(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy report_score_scope_update on public.report_scores for update using(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy report_score_scope_delete on public.report_scores for delete using(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));

create policy affective_scope_select on public.affective_traits for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=affective_traits.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy affective_scope_write on public.affective_traits for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
create policy psychomotor_scope_select on public.psychomotor_traits for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=psychomotor_traits.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy psychomotor_scope_write on public.psychomotor_traits for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
alter table public.report_comments add column if not exists teacher_id uuid references public.profiles(id)on delete set null;
create policy comments_scope_select on public.report_comments for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=report_comments.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create policy comments_scope_write on public.report_comments for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));

-- School structure is admin-managed; teachers read it through existing select policies.
do $$declare t text;p record;begin foreach t in array array['classes','subjects','departments','timetable_requirements','teacher_availability']loop for p in select policyname from pg_policies where schemaname='public'and tablename=t and cmd<>'SELECT'loop execute format('drop policy if exists %I on public.%I',p.policyname,t);end loop;execute format('create policy %I on public.%I for all using(public.is_admin(auth.uid()))with check(public.is_admin(auth.uid()))','admin_manage_'||t,t);end loop;end$$;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.6 strict teacher subject/class isolation installed ✅'as status;
drop policy if exists authenticated_read_classes on public.classes;create policy authenticated_read_classes on public.classes for select using(auth.role()='authenticated');
drop policy if exists authenticated_read_subjects on public.subjects;create policy authenticated_read_subjects on public.subjects for select using(auth.role()='authenticated');
drop policy if exists authenticated_read_departments on public.departments;create policy authenticated_read_departments on public.departments for select using(auth.role()='authenticated');
drop policy if exists scoped_read_timetable_requirements on public.timetable_requirements;create policy scoped_read_timetable_requirements on public.timetable_requirements for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class));
drop policy if exists scoped_read_teacher_availability on public.teacher_availability;create policy scoped_read_teacher_availability on public.teacher_availability for select using(public.is_admin(auth.uid())or lower(trim(teacher))=lower(trim(coalesce((select full_name from public.profiles where id=auth.uid()),''))));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- Additional teacher-owned/class-scoped operational records.
alter table public.digital_library add column if not exists teacher_id uuid references public.profiles(id)on delete set null;
alter table public.conduct add column if not exists recorded_by_id uuid references public.profiles(id)on delete set null;
alter table public.support_plans add column if not exists created_by uuid references public.profiles(id)on delete set null;
do $$declare t text;p record;begin foreach t in array array['digital_library','eresources','conduct','behaviour_points','support_plans','student_diary','student_term_metrics']loop for p in select policyname from pg_policies where schemaname='public'and tablename=t and cmd<>'SELECT'loop execute format('drop policy if exists %I on public.%I',p.policyname,t);end loop;end loop;end$$;
create policy dl_teacher_write on public.digital_library for all using(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy er_teacher_write on public.eresources for all using(public.is_admin(auth.uid())or(uploaded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(uploaded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
create policy conduct_teacher_write on public.conduct for all using(public.is_admin(auth.uid())or(recorded_by_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(recorded_by_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
create policy behaviour_teacher_write on public.behaviour_points for all using(public.is_admin(auth.uid())or(awarded_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(awarded_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
create policy support_teacher_write on public.support_plans for all using(public.is_admin(auth.uid())or(created_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(created_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
create policy diary_teacher_write on public.student_diary for all using(public.is_admin(auth.uid())or(created_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(created_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists metrics_staff_all on public.student_term_metrics;create policy metrics_teacher_write on public.student_term_metrics for all using(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.6 extended teacher ownership installed ✅'as status;
drop policy if exists dl_scope_read on public.digital_library;create policy dl_scope_read on public.digital_library for select using(auth.role()='authenticated');
drop policy if exists er_scope_read on public.eresources;create policy er_scope_read on public.eresources for select using(auth.role()='authenticated');
drop policy if exists conduct_scope_read on public.conduct;create policy conduct_scope_read on public.conduct for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=conduct.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
drop policy if exists behaviour_scope_read on public.behaviour_points;create policy behaviour_scope_read on public.behaviour_points for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=behaviour_points.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
drop policy if exists support_scope_read on public.support_plans;create policy support_scope_read on public.support_plans for select using(public.is_admin(auth.uid())or public.teacher_can_manage_student(auth.uid(),student_id)or exists(select 1 from public.students s where s.id=support_plans.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
drop policy if exists diary_scope_read on public.student_diary;create policy diary_scope_read on public.student_diary for select using(public.is_admin(auth.uid())or public.teacher_can_manage_subject_class(auth.uid(),subject,class)or exists(select 1 from public.students s where s.id=student_diary.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- V5.6 legacy-row claim rule: assigned teachers may claim an unowned row once;
-- owned rows remain editable/deletable only by that owner or admin.
drop policy if exists results_scope_update on public.results;create policy results_scope_update on public.results for update using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists results_scope_delete on public.results;create policy results_scope_delete on public.results for delete using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists attendance_scope_update on public.attendance;create policy attendance_scope_update on public.attendance for update using(public.is_admin(auth.uid())or((recorded_by=auth.uid()or recorded_by is null)and public.teacher_can_manage_subject_class(auth.uid(),'',class)))with check(public.is_admin(auth.uid())or(recorded_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),'',class)));
drop policy if exists attendance_scope_delete on public.attendance;create policy attendance_scope_delete on public.attendance for delete using(public.is_admin(auth.uid())or((recorded_by=auth.uid()or recorded_by is null)and public.teacher_can_manage_subject_class(auth.uid(),'',class)));
drop policy if exists assignments_scope_write on public.assignments;create policy assignments_scope_write on public.assignments for all using(public.is_admin(auth.uid())or((posted_by=auth.uid()or posted_by is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(posted_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists sow_scope_write on public.scheme_of_work;create policy sow_scope_write on public.scheme_of_work for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists lesson_scope_write on public.lesson_plans;create policy lesson_scope_write on public.lesson_plans for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists cbt_exam_scope_update on public.cbt_exams;create policy cbt_exam_scope_update on public.cbt_exams for update using(public.is_admin(auth.uid())or teacher_id=auth.uid()or(teacher_id is null and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or teacher_id=auth.uid());
drop policy if exists cbt_exam_scope_delete on public.cbt_exams;create policy cbt_exam_scope_delete on public.cbt_exams for delete using(public.is_admin(auth.uid())or teacher_id=auth.uid());
drop policy if exists report_score_scope_update on public.report_scores;create policy report_score_scope_update on public.report_scores for update using(public.is_admin(auth.uid())or((updated_by=auth.uid()or updated_by is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)))with check(public.is_admin(auth.uid())or(updated_by=auth.uid()and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists report_score_scope_delete on public.report_scores;create policy report_score_scope_delete on public.report_scores for delete using(public.is_admin(auth.uid())or((updated_by=auth.uid()or updated_by is null)and public.teacher_can_manage_subject_class(auth.uid(),subject,class)));
drop policy if exists affective_scope_write on public.affective_traits;create policy affective_scope_write on public.affective_traits for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
drop policy if exists psychomotor_scope_write on public.psychomotor_traits;create policy psychomotor_scope_write on public.psychomotor_traits for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
drop policy if exists comments_scope_write on public.report_comments;create policy comments_scope_write on public.report_comments for all using(public.is_admin(auth.uid())or((teacher_id=auth.uid()or teacher_id is null)and public.teacher_can_manage_student(auth.uid(),student_id)))with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.teacher_can_manage_student(auth.uid(),student_id)));
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');


-- V5.6.1 open/multi-subject CBT identity safety repair.
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
revoke execute on function public.cbt_get_public_exam_v6(text,text)from public;grant execute on function public.cbt_get_public_exam_v6(text,text)to anon,authenticated;revoke execute on function public.cbt_submit_v6(jsonb)from public;grant execute on function public.cbt_submit_v6(jsonb)to anon,authenticated;notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');select 'School Connect V5.6.1 open/multi-subject CBT repair installed ✅'as status;
