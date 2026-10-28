-- SCHOOL CONNECT CBT V5.1 ZERO-SCORE HOTFIX (existing databases)
-- Generated from the canonical complete schema. Back up Supabase before running.
-- For fresh projects run complete-schema.sql instead. This file is idempotent.

alter table public.cbt_exams add column if not exists questions jsonb not null default '[]'::jsonb;
alter table public.cbt_exams add column if not exists duration_min int default 45;
alter table public.cbt_exams add column if not exists created_at timestamptz default now();
alter table public.cbt_exams add column if not exists updated_at timestamptz default now();
alter table public.cbt_results add column if not exists client_ref text;
alter table public.cbt_results add column if not exists subject_scores jsonb not null default '{}'::jsonb;
alter table public.cbt_results add column if not exists correct_count int default 0;
alter table public.cbt_results add column if not exists wrong_count int default 0;
alter table public.cbt_results add column if not exists skipped_count int default 0;
alter table public.cbt_results add column if not exists violation_log jsonb default '[]'::jsonb;
alter table public.cbt_results add column if not exists submitted_at timestamptz default now();
alter table public.cbt_results alter column total type numeric(10,2) using total::numeric;
create unique index if not exists cbt_results_client_ref_uidx on public.cbt_results(exam_id,client_ref) where client_ref is not null and client_ref<>'';
create or replace function public.sc_cbt_norm(p_value text)returns text language sql immutable parallel safe as $$select lower(regexp_replace(trim(coalesce(p_value,'')),'\s+',' ','g'))$$;

-- ============================================================================
-- SECTION 22: CBT V5.1 DEFINITIVE GRADING ENGINE
-- A distinct RPC name prevents stale/legacy PostgREST overloads from silently
-- returning zero. Legacy answer-key spellings are normalised case-insensitively.
-- ============================================================================

alter table public.cbt_results add column if not exists ungraded_count int not null default 0;
alter table public.cbt_results add column if not exists grading_status text not null default 'graded';
alter table public.cbt_results add column if not exists engine_version text not null default '';

create or replace function public.sc_cbt_json_value(p_object jsonb,p_keys text[])
returns jsonb language sql immutable parallel safe as $$
  select e.value from jsonb_each(coalesce(p_object,'{}'::jsonb)) e
   where regexp_replace(lower(e.key),'[^a-z0-9]','','g')=any(p_keys)
   order by array_position(p_keys,regexp_replace(lower(e.key),'[^a-z0-9]','','g')) nulls last
   limit 1
$$;

create or replace function public.sc_cbt_options(p_question jsonb)
returns text[] language plpgsql immutable parallel safe as $$
declare raw jsonb; elem jsonb; value text; result text[]:='{}'; keyset text[][]:=array[
 array['a','optiona','opta','choicea','option1'],array['b','optionb','optb','choiceb','option2'],
 array['c','optionc','optc','choicec','option3'],array['d','optiond','optd','choiced','option4'],
 array['e','optione','opte','choicee','option5']]; keys text[];
begin
 raw:=public.sc_cbt_json_value(p_question,array['options','choices','optionlist','choiceoptions']);
 if jsonb_typeof(raw)='array' then
   for elem in select * from jsonb_array_elements(raw) loop
     if jsonb_typeof(elem)='object' then
       value:=coalesce(public.sc_cbt_json_value(elem,array['text','label','value','option'])#>>'{}',elem::text);
     else value:=elem#>>'{}'; end if;
     if coalesce(trim(value),'')<>'' then result:=array_append(result,value); end if;
   end loop;
 elsif jsonb_typeof(raw)='object' then
   for elem in select value from jsonb_each(raw) order by key loop
     value:=case when jsonb_typeof(elem)='object' then coalesce(public.sc_cbt_json_value(elem,array['text','label','value','option'])#>>'{}',elem::text) else elem#>>'{}' end;
     if coalesce(trim(value),'')<>'' then result:=array_append(result,value); end if;
   end loop;
 elsif jsonb_typeof(raw)='string' then
   result:=regexp_split_to_array(raw#>>'{}','\s*[|;]\s*');
 end if;
 if coalesce(array_length(result,1),0)=0 then
   foreach keys slice 1 in array keyset loop
     raw:=public.sc_cbt_json_value(p_question,keys); value:=case when raw is null then null else raw#>>'{}' end;
     if coalesce(trim(value),'')<>'' then result:=array_append(result,value); end if;
   end loop;
 end if;
 return coalesce(result,'{}'::text[]);
end $$;

create or replace function public.sc_cbt_answer_value(p_question jsonb)
returns jsonb language plpgsql immutable parallel safe as $$
declare answer jsonb;
begin
 answer:=public.sc_cbt_json_value(p_question,array['answer','correct','correctanswer','answerkey','correctoption','key','solutionanswer','rightanswer']);
 if jsonb_typeof(answer)='object' then answer:=coalesce(public.sc_cbt_json_value(answer,array['value','answer','key','text','label']),answer); end if;
 return answer;
end $$;

create or replace function public.sc_cbt_question_type(p_question jsonb)
returns text language plpgsql immutable parallel safe as $$
declare raw jsonb; typ text;
begin
 raw:=public.sc_cbt_json_value(p_question,array['type','questiontype']); typ:=lower(regexp_replace(coalesce(raw#>>'{}','mcq'),'[^a-z0-9]+','_','g'));
 if typ in ('tf','boolean','truefalse','true_or_false','yes_no','yesno') then return 'true_false'; end if;
 if typ in ('multiplechoice','multiple_choice','singlechoice','single_choice','objective') then return 'mcq'; end if;
 if typ in ('mrq','multiple_response','multiple_responses','multiple_select','multiselect','checkbox','checkboxes') then return 'multi_select'; end if;
 if typ in ('number','integer','decimal','calculation') then return 'numeric'; end if;
 if typ in ('short','text','free_text') then return 'short_answer'; end if;
 return typ;
end $$;

create or replace function public.sc_cbt_canonical_option(p_question jsonb,p_value text)
returns text language plpgsql immutable parallel safe as $$
declare opts text[]:=public.sc_cbt_options(p_question); val text:=public.sc_cbt_norm(p_value); idx int; typ text:=public.sc_cbt_question_type(p_question);
begin
 if typ='true_false' and coalesce(array_length(opts,1),0)=0 then opts:=array['true','false']; end if;
 if val~'^(option|choice)[ _-]*[a-z]$' then val:=right(val,1); end if;
 if val~'^[a-z]$' then idx:=ascii(val)-ascii('a')+1; if idx between 1 and coalesce(array_length(opts,1),0) then return public.sc_cbt_norm(opts[idx]); end if; end if;
 return val;
end $$;

create or replace function public.sc_cbt_answer_matches(p_question jsonb,p_given jsonb)
returns boolean language plpgsql immutable parallel safe as $$
declare expected jsonb:=public.sc_cbt_answer_value(p_question); accepted jsonb:=public.sc_cbt_json_value(p_question,array['accept','acceptedanswers','alternateanswers','alternatives']);
 typ text:=public.sc_cbt_question_type(p_question); given_value jsonb:=p_given; given_text text; expected_text text; token text;
 given_tokens text[]:='{}'; expected_tokens text[]:='{}'; opts text[]:=public.sc_cbt_options(p_question); n int; tol numeric; gv numeric; ev numeric;
begin
 if given_value is null or given_value='null'::jsonb or expected is null or expected='null'::jsonb then return false; end if;
 if jsonb_typeof(given_value)='object' then given_value:=coalesce(public.sc_cbt_json_value(given_value,array['value','answer','key','text','label']),given_value); end if;
 if typ='numeric' then
   begin
     given_text:=case when jsonb_typeof(given_value)='string' then given_value#>>'{}' else trim(both '"' from given_value::text) end;
     expected_text:=case when jsonb_typeof(expected)='string' then expected#>>'{}' else trim(both '"' from expected::text) end;
     gv:=given_text::numeric;ev:=expected_text::numeric;
     begin tol:=abs(coalesce(nullif(public.sc_cbt_json_value(p_question,array['tolerance','margin'])#>>'{}','')::numeric,0.0001)); exception when others then tol:=0.0001; end;
     return abs(gv-ev)<=tol;
   exception when others then return false; end;
 end if;
 if typ='multi_select' or jsonb_typeof(given_value)='array' then
   if jsonb_typeof(given_value)='array' then
     for token in select jsonb_array_elements_text(given_value) loop given_tokens:=array_append(given_tokens,public.sc_cbt_canonical_option(p_question,token)); end loop;
   else
     given_text:=given_value#>>'{}'; foreach token in array regexp_split_to_array(coalesce(given_text,''),'\s*[,;|]\s*') loop if trim(token)<>'' then given_tokens:=array_append(given_tokens,public.sc_cbt_canonical_option(p_question,token));end if;end loop;
   end if;
   if jsonb_typeof(expected)='array' then
     for token in select jsonb_array_elements_text(expected) loop expected_tokens:=array_append(expected_tokens,public.sc_cbt_canonical_option(p_question,token)); end loop;
   else
     expected_text:=expected#>>'{}'; foreach token in array regexp_split_to_array(coalesce(expected_text,''),'\s*[,;|]\s*') loop if trim(token)<>'' then expected_tokens:=array_append(expected_tokens,public.sc_cbt_canonical_option(p_question,token));end if;end loop;
   end if;
   select coalesce(array_agg(distinct x order by x),'{}'::text[]) into given_tokens from unnest(given_tokens)x;
   select coalesce(array_agg(distinct x order by x),'{}'::text[]) into expected_tokens from unnest(expected_tokens)x;
   return coalesce(array_length(expected_tokens,1),0)>0 and given_tokens=expected_tokens;
 end if;
 given_text:=case when jsonb_typeof(given_value)='string' then given_value#>>'{}' else trim(both '"' from given_value::text) end;
 if jsonb_typeof(expected)='array' then
   for token in select jsonb_array_elements_text(expected) loop if public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_canonical_option(p_question,token) then return true;end if;end loop;
 else
   expected_text:=case when jsonb_typeof(expected)='string' then expected#>>'{}' else trim(both '"' from expected::text) end;
   if public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_canonical_option(p_question,expected_text) then return true;end if;
   -- Legacy banks sometimes stored an option index rather than a letter. Accept
   -- both zero-based and one-based conventions only when the literal is not an option.
   if expected_text~'^[0-9]+$' and not(public.sc_cbt_norm(expected_text)=any(select public.sc_cbt_norm(x) from unnest(opts)x)) then
     n:=expected_text::int;
     if n between 0 and coalesce(array_length(opts,1),0)-1 and public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_norm(opts[n+1]) then return true;end if;
     if n between 1 and coalesce(array_length(opts,1),0) and public.sc_cbt_canonical_option(p_question,given_text)=public.sc_cbt_norm(opts[n]) then return true;end if;
   end if;
 end if;
 if accepted is not null then
   if jsonb_typeof(accepted)='array' then for token in select jsonb_array_elements_text(accepted) loop if public.sc_cbt_norm(given_text)=public.sc_cbt_norm(token) then return true;end if;end loop;
   else foreach token in array regexp_split_to_array(coalesce(accepted#>>'{}',''),'\s*[|;]\s*') loop if public.sc_cbt_norm(given_text)=public.sc_cbt_norm(token) then return true;end if;end loop; end if;
 end if;
 return false;
end $$;

create or replace function public.sc_cbt_normalize_question(p_question jsonb)
returns jsonb language plpgsql immutable parallel safe as $$
declare outq jsonb:=coalesce(p_question,'{}'::jsonb); answer jsonb:=public.sc_cbt_answer_value(p_question); opts text[]:=public.sc_cbt_options(p_question); typ text:=public.sc_cbt_question_type(p_question); raw jsonb;
begin
 if answer is not null then outq:=outq||jsonb_build_object('answer',answer);end if;
 if coalesce(array_length(opts,1),0)>0 then outq:=outq||jsonb_build_object('options',to_jsonb(opts));end if;
 outq:=outq||jsonb_build_object('type',typ);
 raw:=public.sc_cbt_json_value(p_question,array['mark','marks','score','points']);if raw is not null then outq:=outq||jsonb_build_object('mark',raw);end if;
 raw:=public.sc_cbt_json_value(p_question,array['section','subjectsection','subject','examsubject']);if raw is not null then outq:=outq||jsonb_build_object('section',raw,'subject',raw);end if;
 return outq;
end $$;

create or replace function public.cbt_diagnose_exam(p_exam_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record;bank jsonb;q jsonb;i int:=0;gradable int:=0;manual_count int:=0;missing int[]:='{}';typ text;source text;
begin
 if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'message','Staff role required');end if;
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'message','Exam not found');end if;
 if jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then bank:=e.csv_data;source:='csv_data';elsif jsonb_typeof(e.questions)='array' then bank:=e.questions;source:='questions';else bank:='[]';source:='empty';end if;
 for q in select * from jsonb_array_elements(bank) loop typ:=public.sc_cbt_question_type(q);if typ in('essay','long_answer','file_upload') and public.sc_cbt_answer_value(q)is null then manual_count:=manual_count+1;elsif public.sc_cbt_answer_value(q)is null then missing:=array_append(missing,i);else gradable:=gradable+1;end if;i:=i+1;end loop;
 return jsonb_build_object('ok',true,'engine_version','v5.1.0','exam_id',e.id,'code',e.code,'bank_source',source,'question_count',jsonb_array_length(bank),'gradable_count',gradable,'manual_review_count',manual_count,'missing_answer_indexes',to_jsonb(missing));
end $$;

create or replace function public.cbt_repair_exam_scoring(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record;bank jsonb;fixed jsonb;
begin
 if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'message','Staff role required');end if;
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'message','Exam not found');end if;
 bank:=case when jsonb_typeof(e.csv_data)='array' and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array' then e.questions else '[]'::jsonb end;
 select coalesce(jsonb_agg(public.sc_cbt_normalize_question(q)order by ord),'[]'::jsonb)into fixed from jsonb_array_elements(bank)with ordinality x(q,ord);
 update public.cbt_exams set csv_data=fixed,questions=fixed,updated_at=now()where id=p_exam_id;
 return public.cbt_diagnose_exam(p_exam_id);
end $$;

-- Automatically add canonical answer/options/type fields to existing banks.
do $$ declare r record;fixed jsonb;begin
 for r in select id,(case when jsonb_typeof(csv_data)='array'and jsonb_array_length(csv_data)>0 then csv_data when jsonb_typeof(questions)='array'then questions else '[]'::jsonb end)bank from public.cbt_exams loop
  select coalesce(jsonb_agg(public.sc_cbt_normalize_question(q)order by ord),'[]'::jsonb)into fixed from jsonb_array_elements(r.bank)with ordinality x(q,ord);
  update public.cbt_exams set csv_data=fixed,questions=fixed,updated_at=now()where id=r.id;
 end loop;
end $$;

create or replace function public.cbt_submit_v5(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record;r record;rid uuid;sid uuid;taken int:=0;idx int:=0;qidx int;score numeric:=0;total numeric:=0;cc int:=0;wc int:=0;sc int:=0;manual_count int:=0;missing_count int:=0;
 ans jsonb;q jsonb;bank jsonb;given jsonb;answer_key jsonb;mark numeric;penalty numeric;ref text:=nullif(p_payload->>'client_ref','');pct numeric;grade text;idref text:=trim(coalesce(p_payload->>'student_id_ref',''));typ text;subject_name text;subject_scores jsonb:='{}';subject_row jsonb;missing_indexes int[]:='{}';offline_override boolean:=coalesce((p_payload->>'offline_override')::boolean,false)and public.is_staff(auth.uid());effective_release boolean;
begin
 select * into e from public.cbt_exams where id=(p_payload->>'exam_id')::uuid;if not found then return jsonb_build_object('saved',false,'error','exam_not_found','message','Exam not found.','engine_version','v5.1.0');end if;
 if not offline_override then
  if not coalesce(e.is_open,false)or coalesce(e.is_archived,false)then return jsonb_build_object('saved',false,'error','closed','message','This exam is not open.','engine_version','v5.1.0');end if;
  if e.start_at is not null and now()<e.start_at then return jsonb_build_object('saved',false,'error','not_started','message','This exam has not started.','engine_version','v5.1.0');end if;
  if e.close_at is not null and now()>e.close_at+interval'120 seconds'then return jsonb_build_object('saved',false,'error','closed','message','This exam has closed.','engine_version','v5.1.0');end if;
 end if;
 if ref is not null then select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;if found then return jsonb_build_object('saved',true,'duplicate',true,'engine_version',coalesce(nullif(r.engine_version,''),'v5.1.0'),'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,'grade',case when r.percent>=75 then'A'when r.percent>=60 then'B'when r.percent>=50 then'C'when r.percent>=40 then'D'else'F'end,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'ungraded_count',r.ungraded_count,'grading_status',r.grading_status,'cert_code',r.cert_code,'subject_scores',r.subject_scores,'release_results',e.release_results and r.grading_status='graded','report_column',e.report_column);end if;end if;
 if not offline_override and idref<>''and coalesce(e.attempt_limit,0)>0 then select count(*)into taken from public.cbt_results where exam_id=e.id and student_id_ref=idref;if taken>=e.attempt_limit then return jsonb_build_object('saved',false,'error','attempts_exhausted','message','Attempt limit reached.','engine_version','v5.1.0');end if;end if;
 bank:=case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end;
 if jsonb_array_length(bank)=0 then return jsonb_build_object('saved',false,'error','question_bank_empty','message','The exam question bank is empty.','engine_version','v5.1.0');end if;
 penalty:=greatest(coalesce(e.negative_mark,0),0);
 for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb))loop
  qidx:=case when coalesce(ans->>'index','')~'^[0-9]+$'then(ans->>'index')::int else idx end;if qidx<0 or qidx>=jsonb_array_length(bank)then idx:=idx+1;continue;end if;q:=bank->qidx;typ:=public.sc_cbt_question_type(q);answer_key:=public.sc_cbt_answer_value(q);
  if answer_key is null then if typ in('essay','long_answer','file_upload')then manual_count:=manual_count+1;else missing_count:=missing_count+1;missing_indexes:=array_append(missing_indexes,qidx);end if;idx:=idx+1;continue;end if;
  begin mark:=coalesce(nullif(public.sc_cbt_json_value(q,array['mark','marks','score','points'])#>>'{}','')::numeric,1);exception when others then mark:=1;end;mark:=greatest(mark,0);total:=total+mark;given:=ans->'answer';
  subject_name:=coalesce(public.sc_cbt_json_value(q,array['section','subjectsection','subject','examsubject'])#>>'{}',nullif(ans->>'subject',''),'General');subject_row:=coalesce(subject_scores->subject_name,'{"score":0,"total":0,"correct":0,"wrong":0,"skipped":0}'::jsonb);subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
  if given is null or given='null'::jsonb or(jsonb_typeof(given)='string'and public.sc_cbt_norm(given#>>'{}')='')or(jsonb_typeof(given)='array'and jsonb_array_length(given)=0)then sc:=sc+1;subject_row:=jsonb_set(subject_row,'{skipped}',to_jsonb(coalesce((subject_row->>'skipped')::int,0)+1));
  elsif public.sc_cbt_answer_matches(q,given)then score:=score+mark;cc:=cc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+mark));subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
  else score:=score-penalty;wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(greatest(coalesce((subject_row->>'score')::numeric,0)-penalty,0)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));end if;
  subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true);idx:=idx+1;
 end loop;
 if missing_count>0 then return jsonb_build_object('saved',false,'error','answer_key_missing','message','This exam has '||missing_count||' objective question(s) without a recognised correct answer key. Ask the exam officer to use Diagnose Scoring / Repair Scoring, then submit again.','missing_answer_indexes',to_jsonb(missing_indexes),'engine_version','v5.1.0');end if;
 score:=greatest(round(score,2),0);pct:=case when total>0 then round(score/total*100,2)else 0 end;grade:=case when pct>=75 then'A'when pct>=60 then'B'when pct>=50 then'C'when pct>=40 then'D'else'F'end;
 if coalesce(p_payload->>'student_id','')~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'then sid:=(p_payload->>'student_id')::uuid;end if;if sid is null and idref<>''then select id into sid from public.students where admission_no=idref limit 1;end if;effective_release:=e.release_results and manual_count=0;
 insert into public.cbt_results(exam_id,student_id,student_name,student_class,student_id_ref,student_type,score,total,percent,correct_count,wrong_count,skipped_count,ungraded_count,grading_status,engine_version,attempt_number,time_taken,violations,violation_log,answers_data,cert_code,client_ref,subject_scores)
 values(e.id,sid,coalesce(nullif(p_payload->>'student_name',''),'Anonymous'),coalesce(nullif(p_payload->>'student_class',''),e.class),idref,coalesce(p_payload->>'student_type',e.exam_mode),score,total,pct,cc,wc,sc,manual_count,case when manual_count>0 then'manual_review'else'graded'end,'v5.1.0',taken+1,coalesce((p_payload->>'time_taken')::int,0),coalesce((p_payload->>'violations')::int,0),coalesce(p_payload->'violation_log','[]'::jsonb),coalesce(p_payload->'answers_data','[]'::jsonb),case when e.certificate_enabled and manual_count=0 then'CERT-'||upper(substr(md5(random()::text),1,8))else''end,ref,subject_scores)returning id into rid;
 return jsonb_build_object('saved',true,'engine_version','v5.1.0','result_id',rid,'score',score,'total',total,'percent',pct,'grade',grade,'correct_count',cc,'wrong_count',wc,'skipped_count',sc,'ungraded_count',manual_count,'grading_status',case when manual_count>0 then'manual_review'else'graded'end,'cert_code',(select cert_code from public.cbt_results where id=rid),'subject_scores',subject_scores,'release_results',effective_release,'report_column',e.report_column);
exception when unique_violation then select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;if found then return jsonb_build_object('saved',true,'duplicate',true,'engine_version',coalesce(nullif(r.engine_version,''),'v5.1.0'),'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'ungraded_count',r.ungraded_count,'grading_status',r.grading_status,'cert_code',r.cert_code,'subject_scores',r.subject_scores,'release_results',e.release_results and r.grading_status='graded','report_column',e.report_column);end if;return jsonb_build_object('saved',false,'error','duplicate_submission','message','Duplicate submission conflict.','engine_version','v5.1.0');
when others then return jsonb_build_object('saved',false,'error','server_error','message',sqlerrm,'engine_version','v5.1.0');end $$;

-- Unambiguous compatibility paths all delegate to V5.1.
drop function if exists public.cbt_submit(json);
create or replace function public.cbt_submit(p_payload jsonb)returns jsonb language sql security definer set search_path=public as $$select public.cbt_submit_v5(p_payload)$$;
create or replace function public.cbt_submit_v2(p_payload jsonb)returns jsonb language sql security definer set search_path=public as $$select public.cbt_submit_v5(p_payload)$$;
create or replace function public.cbt_import_backup(p_payload jsonb)returns jsonb language plpgsql security definer set search_path=public as $$begin if not public.is_staff(auth.uid())then return jsonb_build_object('saved',false,'error','Staff role required','engine_version','v5.1.0');end if;return public.cbt_submit_v5(p_payload||jsonb_build_object('offline_override',true,'client_engine','v5.1'));end$$;

revoke execute on function public.sc_cbt_json_value(jsonb,text[])from public,anon,authenticated;
revoke execute on function public.sc_cbt_options(jsonb)from public,anon,authenticated;
revoke execute on function public.sc_cbt_answer_value(jsonb)from public,anon,authenticated;
revoke execute on function public.sc_cbt_question_type(jsonb)from public,anon,authenticated;
revoke execute on function public.sc_cbt_normalize_question(jsonb)from public,anon,authenticated;
revoke execute on function public.cbt_submit_v5(jsonb)from public;
grant execute on function public.cbt_submit_v5(jsonb)to anon,authenticated;
grant execute on function public.cbt_submit(jsonb)to anon,authenticated;
grant execute on function public.cbt_submit_v2(jsonb)to anon,authenticated;
grant execute on function public.cbt_diagnose_exam(uuid)to authenticated;
grant execute on function public.cbt_repair_exam_scoring(uuid)to authenticated;
grant execute on function public.cbt_import_backup(jsonb)to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect CBT V5.1 definitive grading engine installed — use RPC cbt_submit_v5 ✅'as status;

-- V5.1 public question redaction: remove answer aliases case-insensitively.
create or replace function public.sc_cbt_public_question(p_question jsonb)
returns jsonb language sql immutable parallel safe as $$
 select coalesce(jsonb_object_agg(e.key,e.value),'{}'::jsonb)
 from jsonb_each(coalesce(p_question,'{}'::jsonb))e
 where regexp_replace(lower(e.key),'[^a-z0-9]','','g')not in
 ('answer','correct','correctanswer','answerkey','correctoption','key','solutionanswer','rightanswer','accept','acceptedanswers','alternateanswers','explanation','reason','solution')
$$;

create or replace function public.cbt_get_public_exam(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record;qs jsonb;school jsonb;
begin
 select * into e from public.cbt_exams where upper(code)=upper(trim(p_code))and is_open=true and is_archived=false limit 1;if not found then return null;end if;
 if e.start_at is not null and now()<e.start_at then return jsonb_build_object('wait',true,'start_at',e.start_at,'title',e.title,'server_now',now(),'engine_version','v5.1.0');end if;
 if e.close_at is not null and now()>e.close_at then return jsonb_build_object('closed',true,'server_now',now(),'engine_version','v5.1.0');end if;
 select coalesce(jsonb_agg(public.sc_cbt_public_question(q)||jsonb_build_object('_orig_index',ord-1)order by ord),'[]'::jsonb)into qs
 from jsonb_array_elements(case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end)with ordinality x(q,ord);
 select jsonb_build_object('name',school_name,'short_name',short_name,'motto',motto,'address',address,'phone',phone,'email',email,'logo_url',logo_url)into school from public.school_settings where id=1;
 return jsonb_build_object('id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,'term',e.term,'session',e.session,'assessment_type',e.assessment_type,'duration',coalesce(nullif(e.duration_min,0),nullif(e.duration,0),45),'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode,'server_now',now(),'start_at',e.start_at,'close_at',e.close_at,'instructions',e.instructions,'anti_cheat_config',e.anti_cheat_config,'attempt_limit',e.attempt_limit,'randomise',e.randomise,'select_count',e.select_count,'negative_mark',e.negative_mark,'pass_mark',e.pass_mark,'release_results',e.release_results,'certificate_enabled',e.certificate_enabled,'updated_at',e.updated_at,'school',coalesce(school,'{}'::jsonb),'engine_version','v5.1.0');
end$$;
create or replace function public.cbt_get_public_exam_v2(p_code text)returns jsonb language sql security definer stable set search_path=public as $$select public.cbt_get_public_exam(p_code)$$;
revoke execute on function public.sc_cbt_public_question(jsonb)from public,anon,authenticated;
grant execute on function public.cbt_get_public_exam(text)to anon,authenticated;
grant execute on function public.cbt_get_public_exam_v2(text)to anon,authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- Regrade historical zero/incorrect result rows whose answers_data was retained.
create or replace function public.cbt_regrade_exam_results_v5(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
<<regrade>>
declare e record;res record;ans jsonb;q jsonb;bank jsonb;given jsonb;key jsonb;qidx int;idx int;mark numeric;penalty numeric;score numeric;total numeric;pct numeric;cc int;wc int;sc int;manual_count int;missing_count int;updated_count int:=0;missing_rows int:=0;no_answer_rows int:=0;subject_name text;subject_scores jsonb;subject_row jsonb;typ text;
begin
 if not public.is_staff(auth.uid())then return jsonb_build_object('ok',false,'message','Staff role required','engine_version','v5.1.0');end if;
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'message','Exam not found','engine_version','v5.1.0');end if;
 bank:=case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end;
 if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'message','Question bank is empty','engine_version','v5.1.0');end if;penalty:=greatest(coalesce(e.negative_mark,0),0);
 for res in select * from public.cbt_results where exam_id=p_exam_id order by submitted_at loop
  if jsonb_typeof(res.answers_data)<>'array'or jsonb_array_length(res.answers_data)=0 then no_answer_rows:=no_answer_rows+1;continue;end if;
  idx:=0;score:=0;total:=0;cc:=0;wc:=0;sc:=0;manual_count:=0;missing_count:=0;subject_scores:='{}'::jsonb;
  for ans in select * from jsonb_array_elements(res.answers_data)loop
   if jsonb_typeof(ans)='object'then qidx:=case when coalesce(ans->>'index','')~'^[0-9]+$'then(ans->>'index')::int else idx end;given:=ans->'answer';else qidx:=idx;given:=ans;end if;
   if qidx<0 or qidx>=jsonb_array_length(bank)then idx:=idx+1;continue;end if;q:=bank->qidx;typ:=public.sc_cbt_question_type(q);key:=public.sc_cbt_answer_value(q);
   if key is null then if typ in('essay','long_answer','file_upload')then manual_count:=manual_count+1;else missing_count:=missing_count+1;end if;idx:=idx+1;continue;end if;
   begin mark:=coalesce(nullif(public.sc_cbt_json_value(q,array['mark','marks','score','points'])#>>'{}','')::numeric,1);exception when others then mark:=1;end;mark:=greatest(mark,0);total:=total+mark;
   subject_name:=coalesce(public.sc_cbt_json_value(q,array['section','subjectsection','subject','examsubject'])#>>'{}',case when jsonb_typeof(ans)='object'then nullif(ans->>'subject','')end,'General');subject_row:=coalesce(subject_scores->subject_name,'{"score":0,"total":0,"correct":0,"wrong":0,"skipped":0}'::jsonb);subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
   if given is null or given='null'::jsonb or(jsonb_typeof(given)='string'and public.sc_cbt_norm(given#>>'{}')='')or(jsonb_typeof(given)='array'and jsonb_array_length(given)=0)then sc:=sc+1;subject_row:=jsonb_set(subject_row,'{skipped}',to_jsonb(coalesce((subject_row->>'skipped')::int,0)+1));
   elsif public.sc_cbt_answer_matches(q,given)then score:=score+mark;cc:=cc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+mark));subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
   else score:=score-penalty;wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(greatest(coalesce((subject_row->>'score')::numeric,0)-penalty,0)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));end if;subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true);idx:=idx+1;
  end loop;
  if missing_count>0 then missing_rows:=missing_rows+1;continue;end if;score:=greatest(round(score,2),0);pct:=case when total>0 then round(score/total*100,2)else 0 end;
  update public.cbt_results set score=regrade.score,total=regrade.total,percent=regrade.pct,correct_count=regrade.cc,wrong_count=regrade.wc,skipped_count=regrade.sc,ungraded_count=regrade.manual_count,grading_status=case when regrade.manual_count>0 then'manual_review'else'graded'end,engine_version='v5.1.0-regraded',subject_scores=regrade.subject_scores where id=res.id;updated_count:=updated_count+1;
 end loop;
 return jsonb_build_object('ok',true,'engine_version','v5.1.0','exam_id',p_exam_id,'regraded_count',updated_count,'skipped_missing_key_rows',missing_rows,'skipped_no_answer_rows',no_answer_rows);
end$$;
revoke execute on function public.cbt_regrade_exam_results_v5(uuid)from public,anon;
grant execute on function public.cbt_regrade_exam_results_v5(uuid)to authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');

-- Distinct V5.1 public getter with normalised codes and explicit diagnostics.
create index if not exists cbt_exams_normalized_code_idx on public.cbt_exams((regexp_replace(upper(code),'[^A-Z0-9]','','g')));
create or replace function public.cbt_get_public_exam_v5(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare e record;qs jsonb;school jsonb;wanted text:=regexp_replace(upper(coalesce(p_code,'')),'[^A-Z0-9]','','g');
begin
 if wanted=''then return jsonb_build_object('ok',false,'error','code_required','message','Enter an exam code.','engine_version','v5.1.0');end if;
 select * into e from public.cbt_exams where regexp_replace(upper(code),'[^A-Z0-9]','','g')=wanted order by updated_at desc nulls last,created_at desc limit 1;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found','message','No exam matches that code. Ask the exam officer to confirm the code.','engine_version','v5.1.0','normalised_code',wanted);end if;
 if coalesce(e.is_archived,false)then return jsonb_build_object('ok',false,'error','archived','message','This exam is archived. The exam officer must unarchive it.','id',e.id,'title',e.title,'code',e.code,'engine_version','v5.1.0');end if;
 if not coalesce(e.is_open,false)then return jsonb_build_object('ok',false,'error','not_open','message','This exam exists but is not open. The exam officer must click Open in CBT Manager.','id',e.id,'title',e.title,'code',e.code,'engine_version','v5.1.0');end if;
 if e.start_at is not null and now()<e.start_at then return jsonb_build_object('ok',false,'wait',true,'error','not_started','message','This exam has not started yet.','start_at',e.start_at,'title',e.title,'code',e.code,'server_now',now(),'engine_version','v5.1.0');end if;
 if e.close_at is not null and now()>e.close_at then return jsonb_build_object('ok',false,'closed',true,'error','closed','message','This exam closing time has passed.','close_at',e.close_at,'title',e.title,'code',e.code,'server_now',now(),'engine_version','v5.1.0');end if;
 select coalesce(jsonb_agg(public.sc_cbt_public_question(q)||jsonb_build_object('_orig_index',ord-1)order by ord),'[]'::jsonb)into qs from jsonb_array_elements(case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end)with ordinality x(q,ord);
 select jsonb_build_object('name',school_name,'short_name',short_name,'motto',motto,'address',address,'phone',phone,'email',email,'logo_url',logo_url)into school from public.school_settings where id=1;
 return jsonb_build_object('ok',true,'id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,'term',e.term,'session',e.session,'assessment_type',e.assessment_type,'duration',coalesce(nullif(e.duration_min,0),nullif(e.duration,0),45),'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode,'server_now',now(),'start_at',e.start_at,'close_at',e.close_at,'instructions',e.instructions,'anti_cheat_config',e.anti_cheat_config,'attempt_limit',e.attempt_limit,'randomise',e.randomise,'select_count',e.select_count,'negative_mark',e.negative_mark,'pass_mark',e.pass_mark,'release_results',e.release_results,'certificate_enabled',e.certificate_enabled,'updated_at',e.updated_at,'school',coalesce(school,'{}'::jsonb),'engine_version','v5.1.0');
exception when others then return jsonb_build_object('ok',false,'error','getter_server_error','message',sqlerrm,'engine_version','v5.1.0');
end$$;
revoke execute on function public.cbt_get_public_exam_v5(text)from public;
grant execute on function public.cbt_get_public_exam_v5(text)to anon,authenticated;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect CBT hotfix installed — cbt_submit_v5, cbt_get_public_exam_v5, diagnosis, repair and historical regrade enabled ✅' as status;
-- School Connect CBT V5.1.1 — legacy school_settings compatibility repair
-- Fixes: column "motto" does not exist in cbt_get_public_exam_v5.
-- Safe/idempotent for an existing School Connect database. Back up first.

alter table public.school_settings add column if not exists school_name text default 'School';
alter table public.school_settings add column if not exists short_name text default 'SCH';
alter table public.school_settings add column if not exists motto text default '';
alter table public.school_settings add column if not exists address text default '';
alter table public.school_settings add column if not exists phone text default '';
alter table public.school_settings add column if not exists email text default '';
alter table public.school_settings add column if not exists logo_url text default '';

-- The function deliberately reads the settings row through to_jsonb(). Missing
-- optional settings keys therefore return NULL instead of aborting exam lookup.
create or replace function public.cbt_get_public_exam_v5(p_code text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare
 e record;qs jsonb;school jsonb;settings_json jsonb:='{}'::jsonb;matched_code text:='';matched_id uuid;
 wanted text:=regexp_replace(upper(coalesce(p_code,'')),'[^A-Z0-9]','','g');
begin
 if wanted=''then return jsonb_build_object('ok',false,'error','code_required','message','Enter an exam code.','engine_version','v5.1.1');end if;
 select * into e from public.cbt_exams where regexp_replace(upper(code),'[^A-Z0-9]','','g')=wanted order by updated_at desc nulls last,created_at desc limit 1;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found','message','No exam matches that code. Ask the exam officer to confirm the code.','engine_version','v5.1.1','normalised_code',wanted);end if;
 matched_code:=coalesce(e.code,'');matched_id:=e.id;
 if coalesce(e.is_archived,false)then return jsonb_build_object('ok',false,'error','archived','message','This exam is archived. The exam officer must unarchive it.','id',e.id,'title',e.title,'code',e.code,'engine_version','v5.1.1');end if;
 if not coalesce(e.is_open,false)then return jsonb_build_object('ok',false,'error','not_open','message','This exam exists but is not open. The exam officer must click Open in CBT Manager.','id',e.id,'title',e.title,'code',e.code,'engine_version','v5.1.1');end if;
 if e.start_at is not null and now()<e.start_at then return jsonb_build_object('ok',false,'wait',true,'error','not_started','message','This exam has not started yet.','start_at',e.start_at,'title',e.title,'code',e.code,'server_now',now(),'engine_version','v5.1.1');end if;
 if e.close_at is not null and now()>e.close_at then return jsonb_build_object('ok',false,'closed',true,'error','closed','message','This exam closing time has passed.','close_at',e.close_at,'title',e.title,'code',e.code,'server_now',now(),'engine_version','v5.1.1');end if;
 select coalesce(jsonb_agg(public.sc_cbt_public_question(q)||jsonb_build_object('_orig_index',ord-1)order by ord),'[]'::jsonb)into qs from jsonb_array_elements(case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end)with ordinality x(q,ord);
 select to_jsonb(ss)into settings_json from public.school_settings ss where id=1;
 school:=jsonb_build_object(
  'name',coalesce(nullif(settings_json->>'school_name',''),nullif(settings_json->>'name',''),nullif(settings_json->>'short_name',''),'School'),
  'short_name',coalesce(settings_json->>'short_name',''),
  'motto',coalesce(settings_json->>'motto',''),
  'address',coalesce(settings_json->>'address',''),
  'phone',coalesce(settings_json->>'phone',''),
  'email',coalesce(settings_json->>'email',''),
  'logo_url',coalesce(settings_json->>'logo_url','')
 );
 return jsonb_build_object('ok',true,'id',e.id,'code',e.code,'title',e.title,'subject',e.subject,'class',e.class,'term',e.term,'session',e.session,'assessment_type',e.assessment_type,'duration',coalesce(nullif(e.duration_min,0),nullif(e.duration,0),45),'questions',qs,'_questions',qs,'report_column',e.report_column,'max_score',e.max_score,'exam_mode',e.exam_mode,'server_now',now(),'start_at',e.start_at,'close_at',e.close_at,'instructions',e.instructions,'anti_cheat_config',e.anti_cheat_config,'attempt_limit',e.attempt_limit,'randomise',e.randomise,'select_count',e.select_count,'negative_mark',e.negative_mark,'pass_mark',e.pass_mark,'release_results',e.release_results,'certificate_enabled',e.certificate_enabled,'updated_at',e.updated_at,'school',school,'engine_version','v5.1.1');
exception when others then
 return jsonb_build_object('ok',false,'error','getter_server_error','message','Exam lookup failed: '||sqlerrm,'code',matched_code,'matched_exam_id',matched_id,'engine_version','v5.1.1');
end$$;

revoke execute on function public.cbt_get_public_exam_v5(text)from public;
grant execute on function public.cbt_get_public_exam_v5(text)to anon,authenticated;
notify pgrst,'reload schema';
select pg_notify('pgrst','reload schema');
select 'School Connect CBT V5.1.1 getter compatibility fix installed — legacy school settings supported ✅'as status;
