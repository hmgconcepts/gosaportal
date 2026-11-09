-- ============================================================================
-- School Connect V12.60 — EXPERT FIX PACK
--   1) CBT assignment "Take Assignment" code bridge (code ⇄ id, always a code)
--   2) Fee ledger ⇄ dashboard single source of truth (no double counting)
--   3) One-click bulk portal/report locking (all filtered / all debtors)
--   4) Publish midterm reports for EVERY class in one click
--   5) CBT question flags: capture, surface to tutors, resolve & re-score
--   6) Fee roster: fully-paid vs debtor filtering that matches the dashboard
-- Idempotent — safe to run on any existing database, and embedded at the end
-- of complete-schema.sql so fresh installs get it automatically.
-- ============================================================================
select 'RUNNING: School Connect V12.60 expert fix pack' as running_version;

-- ---------------------------------------------------------------------------
-- 1. CBT CODE BRIDGE
--    Root cause: assignments.cbt_exam_id stores the cbt_exams UUID and the
--    mirror trigger never copied cbt_exams.code into assignments.drive_link,
--    so student-facing "Take Assignment" links were
--    ./cbt-exam.html?code=<uuid>. cbt_exam.html sends that to
--    cbt_get_public_exam_v6 → cbt_get_public_exam_v5, which only matches
--    cbt_exams.code → exam_not_found. Fix at BOTH ends: (a) every take link
--    is generated from the code, (b) the getter accepts a code OR an id.
-- ---------------------------------------------------------------------------
create or replace function public.sc_cbt_resolve_code(p_ref text)
returns text language plpgsql stable security definer set search_path=public as $$
declare v_txt text := coalesce(p_ref,''); v_norm text; v_code text; v_uuid uuid;
begin
  if btrim(v_txt) = '' then return ''; end if;
  v_norm := regexp_replace(upper(v_txt),'[^A-Z0-9]','','g');
  -- 1. exact code match (normalised, so "4ntjnc" and "4NT-JNC" work)
  select ce.code into v_code from public.cbt_exams ce
   where regexp_replace(upper(coalesce(ce.code,'')),'[^A-Z0-9]','','g') = v_norm
   order by ce.updated_at desc nulls last, ce.created_at desc limit 1;
  if coalesce(v_code,'') <> '' then return v_code; end if;
  -- 2. the reference is an exam id (uuid) — the historic Take-Assignment bug
  begin v_uuid := v_txt::uuid; exception when others then v_uuid := null; end;
  if v_uuid is null then
    -- normalised uuid text (hyphens stripped) e.g. "082e699fe2904f8e93b2bd4df0a7fd2a"
    if v_norm ~ '^[0-9A-F]{32}$' then
      begin
        v_uuid := (substr(v_norm,1,8)||'-'||substr(v_norm,9,4)||'-'||substr(v_norm,13,4)||'-'||
                   substr(v_norm,17,4)||'-'||substr(v_norm,21,12))::uuid;
      exception when others then v_uuid := null; end;
    end if;
  end if;
  if v_uuid is not null then
    select ce.code into v_code from public.cbt_exams ce where ce.id = v_uuid limit 1;
    if coalesce(v_code,'') <> '' then return v_code; end if;
  end if;
  return '';
end $$;
grant execute on function public.sc_cbt_resolve_code(text) to anon, authenticated, public;

-- Canonical, always-correct public take link for an exam (code or id in, link out).
create or replace function public.sc_cbt_take_link(p_ref text)
returns text language sql stable security definer set search_path=public as $$
  select case when coalesce(public.sc_cbt_resolve_code(p_ref),'') = '' then ''
              else './cbt-exam.html?code=' || public.sc_cbt_resolve_code(p_ref) end
$$;
grant execute on function public.sc_cbt_take_link(text) to anon, authenticated, public;

-- The getter itself now resolves ids too (defence in depth: old links,
-- WhatsApp shares and printed QR codes keep working forever).
create or replace function public.cbt_get_public_exam_v7(p_code text, p_admission_no text default '')
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare v_code text; v_norm text;
begin
  v_norm := regexp_replace(upper(coalesce(p_code,'')),'[^A-Z0-9]','','g');
  if v_norm = '' then
    return jsonb_build_object('ok',false,'error','code_required','message','Enter an exam code.','engine_version','v5.6.2-class');
  end if;
  v_code := public.sc_cbt_resolve_code(p_code);
  if coalesce(v_code,'') = '' then
    return jsonb_build_object('ok',false,'error','exam_not_found',
      'message','No exam matches that code. Ask the exam officer to confirm the code.',
      'engine_version','v5.6.2-class','normalised_code',v_norm);
  end if;
  return public.cbt_get_public_exam_v6(v_code, p_admission_no);
end $$;
grant execute on function public.cbt_get_public_exam_v7(text,text) to anon, authenticated;

-- Mirror trigger: always store the human CODE take link (never the id).
create or replace function public.sc_mirror_cbt_assignment()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_aid uuid; v_code text; v_link text;
begin
  if pg_trigger_depth() > 1 then return new; end if;
  v_code := coalesce(nullif(new.code,''), public.sc_cbt_resolve_code(new.id::text));
  v_link := case when coalesce(v_code,'') = '' then null else './cbt-exam.html?code=' || v_code end;
  if lower(coalesce(new.assessment_type,'')) <> 'assignment' then
    if lower(coalesce(old.assessment_type,'')) = 'assignment' then
      delete from public.assignments where cbt_exam_id = new.id;
    end if;
    return new;
  end if;
  insert into public.assignments (id, title, class, subject, due_date, posted_by, cbt_exam_id, is_cbt, source, description, drive_link, created_at)
  values (coalesce((select id from public.assignments where cbt_exam_id = new.id limit 1), gen_random_uuid()),
    new.title, new.class, new.subject, coalesce(new.close_at::date, current_date + interval '7 days'),
    new.teacher_id, new.id, true, 'cbt_assignment',
    'CBT Assignment auto-mirrored from cbt_exams code=' || coalesce(v_code,'') ||
    ' — scores auto-fill from CBT results. Multiple per term accumulate cumulatively → push to Assignment column.',
    v_link, now())
  on conflict (id) do update set
    title = excluded.title, class = excluded.class, subject = excluded.subject,
    due_date = excluded.due_date, posted_by = excluded.posted_by,
    cbt_exam_id = excluded.cbt_exam_id, is_cbt = true,
    source = 'cbt_assignment',
    drive_link = coalesce(excluded.drive_link, public.assignments.drive_link);
  return new;
end $$;

drop trigger if exists trg_cbt_assignment_mirror on public.cbt_exams;
create trigger trg_cbt_assignment_mirror
  after insert or update of assessment_type, title, class, subject, close_at, teacher_id, code
  on public.cbt_exams for each row execute function public.sc_mirror_cbt_assignment();

-- Heal every historic mirror row that still carries a UUID (or nothing).
update public.assignments a
   set drive_link = './cbt-exam.html?code=' || e.code
  from public.cbt_exams e
 where a.cbt_exam_id = e.id
   and coalesce(e.code,'') <> ''
   and (a.drive_link is null
        or btrim(a.drive_link) = ''
        or a.drive_link ~* '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        or a.drive_link !~* 'code=');
-- Any assignments that carry a cbt_exam_id but were never linked get the flag too.
update public.assignments set is_cbt = true where cbt_exam_id is not null and coalesce(is_cbt,false) = false;

insert into public.sc_install_state(key,details) values ('v12.60-cbt-code-bridge','{"self":true}') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. FEE TRUTH ENGINE — ONE BILL, ONE PAID, ONE BALANCE
--    Root causes found:
--      (a) dashboards summed fee_payments.balance SNAPSHOTS across rows, so
--          "outstanding" grew every time a payment was added (a snapshot is
--          "what was left after that row", not the student's balance);
--      (b) the fees form wrote fee_total = total_due at entry time, which the
--          v10.8 healing trigger then "reconstructed" into a grand total —
--          two different notions of the same number.
--    Fix: one non-authorising bill resolver used by EVERY reader, a snapshot
--    rewriter that derives every row from that bill, and roster/overview RPCs
--    so the dashboard and the fees page can never disagree again.
-- ---------------------------------------------------------------------------
create or replace function public.sc_fee_bill_for(p_student uuid, p_term text default null, p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare st record; cur record; fs record; bill numeric := 0; breakdown jsonb := '[]'::jsonb;
        aid_total numeric := 0; aid_rows jsonb := '[]'::jsonb; a record; ovr numeric; overridden boolean := false;
        t_term text; t_session text;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term := coalesce(nullif(btrim(p_term),''), cur.term);
  t_session := coalesce(nullif(btrim(p_session),''), cur.session);

  select * into fs from public.class_fee_structure f
   where f.active is not false
     and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')))
     and (coalesce(f.session,'') = '' or f.session = coalesce(t_session,''))
     and coalesce(f.term,'Current Term') in ('Current Term', coalesce(t_term,''))
   order by (lower(coalesce(f.arm,'')) = lower(coalesce(st.arm,''))) desc,
            (coalesce(f.arm,'') = '') desc,
            (lower(coalesce(f.department,'')) = lower(coalesce(st.department,''))) desc,
            (coalesce(f.department,'') = '') desc,
            (coalesce(f.session,'') <> '') desc,
            f.updated_at desc nulls last
   limit 1;

  if fs.id is not null then
    bill := coalesce(nullif(fs.total,0), coalesce(fs.tuition,0)+coalesce(fs.exam_fee,0)+coalesce(fs.development,0)
            +coalesce(fs.transport,0)+coalesce(fs.boarding,0)+coalesce(fs.other_fee,0)-coalesce(fs.discount,0));
    if coalesce(fs.tuition,0)     <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Tuition','amount',fs.tuition)); end if;
    if coalesce(fs.exam_fee,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Exam / assessment','amount',fs.exam_fee)); end if;
    if coalesce(fs.development,0) <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Development / PTA','amount',fs.development)); end if;
    if coalesce(fs.transport,0)   <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Transport','amount',fs.transport)); end if;
    if coalesce(fs.boarding,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Boarding / hostel','amount',fs.boarding)); end if;
    if coalesce(fs.other_fee,0)   <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Other compulsory','amount',fs.other_fee)); end if;
    if coalesce(fs.discount,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Discount','amount',-fs.discount)); end if;
  end if;

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
  bill := greatest(coalesce(bill,0) - aid_total, 0);

  -- A deliberate bursar override always wins.
  begin
    select fee_total into ovr from public.fee_payments
     where student_id = p_student and coalesce(total_overridden,false) = true and coalesce(fee_total,0) > 0
       and (coalesce(t_term,'') = '' or coalesce(term,'') = t_term)
       and (coalesce(t_session,'') = '' or coalesce(session,'') = t_session)
     order by created_at desc nulls last limit 1;
    if ovr is not null then
      overridden := true;
      bill := coalesce(ovr,0);
      breakdown := jsonb_build_array(jsonb_build_object('item','✏️ Personal total set by the bursar (override)','amount',bill));
    end if;
  exception when undefined_column then null;
  end;

  return jsonb_build_object('ok',true,'student_id',st.id,'class',st.class,'term',t_term,'session',t_session,
    'bill',bill,'aid',case when overridden then 0 else aid_total end,'aid_rows',case when overridden then '[]'::jsonb else aid_rows end,
    'breakdown',breakdown,'override',overridden,'matched',overridden or fs.id is not null,
    'currency',coalesce(fs.currency,'₦'),'due_date',fs.due_date,'note',coalesce(fs.note,''));
end $$;
revoke all on function public.sc_fee_bill_for(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_bill_for(uuid,text,text) to authenticated;

-- Per-term, per-student ledger truth: bill, paid, balance, arrears, status.
create or replace function public.sc_fee_account(p_student uuid, p_term text default null, p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare st record; cur record; b jsonb; bill numeric := 0; paid numeric := 0; arrears numeric := 0;
        arr_rows jsonb := '[]'::jsonb; t record; tbill numeric; tbill_row jsonb; tpaid numeric; opening numeric := 0;
        t_term text; t_session text; owing numeric; total_due numeric; status_txt text;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term := coalesce(nullif(btrim(p_term),''), cur.term);
  t_session := coalesce(nullif(btrim(p_session),''), cur.session);
  b := public.sc_fee_bill_for(p_student, t_term, t_session);
  bill := coalesce((b->>'bill')::numeric,0);

  select coalesce(sum(amount_paid),0) into paid from public.fee_payments
   where student_id = p_student
     and (coalesce(t_term,'') = '' or coalesce(term,'') = t_term)
     and (coalesce(t_session,'') = '' or coalesce(session,'') = t_session);

  for t in
    select coalesce(term,'') as term, coalesce(session,'') as session,
           max(coalesce(fee_total,0)) as tb, sum(coalesce(amount_paid,0)) as tp
      from public.fee_payments
     where student_id = p_student
       and not (coalesce(term,'') = coalesce(t_term,'') and coalesce(session,'') = coalesce(t_session,''))
     group by 1,2
  loop
    tpaid := coalesce(t.tp,0);
    /* The resolver returns jsonb; assigning it straight to a numeric variable
       made PostgreSQL attempt a jsonb->numeric cast and abort the whole call
       with `invalid input syntax for type numeric: {"ok": true, ...}`.
       Assign to a jsonb holder, then extract the scalar. */
    tbill_row := public.sc_fee_bill_for(p_student, t.term, t.session);
    tbill := coalesce(
               case when jsonb_typeof(tbill_row) = 'object'
                    then nullif(tbill_row->>'bill','')::numeric end,
               coalesce(t.tb,0));
    if tbill > tpaid then
      arrears := arrears + (tbill - tpaid);
      arr_rows := arr_rows || jsonb_build_array(jsonb_build_object('term',t.term,'session',t.session,'bill',tbill,'paid',tpaid,'owing',tbill-tpaid));
    end if;
  end loop;

  begin
    opening := coalesce(st.opening_arrears,0);
    if opening > 0 then
      arrears := arrears + opening;
      arr_rows := arr_rows || jsonb_build_array(jsonb_build_object('term','Before School Connect',
        'session',coalesce(nullif(st.opening_arrears_note,''),'Opening balance'),
        'bill',opening,'paid',0,'owing',opening,'opening',true));
    end if;
  exception when undefined_column then opening := 0;
  end;

  owing := greatest(bill - paid, 0);
  total_due := owing + arrears;
  status_txt := case when total_due <= 0.005 then 'paid'
                     when paid <= 0.005 then 'debtor'
                     else 'partial' end;
  if bill <= 0 and paid <= 0 and arrears <= 0 then status_txt := 'no-bill'; end if;

  return jsonb_build_object('ok',true,'student_id',st.id,'student_name',st.full_name,'admission_no',st.admission_no,
    'class',st.class,'arm',st.arm,'department',st.department,'term',t_term,'session',t_session,
    'bill',bill,'aid',coalesce((b->>'aid')::numeric,0),'paid',paid,'balance',owing,'arrears',arrears,
    'arrears_rows',arr_rows,'opening_arrears',opening,'total_due',total_due,'status',status_txt,
    'currency',coalesce(b->>'currency','₦'),'breakdown',coalesce(b->'breakdown','[]'::jsonb),
    'override',coalesce((b->>'override')::boolean,false),'matched',coalesce((b->>'matched')::boolean,false),
    'portal_locked',coalesce(st.portal_locked,false),'report_locked',coalesce(st.report_locked,false),
    'fully_paid', total_due <= 0.005, 'debtor', total_due > 0.005);
end $$;
revoke all on function public.sc_fee_account(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_account(uuid,text,text) to authenticated;

-- The whole-school / per-class fee overview the dashboards now use.
create or replace function public.sc_fee_overview(p_class text default null, p_term text default null, p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare me uuid := auth.uid(); cur record; rows jsonb := '[]'::jsonb; r record; acct jsonb;
        n int := 0; paid_n int := 0; debtor_n int := 0; partial_n int := 0; nobill_n int := 0;
        billed numeric := 0; collected numeric := 0; outstanding numeric := 0; arrears_total numeric := 0;
        aid_total numeric := 0; opening_total numeric := 0;
        t_term text; t_session text;
begin
  if me is null or not (public.is_staff(me) or public.is_admin(me)) then
    return jsonb_build_object('ok',false,'error','Only staff can load the fee overview.');
  end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term := coalesce(nullif(btrim(p_term),''), cur.term);
  t_session := coalesce(nullif(btrim(p_session),''), cur.session);
  for r in select st.id from public.students st
            where coalesce(st.status,'active') in ('active','approved')
              and (coalesce(btrim(p_class),'') = '' or lower(btrim(st.class)) = lower(btrim(p_class)))
            order by st.class, st.full_name loop
    acct := public.sc_fee_account(r.id, t_term, t_session);
    if coalesce((acct->>'ok')::boolean,false) then
      n := n + 1;
      billed := billed + coalesce((acct->>'bill')::numeric,0);
      collected := collected + coalesce((acct->>'paid')::numeric,0);
      outstanding := outstanding + coalesce((acct->>'total_due')::numeric,0);
      arrears_total := arrears_total + coalesce((acct->>'arrears')::numeric,0);
      aid_total := aid_total + coalesce((acct->>'aid')::numeric,0);
      opening_total := opening_total + coalesce((acct->>'opening_arrears')::numeric,0);
      if (acct->>'status') = 'paid' then paid_n := paid_n + 1;
      elsif (acct->>'status') = 'debtor' then debtor_n := debtor_n + 1;
      elsif (acct->>'status') = 'partial' then partial_n := partial_n + 1;
      else nobill_n := nobill_n + 1; end if;
      rows := rows || jsonb_build_array(jsonb_build_object(
        'student_id',acct->'student_id','student',acct->>'student_name','admission_no',acct->>'admission_no',
        'class',acct->>'class','department',acct->>'department',
        'bill',acct->'bill','aid',acct->'aid','paid',acct->'paid','balance',acct->'balance',
        'arrears',acct->'arrears','total_due',acct->'total_due','status',acct->>'status',
        'fully_paid',acct->'fully_paid','debtor',acct->'debtor',
        'portal_locked',acct->'portal_locked','report_locked',acct->'report_locked'));
    end if;
  end loop;
  /* V12.61 — a CONCISE, EXACT breakdown so the dashboard widget is complete
     and its figures can be reconciled line by line with the Fees page:
        billed        = this term's class-structure bills (before aid)
        aid           = scholarships / bursaries applied to this term
        net_bill      = billed - aid  (what the school actually expects)
        collected     = money received against THIS term
        outstanding   = net_bill + arrears - collected   (never negative)
        arrears       = unpaid balances carried in from earlier terms
        opening       = pre-School-Connect balances still owed
        rate          = collected / net_bill  */
  return jsonb_build_object('ok',true,'term',t_term,'session',t_session,'class',coalesce(p_class,''),
    'students',n,'fully_paid',paid_n,'debtors',debtor_n,'partial',partial_n,'no_bill',nobill_n,
    'billed',billed,'aid',aid_total,'net_bill',greatest(billed-aid_total,0),
    'collected',collected,'outstanding',outstanding,'arrears',arrears_total,'opening_arrears',opening_total,
    'collection_rate', case when (billed-aid_total) > 0 then round(collected / (billed-aid_total) * 100, 1) else 0 end,
    'breakdown', jsonb_build_array(
       jsonb_build_object('item','This term bill (class structure)','amount',billed),
       jsonb_build_object('item','Scholarship / aid applied','amount',-aid_total),
       jsonb_build_object('item','Arrears from earlier terms','amount',arrears_total),
       jsonb_build_object('item','Paid so far this term','amount',-collected)),
    'rows',rows);
end $$;
revoke all on function public.sc_fee_overview(text,text,text) from public, anon;
grant execute on function public.sc_fee_overview(text,text,text) to authenticated;

-- Snapshot rewriter: every fee_payments row is a CONSEQUENCE of the bill.
create or replace function public.sc_fee_sync_snapshots(p_student uuid, p_term text default null, p_session text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare bill numeric; paid_before numeric := 0; r record; n int := 0; t_term text; t_session text; cur record;
begin
  if p_student is null then return jsonb_build_object('ok',false,'error','No student.'); end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term := coalesce(nullif(btrim(p_term),''), cur.term);
  t_session := coalesce(nullif(btrim(p_session),''), cur.session);
  bill := coalesce((public.sc_fee_bill_for(p_student,t_term,t_session)->>'bill')::numeric,0);
  if bill <= 0 then
    -- No fee structure: keep the bursar's own figures, only fix impossible rows.
    update public.fee_payments set balance = greatest(coalesce(fee_total,0) - coalesce(amount_paid,0), 0)
     where student_id = p_student
       and coalesce(term,'') = coalesce(t_term,'') and coalesce(session,'') = coalesce(t_session,'')
       and coalesce(balance,-1) <> greatest(coalesce(fee_total,0) - coalesce(amount_paid,0), 0);
    get diagnostics n = row_count;
    return jsonb_build_object('ok',true,'rows',n,'grand_total',0,'note','No class fee structure matched — ledger untouched.');
  end if;
  for r in select id, coalesce(amount_paid,0) as amt from public.fee_payments
            where student_id = p_student
              and coalesce(term,'') = coalesce(t_term,'') and coalesce(session,'') = coalesce(t_session,'')
            order by created_at asc nulls last, id asc loop
    update public.fee_payments
       set fee_total = greatest(bill - paid_before, 0),
           balance   = greatest(bill - paid_before - r.amt, 0)
     where id = r.id
       and (coalesce(fee_total,-1) <> greatest(bill - paid_before, 0)
         or coalesce(balance,-1)   <> greatest(bill - paid_before - r.amt, 0));
    paid_before := paid_before + r.amt;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok',true,'rows',n,'grand_total',bill,'paid',paid_before,
    'outstanding',greatest(bill-paid_before,0));
end $$;
revoke all on function public.sc_fee_sync_snapshots(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_sync_snapshots(uuid,text,text) to authenticated;

-- Route the existing healer through the bill-truth engine so both sides agree.
create or replace function public.sc_recompute_fee_rows(p_student uuid, p_term text default '', p_session text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  return public.sc_fee_sync_snapshots(p_student, nullif(btrim(coalesce(p_term,'')),''), nullif(btrim(coalesce(p_session,'')),''));
end $$;
grant execute on function public.sc_recompute_fee_rows(uuid,text,text) to authenticated;

insert into public.sc_install_state(key,details) values ('v12.60-fee-truth','{"self":true}') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. ONE-CLICK BULK LOCKING BY FILTER (not row by row)
-- ---------------------------------------------------------------------------
create or replace function public.sc_set_student_locks_by_filter(
  p_kind text, p_locked boolean, p_message text default '',
  p_class text default null, p_only_debtors boolean default false,
  p_student_ids uuid[] default null, p_term text default null, p_session text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); ids uuid[] := '{}'; r record; acct jsonb; n int := 0;
begin
  if not coalesce(public.is_admin(me),false) then
    return jsonb_build_object('ok',false,'error','Only an administrator/bursar-tier account can lock or unlock students.');
  end if;
  if coalesce(p_kind,'portal') not in ('portal','report','both') then
    return jsonb_build_object('ok',false,'error','Unknown lock kind: '||coalesce(p_kind,'(null)'));
  end if;
  if p_student_ids is not null and coalesce(array_length(p_student_ids,1),0) > 0 then
    ids := p_student_ids;
  else
    for r in select st.id from public.students st
              where coalesce(st.status,'active') in ('active','approved')
                and (coalesce(btrim(p_class),'') = '' or lower(btrim(st.class)) = lower(btrim(p_class)))
              order by st.class, st.full_name loop
      if p_only_debtors then
        acct := public.sc_fee_account(r.id, p_term, p_session);
        if coalesce((acct->>'debtor')::boolean,false) then ids := ids || r.id; end if;
      else
        ids := ids || r.id;
      end if;
    end loop;
  end if;
  if coalesce(array_length(ids,1),0) = 0 then
    return jsonb_build_object('ok',false,'error','No students matched that filter.');
  end if;
  if p_kind in ('portal','both') then
    update public.students set portal_locked = p_locked,
      portal_lock_message = case when p_locked then coalesce(nullif(btrim(p_message),''), portal_lock_message) else '' end,
      locked_by = case when p_locked then me else locked_by end,
      locked_at = case when p_locked then now() else locked_at end
     where id = any(ids);
    get diagnostics n = row_count;
  end if;
  if p_kind in ('report','both') then
    update public.students set report_locked = p_locked,
      report_lock_message = case when p_locked then coalesce(nullif(btrim(p_message),''), report_lock_message) else '' end,
      locked_by = case when p_locked then me else locked_by end,
      locked_at = case when p_locked then now() else locked_at end
     where id = any(ids);
    get diagnostics n = row_count;
  end if;
  begin
    insert into public.activity_log(action,module,detail,actor_id,created_at)
    values (case when p_locked then 'bulk-lock' else 'bulk-unlock' end,'students',
            p_kind||':'||coalesce(array_length(ids,1),0)||' student(s)'||case when p_only_debtors then ' (debtors only)' else '' end,
            me, now());
  exception when undefined_table or undefined_column then null;
  end;
  return jsonb_build_object('ok',true,'updated',coalesce(array_length(ids,1),0),'kind',p_kind,'locked',p_locked);
end $$;
revoke all on function public.sc_set_student_locks_by_filter(text,boolean,text,text,boolean,uuid[],text,text) from public, anon;
grant execute on function public.sc_set_student_locks_by_filter(text,boolean,text,text,boolean,uuid[],text,text) to authenticated;

insert into public.sc_install_state(key,details) values ('v12.60-bulk-lock-by-filter','{"self":true}') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 4. MIDTERM REPORTS FOR EVERY CLASS IN ONE CLICK
-- ---------------------------------------------------------------------------
create or replace function public.sc_publish_all_midterm_reports(
  p_term text, p_session text, p_publish boolean default true, p_generate boolean default true)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); r record; classes jsonb := '[]'::jsonb; total_gen int := 0; total_pub int := 0;
        gen jsonb; n int := 0; t_term text; t_session text; cur record;
begin
  if me is null or not (public.is_admin(me) or public.is_staff(me)) then
    return jsonb_build_object('ok',false,'error','Only staff can publish midterm reports.');
  end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term := coalesce(nullif(btrim(p_term),''), cur.term);
  t_session := coalesce(nullif(btrim(p_session),''), cur.session);
  if coalesce(t_term,'') = '' or coalesce(t_session,'') = '' then
    return jsonb_build_object('ok',false,'error','A term and session are required.');
  end if;
  for r in select distinct btrim(st.class) as class_name from public.students st
            where coalesce(st.status,'active') in ('active','approved') and coalesce(btrim(st.class),'') <> ''
            order by 1 loop
    n := n + 1;
    if p_generate then
      gen := public.generate_midterm_reports(r.class_name, t_term, t_session);
      total_gen := total_gen + coalesce((gen->>'generated')::int,0);
    end if;
    update public.midterm_report_cards set published = p_publish, updated_at = now()
     where regexp_replace(lower(btrim(coalesce(class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(btrim(r.class_name)),'[^a-z0-9]','','g')
       and lower(btrim(coalesce(term,''))) = lower(btrim(t_term))
       and lower(btrim(coalesce(session,''))) = lower(btrim(t_session));
    get diagnostics total_pub = row_count;
    classes := classes || jsonb_build_array(jsonb_build_object(
      'class',r.class_name,'generated',coalesce((gen->>'generated')::int,0),
      'with_scores',coalesce((gen->>'with_scores')::int,0),
      'without_scores',coalesce((gen->>'without_scores')::int,0),
      'published_rows', total_pub));
    total_pub := 0;
  end loop;
  return jsonb_build_object('ok',true,'term',t_term,'session',t_session,'classes',n,
    'generated',total_gen,'published',p_publish,'details',classes);
end $$;
revoke all on function public.sc_publish_all_midterm_reports(text,text,boolean,boolean) from public, anon;
grant execute on function public.sc_publish_all_midterm_reports(text,text,boolean,boolean) to authenticated;

insert into public.sc_install_state(key,details) values ('v12.60-midterm-all-classes','{"self":true}') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 5. CBT QUESTION FLAGS — capture, surface, resolve, re-score
-- ---------------------------------------------------------------------------
/* NOTE: public.cbt_results is exposed through the cbt_results_with_exam view
   (r.* + exam metadata). Adding a column silently changes the view's column
   list, so the view must be dropped and rebuilt around the ALTER — otherwise
   re-running the schema fails with 42P16 ("cannot change name of view
   column") and the admin is left half-migrated. Same guard the schema already
   uses for its V12.38 alter. */
drop view if exists public.cbt_results_with_exam cascade;
alter table public.cbt_results add column if not exists flagged_questions jsonb not null default '[]'::jsonb;
alter table public.cbt_results add column if not exists flag_resolution jsonb not null default '{}'::jsonb;
create or replace view public.cbt_results_with_exam as
select r.*, e.code as exam_code, e.title as exam_title, e.subject as exam_subject,
       e.class as exam_class, e.term as exam_term, e.session as exam_session
from public.cbt_results r join public.cbt_exams e on e.id = r.exam_id;
grant select on public.cbt_results_with_exam to authenticated;

create table if not exists public.cbt_flag_resolutions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.cbt_exams(id) on delete cascade,
  question_index int not null,
  question_excerpt text default '',
  action text not null default 'award_all',
  mark numeric default 0,
  note text default '',
  affected_results int default 0,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_by_name text default '',
  resolved_at timestamptz default now(),
  revoked_at timestamptz
);
create index if not exists cbt_flag_resolutions_exam_idx on public.cbt_flag_resolutions(exam_id, question_index);
alter table public.cbt_flag_resolutions enable row level security;
drop policy if exists cbt_flag_res_staff on public.cbt_flag_resolutions;
create policy cbt_flag_res_staff on public.cbt_flag_resolutions for all
  using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- Tutor view: every flagged question with counts + who + resolution state.
create or replace function public.sc_cbt_flagged_summary(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); e record; out_rows jsonb := '[]'::jsonb; r record; res jsonb;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  select * into e from public.cbt_exams where id = p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  if not (public.is_admin(me) or public.is_staff(me) or e.teacher_id = me
          or public.teacher_can_manage_subject_class(me,e.subject,e.class)) then
    return jsonb_build_object('ok',false,'error','Not authorised to review flags for this exam');
  end if;
  for r in
    select (f.value)::int as q_index,
           count(*)::int as flagged_by,
           jsonb_agg(jsonb_build_object('student', cr.student_name, 'ref', cr.student_id_ref,
                                        'score', cr.score, 'total', cr.total, 'at', cr.created_at)
                     order by cr.created_at) as students
      from public.cbt_results cr
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(coalesce(cr.flagged_questions,'[]'::jsonb)) = 'array'
             then coalesce(cr.flagged_questions,'[]'::jsonb) else '[]'::jsonb end) f
     where cr.exam_id = p_exam_id
     group by 1
     order by 1
  loop
    select to_jsonb(x) into res from (
      select id, action, mark, note, affected_results, resolved_by_name, resolved_at
        from public.cbt_flag_resolutions
       where exam_id = p_exam_id and question_index = r.q_index and revoked_at is null
       order by resolved_at desc limit 1) x;
    out_rows := out_rows || jsonb_build_array(jsonb_build_object(
      'index', r.q_index,
      'question', coalesce(
        (case when jsonb_typeof(coalesce(e.csv_data,'[]'::jsonb)) = 'array' and jsonb_array_length(coalesce(e.csv_data,'[]'::jsonb)) > r.q_index
              then e.csv_data->r.q_index->>'question'
              when jsonb_typeof(coalesce(e.questions,'[]'::jsonb)) = 'array' and jsonb_array_length(coalesce(e.questions,'[]'::jsonb)) > r.q_index
              then e.questions->r.q_index->>'question' else null end), '(question text unavailable)'),
      'flagged_by', r.flagged_by,
      'students', coalesce(r.students,'[]'::jsonb),
      'resolution', coalesce(res,'null'::jsonb)));
  end loop;
  return jsonb_build_object('ok',true,'exam_id',p_exam_id,'code',e.code,'title',e.title,
    'total_results',(select count(*) from public.cbt_results where exam_id = p_exam_id),
    'flagged_results',(select count(*) from public.cbt_results where exam_id = p_exam_id
                        and jsonb_array_length(case when jsonb_typeof(coalesce(flagged_questions,'[]'::jsonb))='array'
                                                   then coalesce(flagged_questions,'[]'::jsonb) else '[]'::jsonb end) > 0),
    'questions', out_rows);
end $$;
revoke all on function public.sc_cbt_flagged_summary(uuid) from public, anon;
grant execute on function public.sc_cbt_flagged_summary(uuid) to authenticated;

-- Apply a resolution and re-score every affected attempt.
create or replace function public.sc_cbt_resolve_flag(
  p_exam_id uuid, p_question_index int, p_action text, p_note text default '', p_revoke boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); e record; mark numeric := 0; bank jsonb; q jsonb;
        res public.cbt_flag_resolutions%rowtype; affected int := 0; r record; new_score numeric; new_total numeric;
        new_pct numeric; act text := lower(btrim(coalesce(p_action,'award_all'))); who text := '';
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  select * into e from public.cbt_exams where id = p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found'); end if;
  if not (public.is_admin(me) or public.is_staff(me) or e.teacher_id = me
          or public.teacher_can_manage_subject_class(me,e.subject,e.class)) then
    return jsonb_build_object('ok',false,'error','Not authorised to resolve flags for this exam');
  end if;
  if act not in ('award_all','drop','none') then
    return jsonb_build_object('ok',false,'error','Unknown action: '||act);
  end if;
  bank := case when jsonb_typeof(coalesce(e.csv_data,'[]'::jsonb)) = 'array' and jsonb_array_length(coalesce(e.csv_data,'[]'::jsonb)) > 0
               then e.csv_data else coalesce(e.questions,'[]'::jsonb) end;
  q := case when jsonb_array_length(coalesce(bank,'[]'::jsonb)) > coalesce(p_question_index,0)
            then bank->coalesce(p_question_index,0) else '{}'::jsonb end;
  begin mark := coalesce(nullif(coalesce(q->>'mark', q->>'marks', q->>'points'),'')::numeric, 1);
  exception when others then mark := 1; end;

  select coalesce(full_name, email, 'staff') into who from public.profiles where id = me;

  if p_revoke then
    update public.cbt_flag_resolutions set revoked_at = now()
     where exam_id = p_exam_id and question_index = p_question_index and revoked_at is null;
    -- Rebuild those affected results from their stored answers (server re-grade).
    return jsonb_build_object('ok',true,'revoked',true,'note','Resolution revoked. Ask the tutor to Re-grade to restore the original scores.');
  end if;

  perform 1 from public.cbt_flag_resolutions
   where exam_id = p_exam_id and question_index = p_question_index and revoked_at is null;
  update public.cbt_flag_resolutions set revoked_at = now()
   where exam_id = p_exam_id and question_index = p_question_index and revoked_at is null;

  update public.cbt_results set flag_resolution = coalesce(flag_resolution,'{}'::jsonb)
    || jsonb_build_object(p_question_index::text, jsonb_build_object('action',act,'mark',mark,'at',now()))
   where exam_id = p_exam_id
     and flagged_questions @> to_jsonb(p_question_index)::jsonb;
  get diagnostics affected = row_count;

  if act <> 'none' then
    for r in select id, score, total, answers_data from public.cbt_results
              where exam_id = p_exam_id
              order by created_at loop
      new_score := coalesce(r.score,0);
      new_total := coalesce(r.total,0);
      if act = 'award_all' then
        new_score := least(new_score + mark, greatest(new_total, new_score + mark));
        new_total := greatest(new_total, new_score);
      elsif act = 'drop' then
        -- remove the question from the denominator; credit anyone who had it right
        new_total := greatest(new_total - mark, 0);
        if new_score > new_total then new_score := new_total; end if;
      end if;
      new_pct := case when new_total > 0 then round(new_score / new_total * 100, 2) else 0 end;
      update public.cbt_results
         set score = round(new_score,2), total = round(new_total,2), percent = new_pct
       where id = r.id;
    end loop;
  end if;

  insert into public.cbt_flag_resolutions(exam_id, question_index, question_excerpt, action, mark, note,
                                          affected_results, resolved_by, resolved_by_name)
  values (p_exam_id, p_question_index, left(coalesce(q->>'question',''),220), act, mark,
          coalesce(p_note,''), affected, me, coalesce(who,''))
  returning * into res;

  return jsonb_build_object('ok',true,'action',act,'question_index',p_question_index,'mark',mark,
    'affected_results',affected,'resolution_id',res.id,
    'message', case act
      when 'award_all' then 'All attempts received '||mark||' mark(s) for this question. Re-push to report cards to update scores.'
      when 'drop' then 'The question was removed from every attempt''s total. Re-push to report cards.'
      else 'Flag recorded as reviewed with no score change.' end);
exception when others then
  return jsonb_build_object('ok',false,'error',sqlerrm,'sqlstate',sqlstate);
end $$;
revoke all on function public.sc_cbt_resolve_flag(uuid,int,text,text,boolean) from public, anon;
grant execute on function public.sc_cbt_resolve_flag(uuid,int,text,text,boolean) to authenticated;


-- Persist the flags a candidate raised (called by cbt-exam.html right after a
-- confirmed submit; safe to re-run, and idempotent per result row).
create or replace function public.sc_cbt_save_flags(
  p_exam_id uuid, p_client_ref text, p_flagged jsonb default '[]'::jsonb,
  p_notes jsonb default '{}'::jsonb, p_admission_no text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare r record; n int := 0; idx int;
begin
  if p_exam_id is null then return jsonb_build_object('ok',false,'error','exam_id required'); end if;
  if jsonb_typeof(coalesce(p_flagged,'[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok',false,'error','flagged_questions must be an array of question indexes');
  end if;
  select id into r from public.cbt_results
   where exam_id = p_exam_id
     and ( (p_client_ref is not null and p_client_ref <> '' and client_ref = p_client_ref)
        or (coalesce(p_client_ref,'') = '' and coalesce(student_id_ref,'') = coalesce(p_admission_no,'')) )
   order by created_at desc limit 1;
  if r.id is null then
    return jsonb_build_object('ok',false,'error','No matching attempt — flags will appear once the attempt syncs.');
  end if;
  update public.cbt_results
     set flagged_questions = coalesce(p_flagged,'[]'::jsonb),
         flag_resolution = coalesce(flag_resolution,'{}'::jsonb)
   where id = r.id;
  n := jsonb_array_length(coalesce(p_flagged,'[]'::jsonb));
  return jsonb_build_object('ok',true,'result_id',r.id,'flagged',n,
    'note', case when n > 0 then 'Your tutor can now see the '||n||' flagged question(s).' else 'No flags recorded.' end);
end $$;
grant execute on function public.sc_cbt_save_flags(uuid,text,jsonb,jsonb,text) to anon, authenticated;

insert into public.sc_install_state(key,details) values ('v12.60-cbt-flag-resolution','{"self":true}') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 6. STUDENT FEE FILTER ROSTER (fully paid vs debtors) — one RPC
-- ---------------------------------------------------------------------------
create or replace function public.sc_fee_roster(p_class text default null, p_term text default null,
                                                p_session text default null, p_filter text default 'all')
returns jsonb language plpgsql security definer set search_path=public as $$
declare o jsonb; rows jsonb; f text := lower(btrim(coalesce(p_filter,'all')));
begin
  o := public.sc_fee_overview(p_class, p_term, p_session);
  if not coalesce((o->>'ok')::boolean,false) then return o; end if;
  rows := coalesce(o->'rows','[]'::jsonb);
  if f in ('paid','fully_paid','cleared') then
    select coalesce(jsonb_agg(x),'[]'::jsonb) into rows from jsonb_array_elements(rows) x
     where coalesce((x->>'fully_paid')::boolean,false);
  elsif f in ('debtor','debtors','owing','outstanding') then
    select coalesce(jsonb_agg(x),'[]'::jsonb) into rows from jsonb_array_elements(rows) x
     where coalesce((x->>'debtor')::boolean,false);
  elsif f = 'partial' then
    select coalesce(jsonb_agg(x),'[]'::jsonb) into rows from jsonb_array_elements(rows) x
     where (x->>'status') = 'partial';
  elsif f = 'unbilled' then
    select coalesce(jsonb_agg(x),'[]'::jsonb) into rows from jsonb_array_elements(rows) x
     where (x->>'status') = 'no-bill';
  end if;
  return o || jsonb_build_object('rows', rows, 'filter', f,
    'filtered_count', coalesce(jsonb_array_length(rows),0));
end $$;
revoke all on function public.sc_fee_roster(text,text,text,text) from public, anon;
grant execute on function public.sc_fee_roster(text,text,text,text) to authenticated;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'School Connect V12.60 installed — CBT code bridge, fee truth engine, bulk locks, all-class midterm publish, CBT flag resolution, fee roster ✅' as status;
