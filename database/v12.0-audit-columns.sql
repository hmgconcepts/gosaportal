-- ============================================================================
-- School Connect V12.0 — PRE-UPLOAD AUDIT PACK (pass 68)
-- ----------------------------------------------------------------------------
-- A full-platform 42703 sweep (client selects vs real schema) found the staff
-- birthday importer selecting staff.date_of_birth, which was never added.
-- Every other flagged column was verified present (drive_sync_*, lockdown_*,
-- idle_lock_minutes, departments.next_term_fees*, digital_library.max_score);
-- the truly wrong selects (poll_votes.created_at, results.percentage,
-- birthdays.date_of_birth, students.email) were fixed CLIENT-side to use the
-- real columns. This pack adds the one column that SHOULD exist.
-- Idempotent — safe to run repeatedly.
-- ============================================================================
select 'RUNNING: School Connect audit-columns pack V12.0' as running_version;

alter table public.staff add column if not exists date_of_birth date;

comment on column public.staff.date_of_birth is
  'V12.0: staff birthday (used by the Birthdays importer and dashboard widget). Optional.';

-- REAL BUG FOUND BY THE SWEEP: report-engine.js reads per-DEPARTMENT next-term
-- fees (departments.next_term_fees*) for report cards, but the columns were
-- only ever added to school_settings and classes — the department-level
-- override silently never worked. Added here; the engine's existing fallback
-- chain (department → class → global) now functions as designed.
alter table public.departments add column if not exists next_term_fees numeric default 0;
alter table public.departments add column if not exists next_term_fees_currency text default '₦';
alter table public.departments add column if not exists next_term_fees_note text default 'Payable before resumption';
