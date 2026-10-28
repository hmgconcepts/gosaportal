-- ============================================================================
-- School Connect V12.52 — Midterm reports include every class student + context sync
-- ----------------------------------------------------------------------------
-- Deep edge-case found after V12.47/48:
-- 1) generate_midterm_reports iterated report_scores only, so absent/no-score
--    students had no sheet at all. Requirement says each student/parent can see
--    a midterm sheet; include every active registered student in class with
--    has_scores=false (not a misleading zero score).
-- 2) V12.48 report_scores trigger refreshed only NEW context on UPDATE. Moving
--    a score from one class/term/column to another could leave a stale midterm
--    report in the OLD context. Refresh both OLD and NEW contexts atomically.
-- 3) Class/term spelling variations should normalize alphanumeric; midterm
--    filter is separate from terminal and includes only Midterm/Test columns.
-- ============================================================================
select 'RUNNING: School Connect midterm roster-complete + context-sync V12.52' as running_version;

alter table public.midterm_report_cards add column if not exists has_scores boolean not null default true;

-- Internal helper: recalculate one student/context from Midterm columns only.
create or replace function public.sc_midterm_rebuild_one(p_sid uuid,p_sid_ref text,p_name text,p_class text,p_term text,p_session text)
returns void language plpgsql security definer set search_path=public as $$
declare v_scores jsonb; v_total numeric; v_avg numeric; v_cols uuid[];
begin
 select array_agg(id) into v_cols from public.assessment_columns ac
  where regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
    and lower(trim(coalesce(ac.term,'')))=lower(trim(coalesce(p_term,'')))
    and lower(trim(coalesce(ac.session,'')))=lower(trim(coalesce(p_session,'')))
    and (lower(trim(coalesce(ac.name,''))) like 'midterm%' or lower(trim(coalesce(ac.cbt_assessment_type,''))) in('test','midterm','mid_term','mid_term_test'));
 select coalesce(jsonb_object_agg(rs.subject,rs.score order by rs.subject),'{}'::jsonb),coalesce(sum(rs.score),0),coalesce(avg(rs.score),0)
  into v_scores,v_total,v_avg from public.report_scores rs where rs.student_id_ref=p_sid_ref and v_cols is not null and rs.column_id=any(v_cols);
 insert into public.midterm_report_cards(student_id,student_id_ref,student_name,class,term,session,scores,total,average,has_scores,published,updated_at)
 values(p_sid,p_sid_ref,coalesce(p_name,''),coalesce(p_class,''),coalesce(p_term,''),coalesce(p_session,''),coalesce(v_scores,'{}'::jsonb),coalesce(v_total,0),coalesce(v_avg,0),coalesce(v_scores,'{}'::jsonb)<>'{}'::jsonb,false,now())
 on conflict(student_id_ref,class,term,session) do update set student_id=excluded.student_id,student_name=excluded.student_name,scores=excluded.scores,total=excluded.total,average=excluded.average,has_scores=excluded.has_scores,updated_at=now();
end$$;
revoke execute on function public.sc_midterm_rebuild_one(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.sc_midterm_rebuild_one(uuid,text,text,text,text,text) to authenticated;

-- Complete roster: every active student gets a sheet row, even absent/no result.
create or replace function public.generate_midterm_reports(p_class text,p_term text,p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s record; n int:=0; cols int:=0;
begin
 if not (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) then return jsonb_build_object('ok',false,'error','Only staff can generate midterm reports'); end if;
 if coalesce(trim(p_class),'')='' or coalesce(trim(p_term),'')='' or coalesce(trim(p_session),'')='' then return jsonb_build_object('ok',false,'error','class, term, session required'); end if;
 select count(*) into cols from public.assessment_columns ac where regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g') and lower(trim(coalesce(ac.term,'')))=lower(trim(p_term)) and lower(trim(coalesce(ac.session,'')))=lower(trim(p_session)) and (lower(trim(coalesce(ac.name,''))) like 'midterm%' or lower(trim(coalesce(ac.cbt_assessment_type,''))) in('test','midterm','mid_term','mid_term_test'));
 if cols=0 then return jsonb_build_object('ok',false,'error','No Midterm column found for class/term/session. Create a Midterm Test CBT and push its scores to a column named Midterm first.'); end if;
 for s in select st.id,coalesce(nullif(trim(st.admission_no),''),st.id::text) sid_ref,st.full_name,st.class from public.students st where regexp_replace(lower(trim(coalesce(st.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g') and coalesce(st.status,'active') in('active','approved') loop
   perform public.sc_midterm_rebuild_one(s.id,s.sid_ref,s.full_name,s.class,p_term,p_session); n:=n+1;
 end loop;
 with ranked as(select id,rank() over(order by average desc) pos from public.midterm_report_cards where regexp_replace(lower(trim(class)),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g') and term=p_term and session=p_session)
 update public.midterm_report_cards m set position=r.pos from ranked r where m.id=r.id;
 return jsonb_build_object('ok',true,'generated',n,'with_scores',(select count(*) from public.midterm_report_cards where class=p_class and term=p_term and session=p_session and has_scores),'without_scores',(select count(*) from public.midterm_report_cards where class=p_class and term=p_term and session=p_session and not has_scores),'class',p_class,'term',p_term,'session',p_session);
end$$;
grant execute on function public.generate_midterm_reports(text,text,text) to authenticated;

-- Refresh both OLD and NEW context on report_score UPDATE; old midterm sheets
-- cannot remain stale when a teacher moves a row across class/term/column.
create or replace function public.sc_refresh_midterm_report_for_score()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='DELETE' or tg_op='UPDATE' then
   perform public.sc_midterm_rebuild_one(old.student_id,coalesce(nullif(old.student_id_ref,''),old.student_id::text),old.student_name,old.class,old.term,old.session);
 end if;
 if tg_op='INSERT' or tg_op='UPDATE' then
   perform public.sc_midterm_rebuild_one(new.student_id,coalesce(nullif(new.student_id_ref,''),new.student_id::text),new.student_name,new.class,new.term,new.session);
 end if;
 if tg_op='DELETE' then return old; else return new; end if;
end$$;
drop trigger if exists trg_midterm_report_sync on public.report_scores;
create trigger trg_midterm_report_sync after insert or update or delete on public.report_scores for each row execute function public.sc_refresh_midterm_report_for_score();

insert into public.sc_install_state(key,details) values ('v12.52-midterm-roster-complete-and-context-sync.sql','{"self":true}') on conflict(key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.52 midterm reports cover every active class student and refresh old/new contexts atomically' as status;
