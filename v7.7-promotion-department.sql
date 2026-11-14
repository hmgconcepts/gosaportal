-- ============================================================================
-- School Connect V7.7 — Promotion department + outputs history support
-- ============================================================================
-- 1. promotions.department — lets the admin filter/report promotion decisions
--    by department (Science/Arts/Commercial…), auto-filled from the student.
-- 2. Backfill: existing promotion rows inherit their student's department.
-- Idempotent — safe to run repeatedly.
-- ============================================================================
alter table public.promotions add column if not exists department text default '';
update public.promotions p
   set department = coalesce(s.department,'')
  from public.students s
 where (p.student_id = s.id or lower(p.student_name) = lower(s.full_name))
   and coalesce(p.department,'') = '';
create index if not exists idx_promotions_dept on public.promotions (department);
select 'V7.7 promotion department installed' as status;
