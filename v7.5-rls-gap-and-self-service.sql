-- ============================================================================
-- School Connect V7.5 — RLS gap closure + staff self-service reads
-- ============================================================================
-- ROOT CAUSE (same family as the v7.3 admission_links fix, found by a live
-- REST audit of every table): these tables had ROW LEVEL SECURITY *enabled*
-- but ZERO policies, which in PostgreSQL means DEFAULT-DENY FOR EVERYONE —
-- including the admin. Confirmed live symptoms:
--   • staff_loans / staff_appraisals  → admin INSERT returns 403 (pages unusable)
--   • certificate_designs             → designs never save; page always empty
--   • timetable_config                → period/break structure can't be stored
--   • cbt_roster                      → entrance-exam rosters unreadable
--   • admission_letters               → generated letters invisible
--   • sc_install_state                → install bookkeeping unreadable to admin
--   • sc_heartbeat                    → "permission denied" on the Platform
--                                        Health heartbeat tile (missing GRANT)
-- PLUS one enterprise self-service gap: ordinary staff could not see even
-- their OWN payslips, loans or appraisals (admin-only policies). HR pages
-- looked "empty / no sample data" to every non-admin guest in the demo.
--
-- Idempotent: safe to run any number of times, on any School Connect database.
-- ============================================================================

-- ---------- helper-safe grants (RLS still filters rows) ---------------------
grant select on public.sc_heartbeat to authenticated;
grant select on public.sc_heartbeat to anon;

-- ---------- sc_heartbeat: world-readable single status row ------------------
alter table public.sc_heartbeat enable row level security;
drop policy if exists "hb_read" on sc_heartbeat;
create policy "hb_read" on public.sc_heartbeat for select using (true);
-- writes stay exclusively inside the SECURITY DEFINER RPC sc_keep_alive().

-- ---------- sc_install_state: admin visibility only --------------------------
alter table public.sc_install_state enable row level security;
drop policy if exists "sis_admin_read" on sc_install_state;
create policy "sis_admin_read" on public.sc_install_state
  for select using (public.is_admin(auth.uid()));

-- ---------- certificate_designs: everyone reads, admin manages ---------------
alter table public.certificate_designs enable row level security;
drop policy if exists "cd_read" on certificate_designs;
create policy "cd_read" on public.certificate_designs
  for select using (auth.role() = 'authenticated');
drop policy if exists "cd_admin_write" on certificate_designs;
create policy "cd_admin_write" on public.certificate_designs
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- timetable_config: everyone reads the bell schedule, admin edits --
alter table public.timetable_config enable row level security;
drop policy if exists "tc_read" on timetable_config;
create policy "tc_read" on public.timetable_config
  for select using (auth.role() = 'authenticated');
drop policy if exists "tc_admin_write" on timetable_config;
create policy "tc_admin_write" on public.timetable_config
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- cbt_roster: candidates check themselves in, staff manage ---------
alter table public.cbt_roster enable row level security;
drop policy if exists "cr_read" on cbt_roster;
create policy "cr_read" on public.cbt_roster for select using (true);
drop policy if exists "cr_staff_write" on cbt_roster;
create policy "cr_staff_write" on public.cbt_roster
  for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------- admission_letters: public verification read, admin manages -------
alter table public.admission_letters enable row level security;
drop policy if exists "al_read" on admission_letters;
create policy "al_read" on public.admission_letters for select using (true);
drop policy if exists "al_admin_write" on admission_letters;
create policy "al_admin_write" on public.admission_letters
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- staff_loans: admin manages, staff read their own -----------------
alter table public.staff_loans enable row level security;
drop policy if exists "sl_admin_all" on staff_loans;
create policy "sl_admin_all" on public.staff_loans
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "sl_self_read" on staff_loans;
create policy "sl_self_read" on public.staff_loans
  for select using (exists (
    select 1 from public.staff s
    where s.user_id = auth.uid()
      and lower(s.full_name) = lower(staff_loans.staff_name)));

-- ---------- staff_appraisals: admin manages, staff read their own ------------
alter table public.staff_appraisals enable row level security;
drop policy if exists "sa_admin_all" on staff_appraisals;
create policy "sa_admin_all" on public.staff_appraisals
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
drop policy if exists "sa_self_read" on staff_appraisals;
create policy "sa_self_read" on public.staff_appraisals
  for select using (exists (
    select 1 from public.staff s
    where s.user_id = auth.uid()
      and lower(s.full_name) = lower(staff_appraisals.staff_name)));

-- ---------- payroll: staff can read (only) their OWN payslips ----------------
-- Admin keeps full read/write via the existing pay_all policy; this ADDS a
-- narrow self-read so a teacher's payslip page is no longer blank.
drop policy if exists "pay_self_read" on payroll;
create policy "pay_self_read" on public.payroll
  for select using (exists (
    select 1 from public.staff s
    where s.user_id = auth.uid()
      and (s.id = payroll.staff_id or lower(s.full_name) = lower(coalesce(payroll.staff_name,''))))); 

select 'V7.5 RLS gap closure + staff self-service installed' as status;
