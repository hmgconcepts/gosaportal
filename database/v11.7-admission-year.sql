-- ============================================================================
-- School Connect V11.7 — TRUE ADMISSION YEAR (pass 65, issue 2)
-- ----------------------------------------------------------------------------
-- WHY: the lifetime ID card printed an "Admitted <year>" derived from the
-- admission number. That is WRONG for onboarded schools: when School Connect
-- is deployed in 2026, pre-existing students receive 2026-stamped admission
-- numbers although they joined years earlier. The number records REGISTRATION
-- ON THE PLATFORM, not admission into the school.
-- FIX: an explicit admission_year column — the year the student ACTUALLY
-- joined the school — editable on the student form, importable via CSV, and
-- the ONLY source the ID card trusts. When it is not recorded, the card
-- simply omits the row (honest omission beats a confident guess).
-- Idempotent; safe to run on every existing database.
-- ============================================================================
select 'RUNNING: School Connect admission-year pack V11.7' as running_version;

alter table public.students add column if not exists admission_year int;

comment on column public.students.admission_year is
  'The year the student ACTUALLY joined the school (may be years before the platform was deployed). Printed on the lifetime ID card. NULL = unknown → the card omits the Admitted row.';

-- Gentle sanity: reject obviously impossible years at write time (1900..next year).
do $adm_year_ck$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'students_admission_year_sane' and conrelid = 'public.students'::regclass
  ) then
    alter table public.students add constraint students_admission_year_sane
      check (admission_year is null or (admission_year >= 1900 and admission_year <= extract(year from now())::int + 1));
  end if;
exception when others then
  raise notice 'admission_year check constraint skipped (%)', sqlerrm;
end $adm_year_ck$;
