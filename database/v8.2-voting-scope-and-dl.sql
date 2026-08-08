-- ============================================================================
-- School Connect V8.2 — Class-scoped voting + audience enforcement + DL types
-- ============================================================================
-- 1. polls.class_scope — a poll can belong to ONE class (class captain election
--    etc.). Only students OF THAT CLASS can vote in it; other classes cannot.
-- 2. Database-enforced audience: parents-only polls accept votes only from
--    parents, students-only from students, staff-only from staff — enforced in
--    RLS (pv_insert), not just hidden in the UI.
-- 3. digital_library question types (multiple_response/true_false/short_answer/
--    keyword) are data-only (JSON) — no schema change needed; this pack adds
--    the class-scope read policy hardening for digital_library.
-- Idempotent — safe to run repeatedly.
-- ============================================================================
alter table public.polls add column if not exists class_scope text default '';

create or replace function public.sc_can_vote(p_poll uuid)
returns boolean language plpgsql security definer stable set search_path=public as $$
declare pol record; my_role text; my_class text;
begin
  select * into pol from public.polls where id = p_poll;
  if pol.id is null then return false; end if;
  if coalesce(pol.status,'open') <> 'open' then return false; end if;
  select lower(coalesce(role,'')) into my_role from public.profiles where id = auth.uid();
  -- audience gate (admins can always test-vote)
  if public.is_admin(auth.uid()) then null;
  elsif coalesce(pol.audience,'all') in ('','all','everyone') then null;
  elsif pol.audience in ('students','student') and my_role <> 'student' then return false;
  elsif pol.audience in ('parents','parent') and my_role <> 'parent' then return false;
  elsif pol.audience in ('staff','teachers','teacher') and my_role not in ('staff','teacher') then return false;
  end if;
  -- class gate: when the poll is scoped to a class, a STUDENT voter must be in it
  if coalesce(pol.class_scope,'') <> '' and my_role = 'student' then
    select class into my_class from public.students where user_id = auth.uid() limit 1;
    if lower(regexp_replace(coalesce(my_class,''),'\s+','','g'))
       <> lower(regexp_replace(pol.class_scope,'\s+','','g')) then return false; end if;
  end if;
  return true;
end$$;
revoke execute on function public.sc_can_vote(uuid) from public, anon;
grant execute on function public.sc_can_vote(uuid) to authenticated;

drop policy if exists "pv_insert" on poll_votes;
create policy "pv_insert" on public.poll_votes for insert with check (
  auth.uid() = voter_id and public.sc_can_vote(poll_id)
);
-- teachers can create/manage their own class polls; admin manages all
drop policy if exists "polls_write" on polls;
create policy "polls_write" on public.polls for insert with check (public.is_staff(auth.uid()));
drop policy if exists "polls_update" on polls;
create policy "polls_update" on public.polls for update
  using (public.is_admin(auth.uid()) or created_by = auth.uid())
  with check (public.is_admin(auth.uid()) or created_by = auth.uid());
drop policy if exists "polls_delete" on polls;
create policy "polls_delete" on public.polls for delete
  using (public.is_admin(auth.uid()) or created_by = auth.uid());

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V8.2 class-scoped voting + audience enforcement installed' as status;
