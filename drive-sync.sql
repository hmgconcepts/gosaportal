-- ============================================================
-- GOOGLE DRIVE BACKUP & SYNC SETTINGS (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Stores the school's Google OAuth Client ID and the automatic
-- backup schedule so every admin device shares one configuration.
-- The Client ID is PUBLIC by design (it is not a secret); backups
-- themselves go to the school's own Google Drive via the
-- drive.file scope and never touch Supabase.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this feature.
-- ============================================================
alter table if exists public.school_settings add column if not exists drive_client_id text default '';
alter table if exists public.school_settings add column if not exists drive_sync_enabled boolean not null default false;
alter table if exists public.school_settings add column if not exists drive_sync_days int not null default 7;
alter table if exists public.school_settings add column if not exists drive_folder_id text default '';
alter table if exists public.school_settings add column if not exists drive_last_backup timestamptz;

select 'Google Drive backup & sync settings installed ✅' as status;
