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
