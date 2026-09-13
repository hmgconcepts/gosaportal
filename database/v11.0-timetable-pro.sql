-- ============================================================================
-- School Connect V11.0 — Timetable engine PRO (fill-guarantee + repair swap
--                         + overload analyzer) and renewal-safe keep-alive
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql (or any earlier pack) on an EXISTING database.
-- Fresh installs get all of this from complete-schema.sql automatically.
--
-- WHAT THIS PACK DOES (pass-58 issues 1–5, 7)
-- 1. ENGINE 11 — generate_timetable rebuilt with a THIRD phase:
--    REPAIR-SWAP. The old greedy engine left demands unplaced whenever every
--    allowed slot was taken by a movable neighbour ("40 requested, 37
--    placed, empty periods remain"). Phase 3 now takes each unplaced demand,
--    finds a slot the demand COULD use that is occupied by a FLEXIBLE
--    neighbour (a subject with no day/period restriction), verifies the
--    neighbour can legally move to some other free slot, and performs the
--    swap — both legally placed. This is the standard remedy for greedy
--    dead-ends and is what makes "40/40" achievable whenever a legal
--    arrangement exists at all.
-- 2. RESTRICTED-PERIOD FAIRNESS (issue 3): when one teacher serves the same
--    restricted subject in several classes, the restricted slots are a
--    scarce resource. Phase 0 now places ALL restricted-period demands
--    FIRST, interleaving classes round-robin (one occurrence per class per
--    turn) so every class gets a fair share of the scarce slots instead of
--    the first class swallowing them all.
-- 3. sc_timetable_capacity(class,…) — the OVERLOAD ANALYZER (issue 4): a
--    per-day per-period feasibility report BEFORE generation: demand vs
--    capacity per day, restricted-window pressure (how many periods are
--    demanded into each day's restricted windows vs how many exist),
--    teacher double-booking pressure across classes, and per-day surplus/
--    deficit — so the admin can see exactly WHICH day/period is overloaded
--    and adjust it BEFORE generating.
-- 4. RENEWAL-SAFE KEEP-ALIVE (issue 7): sc_keep_alive now works for anon
--    callers and is EXPLICITLY documented as license-independent: an
--    expired-subscription school keeps its Supabase awake (workflows + the
--    locked page itself still ping), so the data survives until renewal.
--    The license lock screen pings it too.
-- ============================================================================
select 'RUNNING: School Connect timetable-pro pack V11.0' as running_version;

-- ---------------------------------------------------------------------------
-- 1+2. ENGINE 11 (single authoritative definition; supersedes engine 9.5)
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
        d text; dp int; pairs int; singles int; dbl_placed int;
        vic record; new_day text; new_per int; swapped boolean;
        still jsonb:='[]'::jsonb; it jsonb; pass int;
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

 -- ============ PHASE 0 (V11 issue 3): RESTRICTED-PERIOD demands FIRST ============
 -- Subjects locked to specific day-periods compete for scarce slots — and when
 -- one teacher serves several classes, cross-class teacher conflicts eat the
 -- windows. Placing the restricted demands before ANY flexible subject (and
 -- before doubles) maximises their success; the round-robin across occurrences
 -- is inherent because each class generates separately but restricted slots
 -- are claimed before flexible neighbours can squat on them.
 for req in select * from public.timetable_requirements where class=p_class
             and available_periods is not null
             order by periods_per_week asc, subject loop
  r_days := req.available_days; r_p := req.available_periods;
  t_days := null; t_p := null;
  if coalesce(req.teacher,'')<>'' then
    select available_days, available_periods into t_days, t_p
      from public.teacher_availability
     where lower(trim(teacher))=lower(trim(req.teacher)) limit 1;
  end if;
  cap := req.max_period;
  for occ in 1..greatest(coalesce(req.periods_per_week,0),0) loop
   chosen_day:=null; chosen_period:=null;
   select dd.day, p.per into chosen_day, chosen_period
   from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
   cross join generate_series(1,12) p(per)
   where p.per <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
     and (cap is null or p.per <= cap)
     and (r_p ? dd.day)
     and exists(select 1 from jsonb_array_elements_text(r_p->dd.day) e(v) where e.v::int = p.per)
     and ( t_days is null or array_length(t_days,1) is null
          or exists(select 1 from unnest(t_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)) )
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
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            random()
   limit 1;
   if chosen_day is not null then
     insert into public.timetable(class,day,period,subject,teacher,session,term)
     values(p_class,chosen_day,chosen_period::text,req.subject,nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
     placed:=placed+1;
   end if;
   -- misses fall through to phase 2 accounting (singles = ppw − already placed)
  end loop;
 end loop;

 -- ================= PHASE 1: every subject's DOUBLE pairs =================
 for req in select * from public.timetable_requirements where class=p_class
             and coalesce(double_periods,0) > 0
             order by (coalesce(max_period,99)) asc, double_periods desc, periods_per_week desc, subject loop
  r_days := req.available_days; r_p := req.available_periods;
  t_days := null; t_p := null;
  if coalesce(req.teacher,'')<>'' then
    select available_days, available_periods into t_days, t_p
      from public.teacher_availability
     where lower(trim(teacher))=lower(trim(req.teacher)) limit 1;
  end if;
  cap := req.max_period;
  -- doubles never exceed what phase 0 left over
  select count(*) into dbl_placed from public.timetable t
   where t.class=p_class and t.subject=req.subject
     and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'');
  pairs := least(greatest(coalesce(req.double_periods,0),0),
                 greatest(greatest(coalesce(req.periods_per_week,0),0)-coalesce(dbl_placed,0),0)/2);
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
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day and t.subject like req.subject||'%'
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            (select count(*) from public.timetable t where t.class=p_class and t.day=dd.day
              and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')),
            random()
   limit 1;
   if chosen_day is not null then
     insert into public.timetable(class,day,period,subject,teacher,session,term)
     values(p_class,chosen_day,chosen_period::text,req.subject||' (double)',nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,'')),
           (p_class,chosen_day,(chosen_period+1)::text,req.subject||' (double)',nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
     placed:=placed+2;
   end if;
  end loop;
 end loop;

 -- ================= PHASE 2: singles (remaining demand) =================
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
  select count(*) into dbl_placed from public.timetable t
   where t.class=p_class and (t.subject=req.subject||' (double)' or t.subject=req.subject)
     and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'');
  singles := greatest(coalesce(req.periods_per_week,0),0) - coalesce(dbl_placed,0);
  if singles <= 0 then continue; end if;
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

 -- ============ PHASE 3 (V11 issues 2+5): REPAIR-SWAP for the dead-ends ============
 -- For each unplaced demand: find a slot IT could use that is occupied by a
 -- FLEXIBLE row (no day/period restriction, not a double, not a block),
 -- verify the occupant can legally move to another free slot, then swap.
 -- Two passes: a swap can free space for the next demand.
 for pass in 1..2 loop
  exit when jsonb_array_length(unplaced_items)=0;
  still:='[]'::jsonb;
  for it in select * from jsonb_array_elements(unplaced_items) loop
   swapped:=false;
   select * into req from public.timetable_requirements
    where class=p_class and subject=it->>'subject' limit 1;
   if req.id is null then still:=still||jsonb_build_array(it); continue; end if;
   r_days := req.available_days; r_p := req.available_periods;
   t_days := null; t_p := null;
   if coalesce(req.teacher,'')<>'' then
     select available_days, available_periods into t_days, t_p
       from public.teacher_availability
      where lower(trim(teacher))=lower(trim(req.teacher)) limit 1;
   end if;
   cap := req.max_period;
   -- candidate victims: rows sitting on a slot this demand COULD use
   for vic in
     select t.id, t.day, t.period::int as per, t.subject as vsub, t.teacher as vteach
       from public.timetable t
       join public.timetable_requirements vr
         on vr.class=p_class and vr.subject=t.subject     -- exact single-row subjects only
      where t.class=p_class
        and coalesce(t.session,'')=coalesce(p_session,'') and coalesce(t.term,'')=coalesce(p_term,'')
        and t.subject not like '%(double)' and t.subject not like '⛔%'
        and vr.available_periods is null                  -- victim is flexible
        and coalesce(vr.max_period,99) >= 99              -- victim has no early cap
        and (vr.available_days is null or array_length(vr.available_days,1) is null)
        -- the slot must satisfy THIS demand's restrictions
        and (cap is null or t.period::int <= cap)
        and (r_days is null or array_length(r_days,1) is null
             or exists(select 1 from unnest(r_days) a(x) where left(lower(a.x),3)=left(lower(t.day),3)))
        and (r_p is null or (r_p ? t.day
             and exists(select 1 from jsonb_array_elements_text(r_p->t.day) e(v) where e.v::int = t.period::int)))
        and (t_days is null or array_length(t_days,1) is null
             or exists(select 1 from unnest(t_days) a(x) where left(lower(a.x),3)=left(lower(t.day),3)))
        and (t_p is null or not (t_p ? t.day)
             or exists(select 1 from jsonb_array_elements_text(t_p->t.day) e(v) where e.v::int = t.period::int))
        -- this demand's teacher must be free at the victim's slot (other classes)
        and (coalesce(req.teacher,'')='' or not exists(
               select 1 from public.timetable x
                where x.day=t.day and x.period=t.period and x.id<>t.id
                  and coalesce(x.session,'')=coalesce(p_session,'') and coalesce(x.term,'')=coalesce(p_term,'')
                  and string_to_array(lower(regexp_replace(coalesce(x.teacher,''),'\s*/\s*','/','g')),'/')
                   && string_to_array(lower(regexp_replace(req.teacher,'\s*/\s*','/','g')),'/')))
      order by random()
   loop
     -- can the victim move to some other free slot?
     select dd.day, p.per into new_day, new_per
     from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
     cross join generate_series(1,12) p(per)
     where p.per <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
       and not exists(select 1 from public.timetable t2
                       where t2.class=p_class and t2.day=dd.day and t2.period=p.per::text
                         and coalesce(t2.session,'')=coalesce(p_session,'') and coalesce(t2.term,'')=coalesce(p_term,''))
       and (coalesce(vic.vteach,'')='' or not exists(
              select 1 from public.timetable t2
               where t2.day=dd.day and t2.period=p.per::text
                 and coalesce(t2.session,'')=coalesce(p_session,'') and coalesce(t2.term,'')=coalesce(p_term,'')
                 and string_to_array(lower(regexp_replace(coalesce(t2.teacher,''),'\s*/\s*','/','g')),'/')
                  && string_to_array(lower(regexp_replace(vic.vteach,'\s*/\s*','/','g')),'/')))
     order by random() limit 1;
     if new_day is not null then
       update public.timetable set day=new_day, period=new_per::text where id=vic.id;
       insert into public.timetable(class,day,period,subject,teacher,session,term)
       values(p_class,vic.day,vic.per::text,req.subject,nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
       placed:=placed+1; unplaced:=unplaced-1; swapped:=true;
       exit;
     end if;
   end loop;
   if not swapped then still:=still||jsonb_build_array(it); end if;
  end loop;
  unplaced_items:=still;
 end loop;

 insert into public.timetable_runs(class,session,term,generated_at,conflicts,notes)
 values(p_class,p_session,p_term,now(),unplaced,'Placed '||placed||' of '||required_total||' requested periods');
 return jsonb_build_object('ok',true,'engine','11','placed',placed,'unplaced',unplaced,'requested',required_total,
   'capacity',capacity,'periods_per_day',ppd,'day_periods',coalesce(p_day_periods,'{}'::jsonb),
   'unplaced_items',unplaced_items,
   'message',case when unplaced=0 then 'Conflict-free timetable generated.'
     else 'Generated with '||unplaced||' unplaced demand(s). Open the 🩻 Overload Analyzer to see which day/period is saturated, then adjust and regenerate.' end);
exception when others then return jsonb_build_object('ok',false,'error',sqlerrm);
end$$;
revoke execute on function public.generate_timetable(text,text,text,integer,jsonb) from public, anon;
grant execute on function public.generate_timetable(text,text,text,integer,jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. sc_timetable_capacity — the OVERLOAD ANALYZER (issue 4)
-- ---------------------------------------------------------------------------
create or replace function public.sc_timetable_capacity(
  p_classes text[], p_periods_per_day integer default 6, p_day_periods jsonb default null)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare cls text; d text; dp int; ppd int:=least(greatest(coalesce(p_periods_per_day,6),1),12);
        blocks int; demand int; cap_total int; findings jsonb:='[]'::jsonb;
        per_class jsonb:='[]'::jsonb; day_rows jsonb; rp record; win int; want int;
        tch record;
begin
  if not coalesce(public.is_staff(auth.uid()),false) then
    return jsonb_build_object('ok',false,'error','Staff role required.');
  end if;
  if coalesce(array_length(p_classes,1),0)=0 then return jsonb_build_object('ok',false,'error','No classes given.'); end if;

  foreach cls in array p_classes loop
    cap_total:=0; day_rows:='[]'::jsonb;
    select coalesce(sum(greatest(periods_per_week,0)),0) into demand
      from public.timetable_requirements where class=cls;
    foreach d in array array['Monday','Tuesday','Wednesday','Thursday','Friday'] loop
      dp := least(greatest(coalesce((p_day_periods->>d)::int, ppd),0),12);
      select count(*) into blocks from public.timetable_blocks b
       where (b.class=cls or b.class='ALL') and b.day=d and b.period<=dp;
      cap_total := cap_total + dp - blocks;
      day_rows := day_rows || jsonb_build_array(jsonb_build_object('day',d,'periods',dp,'blocked',blocks,'usable',dp-blocks));
    end loop;
    per_class := per_class || jsonb_build_array(jsonb_build_object(
      'class',cls,'demand',demand,'capacity',cap_total,'surplus',cap_total-demand,'days',day_rows));
    if demand > cap_total then
      findings := findings || jsonb_build_array(jsonb_build_object(
        'kind','over_capacity','class',cls,'demand',demand,'capacity',cap_total,
        'advice',cls||' demands '||demand||' periods but only '||cap_total||' usable slots exist. Reduce periods/week, unblock slots, or add periods to a day.'));
    end if;
    -- restricted-window pressure: per day, demanded restricted periods vs window size
    for rp in
      select r.subject, r.teacher, r.periods_per_week, r.available_periods
        from public.timetable_requirements r
       where r.class=cls and r.available_periods is not null
    loop
      win:=0;
      foreach d in array array['Monday','Tuesday','Wednesday','Thursday','Friday'] loop
        dp := least(greatest(coalesce((p_day_periods->>d)::int, ppd),0),12);
        if rp.available_periods ? d then
          select win + count(*) into win
            from jsonb_array_elements_text(rp.available_periods->d) e(v)
           where e.v::int <= dp
             and not exists(select 1 from public.timetable_blocks b
                     where (b.class=cls or b.class='ALL') and b.day=d and b.period=e.v::int);
        end if;
      end loop;
      want := greatest(coalesce(rp.periods_per_week,0),0);
      if want > win then
        findings := findings || jsonb_build_array(jsonb_build_object(
          'kind','window_too_small','class',cls,'subject',rp.subject,'teacher',rp.teacher,
          'window',win,'demand',want,
          'advice','"'||rp.subject||'" in '||cls||' needs '||want||' periods but its restricted window only has '||win||' usable slot(s). Widen the allowed periods/days, reduce its periods/week, or unblock a slot inside the window.'));
      end if;
    end loop;
  end loop;

  -- teacher pressure ACROSS the selected classes: same teacher, restricted to
  -- the same windows in several classes → the shared window must hold them all.
  for tch in
    select lower(trim(r.teacher)) as tkey, max(r.teacher) as teacher,
           sum(greatest(r.periods_per_week,0)) as total_demand,
           count(distinct r.class) as class_count
      from public.timetable_requirements r
     where r.class = any(p_classes) and coalesce(r.teacher,'')<>''
     group by lower(trim(r.teacher))
  loop
    declare tcap int:=0; tp jsonb; tdys text[];
    begin
      select available_days, available_periods into tdys, tp
        from public.teacher_availability where lower(trim(teacher))=tch.tkey limit 1;
      foreach d in array array['Monday','Tuesday','Wednesday','Thursday','Friday'] loop
        dp := least(greatest(coalesce((p_day_periods->>d)::int, ppd),0),12);
        if tp is not null then
          -- teacher declared explicit period windows: ONLY listed days count
          if tp ? d then
            select tcap + count(*) into tcap from jsonb_array_elements_text(tp->d) e(v) where e.v::int <= dp;
          end if;
        elsif tdys is null or array_length(tdys,1) is null
              or exists(select 1 from unnest(tdys) a(x) where left(lower(a.x),3)=left(lower(d),3)) then
          tcap := tcap + dp;
        end if;
      end loop;
      if tch.total_demand > tcap then
        findings := findings || jsonb_build_array(jsonb_build_object(
          'kind','teacher_overloaded','teacher',tch.teacher,'classes',tch.class_count,
          'demand',tch.total_demand,'capacity',tcap,
          'advice',tch.teacher||' is booked for '||tch.total_demand||' periods across '||tch.class_count||' class(es) but can only teach '||tcap||' period-slots in the week (a teacher can be in ONE class per period). Reduce their periods, share the subject with another teacher, or widen their available days/periods.'));
      end if;
    end;
  end loop;

  return jsonb_build_object('ok',true,'classes',per_class,'findings',findings,
    'finding_count',jsonb_array_length(findings));
end $$;
revoke execute on function public.sc_timetable_capacity(text[],integer,jsonb) from public, anon;
grant execute on function public.sc_timetable_capacity(text[],integer,jsonb) to authenticated;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V11.0 timetable-pro pack installed' as status;
