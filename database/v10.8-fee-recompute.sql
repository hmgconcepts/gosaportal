-- ============================================================================
-- School Connect V10.8 — Self-healing fee ledger (edit/delete recompute)
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql (or any earlier pack) on an EXISTING database.
-- Fresh installs get all of this from complete-schema.sql automatically.
--
-- THE SCENARIO (pass-56 issue 2): the bursar records ₦15,000 for a student
-- who paid ₦10,000, or records ₦50,000 for a student who paid nothing. When
-- the erroneous row is EDITED or DELETED, every other row of that student's
-- term must adjust — because each payment row snapshots "total due at the
-- time" (fee_total) and "balance after this payment" (balance), and those
-- snapshots go stale the moment an earlier row changes.
--
-- THE ENGINE: sc_recompute_fee_rows(student, term, session) re-walks the
-- student's payments for the term in chronological order and rewrites every
-- snapshot from one reconstructed GRAND TOTAL:
--   grand = the bursar's override row (fee_total + payments made before it)
--           when one exists — the override stays authoritative;
--   else    the maximum of (row.fee_total + payments before that row) across
--           rows — i.e. the best evidence of the original full bill, immune
--           to any single wrong row.
-- Then row i gets fee_total = grand − paid_before_i and
--                 balance   = fee_total − amount_paid_i  (floor 0).
-- A statement-level trigger runs it automatically after ANY insert, update
-- or delete on fee_payments, so the ledger heals itself no matter which
-- client (form, CSV import, REST) touched it. Recursion is depth-guarded.
-- sc_student_fee_state (dashboards/receipts) already computes live from the
-- rows, so it agrees with the healed snapshots automatically.
-- ============================================================================
select 'RUNNING: School Connect fee-recompute pack V10.8' as running_version;

create or replace function public.sc_recompute_fee_rows(p_student uuid, p_term text default '', p_session text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare grand numeric := null; r record; paid_before numeric := 0; n int := 0; cand numeric;
begin
  if p_student is null then return jsonb_build_object('ok',false,'error','No student.'); end if;

  -- 1. Reconstruct the grand total for this student+term.
  --    Override row wins; else best evidence across rows.
  for r in
    select id, coalesce(amount_paid,0) as amt, coalesce(fee_total,0) as ft, coalesce(total_overridden,false) as ovr
      from public.fee_payments
     where student_id = p_student
       and coalesce(term,'')    = coalesce(p_term,'')
       and coalesce(session,'') = coalesce(p_session,'')
     order by created_at asc nulls last, id asc
  loop
    if r.ovr and r.ft > 0 then
      grand := r.ft + paid_before;         -- override defined the total AT THAT POINT
    elsif grand is null or not exists (
        select 1 from public.fee_payments fp
         where fp.student_id = p_student
           and coalesce(fp.term,'') = coalesce(p_term,'')
           and coalesce(fp.session,'') = coalesce(p_session,'')
           and coalesce(fp.total_overridden,false) and coalesce(fp.fee_total,0) > 0) then
      cand := r.ft + paid_before;
      if grand is null or cand > grand then grand := cand; end if;
    end if;
    paid_before := paid_before + r.amt;
  end loop;
  if grand is null then return jsonb_build_object('ok',true,'rows',0); end if;

  -- 2. Rewrite every snapshot from the reconstructed grand total.
  paid_before := 0;
  for r in
    select id, coalesce(amount_paid,0) as amt
      from public.fee_payments
     where student_id = p_student
       and coalesce(term,'')    = coalesce(p_term,'')
       and coalesce(session,'') = coalesce(p_session,'')
     order by created_at asc nulls last, id asc
  loop
    update public.fee_payments
       set fee_total = greatest(grand - paid_before, 0),
           balance   = greatest(grand - paid_before - r.amt, 0)
     where id = r.id
       and (coalesce(fee_total,-1) <> greatest(grand - paid_before, 0)
         or coalesce(balance,-1)   <> greatest(grand - paid_before - r.amt, 0));
    paid_before := paid_before + r.amt;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok',true,'rows',n,'grand_total',grand,'paid',paid_before,'outstanding',greatest(grand-paid_before,0));
end $$;
revoke execute on function public.sc_recompute_fee_rows(uuid,text,text) from public, anon;
grant execute on function public.sc_recompute_fee_rows(uuid,text,text) to authenticated;

-- Statement-level trigger: heal the affected student+term after ANY write.
create or replace function public.sc_fee_rows_autoheal()
returns trigger language plpgsql security definer set search_path=public as $$
declare r record;
begin
  if pg_trigger_depth() > 1 then return null; end if;   -- our own rewrites do not re-trigger
  if tg_op = 'DELETE' then
    for r in select distinct student_id, coalesce(term,'') as term, coalesce(session,'') as session from old_table where student_id is not null loop
      perform public.sc_recompute_fee_rows(r.student_id, r.term, r.session);
    end loop;
  else
    for r in select distinct student_id, coalesce(term,'') as term, coalesce(session,'') as session from new_table where student_id is not null loop
      perform public.sc_recompute_fee_rows(r.student_id, r.term, r.session);
    end loop;
    if tg_op = 'UPDATE' then
      -- a row moved to another term/student: heal the OLD context too
      for r in select distinct student_id, coalesce(term,'') as term, coalesce(session,'') as session from old_table where student_id is not null loop
        perform public.sc_recompute_fee_rows(r.student_id, r.term, r.session);
      end loop;
    end if;
  end if;
  return null;
end $$;
drop trigger if exists trg_fee_rows_autoheal_ins on public.fee_payments;
create trigger trg_fee_rows_autoheal_ins after insert on public.fee_payments
referencing new table as new_table for each statement execute function public.sc_fee_rows_autoheal();
drop trigger if exists trg_fee_rows_autoheal_upd on public.fee_payments;
create trigger trg_fee_rows_autoheal_upd after update on public.fee_payments
referencing old table as old_table new table as new_table for each statement execute function public.sc_fee_rows_autoheal();
drop trigger if exists trg_fee_rows_autoheal_del on public.fee_payments;
create trigger trg_fee_rows_autoheal_del after delete on public.fee_payments
referencing old table as old_table for each statement execute function public.sc_fee_rows_autoheal();

-- ---------------------------------------------------------------------------
-- 2. REPORT LOCK now covers RESULTS and CBT RESULTS too (pass-56 issue 1).
--    V10.7 blanked report_scores/report_cards; a locked family could still
--    read raw subject results and CBT attempt rows. All four family-read
--    surfaces now honour sc_report_hidden_for. Staff paths untouched.
-- ---------------------------------------------------------------------------
drop policy if exists results_scope_select on public.results;
create policy results_scope_select on public.results for select using(
  public.is_admin(auth.uid())
  or public.teacher_can_manage_subject_class(auth.uid(),subject,class)
  or exists(select 1 from public.students s where s.id=results.student_id
        and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))
        and not public.sc_report_hidden_for(auth.uid(), s.id)));

drop policy if exists cbt_result_scope_select on public.cbt_results;
create policy cbt_result_scope_select on public.cbt_results for select using(
  public.is_admin(auth.uid())
  or exists(select 1 from public.cbt_exams e where e.id=cbt_results.exam_id
        and(e.teacher_id=auth.uid()or public.teacher_can_manage_subject_class(auth.uid(),e.subject,e.class)))
  or exists(select 1 from public.students s where s.id=cbt_results.student_id
        and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))
        and not public.sc_report_hidden_for(auth.uid(), s.id)));

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.8 fee-recompute pack installed' as status;
