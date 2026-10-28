-- School Connect V12.51 — Runtime/cache deployment marker.
-- CBT pages and executable JS now use network-first service-worker fetch with
-- cached fallback only when offline; a new cache version is required to evict
-- V12.46 stale CBT scripts currently seen on the live client sites.
select 'RUNNING: School Connect runtime cache bust V12.51' as running_version;
insert into public.sc_install_state(key,details) values ('v12.51-runtime-cache-bust.sql','{"self":true,"runtime_cache":"v12.51"}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.51 runtime cache marker installed' as status;
