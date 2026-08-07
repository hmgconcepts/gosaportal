-- ============================================================================
-- School Connect V7.9 — Flexible Timetable Engine + Assignment Class-Scope Reset
-- ============================================================================
-- PART 1 — TIMETABLE FLEXIBILITY (educator requirements):
--   • PERIOD-LEVEL part-time availability: a part-timer can be "Monday periods
--     1–3 and Thursday periods 4–6", not just "Monday and Thursday".
--   • BLOCKED SLOTS: free periods / clubs / games / assembly per class (or ALL
--     classes) on chosen day+period. The generator writes them into the grid
--     (e.g. "⛔ Sports & Clubs") and never schedules over them.
--   • PER-DAY PERIOD COUNTS: Friday (or any day) can have fewer periods than
--     Monday–Thursday via the new p_day_periods parameter, e.g. {"Friday":4}.
--   • Cross-class teacher conflicts remain checked (a teacher is never in two
--     classes at the same time, across every generated class).
-- PART 2 — ASSIGNMENT CLASS-SCOPE HARD RESET:
--   Old installs may still carry the permissive "read_assignments …
--   authenticated" policy from early schema versions, which let students see
--   other classes' homework. This pack force-drops EVERY select policy on
--   assignments and installs the single scoped contract (idempotent).
-- Idempotent: safe to run repeatedly on any School Connect database.
-- ============================================================================

-- ---------- 1a. schema additions ---------------------------------------------
alter table public.teacher_availability   add column if not exists available_periods jsonb;
alter table public.timetable_requirements add column if not exists available_periods jsonb;
comment on column public.timetable_requirements.available_periods is
  'Period-level availability, e.g. {"Monday":[1,2,3],"Thursday":[4,5,6]}. When set, its KEYS are the allowed days and the arrays the allowed periods. Null = use available_days / any period.';

create table if not exists public.timetable_blocks (
  id uuid primary key default gen_random_uuid(),
  class text not null default 'ALL',            -- 'ALL' or an exact class name
  day text not null,
  period int not null,
  label text default 'Free period',              -- e.g. Sports & Clubs, Assembly
  created_at timestamptz default now(),
  unique(class, day, period)
);
alter table public.timetable_blocks enable row level security;
drop policy if exists tb_read on timetable_blocks;
create policy tb_read on public.timetable_blocks
  for select using (auth.role() = 'authenticated');
drop policy if exists tb_staff_write on timetable_blocks;
create policy tb_staff_write on public.timetable_blocks
  for all using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------- 1b. the upgraded generator ---------------------------------------
drop function if exists public.generate_timetable(text,text,text,integer);
create or replace function public.generate_timetable(
  p_class text, p_session text default '', p_term text default '',
  p_periods_per_day integer default 6, p_day_periods jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare req record; blk record; occ int; placed int:=0; unplaced int:=0;
        ppd int:=least(greatest(coalesce(p_periods_per_day,6),1),12);
        chosen_day text; chosen_period int;
        allowed text[]; allowed_p jsonb;
        unplaced_items jsonb:='[]'::jsonb; required_total int:=0; capacity int:=0;
        d text; dp int;
begin
 if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'error','Staff/admin role required.'); end if;
 if coalesce(trim(p_class),'')='' then return jsonb_build_object('ok',false,'error','Select a class.'); end if;
 select coalesce(sum(greatest(periods_per_week,0)),0) into required_total from public.timetable_requirements where class=p_class;
 if required_total=0 then return jsonb_build_object('ok',false,'error','No subject demand exists for '||p_class||'. Add each subject, teacher and periods/week first.'); end if;

 -- weekly capacity honours per-day period counts and blocked slots
 foreach d in array array['Monday','Tuesday','Wednesday','Thursday','Friday'] loop
   dp := least(greatest(coalesce((p_day_periods->>d)::int, ppd),0),12);
   capacity := capacity + dp
     - (select count(*) from public.timetable_blocks b
         where (b.class=p_class or b.class='ALL') and b.day=d and b.period<=dp);
 end loop;

 delete from public.timetable where class=p_class
   and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'');

 -- write blocked slots into the grid FIRST: they display everywhere and the
 -- free-slot check below then avoids them automatically.
 for blk in select * from public.timetable_blocks b
             where (b.class=p_class or b.class='ALL')
               and b.period <= least(greatest(coalesce((p_day_periods->>b.day)::int, ppd),0),12) loop
   insert into public.timetable(class,day,period,subject,teacher,session,term)
   values (p_class, blk.day, blk.period::text, '⛔ '||coalesce(nullif(blk.label,''),'Free period'), null,
           coalesce(p_session,''), coalesce(p_term,''));
 end loop;

 for req in select * from public.timetable_requirements where class=p_class
             order by periods_per_week desc, subject loop
  allowed := req.available_days;
  allowed_p := req.available_periods;
  if (allowed is null or array_length(allowed,1) is null)
     and (allowed_p is null) and coalesce(req.teacher,'')<>'' then
    select available_days, available_periods into allowed, allowed_p
      from public.teacher_availability
     where lower(trim(teacher))=lower(trim(req.teacher)) limit 1;
  end if;
  for occ in 1..greatest(coalesce(req.periods_per_week,0),0) loop
   chosen_day:=null; chosen_period:=null;
   select dd.day, p.per into chosen_day, chosen_period
   from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
   cross join generate_series(1,12) p(per)
   where p.per <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
     -- day allowed: period-map keys win; else available_days; else any day
     and ( (allowed_p is not null and allowed_p ? dd.day)
        or (allowed_p is null and (allowed is null or array_length(allowed,1) is null
             or exists(select 1 from unnest(allowed) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))) )
     -- period allowed for that day when a period-map exists
     and ( allowed_p is null or not (allowed_p ? dd.day)
        or exists(select 1 from jsonb_array_elements_text(allowed_p->dd.day) e(v) where e.v::int = p.per) )
     -- class slot free (blocked slots already occupy their cells)
     and not exists(select 1 from public.timetable t
                     where t.class=p_class and t.day=dd.day and t.period=p.per::text
                       and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,''))
     -- teacher free across ALL classes this term/session
     and (coalesce(req.teacher,'')='' or not exists(
            select 1 from public.timetable t
             where lower(trim(coalesce(t.teacher,'')))=lower(trim(req.teacher))
               and t.day=dd.day and t.period=p.per::text
               and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')))
   order by
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day and t.subject=req.subject
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            (select count(*) from public.timetable t where t.class=p_class and t.period=p.per::text and t.subject=req.subject
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            random()
   limit 1;
   if chosen_day is null then
     unplaced:=unplaced+1;
     unplaced_items:=unplaced_items||jsonb_build_array(jsonb_build_object('subject',req.subject,'teacher',req.teacher,'occurrence',occ,'reason','No free slot on an allowed day/period'));
   else
     insert into public.timetable(class,day,period,subject,teacher,session,term)
     values(p_class,chosen_day,chosen_period::text,req.subject,nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
     placed:=placed+1;
   end if;
  end loop;
 end loop;
 insert into public.timetable_runs(class,session,term,generated_at,conflicts,notes)
 values(p_class,p_session,p_term,now(),unplaced,'Placed '||placed||' of '||required_total||' requested periods');
 return jsonb_build_object('ok',true,'placed',placed,'unplaced',unplaced,'requested',required_total,
   'capacity',capacity,'periods_per_day',ppd,'day_periods',coalesce(p_day_periods,'{}'::jsonb),
   'unplaced_items',unplaced_items,
   'message',case when unplaced=0 then 'Conflict-free timetable generated.'
     else 'Generated with '||unplaced||' unplaced demand(s). Review teacher days/periods, blocked slots or increase periods/day.' end);
exception when others then return jsonb_build_object('ok',false,'error',sqlerrm);
end$$;
revoke execute on function public.generate_timetable(text,text,text,integer,jsonb) from public, anon;
grant execute on function public.generate_timetable(text,text,text,integer,jsonb) to authenticated;

-- ---------- 2. assignments class-scope HARD RESET -----------------------------
-- Drop every historic SELECT policy (any name), then install the single scoped
-- contract: admins & subject/class teachers see all they manage; students and
-- parents see ONLY their own class's assignments.
do $$ declare p record; begin
  for p in select policyname from pg_policies
            where schemaname='public' and tablename='assignments' and cmd='SELECT' loop
    execute format('drop policy if exists %I on public.assignments', p.policyname);
  end loop;
end $$;
create policy assignments_scope_select on public.assignments for select using(
  public.is_admin(auth.uid())
  or public.teacher_can_manage_subject_class(auth.uid(),subject,class)
  or exists(select 1 from public.students s
             where (s.user_id=auth.uid() or public.is_parent_of(auth.uid(),s.id))
               and lower(regexp_replace(coalesce(s.class,''),'\s+','','g'))
                 = lower(regexp_replace(coalesce(assignments.class,''),'\s+','','g')))
);

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V7.9 flexible timetable + assignment class-scope installed' as status;
