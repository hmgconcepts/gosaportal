-- ============================================================
-- FILE-STORAGE ARCHIVE VAULT (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Purpose: keep the limited 500 MB FREE-TIER DATABASE small by
-- moving OLD/COLD rows (audit logs, old CBT attempts, read
-- notifications, old check-ins…) into the SEPARATE 1 GB Supabase
-- FILE STORAGE as portable JSON archives, then purging them from
-- the database. Archives can be listed, downloaded and RESTORED
-- back into the database at any time from the Storage Manager page.
--
-- This creates a PRIVATE bucket called `archives` that only
-- owner-level admins (super_admin / admin / proprietor) can use.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this feature.
-- ============================================================
do $offload$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema not present (local test database) — archive bucket skipped.';
    return;
  end if;

  -- 1. Private bucket (50 MB per single archive file is far more than needed)
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('archives', 'archives', false, 52428800, array['application/json'])
  on conflict (id) do nothing;

  -- 2. Owner-only policies on storage.objects for this bucket
  execute 'drop policy if exists "sc archives owner select" on storage.objects';
  execute 'create policy "sc archives owner select" on storage.objects for select to authenticated using (bucket_id=''archives'' and public.is_owner(auth.uid()))';
  execute 'drop policy if exists "sc archives owner insert" on storage.objects';
  execute 'create policy "sc archives owner insert" on storage.objects for insert to authenticated with check (bucket_id=''archives'' and public.is_owner(auth.uid()))';
  execute 'drop policy if exists "sc archives owner update" on storage.objects';
  execute 'create policy "sc archives owner update" on storage.objects for update to authenticated using (bucket_id=''archives'' and public.is_owner(auth.uid())) with check (bucket_id=''archives'' and public.is_owner(auth.uid()))';
  execute 'drop policy if exists "sc archives owner delete" on storage.objects';
  execute 'create policy "sc archives owner delete" on storage.objects for delete to authenticated using (bucket_id=''archives'' and public.is_owner(auth.uid()))';

  raise notice 'File-storage archive vault ready: private bucket "archives" (owner-only).';
exception when others then
  raise notice 'Archive bucket setup skipped (%). You can create a private bucket named "archives" from Dashboard → Storage instead.', sqlerrm;
end
$offload$;

select 'File-storage archive vault installed ✅' as status;
