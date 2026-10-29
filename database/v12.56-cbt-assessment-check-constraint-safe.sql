-- ============================================================================
-- School Connect V12.56 — unblock canonical Midterm purpose on existing DBs
--
-- Fixes upgrade error 23514 when an existing enum-style
-- cbt_exams_assessment_type_check rejects assessment_type='midterm'. Dropping
-- this CHECK does not delete or rewrite records; the idempotent update below
-- only canonicalizes known legacy CA/Test values. The app dropdown validates
-- new purpose values. Existing unrelated purpose strings remain untouched.
-- Safe to run alone before re-running complete-schema.sql, or repeatedly.
-- ============================================================================
select 'RUNNING: School Connect CBT assessment-type check compatibility V12.56' as running_version;

alter table public.cbt_exams drop constraint if exists cbt_exams_assessment_type_check;

update public.cbt_exams
   set assessment_type='midterm',updated_at=now()
 where regexp_replace(lower(trim(coalesce(assessment_type,''))),'[^a-z0-9]','','g')
       in ('ca','test','midtermca','midtermtest','midtermassessment','midtermcolumn')
   and lower(trim(coalesce(assessment_type,'')))<>'midterm';

insert into public.sc_install_state(key,details)
values ('v12.56-cbt-assessment-check-constraint-safe.sql','{"self":true}')
on conflict(key) do nothing;
notify pgrst,'reload schema';
select pg_notify('pgrst','reload schema');
select 'V12.56 removed only the narrow assessment-type CHECK and retained all CBT records' as status;
