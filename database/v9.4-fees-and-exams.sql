-- ============================================================================
-- School Connect V9.4 — Fees automation + flexible exam timetable
--   1. class_fee_structure: total is COMPUTED from the components by a
--      trigger (tuition+exam+development+transport+boarding+other − discount).
--      Manual grand-total entry still works for schools that enter ONLY a
--      grand total (all components 0) — feature-preserving.
--   2. exam_timetable: day-number mode (Day 1/Day 2…) + paper divisions
--      (Paper/CBT/Practical…) + per-slot flexibility columns.
--   3. sc_student_fee_state(student): one RPC the dashboards/fee form call —
--      current-term bill (from the class fee structure), amount paid this
--      term, arrears from previous terms (bill − paid per past term), and
--      the full component breakdown. SECURITY DEFINER with an access wall:
--      staff, the student themself, or a linked parent only.
-- Idempotent — safe to run repeatedly.
select 'RUNNING: School Connect fees & exams pack V9.4' as running_version;

-- ---------------------------------------------------------------------------
-- 1. Auto-computed class fee total
-- ---------------------------------------------------------------------------
create or replace function public.compute_class_fee_total()
returns trigger language plpgsql as $$
declare comp numeric;
begin
  comp := coalesce(new.tuition,0)+coalesce(new.exam_fee,0)+coalesce(new.development,0)
        + coalesce(new.transport,0)+coalesce(new.boarding,0)+coalesce(new.other_fee,0)
        - coalesce(new.discount,0);
  -- Components entered → the SYSTEM computes the total (no manual math errors).
  -- All components zero → the school works grand-total-only; keep what they typed.
  if comp <> 0 then new.total := greatest(comp, 0); end if;
  if coalesce(new.amount,0) = 0 then new.amount := coalesce(new.total,0); end if;
  return new;
end $$;
drop trigger if exists trg_compute_class_fee_total on public.class_fee_structure;
create trigger trg_compute_class_fee_total
before insert or update on public.class_fee_structure
for each row execute function public.compute_class_fee_total();
-- one-time backfill
update public.class_fee_structure set tuition = tuition;

-- ---------------------------------------------------------------------------
-- 2. Exam timetable flexibility
-- ---------------------------------------------------------------------------
alter table public.exam_timetable add column if not exists day_no int;
alter table public.exam_timetable add column if not exists paper_kind text default '';

-- ---------------------------------------------------------------------------
-- 3. One-call student fee state
-- ---------------------------------------------------------------------------
create or replace function public.sc_student_fee_state(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st record; cur record; fs record; paid_now numeric := 0;
        arrears numeric := 0; arr_rows jsonb := '[]'::jsonb;
        bill numeric := 0; breakdown jsonb := '[]'::jsonb;
        t record; tbill numeric; tpaid numeric; allowed boolean;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok', false, 'error', 'Student not found.'); end if;
  -- coalesce: NULL user_id/guardian_email must not turn the whole OR-chain
  -- NULL (NULL is not FALSE, so 'if not allowed' would silently pass).
  allowed := coalesce(public.is_staff(auth.uid()), false)
          or coalesce(st.user_id = auth.uid(), false)
          or coalesce(public.is_parent_of(auth.uid(), st.id), false)
          or coalesce(st.guardian_email = auth.jwt()->>'email', false);
  if not allowed then return jsonb_build_object('ok', false, 'error', 'Not authorised for this student.'); end if;

  select term, session into cur from public.academic_periods where is_current = true limit 1;

  -- current-term bill: most specific matching fee structure wins
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

  -- NB: 'fs is not null' would require EVERY field non-null (PL/pgSQL record
  -- semantics) — a NULL due_date silently skipped the whole bill. Test the PK.
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

  -- paid this term
  select coalesce(sum(amount_paid),0) into paid_now from public.fee_payments
   where student_id = p_student
     and (coalesce(cur.term,'')    = '' or coalesce(term,'')    = cur.term)
     and (coalesce(cur.session,'') = '' or coalesce(session,'') = cur.session);

  -- arrears: for every PAST term that has payment rows carrying a fee_total,
  -- outstanding = max(fee_total) − sum(paid). (fee_total travels on payments,
  -- so history survives class changes and fee-structure edits.)
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
    'paid', paid_now, 'balance', greatest(coalesce(bill,0) - paid_now, 0),
    'arrears', arrears, 'arrears_rows', arr_rows,
    'total_due', greatest(coalesce(bill,0) - paid_now, 0) + arrears,
    'grand_total', coalesce(bill,0) + arrears,
    'currency', coalesce(fs.currency, '₦'),
    'due_date', fs.due_date, 'note', coalesce(fs.note,''));
end $$;
revoke all on function public.sc_student_fee_state(uuid) from public, anon;
grant execute on function public.sc_student_fee_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Timetable engine V9.4 — two-phase double-period placement (see comments)
-- ---------------------------------------------------------------------------
-- V9.4 (#7) TWO-PHASE PLACEMENT: all DOUBLE-PERIOD pairs are placed FIRST
-- (while the grid is empty and adjacent slots abound), then all singles.
-- Previously pairs were sought per-subject mid-generation, when the grid was
-- already fragmented — so later subjects "lost" their doubles. Phase 2 derives
-- each subject's remaining singles from what phase 1 actually placed, so the
-- weekly count is always exact.
create or replace function public.generate_timetable(
  p_class text, p_session text default '', p_term text default '',
  p_periods_per_day integer default 6, p_day_periods jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare req record; blk record; occ int; placed int:=0; unplaced int:=0;
        ppd int:=least(greatest(coalesce(p_periods_per_day,6),1),12);
        chosen_day text; chosen_period int;
        r_days text[]; r_p jsonb; t_days text[]; t_p jsonb; cap int;
        unplaced_items jsonb:='[]'::jsonb; required_total int:=0; capacity int:=0;
        d text; dp int; pairs int; singles int; dbl_placed int;
begin
 if not public.sc_can_edit('timetable') then return jsonb_build_object('ok',false,'error','Only the admin or an authorized timetable editor can generate timetables. Ask the admin for access (Timetable Wizard → Authorized editors).'); end if;
 if coalesce(trim(p_class),'')='' then return jsonb_build_object('ok',false,'error','Select a class.'); end if;
 select coalesce(sum(greatest(periods_per_week,0)),0) into required_total from public.timetable_requirements where class=p_class;
 if required_total=0 then return jsonb_build_object('ok',false,'error','No subject demand exists for '||p_class||'. Add each subject, teacher and periods/week first.'); end if;

 foreach d in array array['Monday','Tuesday','Wednesday','Thursday','Friday'] loop
   dp := least(greatest(coalesce((p_day_periods->>d)::int, ppd),0),12);
   capacity := capacity + dp
     - (select count(*) from public.timetable_blocks b
         where (b.class=p_class or b.class='ALL') and b.day=d and b.period<=dp);
 end loop;

 delete from public.timetable where class=p_class
   and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'');

 for blk in select * from public.timetable_blocks b
             where (b.class=p_class or b.class='ALL')
               and b.period <= least(greatest(coalesce((p_day_periods->>b.day)::int, ppd),0),12) loop
   insert into public.timetable(class,day,period,subject,teacher,session,term)
   values (p_class, blk.day, blk.period::text, '⛔ '||coalesce(nullif(blk.label,''),'Free period'), null,
           coalesce(p_session,''), coalesce(p_term,''))
   on conflict do nothing;
 end loop;

 -- ================= PHASE 1: every subject's DOUBLE pairs =================
 for req in select * from public.timetable_requirements where class=p_class
             and coalesce(double_periods,0) > 0
             order by (coalesce(max_period,99)) asc, double_periods desc, periods_per_week desc, subject loop
  r_days := req.available_days; r_p := req.available_periods;
  t_days := null; t_p := null;
  if coalesce(req.teacher,'')<>'' then
    select available_days, available_periods into t_days, t_p
      from public.teacher_availability
     where lower(trim(teacher))=lower(trim(req.teacher)) limit 1;
  end if;
  cap := req.max_period;
  pairs := least(greatest(coalesce(req.double_periods,0),0), greatest(coalesce(req.periods_per_week,0),0)/2);
  for occ in 1..pairs loop
   chosen_day:=null; chosen_period:=null;
   select dd.day, p.per into chosen_day, chosen_period
   from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
   cross join generate_series(1,11) p(per)
   where p.per+1 <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
     and (cap is null or p.per+1 <= cap)
     and (r_days is null or array_length(r_days,1) is null
          or exists(select 1 from unnest(r_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))
     and (t_days is null or array_length(t_days,1) is null
          or exists(select 1 from unnest(t_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))
     and (r_p is null or (r_p ? dd.day
          and exists(select 1 from jsonb_array_elements_text(r_p->dd.day) e(v) where e.v::int = p.per)
          and exists(select 1 from jsonb_array_elements_text(r_p->dd.day) e(v) where e.v::int = p.per+1)))
     and (t_p is null or (t_p ? dd.day
          and exists(select 1 from jsonb_array_elements_text(t_p->dd.day) e(v) where e.v::int = p.per)
          and exists(select 1 from jsonb_array_elements_text(t_p->dd.day) e(v) where e.v::int = p.per+1)))
     and not exists(select 1 from public.timetable t
                     where t.class=p_class and t.day=dd.day and t.period in (p.per::text,(p.per+1)::text)
                       and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,''))
     and (coalesce(req.teacher,'')='' or not exists(
            select 1 from public.timetable t
             where t.day=dd.day and t.period in (p.per::text,(p.per+1)::text)
               and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')
               and string_to_array(lower(regexp_replace(coalesce(t.teacher,''),'\s*/\s*','/','g')),'/')
                && string_to_array(lower(regexp_replace(req.teacher,'\s*/\s*','/','g')),'/')))
   order by
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day and t.subject like req.subject||'%'
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            random()
   limit 1;
   if chosen_day is not null then
     insert into public.timetable(class,day,period,subject,teacher,session,term)
     values(p_class,chosen_day,chosen_period::text,req.subject||' (double)',nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,'')),
           (p_class,chosen_day,(chosen_period+1)::text,req.subject||' (double)',nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
     placed:=placed+2;
   end if;
   -- no adjacent pair anywhere → the missing periods return as singles in phase 2
  end loop;
 end loop;

 -- ================= PHASE 2: singles (remaining demand) =================
 for req in select * from public.timetable_requirements where class=p_class
             order by (coalesce(max_period,99)) asc, periods_per_week desc, subject loop
  r_days := req.available_days; r_p := req.available_periods;
  t_days := null; t_p := null;
  if coalesce(req.teacher,'')<>'' then
    select available_days, available_periods into t_days, t_p
      from public.teacher_availability
     where lower(trim(teacher))=lower(trim(req.teacher)) limit 1;
  end if;
  cap := req.max_period;
  -- exact accounting: whatever phase 1 actually placed for this subject
  select count(*) into dbl_placed from public.timetable t
   where t.class=p_class and t.subject=req.subject||' (double)'
     and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'');
  singles := greatest(coalesce(req.periods_per_week,0),0) - coalesce(dbl_placed,0);
  if singles <= 0 then continue; end if;
  for occ in 1..singles loop
   chosen_day:=null; chosen_period:=null;
   select dd.day, p.per into chosen_day, chosen_period
   from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
   cross join generate_series(1,12) p(per)
   where p.per <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
     and (cap is null or p.per <= cap)
     and ( (r_p is not null and r_p ? dd.day)
        or (r_p is null and (r_days is null or array_length(r_days,1) is null
             or exists(select 1 from unnest(r_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))) )
     and ( (t_p is not null and t_p ? dd.day)
        or (t_p is null and (t_days is null or array_length(t_days,1) is null
             or exists(select 1 from unnest(t_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))) )
     and ( r_p is null or not (r_p ? dd.day)
        or exists(select 1 from jsonb_array_elements_text(r_p->dd.day) e(v) where e.v::int = p.per) )
     and ( t_p is null or not (t_p ? dd.day)
        or exists(select 1 from jsonb_array_elements_text(t_p->dd.day) e(v) where e.v::int = p.per) )
     and not exists(select 1 from public.timetable t
                     where t.class=p_class and t.day=dd.day and t.period=p.per::text
                       and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,''))
     and (coalesce(req.teacher,'')='' or not exists(
            select 1 from public.timetable t
             where t.day=dd.day and t.period=p.per::text
               and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')
               and string_to_array(lower(regexp_replace(coalesce(t.teacher,''),'\s*/\s*','/','g')),'/')
                && string_to_array(lower(regexp_replace(req.teacher,'\s*/\s*','/','g')),'/')))
   order by
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day and t.subject like req.subject||'%'
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            (select count(*) from public.timetable t where t.class=p_class and t.period=p.per::text and t.subject like req.subject||'%'
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            random()
   limit 1;
   if chosen_day is null then
     unplaced:=unplaced+1;
     unplaced_items:=unplaced_items||jsonb_build_array(jsonb_build_object('subject',req.subject,'teacher',req.teacher,'occurrence',occ,'reason','No free slot on an allowed day/period'));
   else
     insert into public.timetable(class,day,period,subject,teacher,session,term)
     values(p_class,chosen_day,chosen_period::text,req.subject,nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
     placed:=placed+1;
   end if;
  end loop;
 end loop;
 insert into public.timetable_runs(class,session,term,generated_at,conflicts,notes)
 values(p_class,p_session,p_term,now(),unplaced,'Placed '||placed||' of '||required_total||' requested periods');
 return jsonb_build_object('ok',true,'placed',placed,'unplaced',unplaced,'requested',required_total,
   'capacity',capacity,'periods_per_day',ppd,'day_periods',coalesce(p_day_periods,'{}'::jsonb),
   'unplaced_items',unplaced_items,
   'message',case when unplaced=0 then 'Conflict-free timetable generated.'
     else 'Generated with '||unplaced||' unplaced demand(s). Review teacher days/periods, blocked slots or increase periods/day.' end);
exception when others then return jsonb_build_object('ok',false,'error',sqlerrm);
end$$;
revoke execute on function public.generate_timetable(text,text,text,integer,jsonb) from public, anon;
grant execute on function public.generate_timetable(text,text,text,integer,jsonb) to authenticated;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V9.4 fees & exams pack installed — auto totals, fee state RPC, exam day-mode + paper divisions' as status;
