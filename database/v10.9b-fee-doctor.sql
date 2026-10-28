-- ============================================================================
-- School Connect V10.9 (part B) — Fee Ledger Doctor
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql on an EXISTING database (fresh installs get
-- it from complete-schema.sql). Ships in the same pass as v10.9-lock-coverage.
--
-- WHAT THIS DOES (pass-57 issue 1, "identify every kind of error in advance")
-- One RPC that scans the whole fee ledger for every recording error a bursar
-- can realistically make, and (optionally) heals what is mechanically
-- healable:
--   duplicate        — same student + amount + same calendar day recorded
--                      twice (double-entry / double-click)
--   unlinked         — a payment row with NO student link (typed free-hand,
--                      invisible to every dashboard and receipt)
--   non_positive     — zero or negative amount_paid
--   future_dated     — payment recorded with a future date
--   overpayment      — a term where total paid exceeds the reconstructed
--                      grand total (wrong amount, or missing bill)
--   no_period        — rows missing term/session (they escape every term
--                      filter and every arrears computation)
--   stale_snapshot   — fee_total/balance that disagree with the recomputed
--                      ledger (pre-V10.8 rows, or foreign writers)
-- p_heal=true additionally re-runs sc_recompute_fee_rows on every affected
-- student+term (fixing all stale snapshots) — destructive fixes (deleting a
-- duplicate, relinking a student) remain deliberate human actions, surfaced
-- with the exact row ids so one click in the fees table finishes the job.
-- ============================================================================
select 'RUNNING: School Connect fee-doctor pack V10.9b' as running_version;

create or replace function public.sc_fee_ledger_doctor(p_heal boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare issues jsonb := '[]'::jsonb; r record; healed int := 0; cur record;
begin
  if not coalesce(public.is_staff(auth.uid()),false) then
    return jsonb_build_object('ok',false,'error','Staff role required.');
  end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;

  -- 1. duplicates: same student + amount + same day, 2+ rows
  for r in
    select student_id, coalesce(student_name,'') as student_name, amount_paid,
           date(created_at) as day, count(*) as n, array_agg(id order by created_at) as ids
      from public.fee_payments
     where student_id is not null and coalesce(amount_paid,0) > 0
     group by student_id, coalesce(student_name,''), amount_paid, date(created_at)
    having count(*) > 1
  loop
    issues := issues || jsonb_build_array(jsonb_build_object(
      'kind','duplicate','student_id',r.student_id,'student',r.student_name,
      'amount',r.amount_paid,'day',r.day,'count',r.n,'row_ids',to_jsonb(r.ids),
      'advice','Same student, same amount, same day, recorded '||r.n||' times. If it is a double entry, delete the extra row(s) — the ledger recomputes itself.'));
  end loop;

  -- 2. unlinked rows
  for r in select id, coalesce(student_name,'') as student_name, amount_paid, created_at
             from public.fee_payments where student_id is null limit 200
  loop
    issues := issues || jsonb_build_array(jsonb_build_object(
      'kind','unlinked','row_id',r.id,'student',r.student_name,'amount',r.amount_paid,
      'advice','No student is linked — this payment reaches NO dashboard, receipt or arrears computation. Edit the row and pick the student.'));
  end loop;

  -- 3. non-positive amounts
  for r in select id, student_id, coalesce(student_name,'') as student_name, amount_paid
             from public.fee_payments where coalesce(amount_paid,0) <= 0 limit 200
  loop
    issues := issues || jsonb_build_array(jsonb_build_object(
      'kind','non_positive','row_id',r.id,'student',r.student_name,'amount',r.amount_paid,
      'advice','Zero or negative amount. Delete it, or edit it to the real figure.'));
  end loop;

  -- 4. future-dated
  for r in select id, coalesce(student_name,'') as student_name, amount_paid, created_at
             from public.fee_payments where created_at > now() + interval '1 day' limit 200
  loop
    issues := issues || jsonb_build_array(jsonb_build_object(
      'kind','future_dated','row_id',r.id,'student',r.student_name,'amount',r.amount_paid,'when',r.created_at,
      'advice','Recorded with a future date — it will sort above real payments and distort the running balance order.'));
  end loop;

  -- 5. missing term/session
  for r in select id, coalesce(student_name,'') as student_name, amount_paid
             from public.fee_payments
            where student_id is not null and (coalesce(term,'')='' or coalesce(session,'')='') limit 200
  loop
    issues := issues || jsonb_build_array(jsonb_build_object(
      'kind','no_period','row_id',r.id,'student',r.student_name,'amount',r.amount_paid,
      'advice','Missing term/session — this row escapes every term filter and every arrears computation. Edit it and set the period (current: '||coalesce(cur.term,'?')||' '||coalesce(cur.session,'?')||').'));
  end loop;

  -- 6+7. per student+term: overpayment and stale snapshots (recompute simulation)
  for r in
    select student_id, coalesce(term,'') as term, coalesce(session,'') as session,
           max(coalesce(student_name,'')) as student_name,
           sum(coalesce(amount_paid,0)) as paid,
           max(coalesce(fee_total,0) + paid_before) as grand_guess
      from (
        select fp.*, coalesce((select sum(coalesce(f2.amount_paid,0)) from public.fee_payments f2
                 where f2.student_id = fp.student_id
                   and coalesce(f2.term,'') = coalesce(fp.term,'')
                   and coalesce(f2.session,'') = coalesce(fp.session,'')
                   and (f2.created_at < fp.created_at or (f2.created_at = fp.created_at and f2.id < fp.id))),0) as paid_before
          from public.fee_payments fp
         where fp.student_id is not null
      ) x
     group by student_id, coalesce(term,''), coalesce(session,'')
  loop
    if r.grand_guess > 0 and r.paid > r.grand_guess then
      issues := issues || jsonb_build_array(jsonb_build_object(
        'kind','overpayment','student_id',r.student_id,'student',r.student_name,
        'term',r.term,'session',r.session,'paid',r.paid,'grand_total',r.grand_guess,'excess',r.paid - r.grand_guess,
        'advice','Total recorded ('||r.paid||') exceeds the reconstructed bill ('||r.grand_guess||'). Either an amount was typed too high, a payment landed on the wrong student, or the bill itself is missing — review this student''s rows.'));
    end if;
    if p_heal then
      perform public.sc_recompute_fee_rows(r.student_id, r.term, r.session);
      healed := healed + 1;
    end if;
  end loop;

  -- stale snapshots (only reported when NOT healing — heal fixes them all)
  if not p_heal then
    for r in
      select fp.id, coalesce(fp.student_name,'') as student_name, fp.student_id,
             coalesce(fp.term,'') as term, coalesce(fp.session,'') as session
        from public.fee_payments fp
       where fp.student_id is not null and coalesce(fp.fee_total,0) > 0
         and coalesce(fp.balance,-1) <> greatest(coalesce(fp.fee_total,0) - coalesce(fp.amount_paid,0), 0)
       limit 200
    loop
      issues := issues || jsonb_build_array(jsonb_build_object(
        'kind','stale_snapshot','row_id',r.id,'student',r.student_name,
        'advice','Stored balance disagrees with total − paid (pre-V10.8 row or external writer). Run the doctor with Heal to rewrite all snapshots.'));
    end loop;
  end if;

  return jsonb_build_object('ok',true,'issues',issues,'issue_count',jsonb_array_length(issues),
    'healed_terms',case when p_heal then healed else 0 end,
    'current_term',coalesce(cur.term,''),'current_session',coalesce(cur.session,''));
end $$;
revoke execute on function public.sc_fee_ledger_doctor(boolean) from public, anon;
grant execute on function public.sc_fee_ledger_doctor(boolean) to authenticated;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.9b fee-doctor pack installed' as status;
