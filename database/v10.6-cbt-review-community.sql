-- ============================================================================
-- School Connect V10.6 — Teacher review of manual-marked CBT questions
--                         + community records visible to every role
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql (or any earlier pack) on an EXISTING database.
-- Fresh installs get all of this from complete-schema.sql automatically.
--
-- WHAT THIS PACK DOES
-- 1. TEACHER REVIEW / SCORE AUDIT (pass-54 issue 1). Essay / code / oral /
--    peer-review questions are deliberately teacher-marked (no AI). Results
--    containing them land as grading_status='manual_review' with
--    ungraded_count>0 — but there was NO tool to award those marks. Now:
--      • cbt_results.manual_awards jsonb stores the teacher's per-question
--        awards ({"14": 3.5, "15": 5}), auditable and re-editable.
--      • cbt_review_result(p_result_id, p_awards) — staff-only RPC that
--        re-grades the whole result with the canonical V10.3 engine, folds
--        the awards in (capped at each question's mark), includes manual
--        marks in the total, updates per-subject scores, stamps reviewed_by/
--        reviewed_at, and flips grading_status to 'graded' once every
--        manual question has an award.
--      • cbt_regrade_exam_results_v5 is now AWARD-AWARE: bulk regrades keep
--        honouring saved teacher awards instead of wiping them.
-- 2. COMMUNITY RECORDS FOR EVERY ROLE (pass-54 issue 3). Lost & Found (and
--    sibling community modules) were saved with the module_records DEFAULT
--    audience='private', so RLS hid them from students/parents and the
--    dashboard Live Feed stayed empty for those roles. Backfilled to 'all'
--    (the client now stamps audience='all' on new community records).
-- ============================================================================
select 'RUNNING: School Connect CBT review + community pack V10.6' as running_version;

-- ---------------------------------------------------------------------------
-- 0. Schema
-- ---------------------------------------------------------------------------
alter table public.cbt_results add column if not exists manual_awards jsonb not null default '{}'::jsonb;
alter table public.cbt_results add column if not exists reviewed_by uuid references public.profiles(id) on delete set null;
alter table public.cbt_results add column if not exists reviewed_at timestamptz;

-- Community records must be readable by every role.
update public.module_records set audience='all'
 where module in ('lost_found','parent_meeting','cafeteria','menu','school_calendar','gallery')
   and coalesce(audience,'private') in ('private','');

-- ---------------------------------------------------------------------------
-- 1. sc_cbt_grade_result_row — one result graded by the canonical engine
--    WITH teacher awards folded in. Shared by review + bulk regrade so the
--    two paths can never disagree.
-- ---------------------------------------------------------------------------
create or replace function public.sc_cbt_grade_result_row(p_bank jsonb,p_answers jsonb,p_penalty numeric,p_awards jsonb)
returns jsonb language plpgsql immutable as $$
declare ans jsonb;q jsonb;given jsonb;key jsonb;qidx int;idx int:=0;mark numeric;score numeric:=0;total numeric:=0;cc int:=0;wc int:=0;sc int:=0;
 manual_total int:=0;manual_awarded int:=0;keyed boolean;typ text;frac numeric;awarded numeric;subject_name text;subject_scores jsonb:='{}';subject_row jsonb;
begin
 for ans in select * from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb))loop
  if jsonb_typeof(ans)='object'then qidx:=case when coalesce(ans->>'index','')~'^[0-9]+$'then(ans->>'index')::int else idx end;given:=ans->'answer';else qidx:=idx;given:=ans;end if;
  if qidx<0 or qidx>=jsonb_array_length(p_bank)then idx:=idx+1;continue;end if;
  q:=p_bank->qidx;typ:=public.sc_cbt_question_type(q);key:=public.sc_cbt_answer_value(q);
  keyed:=key is not null or (typ in('matching','ordering','categorization','matrix','multi_numeric','cloze','hot_text') and public.sc_cbt_items(q) is not null);
  begin mark:=coalesce(nullif(public.sc_cbt_json_value(q,array['mark','marks','score','points'])#>>'{}','')::numeric,1);exception when others then mark:=1;end;mark:=greatest(mark,0);
  subject_name:=coalesce(public.sc_cbt_json_value(q,array['section','subjectsection','subject','examsubject'])#>>'{}',case when jsonb_typeof(ans)='object'then nullif(ans->>'subject','')end,'General');
  subject_row:=coalesce(subject_scores->subject_name,'{"score":0,"total":0,"correct":0,"wrong":0,"skipped":0}'::jsonb);
  if not keyed then
    if typ in('essay','long_answer','file_upload','code','oral_prompt','peer_review')then
      manual_total:=manual_total+1;total:=total+mark;
      subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
      if p_awards ? qidx::text then
        begin awarded:=greatest(least(coalesce((p_awards->>qidx::text)::numeric,0),mark),0);exception when others then awarded:=0;end;
        manual_awarded:=manual_awarded+1;score:=score+awarded;
        subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+awarded));
        if awarded>=mark-0.001 then cc:=cc+1;subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
        else wc:=wc+1;subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));end if;
      end if;
      subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true);
    end if;
    idx:=idx+1;continue;
  end if;
  total:=total+mark;
  subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
  if given is null or given='null'::jsonb or(jsonb_typeof(given)='string'and public.sc_cbt_norm(given#>>'{}')='')or(jsonb_typeof(given)='array'and jsonb_array_length(given)=0)then
    sc:=sc+1;subject_row:=jsonb_set(subject_row,'{skipped}',to_jsonb(coalesce((subject_row->>'skipped')::int,0)+1));
  else
    frac:=public.sc_cbt_grade_fraction(q,given);
    if frac is null then frac:=case when public.sc_cbt_answer_matches(q,given)then 1 else 0 end;end if;
    if frac>=0.999 then score:=score+mark;cc:=cc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+mark));subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
    elsif frac<=0.001 then score:=score-coalesce(p_penalty,0);wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(greatest(coalesce((subject_row->>'score')::numeric,0)-coalesce(p_penalty,0),0)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));
    else score:=score+round(mark*frac,2);wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+round(mark*frac,2)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));end if;
  end if;
  subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true);idx:=idx+1;
 end loop;
 score:=greatest(round(score,2),0);
 return jsonb_build_object('score',score,'total',total,
  'percent',case when total>0 then round(score/total*100,2)else 0 end,
  'correct',cc,'wrong',wc,'skipped',sc,
  'manual_total',manual_total,'manual_awarded',manual_awarded,
  'manual_left',manual_total-manual_awarded,'subject_scores',subject_scores);
end$$;

-- ---------------------------------------------------------------------------
-- 2. cbt_review_result — the teacher's score-audit RPC
-- ---------------------------------------------------------------------------
create or replace function public.cbt_review_result(p_result_id uuid,p_awards jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare res record;e record;bank jsonb;merged jsonb;g jsonb;k text;v numeric;
begin
 if not public.is_staff(auth.uid())then return jsonb_build_object('ok',false,'error','Staff role required','engine_version','v5.1.4');end if;
 select * into res from public.cbt_results where id=p_result_id;
 if not found then return jsonb_build_object('ok',false,'error','Result not found','engine_version','v5.1.4');end if;
 select * into e from public.cbt_exams where id=res.exam_id;
 if not found then return jsonb_build_object('ok',false,'error','Exam not found','engine_version','v5.1.4');end if;
 if not(public.is_admin(auth.uid())or e.teacher_id=auth.uid()or public.sc_cbt_subject_allowed(auth.uid(),e.subject,e.class))then
   return jsonb_build_object('ok',false,'error','Only the exam owner, a teacher of this subject/class, or an admin can review scores.','engine_version','v5.1.4');end if;
 bank:=case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end;
 if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'error','Question bank is empty','engine_version','v5.1.4');end if;
 -- merge: new awards override, null removes an award (undo)
 merged:=coalesce(res.manual_awards,'{}'::jsonb);
 for k,v in select key,null::numeric from jsonb_each(coalesce(p_awards,'{}'::jsonb))loop
   if p_awards->k='null'::jsonb then merged:=merged-k;
   else merged:=jsonb_set(merged,array[k],p_awards->k,true);end if;
 end loop;
 g:=public.sc_cbt_grade_result_row(bank,res.answers_data,greatest(coalesce(e.negative_mark,0),0),merged);
 update public.cbt_results set
   score=(g->>'score')::numeric,total=(g->>'total')::numeric,percent=(g->>'percent')::numeric,
   correct_count=(g->>'correct')::int,wrong_count=(g->>'wrong')::int,skipped_count=(g->>'skipped')::int,
   ungraded_count=(g->>'manual_left')::int,
   grading_status=case when(g->>'manual_left')::int>0 then'manual_review'else'graded'end,
   subject_scores=g->'subject_scores',manual_awards=merged,
   reviewed_by=auth.uid(),reviewed_at=now(),engine_version='v5.1.4-reviewed'
 where id=p_result_id;
 return jsonb_build_object('ok',true,'engine_version','v5.1.4','result_id',p_result_id,
   'score',(g->>'score')::numeric,'total',(g->>'total')::numeric,'percent',(g->>'percent')::numeric,
   'manual_total',(g->>'manual_total')::int,'manual_awarded',(g->>'manual_awarded')::int,
   'manual_left',(g->>'manual_left')::int,
   'grading_status',case when(g->>'manual_left')::int>0 then'manual_review'else'graded'end,
   'release_results',e.release_results and(g->>'manual_left')::int=0);
end$$;

-- ---------------------------------------------------------------------------
-- 3. cbt_regrade_exam_results_v5 — AWARD-AWARE bulk regrade (single engine).
--    Supersedes the V10.3 definition; a bulk regrade no longer wipes the
--    teacher's saved manual awards.
-- ---------------------------------------------------------------------------
create or replace function public.cbt_regrade_exam_results_v5(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record;res record;bank jsonb;g jsonb;updated_count int:=0;no_answer_rows int:=0;
begin
 if not public.is_staff(auth.uid())then return jsonb_build_object('ok',false,'message','Staff role required','engine_version','v5.1.4');end if;
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'message','Exam not found','engine_version','v5.1.4');end if;
 bank:=case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end;
 if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'message','Question bank is empty','engine_version','v5.1.4');end if;
 for res in select * from public.cbt_results where exam_id=p_exam_id order by submitted_at loop
  if jsonb_typeof(res.answers_data)<>'array'or jsonb_array_length(res.answers_data)=0 then no_answer_rows:=no_answer_rows+1;continue;end if;
  g:=public.sc_cbt_grade_result_row(bank,res.answers_data,greatest(coalesce(e.negative_mark,0),0),coalesce(res.manual_awards,'{}'::jsonb));
  update public.cbt_results set
    score=(g->>'score')::numeric,total=(g->>'total')::numeric,percent=(g->>'percent')::numeric,
    correct_count=(g->>'correct')::int,wrong_count=(g->>'wrong')::int,skipped_count=(g->>'skipped')::int,
    ungraded_count=(g->>'manual_left')::int,
    grading_status=case when(g->>'manual_left')::int>0 then'manual_review'else'graded'end,
    subject_scores=g->'subject_scores',engine_version='v5.1.4-regraded'
  where id=res.id;updated_count:=updated_count+1;
 end loop;
 return jsonb_build_object('ok',true,'engine_version','v5.1.4','exam_id',p_exam_id,'regraded_count',updated_count,'skipped_no_answer_rows',no_answer_rows,'skipped_missing_key_rows',0);
end$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.sc_cbt_grade_result_row(jsonb,jsonb,numeric,jsonb)from public,anon,authenticated;
revoke execute on function public.cbt_review_result(uuid,jsonb)from public,anon;
grant execute on function public.cbt_review_result(uuid,jsonb)to authenticated;
revoke execute on function public.cbt_regrade_exam_results_v5(uuid)from public,anon;
grant execute on function public.cbt_regrade_exam_results_v5(uuid)to authenticated;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.6 CBT review + community pack installed' as status;
