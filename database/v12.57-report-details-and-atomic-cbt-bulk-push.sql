-- ============================================================================
-- School Connect V12.57 — Midterm student-sheet details + secure CBT bulk push
-- ============================================================================
select 'RUNNING: School Connect standalone reports + atomic CBT score push V12.57' as running_version;

alter table public.midterm_report_cards add column if not exists max_total numeric not null default 0;
alter table public.midterm_report_cards add column if not exists score_details jsonb not null default '[]'::jsonb;

-- Rebuild a student's separate Midterm report. Resolve ID fallbacks before
-- writing; an unlinked/anonymous result can never create a NULL identity row.
create or replace function public.sc_midterm_rebuild_one(
  p_sid uuid,p_sid_ref text,p_name text,p_class text,p_term text,p_session text
) returns void language plpgsql security definer set search_path=public as $$
declare v_ref text:=nullif(trim(coalesce(p_sid_ref,'')),''); v_student_ref text;
        v_scores jsonb; v_details jsonb; v_total numeric; v_max numeric; v_avg numeric;
begin
  if p_sid is not null then
    select coalesce(nullif(trim(st.admission_no),''),p_sid::text) into v_student_ref from public.students st where st.id=p_sid;
    if v_ref is null or v_ref=p_sid::text then v_ref:=coalesce(v_student_ref,p_sid::text); end if;
  end if;
  if v_ref is null or trim(v_ref)='' then return; end if;

  with candidates as (
    select coalesce(nullif(trim(rs.subject),''),'Unspecified subject') subject,
           coalesce(nullif(trim(ac.name),''),'Midterm') assessment,
           coalesce(rs.score,0)::numeric score,coalesce(ac.max_mark,0)::numeric max_mark,
           row_number() over(partition by coalesce(nullif(trim(rs.subject),''),'Unspecified subject'),lower(trim(coalesce(ac.name,'')))
             order by rs.updated_at desc nulls last,(ac.subject='*') desc,ac.id) rn
      from public.report_scores rs join public.assessment_columns ac on ac.id=rs.column_id
     where (nullif(trim(coalesce(rs.student_id_ref,'')),'')=v_ref or (p_sid is not null and rs.student_id=p_sid))
       and regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and lower(trim(coalesce(ac.term,'')))=lower(trim(coalesce(p_term,'')))
       and lower(trim(coalesce(ac.session,'')))=lower(trim(coalesce(p_session,'')))
       and public.sc_is_midterm_column(ac.name,ac.cbt_assessment_type)
  ), detail as (select subject,assessment,score,max_mark from candidates where rn=1)
  select coalesce(jsonb_object_agg(d.subject||' — '||d.assessment,d.score order by d.subject,d.assessment),'{}'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('subject',d.subject,'assessment',d.assessment,'score',d.score,'max_mark',d.max_mark) order by d.subject,d.assessment),'[]'::jsonb),
         coalesce(sum(d.score),0),coalesce(sum(d.max_mark),0)
    into v_scores,v_details,v_total,v_max from detail d;
  v_avg:=case when v_max>0 then round((v_total/v_max)*100,2) else 0 end;

  insert into public.midterm_report_cards(student_id,student_id_ref,student_name,class,term,session,scores,score_details,total,max_total,average,has_scores,published,updated_at)
  values(p_sid,v_ref,coalesce(nullif(trim(p_name),''),'Student'),coalesce(p_class,''),coalesce(p_term,''),coalesce(p_session,''),coalesce(v_scores,'{}'::jsonb),coalesce(v_details,'[]'::jsonb),coalesce(v_total,0),coalesce(v_max,0),coalesce(v_avg,0),coalesce(v_scores,'{}'::jsonb)<>'{}'::jsonb,false,now())
  on conflict(student_id_ref,class,term,session) do update set
    student_id=coalesce(excluded.student_id,midterm_report_cards.student_id),student_name=excluded.student_name,
    scores=excluded.scores,score_details=excluded.score_details,total=excluded.total,max_total=excluded.max_total,
    average=excluded.average,has_scores=excluded.has_scores,updated_at=now();
end$$;
revoke execute on function public.sc_midterm_rebuild_one(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.sc_midterm_rebuild_one(uuid,text,text,text,text,text) to authenticated;

-- Families may use an admission number or internal UUID fallback. Authorization
-- always checks the linked student record, and publication remains mandatory.
create or replace function public.get_midterm_report(p_student_id_ref text,p_class text,p_term text,p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare rec public.midterm_report_cards%rowtype; me uuid:=auth.uid();
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  select * into rec from public.midterm_report_cards m
   where (m.student_id_ref=p_student_id_ref or m.student_id::text=p_student_id_ref)
     and lower(trim(m.class))=lower(trim(p_class)) and lower(trim(m.term))=lower(trim(p_term)) and lower(trim(m.session))=lower(trim(p_session))
   order by case when m.student_id_ref=p_student_id_ref then 0 else 1 end limit 1;
  if not found then return jsonb_build_object('ok',false,'error','Midterm report not found. Ask tutor to generate it.'); end if;
  if not (public.is_admin(me) or public.is_staff(me)) then
    if not rec.published then return jsonb_build_object('ok',false,'error','not_published','message','This midterm report has not been released yet.'); end if;
    if not exists(select 1 from public.students st where (st.id=rec.student_id or st.id::text=rec.student_id_ref or st.admission_no=rec.student_id_ref) and (st.user_id=me or public.is_parent_of(me,st.id))) then
      return jsonb_build_object('ok',false,'error','Not authorized');
    end if;
  end if;
  return jsonb_build_object('ok',true,'report',row_to_json(rec));
end$$;
grant execute on function public.get_midterm_report(text,text,text,text) to authenticated;

-- Rank only students with actual score rows. A generated no-score sheet must
-- never receive a misleading rank/position.
create or replace function public.generate_midterm_reports(p_class text,p_term text,p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s record;n int:=0;cols int:=0;scored int:=0;unscored int:=0;
begin
  if auth.uid() is null or not (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) then return jsonb_build_object('ok',false,'error','Only staff can generate midterm reports'); end if;
  if coalesce(trim(p_class),'')='' or coalesce(trim(p_term),'')='' or coalesce(trim(p_session),'')='' then return jsonb_build_object('ok',false,'error','class, term, and session are required'); end if;
  select count(*) into cols from public.assessment_columns ac
   where regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
     and lower(trim(coalesce(ac.term,'')))=lower(trim(p_term)) and lower(trim(coalesce(ac.session,'')))=lower(trim(p_session))
     and public.sc_is_midterm_column(ac.name,ac.cbt_assessment_type);
  for s in select st.id,coalesce(nullif(trim(st.admission_no),''),st.id::text) sid_ref,st.full_name,st.class
      from public.students st where regexp_replace(lower(trim(coalesce(st.class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
       and coalesce(st.status,'active') in('active','approved')
  loop perform public.sc_midterm_rebuild_one(s.id,s.sid_ref,s.full_name,s.class,p_term,p_session);n:=n+1;end loop;
  with ranked as(select id,rank() over(order by average desc) pos from public.midterm_report_cards
    where has_scores and regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
      and lower(trim(coalesce(term,'')))=lower(trim(p_term)) and lower(trim(coalesce(session,'')))=lower(trim(p_session)))
  update public.midterm_report_cards m set position=r.pos from ranked r where m.id=r.id;
  update public.midterm_report_cards set position=null where not has_scores
    and regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
    and lower(trim(coalesce(term,'')))=lower(trim(p_term)) and lower(trim(coalesce(session,'')))=lower(trim(p_session));
  select count(*) filter(where has_scores),count(*) filter(where not has_scores) into scored,unscored from public.midterm_report_cards
    where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')=regexp_replace(lower(trim(p_class)),'[^a-z0-9]','','g')
      and lower(trim(coalesce(term,'')))=lower(trim(p_term)) and lower(trim(coalesce(session,'')))=lower(trim(p_session));
  return jsonb_build_object('ok',true,'generated',n,'with_scores',coalesce(scored,0),'without_scores',coalesce(unscored,0),'eligible_columns',cols,
    'warning',case when cols=0 then 'No recognized midterm score column exists. Roster sheets were still generated without marks; push verified results to a Midterm/CA1/CA2 column and regenerate.' else null end,
    'class',p_class,'term',p_term,'session',p_session);
end$$;
grant execute on function public.generate_midterm_reports(text,text,text) to authenticated;

-- RLS-safe counts for the preview. A staff account can inspect counts for its
-- school; an individual teacher must own or be assigned to each requested exam.
create or replace function public.sc_cbt_bulk_result_counts_v1(p_exam_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid:=auth.uid(); bad int;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  if not (public.is_admin(me) or public.is_staff(me)) then
    select count(*) into bad from unnest(coalesce(p_exam_ids,'{}'::uuid[])) x(id)
      left join public.cbt_exams e on e.id=x.id
     where e.id is null or not (e.teacher_id=me or public.teacher_can_manage_subject_class(me,e.subject,e.class));
    if coalesce(bad,0)>0 then return jsonb_build_object('ok',false,'error','Not authorized to inspect one or more exams'); end if;
  end if;
  return jsonb_build_object('ok',true,'counts',coalesce((select jsonb_agg(jsonb_build_object('exam_id',e.id,'count',coalesce(c.n,0)) order by e.created_at desc)
    from public.cbt_exams e left join lateral(select count(*)::int n from public.cbt_results r where r.exam_id=e.id)c on true
    where e.id=any(coalesce(p_exam_ids,'{}'::uuid[]))),'[]'::jsonb));
end$$;
revoke execute on function public.sc_cbt_bulk_result_counts_v1(uuid[]) from public,anon;
grant execute on function public.sc_cbt_bulk_result_counts_v1(uuid[]) to authenticated;

-- Atomic authorized score push. SECURITY DEFINER is used narrowly because the
-- current UI's direct writes to assessment_columns/report_scores hit stricter
-- teacher RLS and failed after partially processing a batch. This RPC checks the
-- caller's staff/teacher access, creates/reuses the destination safely, resolves
-- identities, filters reviewed/verified attempts, deduplicates attempts, and
-- upserts one row per student+subject+destination in one transaction.
create or replace function public.sc_cbt_bulk_push_exam_v2(
  p_exam_id uuid,p_destination text default null,p_create_missing boolean default true,
  p_max_mark numeric default 10,p_verified_only boolean default true,
  p_attempt_policy text default 'best',p_subject_filter text default null,
  p_require_midterm boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  me uuid:=auth.uid(); actor_profile uuid; e public.cbt_exams%rowtype; col public.assessment_columns%rowtype;
  dest text; saved int:=0; total_results int:=0; skipped_unverified int:=0;
  skipped_manual int:=0; skipped_unidentified int:=0; inserted_column boolean:=false; insert_count int:=0;
begin
  if me is null then return jsonb_build_object('ok',false,'error','Not authenticated'); end if;
  if coalesce(p_attempt_policy,'best') not in ('best','latest') then return jsonb_build_object('ok',false,'error','attempt_policy must be best or latest'); end if;
  select * into e from public.cbt_exams where id=p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','CBT exam not found'); end if;
  if not (public.is_admin(me) or public.is_staff(me) or e.teacher_id=me or public.teacher_can_manage_subject_class(me,e.subject,e.class)) then
    return jsonb_build_object('ok',false,'error','Not authorized to push this CBT');
  end if;
  if coalesce(p_require_midterm,false) and not public.sc_is_midterm_assessment(e.assessment_type) then
    return jsonb_build_object('ok',false,'error','purpose_filter_mismatch','message','Midterm-only push selected, but this exam is not a Mid-term Assessment. Refresh the preview.');
  end if;
  select p.id into actor_profile from public.profiles p where p.id=me;
  dest:=coalesce(nullif(trim(p_destination),''),nullif(trim(e.report_column),''),'CBT / Online Exam');
  if coalesce(trim(e.class),'')='' or coalesce(trim(e.term),'')='' or coalesce(trim(e.session),'')='' then
    return jsonb_build_object('ok',false,'error','CBT is missing class, term, or session metadata');
  end if;
  if p_max_mark is not null and p_max_mark<=0 then return jsonb_build_object('ok',false,'error','Destination maximum mark must be greater than zero'); end if;
  if not exists(select 1 from public.cbt_results r left join public.students st on st.id=r.student_id
    where r.exam_id=e.id and coalesce(r.grading_status,'graded')='graded'
      and (not p_verified_only or coalesce(r.engine_version,'') like 'v5.1%')
      and (nullif(trim(coalesce(r.student_id_ref,'')),'') is not null or nullif(trim(coalesce(st.admission_no,'')),'') is not null or r.student_id is not null)) then
    return jsonb_build_object('ok',false,'error','No eligible identified result','message','No graded result with a usable student identity is available for this push. No destination column or score row was created.');
  end if;

  perform pg_advisory_xact_lock(hashtext(lower(trim(e.class))||'|'||lower(trim(e.term))||'|'||lower(trim(e.session))||'|'||lower(trim(dest))));
  select * into col from public.assessment_columns ac
   where ac.class=e.class and ac.subject='*' and lower(trim(ac.term))=lower(trim(e.term))
     and lower(trim(ac.session))=lower(trim(e.session)) and lower(trim(ac.name))=lower(trim(dest))
   order by ac.created_at asc limit 1;
  if col.id is null then
    if not coalesce(p_create_missing,false) then return jsonb_build_object('ok',false,'error','Missing destination column','message','No global report column "'||dest||'" exists for this class/term/session. Enable safe auto-create or create it in Report Cards.'); end if;
    insert into public.assessment_columns(class,subject,term,session,name,max_mark,weight,position,source,cbt_assessment_type,created_by)
    values(e.class,'*',e.term,e.session,dest,coalesce(nullif(p_max_mark,0),nullif(e.max_score,0),10),1,
      coalesce((select max(position)+1 from public.assessment_columns where class=e.class and subject='*' and term=e.term and session=e.session),0),
      'cbt',coalesce(e.assessment_type,'exam'),actor_profile)
    on conflict(class,subject,term,session,name) do nothing;
    get diagnostics insert_count=row_count;inserted_column:=insert_count=1;
    select * into col from public.assessment_columns ac
     where ac.class=e.class and ac.subject='*' and lower(trim(ac.term))=lower(trim(e.term))
       and lower(trim(ac.session))=lower(trim(e.session)) and lower(trim(ac.name))=lower(trim(dest))
     order by ac.created_at asc limit 1;
    if col.id is null then return jsonb_build_object('ok',false,'error','Destination column create/read-back failed'); end if;
  end if;

  select count(*) into total_results from public.cbt_results r where r.exam_id=e.id;
  select count(*) into skipped_manual from public.cbt_results r where r.exam_id=e.id and coalesce(r.grading_status,'graded')<>'graded';
  select count(*) into skipped_unverified from public.cbt_results r where r.exam_id=e.id
    and coalesce(r.grading_status,'graded')='graded' and p_verified_only and coalesce(r.engine_version,'') not like 'v5.1%';
  select count(*) into skipped_unidentified from public.cbt_results r left join public.students st on st.id=r.student_id
   where r.exam_id=e.id and coalesce(r.grading_status,'graded')='graded'
     and (not p_verified_only or coalesce(r.engine_version,'') like 'v5.1%')
     and nullif(trim(coalesce(r.student_id_ref,'')), '') is null
     and nullif(trim(coalesce(st.admission_no,'')), '') is null and r.student_id is null;

  with base as (
    select r.id result_id,r.student_id,
      coalesce(nullif(trim(r.student_id_ref),''),nullif(trim(st.admission_no),''),r.student_id::text) student_ref,
      coalesce(nullif(trim(st.full_name),''),nullif(trim(r.student_name),''),'Student') student_name,
      coalesce(nullif(trim(e.class),''),nullif(trim(r.student_class),''),nullif(trim(st.class),''),'') class_name,
      coalesce(nullif(trim(e.subject),''),'CBT') exam_subject,coalesce(r.subject_scores,'{}'::jsonb) subject_scores,
      coalesce(r.percent,case when r.total>0 then (r.score/r.total)*100 else 0 end) pct,r.created_at
    from public.cbt_results r left join public.students st on st.id=r.student_id
    where r.exam_id=e.id and coalesce(r.grading_status,'graded')='graded'
      and (not p_verified_only or coalesce(r.engine_version,'') like 'v5.1%')
  ), parts as (
    select b.result_id,b.student_id,b.student_ref,b.student_name,b.class_name,trim(k.key) subject,
      case when jsonb_typeof(k.value)='object' and coalesce(k.value->>'total','') ~ '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$' and (k.value->>'total')::numeric>0
           then (case when coalesce(k.value->>'score','') ~ '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$' then (k.value->>'score')::numeric else 0 end/(k.value->>'total')::numeric)*100 else b.pct end pct,b.created_at
    from base b cross join lateral jsonb_each(case when jsonb_typeof(b.subject_scores)='object' then b.subject_scores else '{}'::jsonb end) k
    where nullif(trim(k.key),'') is not null
    union all
    select b.result_id,b.student_id,b.student_ref,b.student_name,b.class_name,b.exam_subject,b.pct,b.created_at
    from base b where (jsonb_typeof(b.subject_scores)<>'object' or b.subject_scores='{}'::jsonb) and upper(b.exam_subject) not like 'MULTI-SUBJECT%'
  ), filtered as (
    select * from parts where nullif(trim(student_ref),'') is not null
      and (coalesce(trim(p_subject_filter),'')='' or lower(subject)=lower(trim(p_subject_filter)))
  ), ranked as (
    select f.*,row_number() over(partition by f.student_ref,f.subject
      order by case when p_attempt_policy='best' then f.pct end desc nulls last,
               case when p_attempt_policy='latest' then f.created_at end desc nulls last,
               f.created_at desc,f.result_id desc) rn from filtered f
  ), chosen as (
    select r.*,coalesce((select rs.student_name from public.report_scores rs where rs.column_id=col.id and rs.student_id_ref=r.student_ref
      and rs.class=r.class_name and rs.subject=r.subject and rs.term=e.term and rs.session=e.session order by rs.updated_at desc limit 1),r.student_name) display_name
    from ranked r where rn=1
  )
  insert into public.report_scores(column_id,student_id,student_id_ref,student_name,class,subject,term,session,score,source,updated_by,updated_at)
  select col.id,c.student_id,c.student_ref,c.display_name,c.class_name,c.subject,e.term,e.session,
    round((c.pct/100)*coalesce(col.max_mark,10),2),'cbt:'||c.result_id::text,actor_profile,now() from chosen c
  on conflict(column_id,student_id_ref,student_name,class,subject,term,session) do update set
    student_id=coalesce(excluded.student_id,report_scores.student_id),score=excluded.score,
    source=excluded.source,updated_by=excluded.updated_by,updated_at=now();
  get diagnostics saved=row_count;
  return jsonb_build_object('ok',true,'exam_id',e.id,'code',e.code,'destination',col.name,'column_id',col.id,
    'created_column',inserted_column,'total_results',total_results,'saved',saved,'skipped_unverified',skipped_unverified,
    'skipped_manual',skipped_manual,'skipped_unidentified',skipped_unidentified,'attempt_policy',p_attempt_policy,
    'dedupe_key','student + subject + destination');
exception when others then return jsonb_build_object('ok',false,'error',sqlerrm,'sqlstate',sqlstate);
end$$;
revoke execute on function public.sc_cbt_bulk_push_exam_v2(uuid,text,boolean,numeric,boolean,text,text,boolean) from public,anon;
grant execute on function public.sc_cbt_bulk_push_exam_v2(uuid,text,boolean,numeric,boolean,text,text,boolean) to authenticated;

insert into public.sc_install_state(key,details) values ('v12.57-report-details-and-atomic-cbt-bulk-push.sql',jsonb_build_object('self',true)) on conflict(key) do nothing;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V12.57 standalone Midterm sheet details and RLS-safe/deduplicated CBT bulk score push installed' as status;
