-- ============================================================
-- SECURITY HARDENING SETTINGS — V6.0 (idempotent, safe to re-run)
-- ------------------------------------------------------------
-- Powers assets/js/security-guard.js:
--   • idle_lock_minutes : auto sign-out after N idle minutes (0 = off)
--   • lockdown_mode     : emergency switch — locks the portal for all
--                         non-admin roles instantly
--   • lockdown_message  : friendly notice shown to locked-out users
-- Managed from the Platform Health Console (health-check.html).
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this feature.
-- ============================================================
alter table if exists public.school_settings add column if not exists idle_lock_minutes int not null default 30;
alter table if exists public.school_settings add column if not exists lockdown_mode boolean not null default false;
alter table if exists public.school_settings add column if not exists lockdown_message text default '';

select 'Security hardening settings installed ✅' as status;
