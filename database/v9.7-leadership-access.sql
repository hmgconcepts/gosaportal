-- ============================================================================
-- School Connect V9.7 — Leadership access completion
-- The bursar was missing from is_school_leader(), so RLS blocked bursars from
-- school_settings and other leader-managed tables even after the UI opened up.
-- Principal / head teacher / bursar are ADMIN-TIER: full access everywhere
-- except the owner cockpit. Idempotent.
-- ============================================================================
select 'RUNNING: School Connect leadership access pack V9.7' as running_version;
create or replace function public.is_school_leader(p_uid uuid)returns boolean language sql security definer stable set search_path=public as $$select exists(select 1 from profiles where id=p_uid and role in('super_admin','admin','proprietor','principal','head_teacher','bursar')and status in('approved','active'))$$;
revoke execute on function public.is_school_leader(uuid) from public, anon;
grant execute on function public.is_school_leader(uuid) to authenticated;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V9.7 leadership access installed — bursar joins the leader tier' as status;
