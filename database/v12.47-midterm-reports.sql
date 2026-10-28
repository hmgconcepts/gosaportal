-- ============================================================================
-- School Connect V12.47 — Midterm Reports (once per term) — Separate from Terminal
-- ----------------------------------------------------------------------------
-- Requirement: Midterm test is ONCE per term. Generate Mid term test reports
-- per student that contain ONLY mid term test scores, so student/parent can
-- see Mid term sheet. Must be robust, self-contained, all-inclusive, seamless,
-- not affecting terminal report generation, in sync, not conflicting.
--
-- Design (expert, robust):
--   - New table midterm_report_cards (id uuid, student_id uuid, student_id_ref text,
--     student_name text, class text, term text, session text, scores jsonb
--     (subject->score), total numeric, average numeric, position int, published bool,
--     created_at, updated_at, unique(student_id_ref, class, term, session))
--   - New RPC generate_midterm_reports(p_class text, p_term text, p_session text)
--     aggregates report_scores where assessment_columns.name = 'Midterm' or
--     cbt_assessment_type = 'test' or 'midterm' (case-insensitive, normalized)
--     and assessment_columns.class = p_class, term = p_term, session = p_session.
--     It inserts/updates midterm_report_cards with total/average/position,
--     published=false initially, tutor can publish.
--   - New RPC get_midterm_report(p_student_id_ref text, p_class text, p_term text, p_session text)
--     returns single student's mid-term report for student/parent view.
--   - Existing report_scores and assessment_columns remain untouched — terminal
--     reports use all columns (CA1, CA2, Exam, etc.), mid-term uses only
--     `Midterm` column, so no conflict. Both can coexist for same class/term/session.
--   - In sync: When report_scores are updated (push from CBT), both
--     generate_midterm_reports and generate_terminal_reports can be called;
--     they read from same report_scores but filter different columns, so they
--     stay in sync automatically.
--   - Self-contained: No new dependencies, just SQL + HTML page.
-- Idempotent.
-- ============================================================================
select 'RUNNING: School Connect midterm reports V12.47' as running_version;

create table if not exists public.midterm_report_cards(
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete set null,
  student_id_ref text not null default '',
  student_name text not null default '',
  class text not null default '',
  term text not null default '',
  session text not null default '',
  scores jsonb not null default '{}'::jsonb,
  total numeric not null default 0,
  average numeric not null default 0,
  position int,
  published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(student_id_ref, class, term, session)
);
alter table public.midterm_report_cards enable row level security;
drop policy if exists midterm_rc_select on public.midterm_report_cards;
create policy midterm_rc_select on public.midterm_report_cards for select using (
  public.is_admin(auth.uid()) or public.is_staff(auth.uid())
  or exists(select 1 from public.students s where s.id=midterm_report_cards.student_id and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(), s.id)))
);
drop policy if exists midterm_rc_write on public.midterm_report_cards;
create policy midterm_rc_write on public.midterm_report_cards for all using (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) with check (public.is_admin(auth.uid()) or public.is_staff(auth.uid()));
create index if not exists midterm_rc_lookup_idx on public.midterm_report_cards(class, term, session);
create index if not exists midterm_rc_student_idx on public.midterm_report_cards(student_id_ref);

create or replace function public.generate_midterm_reports(p_class text, p_term text, p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  col_ids uuid[]; r record; total_count int:=0;
begin
  if not (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) then
    return jsonb_build_object('ok',false,'error','Only staff can generate midterm reports');
  end if;
  if coalesce(trim(p_class),'')='' or coalesce(trim(p_term),'')='' or coalesce(trim(p_session),'')='' then
    return jsonb_build_object('ok',false,'error','class, term, session required');
  end if;
  -- Find midterm columns for this class/term/session (name ILIKE midterm% or cbt_assessment_type = test/midterm)
  select array_agg(id) into col_ids from public.assessment_columns
   where lower(trim(class))=lower(trim(p_class))
     and lower(trim(term))=lower(trim(p_term))
     and lower(trim(session))=lower(trim(p_session))
     and (lower(trim(name)) like 'midterm%' or lower(trim(cbt_assessment_type)) in ('test','midterm','mid_term','mid_term_test'));

  if col_ids is null or array_length(col_ids,1) is null then
    return jsonb_build_object('ok',false,'error','No Midterm column found for class/term/session. Create a Midterm Test CBT and push its scores to a column named Midterm first.');
  end if;

  -- Aggregate per student
  for r in
    select
      rs.student_id_ref as sid_ref,
      max(rs.student_name) as sname,
      max(rs.student_id) as sid,
      jsonb_object_agg(rs.subject, rs.score order by rs.subject) as scores,
      sum(rs.score)::numeric as total,
      avg(rs.score)::numeric as avg_score
    from public.report_scores rs
    where rs.column_id = any(col_ids)
    group by rs.student_id_ref
  loop
    insert into public.midterm_report_cards(student_id, student_id_ref, student_name, class, term, session, scores, total, average, updated_at)
    values (r.sid, r.sid_ref, r.sname, p_class, p_term, p_session, coalesce(r.scores,'{}'::jsonb), coalesce(r.total,0), coalesce(r.avg_score,0), now())
    on conflict (student_id_ref, class, term, session) do update
      set scores=excluded.scores, total=excluded.total, average=excluded.average, student_name=excluded.student_name, student_id=excluded.student_id, updated_at=now();

    total_count:=total_count+1;
  end loop;

  -- Compute positions
  with ranked as (select id, rank() over (order by average desc) as pos from public.midterm_report_cards where class=p_class and term=p_term and session=p_session)
  update public.midterm_report_cards m set position=r.pos from ranked r where m.id=r.id;

  return jsonb_build_object('ok',true,'generated',total_count,'class',p_class,'term',p_term,'session',p_session);
end$$;
grant execute on function public.generate_midterm_reports(text,text,text) to authenticated;

create or replace function public.get_midterm_report(p_student_id_ref text, p_class text, p_term text, p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare rec record;
begin
  select * into rec from public.midterm_report_cards where student_id_ref=p_student_id_ref and class=p_class and term=p_term and session=p_session;
  if not found then return jsonb_build_object('ok',false,'error','Midterm report not found. Ask tutor to generate it.'); end if;
  -- Check access: admin/staff or owner student/parent
  if not (public.is_admin(auth.uid()) or public.is_staff(auth.uid()) or exists(select 1 from public.students s where s.admission_no=rec.student_id_ref and (s.user_id=auth.uid() or public.is_parent_of(auth.uid(), s.id)))) then
    return jsonb_build_object('ok',false,'error','Not authorized');
  end if;
  return jsonb_build_object('ok',true,'report', row_to_json(rec));
end$$;
grant execute on function public.get_midterm_report(text,text,text,text) to authenticated;

create or replace function public.publish_midterm_reports(p_class text, p_term text, p_session text, p_publish boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) then return jsonb_build_object('ok',false,'error','Only staff'); end if;
  update public.midterm_report_cards set published=p_publish, updated_at=now() where class=p_class and term=p_term and session=p_session;
  return jsonb_build_object('ok',true,'published',p_publish);
end$$;
grant execute on function public.publish_midterm_reports(text,text,text,boolean) to authenticated;

insert into public.sc_install_state(key,details) values ('v12.47-midterm-reports.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V12.47 midterm reports installed — generate per student, only Midterm scores, separate from terminal, in sync' as status;
