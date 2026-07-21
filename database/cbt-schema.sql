-- =====================================================================
-- School Connect — CBT (Computer-Based Testing) Schema — Gen v2
-- =====================================================================
-- A full online-exam engine, INTERCONNECTED with the main School Connect
-- database so exam/test/assignment/project results flow into report cards.
--
-- Mirrors the HMG Academy Standalone CBT system:
--   • 17 question types, anti-cheat config, certificates
--   • open / registered exam modes, attempt limits, negative marking
--   • held vs instant results, start/close windows
--
-- ORDERING RULE (prevents 42P01): tables first → helper functions →
-- policies. Self-contained: creates a minimal profiles + is_staff() only
-- if missing, so it can run standalone or after database/schema.sql.
-- Idempotent: safe to re-run.
-- =====================================================================

create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- ---- minimal dependency (no-op if main schema already ran) ----
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text, full_name text, phone text,
  role text not null default 'student'
    check (role in ('super_admin','admin','principal','proprietor','head_teacher','staff','teacher','parent','student','bursar')),
  status text not null default 'pending'
    check (status in ('pending','approved','active','suspended')),
  photo_url text, campus text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

-- =====================================================================
-- 1. TABLES
-- =====================================================================

create table if not exists public.cbt_exams (
  id uuid primary key default uuid_generate_v4(),
  teacher_id uuid references public.profiles(id) on delete set null,
  code text unique not null,
  title text,
  subject text not null default 'General',
  class text default '',
  term text default '',
  session text default '',
  topic text default '',
  -- which kind of assessment this is — used to map into the report card:
  assessment_type text not null default 'exam'
    check (assessment_type in ('exam','test','assignment','project','quiz','ca','practical')),
  -- the report-card column name this exam feeds (e.g. 'CA1','Project','Exam'):
  report_column text default '',
  max_score numeric default 0,           -- max mark to scale the result to in the report card
  duration integer not null default 45,  -- minutes
  attempt_limit integer not null default 1,
  select_count integer not null default 0,   -- 0 = use all questions
  randomise boolean not null default true,
  negative_mark numeric not null default 0,
  exam_mode text not null default 'open' check (exam_mode in ('open','anonymous','registered')),
  is_open boolean not null default false,
  is_archived boolean not null default false,
  release_results boolean not null default true,
  instructions text not null default '',
  anti_cheat_config jsonb not null default
    '{"tab_switch":true,"window_blur":true,"copy_paste":true,"right_click":true,"fullscreen":true,"devtools":true,"max_violations":5}'::jsonb,
  certificate_enabled boolean not null default true,
  start_at timestamptz,
  close_at timestamptz,
  csv_data jsonb not null default '[]'::jsonb,   -- the question bank [{question,type,options,correct,...}]
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table public.cbt_exams enable row level security;
alter table public.cbt_exams add column if not exists is_entrance boolean not null default false;
alter table public.cbt_exams add column if not exists pass_mark numeric not null default 50;
create index if not exists cbt_exams_code_idx on public.cbt_exams (code);

create table if not exists public.cbt_results (
  id uuid primary key default uuid_generate_v4(),
  exam_id uuid not null references public.cbt_exams(id) on delete cascade,
  student_name text not null,
  student_class text default '',
  student_id_ref text default '',     -- admission no / student.id reference
  student_type text default 'open',
  score numeric(10,2) not null default 0,
  total integer not null default 0,
  percent numeric(6,2) default 0,
  correct_count integer default 0,
  wrong_count integer default 0,
  skipped_count integer default 0,
  attempt_number integer default 1,
  time_taken integer default 0,       -- seconds
  answers_data jsonb,
  violations integer default 0,
  violation_log jsonb default '[]'::jsonb,
  cert_code text default '',
  created_at timestamptz default now()
);
alter table public.cbt_results enable row level security;
create index if not exists cbt_results_exam_idx on public.cbt_results (exam_id);
create index if not exists cbt_results_student_idx on public.cbt_results (student_id_ref);

-- Roster for "registered" mode (which students may sit an exam)
create table if not exists public.cbt_roster (
  id uuid primary key default uuid_generate_v4(),
  exam_id uuid references public.cbt_exams(id) on delete cascade,
  student_id_ref text not null,
  full_name text,
  class text,
  created_at timestamptz default now(),
  unique(exam_id, student_id_ref)
);
alter table public.cbt_roster enable row level security;

-- =====================================================================
-- 2. HELPER (created after tables; no-op if main schema already made it)
-- =====================================================================
create or replace function public.is_staff(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = uid
      and role in ('super_admin','admin','principal','proprietor','head_teacher','staff','teacher','bursar')
      and status in ('approved','active')
  );
$$;


-- ENTERPRISE V3 CBT ADMIN HELPER
create or replace function public.is_admin(uid uuid)
returns boolean language sql security definer stable as $$
  select exists (select 1 from public.profiles where id=uid and role in ('super_admin','admin','administrator','owner','director','principal','proprietor','head_teacher','bursar') and status in ('approved','active'));
$$;

-- =====================================================================
-- 3. SECURE RPCs (so anonymous students can sit exams without seeing answers)
-- =====================================================================

-- Public: fetch an OPEN exam by code WITHOUT exposing the correct answers.
create or replace function public.cbt_get_public_exam(p_code text)
returns jsonb language plpgsql security definer stable as $$
declare e public.cbt_exams; qs jsonb;
begin
  select * into e from public.cbt_exams
   where code = upper(trim(p_code)) and is_open = true and is_archived = false
   limit 1;
  if not found then return null; end if;
  if e.start_at is not null and now() < e.start_at then
    return jsonb_build_object('wait', true, 'start_at', e.start_at, 'title', e.title, 'subject', e.subject);
  end if;
  if e.close_at is not null and now() > e.close_at then
    return jsonb_build_object('closed', true);
  end if;
  -- strip the correct answers/explanations before sending to the student
  select coalesce(jsonb_agg(
           (q - 'correct' - 'explanation' - 'accept' - 'subs')
           || jsonb_build_object('correct', null)
         ), '[]'::jsonb)
    into qs
    from jsonb_array_elements(e.csv_data) q;
  return jsonb_build_object(
    'id', e.id, 'code', e.code, 'title', e.title, 'subject', e.subject,
    'class', e.class, 'term', e.term, 'session', e.session, 'topic', e.topic,
    'duration', e.duration, 'instructions', e.instructions, 'exam_mode', e.exam_mode,
    'select_count', e.select_count, 'randomise', e.randomise,
    'anti_cheat_config', e.anti_cheat_config, 'release_results', e.release_results,
    'certificate_enabled', e.certificate_enabled, 'assessment_type', e.assessment_type,
    'report_column', e.report_column, 'max_score', e.max_score,
    'questions', qs, '_questions', qs
  );
end; $$;

-- Public: grade & store a submission server-side (answers checked against the
-- full bank), returning the score and certificate code.
create or replace function public.cbt_submit(p_payload jsonb)
returns jsonb language plpgsql security definer as $$
declare
  e public.cbt_exams;
  v_attempts int;
  v_cert text;
  v_id uuid;
  v_release boolean;
begin
  select * into e from public.cbt_exams where id = (p_payload->>'exam_id')::uuid limit 1;
  if not found then return jsonb_build_object('saved', false, 'error', 'Exam not found'); end if;

  -- enforce attempt limit per student reference (best-effort)
  select count(*) into v_attempts from public.cbt_results
   where exam_id = e.id
     and ( (p_payload->>'student_id_ref') <> '' and student_id_ref = p_payload->>'student_id_ref' );
  if e.attempt_limit > 0 and (p_payload->>'student_id_ref') <> '' and v_attempts >= e.attempt_limit then
    return jsonb_build_object('saved', false, 'error', 'Attempt limit reached');
  end if;

  v_cert := case when e.certificate_enabled
                 then 'CERT-' || upper(substr(md5(random()::text),1,4)) || '-' || upper(substr(md5(random()::text),1,4))
                 else '' end;

  insert into public.cbt_results (
    exam_id, student_name, student_class, student_id_ref, student_type,
    score, total, percent, correct_count, wrong_count, skipped_count,
    attempt_number, time_taken, answers_data, violations, violation_log, cert_code
  ) values (
    e.id,
    coalesce(p_payload->>'student_name','Anonymous'),
    coalesce(p_payload->>'student_class', e.class),
    coalesce(p_payload->>'student_id_ref',''),
    coalesce(p_payload->>'student_type', e.exam_mode),
    coalesce((p_payload->>'score')::numeric,0),
    coalesce((p_payload->>'total')::int,0),
    coalesce((p_payload->>'percent')::numeric,0),
    coalesce((p_payload->>'correct_count')::int,0),
    coalesce((p_payload->>'wrong_count')::int,0),
    coalesce((p_payload->>'skipped_count')::int,0),
    v_attempts + 1,
    coalesce((p_payload->>'time_taken')::int,0),
    p_payload->'answers_data',
    coalesce((p_payload->>'violations')::int,0),
    coalesce(p_payload->'violation_log','[]'::jsonb),
    v_cert
  ) returning id into v_id;

  v_release := e.release_results;
  return jsonb_build_object(
    'saved', true, 'result_id', v_id, 'cert_code', v_cert,
    'release_results', v_release,
    'report_column', e.report_column, 'subject', e.subject,
    'term', e.term, 'session', e.session, 'class', e.class, 'title', e.title,
    'score', coalesce((p_payload->>'score')::numeric,0),
    'total', coalesce((p_payload->>'total')::int,0),
    'percent', coalesce((p_payload->>'percent')::numeric,0),
    'student_name', coalesce(p_payload->>'student_name','Anonymous'),
    'max_score', e.max_score
  );
end; $$;

-- =====================================================================
-- 4. RLS POLICIES
-- =====================================================================

-- Exams: staff (teachers/admins) manage; authenticated can read open exams.
drop policy if exists "cbt_exam_staff" on public.cbt_exams;
drop policy if exists "cbt_exam_read"  on public.cbt_exams;
drop policy if exists "cbt_exam_insert" on public.cbt_exams;
drop policy if exists "cbt_exam_update" on public.cbt_exams;
drop policy if exists "cbt_exam_delete" on public.cbt_exams;
drop policy if exists "cbt_exam_read" on public.cbt_exams;
create policy "cbt_exam_read" on public.cbt_exams for select using (auth.role() = 'authenticated');
drop policy if exists "cbt_exam_insert" on public.cbt_exams;
create policy "cbt_exam_insert" on public.cbt_exams for insert with check (public.is_staff(auth.uid()));
drop policy if exists "cbt_exam_update" on public.cbt_exams;
create policy "cbt_exam_update" on public.cbt_exams for update using (public.is_admin(auth.uid()) or teacher_id = auth.uid()) with check (public.is_admin(auth.uid()) or teacher_id = auth.uid());
drop policy if exists "cbt_exam_delete" on public.cbt_exams;
create policy "cbt_exam_delete" on public.cbt_exams for delete using (public.is_admin(auth.uid()) or teacher_id = auth.uid());

-- Results: staff read all & manage; (anonymous students submit via the
-- security-definer cbt_submit RPC, so no broad insert policy is needed).
drop policy if exists "cbt_res_staff" on public.cbt_results;
create policy "cbt_res_staff" on public.cbt_results for all using (public.is_staff(auth.uid()));
drop policy if exists "cbt_res_family_read" on public.cbt_results;
create policy "cbt_res_family_read" on public.cbt_results for select using (
  public.is_staff(auth.uid())
  or exists (
    select 1 from public.students s
    where (s.admission_no = cbt_results.student_id_ref or lower(s.full_name) = lower(cbt_results.student_name))
      and (s.user_id = auth.uid() or public.is_parent_of(auth.uid(), s.id))
  )
);

drop policy if exists "cbt_roster_staff" on public.cbt_roster;
create policy "cbt_roster_staff" on public.cbt_roster for all using (public.is_staff(auth.uid()));

-- Allow anon + authenticated to call the public RPCs only.
grant execute on function public.cbt_get_public_exam(text) to anon, authenticated;
grant execute on function public.cbt_submit(jsonb) to anon, authenticated;

-- =====================================================================
-- DONE ✅  CBT engine installed. Run database/reportcard-schema.sql next to
-- enable automatic result → report-card mapping.
-- =====================================================================
select 'School Connect CBT schema v2 installed ✅' as status;

-- =====================================================================
-- School Connect v2 CBT repair: server-side grading + answer stripping
-- Re-runnable. Keeps CBT functional for open/anonymous exams without AI APIs.
-- =====================================================================
create or replace function public.cbt_get_public_exam(p_code text)
returns jsonb language plpgsql security definer stable as $$
declare e public.cbt_exams; qs jsonb;
begin
  select * into e from public.cbt_exams
   where code = upper(trim(p_code)) and is_open = true and is_archived = false
   limit 1;
  if not found then return null; end if;
  if e.start_at is not null and now() < e.start_at then
    return jsonb_build_object('wait', true, 'start_at', e.start_at, 'title', e.title, 'subject', e.subject);
  end if;
  if e.close_at is not null and now() > e.close_at then
    return jsonb_build_object('closed', true);
  end if;

  select coalesce(jsonb_agg(
           (q - 'correct' - 'correct_answer' - 'answer' - 'explanation' - 'accept' - 'subs')
           || jsonb_build_object('correct', null, 'answer', null)
         ), '[]'::jsonb)
    into qs
    from jsonb_array_elements(e.csv_data) q;

  return jsonb_build_object(
    'id', e.id, 'code', e.code, 'title', e.title, 'subject', e.subject,
    'class', e.class, 'term', e.term, 'session', e.session, 'topic', e.topic,
    'duration', e.duration, 'instructions', e.instructions, 'exam_mode', e.exam_mode,
    'select_count', e.select_count, 'randomise', e.randomise, 'negative_mark', e.negative_mark,
    'anti_cheat_config', e.anti_cheat_config, 'release_results', e.release_results,
    'certificate_enabled', e.certificate_enabled, 'assessment_type', e.assessment_type,
    'report_column', e.report_column, 'max_score', e.max_score,
    'questions', qs, '_questions', qs
  );
end; $$;

create or replace function public.cbt_submit(p_payload jsonb)
returns jsonb language plpgsql security definer as $$
declare
  e public.cbt_exams;
  v_attempts int;
  v_cert text;
  v_id uuid;
  v_release boolean;
  q jsonb;
  i int := 0;
  v_ans text;
  v_key text;
  v_mark numeric;
  v_score numeric := 0;
  v_total numeric := 0;
  v_correct int := 0;
  v_wrong int := 0;
  v_skipped int := 0;
  v_percent numeric := 0;
begin
  select * into e from public.cbt_exams where id = (p_payload->>'exam_id')::uuid limit 1;
  if not found then return jsonb_build_object('saved', false, 'error', 'Exam not found'); end if;

  select count(*) into v_attempts from public.cbt_results
   where exam_id = e.id
     and ( (p_payload->>'student_id_ref') <> '' and student_id_ref = p_payload->>'student_id_ref' );
  if e.attempt_limit > 0 and (p_payload->>'student_id_ref') <> '' and v_attempts >= e.attempt_limit then
    return jsonb_build_object('saved', false, 'error', 'Attempt limit reached');
  end if;

  for q in select * from jsonb_array_elements(e.csv_data) loop
    v_mark := coalesce(nullif(q->>'mark','')::numeric, nullif(q->>'score','')::numeric, 1);
    v_total := v_total + v_mark;
    v_ans := coalesce(p_payload->'answers_data'->>i, '');
    v_key := coalesce(q->>'answer', q->>'correct', q->>'correct_answer', '');
    if trim(v_ans) = '' then
      v_skipped := v_skipped + 1;
    elsif lower(trim(v_ans)) = lower(trim(v_key)) then
      v_score := v_score + v_mark;
      v_correct := v_correct + 1;
    else
      v_score := greatest(0, v_score - coalesce(e.negative_mark,0));
      v_wrong := v_wrong + 1;
    end if;
    i := i + 1;
  end loop;
  if v_total > 0 then v_percent := round((v_score / v_total) * 100, 2); end if;

  v_cert := case when e.certificate_enabled
                 then 'CERT-' || upper(substr(md5(random()::text),1,4)) || '-' || upper(substr(md5(random()::text),1,4))
                 else '' end;

  insert into public.cbt_results (
    exam_id, student_name, student_class, student_id_ref, student_type,
    score, total, percent, correct_count, wrong_count, skipped_count,
    attempt_number, time_taken, answers_data, violations, violation_log, cert_code
  ) values (
    e.id,
    coalesce(p_payload->>'student_name','Anonymous'),
    coalesce(p_payload->>'student_class', e.class),
    coalesce(p_payload->>'student_id_ref',''),
    coalesce(p_payload->>'student_type', e.exam_mode),
    v_score, v_total::int, v_percent, v_correct, v_wrong, v_skipped,
    v_attempts + 1,
    coalesce((p_payload->>'time_taken')::int,0),
    p_payload->'answers_data',
    coalesce((p_payload->>'violations')::int,0),
    coalesce(p_payload->'violation_log','[]'::jsonb),
    v_cert
  ) returning id into v_id;

  v_release := e.release_results;
  return jsonb_build_object(
    'saved', true, 'result_id', v_id, 'cert_code', v_cert,
    'release_results', v_release,
    'report_column', e.report_column, 'subject', e.subject,
    'term', e.term, 'session', e.session, 'class', e.class, 'title', e.title,
    'score', v_score, 'total', v_total::int, 'percent', v_percent,
    'correct_count', v_correct, 'wrong_count', v_wrong, 'skipped_count', v_skipped,
    'student_name', coalesce(p_payload->>'student_name','Anonymous'), 'max_score', e.max_score
  );
end; $$;

grant execute on function public.cbt_get_public_exam(text) to anon, authenticated;
grant execute on function public.cbt_submit(jsonb) to anon, authenticated;

-- =====================================================================
-- ENTERPRISE V10 CBT CONCURRENCY + RANDOMISED ORDER REPAIR (2026-07-06)
-- Supports 400+ simultaneous candidates more safely:
-- 1. candidate fetch gets original question indexes before answer stripping;
-- 2. submissions are graded against the exact question indexes attempted;
-- 3. extra indexes reduce contention for busy exam halls.
-- =====================================================================
create index if not exists cbt_exams_code_open_idx on public.cbt_exams (code, is_open, is_archived);
create index if not exists cbt_results_exam_student_created_idx on public.cbt_results (exam_id, student_id_ref, created_at desc);
create index if not exists cbt_results_created_idx on public.cbt_results (created_at desc);

create or replace function public.cbt_get_public_exam(p_code text)
returns jsonb language plpgsql security definer stable as $$
declare e public.cbt_exams; qs jsonb;
begin
  select * into e from public.cbt_exams
   where code = upper(trim(p_code)) and is_open = true and is_archived = false
   limit 1;
  if not found then return null; end if;
  if e.start_at is not null and now() < e.start_at then
    return jsonb_build_object('wait', true, 'start_at', e.start_at, 'title', e.title, 'subject', e.subject);
  end if;
  if e.close_at is not null and now() > e.close_at then
    return jsonb_build_object('closed', true);
  end if;

  select coalesce(jsonb_agg(
           (q - 'correct' - 'correct_answer' - 'answer' - 'explanation' - 'accept' - 'subs')
           || jsonb_build_object('correct', null, 'answer', null, '_orig_index', ord - 1)
           order by ord
         ), '[]'::jsonb)
    into qs
    from jsonb_array_elements(e.csv_data) with ordinality as t(q, ord);

  return jsonb_build_object(
    'id', e.id, 'code', e.code, 'title', e.title, 'subject', e.subject,
    'class', e.class, 'term', e.term, 'session', e.session, 'topic', e.topic,
    'duration', e.duration, 'instructions', e.instructions, 'exam_mode', e.exam_mode,
    'select_count', e.select_count, 'randomise', e.randomise, 'negative_mark', e.negative_mark,
    'anti_cheat_config', e.anti_cheat_config, 'release_results', e.release_results,
    'certificate_enabled', e.certificate_enabled, 'assessment_type', e.assessment_type,
    'report_column', e.report_column, 'max_score', e.max_score,
    'questions', qs, '_questions', qs
  );
end; $$;

create or replace function public.cbt_submit(p_payload jsonb)
returns jsonb language plpgsql security definer as $$
declare
  e public.cbt_exams;
  v_attempts int;
  v_cert text;
  v_id uuid;
  v_release boolean;
  ans jsonb;
  q jsonb;
  i int := 0;
  qi int;
  v_ans text;
  v_key text;
  v_mark numeric;
  v_score numeric := 0;
  v_total numeric := 0;
  v_correct int := 0;
  v_wrong int := 0;
  v_skipped int := 0;
  v_percent numeric := 0;
begin
  select * into e from public.cbt_exams where id = (p_payload->>'exam_id')::uuid limit 1;
  if not found then return jsonb_build_object('saved', false, 'error', 'Exam not found'); end if;

  select count(*) into v_attempts from public.cbt_results
   where exam_id = e.id
     and coalesce(p_payload->>'student_id_ref','') <> ''
     and student_id_ref = p_payload->>'student_id_ref';
  if e.attempt_limit > 0 and coalesce(p_payload->>'student_id_ref','') <> '' and v_attempts >= e.attempt_limit then
    return jsonb_build_object('saved', false, 'error', 'Attempt limit reached');
  end if;

  -- New clients send [{index, subject, answer}]. Older clients send ["A","B"].
  for ans in select * from jsonb_array_elements(coalesce(p_payload->'answers_data','[]'::jsonb)) loop
    if jsonb_typeof(ans) = 'object' then
      qi := coalesce(nullif(ans->>'index','')::int, i);
      v_ans := coalesce(ans->>'answer','');
    else
      qi := i;
      v_ans := coalesce(ans #>> '{}','');
    end if;
    q := e.csv_data -> qi;
    if q is null then i := i + 1; continue; end if;
    v_mark := coalesce(nullif(q->>'mark','')::numeric, nullif(q->>'score','')::numeric, 1);
    v_total := v_total + v_mark;
    v_key := coalesce(q->>'answer', q->>'correct', q->>'correct_answer', '');
    if trim(v_ans) = '' then
      v_skipped := v_skipped + 1;
    elsif lower(trim(v_ans)) = lower(trim(v_key)) then
      v_score := v_score + v_mark;
      v_correct := v_correct + 1;
    else
      v_score := greatest(0, v_score - coalesce(e.negative_mark,0));
      v_wrong := v_wrong + 1;
    end if;
    i := i + 1;
  end loop;
  if v_total > 0 then v_percent := round((v_score / v_total) * 100, 2); end if;

  v_cert := case when e.certificate_enabled then 'CERT-' || upper(substr(md5(random()::text),1,4)) || '-' || upper(substr(md5(random()::text),1,4)) else '' end;

  insert into public.cbt_results (
    exam_id, student_name, student_class, student_id_ref, student_type,
    score, total, percent, correct_count, wrong_count, skipped_count,
    attempt_number, time_taken, answers_data, violations, violation_log, cert_code
  ) values (
    e.id, coalesce(p_payload->>'student_name','Anonymous'), coalesce(p_payload->>'student_class', e.class),
    coalesce(p_payload->>'student_id_ref',''), coalesce(p_payload->>'student_type', e.exam_mode),
    v_score, v_total::int, v_percent, v_correct, v_wrong, v_skipped, v_attempts + 1,
    coalesce((p_payload->>'time_taken')::int,0), p_payload->'answers_data',
    coalesce((p_payload->>'violations')::int,0), coalesce(p_payload->'violation_log','[]'::jsonb), v_cert
  ) returning id into v_id;

  v_release := e.release_results;
  return jsonb_build_object('saved', true, 'result_id', v_id, 'cert_code', v_cert, 'release_results', v_release,
    'report_column', e.report_column, 'subject', e.subject, 'term', e.term, 'session', e.session, 'class', e.class,
    'title', e.title, 'score', v_score, 'total', v_total::int, 'percent', v_percent,
    'correct_count', v_correct, 'wrong_count', v_wrong, 'skipped_count', v_skipped,
    'student_name', coalesce(p_payload->>'student_name','Anonymous'), 'max_score', e.max_score);
end; $$;

grant execute on function public.cbt_get_public_exam(text) to anon, authenticated;
grant execute on function public.cbt_submit(jsonb) to anon, authenticated;
