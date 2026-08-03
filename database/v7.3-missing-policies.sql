-- ============================================================
-- V7.3 — MISSING POLICIES + PROMOTION FINALISER (idempotent)
-- ------------------------------------------------------------
-- Root-cause fixes:
--  A. admission_links & staff_bonus had RLS ENABLED but NO policies
--     → default deny for everyone (even admins). This is why those
--     pages stayed empty and every sample-data loader silently
--     failed on them. Proper policies installed.
--  B. sc_finalise_promotions(): server-side "Apply promotions" —
--     moves students by id, stamps status='applied' + the current
--     period, and marks graduates; returns per-action counts. The
--     page keeps its preview and calls this one RPC (fallback to
--     the old loop when the RPC is missing).
-- This file is ALREADY embedded inside complete-schema.sql; run it
-- standalone only on databases installed before this release.
-- ============================================================

-- ---------- A. admission_links ----------
drop policy if exists adl_read on public.admission_links;
create policy adl_read on public.admission_links for select using (true); -- tokens are public application URLs
drop policy if exists adl_admin_write on public.admission_links;
create policy adl_admin_write on public.admission_links for all
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- A2. staff_bonus ----------
drop policy if exists sbn_staff_read on public.staff_bonus;
create policy sbn_staff_read on public.staff_bonus for select using (public.is_staff(auth.uid()));
drop policy if exists sbn_admin_write on public.staff_bonus;
create policy sbn_admin_write on public.staff_bonus for all
using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------- B. one-call promotion finaliser ----------
create or replace function public.sc_finalise_promotions()
returns jsonb language plpgsql security definer set search_path=public as $$
declare r record; moved int:=0; grads int:=0; repeats int:=0; failed int:=0;
        cur_term text:=''; cur_session text:='';
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admin role required.'; end if;
  select term, session into cur_term, cur_session from public.academic_periods where is_current = true limit 1;
  for r in select * from public.promotions where status in ('draft','approved')
             and lower(coalesce(action,'')) in ('promote','graduate','repeat')
  loop
    begin
      if r.action = 'promote' then
        if r.student_id is not null then
          update public.students set class = r.to_class where id = r.student_id;
        else
          update public.students set class = r.to_class where lower(full_name) = lower(r.student_name);
        end if;
        if not found then failed := failed + 1; continue; end if;
        moved := moved + 1;
      elsif r.action = 'graduate' then
        if r.student_id is not null then
          update public.students set status = 'graduated' where id = r.student_id;
        else
          update public.students set status = 'graduated' where lower(full_name) = lower(r.student_name);
        end if;
        if not found then failed := failed + 1; continue; end if;
        grads := grads + 1;
      else
        repeats := repeats + 1;
      end if;
      update public.promotions
         set status = 'applied',
             term    = coalesce(nullif(term,''), cur_term, ''),
             session = coalesce(nullif(session,''), cur_session, '')
       where id = r.id;
    exception when others then failed := failed + 1;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'promoted', moved, 'graduated', grads,
                            'repeated', repeats, 'failed', failed,
                            'term', cur_term, 'session', cur_session);
end $$;
revoke execute on function public.sc_finalise_promotions() from public, anon;
grant  execute on function public.sc_finalise_promotions() to authenticated;

notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V7.3 missing policies + promotion finaliser installed ✅' as status;
