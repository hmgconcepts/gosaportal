-- ============================================================================
-- School Connect V9.1 — Enterprise pack
--   1. Timetable engine upgrades: double periods, early-period caps,
--      part-time teacher period fix (teacher_availability ALWAYS honoured),
--      duplicate-row cleanup + uniqueness (master/class/teacher grids can
--      never disagree again).
--   2. Examination timetable: new exam_timetable table + RLS.
--   3. Subscription hardening: server-side license state (client clocks and
--      hand-edited rows no longer matter), signed activation keys, TOFU salt
--      lock, license event audit trail.
--   4. Assignment integrity: scores follow their assignment (cascade).
--   5. Optional AI assistant settings (staff-read, admin-write; OFF by default).
-- Idempotent — safe to run repeatedly.
select 'RUNNING: School Connect enterprise pack V9.1' as running_version;

-- ---------------------------------------------------------------------------
-- 1a. Timetable demand: double periods + early-period cap
-- ---------------------------------------------------------------------------
alter table public.timetable_requirements add column if not exists double_periods int not null default 0;
alter table public.timetable_requirements add column if not exists max_period int;

-- ---------------------------------------------------------------------------
-- 1b. Duplicate timetable rows are the root cause of "master says Maths,
--     class grid says CRS": older generations with a different term/session
--     spelling, or repeated manual adds, left several rows claiming the same
--     cell. Remove older duplicates (newest id kept), then enforce uniqueness.
-- ---------------------------------------------------------------------------
do $$
begin
  delete from public.timetable t using public.timetable t2
   where t.class = t2.class and t.day = t2.day and t.period = t2.period
     and coalesce(t.session,'') = coalesce(t2.session,'')
     and coalesce(t.term,'')    = coalesce(t2.term,'')
     and t.ctid < t2.ctid;
  begin
    create unique index if not exists ux_timetable_slot
      on public.timetable (class, day, period, coalesce(session,''), coalesce(term,''));
  exception when others then
    raise notice 'Timetable uniqueness index skipped (%). Duplicates were still cleaned.', sqlerrm;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 1c. generate_timetable V9.1 (same signature — clients need no change).
--     • Part-time fix: teacher_availability now ALWAYS applies when the
--       teacher has one (previously it was consulted only when the subject
--       row had no restrictions of its own — so a teacher's fixed periods
--       were silently ignored the moment the subject carried its own days).
--       Requirement-level AND teacher-level constraints are enforced TOGETHER.
--     • Double periods: double_periods pairs are placed on two ADJACENT
--       free periods of the same day first; leftovers fall back to singles.
--     • Early-period cap: max_period (e.g. 4) is a hard ceiling for that
--       subject — calculational subjects can be pinned to the morning.
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
 if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'error','Staff/admin role required.'); end if;
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
  -- V9.1: requirement-level AND teacher-level constraints BOTH apply.
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

  -- -------- double periods: two ADJACENT slots on the same day --------
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
     singles := singles + 2;   -- no adjacent pair available: place as singles instead
   else
     insert into public.timetable(class,day,period,subject,teacher,session,term)
     values(p_class,chosen_day,chosen_period::text,req.subject||' (double)',nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,'')),
           (p_class,chosen_day,(chosen_period+1)::text,req.subject||' (double)',nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));
     placed:=placed+2;
   end if;
  end loop;

  -- -------- single periods --------
  for occ in 1..singles loop
   chosen_day:=null; chosen_period:=null;
   select dd.day, p.per into chosen_day, chosen_period
   from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday']) with ordinality dd(day,dord)
   cross join generate_series(1,12) p(per)
   where p.per <= least(greatest(coalesce((p_day_periods->>dd.day)::int, ppd),0),12)
     and (cap is null or p.per <= cap)
     -- day allowed by the SUBJECT row
     and ( (r_p is not null and r_p ? dd.day)
        or (r_p is null and (r_days is null or array_length(r_days,1) is null
             or exists(select 1 from unnest(r_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))) )
     -- day allowed by the TEACHER (V9.1: always enforced when present)
     and ( (t_p is not null and t_p ? dd.day)
        or (t_p is null and (t_days is null or array_length(t_days,1) is null
             or exists(select 1 from unnest(t_days) a(x) where left(lower(a.x),3)=left(lower(dd.day),3)))) )
     -- period allowed by the SUBJECT row's map
     and ( r_p is null or not (r_p ? dd.day)
        or exists(select 1 from jsonb_array_elements_text(r_p->dd.day) e(v) where e.v::int = p.per) )
     -- period allowed by the TEACHER's map (V9.1)
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

-- ---------------------------------------------------------------------------
-- 2. Examination timetable
-- ---------------------------------------------------------------------------
create table if not exists public.exam_timetable (
  id uuid primary key default gen_random_uuid(),
  class text not null,
  subject text not null,
  exam_date date not null,
  start_time text not null default '09:00',
  end_time text not null default '11:00',
  venue text default '',
  invigilator text default '',
  paper text default '',
  term text default '', session text default '',
  notes text default '',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);
create index if not exists ix_exam_tt_class on public.exam_timetable(class, exam_date);
alter table public.exam_timetable enable row level security;
drop policy if exists "examtt_read" on public.exam_timetable;
create policy "examtt_read"  on public.exam_timetable for select using (auth.role() = 'authenticated');
drop policy if exists "examtt_write" on public.exam_timetable;
create policy "examtt_write" on public.exam_timetable for all
  using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));

-- ---------------------------------------------------------------------------
-- 3. Subscription hardening
-- ---------------------------------------------------------------------------
create schema if not exists sc_private;
create table if not exists sc_private.license_secret(
  id int primary key default 1 check (id=1),
  salt text not null,
  set_at timestamptz not null default now());

create table if not exists public.license_events (
  id uuid primary key default gen_random_uuid(),
  at timestamptz not null default now(),
  actor uuid,
  action text not null,
  details jsonb default '{}'::jsonb
);
alter table public.license_events enable row level security;
drop policy if exists "licev_read" on public.license_events;
create policy "licev_read" on public.license_events for select using (public.is_admin(auth.uid()));

-- Is the site salt-locked? (After HMG locks it, ONLY signed activation keys
-- can change the subscription — the client's own admin can no longer extend
-- the license by editing the row.)
create or replace function public.sc_license_locked()
returns boolean language sql security definer set search_path=public, sc_private
as $$ select exists(select 1 from sc_private.license_secret where id=1) $$;
grant execute on function public.sc_license_locked() to anon, authenticated;

-- TOFU: the first (and only) salt write wins. Admin-only. HMG runs this once
-- at handover; from then on the license is key-controlled.
create or replace function public.sc_license_set_salt(p_salt text)
returns text language plpgsql security definer set search_path=public, sc_private
as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admin only.'; end if;
  if coalesce(trim(p_salt),'')='' or length(trim(p_salt))<12 then
    raise exception 'Salt must be at least 12 characters.';
  end if;
  if exists(select 1 from sc_private.license_secret where id=1) then
    raise exception 'License is already locked. The salt cannot be changed.';
  end if;
  insert into sc_private.license_secret(id,salt) values (1, trim(p_salt));
  insert into public.license_events(actor,action,details)
  values (auth.uid(),'salt_locked',jsonb_build_object('at',now()));
  return 'License locked. From now on only signed activation keys can modify the subscription.';
end $$;
revoke all on function public.sc_license_set_salt(text) from public, anon;
grant execute on function public.sc_license_set_salt(text) to authenticated;

-- Apply a signed activation key: 'SC1.<base64url(payload json)>.<hex sha256(payload_b64||'.'||salt)>'
-- Payload: {"expires_on":"YYYY-MM-DD","grace_days":7,"status":"active|suspended",
--           "plan":"...","cycle":"...","renew_url":"...","lock_message":"...","nonce":"..."}
create or replace function public.sc_license_apply(p_key text)
returns jsonb language plpgsql security definer set search_path=public, sc_private
as $$
declare v_salt text; v_b64 text; v_sig text; v_pad text; v_json jsonb; v_calc text;
begin
  if auth.role() <> 'authenticated' then raise exception 'Sign in first.'; end if;
  select salt into v_salt from sc_private.license_secret where id=1;
  if v_salt is null then
    return jsonb_build_object('ok',false,'error','License is not key-locked yet. Ask HMG to lock it, or use the admin form.');
  end if;
  if p_key is null or p_key not like 'SC1.%' or array_length(string_to_array(p_key,'.'),1)<>3 then
    return jsonb_build_object('ok',false,'error','Invalid key format.');
  end if;
  v_b64 := split_part(p_key,'.',2); v_sig := lower(split_part(p_key,'.',3));
  v_calc := encode(sha256(convert_to(v_b64||'.'||v_salt,'utf8')),'hex');
  if v_calc <> v_sig then
    insert into public.license_events(actor,action,details) values (auth.uid(),'key_rejected',jsonb_build_object('reason','bad signature'));
    return jsonb_build_object('ok',false,'error','Key verification failed. The key was not issued for this site.');
  end if;
  if exists (select 1 from public.license_events where action='key_applied' and details->>'sig'=v_sig) then
    return jsonb_build_object('ok',false,'error','This key has already been used.');
  end if;
  v_pad := translate(v_b64,'-_','+/');
  v_pad := v_pad || repeat('=', (4 - length(v_pad) % 4) % 4);
  begin
    v_json := convert_from(decode(v_pad,'base64'),'utf8')::jsonb;
  exception when others then
    return jsonb_build_object('ok',false,'error','Key payload could not be decoded.');
  end;
  update public.site_license set
    model        = coalesce(nullif(v_json->>'model',''),'subscription'),
    plan         = coalesce(nullif(v_json->>'plan',''), plan),
    cycle        = coalesce(nullif(v_json->>'cycle',''), cycle),
    expires_on   = coalesce(nullif(v_json->>'expires_on','')::date, expires_on),
    grace_days   = coalesce((v_json->>'grace_days')::int, grace_days),
    status       = case when v_json->>'status' in ('active','suspended') then v_json->>'status' else status end,
    renew_url    = coalesce(nullif(v_json->>'renew_url',''), renew_url),
    lock_message = coalesce(v_json->>'lock_message', lock_message),
    signature    = v_sig
  where id = 1;
  insert into public.license_events(actor,action,details)
  values (auth.uid(),'key_applied',jsonb_build_object('sig',v_sig,'expires_on',v_json->>'expires_on','status',v_json->>'status'));
  return jsonb_build_object('ok',true,'message','Activation key applied.','expires_on',v_json->>'expires_on','status',coalesce(v_json->>'status','active'));
end $$;
revoke all on function public.sc_license_apply(text) from public, anon;
grant execute on function public.sc_license_apply(text) to authenticated;

-- Server-computed license state: the client's clock and hand-edited rows no
-- longer decide anything. Readable pre-login so the lock also works there.
create or replace function public.sc_license_status()
returns jsonb language plpgsql security definer set search_path=public, sc_private
as $$
declare l record; v_state text; v_exp date; v_grace_end date; v_days int;
begin
  select * into l from public.site_license where id=1;
  if l is null then return jsonb_build_object('state','lifetime','locked',public.sc_license_locked()); end if;
  if l.model <> 'subscription' then
    return jsonb_build_object('state','lifetime','locked',public.sc_license_locked());
  end if;
  if l.status = 'suspended' then
    return jsonb_build_object('state','suspended','locked',public.sc_license_locked(),
      'plan',l.plan,'cycle',l.cycle,'renew_url',l.renew_url,'lock_message',l.lock_message);
  end if;
  v_exp := l.expires_on;
  if v_exp is null then return jsonb_build_object('state','active','locked',public.sc_license_locked(),'plan',l.plan); end if;
  v_grace_end := v_exp + make_interval(days=>coalesce(l.grace_days,7));
  if current_date > v_grace_end then v_state:='expired'; v_days:=current_date - v_grace_end;
  elsif current_date > v_exp then v_state:='grace'; v_days:=v_grace_end - current_date;
  else v_days := v_exp - current_date;
       v_state := case when v_days<=30 then 'warning' else 'active' end;
  end if;
  return jsonb_build_object('state',v_state,'days',v_days,'expires_on',v_exp,'grace_days',coalesce(l.grace_days,7),
    'plan',l.plan,'cycle',l.cycle,'status',l.status,'renew_url',l.renew_url,'lock_message',l.lock_message,
    'locked',public.sc_license_locked(),'server_date',current_date);
end $$;
grant execute on function public.sc_license_status() to anon, authenticated;

-- Once locked, direct writes to site_license stop working for everyone via
-- the API (keys become the only path). Pre-lock behaviour is unchanged.
drop policy if exists "site_license_write" on public.site_license;
create policy "site_license_write" on public.site_license for all
  using (public.is_admin(auth.uid()) and not public.sc_license_locked())
  with check (public.is_admin(auth.uid()) and not public.sc_license_locked());

-- ---------------------------------------------------------------------------
-- 4. Assignment integrity: scores follow their assignment.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='assignment_scores') then
    begin
      alter table public.assignment_scores drop constraint if exists assignment_scores_assignment_id_fkey;
      alter table public.assignment_scores
        add constraint assignment_scores_assignment_id_fkey
        foreign key (assignment_id) references public.assignments(id) on delete cascade;
    exception when others then
      raise notice 'assignment_scores FK left unchanged (%).', sqlerrm;
    end;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Optional AI assistant settings (single row; staff read, admin write).
--    OFF by default — the platform never depends on it.
-- ---------------------------------------------------------------------------
create table if not exists public.sc_ai_settings (
  id int primary key default 1 check (id=1),
  enabled boolean not null default false,
  base_url text not null default '',
  api_key text not null default '',
  model text not null default '',
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz default now()
);
insert into public.sc_ai_settings(id) values (1) on conflict (id) do nothing;
alter table public.sc_ai_settings enable row level security;
drop policy if exists "ai_read" on public.sc_ai_settings;
create policy "ai_read"  on public.sc_ai_settings for select using (public.is_staff(auth.uid()));
drop policy if exists "ai_write" on public.sc_ai_settings;
create policy "ai_write" on public.sc_ai_settings for all
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V9.1 enterprise pack installed — timetable V9.1, exam timetable, license hardening, AI settings' as status;
