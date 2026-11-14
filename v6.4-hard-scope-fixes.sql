-- ============================================================
-- V6.4 HARD-SCOPE FIXES (idempotent — safe to re-run)
-- ------------------------------------------------------------
-- 4. fee_payments: drop EVERY policy (including legacy permissive
--    ones from old installs) and re-create exactly two:
--    family-scoped read + staff write. Guarantees a student can
--    NEVER read another student's payments at database level.
-- 2. Punctuality → report card: new RPC that writes the summed
--    points into REPORT_SCORES against an ADMIN-CREATED assessment
--    column (column_id), so the push uses the school's own report
--    template — never a hard-coded ca1/ca2 list.
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this release.
-- ============================================================

-- ---------- 4. fee_payments total policy reset ----------
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='fee_payments' loop
    execute format('drop policy if exists %I on public.fee_payments', p.policyname);
  end loop;
end $$;
create policy "fp_read" on public.fee_payments for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
create policy "fp_write" on public.fee_payments for all
using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- Same total reset for payment_intents (online payment references).
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='payment_intents' loop
    execute format('drop policy if exists %I on public.payment_intents', p.policyname);
  end loop;
end $$;
create policy "pi_read" on public.payment_intents for select using (
  public.is_parent_of(auth.uid(), student_id)
  or student_id in (select id from public.students where user_id = auth.uid())
  or public.is_staff(auth.uid())
);
create policy "pi_write" on public.payment_intents for all
using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------- 2. punctuality → ADMIN-CREATED report column ----------
-- Sums each student's punctuality points in the window and UPSERTS them into
-- report_scores under the admin-created assessment column (p_column_id).
-- Re-pushing the same scope updates the same rows (report_scores_uq).
create or replace function public.sc_push_punctuality_to_report(
  p_column_id uuid, p_term text, p_session text,
  p_class text default '', p_start date default null, p_end date default null,
  p_subject text default 'PUNCTUALITY')
returns int language plpgsql security definer set search_path=public as $$
declare saved int := 0; r record; colrec record;
begin
  if not public.is_staff(auth.uid()) then
    raise exception 'Staff/admin role required.';
  end if;
  select id, name, max_mark into colrec from public.assessment_columns where id = p_column_id;
  if not found then
    raise exception 'That report-card column no longer exists. Ask the admin to create columns on the Report Cards page first.';
  end if;
  for r in
    select a.student_id,
           max(a.student_name) as student_name, max(coalesce(a.student_id_ref,'')) as student_id_ref,
           coalesce(nullif(p_class,''), max(a.class)) as class,
           sum(a.points) as points
      from public.punctuality_awards a
      join public.students s on s.id = a.student_id
     where (p_class = '' or a.class = p_class or s.class = p_class)
       and (p_start is null or a.date >= p_start)
       and (p_end   is null or a.date <= p_end)
     group by a.student_id
  loop
    insert into public.report_scores
      (column_id, student_id, student_id_ref, student_name, class, subject, term, session, score, source, updated_by, updated_at)
    values
      (p_column_id, r.student_id, r.student_id_ref, coalesce(r.student_name,'Student'),
       coalesce(r.class,''), p_subject, coalesce(p_term,''), coalesce(p_session,''),
       r.points, 'punctuality', auth.uid(), now())
    on conflict (column_id, student_id_ref, student_name, class, subject, term, session)
    do update set score = excluded.score, updated_by = excluded.updated_by, updated_at = now(), source = 'punctuality';
    saved := saved + 1;
  end loop;
  return saved;
end $$;
revoke execute on function public.sc_push_punctuality_to_report(uuid,text,text,text,date,date,text) from public, anon;
grant  execute on function public.sc_push_punctuality_to_report(uuid,text,text,text,date,date,text) to authenticated;

notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V6.4 hard-scope fixes installed ✅' as status;
