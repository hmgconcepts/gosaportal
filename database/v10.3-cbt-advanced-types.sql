-- ============================================================================
-- School Connect V10.3 — Advanced CBT question types + per-student fee override
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql (or any earlier pack) on an EXISTING database.
-- Fresh installs get all of this from complete-schema.sql automatically.
--
-- WHAT THIS PACK DOES
-- 1. ADVANCED QUESTION TYPES, SERVER-GRADED (Tutoring Connect parity).
--    matching / ordering / categorization / matrix / multi-part numeric /
--    cloze (multi-blank) / hot-text now grade with PER-ROW PARTIAL CREDIT via
--    sc_cbt_grade_fraction. Binary types keep the proven sc_cbt_answer_matches
--    path, so no existing paper changes behaviour.
-- 2. ANSWER-KEY SANITISER. sc_cbt_public_question now also sanitises the
--    Items/Pairs payload per type before it reaches the candidate: matching
--    pairings, correct order, categories, matrix row answers, per-part numeric
--    answers, hot-text flags and cloze answers are all removed. What the
--    student needs to RENDER (left column, option pool, statements, labels)
--    is re-emitted in a safe shape ('items' + 'pool' + 'blanks').
-- 3. FEE OVERRIDE ROOT-CAUSE FIX (pass-51 issue 4). The bursar's double-click
--    override of "Total due" was saved into fee_payments.fee_total but
--    sc_student_fee_state kept recomputing the bill from the CLASS fee
--    structure, so the student dashboard ignored the override. A new column
--    fee_payments.total_overridden marks a deliberate override, and
--    sc_student_fee_state now honours the latest overridden total for the
--    current term as the student's PERSONAL total due (arrears and aid are
--    considered folded into the bursar's figure — one authoritative number).
-- ============================================================================
select 'RUNNING: School Connect CBT advanced types + fee override pack V10.3' as running_version;

-- ---------------------------------------------------------------------------
-- 0. Schema: deliberate per-student fee override marker
-- ---------------------------------------------------------------------------
alter table public.fee_payments add column if not exists total_overridden boolean default false;

-- ---------------------------------------------------------------------------
-- 1. sc_cbt_items — canonical Items/Pairs reader (array or JSON-in-text)
-- ---------------------------------------------------------------------------
create or replace function public.sc_cbt_items(p_question jsonb)
returns jsonb language plpgsql immutable parallel safe as $$
declare raw jsonb; txt text; parsed jsonb; parts text[]; result jsonb;
begin
 raw:=public.sc_cbt_json_value(p_question,array['items','pairs']);
 if raw is null then return null; end if;
 if jsonb_typeof(raw)='array' then
   return case when jsonb_array_length(raw)>0 then raw else null end;
 end if;
 if jsonb_typeof(raw)='string' then
   txt:=trim(raw#>>'{}');
   if txt='' then return null; end if;
   if left(txt,1)='[' then
     begin parsed:=txt::jsonb; if jsonb_typeof(parsed)='array' and jsonb_array_length(parsed)>0 then return parsed; end if;
     exception when others then null; end;
   end if;
   -- pipe / semicolon list becomes an array of strings
   parts:=regexp_split_to_array(txt,'\s*[|;]\s*');
   select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into result from unnest(parts) x where trim(x)<>'';
   return case when jsonb_array_length(result)>0 then result else null end;
 end if;
 return null;
end $$;

-- ---------------------------------------------------------------------------
-- 2. sc_cbt_grade_fraction — partial-credit grader for structured types.
--    Returns a fraction 0..1, or NULL when the question is not a structured
--    type this engine owns (caller then falls back to the binary matcher).
-- ---------------------------------------------------------------------------
create or replace function public.sc_cbt_grade_fraction(p_question jsonb,p_given jsonb)
returns numeric language plpgsql immutable parallel safe as $$
declare typ text:=public.sc_cbt_question_type(p_question); its jsonb; row_j jsonb; expect text; alts text[]; alt text;
        given_arr text[]:='{}'; token text; n int:=0; good int:=0; i int; tol numeric; gv numeric; ev numeric; hit int:=0; bad int:=0;
        want text[]:='{}'; right_norms text[]:='{}'; aon text;
begin
 if p_given is null or p_given='null'::jsonb then return null; end if;

 -- optional partial-credit multiple response (MRQ_AON explicitly false-ish)
 if typ='multi_select' then
   aon:=lower(coalesce(public.sc_cbt_json_value(p_question,array['mrqaon','allornothing'])#>>'{}',''));
   if aon not in ('false','0','no','partial') then return null; end if;
   if jsonb_typeof(public.sc_cbt_answer_value(p_question))='array' then
     for token in select jsonb_array_elements_text(public.sc_cbt_answer_value(p_question)) loop
       want:=array_append(want,public.sc_cbt_canonical_option(p_question,token)); end loop;
   else
     foreach token in array regexp_split_to_array(coalesce(public.sc_cbt_answer_value(p_question)#>>'{}',''),'\s*[,;|]\s*') loop
       if trim(token)<>'' then want:=array_append(want,public.sc_cbt_canonical_option(p_question,token)); end if; end loop;
   end if;
   if coalesce(array_length(want,1),0)=0 then return null; end if;
   if jsonb_typeof(p_given)='array' then
     for token in select jsonb_array_elements_text(p_given) loop given_arr:=array_append(given_arr,public.sc_cbt_canonical_option(p_question,token)); end loop;
   else
     foreach token in array regexp_split_to_array(coalesce(p_given#>>'{}',''),'\s*[,;|]\s*') loop
       if trim(token)<>'' then given_arr:=array_append(given_arr,public.sc_cbt_canonical_option(p_question,token)); end if; end loop;
   end if;
   hit:=0; bad:=0;
   foreach token in array given_arr loop
     if token=any(want) then hit:=hit+1; else bad:=bad+1; end if;
   end loop;
   return greatest(0,hit-bad)::numeric/array_length(want,1);
 end if;

 if typ not in ('matching','ordering','categorization','matrix','multi_numeric','cloze','hot_text') then return null; end if;
 its:=public.sc_cbt_items(p_question);
 if its is null and typ='cloze' then return null; end if;   -- legacy single-blank cloze → binary path
 if its is null then return null; end if;

 -- candidate answers as an ordered text array
 if jsonb_typeof(p_given)='array' then
   for token in select jsonb_array_elements_text(p_given) loop given_arr:=array_append(given_arr,coalesce(token,'')); end loop;
 else
   foreach token in array regexp_split_to_array(coalesce(p_given#>>'{}',''),'\s*[,;|]\s*') loop
     given_arr:=array_append(given_arr,token); end loop;
 end if;

 if typ='hot_text' then
   for row_j in select * from jsonb_array_elements(its) loop
     if jsonb_typeof(row_j)='object' and lower(coalesce(row_j->>'correct',''))in('true','t','1','yes') then
       right_norms:=array_append(right_norms,public.sc_cbt_norm(coalesce(row_j->>'text',row_j->>'item','')));
     end if;
   end loop;
   if coalesce(array_length(right_norms,1),0)=0 then return 0; end if;
   hit:=0; bad:=0;
   foreach token in array given_arr loop
     if trim(token)='' then continue; end if;
     if public.sc_cbt_norm(token)=any(right_norms) then hit:=hit+1; else bad:=bad+1; end if;
   end loop;
   return greatest(0,hit-bad)::numeric/array_length(right_norms,1);
 end if;

 if typ='ordering' then
   -- explicit answer array wins; else the items order IS the correct order
   declare order_norms text[]:='{}'; ans jsonb:=public.sc_cbt_answer_value(p_question);
   begin
     if jsonb_typeof(ans)='array' and jsonb_array_length(ans)>0 then
       for token in select jsonb_array_elements_text(ans) loop order_norms:=array_append(order_norms,public.sc_cbt_norm(token)); end loop;
     else
       for row_j in select * from jsonb_array_elements(its) loop
         order_norms:=array_append(order_norms,public.sc_cbt_norm(
           case when jsonb_typeof(row_j)='object' then coalesce(row_j->>'text',row_j->>'item',row_j->>'label','') else row_j#>>'{}' end));
       end loop;
     end if;
     n:=coalesce(array_length(order_norms,1),0);
     if n=0 then return 0; end if;
     good:=0;
     for i in 1..n loop
       if i<=coalesce(array_length(given_arr,1),0) and public.sc_cbt_norm(given_arr[i])=order_norms[i] then good:=good+1; end if;
     end loop;
     return good::numeric/n;
   end;
 end if;

 -- matching / categorization / matrix / multi_numeric / multi-blank cloze:
 -- one expected value per row, alternatives separated by |
 n:=jsonb_array_length(its);
 if n=0 then return 0; end if;
 good:=0; i:=0;
 for row_j in select * from jsonb_array_elements(its) loop
   i:=i+1;
   if jsonb_typeof(row_j)='object' then
     expect:=case typ
       when 'matching' then row_j->>'right'
       when 'categorization' then row_j->>'category'
       when 'matrix' then coalesce(row_j->>'answer',row_j->>'correct')
       when 'multi_numeric' then row_j->>'answer'
       else coalesce(row_j->>'answer',row_j->>'text') end;
   else expect:=row_j#>>'{}'; end if;
   if typ='multi_numeric' then
     begin
       tol:=coalesce(nullif(case when jsonb_typeof(row_j)='object' then row_j->>'tolerance' end,'')::numeric,
                     nullif(public.sc_cbt_json_value(p_question,array['tolerance','margin'])#>>'{}','')::numeric,0);
     exception when others then tol:=0; end;
     begin
       if i<=coalesce(array_length(given_arr,1),0) and trim(coalesce(given_arr[i],''))<>'' then
         gv:=given_arr[i]::numeric; ev:=expect::numeric;
         if abs(gv-ev)<=abs(tol)+0.000000001 then good:=good+1; end if;
       end if;
     exception when others then null; end;
   else
     alts:=regexp_split_to_array(coalesce(expect,''),'\s*\|\s*');
     if coalesce(array_length(alts,1),0)>0 and i<=coalesce(array_length(given_arr,1),0) then
       foreach alt in array alts loop
         if trim(alt)<>'' and public.sc_cbt_norm(given_arr[i])=public.sc_cbt_norm(alt) then good:=good+1; exit; end if;
       end loop;
     end if;
   end if;
 end loop;
 return good::numeric/n;
end $$;

-- ---------------------------------------------------------------------------
-- 3. sc_cbt_public_question V10.3 — key stripping + per-type Items sanitising.
--    Everything a candidate needs to render survives; every answer secret
--    (pairings, correct order, categories, matrix answers, numeric answers,
--    hot-text flags, cloze answers) is removed before the payload leaves the
--    database. Assertion/Reason items are the question stem, not a secret,
--    and pass through untouched.
-- ---------------------------------------------------------------------------
create or replace function public.sc_cbt_public_question(p_question jsonb)
returns jsonb language plpgsql immutable parallel safe as $$
declare filtered jsonb; typ text; its jsonb; row_j jsonb; out_items jsonb:='[]'::jsonb; pool jsonb:='[]'::jsonb;
        v text; seen text[]:='{}'; raw jsonb; token text;
begin
 select coalesce(jsonb_object_agg(e.key,e.value),'{}'::jsonb) into filtered
 from jsonb_each(coalesce(p_question,'{}'::jsonb))e
 where regexp_replace(lower(e.key),'[^a-z0-9]','','g')not in
 ('answer','correct','correctanswer','answerkey','correctoption','key','solutionanswer','rightanswer','accept','acceptedanswers','alternateanswers','explanation','reason','solution');
 typ:=public.sc_cbt_question_type(p_question);
 if typ not in ('matching','ordering','categorization','matrix','multi_numeric','cloze','hot_text') then return filtered; end if;
 its:=public.sc_cbt_items(p_question);
 if its is null then return filtered; end if;
 filtered:=filtered-'items'-'pairs';

 if typ='cloze' then
   return filtered||jsonb_build_object('blanks',jsonb_array_length(its));
 end if;

 if typ='matching' then
   for row_j in select * from jsonb_array_elements(its) loop
     if jsonb_typeof(row_j)='object' then
       out_items:=out_items||jsonb_build_array(jsonb_build_object('left',coalesce(row_j->>'left','')));
       v:=coalesce(row_j->>'right','');
       if v<>'' and not(v=any(seen)) then seen:=array_append(seen,v); end if;
     else
       out_items:=out_items||jsonb_build_array(jsonb_build_object('left',row_j#>>'{}'));
     end if;
   end loop;
   -- distractors ride along in Accept before it is stripped
   raw:=public.sc_cbt_json_value(p_question,array['distractors','accept','acceptedanswers']);
   if raw is not null then
     if jsonb_typeof(raw)='array' then
       for token in select jsonb_array_elements_text(raw) loop
         if trim(token)<>'' and not(token=any(seen)) then seen:=array_append(seen,token); end if; end loop;
     else
       foreach token in array regexp_split_to_array(coalesce(raw#>>'{}',''),'\s*[|;]\s*') loop
         if trim(token)<>'' and not(token=any(seen)) then seen:=array_append(seen,token); end if; end loop;
     end if;
   end if;
   select coalesce(jsonb_agg(to_jsonb(x) order by x),'[]'::jsonb) into pool from unnest(seen) x;  -- alphabetical hides pairing order
   return filtered||jsonb_build_object('items',out_items,'pool',pool);
 end if;

 if typ='ordering' then
   for row_j in select * from jsonb_array_elements(its) loop
     v:=case when jsonb_typeof(row_j)='object' then coalesce(row_j->>'text',row_j->>'item',row_j->>'label','') else row_j#>>'{}' end;
     if v<>'' then seen:=array_append(seen,v); end if;
   end loop;
   select coalesce(jsonb_agg(to_jsonb(x) order by x),'[]'::jsonb) into out_items from unnest(seen) x;  -- alphabetical hides the correct order
   return filtered||jsonb_build_object('items',out_items);
 end if;

 if typ='categorization' then
   for row_j in select * from jsonb_array_elements(its) loop
     if jsonb_typeof(row_j)='object' then
       out_items:=out_items||jsonb_build_array(jsonb_build_object('item',coalesce(row_j->>'item',row_j->>'label','')));
       v:=coalesce(row_j->>'category','');
       if v<>'' and not(v=any(seen)) then seen:=array_append(seen,v); end if;
     else out_items:=out_items||jsonb_build_array(jsonb_build_object('item',row_j#>>'{}')); end if;
   end loop;
   select coalesce(jsonb_agg(to_jsonb(x) order by x),'[]'::jsonb) into pool from unnest(seen) x;
   return filtered||jsonb_build_object('items',out_items,'pool',pool);
 end if;

 if typ='matrix' then
   for row_j in select * from jsonb_array_elements(its) loop
     if jsonb_typeof(row_j)='object' then
       out_items:=out_items||jsonb_build_array(jsonb_build_object('statement',coalesce(row_j->>'statement',row_j->>'item',row_j->>'label','')));
     else out_items:=out_items||jsonb_build_array(jsonb_build_object('statement',row_j#>>'{}')); end if;
   end loop;
   -- the shared options normally live in Accept (stripped) → re-emit as pool
   raw:=public.sc_cbt_json_value(p_question,array['accept','acceptedanswers','options','choices']);
   if raw is not null then
     if jsonb_typeof(raw)='array' then pool:=raw;
     else
       foreach token in array regexp_split_to_array(coalesce(raw#>>'{}',''),'\s*[|;]\s*') loop
         if trim(token)<>'' then pool:=pool||jsonb_build_array(to_jsonb(token)); end if; end loop;
     end if;
   end if;
   if jsonb_array_length(pool)=0 then pool:='["True","False"]'::jsonb; end if;
   return filtered||jsonb_build_object('items',out_items,'pool',pool);
 end if;

 if typ='multi_numeric' then
   for row_j in select * from jsonb_array_elements(its) loop
     if jsonb_typeof(row_j)='object' then
       out_items:=out_items||jsonb_build_array(jsonb_build_object('label',coalesce(row_j->>'label',row_j->>'name',''),'unit',coalesce(row_j->>'unit','')));
     else out_items:=out_items||jsonb_build_array(jsonb_build_object('label',row_j#>>'{}','unit','')); end if;
   end loop;
   return filtered||jsonb_build_object('items',out_items);
 end if;

 if typ='hot_text' then
   for row_j in select * from jsonb_array_elements(its) loop
     if jsonb_typeof(row_j)='object' then
       out_items:=out_items||jsonb_build_array(jsonb_build_object('text',coalesce(row_j->>'text',row_j->>'item','')));
     else out_items:=out_items||jsonb_build_array(jsonb_build_object('text',row_j#>>'{}')); end if;
   end loop;
   return filtered||jsonb_build_object('items',out_items);
 end if;

 return filtered;
end $$;

-- ---------------------------------------------------------------------------
-- 4. cbt_submit_v5 V10.3 — fraction-aware canonical grading.
--    Identical contract and diagnostics to the V5.1 engine; structured types
--    earn per-row partial credit, manual families widened (code / oral /
--    peer-review join essay), and a structured Items key satisfies the
--    answer-key guard so the new types are never rejected as key-missing.
-- ---------------------------------------------------------------------------
create or replace function public.cbt_submit_v5(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record;r record;rid uuid;sid uuid;taken int:=0;idx int:=0;qidx int;score numeric:=0;total numeric:=0;cc int:=0;wc int:=0;sc int:=0;manual_count int:=0;missing_count int:=0;
 ans jsonb;q jsonb;bank jsonb;given jsonb;answer_key jsonb;mark numeric;penalty numeric;ref text:=nullif(p_payload->>'client_ref','');pct numeric;grade text;idref text:=trim(coalesce(p_payload->>'student_id_ref',''));typ text;subject_name text;subject_scores jsonb:='{}';subject_row jsonb;missing_indexes int[]:='{}';offline_override boolean:=coalesce((p_payload->>'offline_override')::boolean,false)and public.is_staff(auth.uid());effective_release boolean;
 frac numeric;keyed boolean;
begin
 select * into e from public.cbt_exams where id=(p_payload->>'exam_id')::uuid;if not found then return jsonb_build_object('saved',false,'error','exam_not_found','message','Exam not found.','engine_version','v5.1.3');end if;
 if not offline_override then
  if not coalesce(e.is_open,false)or coalesce(e.is_archived,false)then return jsonb_build_object('saved',false,'error','closed','message','This exam is not open.','engine_version','v5.1.3');end if;
  if e.start_at is not null and now()<e.start_at then return jsonb_build_object('saved',false,'error','not_started','message','This exam has not started.','engine_version','v5.1.3');end if;
  if e.close_at is not null and now()>e.close_at+interval'120 seconds'then return jsonb_build_object('saved',false,'error','closed','message','This exam has closed.','engine_version','v5.1.3');end if;
 end if;
 if ref is not null then select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;if found then return jsonb_build_object('saved',true,'duplicate',true,'engine_version',coalesce(nullif(r.engine_version,''),'v5.1.3'),'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,'grade',case when r.percent>=75 then'A'when r.percent>=60 then'B'when r.percent>=50 then'C'when r.percent>=40 then'D'else'F'end,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'ungraded_count',r.ungraded_count,'grading_status',r.grading_status,'cert_code',r.cert_code,'subject_scores',r.subject_scores,'release_results',e.release_results and r.grading_status='graded','report_column',e.report_column);end if;end if;
 if not offline_override and idref<>''and coalesce(e.attempt_limit,0)>0 then select count(*)into taken from public.cbt_results where exam_id=e.id and student_id_ref=idref;if taken>=e.attempt_limit then return jsonb_build_object('saved',false,'error','attempts_exhausted','message','Attempt limit reached.','engine_version','v5.1.3');end if;end if;
 bank:=case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end;
 if jsonb_array_length(bank)=0 then return jsonb_build_object('saved',false,'error','question_bank_empty','message','The exam question bank is empty.','engine_version','v5.1.3');end if;
 penalty:=greatest(coalesce(e.negative_mark,0),0);
 for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb))loop
  qidx:=case when coalesce(ans->>'index','')~'^[0-9]+$'then(ans->>'index')::int else idx end;if qidx<0 or qidx>=jsonb_array_length(bank)then idx:=idx+1;continue;end if;q:=bank->qidx;typ:=public.sc_cbt_question_type(q);answer_key:=public.sc_cbt_answer_value(q);
  keyed:=answer_key is not null or (typ in('matching','ordering','categorization','matrix','multi_numeric','cloze','hot_text') and public.sc_cbt_items(q) is not null);
  if not keyed then if typ in('essay','long_answer','file_upload','code','oral_prompt','peer_review')then manual_count:=manual_count+1;else missing_count:=missing_count+1;missing_indexes:=array_append(missing_indexes,qidx);end if;idx:=idx+1;continue;end if;
  begin mark:=coalesce(nullif(public.sc_cbt_json_value(q,array['mark','marks','score','points'])#>>'{}','')::numeric,1);exception when others then mark:=1;end;mark:=greatest(mark,0);total:=total+mark;given:=ans->'answer';
  subject_name:=coalesce(public.sc_cbt_json_value(q,array['section','subjectsection','subject','examsubject'])#>>'{}',nullif(ans->>'subject',''),'General');subject_row:=coalesce(subject_scores->subject_name,'{"score":0,"total":0,"correct":0,"wrong":0,"skipped":0}'::jsonb);subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
  if given is null or given='null'::jsonb or(jsonb_typeof(given)='string'and public.sc_cbt_norm(given#>>'{}')='')or(jsonb_typeof(given)='array'and jsonb_array_length(given)=0)then sc:=sc+1;subject_row:=jsonb_set(subject_row,'{skipped}',to_jsonb(coalesce((subject_row->>'skipped')::int,0)+1));
  else
   frac:=public.sc_cbt_grade_fraction(q,given);
   if frac is null then frac:=case when public.sc_cbt_answer_matches(q,given)then 1 else 0 end;end if;
   if frac>=0.999 then score:=score+mark;cc:=cc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+mark));subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
   elsif frac<=0.001 then score:=score-penalty;wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(greatest(coalesce((subject_row->>'score')::numeric,0)-penalty,0)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));
   else score:=score+round(mark*frac,2);wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+round(mark*frac,2)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));end if;
  end if;
  subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true);idx:=idx+1;
 end loop;
 if missing_count>0 then return jsonb_build_object('saved',false,'error','answer_key_missing','message','This exam has '||missing_count||' objective question(s) without a recognised correct answer key. Ask the exam officer to use Diagnose Scoring / Repair Scoring, then submit again.','missing_answer_indexes',to_jsonb(missing_indexes),'engine_version','v5.1.3');end if;
 score:=greatest(round(score,2),0);pct:=case when total>0 then round(score/total*100,2)else 0 end;grade:=case when pct>=75 then'A'when pct>=60 then'B'when pct>=50 then'C'when pct>=40 then'D'else'F'end;
 if coalesce(p_payload->>'student_id','')~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'then sid:=(p_payload->>'student_id')::uuid;end if;if sid is null and idref<>''then select id into sid from public.students where admission_no=idref limit 1;end if;effective_release:=e.release_results and manual_count=0;
 insert into public.cbt_results(exam_id,student_id,student_name,student_class,student_id_ref,student_type,score,total,percent,correct_count,wrong_count,skipped_count,ungraded_count,grading_status,engine_version,attempt_number,time_taken,violations,violation_log,answers_data,cert_code,client_ref,subject_scores)
 values(e.id,sid,coalesce(nullif(p_payload->>'student_name',''),'Anonymous'),coalesce(nullif(p_payload->>'student_class',''),e.class),idref,coalesce(p_payload->>'student_type',e.exam_mode),score,total,pct,cc,wc,sc,manual_count,case when manual_count>0 then'manual_review'else'graded'end,'v5.1.3',taken+1,coalesce((p_payload->>'time_taken')::int,0),coalesce((p_payload->>'violations')::int,0),coalesce(p_payload->'violation_log','[]'::jsonb),coalesce(p_payload->'answers_data','[]'::jsonb),case when e.certificate_enabled and manual_count=0 then'CERT-'||upper(substr(md5(random()::text),1,8))else''end,ref,subject_scores)returning id into rid;
 return jsonb_build_object('saved',true,'engine_version','v5.1.3','result_id',rid,'score',score,'total',total,'percent',pct,'grade',grade,'correct_count',cc,'wrong_count',wc,'skipped_count',sc,'ungraded_count',manual_count,'grading_status',case when manual_count>0 then'manual_review'else'graded'end,'cert_code',(select cert_code from public.cbt_results where id=rid),'subject_scores',subject_scores,'release_results',effective_release,'report_column',e.report_column);
exception when unique_violation then select * into r from public.cbt_results where exam_id=e.id and client_ref=ref limit 1;if found then return jsonb_build_object('saved',true,'duplicate',true,'engine_version',coalesce(nullif(r.engine_version,''),'v5.1.3'),'result_id',r.id,'score',r.score,'total',r.total,'percent',r.percent,'correct_count',r.correct_count,'wrong_count',r.wrong_count,'skipped_count',r.skipped_count,'ungraded_count',r.ungraded_count,'grading_status',r.grading_status,'cert_code',r.cert_code,'subject_scores',r.subject_scores,'release_results',e.release_results and r.grading_status='graded','report_column',e.report_column);end if;return jsonb_build_object('saved',false,'error','duplicate_submission','message','Duplicate submission conflict.','engine_version','v5.1.3');
when others then return jsonb_build_object('saved',false,'error','server_error','message',sqlerrm,'engine_version','v5.1.3');end $$;

-- Unambiguous compatibility paths keep delegating to the canonical engine.
create or replace function public.cbt_submit(p_payload jsonb)returns jsonb language sql security definer set search_path=public as $$select public.cbt_submit_v5(p_payload)$$;
create or replace function public.cbt_submit_v2(p_payload jsonb)returns jsonb language sql security definer set search_path=public as $$select public.cbt_submit_v5(p_payload)$$;

-- ---------------------------------------------------------------------------
-- 5. cbt_regrade_exam_results_v5 V10.3 — same fraction-aware engine for
--    historical results, so a repaired structured paper regrades identically.
-- ---------------------------------------------------------------------------
create or replace function public.cbt_regrade_exam_results_v5(p_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
<<regrade>>
declare e record;res record;ans jsonb;q jsonb;bank jsonb;given jsonb;key jsonb;qidx int;idx int;mark numeric;penalty numeric;score numeric;total numeric;pct numeric;cc int;wc int;sc int;manual_count int;missing_count int;updated_count int:=0;missing_rows int:=0;no_answer_rows int:=0;subject_name text;subject_scores jsonb;subject_row jsonb;typ text;frac numeric;keyed boolean;
begin
 if not public.is_staff(auth.uid())then return jsonb_build_object('ok',false,'message','Staff role required','engine_version','v5.1.3');end if;
 select * into e from public.cbt_exams where id=p_exam_id;if not found then return jsonb_build_object('ok',false,'message','Exam not found','engine_version','v5.1.3');end if;
 bank:=case when jsonb_typeof(e.csv_data)='array'and jsonb_array_length(e.csv_data)>0 then e.csv_data when jsonb_typeof(e.questions)='array'then e.questions else'[]'::jsonb end;
 if jsonb_array_length(bank)=0 then return jsonb_build_object('ok',false,'message','Question bank is empty','engine_version','v5.1.3');end if;penalty:=greatest(coalesce(e.negative_mark,0),0);
 for res in select * from public.cbt_results where exam_id=p_exam_id order by submitted_at loop
  if jsonb_typeof(res.answers_data)<>'array'or jsonb_array_length(res.answers_data)=0 then no_answer_rows:=no_answer_rows+1;continue;end if;
  idx:=0;score:=0;total:=0;cc:=0;wc:=0;sc:=0;manual_count:=0;missing_count:=0;subject_scores:='{}'::jsonb;
  for ans in select * from jsonb_array_elements(res.answers_data)loop
   if jsonb_typeof(ans)='object'then qidx:=case when coalesce(ans->>'index','')~'^[0-9]+$'then(ans->>'index')::int else idx end;given:=ans->'answer';else qidx:=idx;given:=ans;end if;
   if qidx<0 or qidx>=jsonb_array_length(bank)then idx:=idx+1;continue;end if;q:=bank->qidx;typ:=public.sc_cbt_question_type(q);key:=public.sc_cbt_answer_value(q);
   keyed:=key is not null or (typ in('matching','ordering','categorization','matrix','multi_numeric','cloze','hot_text') and public.sc_cbt_items(q) is not null);
   if not keyed then if typ in('essay','long_answer','file_upload','code','oral_prompt','peer_review')then manual_count:=manual_count+1;else missing_count:=missing_count+1;end if;idx:=idx+1;continue;end if;
   begin mark:=coalesce(nullif(public.sc_cbt_json_value(q,array['mark','marks','score','points'])#>>'{}','')::numeric,1);exception when others then mark:=1;end;mark:=greatest(mark,0);total:=total+mark;
   subject_name:=coalesce(public.sc_cbt_json_value(q,array['section','subjectsection','subject','examsubject'])#>>'{}',case when jsonb_typeof(ans)='object'then nullif(ans->>'subject','')end,'General');subject_row:=coalesce(subject_scores->subject_name,'{"score":0,"total":0,"correct":0,"wrong":0,"skipped":0}'::jsonb);subject_row:=jsonb_set(subject_row,'{total}',to_jsonb(coalesce((subject_row->>'total')::numeric,0)+mark));
   if given is null or given='null'::jsonb or(jsonb_typeof(given)='string'and public.sc_cbt_norm(given#>>'{}')='')or(jsonb_typeof(given)='array'and jsonb_array_length(given)=0)then sc:=sc+1;subject_row:=jsonb_set(subject_row,'{skipped}',to_jsonb(coalesce((subject_row->>'skipped')::int,0)+1));
   else
    frac:=public.sc_cbt_grade_fraction(q,given);
    if frac is null then frac:=case when public.sc_cbt_answer_matches(q,given)then 1 else 0 end;end if;
    if frac>=0.999 then score:=score+mark;cc:=cc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+mark));subject_row:=jsonb_set(subject_row,'{correct}',to_jsonb(coalesce((subject_row->>'correct')::int,0)+1));
    elsif frac<=0.001 then score:=score-penalty;wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(greatest(coalesce((subject_row->>'score')::numeric,0)-penalty,0)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));
    else score:=score+round(mark*frac,2);wc:=wc+1;subject_row:=jsonb_set(subject_row,'{score}',to_jsonb(coalesce((subject_row->>'score')::numeric,0)+round(mark*frac,2)));subject_row:=jsonb_set(subject_row,'{wrong}',to_jsonb(coalesce((subject_row->>'wrong')::int,0)+1));end if;
   end if;subject_scores:=jsonb_set(subject_scores,array[subject_name],subject_row,true);idx:=idx+1;
  end loop;
  if missing_count>0 then missing_rows:=missing_rows+1;continue;end if;score:=greatest(round(score,2),0);pct:=case when total>0 then round(score/total*100,2)else 0 end;
  update public.cbt_results set score=regrade.score,total=regrade.total,percent=regrade.pct,correct_count=regrade.cc,wrong_count=regrade.wc,skipped_count=regrade.sc,ungraded_count=regrade.manual_count,grading_status=case when regrade.manual_count>0 then'manual_review'else'graded'end,engine_version='v5.1.3-regraded',subject_scores=regrade.subject_scores where id=res.id;updated_count:=updated_count+1;
 end loop;
 return jsonb_build_object('ok',true,'engine_version','v5.1.3','exam_id',p_exam_id,'regraded_count',updated_count,'skipped_missing_key_rows',missing_rows,'skipped_no_answer_rows',no_answer_rows);
end$$;

-- ---------------------------------------------------------------------------
-- 6. sc_student_fee_state V10.3 — HONOURS THE BURSAR'S PER-STUDENT OVERRIDE.
--    Root cause of pass-51 issue 4: the double-click override wrote
--    fee_payments.fee_total but this RPC always recomputed the bill from
--    class_fee_structure, so dashboards/receipts kept showing the class
--    figure. When the latest current-term payment row is flagged
--    total_overridden, its fee_total becomes the student's PERSONAL total due
--    for the term: class breakdown, aid deduction and prior-term arrears are
--    treated as already folded into the bursar's single figure (they were on
--    screen when the figure was set), so nothing is double-counted.
-- ---------------------------------------------------------------------------
create or replace function public.sc_student_fee_state(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st record; cur record; fs record; paid_now numeric := 0;
        arrears numeric := 0; arr_rows jsonb := '[]'::jsonb;
        bill numeric := 0; breakdown jsonb := '[]'::jsonb;
        t record; tbill numeric; tpaid numeric; allowed boolean;
        aid_total numeric := 0; aid_rows jsonb := '[]'::jsonb; a record;
        ovr record; overridden boolean := false;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok', false, 'error', 'Student not found.'); end if;
  allowed := coalesce(public.is_staff(auth.uid()), false)
          or coalesce(st.user_id = auth.uid(), false)
          or coalesce(public.is_parent_of(auth.uid(), st.id), false)
          or coalesce(st.guardian_email = auth.jwt()->>'email', false);
  if not allowed then return jsonb_build_object('ok', false, 'error', 'Not authorised for this student.'); end if;

  select term, session into cur from public.academic_periods where is_current = true limit 1;

  -- V10 BEST-MATCH SCORING (kept): never hard-exclude on arm/department.
  select * into fs from public.class_fee_structure f
   where f.active is not false
     and lower(trim(f.class)) = lower(trim(coalesce(st.class,'')))
     and (coalesce(f.session,'') = '' or f.session = coalesce(cur.session,''))
     and coalesce(f.term,'Current Term') in ('Current Term', coalesce(cur.term,''))
   order by
     (lower(coalesce(f.arm,''))        = lower(coalesce(st.arm,'')))        desc,
     (coalesce(f.arm,'') = '')                                              desc,
     (lower(coalesce(f.department,'')) = lower(coalesce(st.department,''))) desc,
     (coalesce(f.department,'') = '')                                       desc,
     (coalesce(f.session,'') <> '')                                         desc,
     f.updated_at desc nulls last
   limit 1;

  if fs.id is not null then
    bill := coalesce(nullif(fs.total,0), coalesce(fs.tuition,0)+coalesce(fs.exam_fee,0)+coalesce(fs.development,0)+coalesce(fs.transport,0)+coalesce(fs.boarding,0)+coalesce(fs.other_fee,0)-coalesce(fs.discount,0));
    breakdown := jsonb_build_array();
    if coalesce(fs.tuition,0)     <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Tuition','amount',fs.tuition)); end if;
    if coalesce(fs.exam_fee,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Exam / assessment','amount',fs.exam_fee)); end if;
    if coalesce(fs.development,0) <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Development / PTA','amount',fs.development)); end if;
    if coalesce(fs.transport,0)   <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Transport','amount',fs.transport)); end if;
    if coalesce(fs.boarding,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Boarding / hostel','amount',fs.boarding)); end if;
    if coalesce(fs.other_fee,0)   <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Other compulsory','amount',fs.other_fee)); end if;
    if coalesce(fs.discount,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Discount','amount',-fs.discount)); end if;
  end if;

  begin
    for a in select mr.title, mr.amount from public.module_records mr
              where mr.module = 'financial_aid'
                and coalesce(mr.status,'applied') in ('approved','renewed')
                and coalesce(mr.amount,0) > 0
                and ( mr.data->>'student' = st.id::text
                   or lower(coalesce(mr.data->>'student','')) = lower(coalesce(st.full_name,''))
                   or mr.data->>'student_id' = st.id::text )
    loop
      aid_total := aid_total + a.amount;
      aid_rows := aid_rows || jsonb_build_array(jsonb_build_object('scheme', coalesce(a.title,'Scholarship/Aid'), 'amount', a.amount));
      breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','🎓 '||coalesce(a.title,'Scholarship/Aid'),'amount',-a.amount));
    end loop;
  exception when undefined_table or undefined_column then null;
  end;
  bill := greatest(coalesce(bill,0) - aid_total, 0);

  select coalesce(sum(amount_paid),0) into paid_now from public.fee_payments
   where student_id = p_student
     and (coalesce(cur.term,'')    = '' or coalesce(term,'')    = cur.term)
     and (coalesce(cur.session,'') = '' or coalesce(session,'') = cur.session);

  for t in
    select coalesce(term,'') as term, coalesce(session,'') as session,
           max(coalesce(fee_total,0)) as tb, sum(coalesce(amount_paid,0)) as tp
      from public.fee_payments
     where student_id = p_student
       and not (coalesce(term,'') = coalesce(cur.term,'') and coalesce(session,'') = coalesce(cur.session,''))
     group by 1,2
  loop
    tbill := coalesce(t.tb,0); tpaid := coalesce(t.tp,0);
    if tbill > tpaid then
      arrears := arrears + (tbill - tpaid);
      arr_rows := arr_rows || jsonb_build_array(jsonb_build_object('term',t.term,'session',t.session,'bill',tbill,'paid',tpaid,'owing',tbill-tpaid));
    end if;
  end loop;

  -- V10.3 (#4): the bursar's deliberate per-student override WINS.
  begin
    select fee_total into ovr from public.fee_payments
     where student_id = p_student
       and coalesce(total_overridden,false) = true
       and coalesce(fee_total,0) > 0
       and (coalesce(cur.term,'')    = '' or coalesce(term,'')    = cur.term)
       and (coalesce(cur.session,'') = '' or coalesce(session,'') = cur.session)
     order by created_at desc nulls last limit 1;
    if found and ovr.fee_total is not null then
      overridden := true;
      bill := coalesce(ovr.fee_total,0);
      arrears := 0; arr_rows := '[]'::jsonb;      -- folded into the bursar's figure
      breakdown := jsonb_build_array(jsonb_build_object('item','✏️ Personal total set by the bursar (override)','amount',bill));
    end if;
  exception when undefined_column then null;
  end;

  return jsonb_build_object('ok', true,
    'student_id', st.id, 'student_name', st.full_name, 'class', st.class,
    'term', coalesce(cur.term,''), 'session', coalesce(cur.session,''),
    'bill', coalesce(bill,0), 'breakdown', breakdown,
    'aid', case when overridden then 0 else aid_total end, 'aid_rows', case when overridden then '[]'::jsonb else aid_rows end,
    'paid', paid_now, 'balance', greatest(coalesce(bill,0) - paid_now, 0),
    'arrears', arrears, 'arrears_rows', arr_rows,
    'total_due', greatest(coalesce(bill,0) - paid_now, 0) + arrears,
    'grand_total', coalesce(bill,0) + arrears,
    'currency', coalesce(fs.currency, '₦'),
    'due_date', fs.due_date, 'note', coalesce(fs.note,''),
    'matched', overridden or fs.id is not null,
    'override', overridden,
    'matched_arm', coalesce(fs.arm,''), 'matched_department', coalesce(fs.department,''));
end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.sc_cbt_items(jsonb)from public,anon,authenticated;
revoke execute on function public.sc_cbt_grade_fraction(jsonb,jsonb)from public,anon,authenticated;
revoke execute on function public.cbt_submit_v5(jsonb)from public;
grant execute on function public.cbt_submit_v5(jsonb)to anon,authenticated;
revoke execute on function public.cbt_submit(jsonb)from public;
grant execute on function public.cbt_submit(jsonb)to anon,authenticated;
revoke execute on function public.cbt_submit_v2(jsonb)from public;
grant execute on function public.cbt_submit_v2(jsonb)to anon,authenticated;
revoke execute on function public.cbt_regrade_exam_results_v5(uuid)from public,anon;
grant execute on function public.cbt_regrade_exam_results_v5(uuid)to authenticated;
revoke all on function public.sc_student_fee_state(uuid) from public, anon;
grant execute on function public.sc_student_fee_state(uuid) to authenticated;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.3 CBT advanced types + fee override pack installed' as status;
