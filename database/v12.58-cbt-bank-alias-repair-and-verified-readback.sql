-- ============================================================================
-- School Connect V12.58 — correct source selection + dual-column verification
-- ============================================================================
select 'RUNNING: School Connect CBT bank alias repair V12.58' as running_version;

create or replace function public.cbt_force_replace_bank_v3(p_exam_id uuid,p_bank jsonb,p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; bank jsonb; old_bank jsonb; old_questions jsonb; old_hash text; old_qhash text; new_hash text; ver int;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  bank:=public.cbt_coerce_to_jsonb_array(p_bank);
  if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'error','Bank empty','message','Cannot publish an empty question bank.'); end if;
  select * into e from public.cbt_exams where id=p_exam_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  ver:=coalesce(e.bank_version,1);
  if p_expected_version is not null and p_expected_version<>ver then
    return jsonb_build_object('ok',false,'error','concurrent_edit','message','The question bank changed since the editor loaded it (version '||ver||'). Reload, re-apply your changes, then publish.','current_version',ver);
  end if;
  old_bank:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));
  old_questions:=public.cbt_coerce_to_jsonb_array(coalesce(e.questions,'[]'::jsonb));
  -- Match the student getter: prefer non-empty csv_data, otherwise recover from questions.
  if jsonb_array_length(old_bank)=0 and jsonb_array_length(old_questions)>0 then old_bank:=old_questions; end if;
  old_hash:=md5(old_bank::text);old_qhash:=md5(old_questions::text);new_hash:=md5(bank::text);
  if old_hash=new_hash and old_qhash=new_hash then
    return jsonb_build_object('ok',true,'message','No changes; both database banks already match','exam_id',p_exam_id,'version',ver,'hash',new_hash,'count',jsonb_array_length(bank),'aliases_repaired',false);
  end if;
  -- Always write BOTH aliases. This repairs legacy rows where the candidate
  -- getter and editor previously read different banks, even when primary content
  -- is unchanged but the secondary column has drifted.
  update public.cbt_exams set csv_data=bank,questions=bank,bank_version=ver+1,bank_hash=new_hash,updated_at=now() where id=p_exam_id returning * into e;
  begin insert into public.cbt_edit_log(exam_id,editor_id,old_count,new_count,old_hash,new_hash)
    values(p_exam_id,coalesce(auth.uid(),'00000000-0000-0000-0000-000000000000'::uuid),jsonb_array_length(old_bank),jsonb_array_length(bank),old_hash,new_hash);
  exception when others then null; end;
  perform pg_notify('cbt-bank-updated',e.code);
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'version',e.bank_version,'hash',new_hash,'count',jsonb_array_length(bank),'aliases_repaired',old_qhash<>old_hash);
end$$;
revoke execute on function public.cbt_force_replace_bank_v3(uuid,jsonb,int) from public;
grant execute on function public.cbt_force_replace_bank_v3(uuid,jsonb,int) to authenticated;

create or replace function public.cbt_force_append_bank_v2(p_exam_id uuid,p_new_questions jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; old_bank jsonb; old_questions jsonb; add_bank jsonb; new_bank jsonb; ver int; h text;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  add_bank:=public.cbt_coerce_to_jsonb_array(p_new_questions);
  if jsonb_array_length(add_bank)=0 then return jsonb_build_object('ok',false,'error','No new questions'); end if;
  select * into e from public.cbt_exams where id=p_exam_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  old_bank:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));
  old_questions:=public.cbt_coerce_to_jsonb_array(coalesce(e.questions,'[]'::jsonb));
  if jsonb_array_length(old_bank)=0 and jsonb_array_length(old_questions)>0 then old_bank:=old_questions; end if;
  new_bank:=old_bank||add_bank;ver:=coalesce(e.bank_version,1)+1;h:=md5(new_bank::text);
  update public.cbt_exams set csv_data=new_bank,questions=new_bank,bank_version=ver,bank_hash=h,updated_at=now() where id=p_exam_id returning * into e;
  begin insert into public.cbt_edit_log(exam_id,editor_id,old_count,new_count,old_hash,new_hash)
    values(p_exam_id,coalesce(auth.uid(),'00000000-0000-0000-0000-000000000000'::uuid),jsonb_array_length(old_bank),jsonb_array_length(new_bank),md5(old_bank::text),h);
  exception when others then null; end;
  perform pg_notify('cbt-bank-updated',e.code);
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'version',ver,'hash',h,'added',jsonb_array_length(add_bank),'total',jsonb_array_length(new_bank));
end$$;
revoke execute on function public.cbt_force_append_bank_v2(uuid,jsonb) from public,anon;
grant execute on function public.cbt_force_append_bank_v2(uuid,jsonb) to authenticated;

create or replace function public.cbt_verify_exam_bank(p_exam_id uuid,p_expected_hash text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; bank jsonb; question_alias jsonb; h text; qh text; n int; qn int; aliases_match boolean;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  select * into e from public.cbt_exams where id=p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  bank:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));
  question_alias:=public.cbt_coerce_to_jsonb_array(coalesce(e.questions,'[]'::jsonb));
  n:=jsonb_array_length(bank);qn:=jsonb_array_length(question_alias);h:=md5(bank::text);qh:=md5(question_alias::text);aliases_match:=h=qh;
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'count',n,'questions_count',qn,
    'bank_version',coalesce(e.bank_version,1),'actual_hash',h,'questions_hash',qh,'stored_hash',coalesce(e.bank_hash,''),
    'aliases_match',aliases_match,'verified',(p_expected_hash is null or h=p_expected_hash) and aliases_match,'updated_at',e.updated_at);
end$$;
revoke execute on function public.cbt_verify_exam_bank(uuid,text) from public,anon;
grant execute on function public.cbt_verify_exam_bank(uuid,text) to authenticated;

insert into public.sc_install_state(key,details) values ('v12.58-cbt-bank-alias-repair-and-verified-readback.sql',jsonb_build_object('self',true)) on conflict(key) do nothing;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V12.58 save/append repair both question-bank aliases and verify canonical hashes from both columns' as status;
