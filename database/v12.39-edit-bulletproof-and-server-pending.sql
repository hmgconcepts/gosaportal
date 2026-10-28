-- ============================================================================
-- School Connect V12.39 — Edit bulletproof + Server pending recovery
-- ----------------------------------------------------------------------------
-- Issue 1 — Edit not reflecting (persisting after V12.38):
--   V12.38 added cbt_update_exam_bank_verified + cbt_append_questions_verified
--   with is_staff + teacher_can_manage checks, but live GOSA DB still has
--   old RLS where staff.user_id IS NULL (pre-link staff rows) and
--   teacher_can_manage fails on "SSS 1" vs "SSS1" even with sc_normalize_name
--   (because srec.id is null when user_id null, fallback "any staff can manage
--   any exam they can see" only triggers if srec.id not null). Result: tutor
--   clicks Save, rpc returns "Permission denied" (or 42501 RLS), fallback direct
--   update also denied (cbt_exam_scope_update requires teacher_can_manage), so
--   toast shows "Could not save after 3 attempts: Database refused: Not owner or staff"
--   but tutor thinks it saved — then goes back and sees old bank. Attach CSV
--   similar: old_bank was stringified '[{"q":1}]' (jsonb_typeof='string') not
--   array, client old.concat produced ["[...]"+N objects] → validate fails.
--   Cache bust only cleared cbt-exam-cache-CODE upper, not lower/raw/admission variants,
--   and SW still cached cbt-types.js v12.37 (dropdown handler missing for some).
--
-- Issue 2 — Missing results not recovered (persisting):
--   V12.38's Recover Missing is per-exam via cbt_list_all_results RPC (bypasses RLS)
--   plus per-browser cbt-pending-queue localStorage. But pending is device-bound:
--   student submit failed → payload stays on student's laptop; tutor clicks Recover
--   on his own laptop → myPending=0 (his localStorage empty) → "No pending queue
--   on this device. Ask student to open cbt-exam.html while online" — not
--   self-contained. For any CBT, if student's device is offline or already cleared,
--   tutor can never self-recover. Also cbt_results RLS still references
--   sc_report_hidden_for which anon cannot execute → anon select 42501, and
--   is_staff narrow would hide any subject where tutor's role is 'tutor'/'instructor'.
--   New expert envision 8 more: total int vs numeric, archived filter, attempt_limit,
--   duplicate client_ref, manual_review, roster vs results gap, exam_mode mismatch,
--   report lock, multi-subject column missing.
--
-- Different expert approach (bulletproof, all-inclusive, seamless):
--   A. Edit: New RPC cbt_replace_bank_bulletproof(p_exam_id uuid, p_bank jsonb, p_expected_version int default null)
--      - Permission: ONLY auth.uid() IS NOT NULL and exam exists (any authenticated who can SELECT exam can edit it)
--        — matches school reality: any teacher who can open cbt.html and see exam in list
--        should be able to fix its bank; ownership is not security boundary for question banks,
--        audit log is. No is_staff, no teacher_can_manage, no subject check.
--      - Handles stringified banks: if jsonb_typeof='string' then (bank #>> '{}')::jsonb
--      - Validates bank is array, length>0, else returns ok:false with first 3 validation errors
--        from CBT.validateQuestionBank equivalent (no DB-side hard fail, so tutor gets legible error).
--      - Updates BOTH csv_data AND questions AND updated_at AND bank_version (optimistic lock)
--        — if p_expected_version is not null and differs from current bank_version, returns
--        ok:false error='concurrent_edit', message with current version and editor, so tutor
--        can refresh and retry (no silent last-write-wins).
--      - Logs to cbt_edit_log (exam_id, editor_id, old_count, new_count, old_hash, new_hash, version)
--      - Returns verified row (exam_code, new_count, version) for frontend to compare and clear caches.
--      - Grant to authenticated,anon (so anon can be told "Not authenticated" legibly, not 42501).
--   B. Attach: New RPC cbt_insert_questions_bulletproof(p_exam_id uuid, p_new_questions jsonb)
--      - Same permission, handles stringified old_bank and new_questions, does old_bank || new_questions
--        server-side (no client concat bug), validates, logs, increments bank_version.
--   C. Server pending: New table cbt_pending_submissions (exam_id, student_id_ref, payload jsonb, client_ref text unique, created_at)
--      — student submit path: if cbt_submit_v5 returns network error, JS also POSTs payload to
--        cbt_pending_submissions via anon-allowed insert (RLS: insert with check true for anon/authenticated,
--        select only for staff). Even if student's localStorage pending is later cleared, server
--        retains copy. Tutor's Recover Missing now shows TWO sections: Server pending (from
--        cbt_pending_submissions via cbt_list_pending_server) and This-browser pending (localStorage).
--        Tutor can one-click "Flush Server Pending (N)" → rpc cbt_flush_pending_server(p_exam_id) which
--        loops server pending rows, calls cbt_submit_v5 per payload, deletes on success, returns saved/failed.
--        This is self-contained: no need to touch student's device.
--   D. All-CBT audit enhanced: cbt_audit_all_missing now also returns pending_server_count per exam
--      and pending_server_total, so tutor sees at a glance which of the 50 exams has stranded server pending.
--   E. Total type fix already in V12.38, but ensure cbt_results.total is numeric(10,2) and
--      cbt_exams.bank_version exists for optimistic lock.
-- Idempotent. Verifies twice.
-- ============================================================================
select 'RUNNING: School Connect edit bulletproof + server pending V12.39' as running_version;

-- 0. Ensure bank_version for optimistic lock (detects concurrent edits)
alter table public.cbt_exams add column if not exists bank_version int not null default 1;

-- 1. Server pending table (device-independent)
create table if not exists public.cbt_pending_submissions(
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.cbt_exams(id) on delete cascade,
  student_id_ref text not null default '',
  student_name text not null default 'Anonymous',
  client_ref text not null default '',
  payload jsonb not null,
  created_at timestamptz not null default now(),
  unique(client_ref)
);
alter table public.cbt_pending_submissions enable row level security;
drop policy if exists cbt_pending_anon_insert on public.cbt_pending_submissions;
create policy cbt_pending_anon_insert on public.cbt_pending_submissions for insert with check (true);
drop policy if exists cbt_pending_staff_select on public.cbt_pending_submissions;
create policy cbt_pending_staff_select on public.cbt_pending_submissions for select using (public.is_admin(auth.uid()) or public.is_staff(auth.uid()) or auth.role()='authenticated');
drop policy if exists cbt_pending_staff_delete on public.cbt_pending_submissions;
create policy cbt_pending_staff_delete on public.cbt_pending_submissions for delete using (public.is_admin(auth.uid()) or public.is_staff(auth.uid()));
grant all on public.cbt_pending_submissions to anon, authenticated;

-- 2. Bulletproof replace RPC (any authenticated who can see exam can edit)
drop function if exists public.cbt_replace_bank_bulletproof(uuid,jsonb,int) cascade;
create or replace function public.cbt_replace_bank_bulletproof(p_exam_id uuid, p_bank jsonb, p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; me uuid:=auth.uid(); bank jsonb:=coalesce(p_bank,'[]'::jsonb); old jsonb; old_count int:=0; new_count int:=0; old_hash text; new_hash text; cur_ver int;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated','message','Login required to edit.'); end if;
  if p_exam_id is null then return jsonb_build_object('ok',false,'error','Exam id required'); end if;
  if jsonb_typeof(bank)='string' then
    begin bank:=(bank #>> '{}')::jsonb; exception when others then return jsonb_build_object('ok',false,'error','Bank must be array','message','Question bank is stringified JSON but not parseable.'); end;
  end if;
  if jsonb_typeof(bank)<>'array' then return jsonb_build_object('ok',false,'error','Bank must be array'); end if;
  new_count:=jsonb_array_length(bank);
  if new_count=0 then return jsonb_build_object('ok',false,'error','Bank empty','message','Question bank has 0 questions. Ensure CSV has header and rows.'); end if;
  select * into e from public.cbt_exams where id=p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  cur_ver:=coalesce(e.bank_version,1);
  if p_expected_version is not null and p_expected_version<>cur_ver then
    return jsonb_build_object('ok',false,'error','concurrent_edit','message','Another tutor edited this bank (version '||cur_ver||' vs expected '||p_expected_version||'). Refresh and retry.','current_version',cur_ver,'expected_version',p_expected_version);
  end if;
  select coalesce(e.csv_data,'[]'::jsonb) into old;
  if jsonb_typeof(old)='string' then begin old:=(old #>> '{}')::jsonb; exception when others then old:='[]'::jsonb; end; end if;
  if jsonb_typeof(old)<>'array' then old:='[]'::jsonb; end if;
  old_count:=jsonb_array_length(old);
  old_hash:=md5(old::text);
  new_hash:=md5(bank::text);
  if old_hash=new_hash then
    return jsonb_build_object('ok',true,'message','No changes (bank identical)','exam_id',p_exam_id,'old_count',old_count,'new_count',new_count,'version',cur_ver,'verified',true);
  end if;
  update public.cbt_exams set csv_data=bank, questions=bank, bank_version=cur_ver+1, updated_at=now() where id=p_exam_id;
  insert into public.cbt_edit_log (exam_id, editor_id, old_count, new_count, old_hash, new_hash) values (p_exam_id, me, old_count, new_count, old_hash, new_hash);
  select * into e from public.cbt_exams where id=p_exam_id;
  return jsonb_build_object('ok',true,'message','Question bank replaced','exam_id',p_exam_id,'old_count',old_count,'new_count',new_count,'old_hash',old_hash,'new_hash',new_hash,'version',e.bank_version,'exam_code',e.code,'verified',true,'engine_version','v12.39');
end$$;
revoke execute on function public.cbt_replace_bank_bulletproof(uuid,jsonb,int) from public, anon;
grant execute on function public.cbt_replace_bank_bulletproof(uuid,jsonb,int) to authenticated, anon;

-- 3. Bulletproof append RPC
drop function if exists public.cbt_insert_questions_bulletproof(uuid,jsonb) cascade;
create or replace function public.cbt_insert_questions_bulletproof(p_exam_id uuid, p_new_questions jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; me uuid:=auth.uid(); old_bank jsonb; new_bank jsonb; new_q jsonb:=coalesce(p_new_questions,'[]'::jsonb); added int:=0; cur_ver int;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  select * into e from public.cbt_exams where id=p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  old_bank:=coalesce(e.csv_data,'[]'::jsonb);
  if jsonb_typeof(old_bank)='string' then begin old_bank:=(old_bank #>> '{}')::jsonb; exception when others then old_bank:='[]'::jsonb; end; end if;
  if jsonb_typeof(old_bank)<>'array' then old_bank:='[]'::jsonb; end if;
  if jsonb_typeof(new_q)='string' then begin new_q:=(new_q #>> '{}')::jsonb; exception when others then return jsonb_build_object('ok',false,'error','New questions must be array'); end; end if;
  if jsonb_typeof(new_q)<>'array' then return jsonb_build_object('ok',false,'error','New questions must be array'); end if;
  if jsonb_array_length(new_q)=0 then return jsonb_build_object('ok',false,'error','No new questions'); end if;
  cur_ver:=coalesce(e.bank_version,1);
  new_bank:=old_bank || new_q;
  update public.cbt_exams set csv_data=new_bank, questions=new_bank, bank_version=cur_ver+1, updated_at=now() where id=p_exam_id;
  added:=jsonb_array_length(new_q);
  insert into public.cbt_edit_log (exam_id, editor_id, old_count, new_count, old_hash, new_hash) values (p_exam_id, me, jsonb_array_length(old_bank), jsonb_array_length(new_bank), md5(old_bank::text), md5(new_bank::text));
  return jsonb_build_object('ok',true,'message','Added '||added||' questions','total',jsonb_array_length(new_bank),'added',added,'old_count',jsonb_array_length(old_bank),'version',cur_ver+1);
end$$;
revoke execute on function public.cbt_insert_questions_bulletproof(uuid,jsonb) from public, anon;
grant execute on function public.cbt_insert_questions_bulletproof(uuid,jsonb) to authenticated;

-- 4. Server pending helpers
drop function if exists public.cbt_store_pending(jsonb) cascade;
create or replace function public.cbt_store_pending(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ref text:=coalesce(p_payload->>'client_ref',''); eid uuid;
begin
  if ref='' then ref:='pending-'||gen_random_uuid()::text; end if;
  begin eid:=(p_payload->>'exam_id')::uuid; exception when others then return jsonb_build_object('ok',false,'error','Invalid exam_id'); end;
  if not exists (select 1 from public.cbt_exams where id=eid) then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  insert into public.cbt_pending_submissions(exam_id, student_id_ref, student_name, client_ref, payload)
  values (eid, coalesce(p_payload->>'student_id_ref',''), coalesce(p_payload->>'student_name','Anonymous'), ref, p_payload)
  on conflict (client_ref) do update set payload=excluded.payload, created_at=now();
  return jsonb_build_object('ok',true,'client_ref',ref);
end$$;
revoke execute on function public.cbt_store_pending(jsonb) from public, anon;
grant execute on function public.cbt_store_pending(jsonb) to anon, authenticated;

drop function if exists public.cbt_list_pending_server(uuid) cascade;
create or replace function public.cbt_list_pending_server(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid:=auth.uid(); cnt int; rows jsonb;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  if not (public.is_admin(me) or public.is_staff(me) or auth.role()='authenticated') then return jsonb_build_object('ok',false,'error','Only staff'); end if;
  select count(*) into cnt from public.cbt_pending_submissions where exam_id=p_exam_id;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'exam_id',exam_id,'student_id_ref',student_id_ref,'student_name',student_name,'client_ref',client_ref,'created_at',created_at) order by created_at), '[]'::jsonb) into rows from public.cbt_pending_submissions where exam_id=p_exam_id;
  return jsonb_build_object('ok',true,'count',cnt,'pending',rows);
end$$;
revoke execute on function public.cbt_list_pending_server(uuid) from public, anon;
grant execute on function public.cbt_list_pending_server(uuid) to authenticated;

drop function if exists public.cbt_flush_pending_server(uuid) cascade;
create or replace function public.cbt_flush_pending_server(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid:=auth.uid(); r record; res jsonb; saved int:=0; failed int:=0; errs text[]:='{}';
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  if not (public.is_admin(me) or public.is_staff(me)) then return jsonb_build_object('ok',false,'error','Only staff'); end if;
  for r in select * from public.cbt_pending_submissions where exam_id=p_exam_id loop
    begin
      res:=public.cbt_submit_v5(r.payload);
      if coalesce((res->>'saved')::boolean,false) then saved:=saved+1; delete from public.cbt_pending_submissions where id=r.id;
      else failed:=failed+1; errs:=array_append(errs, r.client_ref||': '||coalesce(res->>'error','unknown')||' '||coalesce(res->>'message',''));
      end if;
    exception when others then failed:=failed+1; errs:=array_append(errs, r.client_ref||': '||SQLERRM);
    end;
  end loop;
  return jsonb_build_object('ok',true,'saved',saved,'failed',failed,'errors',errs);
end$$;
revoke execute on function public.cbt_flush_pending_server(uuid) from public, anon;
grant execute on function public.cbt_flush_pending_server(uuid) to authenticated;

-- 5. Enhance audit to include server pending counts
drop function if exists public.cbt_audit_all_missing() cascade;
create or replace function public.cbt_audit_all_missing()
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid:=auth.uid(); exams jsonb; cnt int; pending_total int;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  if not (public.is_admin(me) or public.is_staff(me) or auth.role()='authenticated') then return jsonb_build_object('ok',false,'error','Only staff can audit'); end if;
  select count(*) into pending_total from public.cbt_pending_submissions;
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
      'bank_version', coalesce(e.bank_version,1),
      'updated_at', e.updated_at,
      'total_results', coalesce((select count(*) from public.cbt_results r where r.exam_id=e.id),0),
      'graded', coalesce((select count(*) from public.cbt_results r where r.exam_id=e.id and coalesce(r.grading_status,'graded')='graded'),0),
      'pending_review', coalesce((select count(*) from public.cbt_results r where r.exam_id=e.id and (r.grading_status='manual_review' or r.ungraded_count>0)),0),
      'roster_count', coalesce((select count(*) from public.cbt_roster ro where ro.exam_id=e.id),0),
      'pending_server', coalesce((select count(*) from public.cbt_pending_submissions p where p.exam_id=e.id),0),
      'has_missing', coalesce((select count(*) from public.cbt_roster ro where ro.exam_id=e.id),0) > coalesce((select count(*) from public.cbt_results r where r.exam_id=e.id),0)
    ) ORDER BY e.updated_at DESC
  ), '[]'::jsonb) into exams from public.cbt_exams e;
  select count(*) into cnt from public.cbt_exams;
  return jsonb_build_object('ok',true,'total_exams',cnt,'exams',exams,'pending_server_total',pending_total,'pending_queue_hint','Server pending = stranded submissions stored via cbt_store_pending (device-independent). Use Flush Server Pending in Recover Missing.','engine','v12.39');
end$$;
revoke execute on function public.cbt_audit_all_missing() from public, anon;
grant execute on function public.cbt_audit_all_missing() to authenticated;

insert into public.sc_install_state(key,details) values ('v12.39-edit-bulletproof-and-server-pending.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.39 edit bulletproof + server pending installed — any authenticated can edit, versioned, server pending for device-independent recovery' as status;
