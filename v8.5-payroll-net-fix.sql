-- ============================================================================
-- School Connect V8.5 — Payroll net-pay: unconditional trigger + backfill
-- ============================================================================
-- Symptom on older installs: net pay = basic+allowances only (deductions
-- ignored) or blank. Causes covered here:
--  1. The trigger fired only on UPDATE OF a fixed column list — a row touched
--     any other way kept its stale net_pay. Now recomputed on EVERY write.
--  2. Rows saved before the trigger existed were never corrected. One-time
--     backfill recomputes every stored row.
-- Idempotent — safe to run repeatedly.
-- ============================================================================
create or replace function public.compute_payroll_net()
returns trigger language plpgsql as $$
begin
  new.net_pay := greatest(0,
    coalesce(new.basic,0)+coalesce(new.allowances,0)+coalesce(new.bonus,0)+coalesce(new.overtime,0)
    - coalesce(new.tax,0)-coalesce(new.pension,0)-coalesce(new.loan_deduction,0)
    - coalesce(new.other_deductions,0)-coalesce(new.deductions,0));
  return new;
end $$;
drop trigger if exists trg_compute_payroll_net on public.payroll;
create trigger trg_compute_payroll_net
before insert or update on public.payroll
for each row execute function public.compute_payroll_net();

-- one-time backfill: recompute every existing row
update public.payroll set basic = basic;   -- touches each row; trigger recomputes net_pay

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V8.5 payroll net-pay trigger + backfill installed' as status;
