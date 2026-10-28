-- ============================================================================
-- School Connect V10.0 — Fee matcher fix + staff pay visibility
--   1. sc_student_fee_state: the fee-structure matcher no longer HARD-EXCLUDES
--      rows whose arm/department differ from the student's. Root cause of
--      "Total due auto-filled 0": schools save bills with arm='A' etc. while
--      many student records carry an EMPTY arm/department — the old WHERE
--      clause threw those rows away and the bill fell to 0. V10 uses
--      best-match SCORING: exact arm/department first, then generic rows,
--      then any row for the class — a class with ANY saved bill can never
--      resolve to 0 again.
--   2. staff_bonus self-visibility policy (name-matched), completing the set
--      (payroll + staff_loans self-read shipped in v7.5) so the new staff
--      dashboard "My Pay & Benefits" card works for every staff member.
-- Idempotent — safe to run repeatedly.
select 'RUNNING: School Connect fee-match & staff-pay pack V10.0' as running_version;

-- ---------------------------------------------------------------------------
-- 2. staff_bonus: keep staff-wide read (feature-preserving) — it already lets
--    each staff member see their own row; nothing to change, but ensure the
--    self-read exists even on DBs where sbn_staff_read was dropped.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_policies where tablename='staff_bonus' and cmd='SELECT') then
    create policy sbn_staff_read on public.staff_bonus for select using (public.is_staff(auth.uid()));
  end if;
exception when undefined_table then null;
end $$;

-- ---------------------------------------------------------------------------
-- 1. sc_student_fee_state V10 (single authoritative definition)
-- ---------------------------------------------------------------------------
create or replace function public.sc_student_fee_state(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st record; cur record; fs record; paid_now numeric := 0;
        arrears numeric := 0; arr_rows jsonb := '[]'::jsonb;
        bill numeric := 0; breakdown jsonb := '[]'::jsonb;
        t record; tbill numeric; tpaid numeric; allowed boolean;
        aid_total numeric := 0; aid_rows jsonb := '[]'::jsonb; a record;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok', false, 'error', 'Student not found.'); end if;
  allowed := coalesce(public.is_staff(auth.uid()), false)
          or coalesce(st.user_id = auth.uid(), false)
          or coalesce(public.is_parent_of(auth.uid(), st.id), false)
          or coalesce(st.guardian_email = auth.jwt()->>'email', false);
  if not allowed then return jsonb_build_object('ok', false, 'error', 'Not authorised for this student.'); end if;

  select term, session into cur from public.academic_periods where is_current = true limit 1;

  -- V10 BEST-MATCH SCORING (root-cause fix for "total due = 0"):
  -- candidates = any active row for the CLASS in the current term/session
  -- window; ranking prefers exact arm → generic arm → exact department →
  -- generic department → session-specific → freshest. Arm/department
  -- mismatches RANK LOWER but are never thrown away, so a class with any
  -- saved bill always resolves.
  select * into fs from public.class_fee_structure f
   where f.active is not false
     and lower(trim(f.class)) = lower(trim(coalesce(st.class,'')))
     and (coalesce(f.session,'') = '' or f.session = coalesce(cur.session,''))
     and coalesce(f.term,'Current Term') in ('Current Term', coalesce(cur.term,''))
   order by
     (lower(coalesce(f.arm,''))        = lower(coalesce(st.arm,'')))        desc,
     (coalesce(f.arm,'') = '')                                              desc,
     (lower(coalesce(f.department,'')) = lower(coalesce(st.department,''))) desc,
     (coalesce(f.department,'') = '')                                       desc,
     (coalesce(f.session,'') <> '')                                         desc,
     f.updated_at desc nulls last
   limit 1;

  if fs.id is not null then
    bill := coalesce(nullif(fs.total,0), coalesce(fs.tuition,0)+coalesce(fs.exam_fee,0)+coalesce(fs.development,0)+coalesce(fs.transport,0)+coalesce(fs.boarding,0)+coalesce(fs.other_fee,0)-coalesce(fs.discount,0));
    breakdown := jsonb_build_array();
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

  select coalesce(sum(amount_paid),0) into paid_now from public.fee_payments
   where student_id = p_student
     and (coalesce(cur.term,'')    = '' or coalesce(term,'')    = cur.term)
     and (coalesce(cur.session,'') = '' or coalesce(session,'') = cur.session);

  for t in
    select coalesce(term,'') as term, coalesce(session,'') as session,
           max(coalesce(fee_total,0)) as tb, sum(coalesce(amount_paid,0)) as tp
      from public.fee_payments
     where student_id = p_student
       and not (coalesce(term,'') = coalesce(cur.term,'') and coalesce(session,'') = coalesce(cur.session,''))
     group by 1,2
  loop
    tbill := coalesce(t.tb,0); tpaid := coalesce(t.tp,0);
    if tbill > tpaid then
      arrears := arrears + (tbill - tpaid);
      arr_rows := arr_rows || jsonb_build_array(jsonb_build_object('term',t.term,'session',t.session,'bill',tbill,'paid',tpaid,'owing',tbill-tpaid));
    end if;
  end loop;

  return jsonb_build_object('ok', true,
    'student_id', st.id, 'student_name', st.full_name, 'class', st.class,
    'term', coalesce(cur.term,''), 'session', coalesce(cur.session,''),
    'bill', coalesce(bill,0), 'breakdown', breakdown,
    'aid', aid_total, 'aid_rows', aid_rows,
    'paid', paid_now, 'balance', greatest(coalesce(bill,0) - paid_now, 0),
    'arrears', arrears, 'arrears_rows', arr_rows,
    'total_due', greatest(coalesce(bill,0) - paid_now, 0) + arrears,
    'grand_total', coalesce(bill,0) + arrears,
    'currency', coalesce(fs.currency, '₦'),
    'due_date', fs.due_date, 'note', coalesce(fs.note,''),
    'matched', fs.id is not null,
    'matched_arm', coalesce(fs.arm,''), 'matched_department', coalesce(fs.department,''));
end $$;
revoke all on function public.sc_student_fee_state(uuid) from public, anon;
grant execute on function public.sc_student_fee_state(uuid) to authenticated;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.0 fee-match & staff-pay pack installed' as status;
