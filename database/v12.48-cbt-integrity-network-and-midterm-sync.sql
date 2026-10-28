-- ============================================================================
-- School Connect V12.48 — CBT integrity verification + synchronized midterm
-- ----------------------------------------------------------------------------
-- Fresh root-cause audit (live GOSA still v12.46 SW; submitted 20/20 error
-- reads: 20 vs 20 but hashes differ because JSON.stringify object key order,
-- _orig_index/id/default normalization differs between browser and jsonb output):
-- 1. Fix edit confirmation: server returns a canonical hash from JSONB, then
--    independent SECURITY DEFINER verifier recomputes hash from DB contents
--    bypassing RLS. Frontend compares hash/version, not client JSON string.
-- 2. Replace SW stale-while-revalidate for HTML/JS with network-first. Old
--    installed clients previously executed stale cbt.html/cbt-engine.js for
--    a navigation even after deploy, so old broken verification persisted.
-- 3. Midterm report sync: after report_scores insert/update/delete, refresh
--    matching midterm_report_cards from Midterm assessment columns only;
--    preserve published flag; terminal report_cards remain independent.
-- 4. Midterm family RLS: family sees only published rows (earlier policy let
--    parents query unpublished report before tutor released it).
-- 5. WAL recovery: failed row remains after answer_key_missing/closed/empty
--    bank; tutor can fix bank then re-run recovery. Error remains visible.
--
-- Additional expert safeguards: JSONB stable hashing, question bank version,
-- no false success toast until server verifies, and old-cache invalidation.
-- ============================================================================
select 'RUNNING: School Connect CBT integrity + network-first + midterm sync V12.48' as running_version;

-- Canonical DB-side verifier. Hash is computed from coerced JSONB, so object key
-- ordering and TEXT-vs-JSONB transport never cause a false negative.
create or replace function public.cbt_verify_exam_bank(p_exam_id uuid, p_expected_hash text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; bank jsonb; actual_hash text; n int;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  select * into e from public.cbt_exams where id=p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  bank:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));
  n:=jsonb_array_length(bank);
  actual_hash:=md5(bank::text);
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'count',n,'bank_version',coalesce(e.bank_version,1),'stored_hash',coalesce(e.bank_hash,''),'actual_hash',actual_hash,'verified',p_expected_hash is null or actual_hash=p_expected_hash,'updated_at',e.updated_at);
end$$;
revoke execute on function public.cbt_verify_exam_bank(uuid,text) from public, anon;
grant execute on function public.cbt_verify_exam_bank(uuid,text) to authenticated;

-- Harden atomic publish: only draft editor, admin or approved staff may publish; refresh bank_hash.
create or replace function public.cbt_publish_draft(p_draft_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare d record; e record; bank jsonb; old_bank jsonb; new_ver int; me uuid:=auth.uid(); h text;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  select * into d from public.cbt_exams_drafts where id=p_draft_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Draft not found'); end if;
  if not (public.is_admin(me) or public.is_staff(me) or d.editor_id=me) then return jsonb_build_object('ok',false,'error','Not authorized to publish this draft'); end if;
  bank:=public.cbt_coerce_to_jsonb_array(d.draft);
  if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'error','Draft empty'); end if;
  select * into e from public.cbt_exams where id=d.exam_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  old_bank:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));
  new_ver:=coalesce(e.bank_version,1)+1; h:=md5(bank::text);
  update public.cbt_exams set csv_data=bank,questions=bank,bank_version=new_ver,bank_hash=h,updated_at=now() where id=d.exam_id returning * into e;
  delete from public.cbt_exams_drafts where id=p_draft_id;
  begin insert into public.cbt_edit_log(exam_id,editor_id,old_count,new_count,old_hash,new_hash) values(d.exam_id,me,jsonb_array_length(old_bank),jsonb_array_length(bank),md5(old_bank::text),h); exception when others then null; end;
  perform pg_notify('cbt-bank-updated',e.code);
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'version',new_ver,'hash',h,'old_count',jsonb_array_length(old_bank),'new_count',jsonb_array_length(bank));
end$$;
revoke execute on function public.cbt_publish_draft(uuid) from public,anon;
grant execute on function public.cbt_publish_draft(uuid) to authenticated;

-- Fix midterm reports RLS: family sees only published; staff retains all.
drop policy if exists midterm_rc_select on public.midterm_report_cards;
create policy midterm_rc_select on public.midterm_report_cards for select using (
  public.is_admin(auth.uid()) or public.is_staff(auth.uid())
  or (published=true and exists(select 1 from public.students s where s.id=midterm_report_cards.student_id and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))))
);

-- Harden publish: only the author, admin, or staff may publish a saved draft.
create or replace function public.cbt_publish_draft(p_draft_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare d record; e record; bank jsonb; old jsonb; new_ver int; editor uuid:=auth.uid();
begin
  if editor is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  select * into d from public.cbt_exams_drafts where id=p_draft_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Draft not found'); end if;
  if not (public.is_admin(editor) or public.is_staff(editor) or d.editor_id=editor) then return jsonb_build_object('ok',false,'error','Not authorized to publish this draft'); end if;
  bank:=public.cbt_coerce_to_jsonb_array(d.draft);
  if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'error','Draft empty'); end if;
  select * into e from public.cbt_exams where id=d.exam_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  old:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));
  new_ver:=coalesce(e.bank_version,1)+1;
  update public.cbt_exams set csv_data=bank, questions=bank, bank_version=new_ver, bank_hash=md5(bank::text), updated_at=now() where id=d.exam_id returning * into e;
  delete from public.cbt_exams_drafts where id=p_draft_id;
  begin insert into public.cbt_edit_log(exam_id,editor_id,old_count,new_count,old_hash,new_hash) values(d.exam_id,editor,jsonb_array_length(old),jsonb_array_length(bank),md5(old::text),md5(bank::text)); exception when others then null; end;
  perform pg_notify('cbt-bank-updated',e.code);
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'version',new_ver,'hash',md5(bank::text),'old_count',jsonb_array_length(old),'new_count',jsonb_array_length(bank));
end$$;
revoke execute on function public.cbt_publish_draft(uuid) from public, anon;
grant execute on function public.cbt_publish_draft(uuid) to authenticated;

-- Family only receives a midterm sheet after it is published, even through SECURITY DEFINER RPC.
create or replace function public.get_midterm_report(p_student_id_ref text,p_class text,p_term text,p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare rec public.midterm_report_cards%rowtype; me uuid:=auth.uid();
begin
  select * into rec from public.midterm_report_cards where student_id_ref=p_student_id_ref and class=p_class and term=p_term and session=p_session;
  if not found then return jsonb_build_object('ok',false,'error','Midterm report not found. Ask tutor to generate it.'); end if;
  if not (public.is_admin(me) or public.is_staff(me)) then
    if not rec.published then return jsonb_build_object('ok',false,'error','not_published','message','This midterm report has not been released yet.'); end if;
    if not exists(select 1 from public.students s where s.admission_no=rec.student_id_ref and (s.user_id=me or public.is_parent_of(me,s.id))) then return jsonb_build_object('ok',false,'error','Not authorized'); end if;
  end if;
  return jsonb_build_object('ok',true,'report',row_to_json(rec));
end$$;
grant execute on function public.get_midterm_report(text,text,text,text) to authenticated;

-- Midterm report auto-sync trigger. Runs only for columns explicitly marked
-- Midterm / cbt_assessment_type=test; terminal report_cards never touched.
create or replace function public.sc_refresh_midterm_report_for_score()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_sid_ref text; v_class text; v_term text; v_session text; v_sid uuid; v_name text; v_scores jsonb; v_total numeric; v_avg numeric;
begin
  if tg_op='DELETE' then v_sid_ref:=old.student_id_ref; v_class:=old.class; v_term:=old.term; v_session:=old.session; v_sid:=old.student_id; v_name:=old.student_name;
  else v_sid_ref:=new.student_id_ref; v_class:=new.class; v_term:=new.term; v_session:=new.session; v_sid:=new.student_id; v_name:=new.student_name; end if;
  if coalesce(v_sid_ref,'')='' then if tg_op='DELETE' then return old; else return new; end if; end if;
  select coalesce(jsonb_object_agg(rs.subject,rs.score order by rs.subject),'{}'::jsonb),coalesce(sum(rs.score),0),coalesce(avg(rs.score),0)
    into v_scores,v_total,v_avg
  from public.report_scores rs join public.assessment_columns ac on ac.id=rs.column_id
  where rs.student_id_ref=v_sid_ref and lower(trim(rs.class))=lower(trim(v_class)) and lower(trim(rs.term))=lower(trim(v_term)) and lower(trim(rs.session))=lower(trim(v_session))
    and (lower(trim(ac.name)) like 'midterm%' or lower(trim(ac.cbt_assessment_type)) in ('test','midterm','mid_term','mid_term_test'));
  if coalesce(v_scores,'{}'::jsonb)='{}'::jsonb then
    delete from public.midterm_report_cards where student_id_ref=v_sid_ref and class=v_class and term=v_term and session=v_session;
  else
    insert into public.midterm_report_cards(student_id,student_id_ref,student_name,class,term,session,scores,total,average,published,updated_at)
    values(v_sid,v_sid_ref,coalesce(v_name,''),coalesce(v_class,''),coalesce(v_term,''),coalesce(v_session,''),v_scores,v_total,v_avg,false,now())
    on conflict(student_id_ref,class,term,session) do update set student_id=excluded.student_id,student_name=excluded.student_name,scores=excluded.scores,total=excluded.total,average=excluded.average,updated_at=now();
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end$$;
drop trigger if exists trg_midterm_report_sync on public.report_scores;
create trigger trg_midterm_report_sync after insert or update or delete on public.report_scores for each row execute function public.sc_refresh_midterm_report_for_score();

insert into public.sc_install_state(key,details) values ('v12.48-cbt-integrity-network-and-midterm-sync.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.48 CBT integrity + network-first + midterm auto-sync installed' as status;
