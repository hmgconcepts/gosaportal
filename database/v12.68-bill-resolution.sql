-- =====================================================================
--  School Connect V12.68 — BILL RESOLUTION & TERM CALENDAR
--  "A published class fee is never reported as ₦0."
-- =====================================================================
--
-- WHAT WAS WRONG (reported: dashboard "Total fees this term" shows ₦0)
-- --------------------------------------------------------------------
-- `sc_fee_bill_v2` found the school's "current term" with exactly one rule:
--
--     select term, session from academic_periods where is_current limit 1
--
-- If that one row did not exist — no period flagged, a freshly imported
-- calendar, a base install, an admin who never pressed "set current term", or
-- `is_current` pointing at a different term than the fee structure was entered
-- for — the resolved term became ('',''). The structure lookup then required
--
--     coalesce(f.term,'Current Term') in ('Current Term', '')
--
-- and any structure labelled 'First Term' failed that test. `bill_known`
-- became false and the bill collapsed to 0. Reproduced in four scenarios:
--
--     A. is_current = First Term 2026/2027   -> 35,100  structure
--     B. no period flagged is_current        ->      0  no_structure_this_term
--     C. is_current = a different term       ->      0  no_structure_this_term
--     D. academic_periods empty              ->      0  no_structure_this_term
--
-- A school that had entered a fee for every class saw ₦0 on every dashboard.
-- Meanwhile "previous terms owing" stayed 0 — correctly — so the card read
-- "0 · 0 · 0" and looked broken. It was.
--
-- Two further faults were found while fixing it:
--
--  * Two *independent* term resolvers existed. `sc_fee_ledger_for` and
--    `sc_fee_bill_v2` each read `academic_periods` themselves, so a receipt
--    stamped 'First Term' could be scored against whatever `is_current` said,
--    and the ledger's "this term" payments and the bill's term could disagree.
--
--  * A structure entered with the DEFAULT term label 'Current Term' matched
--    every academic period. That was the V12.67 phantom-arrears bug; the
--    label still needs to mean "the current term" — but only the *resolved*
--    current term, never an arbitrary historical one.
--
-- WHAT THIS PACK DOES
-- -------------------
-- B1  `sc_term_resolve` — ONE resolver, used by everything. Deterministic
--     ladder: explicit argument -> is_current -> dated period containing
--     today -> most recent dated period -> most recent period by session/term
--     -> the only term any fee structure was entered for -> the only term any
--     receipt was stamped with. Never returns ('','') while the school holds
--     any evidence of a term.
-- B2  `sc_term_current` — convenience wrapper.
-- B3  `sc_fee_bill_v2` v3 — uses the resolver, then a *scored* structure
--     matcher with a four-step ladder, and reports which step it used.
-- B4  `sc_fee_structure_for` — would this class be billed, and by what?
--     Lets the bursar see a missing structure before a parent does.
-- B5  `sc_fee_structure_doctor` — classes that bill nothing / conflict /
--     are missing for the resolved term.
-- B6  Notifications: a term with no `starts_on` is invisible to ageing, so
--     the resolver prefers dated periods and reports what it could not date.
--
-- Nothing here invents a debt. Arrears remain unpaid invoices only (V12.67).
-- =====================================================================


-- ---------------------------------------------------------------------
-- B1. THE RESOLVER — one answer to "which term is it?"
-- ---------------------------------------------------------------------
create or replace function public.sc_term_resolve(p_term text default null,
                                                  p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare t_term text; t_session text; r record; ev text := '';
begin
  t_term    := nullif(btrim(coalesce(p_term,'')),'');
  t_session := nullif(btrim(coalesce(p_session,'')),'');

  /* If the caller named a term, honour it. If they named only a session, fill
     the term from the calendar — and never the other way round silently. */
  if t_term is not null and t_session is null then
    select session into t_session from public.academic_periods
     where lower(btrim(term)) = lower(btrim(t_term))
       and coalesce(session,'') <> ''
     order by is_current desc nulls last, coalesce(starts_on,'1900-01-01') desc
     limit 1;
  end if;
  if t_term is not null and t_session is null then
    /* no calendar row for that term name: infer from the structures */
    select session into t_session from public.class_fee_structure
     where lower(btrim(term)) = lower(btrim(t_term)) and coalesce(session,'') <> ''
     order by updated_at desc nulls last limit 1;
  end if;
  if t_term is not null then
    return jsonb_build_object('ok',true,'term',t_term,'session',coalesce(t_session,''),
                              'resolved_by','explicit');
  end if;

  /* 1. the school's declared current term */
  select term, session into r from public.academic_periods
   where is_current is true limit 1;
  if r.term is not null and btrim(r.term) <> '' then
    return jsonb_build_object('ok',true,'term',r.term,'session',coalesce(r.session,''),
                              'resolved_by','is_current');
  end if;

  /* 2. the dated period containing today */
  select term, session into r from public.academic_periods
   where starts_on is not null and ends_on is not null
     and current_date between starts_on and ends_on
   order by starts_on desc limit 1;
  if r.term is not null and btrim(r.term) <> '' then
    return jsonb_build_object('ok',true,'term',r.term,'session',coalesce(r.session,''),
                              'resolved_by','calendar_today');
  end if;

  /* 3. the most recent period that has started */
  select term, session into r from public.academic_periods
   where starts_on is not null and starts_on <= current_date
   order by starts_on desc limit 1;
  if r.term is not null and btrim(r.term) <> '' then
    return jsonb_build_object('ok',true,'term',r.term,'session',coalesce(r.session,''),
                              'resolved_by','calendar_latest');
  end if;

  /* 4. the most recent period on the calendar at all */
  select term, session into r from public.academic_periods
   where coalesce(btrim(term),'') <> ''
   order by coalesce(starts_on, ends_on, '1900-01-01') desc, session desc, term desc
   limit 1;
  if r.term is not null and btrim(r.term) <> '' then
    return jsonb_build_object('ok',true,'term',r.term,'session',coalesce(r.session,''),
                              'resolved_by','calendar_last');
  end if;

  /* 5. no calendar at all — use the term the school actually entered fees for.
        A published structure is evidence of a term even when the calendar is
        blank. This is the case that produced ₦0 on every dashboard. */
  select term, session into r from public.class_fee_structure
   where coalesce(btrim(term),'') <> ''
     and lower(btrim(term)) <> 'current term'
   order by coalesce(session,'') desc, updated_at desc nulls last limit 1;
  if r.term is not null and btrim(r.term) <> '' then
    return jsonb_build_object('ok',true,'term',r.term,'session',coalesce(r.session,''),
                              'resolved_by','structure');
  end if;

  /* 6. fall back to however receipts were stamped */
  select term, session into r from public.fee_payments
   where coalesce(btrim(term),'') <> ''
   order by session desc nulls last, created_at desc nulls last limit 1;
  if r.term is not null and btrim(r.term) <> '' then
    return jsonb_build_object('ok',true,'term',r.term,'session',coalesce(r.session,''),
                              'resolved_by','receipts');
  end if;

  /* 7. nothing anywhere. Say so honestly — and let the caller decide. */
  return jsonb_build_object('ok',true,'term','','session','',
                            'resolved_by','none');
end $$;
revoke all on function public.sc_term_resolve(text,text) from public, anon;
grant execute on function public.sc_term_resolve(text,text) to authenticated;

create or replace function public.sc_term_current()
returns jsonb language sql stable security definer set search_path=public as $$
  select public.sc_term_resolve(null,null);
$$;
revoke all on function public.sc_term_current() from public, anon;
grant execute on function public.sc_term_current() to authenticated;

-- ---------------------------------------------------------------------
-- B2. NOTIFICATION: which periods cannot be aged
-- ---------------------------------------------------------------------
create or replace function public.sc_term_undated()
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('term',term,'session',session)
                            order by coalesce(session,''), term), '[]'::jsonb)
    from public.academic_periods
   where starts_on is null or ends_on is null;
$$;
revoke all on function public.sc_term_undated() from public, anon;
grant execute on function public.sc_term_undated() to authenticated;

-- ---------------------------------------------------------------------
-- B3. THE BILL — resolved term, then a scored structure ladder
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_bill_v2(p_student uuid,
                                                 p_term text default null,
                                                 p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare st record; tr jsonb; fs record; a record;
        structure_bill numeric := 0; aid_total numeric := 0; aid_rows jsonb := '[]'::jsonb;
        breakdown jsonb := '[]'::jsonb; ovr numeric; overridden boolean := false;
        eff_bill numeric := 0; t_term text; t_session text;
        match_status text; match_note text := ''; n_struct int := 0; n_any int := 0;
        inv record; matched_by text := '';
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;

  /* ---- ONE resolver. The caller may name a term; otherwise the shared
          ladder decides, and reports how it decided. ---- */
  tr := public.sc_term_resolve(p_term, p_session);
  t_term    := coalesce(tr->>'term','');
  t_session := coalesce(tr->>'session','');

  /* ---- an invoice, if one was raised, IS the bill ---- */
  select * into inv from public.sc_fee_invoice i
   where i.student_id = p_student
     and lower(btrim(i.term))    = lower(btrim(coalesce(t_term,'')))
     and lower(btrim(i.session)) = lower(btrim(coalesce(t_session,'')))
   limit 1;
  if inv.id is not null then
    return jsonb_build_object('ok',true,
      'student_id', st.id, 'class', st.class, 'arm', st.arm,
      'term', t_term, 'session', t_session, 'resolved_by', tr->>'resolved_by',
      'bill', coalesce(inv.net_amount,0),
      'structure_bill', coalesce(inv.amount,0) + coalesce(inv.aid,0),
      'aid', coalesce(inv.aid,0), 'aid_rows','[]'::jsonb,
      'breakdown', jsonb_build_array(jsonb_build_object('item','Invoice for '||t_term,'amount',coalesce(inv.net_amount,0))),
      'override', (coalesce(inv.source,'') = 'override'),
      'match_status','invoice', 'matched', true, 'bill_known', true, 'matched_by','invoice',
      'match_note', coalesce(inv.note,'The bill recorded on this learner''s invoice.'),
      'currency', public.sc_currency(),
      'due_date', null, 'note', coalesce(inv.note,''),
      'working','Invoice raised for '||t_term||' '||coalesce(t_session,'')||' = '||to_char(coalesce(inv.net_amount,0),'FM999,999,990.00'));
  end if;

  /* ---- the class structure ---- */
  select count(*) into n_any from public.class_fee_structure f
   where f.active is not false
     and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')))
     and coalesce(f.term,'Current Term') not in ('','Current Term');

  /* STEP 1 — this class, this term, this session (exact) */
  select * into fs from public.class_fee_structure f
   where f.active is not false
     and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')))
     and lower(btrim(coalesce(f.term,'Current Term'))) = lower(btrim(coalesce(t_term,'')))
     and (coalesce(f.session,'') = '' or f.session = coalesce(t_session,''))
   order by (lower(coalesce(f.arm,'')) = lower(coalesce(st.arm,''))) desc,
            (coalesce(f.arm,'') = '') desc,
            (lower(coalesce(f.department,'')) = lower(coalesce(st.department,''))) desc,
            (coalesce(f.department,'') = '') desc,
            (coalesce(f.session,'') <> '') desc,
            f.updated_at desc nulls last
   limit 1;
  if fs.id is not null then matched_by := 'exact_term'; end if;

  /* STEP 1b — the structure was saved with the DEFAULT label 'Current Term'.
     That label means "the term that is current" — but only the RESOLVED current
     term. It must never match a historical period (that was the V12.67 phantom
     arrears bug), and it must always match the resolved one (otherwise a school
     that never renamed the label sees a ₦0 bill). */
  if fs.id is null then
    select * into fs from public.class_fee_structure f
     where f.active is not false
       and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')))
       and lower(btrim(coalesce(f.term,''))) = 'current term'
       and (coalesce(f.session,'') = '' or coalesce(t_session,'') = '' or f.session = t_session)
     order by (lower(coalesce(f.arm,'')) = lower(coalesce(st.arm,''))) desc,
              (coalesce(f.arm,'') = '') desc,
              (lower(coalesce(f.department,'')) = lower(coalesce(st.department,''))) desc,
              (coalesce(f.department,'') = '') desc,
              (coalesce(f.session,'') <> '') desc,
              f.updated_at desc nulls last
     limit 1;
    if fs.id is not null then
      matched_by := 'current_term_label';
      match_note := 'Matched the class structure entered as "Current Term". It applies to '
                 || coalesce(nullif(t_term,''),'(the current term)')||' and never to earlier terms.';
    end if;
  end if;

  /* STEP 2 — this class, this session, any term label. A school that entered
     one structure per class for the current session has billed that class;
     refusing to bill it because the label differs is the ₦0 bug. */
  if fs.id is null and coalesce(t_session,'') <> '' then
    select * into fs from public.class_fee_structure f
     where f.active is not false
       and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')))
       and lower(btrim(coalesce(f.term,'Current Term'))) not in ('current term','')
       and f.session = t_session
     order by (lower(coalesce(f.arm,'')) = lower(coalesce(st.arm,''))) desc,
              (coalesce(f.arm,'') = '') desc,
              coalesce(f.due_date,'1900-01-01') desc,
              f.updated_at desc nulls last
     limit 1;
    if fs.id is not null then
      matched_by := 'session_other_term';
      match_note := 'No structure was entered for "'||coalesce(t_term,'this term')||'" specifically; '
                 || 'the class structure for '||coalesce(fs.session,'')||' ('||coalesce(fs.term,'')||') was used. '
                 || 'Enter a structure for the new term when the fees change.';
    end if;
  end if;

  /* STEP 3 — this class, the most recent structure of any session/term */
  if fs.id is null then
    select * into fs from public.class_fee_structure f
     where f.active is not false
       and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')))
       and lower(btrim(coalesce(f.term,'Current Term'))) not in ('current term','')
     order by coalesce(f.session,'') desc, coalesce(f.due_date,'1900-01-01') desc,
              f.updated_at desc nulls last
     limit 1;
    if fs.id is not null then
      matched_by := 'latest_structure';
      match_note := 'No structure matches the current term; the most recent class structure ('
                 || coalesce(fs.session,'')||' '||coalesce(fs.term,'')||') was used. '
                 || 'Publish a structure for the current term to make this exact.';
    end if;
  end if;

  if fs.id is not null then
    structure_bill := coalesce(nullif(fs.total,0),
                        coalesce(fs.tuition,0)+coalesce(fs.exam_fee,0)+coalesce(fs.development,0)
                        +coalesce(fs.transport,0)+coalesce(fs.boarding,0)+coalesce(fs.other_fee,0)
                        -coalesce(fs.discount,0));
    if coalesce(fs.tuition,0)     <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Tuition','amount',fs.tuition)); end if;
    if coalesce(fs.exam_fee,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Exam / assessment','amount',fs.exam_fee)); end if;
    if coalesce(fs.development,0) <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Development / PTA','amount',fs.development)); end if;
    if coalesce(fs.transport,0)   <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Transport','amount',fs.transport)); end if;
    if coalesce(fs.boarding,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Boarding / hostel','amount',fs.boarding)); end if;
    if coalesce(fs.other_fee,0)   <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Other compulsory','amount',fs.other_fee)); end if;
    if coalesce(fs.discount,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Discount','amount',-fs.discount)); end if;
    match_status := 'structure';
    if coalesce(fs.session,'') = '' and matched_by = 'exact_term' then
      match_note := 'Matched a class fee structure with no session set — it applies to every session.';
    end if;
    /* A structure with no term label means "current term". It is matched to the
       RESOLVED term only, never to historical periods (that was V12.67's bug). */
    if matched_by = 'exact_term' and lower(btrim(coalesce(fs.term,''))) = 'current term' then
      match_note := 'Matched the class structure entered as "Current Term". It applies to '
                 || coalesce(t_term,'the current term')||' and never to earlier terms.';
      matched_by := 'current_term_label';
    end if;
    /* 'Current Term' is a label, not a term name: report the real term too. */
    if matched_by = 'current_term_label' then
      match_note := coalesce(nullif(match_note,''),
        'Matched the class structure entered as "Current Term". It applies to '
        || coalesce(t_term,'the current term')||' and never to earlier terms.');
    end if;
    if coalesce(fs.arm,'') <> '' and lower(coalesce(fs.arm,'')) <> lower(coalesce(st.arm,'')) then
      match_note := 'No fee structure for arm "'||coalesce(st.arm,'—')||'"; the class-wide structure was used.';
    end if;
  else
    /* ---- Distinguish the three ways a bill can be unknown ---- */
    select count(*) into n_struct from public.class_fee_structure f
     where f.active is not false
       and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')));
    if n_struct > 0 then
      match_status := 'no_structure_this_term';
      match_note := 'This class has a fee structure, but none for '||coalesce(t_term,'this term')
                    ||' '||coalesce(t_session,'')||'. The bill is unknown — not zero.';
    elsif n_any > 0 or exists (select 1 from public.class_fee_structure f
                                where f.active is not false) then
      match_status := 'no_structure';
      match_note := 'No fee structure has ever been published for class "'
                    ||coalesce(nullif(st.class,''),'(unset)')||'". Check the spelling of the class on the '
                    ||'student record against the 💳 Class Fee Structure page, then publish the fees.';
    else
      match_status := 'no_structures_at_all';
      match_note := 'No class fee structure exists on this platform yet. Open 💳 Class Fee Structure '
                    ||'and enter the fees for each class — every dashboard then fills itself in.';
    end if;
  end if;

  /* ---- scholarships / bursaries ---- */
  begin
    for a in select mr.title, mr.amount from public.module_records mr
              where mr.module = 'financial_aid'
                and coalesce(mr.status,'applied') in ('approved','renewed')
                and coalesce(mr.amount,0) > 0
                and ( mr.data->>'student' = st.id::text
                   or lower(coalesce(mr.data->>'student','')) = lower(coalesce(st.full_name,''))
                   or mr.data->>'student_id' = st.id::text )
    loop
      aid_total := aid_total + a.amount;
      aid_rows := aid_rows || jsonb_build_array(jsonb_build_object('scheme', coalesce(a.title,'Scholarship/Aid'), 'amount', a.amount));
      breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','🎓 '||coalesce(a.title,'Scholarship/Aid'),'amount',-a.amount));
    end loop;
  exception when undefined_table or undefined_column then null;
  end;

  eff_bill := greatest(coalesce(structure_bill,0) - aid_total, 0);

  /* ---- a deliberate bursar override always wins, and says so ---- */
  begin
    select fee_total into ovr from public.fee_payments
     where student_id = p_student and coalesce(total_overridden,false) = true and coalesce(fee_total,0) > 0
       and (coalesce(t_term,'') = '' or term = t_term)
       and (coalesce(t_session,'') = '' or session = t_session)
     order by created_at desc nulls last limit 1;
    if ovr is not null then
      overridden := true;
      eff_bill := coalesce(ovr,0);
      breakdown := jsonb_build_array(jsonb_build_object('item','✏️ Personal total set by the bursar (override)','amount',eff_bill));
      match_status := 'override';
      matched_by := 'override';
      match_note := 'The bursar set a personal total for this learner; it replaces the class structure.';
    end if;
  exception when undefined_column then null;
  end;

  return jsonb_build_object('ok',true,
    'student_id', st.id, 'class', st.class, 'arm', st.arm, 'department', st.department,
    'term', t_term, 'session', t_session,
    'resolved_by', tr->>'resolved_by',
    'bill', eff_bill,                     -- what the learner is actually billed
    'structure_bill', structure_bill,     -- before aid
    'aid', case when overridden then 0 else aid_total end,
    'aid_rows', case when overridden then '[]'::jsonb else aid_rows end,
    'breakdown', breakdown,
    'override', overridden,
    'match_status', match_status,         -- invoice | structure | no_structure | no_structure_this_term | no_structures_at_all | override
    'matched_by', matched_by,             -- invoice | exact_term | current_term_label | session_other_term | latest_structure | override | ''
    'matched', (match_status in ('structure','override','invoice')),
    'bill_known', match_status not in ('no_structure','no_structure_this_term','no_structures_at_all'),
    'match_note', match_note,
    'currency', coalesce(fs.currency,'₦'),
    'due_date', fs.due_date, 'note', coalesce(fs.note,''),
    'working', case
      when overridden then 'Bursar override: the personal total replaces the class structure.'
      when match_status in ('structure','invoice') then
        'Class structure for '||coalesce(st.class,'')||
        case when coalesce(fs.arm,'') <> '' then ' ('||fs.arm||')' else '' end ||
        ' = '||to_char(structure_bill,'FM999,999,990.00')||
        case when aid_total > 0 then ' − aid '||to_char(aid_total,'FM999,999,990.00') else '' end ||
        ' = '||to_char(eff_bill,'FM999,999,990.00')||
        ' · term '||coalesce(t_term,'—')||' (resolved by '||coalesce(tr->>'resolved_by','—')||')'
      else coalesce(match_note,'Bill unknown.') end);
end $$;
revoke all on function public.sc_fee_bill_v2(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_bill_v2(uuid,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- B4. would this class be billed, and by what?
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_structure_for(p_class text,
                                                       p_term text default null,
                                                       p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare tr jsonb; t_term text; t_session text; fs record; n int := 0; n_all int := 0;
begin
  tr := public.sc_term_resolve(p_term, p_session);
  t_term := coalesce(tr->>'term',''); t_session := coalesce(tr->>'session','');

  select * into fs from public.class_fee_structure f
   where f.active is not false
     and lower(btrim(f.class)) = lower(btrim(coalesce(p_class,'')))
   order by
     /* exact term+session first, then same session, then newest */
     (lower(btrim(coalesce(f.term,'Current Term'))) = lower(btrim(t_term))) desc,
     (coalesce(f.session,'') = coalesce(t_session,'')) desc,
     (coalesce(f.session,'') = '') desc,
     coalesce(f.due_date,'1900-01-01') desc,
     f.updated_at desc nulls last
   limit 1;

  select count(*) into n from public.class_fee_structure f
   where f.active is not false and lower(btrim(f.class)) = lower(btrim(coalesce(p_class,'')));
  select count(*) into n_all from public.class_fee_structure;

  if fs.id is null then
    return jsonb_build_object('ok',true,'class',coalesce(p_class,''),'term',t_term,'session',t_session,
      'resolved_by',tr->>'resolved_by','billable',false,'amount',0,'rows_for_class',n,'rows_total',n_all,
      'message', case when n_all = 0
        then 'No class fee structure exists yet. Open 💳 Class Fee Structure and enter the fees.'
        else 'No active fee structure for class "'||coalesce(p_class,'')||'".' end);
  end if;

  return jsonb_build_object('ok',true,'class',coalesce(p_class,''),'term',t_term,'session',t_session,
    'resolved_by',tr->>'resolved_by','billable',true,
    'amount', coalesce(nullif(fs.total,0),
                coalesce(fs.tuition,0)+coalesce(fs.exam_fee,0)+coalesce(fs.development,0)
                +coalesce(fs.transport,0)+coalesce(fs.boarding,0)+coalesce(fs.other_fee,0)
                -coalesce(fs.discount,0)),
    'structure_term',coalesce(fs.term,''),'structure_session',coalesce(fs.session,''),
    'rows_for_class',n,'rows_total',n_all,
    'exact_match', (lower(btrim(coalesce(fs.term,'Current Term'))) = lower(btrim(t_term))
                and (coalesce(fs.session,'') = '' or coalesce(fs.session,'') = coalesce(t_session,''))),
    'message','');
end $$;
revoke all on function public.sc_fee_structure_for(text,text,text) from public, anon;
grant execute on function public.sc_fee_structure_for(text,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- B5. structure doctor — before a parent sees a wrong number
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_structure_doctor()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare me uuid := auth.uid(); tr jsonb; t_term text; t_session text;
        f jsonb := '[]'::jsonb; r record; c_zero int := 0; c_conf int := 0;
        c_missing jsonb := '[]'::jsonb; c_none int := 0; c_classes int := 0;
begin
  if me is null or not coalesce(public.is_staff(me),false) then
    return jsonb_build_object('ok',false,'error','Only staff can inspect fee structures.');
  end if;
  tr := public.sc_term_resolve(null,null);
  t_term := coalesce(tr->>'term',''); t_session := coalesce(tr->>'session','');

  select count(*) into c_none from public.class_fee_structure;
  if c_none = 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','no_structures','severity','error',
      'count',0,'student','(fee structure)',
      'issue','No class fee structure has been entered at all, so every learner''s bill is unknown and shows 0.',
      'fix','Open 💳 Class Fee Structure and enter the fees for each class. Every dashboard and receipt fills in immediately.'));
  end if;

  /* every class that has students but no billable structure */
  for r in select distinct class from public.students
            where coalesce(btrim(class),'') <> ''
              and coalesce(status,'active') not in ('inactive','left','withdrawn','graduated','deleted')
  loop
    c_classes := c_classes + 1;
    if not exists (select 1 from public.class_fee_structure x
                    where x.active is not false and lower(btrim(x.class)) = lower(btrim(r.class))) then
      c_missing := c_missing || jsonb_build_array(r.class);
    end if;
  end loop;
  if jsonb_array_length(c_missing) > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','class_without_fee','severity','warning',
      'count',jsonb_array_length(c_missing),'student','(fee structure)',
      'classes', c_missing,
      'issue', jsonb_array_length(c_missing)||' class(es) have learners but no fee structure, so those learners show a 0 bill.',
      'fix','Enter a fee structure for each class listed. Watch for spelling differences between the student record and the structure row.'));
  end if;

  select count(*) into c_zero from public.class_fee_structure
   where active is not false and coalesce(total,0) = 0
     and coalesce(tuition,0)+coalesce(exam_fee,0)+coalesce(development,0)
        +coalesce(transport,0)+coalesce(boarding,0)+coalesce(other_fee,0) = 0;
  if c_zero > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','zero_structure','severity','warning',
      'count',c_zero,'student','(fee structure)',
      'issue', c_zero||' structure row(s) bill nothing, so those learners look fully paid.',
      'fix','Enter the amounts, or deactivate the row.'));
  end if;

  select count(*) into c_conf from (
    select lower(btrim(class)), coalesce(session,''), coalesce(term,'') from public.class_fee_structure
     where active is not false group by 1,2,3 having count(*) > 1) x;
  if c_conf > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','structure_conflict','severity','warning',
      'count',c_conf,'student','(fee structure)',
      'issue', c_conf||' class/term combination(s) have more than one active structure.',
      'fix','Deactivate the rows you no longer use.'));
  end if;

  return jsonb_build_object('ok',true,'term',t_term,'session',t_session,
    'resolved_by',tr->>'resolved_by','classes_with_students',c_classes,
    'counts', jsonb_build_object('structures',c_none,'zero',c_zero,'conflicts',c_conf,
                                 'classes_without_fee',jsonb_array_length(c_missing)),
    'findings', f);
end $$;
revoke all on function public.sc_fee_structure_doctor() from public, anon;
grant execute on function public.sc_fee_structure_doctor() to authenticated;

-- ---------------------------------------------------------------------
-- B7. THE REMAINING CALLERS
--
--  Five older functions each resolved the term themselves with the same
--  fragile probe. They are the reason a receipt could be scored against a
--  different term from the one the bill was computed for, and they would
--  keep returning 0 even after B3 if left alone. Each is re-issued here to
--  take its term from `sc_term_resolve`, which is now the single source.
--
--  They are thin: same signature, same return shape, one resolver call.
-- ---------------------------------------------------------------------

create or replace function public.sc_fee_bill_for(p_student uuid,
                                                  p_term text default null,
                                                  p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  /* V12.68 — delegates to the one billing engine and the one resolver. */
  return public.sc_fee_bill_v2(p_student, p_term, p_session);
end $$;
revoke all on function public.sc_fee_bill_for(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_bill_for(uuid,text,text) to authenticated;

create or replace function public.sc_student_fee_state(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare l jsonb; b jsonb;
begin
  /* V12.68 — one ledger, resolved term. Previously this probed is_current on
     its own, which is why the family card and the dashboard could disagree. */
  l := public.sc_fee_ledger_for(p_student, null, null);
  if coalesce((l->>'ok')::boolean,false) = false then return l; end if;
  /* V12.68 B9 — carry the PROVENANCE of the figure to the screen. A screen that
     says ₦0 must be able to say why, and a screen showing a bill must be able to
     say which price list it came from. sc_fee_bill_v2 already reports both. */
  b := public.sc_fee_bill_v2(p_student, l->>'term', l->>'session');
  return l || jsonb_build_object(
    'matched', true,
    'term',    l->>'term',
    'session', l->>'session',
    'student_name', l->>'student',
    'student_id_ref', l->>'admission_no',
    'match_status', coalesce(b->>'match_status',''),
    'matched_by',   coalesce(b->>'matched_by',''),
    'resolved_by',  coalesce(b->>'resolved_by',''),
    'match_note',   coalesce(nullif(l->>'match_note',''), b->>'match_note',''));
end $$;
revoke all on function public.sc_student_fee_state(uuid) from public, anon;
grant execute on function public.sc_student_fee_state(uuid) to authenticated;

create or replace function public.sc_fee_overview(p_class text default null,
                                                  p_term text default null,
                                                  p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare tr jsonb; t_term text; t_session text; rows_ jsonb;
        billed numeric := 0; collected numeric := 0; outstanding numeric := 0;
        arrears numeric := 0; n int := 0; debtors int := 0; paid_n int := 0; partial int := 0;
        r record; b record;
begin
  tr := public.sc_term_resolve(p_term, p_session);
  t_term := coalesce(tr->>'term',''); t_session := coalesce(tr->>'session','');
  rows_ := public.sc_fee_page_rows(p_class, t_term, t_session);
  for r in select value v from jsonb_array_elements(rows_) loop
    n := n + 1;
    billed      := billed      + coalesce((r.v->>'bill')::numeric,0);
    collected   := collected   + coalesce((r.v->>'paid')::numeric,0);
    outstanding := outstanding + coalesce((r.v->>'total_due')::numeric,0);
    arrears     := arrears     + coalesce((r.v->>'arrears')::numeric,0);
    if coalesce((r.v->>'total_due')::numeric,0) <= 0.005 then paid_n := paid_n + 1;
    elsif coalesce((r.v->>'paid')::numeric,0) <= 0.005 then debtors := debtors + 1;
    else partial := partial + 1; end if;
  end loop;
  return jsonb_build_object('ok',true,'term',t_term,'session',t_session,
    'resolved_by',tr->>'resolved_by','students',n,
    'billed',billed,'collected',collected,'outstanding',outstanding,'arrears',arrears,
    'fully_paid',paid_n,'debtors',debtors,'partial',partial,
    'collection_rate', case when billed > 0 then round(collected*100.0/billed,1) else 0 end,
    'rows',rows_);
end $$;
revoke all on function public.sc_fee_overview(text,text,text) from public, anon;
grant execute on function public.sc_fee_overview(text,text,text) to authenticated;

create or replace function public.sc_fee_sync_snapshots(p_student uuid,
                                                        p_term text default null,
                                                        p_session text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare tr jsonb; t_term text; t_session text; s record; n int := 0; res jsonb;
begin
  tr := public.sc_term_resolve(p_term, p_session);
  t_term := coalesce(tr->>'term',''); t_session := coalesce(tr->>'session','');
  for s in select id from public.students
            where (p_student is null or id = p_student)
  loop
    res := public.sc_recompute_fee_rows(s.id, t_term, t_session);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok',true,'term',t_term,'session',t_session,
    'resolved_by',tr->>'resolved_by','students',n);
end $$;
revoke all on function public.sc_fee_sync_snapshots(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_sync_snapshots(uuid,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- B8. REPAIR: pg_cron setup block could never install the extension
--
--  The keep-alive block does `create extension if not exists pg_cron;`
--  directly inside a PL/pgSQL body. Postgres does not allow that — extension
--  DDL inside a function/DO block must go through EXECUTE. The statement was
--  wrapped in an exception handler, so it failed silently on every install and
--  the heartbeat was never scheduled; the only symptom was the notice.
--
--  It also broke any tool that neutralises CREATE EXTENSION when loading the
--  file into a test database, because the rewrite produced `select 1;` inside a
--  PL/pgSQL block where a bare SELECT has no destination.
--
--  Re-issued with EXECUTE so it works, and so the statement is portable.
-- ---------------------------------------------------------------------
do $cronsetup_v1268$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      execute 'create extension if not exists pg_cron';
      perform cron.unschedule(jobid) from cron.job where jobname = 'sc-keep-alive';
      perform cron.schedule('sc-keep-alive', '23 5 */2 * *',
                            $job$select public.sc_keep_alive('pg_cron')$job$);
      raise notice 'sc-keep-alive pg_cron job scheduled (every 2 days at 05:23 UTC).';
    exception when others then
      raise notice 'pg_cron keep-alive not scheduled (%). External heartbeats still protect the project.', sqlerrm;
    end;
  else
    raise notice 'pg_cron not available; relying on site-visit + GitHub Actions + UptimeRobot heartbeats.';
  end if;
end
$cronsetup_v1268$;


-- =====================================================================
-- B9. WHAT THE SCREEN IS TOLD — the provenance reaches the page
--
--  The Round-9 report was "Total fees this term shows ₦0". The arithmetic was
--  fixed in B3, but a page cannot explain a number it was never given the
--  source of. Three things are needed on screen and were missing:
--
--    1. WHY a bill is ₦0 — no structure at all, none for this term, or a
--       structure that genuinely bills nothing. Each needs a different action
--       from the bursar, so each must read differently.
--    2. WHERE a bill came from — exact term, the "Current Term" label, another
--       term of the same session, the latest structure, or the invoice.
--    3. THAT the term itself was resolved — a page that shows "First Term
--       2026/2027" must know whether the calendar said so or a fallback did.
--
--  `sc_fee_explain` returns exactly those three, as one call, for one learner.
--  The dashboard, the Fees page and the family card all read it. Nothing about
--  the money changes here: this is the same engine, quoted.
-- =====================================================================
create or replace function public.sc_fee_explain(p_student uuid,
                                                 p_term text default null,
                                                 p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare st record; tr jsonb; b jsonb; led jsonb;
        status_ text; headline text; fix text; tone text;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;

  tr  := public.sc_term_resolve(p_term, p_session);
  b   := public.sc_fee_bill_v2(p_student, p_term, p_session);
  led := public.sc_fee_ledger_for(p_student, tr->>'term', tr->>'session');
  status_ := coalesce(b->>'match_status','');
  /* `match_status` says whether a bill exists at all; `matched_by` says WHICH
     rung of the ladder produced it. A structure bill is status 'structure' with
     matched_by one of exact_term / current_term_label / session_other_term /
     latest_structure — so the wording below is driven by the rung whenever a
     bill is known. */
  if status_ = 'structure' then
    status_ := coalesce(nullif(b->>'matched_by',''), 'exact_term');
  end if;

  /* ---- one sentence per status: what happened, and what to do about it ---- */
  if status_ = 'invoice' then
    headline := 'Billed from the invoice raised for this term.';
    fix := 'Nothing to do — an invoice is the authoritative bill.';
    tone := 'ok';
  elsif status_ = 'exact_term' then
    headline := 'Billed from the class fee structure published for '||coalesce(tr->>'term','this term')||'.';
    fix := 'Nothing to do — this is the price list for this exact term.';
    tone := 'ok';
  elsif status_ = 'current_term_label' then
    headline := 'Billed from the class fee structure saved as "Current Term", which applies to '
                ||coalesce(tr->>'term','the resolved term')||'.';
    fix := 'Nothing to do. To make it explicit, save a structure naming the term instead of "Current Term".';
    tone := 'ok';
  elsif status_ = 'session_other_term' then
    headline := 'No structure is published for '||coalesce(tr->>'term','this term')
                ||'; the fee for another term of the same session was used.';
    fix := 'Publish the class fee for '||coalesce(tr->>'term','this term')||' so the bill is exact.';
    tone := 'warn';
  elsif status_ = 'latest_structure' then
    headline := 'No structure matches this term or this session; the most recent class fee structure was used.';
    fix := 'Publish the class fee for '||coalesce(tr->>'term','this term')||' '||coalesce(tr->>'session','')||'.';
    tone := 'warn';
  elsif status_ = 'override' then
    headline := 'The bursar set this learner''s own total.';
    fix := 'Nothing to do — a personal total deliberately replaces the class fee.';
    tone := 'ok';
  elsif status_ = 'no_structure_this_term' then
    headline := 'This class HAS a fee structure, but none for '||coalesce(tr->>'term','this term')||' '
                ||coalesce(tr->>'session','')||'.';
    fix := 'Open 💳 Class Fee Structure and publish the fee for '||coalesce(tr->>'term','this term')
           ||' '||coalesce(tr->>'session','')||'. The bill is unknown, not zero.';
    tone := 'bad';
  elsif status_ = 'no_structure' then
    headline := 'No fee structure has ever been published for class "'
                ||coalesce(nullif(st.class,''),'(unset)')||'".';
    fix := 'Check the spelling of the class on the student record against 💳 Class Fee Structure, then publish it.';
    tone := 'bad';
  elsif status_ = 'no_structures_at_all' then
    headline := 'No class fee structure exists on this platform yet.';
    fix := 'Open 💳 Class Fee Structure and enter the fees for each class once. Every dashboard then fills itself in — '
           ||'no student is edited by hand.';
    tone := 'bad';
  else
    headline := 'The bill could not be established.';
    fix := 'Publish the class fee structure, or raise an invoice for this learner.';
    tone := 'bad';
  end if;

  return jsonb_build_object('ok', true,
    'student_id', st.id, 'student', st.full_name, 'class', st.class,
    'term', tr->>'term', 'session', tr->>'session',
    'rung', status_,
    'term_resolved_by', coalesce(tr->>'resolved_by',''),
    'term_is_current_flag', case when tr->>'resolved_by' = 'is_current' then true else false end,
    'bill', coalesce((b->>'bill')::numeric,0),
    'bill_known', coalesce((b->>'bill_known')::boolean,false),
    'matched_by', coalesce(b->>'matched_by',''),
    'match_status', coalesce(b->>'match_status',''),
    'headline', headline,
    'fix', fix,
    'tone', tone,
    'match_note', coalesce(b->>'match_note',''),
    'structure_bill', coalesce((b->>'structure_bill')::numeric,0),
    'aid', coalesce((led->>'aid')::numeric,0),
    'paid', coalesce((led->>'paid')::numeric,0),
    'arrears', coalesce((led->>'arrears')::numeric,0),
    'has_arrears', coalesce((led->>'has_arrears')::boolean,false),
    'total_due', coalesce((led->>'total_due')::numeric,0),
    'invoice_raised', coalesce((led->>'invoiced')::boolean,false),
    'currency', public.sc_currency());
end $$;
revoke all on function public.sc_fee_explain(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_explain(uuid,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- B10. SCHOOL-WIDE: how many learners are billed, and from where
--
--  A bursar must be able to see, without opening 400 records, whether the
--  ₦0s are a data-entry gap or a genuine nil bill. This is the audit.
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_bill_audit(p_class text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare me uuid := auth.uid(); tr jsonb; r record; b jsonb;
        n_total int := 0; n_known int := 0; buckets jsonb := '{}'::jsonb; samples jsonb := '[]'::jsonb;
begin
  if me is null or not (coalesce(public.is_staff(me),false) or coalesce(public.is_admin(me),false)) then
    return jsonb_build_object('ok',false,'error','Staff only.');
  end if;
  tr := public.sc_term_resolve(null, null);
  for r in select * from public.students st
            where coalesce(st.status,'active') in ('active','approved')
              and (coalesce(btrim(p_class),'') = '' or lower(btrim(st.class)) = lower(btrim(p_class)))
            order by st.class, st.full_name
  loop
    n_total := n_total + 1;
    b := public.sc_fee_bill_v2(r.id, tr->>'term', tr->>'session');
    if coalesce((b->>'bill_known')::boolean,false) then n_known := n_known + 1; end if;
    buckets := jsonb_set(buckets,
      array[coalesce(b->>'match_status','unknown')],
      to_jsonb(coalesce((buckets->>coalesce(b->>'match_status','unknown'))::int,0) + 1));
    if coalesce((b->>'bill_known')::boolean,false) is not true and jsonb_array_length(samples) < 25 then
      samples := samples || jsonb_build_array(jsonb_build_object(
        'student', r.full_name, 'class', r.class, 'admission_no', r.admission_no,
        'match_status', b->>'match_status', 'note', b->>'match_note'));
    end if;
  end loop;
  return jsonb_build_object('ok',true,
    'term', tr->>'term', 'session', tr->>'session', 'resolved_by', tr->>'resolved_by',
    'students', n_total, 'bill_known', n_known, 'bill_unknown', n_total - n_known,
    'by_status', buckets, 'samples', samples);
end $$;
revoke all on function public.sc_fee_bill_audit(text) from public, anon;
grant execute on function public.sc_fee_bill_audit(text) to authenticated;

-- ---------------------------------------------------------------------
-- B11. the truth sheet carries the provenance too
--
--  The printable statement is the document a parent takes away. It must say
--  "not published" and why, never print a confident ₦0 for a bill nobody has
--  set. Re-issued here with the same body plus `provenance` and `bill_known`
--  on the headline; every figure is still the ledger's.
-- ---------------------------------------------------------------------
create or replace function public.sc_fee_truth_sheet(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare me uuid := auth.uid(); st record; led jsonb; ex jsonb;
        rows jsonb := '[]'::jsonb; r record;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  if me is null or not (coalesce(public.is_staff(me),false) or coalesce(public.is_admin(me),false)
                        or coalesce(st.user_id = me,false) or coalesce(public.is_parent_of(me, st.id),false)) then
    return jsonb_build_object('ok',false,'error','Not authorised for this student.');
  end if;
  led := public.sc_fee_ledger_for(p_student, null, null);
  ex  := public.sc_fee_explain(p_student, led->>'term', led->>'session');

  /* every receipt, with the running balance after it */
  for r in select fp.payment_date, fp.created_at, fp.amount_paid, fp.method, fp.reference,
                  fp.term, fp.session, fp.received_by_name
             from public.fee_payments fp
            where fp.student_id = p_student
            order by coalesce(fp.payment_date, fp.created_at::date), fp.created_at
  loop
    rows := rows || jsonb_build_array(jsonb_build_object(
      'date', coalesce(r.payment_date::text, r.created_at::text),
      'amount', r.amount_paid, 'method', coalesce(r.method,''),
      'reference', coalesce(r.reference,''),
      'term', coalesce(r.term,''), 'session', coalesce(r.session,''),
      'received_by', coalesce(r.received_by_name,''),
      'for_this_term', (coalesce(r.term,'') = coalesce(led->>'term','')
                        and coalesce(r.session,'') = coalesce(led->>'session',''))));
  end loop;

  return jsonb_build_object('ok',true,
    'student', jsonb_build_object('id',st.id,'name',st.full_name,'admission_no',st.admission_no,
      'class',st.class,'arm',st.arm,'department',st.department),
    'period', jsonb_build_object('term',led->>'term','session',led->>'session',
                                 'resolved_by', coalesce(led->>'term_resolved_by', ex->>'term_resolved_by','')),
    'headline', jsonb_build_object(
      'net_bill', led->'bill', 'aid', led->'aid', 'paid_this_term', led->'paid',
      'balance_this_term', led->'balance', 'arrears', led->'arrears',
      'total_outstanding', led->'total_due', 'status', led->>'status',
      'bill_known', coalesce((ex->>'bill_known')::boolean, true),
      'matched_by', coalesce(ex->>'matched_by','')),
    'provenance', ex,
    'arithmetic', led->'explain',
    'arrears_detail', led->'arrears_rows',
    'bill_breakdown', led->'breakdown',
    'checks', led->'checks',
    'receipts', rows,
    'generated_at', now());
end $$;
revoke all on function public.sc_fee_truth_sheet(uuid) from public, anon;
grant execute on function public.sc_fee_truth_sheet(uuid) to authenticated;

-- =====================================================================
-- B12. THE CURRENCY SYMBOL MUST NEVER BREAK THE FEE ENGINE
--
--  Reported: every learner's 💰 School Fees card said
--      Technical detail: column "currency" does not exist
--
--  Three functions read the symbol with `select currency from school_settings
--  limit 1`. If that column is absent the whole RPC aborts — so a missing
--  *display* character takes down the entire fee statement. A currency symbol
--  is decoration; a bill is money. Decoration must never be able to fail.
--
--  Two independent defects fixed here:
--
--    1. THE READ WAS UNGUARDED. The lookup is now ONE helper, `sc_currency()`,
--       which resolves the symbol from a jsonb row (`to_jsonb(school_settings)`)
--       so it cannot depend on a column existing at all, and falls back ₦.
--       Every fee function calls it. No fee function names the column again.
--
--    2. THE COLUMN COULD NOT COME BACK. `create table if not exists` does
--       nothing when the table already exists, so on a database whose
--       school_settings predates `currency`, re-running the complete schema did
--       NOT restore it — the school stayed broken no matter how many times they
--       ran the file. The column is now added explicitly, with `if not exists`,
--       so the schema is genuinely self-healing. No data is touched: only a
--       missing column is added, and an existing one (and its value) is left
--       exactly as it is.
-- =====================================================================

-- 1. heal the table itself (additive, idempotent, no data touched)
alter table public.school_settings add column if not exists currency text default '₦';
update public.school_settings
   set currency = '₦'
 where id = 1 and nullif(btrim(coalesce(currency,'')), '') is null;

-- 2. one guarded reader. jsonb cannot fail on a missing key.
create or replace function public.sc_currency()
returns text language plpgsql stable security definer set search_path=public as $$
declare sym text;
begin
  begin
    select nullif(btrim(coalesce(to_jsonb(ss)->>'currency','')), '') into sym
      from public.school_settings ss limit 1;
  exception when others then
    /* the table itself may be missing on an odd install — a symbol is never
       worth failing a financial statement over */
    sym := null;
  end;
  return coalesce(sym, '₦');
end $$;
revoke all on function public.sc_currency() from public, anon;
grant execute on function public.sc_currency() to authenticated, anon;

comment on function public.sc_currency() is
  'V12.68 — the one place the fee engine reads the currency symbol. Never fails: returns ₦ when the setting (or the table, or the column) is absent.';
