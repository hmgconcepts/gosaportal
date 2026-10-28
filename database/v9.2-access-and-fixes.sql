-- ============================================================================
-- School Connect V9.2 — Timetable access control + integrity fixes
--   1. AUTHORIZED-EDITORS model: only the admin tier PLUS explicitly
--      authorized staff can write to the published timetable, the
--      auto-timetable engine tables and the exam timetable. Random
--      teachers can no longer tamper with published schedules.
--        • table  public.sc_module_editors  (module, user_id)
--        • fn     public.sc_can_edit(module) → is_admin OR granted
--        • write policies on timetable / timetable_blocks / exam_timetable /
--          timetable_requirements / teacher_availability / timetable_config
--        • generate_timetable() itself now refuses unauthorized callers.
--   2. Attendance privacy re-assertion: ONE canonical read policy —
--      students see their own rows, parents see their children's rows,
--      staff see all (older overlapping policies are dropped).
-- Idempotent — safe to run repeatedly.
select 'RUNNING: School Connect access-control pack V9.2' as running_version;

-- ---------------------------------------------------------------------------
-- 1a. Authorized editors registry
-- ---------------------------------------------------------------------------
create table if not exists public.sc_module_editors (
  id uuid primary key default gen_random_uuid(),
  module text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  granted_by uuid references public.profiles(id) on delete set null,
  granted_at timestamptz default now(),
  unique(module, user_id)
);
alter table public.sc_module_editors enable row level security;
drop policy if exists "sme_read" on public.sc_module_editors;
create policy "sme_read"  on public.sc_module_editors for select using (public.is_staff(auth.uid()));
drop policy if exists "sme_write" on public.sc_module_editors;
create policy "sme_write" on public.sc_module_editors for all
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

create or replace function public.sc_can_edit(p_module text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.is_admin(auth.uid())
      or exists (select 1 from public.sc_module_editors e
                  where e.module = p_module and e.user_id = auth.uid());
$$;
grant execute on function public.sc_can_edit(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 1b. Lock the timetable family down to admin + authorized editors.
--     (READ stays open to every authenticated user — everyone can VIEW.)
-- ---------------------------------------------------------------------------
do $$
begin
  -- published class timetable (was generic staff-write)
  drop policy if exists "write_timetable" on public.timetable;
  create policy "write_timetable" on public.timetable for all
    using (public.sc_can_edit('timetable')) with check (public.sc_can_edit('timetable'));

  -- reserved/blocked slots
  drop policy if exists tb_staff_write on public.timetable_blocks;
  drop policy if exists tb_editor_write on public.timetable_blocks;
  create policy tb_editor_write on public.timetable_blocks for all
    using (public.sc_can_edit('timetable')) with check (public.sc_can_edit('timetable'));

  -- exam timetable (was staff-write)
  drop policy if exists "examtt_write" on public.exam_timetable;
  create policy "examtt_write" on public.exam_timetable for all
    using (public.sc_can_edit('timetable')) with check (public.sc_can_edit('timetable'));

  -- subject demand + teacher availability (was admin-only; now admin + authorized)
  drop policy if exists "admin_manage_timetable_requirements" on public.timetable_requirements;
  drop policy if exists "v7_enterprise_write" on public.timetable_requirements;
  drop policy if exists "tt_req_editor_write" on public.timetable_requirements;
  create policy "tt_req_editor_write" on public.timetable_requirements for all
    using (public.sc_can_edit('timetable')) with check (public.sc_can_edit('timetable'));

  drop policy if exists "admin_manage_teacher_availability" on public.teacher_availability;
  drop policy if exists "tt_av_editor_write" on public.teacher_availability;
  create policy "tt_av_editor_write" on public.teacher_availability for all
    using (public.sc_can_edit('timetable')) with check (public.sc_can_edit('timetable'));

  -- period/break schedule
  drop policy if exists "tc_admin_write" on public.timetable_config;
  drop policy if exists "tc_editor_write" on public.timetable_config;
  create policy "tc_editor_write" on public.timetable_config for all
    using (public.sc_can_edit('timetable')) with check (public.sc_can_edit('timetable'));
exception when undefined_table then
  raise notice 'A timetable table is missing on this database — run complete-schema.sql.';
end $$;

-- ---------------------------------------------------------------------------
-- 2. Attendance privacy: ONE canonical scoped read policy.
--    (Older permissive policies stacked up over versions; because PostgreSQL
--    ORs all permissive policies, we drop the legacy ones and keep a single
--    authoritative rule so the scope is provable at a glance.)
-- ---------------------------------------------------------------------------
do $$
begin
  drop policy if exists "att_read" on public.attendance;
  drop policy if exists "attendance_parent_read_v16" on public.attendance;
  drop policy if exists "attendance_scope_select" on public.attendance;  -- subset of the canonical rule (permissive policies OR together, so folding it in loses nothing)
  drop policy if exists "v7_attendance_read_family" on public.attendance;
  create policy "v7_attendance_read_family" on public.attendance for select using (
    public.is_staff(auth.uid())
    or exists(select 1 from public.students s
               where s.id = attendance.student_id
                 and (s.user_id = auth.uid()
                      or public.is_parent_of(auth.uid(), s.id)
                      -- legacy guardian-email linkage kept (feature-preserving)
                      or s.guardian_email = auth.jwt()->>'email'))
  );
exception when undefined_table then null;
end $$;

-- ---------------------------------------------------------------------------
-- 3. generate_timetable(): unauthorized callers are refused at the engine.
--    (Full V9.2 definition — V9.1 body with the sc_can_edit gate.)
-- ---------------------------------------------------------------------------
create or replace function public.generate_timetable(
  p_class text, p_session text default '', p_term text default '',
  p_periods_per_day integer default 6, p_day_periods jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare req record; blk record; occ int; placed int:=0; unplaced int:=0;
        ppd int:=least(greatest(coalesce(p_periods_per_day,6),1),12);
        chosen_day text; chosen_period int;
        r_days text[]; r_p jsonb; t_days text[]; t_p jsonb; cap int;
        unplaced_items jsonb:='[]'::jsonb; required_total int:=0; capacity int:=0;
        d text; dp int; pairs int; singles int;
begin
 if not public.sc_can_edit('timetable') then return jsonb_build_object('ok',false,'error','Only the admin or an authorized timetable editor can generate timetables. Ask the admin for access (Timetable Wizard → Authorized editors).'); end if;
 if coalesce(trim(p_class),'')='' then return jsonb_build_object('ok',false,'error','Select a class.'); end if;
 select coalesce(sum(greatest(periods_per_week,0)),0) into required_total from public.timetable_requirements where class=p_class;
 if required_total=0 then return jsonb_build_object('ok',false,'error','No subject demand exists for '||p_class||'. Add each subject, teacher and periods/week first.'); end if;

 foreach d in array array['Monday','Tuesday','Wednesday','Thursday','Friday'] loop
   dp := least(greatest(coalesce((p_day_periods->>d)::int, ppd),0),12);
   capacity := capacity + dp
     - (select count(*) from public.timetable_blocks b
         where (b.class=p_class or b.class='ALL') and b.day=d and b.period<=dp);
 end loop;

 delete from public.timetable where class=p_class
   and coalesce(session,'')=coalesce(p_session,'') and coalesce(term,'')=coalesce(p_term,'');

 for blk in select * from public.timetable_blocks b
             where (b.class=p_class or b.class='ALL')
               and b.period <= least(greatest(coalesce((p_day_periods->>b.day)::int, ppd),0),12) loop
   insert into public.timetable(class,day,period,subject,teacher,session,term)
   values (p_class, blk.day, blk.period::text, '⛔ '||coalesce(nullif(blk.label,''),'Free period'), null,
           coalesce(p_session,''), coalesce(p_term,''))
   on conflict do nothing;
 end loop;

 for req in select * from public.timetable_requirements where class=p_class
             order by (coalesce(max_period,99)) asc, periods_per_week desc, subject loop
  r_days := req.available_days; r_p := req.available_periods;
  t_days := null; t_p := null;
  if coalesce(req.teacher,'')<>'' then
    select available_days, available_periods into t_days, t_p
      from public.teacher_availability
     where lower(trim(teacher))=lower(trim(req.teacher)) limit 1;
  end if;
  cap := req.max_period;

  pairs   := least(greatest(coalesce(req.double_periods,0),0), greatest(coalesce(req.periods_per_week,0),0)/2);
  singles := greatest(coalesce(req.periods_per_week,0),0) - pairs*2;

  for occ in 1..pairs loop
   chosen_day:=null; chosen_period:=null;
   select dd.day, p.per into chosen_day, chosen_period
   from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
   cross join generate_series(1,11) p(per)
   where p.per+1 <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
     and (cap is null or p.per+1 <= cap)
     and (r_days is null or array_length(r_days,1) is null
          or exists(select 1 from unnest(r_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))
     and (t_days is null or array_length(t_days,1) is null
          or exists(select 1 from unnest(t_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))
     and (r_p is null or (r_p ? dd.day
          and exists(select 1 from jsonb_array_elements_text(r_p->dd.day) e(v) where e.v::int = p.per)
          and exists(select 1 from jsonb_array_elements_text(r_p->dd.day) e(v) where e.v::int = p.per+1)))
     and (t_p is null or (t_p ? dd.day
          and exists(select 1 from jsonb_array_elements_text(t_p->dd.day) e(v) where e.v::int = p.per)
          and exists(select 1 from jsonb_array_elements_text(t_p->dd.day) e(v) where e.v::int = p.per+1)))
     and not exists(select 1 from public.timetable t
                     where t.class=p_class and t.day=dd.day and t.period in (p.per::text,(p.per+1)::text)
                       and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,''))
     and (coalesce(req.teacher,'')='' or not exists(
            select 1 from public.timetable t
             where t.day=dd.day and t.period in (p.per::text,(p.per+1)::text)
               and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')
               and string_to_array(lower(regexp_replace(coalesce(t.teacher,''),'\s*/\s*','/','g')),'/')
                && string_to_array(lower(regexp_replace(req.teacher,'\s*/\s*','/','g')),'/')))
   order by
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day and t.subject=req.subject
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            random()
   limit 1;
   if chosen_day is null then
     singles := singles + 2;
   else
     insert into public.timetable(class,day,period,subject,teacher,session,term)
     values(p_class,chosen_day,chosen_period::text,req.subject||' (double)',nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,'')),
           (p_class,chosen_day,(chosen_period+1)::text,req.subject||' (double)',nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
     placed:=placed+2;
   end if;
  end loop;

  for occ in 1..singles loop
   chosen_day:=null; chosen_period:=null;
   select dd.day, p.per into chosen_day, chosen_period
   from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
   cross join generate_series(1,12) p(per)
   where p.per <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
     and (cap is null or p.per <= cap)
     and ( (r_p is not null and r_p ? dd.day)
        or (r_p is null and (r_days is null or array_length(r_days,1) is null
             or exists(select 1 from unnest(r_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))) )
     and ( (t_p is not null and t_p ? dd.day)
        or (t_p is null and (t_days is null or array_length(t_days,1) is null
             or exists(select 1 from unnest(t_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))) )
     and ( r_p is null or not (r_p ? dd.day)
        or exists(select 1 from jsonb_array_elements_text(r_p->dd.day) e(v) where e.v::int = p.per) )
     and ( t_p is null or not (t_p ? dd.day)
        or exists(select 1 from jsonb_array_elements_text(t_p->dd.day) e(v) where e.v::int = p.per) )
     and not exists(select 1 from public.timetable t
                     where t.class=p_class and t.day=dd.day and t.period=p.per::text
                       and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,''))
     and (coalesce(req.teacher,'')='' or not exists(
            select 1 from public.timetable t
             where t.day=dd.day and t.period=p.per::text
               and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')
               and string_to_array(lower(regexp_replace(coalesce(t.teacher,''),'\s*/\s*','/','g')),'/')
                && string_to_array(lower(regexp_replace(req.teacher,'\s*/\s*','/','g')),'/')))
   order by
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day and t.subject like req.subject||'%'
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            (select count(*) from public.timetable t where t.class=p_class and t.period=p.per::text and t.subject like req.subject||'%'
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

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V9.2 access control installed — timetable family locked to admin + authorized editors; attendance scope canonical' as status;
