-- ============================================================================
-- School Connect V12.3 — WRITE-DIRECTION AUDIT PACK (pass 71)
-- ----------------------------------------------------------------------------
-- The V12.0 sweep checked what clients READ; this pass swept what clients
-- WRITE (insert/update/upsert keys vs real columns). Findings fixed here:
--
-- 1. attendance_checkins.status — checkin-staff.html computes 'late'/'present'
--    at check-in and INSERTS it; the column never existed, so **every staff
--    check-in written through that page silently failed** (42501/42703 in an
--    unread response) and the analytics lateness chart always fell back to
--    demo numbers. Column added; the whole staff-punctuality feature works
--    end-to-end for the first time.
--
-- 2. admissions.photo_url + admissions.data — the public application form
--    falls back to a direct insert carrying an applicant photo link and the
--    full payload as jsonb; both columns were missing, so the FALLBACK path
--    of apply.html failed (applicants got "Could not submit" whenever the
--    primary RPC path was unavailable). Columns added.
--
-- 3. push_subscriptions.subscription / user_agent / updated_at —
--    notifications.js upserts the whole subscription JSON + UA; the table
--    only had endpoint/p256dh/auth. The push-subscription save has silently
--    failed forever (caught by a catch that blamed "no VAPID keys yet").
--    Columns added so subscriptions actually persist.
--
-- (enterprise.js logIncident writes student_name/severity/etc INSIDE data
--  jsonb — legal; flagged keys were inside the nested object. No change.)
-- Idempotent — safe to run repeatedly.
-- ============================================================================
select 'RUNNING: School Connect write-columns pack V12.3' as running_version;

alter table public.attendance_checkins add column if not exists status text default 'present';
comment on column public.attendance_checkins.status is
  'V12.3: present/late computed against school_settings.checkin_deadline at check-in time. Was silently dropped before this column existed.';

alter table public.admissions add column if not exists photo_url text;
alter table public.admissions add column if not exists data jsonb not null default '{}'::jsonb;

alter table public.push_subscriptions add column if not exists subscription text;
alter table public.push_subscriptions add column if not exists user_agent text;
alter table public.push_subscriptions add column if not exists updated_at timestamptz default now();
