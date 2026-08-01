-- ============================================================
-- BRANDING BUCKET — signatures, stamps & logos in File Storage
-- (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Tiny branding images (drawn signatures ~5–20 KB, stamps, logos)
-- now live in the SEPARATE 1 GB File Storage — not the 500 MB
-- database and no Google Drive round-trip needed. The bucket is
-- PUBLIC-READ (report cards and e-receipts embed the images by
-- URL when printing) but only admin-tier roles can upload,
-- replace or delete files. 200 KB per-file cap keeps it light.
-- This file is ALREADY embedded inside complete-schema.sql; run
-- it standalone only on databases installed before this release.
-- ============================================================
do $branding$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema not present (local test database) — branding bucket skipped.';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('branding', 'branding', true, 204800, array['image/png','image/jpeg','image/webp','image/svg+xml'])
  on conflict (id) do nothing;
  execute 'drop policy if exists "sc branding public read" on storage.objects';
  execute 'create policy "sc branding public read" on storage.objects for select using (bucket_id=''branding'')';
  execute 'drop policy if exists "sc branding admin write" on storage.objects';
  execute 'create policy "sc branding admin write" on storage.objects for insert to authenticated with check (bucket_id=''branding'' and public.is_admin(auth.uid()))';
  execute 'drop policy if exists "sc branding admin update" on storage.objects';
  execute 'create policy "sc branding admin update" on storage.objects for update to authenticated using (bucket_id=''branding'' and public.is_admin(auth.uid())) with check (bucket_id=''branding'' and public.is_admin(auth.uid()))';
  execute 'drop policy if exists "sc branding admin delete" on storage.objects';
  execute 'create policy "sc branding admin delete" on storage.objects for delete to authenticated using (bucket_id=''branding'' and public.is_admin(auth.uid()))';
  raise notice 'Branding bucket ready: public-read "branding" (admin-only writes, 200KB cap).';
exception when others then
  raise notice 'Branding bucket setup skipped (%). Create a public bucket named "branding" from Dashboard -> Storage instead.', sqlerrm;
end
$branding$;
select 'Branding bucket installed ✅' as status;
