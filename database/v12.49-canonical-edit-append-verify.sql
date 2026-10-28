-- ============================================================================
-- School Connect V12.49 — Canonical edit/append/verify + midterm privacy hardening
-- ----------------------------------------------------------------------------
-- Root cause of still-persisting CBT edit: frontend cbt.html calls
-- cbt_force_replace_bank_v3 and cbt_verify_exam_bank, but complete-schema as
-- shipped to live GOSA was not rebuilt with the later v12.48 edits. Thus RPC
-- schema cache returned 42883/404 (stale UI may then execute older fallback
-- and toast false success). Also the v12.48 force function definition was in
-- the standalone SQL draft but not in cumulative schema. Vercel SW was v12.46,
-- and stale-while-revalidate served old cbt.html/js on first load. We fix all
-- three layers: DEFINITIVE RPCs embedded in cumulative schema, network-first
-- runtime assets in v12.48 SW, and front-end only reports saved after verifier.
--
-- Attach CSV bug: v12.41 cbt_force_append_bank returns count but frontend
-- didn't server-verify, and fallback code referenced a block-scoped rpc2 var
-- after leaving its try block. Replace with a single v2 append RPC that returns
-- canonical hash + version, then call cbt_verify_exam_bank.
--
-- Midterm consistency: v12.48 auto-sync trigger updates only midterm_report_cards
-- after report_scores changes, never terminal report_cards. Parent RPC checks
-- published=true. Keep this behavior.
-- ============================================================================
select 'RUNNING: School Connect canonical edit/append/verify V12.49' as running_version;

-- Canonical force replace: row-lock, optimistic version, coerce JSONB, hash computed by postgres.
create or replace function public.cbt_force_replace_bank_v3(p_exam_id uuid,p_bank jsonb,p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; bank jsonb; old_bank jsonb; old_hash text; new_hash text; ver int;
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
  old_hash:=md5(old_bank::text); new_hash:=md5(bank::text);
  if old_hash=new_hash then return jsonb_build_object('ok',true,'message','No changes (same canonical bank)','exam_id',p_exam_id,'version',ver,'hash',new_hash,'count',jsonb_array_length(bank)); end if;
  update public.cbt_exams set csv_data=bank,questions=bank,bank_version=ver+1,bank_hash=new_hash,updated_at=now() where id=p_exam_id returning * into e;
  begin insert into public.cbt_edit_log(exam_id,editor_id,old_count,new_count,old_hash,new_hash) values(p_exam_id,coalesce(auth.uid(),'00000000-0000-0000-0000-000000000000'::uuid),jsonb_array_length(old_bank),jsonb_array_length(bank),old_hash,new_hash); exception when others then null; end;
  perform pg_notify('cbt-bank-updated',e.code);
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'version',e.bank_version,'hash',new_hash,'count',jsonb_array_length(bank));
end$$;
revoke execute on function public.cbt_force_replace_bank_v3(uuid,jsonb,int) from public;
grant execute on function public.cbt_force_replace_bank_v3(uuid,jsonb,int) to authenticated;

-- Canonical append: atomic server-side JSONB concatenate and returns hash for verification.
create or replace function public.cbt_force_append_bank_v2(p_exam_id uuid,p_new_questions jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; old_bank jsonb; add_bank jsonb; new_bank jsonb; ver int; h text;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  add_bank:=public.cbt_coerce_to_jsonb_array(p_new_questions);
  if jsonb_array_length(add_bank)=0 then return jsonb_build_object('ok',false,'error','No new questions'); end if;
  select * into e from public.cbt_exams where id=p_exam_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  old_bank:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));
  new_bank:=old_bank||add_bank; ver:=coalesce(e.bank_version,1)+1; h:=md5(new_bank::text);
  update public.cbt_exams set csv_data=new_bank,questions=new_bank,bank_version=ver,bank_hash=h,updated_at=now() where id=p_exam_id returning * into e;
  begin insert into public.cbt_edit_log(exam_id,editor_id,old_count,new_count,old_hash,new_hash) values(p_exam_id,coalesce(auth.uid(),'00000000-0000-0000-0000-000000000000'::uuid),jsonb_array_length(old_bank),jsonb_array_length(new_bank),md5(old_bank::text),h); exception when others then null; end;
  perform pg_notify('cbt-bank-updated',e.code);
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'version',ver,'hash',h,'added',jsonb_array_length(add_bank),'total',jsonb_array_length(new_bank));
end$$;
revoke execute on function public.cbt_force_append_bank_v2(uuid,jsonb) from public,anon;
grant execute on function public.cbt_force_append_bank_v2(uuid,jsonb) to authenticated;

-- Verifier is independent and SECURITY DEFINER: read the committed row, coerce
-- legacy TEXT, recompute canonical hash, compare with the RPC's committed hash.
create or replace function public.cbt_verify_exam_bank(p_exam_id uuid,p_expected_hash text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; bank jsonb; h text; n int;
begin
 if auth.uid() is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
 select * into e from public.cbt_exams where id=p_exam_id;
 if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
 bank:=public.cbt_coerce_to_jsonb_array(coalesce(e.csv_data,'[]'::jsonb));n:=jsonb_array_length(bank);h:=md5(bank::text);
 return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'count',n,'bank_version',coalesce(e.bank_version,1),'actual_hash',h,'stored_hash',coalesce(e.bank_hash,''),'verified',p_expected_hash is null or h=p_expected_hash,'updated_at',e.updated_at);
end$$;
revoke execute on function public.cbt_verify_exam_bank(uuid,text) from public,anon;
grant execute on function public.cbt_verify_exam_bank(uuid,text) to authenticated;

insert into public.sc_install_state(key,details) values ('v12.49-canonical-edit-append-verify.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V12.49 canonical edit/append/verify installed — force v3 + force append v2 + independent server verifier' as status;
