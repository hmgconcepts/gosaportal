-- ============================================================================
-- School Connect V10.5 — Digital Library ⇄ CBT link
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql (or any earlier pack) on an EXISTING database.
-- Fresh installs get this from complete-schema.sql automatically.
--
-- WHAT THIS PACK DOES
-- A reading in the 📚 Digital Library can now carry a LINKED CBT EXAM
-- (digital_library.cbt_code) alongside — never instead of — its embedded
-- "❓ Comprehension questions". The linked CBT is the full engine: timed,
-- anti-cheat, own exam code, server-side grading. Students get a 🧪 Take CBT
-- button on the reading card; the 🚀 push-to-report-card engine on the
-- library page now merges linked-CBT results with embedded-quiz scores, so
-- BOTH kinds of assessment accumulate into the same report-card column.
-- ============================================================================
select 'RUNNING: School Connect Digital Library CBT link pack V10.5' as running_version;

alter table public.digital_library add column if not exists cbt_code text default '';
create index if not exists idx_digital_library_cbt_code on public.digital_library (cbt_code) where cbt_code <> '';

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.5 Digital Library CBT link pack installed' as status;
