-- =====================================================================
-- FIX-GEOFENCE — adds staff geofence columns to school_settings.
-- =====================================================================
-- WHY: "Could not find the 'enforce_geofence' column of 'school_settings'
-- in the schema cache" appeared when an admin clicked "Save Geofence",
-- because these columns were only added in a later DO block that some
-- deployments skipped.
--
-- RUN THIS ONCE in your Supabase SQL Editor if your portal shows that
-- error. It is 100% idempotent (safe to run multiple times).
-- After running, click Database → Tables → school_settings and verify
-- the columns appear, then refresh the Geofence page.
-- =====================================================================

alter table public.school_settings add column if not exists latitude numeric;
alter table public.school_settings add column if not exists longitude numeric;
alter table public.school_settings add column if not exists geo_radius_m integer default 200;
alter table public.school_settings add column if not exists enforce_geofence boolean default true;
alter table public.school_settings add column if not exists geo_updated_at timestamptz;

-- Make sure the single settings row exists.
insert into public.school_settings (id) values (1) on conflict (id) do nothing;

comment on column public.school_settings.latitude is 'Campus centre latitude for staff geofenced check-in.';
comment on column public.school_settings.longitude is 'Campus centre longitude for staff geofenced check-in.';
comment on column public.school_settings.geo_radius_m is 'Allowed radius in metres around the campus centre.';
comment on column public.school_settings.enforce_geofence is 'When true, staff check-in requires the device to be inside the campus geofence.';
comment on column public.school_settings.geo_updated_at is 'Timestamp of the last geofence update.';

-- Notify the PostgREST schema cache to pick up the new columns immediately.
notify pgrst, 'reload schema';
