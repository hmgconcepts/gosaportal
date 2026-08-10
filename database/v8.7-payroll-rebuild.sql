-- ============================================================================
-- School Connect V8.7 — Payroll column rebuild (handles EVERY legacy variant)
-- ============================================================================
-- Symptoms fixed:
--   • "column net_pay can only be updated to DEFAULT" when editing a payslip
--     (net_pay is a GENERATED column on that database — often with an OUTDATED
--     formula that ignores bonus/overtime and the split deduction columns);
--   • bonus/overtime not added, deductions not subtracted after save.
-- What it does (idempotent):
--   1. Guarantees every modern payroll column exists.
--   2. If net_pay is GENERATED ALWAYS → drops and recreates it as a normal
--      numeric column (values recomputed by the trigger right after).
--   3. (Re)installs the ONE correct compute trigger, unconditional.
--   4. Backfills every stored row with the correct net.
-- ============================================================================
alter table public.payroll add column if not exists bonus numeric default 0;
alter table public.payroll add column if not exists overtime numeric default 0;
alter table public.payroll add column if not exists tax numeric default 0;
alter table public.payroll add column if not exists pension numeric default 0;
alter table public.payroll add column if not exists loan_deduction numeric default 0;
alter table public.payroll add column if not exists other_deductions numeric default 0;
alter table public.payroll add column if not exists deductions numeric default 0;

do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='payroll'
       and column_name='net_pay' and is_generated='ALWAYS') then
    alter table public.payroll drop column net_pay;
    alter table public.payroll add column net_pay numeric default 0;
    raise notice 'net_pay was GENERATED — rebuilt as a plain trigger-computed column.';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='payroll' and column_name='net_pay') then
    alter table public.payroll add column net_pay numeric default 0;
  end if;
end $$;

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

update public.payroll set basic = basic;  -- trigger recomputes every row


-- V8.7 also: digital-library attempt limit (1 = once, N = teacher's choice, 0 = unlimited)
alter table public.digital_library add column if not exists attempts_allowed int default 1;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V8.7 payroll rebuild complete — net pay now correct on every row' as status;
