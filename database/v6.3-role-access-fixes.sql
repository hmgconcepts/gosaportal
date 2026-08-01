-- ============================================================
-- V6.3 ROLE-ACCESS & WORKFLOW FIXES (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Fixes reported on the live sites:
--  1. "new row violates row-level security policy for table report_scores"
--     when a teacher saves scores in the subject broadsheet.
--  6. Leave management: staff request; ONLY admin approves/rejects.
--  8. Assessment columns: ONLY admin creates/edits/deletes report-card
--     columns; teachers only enter scores.
-- 10. Affective/Psychomotor/Report-comments: every staff/teacher gets
--     read/write (own rows), admin full control.
-- 11. Substitutions: staff read-only; admin writes.
-- 21. Private "proctor" storage bucket for CBT snapshot monitoring.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this release.
-- ============================================================

-- ---------- 1. report_scores: teachers save scores without RLS rejection ----
-- Root cause: the old insert policy demanded teacher_can_manage_subject_class(),
-- which returns false whenever the subject/class assignment mapping is
-- incomplete (very common in real schools: subjects registered without a
-- teacher, teacher name spelled differently in staff vs subjects, etc.).
-- New contract: any approved staff/teacher may INSERT scores they author
-- (updated_by = themselves). UPDATE/DELETE stay owner-or-admin, with the
-- assignment check as an OR (not a hard gate) so class/subject teachers
-- can still claim legacy unowned rows.
drop policy if exists report_score_scope_insert on public.report_scores;
create policy report_score_scope_insert on public.report_scores
for insert with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid())
);
drop policy if exists report_score_scope_update on public.report_scores;
create policy report_score_scope_update on public.report_scores
for update using (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and (updated_by = auth.uid()
      or (updated_by is null and public.teacher_can_manage_subject_class(auth.uid(),subject,class))))
) with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid())
);
drop policy if exists report_score_scope_delete on public.report_scores;
create policy report_score_scope_delete on public.report_scores
for delete using (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and (updated_by = auth.uid()
      or (updated_by is null and public.teacher_can_manage_subject_class(auth.uid(),subject,class))))
);

-- ---------- 8. assessment_columns: ADMIN-ONLY structure control -------------
alter table public.assessment_columns enable row level security;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='assessment_columns' loop
    execute format('drop policy if exists %I on public.assessment_columns', p.policyname);
  end loop;
end $$;
create policy ac_read_all on public.assessment_columns
for select using (auth.role() = 'authenticated');
create policy ac_admin_write on public.assessment_columns
for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- 6. leave_requests: staff request, ONLY admin approves -----------
alter table public.leave_requests add column if not exists requested_by uuid references public.profiles(id) on delete set null;
alter table public.leave_requests add column if not exists decided_by uuid references public.profiles(id) on delete set null;
alter table public.leave_requests add column if not exists decided_at timestamptz;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='leave_requests' loop
    execute format('drop policy if exists %I on public.leave_requests', p.policyname);
  end loop;
end $$;
-- Staff see their own requests; admins see all.
create policy lr_read on public.leave_requests
for select using (
  public.is_admin(auth.uid())
  or requested_by = auth.uid()
  or staff_id in (select id from public.staff where user_id = auth.uid())
);
-- Staff submit ONLY pending requests, stamped as their own.
create policy lr_insert on public.leave_requests
for insert with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid())
      and coalesce(requested_by, auth.uid()) = auth.uid()
      and coalesce(status,'pending') = 'pending')
);
-- Staff may edit their OWN request only while it is still pending —
-- and can never flip the status themselves. Admin has full control.
create policy lr_update_own_pending on public.leave_requests
for update using (
  requested_by = auth.uid() and status = 'pending' and not public.is_admin(auth.uid())
) with check (
  requested_by = auth.uid() and status = 'pending'
);
create policy lr_admin_all on public.leave_requests
for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));
-- Approval stamp: whenever status changes, record who decided and when.
create or replace function public.lr_stamp_decision()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status is distinct from old.status and new.status in ('approved','rejected') then
    if not public.is_admin(auth.uid()) then
      raise exception 'Only an administrator can approve or reject leave requests.';
    end if;
    new.decided_by := auth.uid(); new.decided_at := now();
  end if;
  return new;
end $$;
drop trigger if exists trg_lr_stamp on public.leave_requests;
create trigger trg_lr_stamp before update on public.leave_requests
for each row execute function public.lr_stamp_decision();

-- ---------- 10. traits & comments: every staff/teacher can read/write -------
-- (own rows; admin overrides). The old policy hard-required the
-- teacher↔student assignment mapping, silently locking out legitimate staff.
drop policy if exists affective_scope_write on public.affective_traits;
create policy affective_scope_write on public.affective_traits
for all using (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and (teacher_id = auth.uid() or teacher_id is null))
) with check (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and coalesce(teacher_id, auth.uid()) = auth.uid())
);
drop policy if exists psychomotor_scope_write on public.psychomotor_traits;
create policy psychomotor_scope_write on public.psychomotor_traits
for all using (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and (teacher_id = auth.uid() or teacher_id is null))
) with check (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and coalesce(teacher_id, auth.uid()) = auth.uid())
);
drop policy if exists comments_scope_write on public.report_comments;
create policy comments_scope_write on public.report_comments
for all using (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and (teacher_id = auth.uid() or teacher_id is null))
) with check (
  public.is_admin(auth.uid()) or (public.is_staff(auth.uid()) and coalesce(teacher_id, auth.uid()) = auth.uid())
);

-- ---------- 11. substitutions: staff READ, admin WRITE ----------------------
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='substitutions' loop
    execute format('drop policy if exists %I on public.substitutions', p.policyname);
  end loop;
end $$;
create policy subs_staff_read on public.substitutions
for select using (public.is_staff(auth.uid()));
create policy subs_admin_write on public.substitutions
for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- 9/17. fee_payments: re-assert the family-safe contract ----------
-- Students see ONLY their own payments; parents only their children's;
-- bursar (inside is_staff/is_admin) keeps full read/write.
drop policy if exists "fp_read" on fee_payments;
create policy "fp_read" on public.fee_payments for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
drop policy if exists "fp_write" on fee_payments;
create policy "fp_write" on public.fee_payments for all
using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------- 21. CBT proctoring media bucket (snapshots → File Storage) ------
do $proctor$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema not present (local test database) — proctor bucket skipped.';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('proctor', 'proctor', false, 512000, array['image/jpeg','image/webp'])
  on conflict (id) do nothing;
  -- Students (any authenticated exam-taker) may UPLOAD snapshots only;
  -- they can never list, view or delete them. Staff/teachers review and
  -- delete; admins keep full control.
  execute 'drop policy if exists "sc proctor upload" on storage.objects';
  execute 'create policy "sc proctor upload" on storage.objects for insert to authenticated with check (bucket_id=''proctor'')';
  execute 'drop policy if exists "sc proctor staff read" on storage.objects';
  execute 'create policy "sc proctor staff read" on storage.objects for select to authenticated using (bucket_id=''proctor'' and public.is_staff(auth.uid()))';
  execute 'drop policy if exists "sc proctor staff delete" on storage.objects';
  execute 'create policy "sc proctor staff delete" on storage.objects for delete to authenticated using (bucket_id=''proctor'' and public.is_staff(auth.uid()))';
  raise notice 'CBT proctoring bucket ready: private "proctor" (student upload-only, staff review/delete).';
exception when others then
  raise notice 'Proctor bucket setup skipped (%). Create a private bucket named "proctor" from Dashboard -> Storage instead.', sqlerrm;
end
$proctor$;

notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V6.3 role-access & workflow fixes installed ✅' as status;
