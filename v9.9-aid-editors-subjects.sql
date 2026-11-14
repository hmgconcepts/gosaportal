-- ============================================================================
-- School Connect V9.9 — Financial aid in fee state, module editors expansion,
-- subject→class mapping
--   1. subjects.classes text[] — a subject is now mapped to the classes taking
--      it (powers wizard validation + exam auto-spread accuracy).
--   2. sc_student_fee_state V9.9: APPROVED financial aid (scholarships,
--      discounts, waivers from module_records module='financial_aid') is
--      subtracted from the student's bill and itemised in the breakdown —
--      aid now appears on dashboards, the fees page and receipts context.
--   3. Fine-grained module editors: sc_can_edit() gains a per-module
--      LEADERSHIP switch — the owner tier can set each protected module to
--      'full' (default) or 'readonly' for principal/head_teacher/bursar via
--      the new sc_module_access table; explicit per-user grants in
--      sc_module_editors still work on top.
-- Idempotent — safe to run repeatedly.
select 'RUNNING: School Connect aid+editors+subjects pack V9.9' as running_version;

-- ---------------------------------------------------------------------------
-- 1. subject → classes mapping
-- ---------------------------------------------------------------------------
alter table public.subjects add column if not exists classes text[];

-- ---------------------------------------------------------------------------
-- 3. per-module leadership access switch
-- ---------------------------------------------------------------------------
create table if not exists public.sc_module_access (
  module text primary key,
  leadership text not null default 'full' check (leadership in ('full','readonly')),
  set_by uuid references public.profiles(id) on delete set null,
  set_at timestamptz default now()
);
alter table public.sc_module_access enable row level security;
drop policy if exists "sma_read" on public.sc_module_access;
create policy "sma_read"  on public.sc_module_access for select using (auth.role() = 'authenticated');
drop policy if exists "sma_write" on public.sc_module_access;
create policy "sma_write" on public.sc_module_access for all
  using (public.is_owner(auth.uid())) with check (public.is_owner(auth.uid()));

-- sc_can_edit V9.9: owner always · leadership honours the per-module switch ·
-- explicit per-user grants (sc_module_editors) still grant on top · other
-- staff only via explicit grant.
create or replace function public.sc_can_edit(p_module text)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare r text; lv text;
begin
  select role into r from public.profiles where id = auth.uid();
  if r in ('super_admin','admin','proprietor') then return true; end if;
  if exists (select 1 from public.sc_module_editors e
              where e.module = p_module and e.user_id = auth.uid()) then return true; end if;
  if r in ('principal','head_teacher','bursar') then
    select leadership into lv from public.sc_module_access where module = p_module;
    return coalesce(lv,'full') = 'full';
  end if;
  return false;
end $$;
grant execute on function public.sc_can_edit(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. fee state with financial aid (full V9.9 definition)
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

  select * into fs from public.class_fee_structure f
   where f.active is not false
     and lower(trim(f.class)) = lower(trim(coalesce(st.class,'')))
     and (coalesce(f.session,'') = '' or f.session = coalesce(cur.session,''))
     and coalesce(f.term,'Current Term') in ('Current Term', coalesce(cur.term,''))
     and (coalesce(f.arm,'') = '' or lower(f.arm) = lower(coalesce(st.arm,'')))
     and (coalesce(f.department,'') = '' or lower(f.department) = lower(coalesce(st.department,'')))
   order by (coalesce(f.arm,'') <> '') desc, (coalesce(f.department,'') <> '') desc,
            (coalesce(f.session,'') <> '') desc, f.updated_at desc nulls last
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

  -- V9.9: APPROVED/RENEWED financial aid (scholarships/discounts/waivers).
  -- Rows live in module_records (module='financial_aid'); the student link is
  -- data->>'student' (name or id — both matched defensively).
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
    'due_date', fs.due_date, 'note', coalesce(fs.note,''));
end $$;
revoke all on function public.sc_student_fee_state(uuid) from public, anon;
grant execute on function public.sc_student_fee_state(uuid) to authenticated;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V9.9 aid+editors+subjects pack installed' as status;
