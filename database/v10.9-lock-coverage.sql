-- ============================================================================
-- School Connect V10.9 — Report-lock full coverage (every report component)
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql (or any earlier pack) on an EXISTING database.
-- Fresh installs get all of this from complete-schema.sql automatically.
--
-- WHAT THIS PACK DOES (pass-57 issue 2)
-- V10.7/10.8 blanked report_scores, report_cards, results and cbt_results for
-- report-locked families. This audit found FOUR more surfaces a report card
-- is assembled from that still had wide-open family reads:
--   • affective_traits      (read: any authenticated user!)
--   • psychomotor_traits    (read: any authenticated user!)
--   • report_comments       (read: any authenticated user!)
--   • student_term_metrics  (family read, no lock check)
-- Beyond the lock, the first three were a privacy hole — ANY signed-in
-- student could read ANY student's traits and teacher comments. Both fixed
-- in one move: family reads are now scoped to OWN children AND honour
-- sc_report_hidden_for; staff keep full access.
-- ============================================================================
select 'RUNNING: School Connect lock-coverage pack V10.9' as running_version;

drop policy if exists "affective_traits_read" on public.affective_traits;
create policy "affective_traits_read" on public.affective_traits for select using (
  public.is_staff(auth.uid())
  or exists(select 1 from public.students s where s.id=affective_traits.student_id
        and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))
        and not public.sc_report_hidden_for(auth.uid(), s.id))
);

drop policy if exists "psychomotor_traits_read" on public.psychomotor_traits;
create policy "psychomotor_traits_read" on public.psychomotor_traits for select using (
  public.is_staff(auth.uid())
  or exists(select 1 from public.students s where s.id=psychomotor_traits.student_id
        and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))
        and not public.sc_report_hidden_for(auth.uid(), s.id))
);

drop policy if exists "report_comments_read" on public.report_comments;
create policy "report_comments_read" on public.report_comments for select using (
  public.is_staff(auth.uid())
  or exists(select 1 from public.students s where s.id=report_comments.student_id
        and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))
        and not public.sc_report_hidden_for(auth.uid(), s.id))
);

drop policy if exists metrics_family_read on public.student_term_metrics;
create policy metrics_family_read on public.student_term_metrics for select using (
  exists(select 1 from public.students s where s.id=student_term_metrics.student_id
     and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))
     and not public.sc_report_hidden_for(auth.uid(), s.id))
);

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.9 lock-coverage pack installed' as status;
