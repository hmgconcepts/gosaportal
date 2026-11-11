-- =====================================================================
--  School Connect V12.67 — INVOICE-BASED FEE LEDGER
--  "A bill is recorded once. Arrears are unpaid bills. Nothing is guessed."
-- =====================================================================
--
-- WHAT WAS WRONG
-- ---------------
-- The screenshots show one learner (OLAYIWOLA TOFUNMI AJOKEADE · JSS 3) with:
--
--   Fees & Payments page            Dashboard "School Fees — Current Term"
--   -----------------------------   -------------------------------------
--   total due 23,100 / 28,100 /     total fees this term     28,100
--   33,100 on three separate        paid                     20,000
--   receipts — the first and        balance this term         8,100
--   third disagreeing with the      previous terms owing     36,100   <-- INVENTED
--   class structure                 total outstanding        44,200
--
-- Two independent faults produced this.
--
-- FAULT 1 — ARREARS WERE INFERRED, NEVER RECORDED.
--   `sc_fee_ledger_for` walked `academic_periods`, joined it to
--   `class_fee_structure` on class + session + term, and charged the learner a
--   bill for every dated term their record predated. Nothing in the school had
--   ever billed them for those terms. A fee structure entered with the default
--   term label ('Current Term') matches EVERY academic period, so a single
--   current-term structure silently became a bill for every historical term in
--   the calendar. The bursar entered no previous-terms debt, and the dashboard
--   showed ₦36,100 of it. The learner owes none.
--
--   This fails the most basic rule of receivables accounting: a receivable
--   exists only if an invoice was raised. You cannot owe money nobody billed.
--
-- FAULT 2 — THE BILL WAS A PER-RECEIPT SNAPSHOT THAT THE UI WROTE BACK.
--   `fee_payments.fee_total` was auto-filled with the learner's CURRENT TOTAL
--   DUE (which already includes arrears and prior balance) and saved onto that
--   one receipt row. On the next receipt it was filled again, now including the
--   earlier balance. So the "total fees" column drifted upward by roughly the
--   amount already paid, once per receipt: 23,100 → 28,100 → 33,100. The Fees
--   & Payments page read that column; the dashboard read the ledger. They could
--   not agree, and neither was a bill.
--
-- WHAT THIS PACK DOES
-- -------------------
-- A1  A real invoice table. One row per learner per term. It is the only source
--     of "what this learner was billed for that term".
-- A2  `sc_fee_invoice_sync` — raises/refreshes one learner's invoice from the
--     class structure, preserving a deliberate bursar override.
-- A3  `sc_fee_invoice_sync_all` — raises invoices for a whole class. Includes a
--     `p_prior_terms` switch: BACK-FILLING EARLIER TERMS IS OFF BY DEFAULT.
--     The school decides, explicitly, which past terms were really billed.
-- A4  `sc_fee_prior_terms` — the only way the engine learns about arrears. It
--     returns UNPAID INVOICES. Empty list when there were none.
-- A5  `sc_fee_payment_counted` — how a receipt is allocated across invoices,
--     oldest first (the standard rule), so a part-payment is never ambiguous.
-- A6  `sc_fee_ledger_for` v3 — arrears come from invoices only. The calendar is
--     never walked. No invoice ⇒ no arrears ⇒ the field is BLANK.
-- A7  `sc_fee_receipt_bill` — replaces the compounding per-receipt snapshot. It
--     reports the SAME term bill on every receipt of that term.
-- A8  `sc_fee_truth_migrate` — one-time, idempotent repair of the compounded
--     `fee_total` snapshots already in the table (audited, reversible in
--     intent: it writes what the receipt *should* have said and says so).
-- A9  `sc_fee_doctor_v3` — adds the invoice-integrity checks.
--
-- The model is deliberately narrow: one bill per learner per term, payments
-- allocated oldest-first, arrears = unpaid prior bills. That is what an auditor
-- expects and what a parent can be shown line by line.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A1. THE INVOICE — the missing record
-- ---------------------------------------------------------------------
create table if not exists public.sc_fee_invoice (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid references public.students(id) on delete cascade,
  student_id_ref text not null default '',
  class          text not null default '',
  term           text not null default '',
  session        text not null default '',
  amount         numeric not null default 0,   -- what was billed (gross)
  aid            numeric not null default 0,   -- scholarship / bursary applied
  net_amount     numeric not null default 0,   -- amount − aid
  source         text not null default 'structure', -- structure | override | manual | opening_balance
  note           text not null default '',
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create unique index if not exists sc_fee_invoice_unique
  on public.sc_fee_invoice(student_id, lower(btrim(term)), lower(btrim(session)));
create index if not exists sc_fee_invoice_student on public.sc_fee_invoice(student_id);
create index if not exists sc_fee_invoice_term    on public.sc_fee_invoice(lower(btrim(term)), lower(btrim(session)));

alter table public.sc_fee_invoice enable row level security;

drop policy if exists sc_fee_invoice_read on public.sc_fee_invoice;
create policy sc_fee_invoice_read on public.sc_fee_invoice for select to authenticated
  using (true);

drop policy if exists sc_fee_invoice_write on public.sc_fee_invoice;
create policy sc_fee_invoice_write on public.sc_fee_invoice for all to authenticated
  using (coalesce(public.is_admin(auth.uid()),false))
  with check (coalesce(public.is_admin(auth.uid()),false));

grant select, insert, update, delete on public.sc_fee_invoice to authenticated;

comment on table public.sc_fee_invoice is
  'V12.67 — one bill per learner per term. The ONLY source of arrears: an unpaid prior-term invoice. The calendar is never walked to invent a debt.';

-- ---------------------------------------------------------------------
-- A2. raise / refresh ONE learner's invoice for one term
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_invoice_sync(p_student uuid,
                                                      p_term text default null,
                                                      p_session text default null,
                                                      p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); st record; b jsonb; t_term text; t_session text;
        ex record; amt numeric := 0; aid numeric := 0; src text := 'structure';
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;

  b := public.sc_fee_bill_v2(p_student, p_term, p_session);
  t_term    := coalesce(nullif(btrim(p_term),''),    b->>'term',    '');
  t_session := coalesce(nullif(btrim(p_session),''), b->>'session', '');
  if coalesce(t_term,'') = '' then
    /* V12.68 — one resolver; never a bare is_current probe */
    b := public.sc_term_resolve(p_term, p_session);
    t_term := coalesce(b->>'term',''); t_session := coalesce(b->>'session','');
  end if;

  select * into ex from public.sc_fee_invoice
   where student_id = p_student
     and lower(btrim(term))    = lower(btrim(coalesce(t_term,'')))
     and lower(btrim(session)) = lower(btrim(coalesce(t_session,'')))
   limit 1;

  /* a bursar's deliberate figure is never overwritten by a structure edit */
  if ex.id is not null and ex.source in ('override','manual') and not coalesce(p_force,false) then
    return jsonb_build_object('ok',true,'action','kept','id',ex.id,
      'amount',ex.net_amount,'source',ex.source,
      'message','A figure was set by hand for this term; the class structure does not replace it.');
  end if;

  amt := coalesce(nullif(b->>'bill','')::numeric, 0);
  aid := coalesce(nullif(b->>'aid','')::numeric, 0);
  if coalesce((b->>'bill_known')::boolean, true) = false then
    /* No structure for this term. Do NOT raise a phantom invoice — say so. */
    return jsonb_build_object('ok',true,'action','unbilled','id',null,
      'term',t_term,'session',t_session,
      'message', coalesce(b->>'match_note','No fee structure for this term — no invoice raised.'));
  end if;
  if amt <= 0 then
    return jsonb_build_object('ok',true,'action','zero','id',null,'term',t_term,'session',t_session,
      'message','The fee structure for this term bills zero — no invoice raised.');
  end if;
  if coalesce((b->>'overridden')::boolean,false) then src := 'override'; end if;

  insert into public.sc_fee_invoice(student_id,student_id_ref,class,term,session,
                                    amount,aid,net_amount,source,note,created_by,updated_at)
  values(st.id, coalesce(st.admission_no,''), coalesce(st.class,''), t_term, t_session,
         amt+aid, aid, amt, src, coalesce(b->>'match_note',''), me, now())
  on conflict (student_id, lower(btrim(term)), lower(btrim(session))) do update
    set amount = excluded.amount,
        aid = excluded.aid,
        net_amount = excluded.net_amount,
        source = excluded.source,
        note = excluded.note,
        class = excluded.class,
        student_id_ref = excluded.student_id_ref,
        updated_at = now();

  return jsonb_build_object('ok',true,'action',case when ex.id is null then 'raised' else 'refreshed' end,
    'term',t_term,'session',t_session,'amount',amt,'aid',aid,'source',src);
end $$;
revoke all on function public.sc_fee_invoice_sync(uuid,text,text,boolean) from public, anon;
grant execute on function public.sc_fee_invoice_sync(uuid,text,text,boolean) to authenticated;

-- ---------------------------------------------------------------------
-- A3. raise invoices for a whole class — prior terms OFF by default
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_invoice_sync_all(p_class text default null,
                                                          p_term text default null,
                                                          p_session text default null,
                                                          p_prior_terms boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); st record; r jsonb; ap jsonb; n_raised int := 0; n_kept int := 0;
        n_unbilled int := 0; per record; st2 record; t_term text; t_session text; skipped jsonb := '[]'::jsonb;
begin
  if me is null or not coalesce(public.is_admin(me),false) then
    return jsonb_build_object('ok',false,'error','Only an administrator can raise fee invoices.');
  end if;
  ap := public.sc_term_resolve(p_term, p_session);
  t_term    := coalesce(nullif(btrim(p_term),''),    ap->>'term',    '');

  for st in select * from public.students
             where (p_class is null or p_class = '' or lower(btrim(class)) = lower(btrim(p_class)))
               and coalesce(status,'active') not in ('inactive','left','withdrawn','graduated','deleted')
  loop
    r := public.sc_fee_invoice_sync(st.id, t_term, t_session, false);
    if coalesce(r->>'action','') in ('raised','refreshed') then n_raised := n_raised + 1;
    elsif (r->>'action') = 'kept'      then n_kept := n_kept + 1;
    elsif (r->>'action') = 'unbilled'  then
      n_unbilled := n_unbilled + 1;
      if jsonb_array_length(skipped) < 50 then
        skipped := skipped || jsonb_build_array(jsonb_build_object(
          'student',st.full_name,'class',st.class,'reason',coalesce(r->>'message','no structure')));
      end if;
    end if;
  end loop;

  /* ---- prior terms: ONLY when the school explicitly asks ----
     This is the whole point of the fix. The old engine invented these silently.
     Now a human says "yes, these learners were billed for that term", and a
     durable, reviewable, correctable invoice is created — never re-derived on
     every read. */
  if coalesce(p_prior_terms,false) then
    for per in select term, session from public.academic_periods
               where starts_on is not null
                 and not (lower(coalesce(term,''))    = lower(coalesce(t_term,''))
                      and lower(coalesce(session,'')) = lower(coalesce(t_session,'')))
               order by starts_on
    loop
      for st2 in select * from public.students s2
                 where (p_class is null or p_class = '' or lower(btrim(s2.class)) = lower(btrim(p_class)))
                   and coalesce(s2.status,'active') not in ('inactive','left','withdrawn','graduated','deleted')
                   /* on roll, provably */
                   and s2.created_at::date <= coalesce(per.ends_on, per.starts_on)
      loop
        r := public.sc_fee_invoice_sync(st2.id, per.term, per.session, false);
        if coalesce(r->>'action','') in ('raised','refreshed') then n_raised := n_raised + 1; end if;
      end loop;
    end loop;
  end if;

  return jsonb_build_object('ok',true,'term',t_term,'session',t_session,
    'raised',n_raised,'kept_overrides',n_kept,'unbilled',n_unbilled,
    'prior_terms_included', coalesce(p_prior_terms,false),
    'skipped', skipped,
    'message', case when coalesce(p_prior_terms,false)
      then 'Invoices raised for this term and for every earlier dated term.'
      else 'Invoices raised for this term only. Earlier terms were left alone — run again with prior terms enabled only if those learners really were billed then.' end);
end $$;
revoke all on function public.sc_fee_invoice_sync_all(text,text,text,boolean) from public, anon;
grant execute on function public.sc_fee_invoice_sync_all(text,text,text,boolean) to authenticated;

-- ---------------------------------------------------------------------
-- A4. the ONLY source of arrears: unpaid earlier invoices
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_prior_terms(p_student uuid,
                                                     p_term text default null,
                                                     p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare cur jsonb; t_term text; t_session text; out_rows jsonb := '[]'::jsonb; i record;
        paid numeric; owing numeric;
begin
  cur := public.sc_term_resolve(p_term, p_session);
  t_term    := coalesce(nullif(btrim(p_term),''),    cur->>'term',    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur->>'session', '');

  /* NOTE: this walks INVOICES, never the calendar. A learner who was never
     billed for a term has no row here and therefore owes nothing for it. */
  for i in select * from public.sc_fee_invoice inv
            where inv.student_id = p_student
              and not (lower(coalesce(inv.term,''))    = lower(coalesce(t_term,''))
                   and lower(coalesce(inv.session,'')) = lower(coalesce(t_session,'')))
            order by inv.session, inv.term
  loop
    select coalesce(sum(amount_paid),0) into paid from public.fee_payments
     where student_id = p_student
       and lower(coalesce(term,''))    = lower(coalesce(i.term,''))
       and lower(coalesce(session,'')) = lower(coalesce(i.session,''));
    owing := greatest(coalesce(i.net_amount,0) - paid, 0);
    if owing > 0.005 then
      out_rows := out_rows || jsonb_build_array(jsonb_build_object(
        'invoice_id', i.id,
        'term', i.term, 'session', i.session,
        'bill', i.net_amount, 'paid', paid, 'owing', owing,
        'source', i.source,
        'opening', (i.source = 'opening_balance'),
        'note', i.note));
    end if;
  end loop;
  return out_rows;
end $$;
revoke all on function public.sc_fee_prior_terms(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_prior_terms(uuid,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- A5. allocate a part-payment across invoices, oldest first
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_allocate(p_student uuid,
                                                  p_amount numeric,
                                                  p_term text default null,
                                                  p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare cur jsonb; t_term text; t_session text; left_over numeric := greatest(coalesce(p_amount,0),0);
        i record; paid numeric; owing numeric; alloc jsonb := '[]'::jsonb; take numeric;
begin
  cur := public.sc_term_resolve(p_term, p_session);
  t_term    := coalesce(nullif(btrim(p_term),''),    cur->>'term',    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur->>'session', '');

  /* standard practice: oldest debt first, so the dues report stays meaningful */
  for i in select * from public.sc_fee_invoice inv
            where inv.student_id = p_student
            order by inv.session nulls first, inv.term
  loop
    exit when left_over <= 0.005;
    select coalesce(sum(amount_paid),0) into paid from public.fee_payments
     where student_id = p_student
       and lower(coalesce(term,''))    = lower(coalesce(i.term,''))
       and lower(coalesce(session,'')) = lower(coalesce(i.session,''));
    owing := greatest(coalesce(i.net_amount,0) - paid, 0);
    continue when owing <= 0.005;
    take := least(left_over, owing);
    left_over := left_over - take;
    alloc := alloc || jsonb_build_array(jsonb_build_object(
      'term',i.term,'session',i.session,'applied',take,
      'is_current_term',(lower(coalesce(i.term,'')) = lower(coalesce(t_term,''))
                     and lower(coalesce(i.session,'')) = lower(coalesce(t_session,'')))));
  end loop;
  return jsonb_build_object('ok',true,'amount',coalesce(p_amount,0),
    'allocated', coalesce(p_amount,0) - left_over, 'unallocated', greatest(left_over,0),
    'lines', alloc);
end $$;
revoke all on function public.sc_fee_allocate(uuid,numeric,text,text) from public, anon;
grant execute on function public.sc_fee_allocate(uuid,numeric,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- A6. the ledger — arrears from invoices only
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_ledger_for(p_student uuid,
                                                    p_term text default null,
                                                    p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  st record; cur jsonb; b jsonb;
  t_term text; t_session text;
  inv record;
  net_bill numeric := 0; aid numeric := 0; gross numeric := 0;
  paid numeric := 0; this_bal numeric := 0;
  arrears numeric := 0; arr_rows jsonb := '[]'::jsonb;
  total_out numeric := 0;
  matched_pct numeric := 100; paid_pct numeric := 100; owed_pct numeric := 0;
  status_txt text; n_receipts int := 0; last_pay date; bill_known boolean := true;
  n_checks jsonb := '[]'::jsonb; r record; row_owing numeric; row_paid numeric;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  cur := public.sc_term_resolve(p_term, p_session);
  t_term    := coalesce(nullif(btrim(p_term),''),    cur->>'term',    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur->>'session', '');

  /* ---------- 1. THIS TERM'S BILL ----------
     Read from the invoice when one exists. The invoice is what the school
     actually billed; the structure is only consulted to RAISE it. */
  select * into inv from public.sc_fee_invoice i
   where i.student_id = p_student
     and lower(btrim(i.term))    = lower(btrim(coalesce(t_term,'')))
     and lower(btrim(i.session)) = lower(btrim(coalesce(t_session,'')))
   limit 1;

  if inv.id is not null then
    gross    := coalesce(inv.amount,0);
    aid      := coalesce(inv.aid,0);
    net_bill := coalesce(inv.net_amount, coalesce(inv.amount,0) - coalesce(inv.aid,0));
    bill_known := true;
    b := jsonb_build_object('bill', net_bill, 'aid', aid, 'bill_known', true,
                            'match_note', coalesce(inv.note,''),
                            'breakdown','[]'::jsonb);
  else
    /* No invoice: fall back to the structure for DISPLAY, but flag it. A
       learner with no invoice has not been billed by this system. */
    b := public.sc_fee_bill_v2(p_student, t_term, t_session);
    net_bill   := coalesce(nullif(b->>'bill','')::numeric, 0);
    aid        := coalesce(nullif(b->>'aid','')::numeric, 0);
    bill_known := coalesce((b->>'bill_known')::boolean, true);
    if net_bill > 0 then
      n_checks := n_checks || jsonb_build_array(jsonb_build_object(
        'check','no_invoice',
        'detail','No invoice has been raised for this term, so the bill shown is taken from the class fee structure. Raise invoices from the Fees page so the bill is recorded rather than inferred.'));
    end if;
  end if;

  /* ---------- 2. money received for THIS term ---------- */
  select coalesce(sum(amount_paid),0), count(*), max(coalesce(payment_date, created_at::date))
    into paid, n_receipts, last_pay
    from public.fee_payments
   where student_id = p_student
     and lower(coalesce(term,''))    = lower(coalesce(t_term,''))
     and lower(coalesce(session,'')) = lower(coalesce(t_session,''));
  this_bal := greatest(net_bill - paid, 0);

  /* ---------- 3. EARLIER TERMS — from invoices, nothing else ---------- */
  arr_rows := public.sc_fee_prior_terms(p_student, t_term, t_session);
  for r in select value as v from jsonb_array_elements(arr_rows) loop
    arrears := arrears + coalesce(nullif(r.v->>'owing','')::numeric, 0);
  end loop;

  total_out := this_bal + arrears;

  /* ---------- 4. status ---------- */
  if not bill_known then
    status_txt := 'unbilled';
  elsif paid <= 0.005 and this_bal <= 0.005 and arrears <= 0.005 then
    status_txt := case when net_bill <= 0.005 then 'no-bill' else 'unpaid' end;
  elsif this_bal <= 0.005 and arrears <= 0.005 then
    status_txt := 'paid';
  elsif paid <= 0.005 then
    status_txt := 'debtor';
  else
    status_txt := 'partial';
  end if;

  matched_pct := case when (net_bill + arrears) > 0
                      then greatest(0, least(100, round(paid * 100.0 / (net_bill + arrears), 2))) else 100 end;
  paid_pct := matched_pct;
  owed_pct := greatest(0, 100 - matched_pct);

  return jsonb_build_object(
    'ok', true,
    'student_id', st.id,
    'student', st.full_name,
    'admission_no', coalesce(st.admission_no,''),
    'class', coalesce(st.class,''),
    'arm', coalesce(st.arm,''),
    'term', t_term, 'session', t_session,
    'currency', public.sc_currency(),
    'bill', net_bill,          -- "Total fees this term"
    'gross_bill', gross,
    'aid', aid,
    'paid', paid,              -- "Paid"
    'balance', this_bal,       -- "Balance this term"
    'arrears', arrears,        -- "Previous terms owing"  (0 ⇒ render BLANK)
    'has_arrears', (arrears > 0.005),   -- the flag the UI must use
    'total_due', total_out,    -- "Total outstanding"
    'bill_known', bill_known,
    'invoiced', (inv.id is not null),
    'invoice_id', inv.id,
    'match_note', coalesce(b->>'match_note',''),
    'bill_breakdown', coalesce(b->'breakdown','[]'::jsonb),
    'arrears_rows', arr_rows,
    'receipts', n_receipts,
    'last_payment', last_pay,
    'paid_pct', matched_pct, 'owed_pct', owed_pct,
    'status', status_txt,
    'checks', n_checks,
    /* the four-line arithmetic, blank-safe */
    'explain', jsonb_build_array(
      jsonb_build_object('line','Total fees this term','amount',net_bill,
        'note', case when inv.id is null then 'From the class fee structure — no invoice raised yet'
                     else 'From the invoice raised for this term' end),
      jsonb_build_object('line','Add previous terms owing','amount',arrears,
        'note', case when arrears > 0.005 then 'Unpaid invoices from earlier terms'
                     else 'Nothing owed from earlier terms' end),
      jsonb_build_object('line','Less total paid so far','amount',-paid,
        'note', n_receipts||' receipt(s) recorded for this term'),
      jsonb_build_object('line','TOTAL OUTSTANDING','amount',total_out,
        'note','Fees this term + previous terms owing − paid')));
end $$;
revoke all on function public.sc_fee_ledger_for(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_ledger_for(uuid,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- A7. what a RECEIPT should print — the same bill on every receipt
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_receipt_bill(p_payment uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare p record; led jsonb; t_term text; t_session text;
begin
  select * into p from public.fee_payments where id = p_payment;
  if p.id is null then return jsonb_build_object('ok',false,'error','Receipt not found.'); end if;
  t_term := coalesce(p.term,''); t_session := coalesce(p.session,'');
  led := public.sc_fee_ledger_for(p.student_id, t_term, t_session);
  return jsonb_build_object(
    'ok', true,
    'receipt_id', p.id,
    'term', t_term, 'session', t_session,
    'bill',  coalesce((led->>'bill')::numeric,0),     -- the term bill, never a running total
    'paid_this_receipt', p.amount_paid,
    'paid_to_date', coalesce((led->>'paid')::numeric,0),
    'balance_now', coalesce((led->>'balance')::numeric,0),
    'arrears', coalesce((led->>'arrears')::numeric,0),
    'has_arrears', coalesce((led->>'has_arrears')::boolean,false));
end $$;
revoke all on function public.sc_fee_receipt_bill(uuid) from public, anon;
grant execute on function public.sc_fee_receipt_bill(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- A8. repair the compounded per-receipt snapshots already stored
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_truth_migrate(p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); p record; led jsonb; real_bill numeric;
        n_scanned int := 0; n_fixed int := 0; samples jsonb := '[]'::jsonb;
begin
  if me is null or not coalesce(public.is_admin(me),false) then
    return jsonb_build_object('ok',false,'error','Only an administrator can repair fee snapshots.');
  end if;

  for p in select * from public.fee_payments
            where coalesce(fee_total,0) > 0 and coalesce(total_overridden,false) is not true
            order by created_at
  loop
    n_scanned := n_scanned + 1;
    /* The authoritative bill for that receipt's term is the INVOICE. Reading the
       ledger here would be unstable: the ledger can fall back to the class
       structure, which never changes, but if it ever read fee_total the repair
       would cascade as it rewrote rows one at a time. The invoice is fixed. */
    select coalesce(i.net_amount, null) into real_bill
      from public.sc_fee_invoice i
     where i.student_id = p.student_id
       and lower(btrim(i.term))    = lower(btrim(coalesce(p.term,'')))
       and lower(btrim(i.session)) = lower(btrim(coalesce(p.session,'')))
     limit 1;
    if real_bill is null then
      /* no invoice yet — fall back to the structure, never to a stored snapshot */
      led := public.sc_fee_bill_v2(p.student_id, p.term, p.session);
      real_bill := coalesce((led->>'bill')::numeric, 0);
    end if;
    if real_bill > 0 and abs(coalesce(p.fee_total,0) - real_bill) > 0.005 then
      n_fixed := n_fixed + 1;
      if jsonb_array_length(samples) < 20 then
        samples := samples || jsonb_build_array(jsonb_build_object(
          'student', p.student_name, 'term', p.term, 'session', p.session,
          'stored', p.fee_total, 'correct', real_bill,
          'difference', coalesce(p.fee_total,0) - real_bill));
      end if;
      if not coalesce(p_dry_run,true) then
        update public.fee_payments
           set fee_total = real_bill,
               balance   = greatest(real_bill - coalesce(amount_paid,0), 0)
         where id = p.id;
      end if;
    end if;
  end loop;

  return jsonb_build_object('ok',true,'dry_run',coalesce(p_dry_run,true),
    'scanned',n_scanned,'would_fix',n_fixed,'fixed', case when coalesce(p_dry_run,true) then 0 else n_fixed end,
    'samples',samples,
    'message', case when n_fixed = 0 then 'Every stored receipt total already matches the term bill.'
      when coalesce(p_dry_run,true) then n_fixed||' receipt row(s) carry a compounded total. Re-run with dry_run=false to correct them.'
      else n_fixed||' receipt row(s) corrected. Each now shows the term bill, not a running balance.' end);
end $$;
revoke all on function public.sc_fee_truth_migrate(boolean) from public, anon;
grant execute on function public.sc_fee_truth_migrate(boolean) to authenticated;


-- ---------------------------------------------------------------------
-- A12. THE COMPOUNDING ENGINE ITSELF — sc_recompute_fee_rows
--
--  This is the function that manufactured the 23,100 → 28,100 → 33,100 drift.
--  It reconstructed the term's "grand total" as, for every row,
--
--        candidate  =  row.fee_total  +  everything paid before that row
--
--  and kept the LARGEST candidate. But row.fee_total was itself the learner's
--  total due (bill + arrears − paid) at the moment the receipt was saved. So
--  the candidate double-counted every earlier payment, and because it kept the
--  maximum it grew monotonically. It then wrote that inflated figure back onto
--  every row — so the "heal" was the disease, and each new receipt made it
--  worse. The Fees page read those snapshots; the dashboard read the ledger.
--
--  THE FIX: the grand total is the INVOICE. It is never reconstructed from the
--  rows being repaired. Every receipt of a term then carries the SAME bill,
--  which is what a receipt is supposed to say.
-- ---------------------------------------------------------------------
create or replace function public.sc_recompute_fee_rows(p_student uuid,
                                                        p_term text default '',
                                                        p_session text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare grand numeric := null; r record; paid_before numeric := 0; n int := 0; b jsonb; inv numeric;
begin
  if p_student is null then return jsonb_build_object('ok',false,'error','No student.'); end if;

  /* 1. THE BILL — from the invoice, which cannot drift. */
  select i.net_amount into inv from public.sc_fee_invoice i
   where i.student_id = p_student
     and lower(btrim(i.term))    = lower(btrim(coalesce(p_term,'')))
     and lower(btrim(i.session)) = lower(btrim(coalesce(p_session,'')))
   limit 1;
  grand := inv;

  if grand is null then
    /* no invoice yet: ask the structure, never the stored snapshots */
    b := public.sc_fee_bill_v2(p_student, p_term, p_session);
    if coalesce((b->>'bill_known')::boolean,true) then
      grand := nullif((b->>'bill')::numeric, 0);
    end if;
  end if;

  /* A genuine bursar override on a row still wins — it is a deliberate figure. */
  for r in select id, coalesce(fee_total,0) ft, coalesce(total_overridden,false) ovr
             from public.fee_payments
            where student_id = p_student
              and coalesce(term,'')    = coalesce(p_term,'')
              and coalesce(session,'') = coalesce(p_session,'')
              and coalesce(total_overridden,false)
              and coalesce(fee_total,0) > 0
            order by created_at desc nulls last limit 1
  loop
    grand := r.ft;
  end loop;

  if grand is null then
    /* Bill unknown. Leave the rows alone rather than invent a number. */
    return jsonb_build_object('ok',true,'rows',0,'grand_total',null,
      'message','No invoice and no fee structure for this term — snapshots left untouched.');
  end if;

  /* 2. Rewrite every snapshot of this term to the SAME bill, with a running
        balance. fee_total is the term bill — identical on every receipt. */
  paid_before := 0;
  for r in select id, coalesce(amount_paid,0) amt
             from public.fee_payments
            where student_id = p_student
              and coalesce(term,'')    = coalesce(p_term,'')
              and coalesce(session,'') = coalesce(p_session,'')
            order by created_at asc nulls last, id asc
  loop
    update public.fee_payments
       set fee_total = grand,
           balance   = greatest(grand - paid_before - r.amt, 0)
     where id = r.id
       and (coalesce(fee_total,-1) <> grand
         or coalesce(balance,-1)   <> greatest(grand - paid_before - r.amt, 0));
    paid_before := paid_before + r.amt;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok',true,'rows',n,'grand_total',grand,
    'paid',paid_before,'outstanding',greatest(grand - paid_before, 0));
end $$;
revoke all on function public.sc_recompute_fee_rows(uuid,text,text) from public, anon;
grant execute on function public.sc_recompute_fee_rows(uuid,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- A9. the doctor — invoice integrity
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_doctor_v3(p_class text default null,
                                                    p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid();
        c_noinv int := 0; c_holes int := 0; c_dup int := 0; c_neg int := 0;
        c_stale int := 0; c_orphan int := 0;
        j record; v2 jsonb; f jsonb := '[]'::jsonb; n_fixed int := 0;
begin
  if me is null or not coalesce(public.is_staff(me),false) then
    return jsonb_build_object('ok',false,'error','Only staff can run the fee doctor.');
  end if;

  /* 1. active learners with NO invoice for the current term */
  select count(*) into c_noinv
    from public.students s
    join public.academic_periods ap on ap.is_current
   where (p_class is null or p_class = '' or lower(btrim(s.class)) = lower(btrim(p_class)))
     and coalesce(s.status,'active') not in ('inactive','left','withdrawn','graduated','deleted')
     and not exists (select 1 from public.sc_fee_invoice i
                      where i.student_id = s.id
                        and lower(btrim(i.term))    = lower(btrim(coalesce(ap.term,'')))
                        and lower(btrim(i.session)) = lower(btrim(coalesce(ap.session,''))));
  if c_noinv > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','no_invoice','severity','warning',
      'count',c_noinv,'student','(all learners)',
      'issue', c_noinv||' learner(s) have no invoice for the current term. Their bill is being taken from the class structure on every read instead of being recorded once.',
      'fix','Press “Raise invoices for this term” on the Fees page. It writes one bill per learner and can be re-run safely.'));
  end if;

  /* 2. payments in a term where no invoice was ever raised */
  for j in select fp.student_id, fp.student_name, fp.term, fp.session, count(*) n, sum(fp.amount_paid) amt
             from public.fee_payments fp
            where not exists (select 1 from public.sc_fee_invoice i
                               where i.student_id = fp.student_id
                                 and lower(btrim(i.term))    = lower(btrim(coalesce(fp.term,'')))
                                 and lower(btrim(i.session)) = lower(btrim(coalesce(fp.session,''))))
            group by 1,2,3,4
  loop
    c_holes := c_holes + 1;
    f := f || jsonb_build_array(jsonb_build_object('kind','payment_without_invoice','severity','needs_human',
      'student',j.student_name,'term',j.term,'session',j.session,'count',j.n,'amount',j.amt,
      'issue','A payment was received for a term that has no invoice. Nothing in the records says what was billed then.',
      'fix','Raise an invoice for that term if the learner really was billed, or re-stamp the receipt with the correct term if it was entered wrongly.'));
  end loop;

  /* 3. two invoices for the same learner and term */
  select count(*) into c_dup from (
    select student_id, lower(btrim(term)), lower(btrim(session)) from public.sc_fee_invoice
     group by 1,2,3 having count(*) > 1) x;
  if c_dup > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','duplicate_invoice','severity','error',
      'count',c_dup,'student','(invoices)',
      'issue','Two invoices exist for the same learner and term, so the bill is counted twice.',
      'fix','Delete the extra invoice. The table enforces one bill per learner per term, so this indicates a manual insert.'));
  end if;

  /* 4. negative or zero invoices */
  select count(*) into c_neg from public.sc_fee_invoice
   where coalesce(net_amount,0) < 0 or (coalesce(amount,0) > 0 and coalesce(net_amount,0) = 0);
  if c_neg > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','bad_invoice_amount','severity','warning',
      'count',c_neg,'student','(invoices)',
      'issue','An invoice carries a negative or impossible amount — most often aid larger than the bill.',
      'fix','Check the scholarship/aid entry for that learner, then refresh the invoice.'));
  end if;

  /* 5. receipts whose stored total disagrees with the term bill */
  select count(*) into c_stale from public.fee_payments fp
   where coalesce(fp.fee_total,0) > 0 and coalesce(fp.total_overridden,false) is not true
     and exists (select 1 from public.sc_fee_invoice i
                  where i.student_id = fp.student_id
                    and lower(btrim(i.term))    = lower(btrim(coalesce(fp.term,'')))
                    and lower(btrim(i.session)) = lower(btrim(coalesce(fp.session,'')))
                    and abs(i.net_amount - fp.fee_total) > 0.005);
  if c_stale > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','compounded_receipt_total','severity','warning',
      'count',c_stale,'student','(receipts)',
      'issue', c_stale||' receipt(s) carry a total that has grown each time a payment was saved. This is what made the Fees page disagree with the dashboard.',
      'fix','Run “Repair stored receipt totals” on the Fees page. It rewrites each receipt with the term bill and reports every change.'));
    if not coalesce(p_dry_run,true) then
      n_fixed := (public.sc_fee_truth_migrate(false)->>'fixed')::int;
    end if;
  end if;

  /* 6. invoices pointing at a student record that no longer exists */
  select count(*) into c_orphan from public.sc_fee_invoice i
   where i.student_id is not null
     and not exists (select 1 from public.students s where s.id = i.student_id);
  if c_orphan > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','orphan_invoice','severity','error',
      'count',c_orphan,'student','(invoices)',
      'issue','An invoice belongs to a learner who has been deleted, so it can never be paid or chased.',
      'fix','Archive or delete the orphan invoice.'));
  end if;

  /* fold in everything v2 already checks */
  v2 := public.sc_fee_doctor_v2(p_class, null, true);
  if coalesce((v2->>'ok')::boolean,false) then
    f := f || coalesce(v2->'findings','[]'::jsonb);
  end if;

  return jsonb_build_object('ok',true,'dry_run',coalesce(p_dry_run,true),
    'counts', jsonb_build_object('no_invoice',c_noinv,'payment_without_invoice',c_holes,
                                 'duplicate_invoice',c_dup,'bad_invoice_amount',c_neg,
                                 'compounded_receipt_total',c_stale,'orphan_invoice',c_orphan),
    'fixed', jsonb_build_object('stale_receipt_totals',n_fixed),
    'findings', f);
end $$;
revoke all on function public.sc_fee_doctor_v3(text,boolean) from public, anon;
grant execute on function public.sc_fee_doctor_v3(text,boolean) to authenticated;

-- ---------------------------------------------------------------------
-- A10. roll the school's opening balances into real invoices
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_opening_to_invoice(p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); s record; n int := 0; made jsonb := '[]'::jsonb;
begin
  if me is null or not coalesce(public.is_admin(me),false) then
    return jsonb_build_object('ok',false,'error','Only an administrator can convert opening balances.');
  end if;
  for s in select id, full_name, admission_no, class, opening_arrears, opening_arrears_note
             from public.students where coalesce(opening_arrears,0) > 0
  loop
    n := n + 1;
    made := made || jsonb_build_array(jsonb_build_object(
      'student', s.full_name, 'amount', s.opening_arrears,
      'note', coalesce(nullif(s.opening_arrears_note,''),'Opening balance')));
    if not coalesce(p_dry_run,true) then
      insert into public.sc_fee_invoice(student_id,student_id_ref,class,term,session,
                                        amount,aid,net_amount,source,note,created_by)
      values(s.id, coalesce(s.admission_no,''), coalesce(s.class,''),
             'Opening balance', coalesce(nullif(s.opening_arrears_note,''),'Before School Connect'),
             0, 0, s.opening_arrears, 'opening_balance',
             coalesce(nullif(s.opening_arrears_note,''),'Carried over from the paper ledger'), me)
      on conflict (student_id, lower(btrim(term)), lower(btrim(session))) do update
        set net_amount = excluded.net_amount, amount = excluded.amount,
            note = excluded.note, updated_at = now();
    end if;
  end loop;
  return jsonb_build_object('ok',true,'dry_run',coalesce(p_dry_run,true),'count',n,
    'students',made,
    'message', case when n = 0 then 'No learner has an opening balance entered.'
                    when coalesce(p_dry_run,true) then n||' opening balance(s) can be converted into real invoices.'
                    else n||' opening balance(s) are now invoices, so arrears are recorded rather than inferred.' end);
end $$;
revoke all on function public.sc_fee_opening_to_invoice(boolean) from public, anon;
grant execute on function public.sc_fee_opening_to_invoice(boolean) to authenticated;

-- ---------------------------------------------------------------------
-- A11. one screen-level reader: the Fees & Payments row
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_page_rows(p_class text default null,
                                                   p_term text default null,
                                                   p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare cur jsonb; t_term text; t_session text; out_rows jsonb := '[]'::jsonb;
        s record; led jsonb;
begin
  cur := public.sc_term_resolve(p_term, p_session);
  t_term    := coalesce(nullif(btrim(p_term),''),    cur->>'term',    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur->>'session', '');

  for s in select * from public.students
            where (p_class is null or p_class = '' or lower(btrim(class)) = lower(btrim(p_class)))
              and coalesce(status,'active') not in ('inactive','left','withdrawn','graduated','deleted')
            order by class, full_name
  loop
    led := public.sc_fee_ledger_for(s.id, t_term, t_session);
    out_rows := out_rows || jsonb_build_array(jsonb_build_object(
      'student_id',    s.id,
      'student',       s.full_name,
      'admission_no',  coalesce(s.admission_no,''),
      'class',         coalesce(s.class,''),
      'term',          t_term,
      'session',       t_session,
      'bill',          coalesce((led->>'bill')::numeric,0),
      'aid',           coalesce((led->>'aid')::numeric,0),
      'paid',          coalesce((led->>'paid')::numeric,0),
      'balance',       coalesce((led->>'balance')::numeric,0),
      'arrears',       coalesce((led->>'arrears')::numeric,0),
      'total_due',     coalesce((led->>'total_due')::numeric,0),
      /* the two flags the table MUST use: render blank, not zero */
      'has_arrears',   coalesce((led->>'has_arrears')::boolean,false),
      'invoiced',      coalesce((led->>'invoiced')::boolean,false),
      'bill_known',    coalesce((led->>'bill_known')::boolean,true),
      'status',        led->>'status',
      'receipts',      coalesce((led->>'receipts')::int,0),
      'last_payment',  led->>'last_payment'));
  end loop;
  return out_rows;
end $$;
revoke all on function public.sc_fee_page_rows(text,text,text) from public, anon;
grant execute on function public.sc_fee_page_rows(text,text,text) to authenticated;
