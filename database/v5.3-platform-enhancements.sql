-- School Connect V5.3 focused upgrade: teacher signatures + robust timetable + promotion lookup
-- Existing database only. Back up Supabase first. Fresh projects run complete-schema.sql.

alter table public.profiles add column if not exists signature_url text default '';
alter table public.staff add column if not exists signature_url text default '';
alter table public.timetable_config alter column period_no type numeric using period_no::numeric;

create or replace function public.get_class_teacher_identity(p_class text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare c record;s record;p record;teacher_name text:='';sig text:='';
begin
 select * into c from public.classes where lower(trim(name))=lower(trim(coalesce(p_class,''))) limit 1;
 if not found then return jsonb_build_object('name','Class Teacher','signature_url','','linked',false);end if;
 teacher_name:=coalesce(c.class_teacher,'');select * into s from public.staff where lower(trim(full_name))=lower(trim(teacher_name))limit 1;
 if found then teacher_name:=coalesce(nullif(s.full_name,''),teacher_name);sig:=coalesce(nullif(s.signature_url,''),'');if s.user_id is not null then select * into p from public.profiles where id=s.user_id limit 1;if found then sig:=coalesce(nullif(p.signature_url,''),sig);teacher_name:=coalesce(nullif(p.full_name,''),teacher_name);end if;end if;end if;
 return jsonb_build_object('name',coalesce(nullif(teacher_name,''),'Class Teacher'),'signature_url',coalesce(sig,''),'linked',coalesce(s.user_id is not null,false));
end$$;
revoke execute on function public.get_class_teacher_identity(text)from public,anon;
grant execute on function public.get_class_teacher_identity(text)to authenticated;

alter table public.promotions drop constraint if exists promotions_action_check;
alter table public.promotions add constraint promotions_action_check check(action in('promote','graduate','repeat','pending','delete'));
create index if not exists promotions_report_lookup_idx on public.promotions(student_id,session,term,created_at desc);
create index if not exists promotions_name_lookup_idx on public.promotions(student_name,session,term,created_at desc);

create or replace function public.generate_timetable(p_class text,p_session text default '',p_term text default '',p_periods_per_day integer default 6)
returns jsonb language plpgsql security definer set search_path=public as $$
declare req record;occ int;placed int:=0;unplaced int:=0;ppd int:=least(greatest(coalesce(p_periods_per_day,6),1),12);chosen_day text;chosen_period int;allowed text[];unplaced_items jsonb:='[]'::jsonb;required_total int:=0;capacity int:=5*least(greatest(coalesce(p_periods_per_day,6),1),12);
begin
 if not public.is_staff(auth.uid())then return jsonb_build_object('ok',false,'error','Staff/admin role required.');end if;if coalesce(trim(p_class),'')=''then return jsonb_build_object('ok',false,'error','Select a class.');end if;
 select coalesce(sum(greatest(periods_per_week,0)),0)into required_total from public.timetable_requirements where class=p_class;if required_total=0 then return jsonb_build_object('ok',false,'error','No subject demand exists for '||p_class||'. Add each subject, teacher and periods/week first.');end if;
 delete from public.timetable where class=p_class and coalesce(session,'')=coalesce(p_session,'')and coalesce(term,'')=coalesce(p_term,'');
 for req in select * from public.timetable_requirements where class=p_class order by periods_per_week desc,subject loop
  allowed:=req.available_days;if(allowed is null or array_length(allowed,1)is null)and coalesce(req.teacher,'')<>''then select available_days into allowed from public.teacher_availability where lower(trim(teacher))=lower(trim(req.teacher))limit 1;end if;
  for occ in 1..greatest(coalesce(req.periods_per_week,0),0)loop chosen_day:=null;chosen_period:=null;
   select d.day,p.per into chosen_day,chosen_period from unnest(array['Monday','Tuesday','Wednesday','Thursday','Friday'])with ordinality d(day,dord)cross join generate_series(1,ppd)p(per)
   where(allowed is null or array_length(allowed,1)is null or exists(select 1 from unnest(allowed)a(x)where left(lower(a.x),3)=left(lower(d.day),3)))and not exists(select 1 from public.timetable t where t.class=p_class and t.day=d.day and t.period=p.per::text and coalesce(t.session,'')=coalesce(p_session,'')and coalesce(t.term,'')=coalesce(p_term,''))and(coalesce(req.teacher,'')=''or not exists(select 1 from public.timetable t where lower(trim(coalesce(t.teacher,'')))=lower(trim(req.teacher))and t.day=d.day and t.period=p.per::text and coalesce(t.session,'')=coalesce(p_session,'')and coalesce(t.term,'')=coalesce(p_term,'')))
   order by(select count(*)from public.timetable t where t.class=p_class and t.day=d.day and t.subject=req.subject and coalesce(t.session,'')=coalesce(p_session,'')and coalesce(t.term,'')=coalesce(p_term,'')),(select count(*)from public.timetable t where t.class=p_class and t.day=d.day and coalesce(t.session,'')=coalesce(p_session,'')and coalesce(t.term,'')=coalesce(p_term,'')),d.dord,p.per limit 1;
   if chosen_day is null then unplaced:=unplaced+1;unplaced_items:=unplaced_items||jsonb_build_array(jsonb_build_object('subject',req.subject,'teacher',req.teacher,'occurrence',occ,'reason','No free class/teacher slot on an allowed day'));else insert into public.timetable(class,day,period,subject,teacher,session,term)values(p_class,chosen_day,chosen_period::text,req.subject,nullif(req.teacher,''),coalesce(p_session,''),coalesce(p_term,''));placed:=placed+1;end if;
  end loop;
 end loop;
 insert into public.timetable_runs(class,session,term,generated_at,conflicts,notes)values(p_class,p_session,p_term,now(),unplaced,'Placed '||placed||' of '||required_total||' requested periods');
 return jsonb_build_object('ok',true,'placed',placed,'unplaced',unplaced,'requested',required_total,'capacity',capacity,'periods_per_day',ppd,'unplaced_items',unplaced_items,'message',case when unplaced=0 then'Conflict-free timetable generated.'else'Generated with '||unplaced||' unplaced demand(s). Review teacher days or increase periods/day.'end);
exception when others then return jsonb_build_object('ok',false,'error',sqlerrm);end$$;
revoke execute on function public.generate_timetable(text,text,text,integer)from public,anon;
grant execute on function public.generate_timetable(text,text,text,integer)to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.3 focused platform enhancements installed ✅'as status;
