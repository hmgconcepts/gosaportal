-- ============================================================================
-- School Connect V7.6 — Term-History Access + Graduate→Alumni pipeline
-- ============================================================================
-- Issue (educator workflow): in a NEW term the admin could no longer regenerate
-- PREVIOUS terms' records. The client-side root cause (report-engine roster
-- gate matching only the CURRENT class roster, so promoted/graduated students'
-- old scores vanished) is fixed in assets/js/report-engine.js + report-cards.
-- This pack adds the database side:
--   1. History indexes — term/session/class lookups on the four "history"
--      tables stay fast as years of data accumulate (free-tier friendly).
--   2. Graduate→Alumni pipeline — "Apply promotions" now files every
--      graduating student into the Alumni register automatically (name,
--      last class, graduation year from the session), so records survive
--      even after the student later leaves the active register.
-- Idempotent: safe to run repeatedly on any School Connect database.
-- ============================================================================

-- ---------- 1. history indexes ----------------------------------------------
create index if not exists idx_results_hist       on public.results       (session, term, class);
create index if not exists idx_report_scores_hist on public.report_scores (session, term, class);
create index if not exists idx_fee_payments_hist  on public.fee_payments  (session, term);
create index if not exists idx_attendance_hist    on public.attendance    (class, date);
create index if not exists idx_promotions_hist    on public.promotions    (session, term, status);

-- ---------- 2. finalise promotions: graduates flow into alumni ---------------
create or replace function public.sc_finalise_promotions()
returns jsonb language plpgsql security definer set search_path=public as $$
declare r record; moved int:=0; grads int:=0; repeats int:=0; failed int:=0;
        cur_term text:=''; cur_session text:=''; grad_year int; s record;
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admin role required.'; end if;
  select term, session into cur_term, cur_session from public.academic_periods where is_current = true limit 1;
  -- graduation year = second half of the session ("2025/2026" -> 2026); fallback: this year
  grad_year := coalesce(nullif(split_part(coalesce(cur_session,''), '/', 2), '')::int,
                        extract(year from now())::int);
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
          select id, full_name, class into s from public.students where id = r.student_id;
          update public.students set status = 'graduated' where id = r.student_id;
        else
          select id, full_name, class into s from public.students where lower(full_name) = lower(r.student_name) limit 1;
          update public.students set status = 'graduated' where lower(full_name) = lower(r.student_name);
        end if;
        if not found then failed := failed + 1; continue; end if;
        grads := grads + 1;
        -- V7.6: automatic Alumni record (skip when an equivalent row exists)
        if s.full_name is not null and not exists (
             select 1 from public.alumni a
              where lower(a.full_name) = lower(s.full_name)
                and coalesce(a.graduation_year,0) = grad_year) then
          insert into public.alumni (full_name, graduation_year, last_class, current_occupation)
          values (s.full_name, grad_year, coalesce(s.class, r.from_class), '');
        end if;
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
                            'term', cur_term, 'session', cur_session,
                            'alumni_year', grad_year);
end$$;
revoke execute on function public.sc_finalise_promotions() from public, anon;
grant execute on function public.sc_finalise_promotions() to authenticated;

select 'V7.6 history indexes + graduate-to-alumni pipeline installed' as status;
