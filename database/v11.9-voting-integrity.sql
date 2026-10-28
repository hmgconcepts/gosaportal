-- ============================================================================
-- School Connect V11.9 — VOTING INTEGRITY PACK (pass 67)
-- ----------------------------------------------------------------------------
-- Designed like a real electoral commission would demand:
--
-- 1. THE 0% BUG, killed at the ROOT: results are now tallied SERVER-SIDE by
--    sc_poll_results() (SECURITY DEFINER). The old client-side tally broke two
--    ways: (a) the page selected a non-existent poll_votes.created_at column
--    (42703, silently swallowed → empty votes → 0% for everyone), and
--    (b) pv_read RLS only shows a voter their OWN ballot, so non-staff could
--    never see a correct tally anyway. The RPC returns AGGREGATES ONLY —
--    counts, percentages, turnout — never individual ballots, so anonymous
--    elections stay anonymous even for admins.
--
-- 2. STRICT AUDIENCE ENFORCEMENT: sc_can_vote loses its admin bypass. A
--    students-only ballot accepts ONLY students; parents-only ONLY parents;
--    staff-only ONLY staff — no exception for admins ("test-voting" polluted
--    real ballots). Enforced in RLS, not just hidden in the UI.
--
-- 3. ONE MANAGER PER BALLOT: the stray V11-era permissive policies
--    (polls_update_v11: ANY staff could edit ANY poll; pv_delete_v11: ANY
--    staff could delete ANY ballot) are DROPPED. Permissive policies OR
--    together in PostgreSQL, so their mere existence defeated the good
--    creator-scoped V8.2 policies. Now: only the CREATOR or an admin edits/
--    closes/deletes a poll; a voter may withdraw their own ballot while the
--    poll is open (revote), and ballot deletion by staff is creator/admin-only.
--
-- 4. ELIGIBLE-VOTER TURNOUT: sc_poll_results also reports how many people
--    were ELIGIBLE (audience size), so results read like a real election:
--    "62 of 118 eligible students voted (52.5% turnout)".
--
-- Idempotent — safe to run repeatedly.
-- ============================================================================
select 'RUNNING: School Connect voting-integrity pack V11.9' as running_version;

-- ---------------------------------------------------------------------------
-- 1+2. Audience gate WITHOUT the admin bypass (supersedes the V8.2 body).
-- ---------------------------------------------------------------------------
create or replace function public.sc_can_vote(p_poll uuid)
returns boolean language plpgsql security definer stable set search_path=public as $$
declare pol record; my_role text; my_class text;
begin
  select * into pol from public.polls where id = p_poll;
  if pol.id is null then return false; end if;
  if coalesce(pol.status,'open') <> 'open' then return false; end if;
  if pol.closes_at is not null and now() > pol.closes_at then return false; end if;
  select lower(coalesce(role,'')) into my_role from public.profiles where id = auth.uid();
  -- V11.9: STRICT audience gate — NO admin bypass. A students-only ballot is
  -- for students, full stop. (Admins still SEE results; they just cannot vote.)
  if coalesce(pol.audience,'all') in ('','all','everyone') then null;
  elsif pol.audience in ('students','student') then
    if my_role <> 'student' then return false; end if;
  elsif pol.audience in ('parents','parent') then
    if my_role <> 'parent' then return false; end if;
  elsif pol.audience in ('staff','teachers','teacher') then
    if my_role not in ('staff','teacher','super_admin','admin','principal','proprietor','head_teacher','bursar') then return false; end if;
  end if;
  -- class gate: class-scoped ballots accept only students OF that class
  if coalesce(pol.class_scope,'') <> '' then
    if my_role <> 'student' then return false; end if;
    select class into my_class from public.students where user_id = auth.uid() limit 1;
    if lower(regexp_replace(coalesce(my_class,''),'\s+','','g'))
       <> lower(regexp_replace(pol.class_scope,'\s+','','g')) then return false; end if;
  end if;
  return true;
end$$;
revoke execute on function public.sc_can_vote(uuid) from public, anon;
grant execute on function public.sc_can_vote(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 1+4. Server-side tally: aggregates only, never individual ballots.
-- ---------------------------------------------------------------------------
create or replace function public.sc_poll_results(p_poll uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare pol record; v_total int; v_voters int; v_eligible int; v_tally jsonb; v_roles jsonb;
begin
  select * into pol from public.polls where id = p_poll;
  if pol.id is null then return jsonb_build_object('ok',false,'error','Poll not found.'); end if;

  select count(*), count(distinct voter_id) into v_total, v_voters
    from public.poll_votes where poll_id = p_poll;

  -- per-candidate counts (works for both real votes and zero-vote candidates,
  -- because the client merges this over the poll's candidate list)
  select coalesce(jsonb_object_agg(candidate_id, n), '{}'::jsonb) into v_tally
    from (select candidate_id, count(*) n from public.poll_votes
          where poll_id = p_poll group by candidate_id) t;

  -- turnout denominator: how many people were ELIGIBLE for this ballot
  if coalesce(pol.class_scope,'') <> '' then
    select count(*) into v_eligible from public.students s
      where coalesce(s.status,'active') = 'active'
        and lower(regexp_replace(coalesce(s.class,''),'\s+','','g'))
          = lower(regexp_replace(pol.class_scope,'\s+','','g'));
  elsif pol.audience in ('students','student') then
    select count(*) into v_eligible from public.students where coalesce(status,'active') = 'active';
  elsif pol.audience in ('parents','parent') then
    select count(*) into v_eligible from public.profiles where lower(coalesce(role,'')) = 'parent' and status in ('approved','active');
  elsif pol.audience in ('staff','teachers','teacher') then
    select count(*) into v_eligible from public.staff where coalesce(status,'active') = 'active';
  else
    select count(*) into v_eligible from public.profiles where status in ('approved','active');
  end if;

  -- role breakdown of ballots (aggregate only — no identities). Skipped for
  -- anonymous ballots where even the role slice could deanonymise tiny groups.
  if coalesce(pol.anonymous,false) then
    v_roles := '{}'::jsonb;
  else
    select coalesce(jsonb_object_agg(r, n), '{}'::jsonb) into v_roles
      from (select lower(coalesce(pr.role,'unknown')) r, count(distinct pv.voter_id) n
              from public.poll_votes pv left join public.profiles pr on pr.id = pv.voter_id
             where pv.poll_id = p_poll group by 1) t;
  end if;

  return jsonb_build_object(
    'ok', true,
    'poll_id', pol.id,
    'status', coalesce(pol.status,'open'),
    'anonymous', coalesce(pol.anonymous,false),
    'total_ballots', coalesce(v_total,0),
    'unique_voters', coalesce(v_voters,0),
    'eligible', coalesce(v_eligible,0),
    'turnout_pct', case when coalesce(v_eligible,0) > 0
        then round(coalesce(v_voters,0)::numeric * 100 / v_eligible, 1) else null end,
    'tally', coalesce(v_tally,'{}'::jsonb),
    'by_role', coalesce(v_roles,'{}'::jsonb),
    'my_ballot', coalesce((select jsonb_agg(candidate_id) from public.poll_votes
                            where poll_id = p_poll and voter_id = auth.uid()), '[]'::jsonb),
    'server_time', now()
  );
end$$;
revoke execute on function public.sc_poll_results(uuid) from public, anon;
grant execute on function public.sc_poll_results(uuid) to authenticated;


-- (relocated from the V8.2 section: the policy references sc_can_vote, which is
--  defined in THIS pack — creating it here keeps fresh installs working.)
drop policy if exists "pv_insert" on public.poll_votes;
create policy "pv_insert" on public.poll_votes for insert with check (
  auth.uid() = voter_id and public.sc_can_vote(poll_id)
);

-- ---------------------------------------------------------------------------
-- 3. Kill the stray permissive policies; assert the creator-scoped set.
-- ---------------------------------------------------------------------------
drop policy if exists "polls_update_v11" on public.polls;   -- ANY staff could edit ANY poll
drop policy if exists "polls_delete_v11" on public.polls;   -- superseded by creator/admin rule
drop policy if exists "pv_delete_v11" on public.poll_votes; -- ANY staff could delete ANY ballot

drop policy if exists "polls_update" on public.polls;
create policy "polls_update" on public.polls for update
  using (public.is_admin(auth.uid()) or created_by = auth.uid())
  with check (public.is_admin(auth.uid()) or created_by = auth.uid());

drop policy if exists "polls_delete" on public.polls;
create policy "polls_delete" on public.polls for delete
  using (public.is_admin(auth.uid()) or created_by = auth.uid());

-- A voter may withdraw/replace their OWN ballot while the poll is open
-- (this is what makes revoting work); the poll creator or an admin may clear
-- ballots (e.g. void a test run before opening); nobody else deletes anything.
drop policy if exists "pv_delete" on public.poll_votes;
create policy "pv_delete" on public.poll_votes for delete using (
  (auth.uid() = voter_id and exists (select 1 from public.polls p
      where p.id = poll_id and coalesce(p.status,'open') = 'open'))
  or public.is_admin(auth.uid())
  or exists (select 1 from public.polls p where p.id = poll_id and p.created_by = auth.uid())
);

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V11.9 voting-integrity pack installed' as status;
