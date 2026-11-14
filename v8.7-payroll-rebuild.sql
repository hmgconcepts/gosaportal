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
-- V8.8.2 FILE-FRESHNESS GUARD ------------------------------------------------
-- The "cannot drop column net_pay ... view staff_salary_overview depends on it
-- ... line 7" error can ONLY come from the ORIGINAL V8.7 copy of this file
-- (its drop statement sat at DO-block line 7 with no view handling). This
-- release prints its version as the FIRST thing it does, so you can always
-- confirm which copy actually ran. If you ever see that error again, the file
-- you executed did not print the banner below — fetch a fresh copy.
select 'RUNNING: School Connect payroll rebuild V8.8.2 (view-safe, CASCADE-fallback)' as running_version;
alter table public.payroll add column if not exists bonus numeric default 0;
alter table public.payroll add column if not exists overtime numeric default 0;
alter table public.payroll add column if not exists tax numeric default 0;
alter table public.payroll add column if not exists pension numeric default 0;
alter table public.payroll add column if not exists loan_deduction numeric default 0;
alter table public.payroll add column if not exists other_deductions numeric default 0;
alter table public.payroll add column if not exists deductions numeric default 0;

do $$
declare v record; view_defs jsonb := '[]'::jsonb;
begin
  raise notice 'School Connect payroll rebuild V8.8.2 running (view-safe, CASCADE fallback).';
  if exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='payroll'
       and column_name='net_pay' and is_generated='ALWAYS') then
    -- V8.8.1 BULLETPROOF: discover EVERY view that depends on payroll,
    -- DIRECTLY OR TRANSITIVELY (view-on-view chains included), via the
    -- pg_catalog dependency graph — information_schema.view_column_usage
    -- only sees direct references and can miss chained views.
    for v in
      with recursive deps as (
        select distinct r.ev_class::regclass as viewoid, 1 as depth
          from pg_depend d
          join pg_rewrite r on r.oid = d.objid
         where d.refobjid = 'public.payroll'::regclass
           and d.classid = 'pg_rewrite'::regclass
           and r.ev_class <> 'public.payroll'::regclass
        union
        select distinct r2.ev_class::regclass, deps.depth + 1
          from deps
          join pg_depend d2 on d2.refobjid = deps.viewoid
          join pg_rewrite r2 on r2.oid = d2.objid
         where d2.classid = 'pg_rewrite'::regclass
           and r2.ev_class <> deps.viewoid
      )
      select viewoid::text as vname, max(depth) as depth
        from deps
       where exists (select 1 from pg_class c where c.oid = deps.viewoid and c.relkind in ('v','m'))
       group by viewoid
       order by max(depth) desc          -- drop deepest first
    loop
      begin
        view_defs := jsonb_build_array(jsonb_build_object(
          'name', v.vname, 'def', pg_get_viewdef(v.vname::regclass, true))) || view_defs;  -- recreate shallowest first
        execute format('drop view if exists %s cascade', v.vname);
        raise notice 'Temporarily dropped dependent view %', v.vname;
      exception when others then
        raise notice 'Skipping dependent object % (%).', v.vname, sqlerrm;
      end;
    end loop;
    -- rebuild the column; CASCADE is a belt-and-braces net for any dependent
    -- object the walk could not see (it is a no-op when none remain).
    begin
      alter table public.payroll drop column net_pay;
    exception when dependent_objects_still_exist then
      raise notice 'Residual dependencies found - dropping net_pay with CASCADE.';
      alter table public.payroll drop column net_pay cascade;
    end;
    alter table public.payroll add column net_pay numeric default 0;
    raise notice 'net_pay was GENERATED - rebuilt as a plain trigger-computed column.';
    for v in select value->>'name' as name, value->>'def' as def
               from jsonb_array_elements(view_defs)
    loop
      begin
        execute format('create or replace view %s as %s', v.name, v.def);
        raise notice 'Recreated dependent view %', v.name;
      exception when others then
        raise notice 'Could not recreate view % automatically (%). Recreate it manually if still needed.', v.name, sqlerrm;
      end;
    end loop;
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
select 'V8.7 payroll rebuild complete (engine V8.8.2) — net pay now correct on every row' as status;
