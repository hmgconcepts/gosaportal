-- School Connect v16 — ownership and family-read hardening
-- Apply to an existing database after v15. Fresh installs include it via complete-schema.sql.

-- Teachers may create only records attributed to themselves; an administrator keeps override.
drop policy if exists "results_insert_v5" on public.results;
create policy "results_insert_v16_owner" on public.results for insert with check (public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and teacher_id = auth.uid()));
drop policy if exists "results_update_v5" on public.results;
create policy "results_update_v16_owner" on public.results for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid()) with check (public.is_admin(auth.uid()) or teacher_id = auth.uid());
drop policy if exists "results_delete_v5" on public.results;
create policy "results_delete_v16_owner" on public.results for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid());

-- module_records backs several enterprise pages. The old broad staff ALL policy
-- allowed one teacher to modify another teacher's record. Keep creation and own-record editing only.
drop policy if exists "mr_write_staff" on public.module_records;
drop policy if exists "mr_delete_v12_owner" on public.module_records;
create policy "mr_insert_v16_owner" on public.module_records for insert with check (public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and created_by = auth.uid()));
create policy "mr_update_v16_owner" on public.module_records for update using (public.is_admin(auth.uid()) or created_by = auth.uid()) with check (public.is_admin(auth.uid()) or created_by = auth.uid());
create policy "mr_delete_v16_owner" on public.module_records for delete using (public.is_admin(auth.uid()) or created_by = auth.uid());

-- Parents can read attendance for linked children; students only their own record. No family write policy is introduced.
drop policy if exists "attendance_parent_read_v16" on public.attendance;
create policy "attendance_parent_read_v16" on public.attendance for select using (
  student_id = auth.uid() or exists (select 1 from public.students s where s.id = attendance.student_id and s.user_id = auth.uid())
  or exists (select 1 from public.parent_child pc where pc.student_id = attendance.student_id and pc.parent_id = auth.uid())
);

-- Report-score ownership: a subject teacher cannot overwrite another teacher's marks.
alter table public.report_scores add column if not exists updated_by uuid references public.profiles(id) default auth.uid();
drop policy if exists "rs_staff" on public.report_scores;
drop policy if exists "rs_insert_v16_owner" on public.report_scores;
drop policy if exists "rs_update_v16_owner" on public.report_scores;
drop policy if exists "rs_delete_v16_owner" on public.report_scores;
create policy "rs_insert_v16_owner" on public.report_scores for insert with check (public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and updated_by = auth.uid()));
create policy "rs_update_v16_owner" on public.report_scores for update using (public.is_admin(auth.uid()) or updated_by = auth.uid()) with check (public.is_admin(auth.uid()) or updated_by = auth.uid());
create policy "rs_delete_v16_owner" on public.report_scores for delete using (public.is_admin(auth.uid()) or updated_by = auth.uid());
