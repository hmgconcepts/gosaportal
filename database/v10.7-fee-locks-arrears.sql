-- ============================================================================
-- School Connect V10.7 — Fee discipline locks, manual arrears, community feed
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql (or any earlier pack) on an EXISTING database.
-- Fresh installs get all of this from complete-schema.sql automatically.
--
-- WHAT THIS PACK DOES
-- 1. PORTAL LOCK + REPORT-CARD LOCK (pass-55 issue 6). Admin/bursar can, per
--    student or per selection, with one click:
--      • lock the student (and their parents) OUT of the portal entirely, or
--      • hide only their REPORT CARD / results,
--    each with a custom bold message shown to the student. Enforced at THREE
--    layers: (a) columns on students, (b) sc_my_access_state() RPC the client
--    calls on sign-in, (c) RLS — locked students/parents lose SELECT on
--    report_scores / report_cards / results via a helper the policies call.
-- 2. MANUAL OPENING ARREARS (pass-55 issue 5). Schools adopting School
--    Connect mid-session have prior-term debts that predate the database.
--    New columns opening_arrears + opening_arrears_note on students, an
--    editable field in the fee form, and sc_student_fee_state now ADDS the
--    opening balance into arrears/total_due with its own breakdown row.
-- 3. COMMUNITY FEED HARDENING (pass-55 issue 4). V10.6 stamped new community
--    rows audience='all' and backfilled — this pack RE-backfills (schools
--    that ran V10.6 before entering data) and adds a trigger so community
--    module rows can NEVER fall back to private again, no matter which
--    client wrote them.
-- ============================================================================
select 'RUNNING: School Connect fee-locks/arrears/community pack V10.7' as running_version;

-- ---------------------------------------------------------------------------
-- 0. Schema
-- ---------------------------------------------------------------------------
alter table public.students add column if not exists portal_locked boolean not null default false;
alter table public.students add column if not exists portal_lock_message text not null default '';
alter table public.students add column if not exists report_locked boolean not null default false;
alter table public.students add column if not exists report_lock_message text not null default '';
alter table public.students add column if not exists locked_by uuid references public.profiles(id) on delete set null;
alter table public.students add column if not exists locked_at timestamptz;
alter table public.students add column if not exists opening_arrears numeric not null default 0;
alter table public.students add column if not exists opening_arrears_note text not null default '';

-- ---------------------------------------------------------------------------
-- 1. Lock helpers — used by RLS and by the client access gate
-- ---------------------------------------------------------------------------
create or replace function public.sc_is_locked_out(p_uid uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select exists(
    select 1 from public.students s
     where coalesce(s.portal_locked,false)
       and (s.user_id = p_uid or public.is_parent_of(p_uid, s.id))
  ) and not coalesce(public.is_staff(p_uid),false)
$$;

create or replace function public.sc_report_hidden_for(p_uid uuid, p_student uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select case when coalesce(public.is_staff(p_uid),false) then false
    else exists(
      select 1 from public.students s
       where s.id = p_student
         and (coalesce(s.report_locked,false) or coalesce(s.portal_locked,false))
         and (s.user_id = p_uid or public.is_parent_of(p_uid, s.id)))
    end
$$;

-- The one RPC the client calls after sign-in: am I (or my children) locked?
create or replace function public.sc_my_access_state()
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare uid uuid := auth.uid(); s record; kids jsonb := '[]'::jsonb; plocked boolean := false; pmsg text := '';
begin
  if uid is null then return jsonb_build_object('ok',true,'portal_locked',false); end if;
  if coalesce(public.is_staff(uid),false) then return jsonb_build_object('ok',true,'portal_locked',false,'staff',true); end if;
  for s in
    select st.* from public.students st
     where st.user_id = uid or public.is_parent_of(uid, st.id)
  loop
    if coalesce(s.portal_locked,false) then
      plocked := true;
      if coalesce(s.portal_lock_message,'') <> '' then pmsg := s.portal_lock_message; end if;
    end if;
    kids := kids || jsonb_build_array(jsonb_build_object(
      'student_id', s.id, 'name', s.full_name,
      'portal_locked', coalesce(s.portal_locked,false),
      'portal_lock_message', coalesce(s.portal_lock_message,''),
      'report_locked', coalesce(s.report_locked,false) or coalesce(s.portal_locked,false),
      'report_lock_message', coalesce(nullif(s.report_lock_message,''), nullif(s.portal_lock_message,''), '')));
  end loop;
  return jsonb_build_object('ok',true,'portal_locked',plocked,
    'portal_lock_message',coalesce(nullif(pmsg,''),
      'Access to the school portal has been suspended. Please contact the school bursary to resolve outstanding school fees.'),
    'students',kids);
end $$;
revoke execute on function public.sc_is_locked_out(uuid) from public, anon;
grant execute on function public.sc_is_locked_out(uuid) to authenticated;
revoke execute on function public.sc_report_hidden_for(uuid,uuid) from public, anon;
grant execute on function public.sc_report_hidden_for(uuid,uuid) to authenticated;
revoke execute on function public.sc_my_access_state() from public, anon;
grant execute on function public.sc_my_access_state() to authenticated;

-- One-click (bulk-capable) lock RPC — admin tier only, audit-stamped.
create or replace function public.sc_set_student_locks(p_student_ids uuid[], p_kind text, p_locked boolean, p_message text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if not coalesce(public.is_admin(auth.uid()),false) then
    return jsonb_build_object('ok',false,'error','Only an administrator/bursar-tier account can lock or unlock students.');
  end if;
  if coalesce(array_length(p_student_ids,1),0)=0 then return jsonb_build_object('ok',false,'error','No students selected.'); end if;
  if p_kind='portal' then
    update public.students set portal_locked=p_locked,
      portal_lock_message=case when p_locked then coalesce(nullif(p_message,''),portal_lock_message) else '' end,
      locked_by=case when p_locked then auth.uid() else locked_by end,
      locked_at=case when p_locked then now() else locked_at end
     where id=any(p_student_ids);
  elsif p_kind='report' then
    update public.students set report_locked=p_locked,
      report_lock_message=case when p_locked then coalesce(nullif(p_message,''),report_lock_message) else '' end,
      locked_by=case when p_locked then auth.uid() else locked_by end,
      locked_at=case when p_locked then now() else locked_at end
     where id=any(p_student_ids);
  else
    return jsonb_build_object('ok',false,'error','Unknown lock kind: '||coalesce(p_kind,'(null)'));
  end if;
  get diagnostics n = row_count;
  return jsonb_build_object('ok',true,'kind',p_kind,'locked',p_locked,'updated',n);
end $$;
revoke execute on function public.sc_set_student_locks(uuid[],text,boolean,text) from public, anon;
grant execute on function public.sc_set_student_locks(uuid[],text,boolean,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. RLS enforcement — a locked family cannot read report data even by
--    direct REST calls. Additive policies-as-restrictive is not available on
--    older setups, so we rebuild the three family-read policies with the
--    hidden-check folded in. Staff paths are untouched.
-- ---------------------------------------------------------------------------
drop policy if exists "v7_report_scores_read" on public.report_scores;
create policy "v7_report_scores_read" on public.report_scores for select using (
  public.is_staff(auth.uid())
  or exists(select 1 from public.students s where s.id=report_scores.student_id
        and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))
        and not public.sc_report_hidden_for(auth.uid(), s.id))
  or exists(select 1 from public.students s where s.admission_no=report_scores.student_id_ref
        and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))
        and not public.sc_report_hidden_for(auth.uid(), s.id))
);
drop policy if exists "v7_report_cards_family" on public.report_cards;
create policy "v7_report_cards_family" on public.report_cards for select using (
  public.is_staff(auth.uid())
  or ((public.is_parent_of(auth.uid(),student_id)
       or exists(select 1 from public.students s where s.id=report_cards.student_id and s.user_id=auth.uid()))
      and not public.sc_report_hidden_for(auth.uid(), student_id))
);

-- ---------------------------------------------------------------------------
-- 3. sc_student_fee_state V10.7 — manual OPENING ARREARS included.
--    Supersedes the V10.3 definition (override logic kept verbatim).
-- ---------------------------------------------------------------------------
create or replace function public.sc_student_fee_state(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st record; cur record; fs record; paid_now numeric := 0;
        arrears numeric := 0; arr_rows jsonb := '[]'::jsonb;
        bill numeric := 0; breakdown jsonb := '[]'::jsonb;
        t record; tbill numeric; tpaid numeric; allowed boolean;
        aid_total numeric := 0; aid_rows jsonb := '[]'::jsonb; a record;
        ovr record; overridden boolean := false; opening numeric := 0;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok', false, 'error', 'Student not found.'); end if;
  allowed := coalesce(public.is_staff(auth.uid()), false)
          or coalesce(st.user_id = auth.uid(), false)
          or coalesce(public.is_parent_of(auth.uid(), st.id), false)
          or coalesce(st.guardian_email = auth.jwt()->>'email', false);
  if not allowed then return jsonb_build_object('ok', false, 'error', 'Not authorised for this student.'); end if;

  select term, session into cur from public.academic_periods where is_current = true limit 1;

  -- V10 BEST-MATCH SCORING (kept): never hard-exclude on arm/department.
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

  -- V10.7 (#5): MANUAL OPENING ARREARS — debts from before the school adopted
  -- School Connect, entered per student. They join arrears/total_due with
  -- their own labelled rows so families see exactly where the figure is from.
  begin
    opening := coalesce(st.opening_arrears,0);
    if opening > 0 then
      arrears := arrears + opening;
      arr_rows := arr_rows || jsonb_build_array(jsonb_build_object(
        'term','Before School Connect','session',coalesce(nullif(st.opening_arrears_note,''),'Opening balance'),
        'bill',opening,'paid',0,'owing',opening,'opening',true));
    end if;
  exception when undefined_column then opening := 0;
  end;

  -- V10.3 (#4): the bursar's deliberate per-student override WINS.
  begin
    select fee_total into ovr from public.fee_payments
     where student_id = p_student
       and coalesce(total_overridden,false) = true
       and coalesce(fee_total,0) > 0
       and (coalesce(cur.term,'')    = '' or coalesce(term,'')    = cur.term)
       and (coalesce(cur.session,'') = '' or coalesce(session,'') = cur.session)
     order by created_at desc nulls last limit 1;
    if found and ovr.fee_total is not null then
      overridden := true;
      bill := coalesce(ovr.fee_total,0);
      arrears := 0; arr_rows := '[]'::jsonb;      -- folded into the bursar's figure
      breakdown := jsonb_build_array(jsonb_build_object('item','✏️ Personal total set by the bursar (override)','amount',bill));
    end if;
  exception when undefined_column then null;
  end;

  return jsonb_build_object('ok', true,
    'student_id', st.id, 'student_name', st.full_name, 'class', st.class,
    'term', coalesce(cur.term,''), 'session', coalesce(cur.session,''),
    'bill', coalesce(bill,0), 'breakdown', breakdown,
    'aid', case when overridden then 0 else aid_total end, 'aid_rows', case when overridden then '[]'::jsonb else aid_rows end,
    'paid', paid_now, 'balance', greatest(coalesce(bill,0) - paid_now, 0),
    'arrears', arrears, 'arrears_rows', arr_rows,
    'opening_arrears', case when overridden then 0 else opening end,
    'total_due', greatest(coalesce(bill,0) - paid_now, 0) + arrears,
    'grand_total', coalesce(bill,0) + arrears,
    'currency', coalesce(fs.currency, '₦'),
    'due_date', fs.due_date, 'note', coalesce(fs.note,''),
    'matched', overridden or fs.id is not null,
    'override', overridden,
    'matched_arm', coalesce(fs.arm,''), 'matched_department', coalesce(fs.department,''));
end $$;
revoke all on function public.sc_student_fee_state(uuid) from public, anon;
grant execute on function public.sc_student_fee_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Community feed hardening — trigger keeps community rows public forever.
-- ---------------------------------------------------------------------------
update public.module_records set audience='all'
 where module in ('lost_found','parent_meeting','cafeteria','menu','school_calendar','gallery')
   and coalesce(audience,'private') in ('private','');

create or replace function public.sc_community_audience()
returns trigger language plpgsql as $$
begin
  if new.module in ('lost_found','parent_meeting','cafeteria','menu','school_calendar','gallery')
     and coalesce(new.audience,'') in ('','private') then
    new.audience := 'all';
  end if;
  return new;
end $$;
drop trigger if exists trg_community_audience on public.module_records;
create trigger trg_community_audience before insert or update on public.module_records
for each row execute function public.sc_community_audience();

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.7 fee-locks/arrears/community pack installed' as status;
