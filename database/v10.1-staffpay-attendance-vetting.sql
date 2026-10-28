-- ============================================================================
-- School Connect V10.1 — Staff pay engine, attendance sync, academic vetting,
-- financial master export
--   1. sc_staff_pay_state(user): one RPC for the staff dashboard — latest
--      payslip breakdown, ACTIVE loans with auto-computed balance, approved
--      bonuses awaiting payroll, plus a suggested next-payroll pre-fill
--      (bonus total + monthly loan repayment).
--   2. Loan auto-balance: repayments recorded either manually (amount_repaid)
--      or through payroll loan_deduction rows are SUMMED; balance =
--      principal − total repaid; status flips to 'completed' automatically.
--      A payroll trigger posts each month's loan_deduction into the loan.
--   3. Attendance ⇄ QR check-in sync: a check-in (attendance_checkins or
--      student_clock) upserts the day's attendance row as 'present' (never
--      overwrites a teacher's explicit mark). sc_push_attendance_to_reports
--      fills report_cards.attendance_present/attendance_total per class+term.
--   4. Scheme of work: admin affirmation columns. Lesson plans: vetting
--      columns (reviewed_by/feedback + needs-changes status).
--   5. sc_class_fee_master(class): per-student financial master rows for the
--      PDF export (current bill, paid, balance, arrears, aid).
--   6. sc_module_access: leadership level 'none' (No access) allowed.
-- Idempotent — safe to run repeatedly.
select 'RUNNING: School Connect staff-pay/attendance/vetting pack V10.1' as running_version;

-- ---------------------------------------------------------------------------
-- 2a. Loan balance engine
-- ---------------------------------------------------------------------------
alter table public.staff_loans add column if not exists repaid_from_payroll numeric default 0;

create or replace function public.sc_payroll_posts_loan()
returns trigger language plpgsql as $$
declare l record;
begin
  -- When a payroll row with loan_deduction is APPROVED/PAID, post the amount
  -- into the staff member's OLDEST active loan (once per payroll row: guard
  -- by only posting on transition into approved/paid).
  if coalesce(new.loan_deduction,0) > 0
     and coalesce(new.status,'') in ('approved','paid')
     and coalesce(old.status,'') not in ('approved','paid') then
    select * into l from public.staff_loans
     where lower(trim(staff_name)) = lower(trim(coalesce(new.staff_name,'')))
       and status = 'active'
     order by date_taken nulls last, created_at limit 1;
    if l.id is not null then
      update public.staff_loans
         set repaid_from_payroll = coalesce(repaid_from_payroll,0) + new.loan_deduction,
             status = case when coalesce(amount_repaid,0) + coalesce(repaid_from_payroll,0) + new.loan_deduction >= coalesce(principal,0)
                           then 'completed' else status end
       where id = l.id;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_payroll_posts_loan on public.payroll;
create trigger trg_payroll_posts_loan
after update on public.payroll
for each row execute function public.sc_payroll_posts_loan();

-- manual repayments: keep status in sync whenever a loan row changes
create or replace function public.sc_loan_status_sync()
returns trigger language plpgsql as $$
begin
  if coalesce(new.amount_repaid,0) + coalesce(new.repaid_from_payroll,0) >= coalesce(new.principal,0)
     and coalesce(new.principal,0) > 0 and new.status = 'active' then
    new.status := 'completed';
  end if;
  return new;
end $$;
drop trigger if exists trg_loan_status_sync on public.staff_loans;
create trigger trg_loan_status_sync
before insert or update on public.staff_loans
for each row execute function public.sc_loan_status_sync();

-- ---------------------------------------------------------------------------
-- 1. Staff pay state RPC (self-service; staff sees ONLY their own)
-- ---------------------------------------------------------------------------
create or replace function public.sc_staff_pay_state(p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_user uuid; s record; pay record; l record; b record;
        loans jsonb := '[]'::jsonb; bonuses jsonb := '[]'::jsonb;
        loan_balance numeric := 0; monthly_due numeric := 0; bonus_due numeric := 0;
        pays jsonb := '[]'::jsonb; p record; net numeric;
begin
  v_user := coalesce(p_user, auth.uid());
  -- staff may only query themselves; admins may query anyone
  if v_user <> auth.uid() and not public.is_admin(auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'Not authorised.');
  end if;
  select * into s from public.staff where user_id = v_user limit 1;
  if s is null then return jsonb_build_object('ok', false, 'error', 'No staff record linked to this account.'); end if;

  for l in select * from public.staff_loans
            where lower(trim(staff_name)) = lower(trim(s.full_name))
            order by created_at desc limit 12 loop
    loans := loans || jsonb_build_array(jsonb_build_object(
      'type', l.loan_type, 'principal', coalesce(l.principal,0),
      'repaid', coalesce(l.amount_repaid,0) + coalesce(l.repaid_from_payroll,0),
      'balance', greatest(coalesce(l.principal,0) - coalesce(l.amount_repaid,0) - coalesce(l.repaid_from_payroll,0), 0),
      'monthly', coalesce(l.monthly_repayment,0), 'status', l.status, 'taken', l.date_taken));
    if l.status = 'active' then
      loan_balance := loan_balance + greatest(coalesce(l.principal,0) - coalesce(l.amount_repaid,0) - coalesce(l.repaid_from_payroll,0), 0);
      monthly_due := monthly_due + coalesce(l.monthly_repayment,0);
    end if;
  end loop;

  for b in select * from public.staff_bonus
            where lower(trim(staff_name)) = lower(trim(s.full_name))
            order by created_at desc limit 12 loop
    bonuses := bonuses || jsonb_build_array(jsonb_build_object(
      'type', b.bonus_type, 'amount', coalesce(b.amount,0), 'reason', b.reason,
      'status', b.status, 'date', b.award_date));
    if b.status = 'approved' then bonus_due := bonus_due + coalesce(b.amount,0); end if;
  end loop;

  for p in select * from public.payroll
            where staff_id = s.id or lower(trim(coalesce(staff_name,''))) = lower(trim(s.full_name))
            order by created_at desc limit 6 loop
    net := greatest(0, coalesce(p.basic,0)+coalesce(p.allowances,0)+coalesce(p.bonus,0)+coalesce(p.overtime,0)
           - coalesce(p.tax,0)-coalesce(p.pension,0)-coalesce(p.loan_deduction,0)-coalesce(p.other_deductions,0)-coalesce(p.deductions,0));
    pays := pays || jsonb_build_array(jsonb_build_object(
      'month', coalesce(p.month,''), 'year', p.year, 'status', coalesce(p.status,''),
      'basic', coalesce(p.basic,0), 'allowances', coalesce(p.allowances,0),
      'bonus', coalesce(p.bonus,0), 'overtime', coalesce(p.overtime,0),
      'tax', coalesce(p.tax,0), 'pension', coalesce(p.pension,0),
      'loan_deduction', coalesce(p.loan_deduction,0),
      'other_deductions', coalesce(p.other_deductions,0) + coalesce(p.deductions,0),
      'net', net));
  end loop;

  return jsonb_build_object('ok', true, 'staff_id', s.id, 'staff_name', s.full_name,
    'payslips', pays, 'loans', loans, 'bonuses', bonuses,
    'loan_balance', loan_balance, 'monthly_loan_due', monthly_due, 'approved_bonus_due', bonus_due,
    'currency', '₦');
end $$;
revoke all on function public.sc_staff_pay_state(uuid) from public, anon;
grant execute on function public.sc_staff_pay_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3a. QR/clock check-ins upsert the day's attendance (never overwrite teacher)
-- ---------------------------------------------------------------------------
create or replace function public.sc_checkin_marks_attendance()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; scls text; sname text;
begin
  if tg_table_name = 'attendance_checkins' then
    select id, class, full_name into sid, scls, sname from public.students
     where admission_no = new.student_id_ref
        or lower(full_name) = lower(coalesce(new.student_name,'')) limit 1;
  else -- student_clock
    sid := new.student_id;
    select class, full_name into scls, sname from public.students where id = sid;
  end if;
  if sid is null then return new; end if;
  insert into public.attendance (student_id, student_name, class, date, status)
  values (sid, coalesce(sname,''), coalesce(scls,''), coalesce(new.date, current_date), 'present')
  on conflict (student_id, date) do nothing;   -- a teacher's explicit mark always wins
  return new;
exception when others then return new;         -- attendance sync must never break a check-in
end $$;
do $$
begin
  drop trigger if exists trg_checkin_attendance on public.attendance_checkins;
  create trigger trg_checkin_attendance
  after insert on public.attendance_checkins
  for each row execute function public.sc_checkin_marks_attendance();
exception when undefined_table then null; end $$;
do $$
begin
  drop trigger if exists trg_clock_attendance on public.student_clock;
  create trigger trg_clock_attendance
  after insert on public.student_clock
  for each row execute function public.sc_checkin_marks_attendance();
exception when undefined_table then null; end $$;

-- ---------------------------------------------------------------------------
-- 3b. Push attendance counts into report cards (per class + term window)
-- ---------------------------------------------------------------------------
create or replace function public.sc_push_attendance_to_reports(
  p_class text, p_term text, p_session text, p_start date, p_end date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare st record; pres int; tot int; days int; n int := 0;
begin
  if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'error','Staff/admin only.'); end if;
  if p_start is null or p_end is null or p_end < p_start then
    return jsonb_build_object('ok',false,'error','Give the term''s start and end dates.');
  end if;
  select count(distinct date) into days from public.attendance
   where class = p_class and date between p_start and p_end;
  for st in select id, full_name, admission_no, class from public.students
             where class = p_class and coalesce(status,'active') <> 'left' loop
    select count(*) filter (where lower(status) in ('present','late')), count(*)
      into pres, tot
      from public.attendance
     where student_id = st.id and date between p_start and p_end;
    insert into public.report_cards (student_id, student_name, student_id_ref, class, term, session,
                                     attendance_present, attendance_total)
    values (st.id, st.full_name, coalesce(st.admission_no,''), st.class, coalesce(p_term,''), coalesce(p_session,''),
            coalesce(pres,0), greatest(coalesce(days,0), coalesce(tot,0)))
    on conflict (student_id_ref, class, term, session)
    do update set attendance_present = excluded.attendance_present,
                  attendance_total  = excluded.attendance_total,
                  student_id = excluded.student_id;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok',true,'students',n,'school_days',days);
end $$;
revoke all on function public.sc_push_attendance_to_reports(text,text,text,date,date) from public, anon;
grant execute on function public.sc_push_attendance_to_reports(text,text,text,date,date) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Scheme-of-work affirmation + lesson-plan vetting columns
-- ---------------------------------------------------------------------------
alter table public.scheme_of_work add column if not exists admin_affirmed boolean default false;
alter table public.scheme_of_work add column if not exists affirmed_by text default '';
alter table public.scheme_of_work add column if not exists affirmed_at timestamptz;
alter table public.lesson_plans add column if not exists reviewed_by text default '';
alter table public.lesson_plans add column if not exists reviewed_at timestamptz;
alter table public.lesson_plans add column if not exists review_feedback text default '';
do $$
begin
  alter table public.lesson_plans drop constraint if exists lesson_plans_status_check;
  alter table public.lesson_plans add constraint lesson_plans_status_check
    check (status in ('draft','submitted','approved','needs-changes'));
exception when others then null; end $$;

-- ---------------------------------------------------------------------------
-- 5. Financial master per class (rows for the PDF export)
-- ---------------------------------------------------------------------------
create or replace function public.sc_class_fee_master(p_class text default '')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st record; f jsonb; rows jsonb := '[]'::jsonb; cur record;
begin
  if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'error','Staff/admin only.'); end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  for st in select id, full_name, admission_no, class, department from public.students
             where (coalesce(p_class,'') = '' or class = p_class)
               and coalesce(status,'active') <> 'left'
             order by class, full_name limit 2000 loop
    f := public.sc_student_fee_state(st.id);
    if coalesce((f->>'ok')::boolean, false) then
      rows := rows || jsonb_build_array(jsonb_build_object(
        'student', st.full_name, 'admission_no', coalesce(st.admission_no,''),
        'class', st.class, 'department', coalesce(st.department,''),
        'bill', f->'bill', 'aid', f->'aid', 'paid', f->'paid', 'balance', f->'balance',
        'arrears', f->'arrears', 'total_due', f->'total_due'));
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'term', coalesce(cur.term,''), 'session', coalesce(cur.session,''), 'rows', rows);
end $$;
revoke all on function public.sc_class_fee_master(text) from public, anon;
grant execute on function public.sc_class_fee_master(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Module access: allow 'none'
-- ---------------------------------------------------------------------------
do $$
begin
  alter table public.sc_module_access drop constraint if exists sc_module_access_leadership_check;
  alter table public.sc_module_access add constraint sc_module_access_leadership_check
    check (leadership in ('full','readonly','none'));
exception when undefined_table then null; end $$;

-- sc_can_edit already returns false for readonly; 'none' also blocks writes.
-- (Nav/read hiding for 'none' is enforced client-side via the cached map;
-- RLS read policies stay as-is so nothing else breaks — 'none' is a UI wall
-- for leadership, and writes remain blocked at the database.)
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

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.1 staff-pay/attendance/vetting pack installed' as status;
