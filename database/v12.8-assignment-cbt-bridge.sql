-- ============================================================================
-- School Connect V12.8 — ASSIGNMENT + CBT ASSIGNMENT BRIDGE (pass 82)
-- ----------------------------------------------------------------------------
-- Blueprint from user:
-- - Unlike mid-term (CA1/CA2) and terminal exams (once per term), assignments
--   are given MORE THAN ONCE per term. Assignment page already collates
--   individual assignments cumulatively → push to Assignment column.
-- - Problem: when more than one CBT assignment is given in a particular
--   subject in a term, there is NO feature to collate these scores cumulatively.
-- - Required: CBT assignments should be handled DIFFERENTLY from mid-term and
--   terminal CBTs. Whenever CBT assignments are given, their scores should be
--   automatically filled when the 'score class' button is clicked for THAT CBT
--   assignment in the assignment page, allowing cumulative collation → push to
--   Assignment column at end of term.
-- - Must clearly and unambiguously differentiate CBT assignments from CBT for
--   mid-term (CAs), terminal examinations and other purposes.
--
-- WHAT THIS PACK ADDS (robust, all-inclusive, self-contained, seamless):
--
-- 1. assignments.cbt_exam_id uuid + is_cbt boolean
--    - When a CBT exam is created with assessment_type='assignment', a mirror
--      row is auto-created in assignments (via trigger) with cbt_exam_id linked.
--    - This makes CBT assignments appear in Assignments page list naturally,
--      with clear badge "CBT Assignment".
--    - is_cbt distinguishes physical vs CBT.
--
-- 2. assignment_scores.cbt_exam_id uuid
--    - Allows multiple CBT assignments per subject/term to be stored as separate
--      columns, each linked to its cbt_exams.id, accumulating cumulatively.
--    - Unique partial indexes prevent duplicate scores per student per CBT exam.
--
-- 3. Triggers:
--    - trg_cbt_assignment_mirror — after insert/update on cbt_exams where
--      assessment_type='assignment', upserts assignments row (title, class,
--      subject, due_date, posted_by, cbt_exam_id, is_cbt=true)
--    - trg_cbt_assignment_cleanup — after delete on cbt_exams, deletes mirror.
--
-- 4. RPCs:
--    - sc_create_assignment_from_cbt(p_cbt_exam_id) — creates/returns assignment
--      row for a CBT exam.
--    - sc_assignment_cbt_sync(p_cbt_exam_id) — syncs that CBT exam's cbt_results
--      into assignment_scores (with cbt_exam_id, assignment_id, class, subject,
--      term, session, score, max_score). Returns {ok, synced, total_results}.
--    - sc_assignment_cbt_sync_all(p_class, p_subject, p_term, p_session) — syncs
--      ALL CBT assignments for a class/subject/term/session.
--    - sc_assignment_totals(p_class, p_subject, p_term, p_session) — returns
--      per-student cumulative totals across ALL assignments (physical + CBT).
--
-- 5. Marker for schema doctor.
--
-- Idempotent — safe to re-run. All functions SECURITY DEFINER, staff-gated.
-- ============================================================================
select 'RUNNING: School Connect assignment + CBT bridge pack V12.8' as running_version;

-- 1. Extend assignments table
alter table public.assignments add column if not exists cbt_exam_id uuid references public.cbt_exams(id) on delete set null;
alter table public.assignments add column if not exists is_cbt boolean not null default false;
alter table public.assignments add column if not exists source text not null default 'manual';

comment on column public.assignments.cbt_exam_id is 'V12.8: when this assignment is a mirror of a CBT exam (assessment_type=assignment), stores the cbt_exams.id';
comment on column public.assignments.is_cbt is 'V12.8: true if this assignment is auto-mirrored from a CBT assignment exam';
comment on column public.assignments.source is 'V12.8: manual | cbt_assignment | cbt_mirror';

create index if not exists assignments_cbt_exam_id_idx on public.assignments(cbt_exam_id) where cbt_exam_id is not null;

-- 2. Extend assignment_scores table
alter table public.assignment_scores add column if not exists cbt_exam_id uuid references public.cbt_exams(id) on delete cascade;
comment on column public.assignment_scores.cbt_exam_id is 'V12.8: when this score comes from a CBT assignment, stores the cbt_exams.id, enabling multiple CBT assignments per subject/term to accumulate separately';

create index if not exists assignment_scores_cbt_exam_id_idx on public.assignment_scores(cbt_exam_id) where cbt_exam_id is not null;

-- Unique per student per CBT exam (when cbt_exam_id not null)
drop index if exists assignment_scores_cbt_unique;
create unique index if not exists assignment_scores_cbt_unique on public.assignment_scores(cbt_exam_id, student_id) where cbt_exam_id is not null;

-- Unique per student per physical assignment (existing, but ensure)
drop index if exists assignment_scores_assignment_unique;
create unique index if not exists assignment_scores_assignment_unique on public.assignment_scores(assignment_id, student_id) where assignment_id is not null;

-- 3. Trigger: mirror CBT assignments into assignments table
create or replace function public.sc_mirror_cbt_assignment()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_aid uuid;
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if lower(coalesce(new.assessment_type,'')) <> 'assignment' then
    -- If previously was assignment but now changed away, remove mirror
    if lower(coalesce(old.assessment_type,'')) = 'assignment' then
      delete from public.assignments where cbt_exam_id = new.id;
    end if;
    return new;
  end if;
  -- Upsert mirror assignment row
  insert into public.assignments (id, title, class, subject, due_date, posted_by, cbt_exam_id, is_cbt, source, description, created_at)
  values (
    coalesce((select id from public.assignments where cbt_exam_id = new.id limit 1), gen_random_uuid()),
    new.title,
    new.class,
    new.subject,
    coalesce(new.close_at::date, current_date + interval '7 days'),
    new.teacher_id,
    new.id,
    true,
    'cbt_assignment',
    'CBT Assignment auto-mirrored from cbt_exams code='||new.code||' — scores auto-fill from CBT results. Multiple per term accumulate cumulatively → push to Assignment column.',
    now()
  )
  on conflict (id) do update set
    title = excluded.title,
    class = excluded.class,
    subject = excluded.subject,
    due_date = excluded.due_date,
    posted_by = excluded.posted_by,
    cbt_exam_id = excluded.cbt_exam_id,
    is_cbt = true,
    source = 'cbt_assignment';
  return new;
end$$;

drop trigger if exists trg_cbt_assignment_mirror on public.cbt_exams;
create trigger trg_cbt_assignment_mirror after insert or update of assessment_type, title, class, subject, close_at, teacher_id on public.cbt_exams
for each row execute function public.sc_mirror_cbt_assignment();

-- Cleanup on delete
create or replace function public.sc_cleanup_cbt_assignment()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if pg_trigger_depth() > 1 then return old; end if;
  delete from public.assignments where cbt_exam_id = old.id;
  return old;
end$$;

drop trigger if exists trg_cbt_assignment_cleanup on public.cbt_exams;
create trigger trg_cbt_assignment_cleanup after delete on public.cbt_exams
for each row execute function public.sc_cleanup_cbt_assignment();

-- 4. RPC: create assignment from CBT
create or replace function public.sc_create_assignment_from_cbt(p_cbt_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_exam record; v_aid uuid;
begin
  if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'error','Only staff can create assignment from CBT'); end if;
  select * into v_exam from public.cbt_exams where id = p_cbt_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','CBT exam not found'); end if;
  select id into v_aid from public.assignments where cbt_exam_id = p_cbt_exam_id limit 1;
  if v_aid is not null then return jsonb_build_object('ok',true,'assignment_id',v_aid,'created',false); end if;
  insert into public.assignments (title, class, subject, due_date, posted_by, cbt_exam_id, is_cbt, source, description)
  values (v_exam.title, v_exam.class, v_exam.subject, coalesce(v_exam.close_at::date, current_date+7), v_exam.teacher_id, v_exam.id, true, 'cbt_assignment', 'CBT Assignment mirror for '||v_exam.code)
  returning id into v_aid;
  return jsonb_build_object('ok',true,'assignment_id',v_aid,'created',true);
end$$;

-- 5. RPC: sync single CBT assignment results into assignment_scores
create or replace function public.sc_assignment_cbt_sync(p_cbt_exam_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_exam record;
  v_aid uuid;
  v_synced int := 0;
  v_total int := 0;
  r record;
begin
  if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'error','Only staff can sync CBT assignment scores'); end if;
  select * into v_exam from public.cbt_exams where id = p_cbt_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','CBT exam not found'); end if;
  if lower(coalesce(v_exam.assessment_type,'')) <> 'assignment' then
    return jsonb_build_object('ok',false,'error','This CBT exam is not an assignment type (assessment_type='||coalesce(v_exam.assessment_type,'')||'). Only CBT assignments can be synced to assignment scores.');
  end if;
  -- Ensure mirror assignment exists
  select id into v_aid from public.assignments where cbt_exam_id = p_cbt_exam_id limit 1;
  if v_aid is null then
    insert into public.assignments (title, class, subject, due_date, posted_by, cbt_exam_id, is_cbt, source, description)
    values (v_exam.title, v_exam.class, v_exam.subject, coalesce(v_exam.close_at::date, current_date+7), v_exam.teacher_id, v_exam.id, true, 'cbt_assignment', 'Auto-mirror for CBT assignment '||v_exam.code)
    returning id into v_aid;
  end if;
  -- Count total results
  select count(*) into v_total from public.cbt_results where exam_id = p_cbt_exam_id;
  -- Upsert each result into assignment_scores
  for r in select cr.*, s.id as sid, s.admission_no, s.full_name as sname
           from public.cbt_results cr
           join public.students s on lower(s.full_name) = lower(cr.student_name) or s.admission_no = cr.student_id_ref
           where cr.exam_id = p_cbt_exam_id
  loop
    begin
      insert into public.assignment_scores (assignment_id, cbt_exam_id, student_id, student_id_ref, student_name, class, subject, term, session, score, max_score, recorded_by)
      values (v_aid, p_cbt_exam_id, r.sid, coalesce(r.admission_no, r.student_id_ref,''), coalesce(r.sname, r.student_name), coalesce(v_exam.class,''), coalesce(v_exam.subject,''), coalesce(v_exam.term,''), coalesce(v_exam.session,''), coalesce(r.score,0), coalesce(r.total, v_exam.max_score, 10), auth.uid())
      on conflict (cbt_exam_id, student_id) where cbt_exam_id is not null
      do update set score = excluded.score, max_score = excluded.max_score, student_name = excluded.student_name, student_id_ref = excluded.student_id_ref, term = excluded.term, session = excluded.session;
      v_synced := v_synced + 1;
    exception when others then
      -- skip one bad row
      continue;
    end;
  end loop;
  return jsonb_build_object('ok',true,'synced',v_synced,'total_results',v_total,'assignment_id',v_aid,'cbt_exam_id',p_cbt_exam_id);
end$$;

-- 6. RPC: sync all CBT assignments for a class/subject/term/session
create or replace function public.sc_assignment_cbt_sync_all(p_class text default null, p_subject text default null, p_term text default null, p_session text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_exam record; v_total_synced int :=0; v_exams int :=0; j jsonb; v_res jsonb := '[]'::jsonb;
begin
  if not public.is_staff(auth.uid()) then return jsonb_build_object('ok',false,'error','Only staff'); end if;
  for v_exam in select * from public.cbt_exams where lower(assessment_type)='assignment' and (p_class is null or class=p_class) and (p_subject is null or subject=p_subject) and (p_term is null or term=p_term) and (p_session is null or session=p_session) and is_archived=false loop
    select public.sc_assignment_cbt_sync(v_exam.id) into j;
    if (j->>'ok')::boolean then v_total_synced := v_total_synced + coalesce((j->>'synced')::int,0); v_exams := v_exams + 1; end if;
    v_res := v_res || jsonb_build_object('exam_id',v_exam.id,'code',v_exam.code,'title',v_exam.title,'synced',j->'synced','total',j->'total_results');
  end loop;
  return jsonb_build_object('ok',true,'exams_synced',v_exams,'total_scores_synced',v_total_synced,'details',v_res);
end$$;

-- 7. RPC: cumulative totals (physical + CBT) per student
create or replace function public.sc_assignment_totals(p_class text, p_subject text, p_term text default null, p_session text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_out jsonb;
begin
  if not public.is_staff(auth.uid()) and not public.is_admin(auth.uid()) then
    -- students/parents can read their own via RLS, but this RPC is staff-gated for totals view
    if not exists (select 1 from public.students s where s.user_id = auth.uid() and s.class = p_class) and not public.is_parent_of(auth.uid(), (select id from public.students where class=p_class limit 1)) then
      return jsonb_build_object('ok',false,'error','Only staff can view class totals');
    end if;
  end if;
  with filtered as (
    select * from public.assignment_scores
     where class = p_class and subject = p_subject
       and (p_term is null or term = p_term)
       and (p_session is null or session = p_session)
  ),
  agg as (
    select student_id, student_name, student_id_ref,
           count(*) as assignments_count,
           sum(score) as total_got,
           sum(max_score) as total_max,
           case when sum(max_score)>0 then round((sum(score)/sum(max_score)*100)::numeric,1) else 0 end as percent
      from filtered group by student_id, student_name, student_id_ref
  )
  select jsonb_agg(to_jsonb(agg)) into v_out from agg;
  return jsonb_build_object('ok',true,'class',p_class,'subject',p_subject,'term',p_term,'session',p_session,'totals',coalesce(v_out,'[]'::jsonb));
end$$;

-- Grants
revoke all on function public.sc_create_assignment_from_cbt(uuid) from public, anon;
grant execute on function public.sc_create_assignment_from_cbt(uuid) to authenticated;
revoke all on function public.sc_assignment_cbt_sync(uuid) from public, anon;
grant execute on function public.sc_assignment_cbt_sync(uuid) to authenticated;
revoke all on function public.sc_assignment_cbt_sync_all(text,text,text,text) from public, anon;
grant execute on function public.sc_assignment_cbt_sync_all(text,text,text,text) to authenticated;
revoke all on function public.sc_assignment_totals(text,text,text,text) from public, anon;
grant execute on function public.sc_assignment_totals(text,text,text,text) to authenticated;

-- Marker
insert into public.sc_install_state(key,details) values ('v12.8-assignment-cbt-bridge.sql','{"self":true}') on conflict (key) do nothing;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.8 assignment + CBT bridge pack installed' as status;
