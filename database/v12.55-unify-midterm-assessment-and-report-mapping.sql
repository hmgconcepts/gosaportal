-- ============================================================================
-- School Connect V12.55 — canonical Midterm assessment + legacy column support
--
-- One user-facing assessment purpose is now "Midterm assessment". Legacy CBT
-- values ca/test and legacy destination labels (CA1/CA2, Mid-term CA/Test,
-- Midterm, Mid Term Test/Column) remain readable and reportable.
-- Assessment purpose and report-card destination are separate concepts.
-- Generation always creates roster rows; without eligible scores it reports
-- has_scores=false rather than failing or inventing a zero mark.
-- ============================================================================
select 'RUNNING: School Connect Midterm assessment unification V12.55' as running_version;

-- Existing customer DBs may have a hand-added enum-like check that rejects the
-- new canonical value (observed constraint: cbt_exams_assessment_type_check).
-- Drop only that brittle CHECK constraint; it carries no data. Purposes are
-- validated in the UI and normalized below. Do NOT rewrite/delete any exam rows.
alter table public.cbt_exams drop constraint if exists cbt_exams_assessment_type_check;

create or replace function public.sc_is_midterm_assessment(p_type text)
returns boolean language sql immutable parallel safe set search_path=public as $$
 select regexp_replace(lower(trim(coalesce(p_type,''))),'[^a-z0-9]','','g') in
   ('ca','test','midterm','midtermtest','midtermca','midtermassessment','midtermcolumn','midtermtst');
$$;
revoke all on function public.sc_is_midterm_assessment(text) from public, anon, authenticated;

create or replace function public.sc_is_midterm_column(p_name text,p_assessment_type text default '')
returns boolean language sql immutable parallel safe set search_path=public as $$
 select
   public.sc_is_midterm_assessment(p_assessment_type)
   or regexp_replace(lower(trim(coalesce(p_name,''))),'[^a-z0-9]','','g') like 'midterm%'
   or regexp_replace(lower(trim(coalesce(p_name,''))),'[^a-z0-9]','','g') like 'ca1%'
   or regexp_replace(lower(trim(coalesce(p_name,''))),'[^a-z0-9]','','g') like 'ca2%';
$$;
revoke all on function public.sc_is_midterm_column(text,text) from public, anon, authenticated;

-- Canonicalize existing mid-term purpose values without touching the separate
-- report_column destination or any terminal/assignment records. Helpers above
-- still accept legacy values for stale clients and imported data.
update public.cbt_exams
   set assessment_type='midterm',updated_at=now()
 where regexp_replace(lower(trim(coalesce(assessment_type,''))),'[^a-z0-9]','','g')
       in ('ca','test','midtermca','midtermtest','midtermassessment','midtermcolumn')
   and lower(trim(coalesce(assessment_type,'')))<>'midterm';

-- Rebuild a report from distinct subject+assessment destinations. This avoids
-- jsonb_object_agg(subject, score) silently overwriting CA1 with CA2 for one
-- subject. The report remains separate from terminal report_cards.
create or replace function public.sc_midterm_rebuild_one(
  p_sid uuid,p_sid_ref text,p_name text,p_class text,p_term text,p_session text
) returns void language plpgsql security definer set search_path=public as $$
declare v_scores jsonb; v_total numeric; v_avg numeric;
begin
  select coalesce(jsonb_object_agg(x.score_label,x.score order by x.score_label),'{}'::jsonb),
         coalesce(sum(x.score),0),coalesce(avg(x.score),0)
    into v_scores,v_total,v_avg
  from (
    select coalesce(nullif(trim(rs.subject),''),'Unspecified subject')||' — '||coalesce(nullif(trim(ac.name),''),'Midterm') as score_label,
           sum(coalesce(rs.score,0))::numeric as score
      from public.report_scores rs
      join public.assessment_columns ac on ac.id=rs.column_id
     where rs.student_id_ref=p_sid_ref
       and regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and lower(trim(coalesce(ac.term,'')))=lower(trim(coalesce(p_term,'')))
       and lower(trim(coalesce(ac.session,'')))=lower(trim(coalesce(p_session,'')))
       and public.sc_is_midterm_column(ac.name,ac.cbt_assessment_type)
     group by coalesce(nullif(trim(rs.subject),''),'Unspecified subject'),ac.id,ac.name
  ) x;

  insert into public.midterm_report_cards(student_id,student_id_ref,student_name,class,term,session,scores,total,average,has_scores,published,updated_at)
  values(p_sid,p_sid_ref,coalesce(p_name,''),coalesce(p_class,''),coalesce(p_term,''),coalesce(p_session,''),coalesce(v_scores,'{}'::jsonb),coalesce(v_total,0),coalesce(v_avg,0),coalesce(v_scores,'{}'::jsonb)<>'{}'::jsonb,false,now())
  on conflict(student_id_ref,class,term,session) do update set
    student_id=excluded.student_id,student_name=excluded.student_name,scores=excluded.scores,
    total=excluded.total,average=excluded.average,has_scores=excluded.has_scores,updated_at=now();
end$$;
revoke execute on function public.sc_midterm_rebuild_one(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.sc_midterm_rebuild_one(uuid,text,text,text,text,text) to authenticated;

-- Generate for the complete active roster. Missing score destinations no longer
-- aborts the operation; the returned warning and has_scores state explain why.
create or replace function public.generate_midterm_reports(p_class text,p_term text,p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s record; n int:=0; cols int:=0; scored int:=0; unscored int:=0;
begin
  if auth.uid() is null or not (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) then
    return jsonb_build_object('ok',false,'error','Only staff can generate midterm reports');
  end if;
  if coalesce(trim(p_class),'')='' or coalesce(trim(p_term),'')='' or coalesce(trim(p_session),'')='' then
    return jsonb_build_object('ok',false,'error','class, term, and session are required');
  end if;

  select count(*) into cols from public.assessment_columns ac
   where regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
     and lower(trim(coalesce(ac.term,'')))=lower(trim(p_term))
     and lower(trim(coalesce(ac.session,'')))=lower(trim(p_session))
     and public.sc_is_midterm_column(ac.name,ac.cbt_assessment_type);

  for s in
    select st.id,coalesce(nullif(trim(st.admission_no),''),st.id::text) sid_ref,st.full_name,st.class
      from public.students st
     where regexp_replace(lower(trim(coalesce(st.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
       and coalesce(st.status,'active') in('active','approved')
  loop
    perform public.sc_midterm_rebuild_one(s.id,s.sid_ref,s.full_name,s.class,p_term,p_session); n:=n+1;
  end loop;

  with ranked as (
    select id,rank() over(order by average desc) pos
      from public.midterm_report_cards
     where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
       and lower(trim(coalesce(term,'')))=lower(trim(p_term))
       and lower(trim(coalesce(session,'')))=lower(trim(p_session))
  ) update public.midterm_report_cards m set position=r.pos from ranked r where m.id=r.id;

  select count(*) filter(where has_scores),count(*) filter(where not has_scores)
    into scored,unscored from public.midterm_report_cards
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(p_term))
     and lower(trim(coalesce(session,'')))=lower(trim(p_session));
  return jsonb_build_object(
    'ok',true,'generated',n,'with_scores',coalesce(scored,0),'without_scores',coalesce(unscored,0),
    'eligible_columns',cols,'warning',case when cols=0 then 'No recognized midterm score column exists for this class/term/session. Reports were created for the active roster with no-score status. Push CBT results into CA1, CA2, or a Midterm column, then generate again.' else null end,
    'class',p_class,'term',p_term,'session',p_session
  );
end$$;
grant execute on function public.generate_midterm_reports(text,text,text) to authenticated;

-- Keep the materialized Midterm report in sync on insert/delete and on both
-- old+new contexts when score rows are edited/moved. Never touches terminal cards.
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

insert into public.sc_install_state(key,details) values ('v12.55-unify-midterm-assessment-and-report-mapping.sql','{"self":true}') on conflict(key) do nothing;
notify pgrst,'reload schema';
select pg_notify('pgrst','reload schema');
select 'V12.55 canonical Midterm purpose; CA1/CA2 and legacy midterm mappings supported; roster generation no longer blocks without score columns' as status;
