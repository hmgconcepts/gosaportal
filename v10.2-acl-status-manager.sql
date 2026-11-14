-- ============================================================================
-- School Connect V10.2 — Role & Status Manager joins Module Access Control
-- status_manager moves from hard owner-only into the ACL system. Default is
-- seeded as 'none' (hidden from leadership) so behaviour is UNCHANGED until
-- the owner deliberately opens it in Settings → Module Access Control.
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect ACL status-manager pack V10.2' as running_version;
insert into public.sc_module_access(module, leadership)
values ('status_manager','none')
on conflict (module) do nothing;   -- an owner's later choice is never overwritten
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.2 installed — Role & Status Manager now ACL-governed (default: hidden from leadership)' as status;
