-- ============================================================
-- V6.9 — BULLETPROOF SCORE SAVING (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- Fixes the persistent "new row violates row-level security policy
-- for table report_scores" seen by teachers on the subject broadsheet.
--
-- WHY IT KEPT FAILING (expert diagnosis):
--  1. The page uses UPSERT. Under Postgres RLS an upsert must pass
--     THREE policies at once (SELECT on the conflicting row, then
--     INSERT's WITH CHECK or UPDATE's USING+WITH CHECK). The old
--     SELECT policy still hard-required teacher_can_manage_subject_class(),
--     so a teacher whose subject↔teacher mapping is imperfect could not
--     even "see" the conflicting row — the upsert then exploded with the
--     generic RLS message no matter what the INSERT policy said.
--  2. SQL-file ordering traps: running an older complete-schema.sql AFTER
--     v6.3-role-access-fixes.sql silently re-installed the restrictive
--     policies. Any run order left some installs broken.
--
-- THE FIX — remove the fragility class entirely:
--  A. A SECURITY-DEFINER RPC (sc_save_report_score) now performs the save
--     server-side. RLS/upsert mechanics can no longer produce the error;
--     the permission contract is enforced INSIDE the function:
--       • caller must be approved staff/teacher/admin;
--       • a row already entered by ANOTHER teacher is locked (skipped with
--         a clear per-row message) unless the caller is admin-tier;
--       • updated_by is stamped server-side from auth.uid() — a slow
--         profile load can never send updated_by=null again.
--  B. The SELECT policy is relaxed so every approved staff member can READ
--     report scores (teachers must see class broadsheets anyway); students/
--     parents still only see their own rows.
--  C. The v6.3 write policies are re-asserted LAST so they win regardless
--     of which files were run in which order.
-- This file is ALREADY embedded inside complete-schema.sql (at the end, so
-- it always wins). Run it standalone on any database installed earlier.
-- ============================================================

-- ---------- B. staff-wide read (family rows stay scoped) ----------
drop policy if exists report_score_scope_select on public.report_scores;
create policy report_score_scope_select on public.report_scores
for select using (
  public.is_staff(auth.uid())
  or exists (select 1 from public.students s
              where (s.id = report_scores.student_id or s.admission_no = report_scores.student_id_ref)
                and (s.user_id = auth.uid() or public.is_parent_of(auth.uid(), s.id)))
);

-- ---------- C. re-assert the v6.3 write contract (order-proof) ----------
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
  or (public.is_staff(auth.uid()) and (updated_by = auth.uid() or updated_by is null))
) with check (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and coalesce(updated_by, auth.uid()) = auth.uid())
);
drop policy if exists report_score_scope_delete on public.report_scores;
create policy report_score_scope_delete on public.report_scores
for delete using (
  public.is_admin(auth.uid())
  or (public.is_staff(auth.uid()) and (updated_by = auth.uid() or updated_by is null))
);

-- ---------- A. the bulletproof save RPC ----------
create or replace function public.sc_save_report_score(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r jsonb; saved int := 0; blocked int := 0; errs text[] := '{}';
  existing public.report_scores%rowtype; uid uuid := auth.uid();
begin
  if uid is null or not public.is_staff(uid) then
    return jsonb_build_object('ok', false, 'error',
      'Staff/admin role required. If you just signed up, an admin must approve your account first (Approvals page).');
  end if;
  for r in select * from jsonb_array_elements(
             case when jsonb_typeof(p_rows) = 'array' then p_rows else jsonb_build_array(p_rows) end)
  loop
    begin
      if coalesce(r->>'column_id','') = '' then
        blocked := blocked + 1; errs := array_append(errs, 'row without column_id skipped'); continue;
      end if;
      select * into existing from public.report_scores
       where column_id = (r->>'column_id')::uuid
         and student_id_ref = coalesce(r->>'student_id_ref','')
         and student_name   = coalesce(r->>'student_name','')
         and class          = coalesce(r->>'class','')
         and subject        = coalesce(r->>'subject','')
         and term           = coalesce(r->>'term','')
         and session        = coalesce(r->>'session','')
       limit 1;
      if found and not public.is_admin(uid)
         and existing.updated_by is not null and existing.updated_by <> uid then
        blocked := blocked + 1;
        errs := array_append(errs, coalesce(nullif(r->>'student_name',''),'A row')
          || ' — locked: this score was entered by another teacher. Ask an administrator to change it.');
        continue;
      end if;
      insert into public.report_scores
        (column_id, student_id, student_id_ref, student_name, class, subject, term, session,
         score, source, updated_by, updated_at)
      values
        ((r->>'column_id')::uuid,
         nullif(r->>'student_id','')::uuid,
         coalesce(r->>'student_id_ref',''), coalesce(r->>'student_name',''),
         coalesce(r->>'class',''), coalesce(r->>'subject',''),
         coalesce(r->>'term',''), coalesce(r->>'session',''),
         coalesce((r->>'score')::numeric, 0), coalesce(nullif(r->>'source',''),'manual'),
         uid, now())
      on conflict (column_id, student_id_ref, student_name, class, subject, term, session)
      do update set score = excluded.score, updated_by = uid, updated_at = now(),
                    source = excluded.source,
                    student_id = coalesce(excluded.student_id, report_scores.student_id);
      saved := saved + 1;
    exception when others then
      blocked := blocked + 1; errs := array_append(errs, sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'saved', saved, 'blocked', blocked, 'errors', to_jsonb(errs));
end $$;
revoke execute on function public.sc_save_report_score(jsonb) from public, anon;
grant  execute on function public.sc_save_report_score(jsonb) to authenticated;

notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V6.9 bulletproof score saving installed ✅' as status;
