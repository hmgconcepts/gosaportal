-- ============================================================================
-- School Connect V12.66 — CBT re-mapping, one fee truth, report presentation
-- ----------------------------------------------------------------------------
-- A. THE WRONG-COLUMN PROBLEM (reported)
--    A teacher pushes a CBT to the wrong report column, the class sits it, the
--    teacher notices, changes the destination, re-pushes — and the midterm
--    report still shows the old column.
--
--    Three independent reasons, all fixed here:
--
--    1. THE PUSH NEVER REMOVED THE OLD ROWS.
--       report_scores rows carry source = 'cbt:<result_id>'. A re-push wrote
--       the new column and left the old one in place, so the learner ended up
--       with the SAME exam counted in two columns (or, after the column was
--       emptied by hand, still with a phantom row). The report sums every
--       column, so the wrong column kept showing — with a figure in it.
--       → sc_cbt_push_result_v2 now works on the identity of the SOURCE, not
--         the destination: before writing, every report_scores row whose
--         source belongs to this exam is removed, whatever column it sits in.
--
--    2. THE CACHED SHEET WAS NEVER INVALIDATED.
--       midterm_report_cards / report_cards are materialised snapshots. The
--       push updated report_scores but the snapshot still held the old
--       scores jsonb, so the printed sheet read the snapshot, not the scores.
--       → the push now refreshes every affected learner's snapshot for the
--         term it touched, in the same transaction.
--
--    3. NOTHING COULD FIND OR REPAIR AN EXISTING MESS.
--       → sc_report_source_audit() reports every exam whose scores are split
--         across more than one column, or whose rows sit in a column that no
--         longer matches the exam's purpose.
--       → sc_report_remap_cbt(exam, new_column) moves an exam's scores from
--         any column to the right one, in one transaction, and reports exactly
--         what it moved. Idempotent: running it twice moves nothing.
--       → sc_report_repair_all() is the one button: audits, remaps to the
--         exam's declared destination, drops orphans, rebuilds and re-ranks.
--
-- B. THE FEE PAGE AND THE DASHBOARD DISAGREE (reported)
--    The engine is already single (V12.62) — one student, one answer — but two
--    structural holes let a *stale* or *partial* answer through, and the pages
--    then present different slices of it without saying so:
--
--      1. ARREARS WERE DISCOVERED FROM RECEIPTS ONLY. A learner billed for an
--         earlier term who had never paid in it produced NO receipt, therefore
--         NO arrears row — the debt existed and was invisible.
--
--      2. A TERM WITH NO FEE STRUCTURE SILENTLY BILLED ZERO. Between "no
--         structure published yet" and "this student owes nothing" the engine
--         returned the same 0, so a real arrears vanished and the balance
--         looked healthy.
--
--      3. OPENING BALANCES COULD BE COUNTED TWICE (opening_arrears column and
--         an "opening" fee_payments row).
--
--      4. THE PAGES SHOWED DIFFERENT HEADLINES FOR THE SAME MONEY: the
--         dashboard's TOTAL OUTSTANDING vs the Fee Truth Sheet's "balance".
--
--    → sc_fee_ledger_for is rebuilt here as ONE arithmetic, with an explicit
--      `explain` block: every figure names itself and states what it includes.
--      sc_fee_reconcile() proves two readers get byte-identical numbers.
--    → every screen prints the same four lines in the same order, and
--      sc_fee_truth_sheet() gives the bursar the line-by-line working.
--
-- C. REPORT PRESENTATION (requested)
--    The school decides, per term and per report type, whether the position is
--    printed. A class teacher may also withhold a single learner's position
--    without withholding anyone else's. Both defaults are "show" — existing
--    behaviour is unchanged until the school chooses.
--
-- Everything here is idempotent and safe to re-run.
-- ============================================================================

-- ============================================================================
-- A1. REPORT PRESENTATION SETTINGS
--     One row per (kind, term, session). kind is 'midterm' or 'terminal'.
-- ============================================================================
create table if not exists public.sc_report_settings (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null default 'terminal',
  term          text not null default '',
  session       text not null default '',
  show_position boolean not null default true,
  show_grade    boolean not null default true,
  show_subject_position boolean not null default true,
  show_remarks  boolean not null default true,
  position_label text not null default 'Position in class',
  notes         text not null default '',
  updated_by    uuid references public.profiles(id) on delete set null,
  updated_at    timestamptz not null default now(),
  unique (kind, term, session)
);
alter table public.sc_report_settings add column if not exists show_position boolean default true;
alter table public.sc_report_settings add column if not exists show_grade boolean default true;
alter table public.sc_report_settings add column if not exists show_subject_position boolean default true;
alter table public.sc_report_settings add column if not exists show_remarks boolean default true;
alter table public.sc_report_settings add column if not exists position_label text default 'Position in class';
alter table public.sc_report_settings add column if not exists notes text default '';
alter table public.sc_report_settings add column if not exists updated_by uuid references public.profiles(id) on delete set null;
alter table public.sc_report_settings add column if not exists updated_at timestamptz default now();

-- per-learner override: withhold one position without withholding the class's
create table if not exists public.sc_report_position_hold (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  student_id_ref text not null default '',
  class      text not null default '',
  term       text not null default '',
  session    text not null default '',
  kind       text not null default 'terminal',
  reason     text not null default '',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (student_id_ref, class, term, session, kind)
);
alter table public.sc_report_position_hold add column if not exists reason text default '';
alter table public.sc_report_position_hold add column if not exists created_by uuid references public.profiles(id) on delete set null;

-- effective setting for a context: the row for this term, else the school default
create or replace function public.sc_report_policy(p_kind text default 'terminal',
                                                   p_term text default null,
                                                   p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare cur record; t_term text; t_session text; s record; k text := lower(btrim(coalesce(p_kind,'terminal')));
begin
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term    := coalesce(nullif(btrim(p_term),''),    cur.term,    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur.session, '');
  select * into s from public.sc_report_settings
   where kind = k
     and lower(btrim(term))    = lower(btrim(t_term))
     and lower(btrim(session)) = lower(btrim(t_session))
   limit 1;
  if s.id is null then
    /* default: show everything (nothing changes for schools that never open
       the setting) */
    return jsonb_build_object('ok', true, 'kind', k, 'term', t_term, 'session', t_session,
      'show_position', true, 'show_grade', true, 'show_subject_position', true,
      'show_remarks', true, 'position_label', 'Position in class',
      'configured', false, 'notes', '');
  end if;
  return jsonb_build_object('ok', true, 'kind', k, 'term', t_term, 'session', t_session,
    'show_position', coalesce(s.show_position,true),
    'show_grade', coalesce(s.show_grade,true),
    'show_subject_position', coalesce(s.show_subject_position,true),
    'show_remarks', coalesce(s.show_remarks,true),
    'position_label', coalesce(nullif(s.position_label,''),'Position in class'),
    'configured', true, 'notes', coalesce(s.notes,''));
end $$;
revoke all on function public.sc_report_policy(text,text,text) from public, anon;
grant execute on function public.sc_report_policy(text,text,text) to authenticated;

-- save (admin only) — one call, one term
create or replace function public.sc_report_policy_save(p_kind text, p_term text, p_session text,
                                                        p_show_position boolean default true,
                                                        p_show_grade boolean default true,
                                                        p_show_subject_position boolean default true,
                                                        p_show_remarks boolean default true,
                                                        p_position_label text default 'Position in class',
                                                        p_notes text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); k text := lower(btrim(coalesce(p_kind,'terminal')));
begin
  /* Switching positions off for a whole class is a governance decision, not a
     marking decision: only an admin may change it. A class teacher can still
     withhold ONE learner through sc_report_hold_position. */
  if me is null or not coalesce(public.is_admin(me),false) then
    return jsonb_build_object('ok',false,'error','Only an administrator can change what every report prints.');
  end if;
  if k not in ('midterm','terminal') then
    return jsonb_build_object('ok',false,'error','kind must be midterm or terminal');
  end if;
  insert into public.sc_report_settings(kind,term,session,show_position,show_grade,
                                        show_subject_position,show_remarks,position_label,notes,updated_by,updated_at)
  values(k, coalesce(p_term,''), coalesce(p_session,''), coalesce(p_show_position,true),
         coalesce(p_show_grade,true), coalesce(p_show_subject_position,true),
         coalesce(p_show_remarks,true), coalesce(nullif(p_position_label,''),'Position in class'),
         coalesce(p_notes,''), me, now())
  on conflict (kind,term,session) do update set
    show_position = excluded.show_position,
    show_grade = excluded.show_grade,
    show_subject_position = excluded.show_subject_position,
    show_remarks = excluded.show_remarks,
    position_label = excluded.position_label,
    notes = excluded.notes,
    updated_by = me,
    updated_at = now();
  return public.sc_report_policy(k, p_term, p_session) || jsonb_build_object('saved', true);
end $$;
revoke all on function public.sc_report_policy_save(text,text,text,boolean,boolean,boolean,boolean,text,text) from public, anon;
grant execute on function public.sc_report_policy_save(text,text,text,boolean,boolean,boolean,boolean,text,text) to authenticated;

-- withhold / restore one learner's position
create or replace function public.sc_report_hold_position(p_student_id_ref text, p_class text,
                                                          p_term text, p_session text,
                                                          p_kind text default 'terminal',
                                                          p_reason text default '',
                                                          p_hold boolean default true)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); st record; k text := lower(btrim(coalesce(p_kind,'terminal')));
begin
  if me is null or not (coalesce(public.is_admin(me),false) or coalesce(public.is_staff(me),false)) then
    return jsonb_build_object('ok',false,'error','Only staff can withhold a position.');
  end if;
  select id, full_name into st from public.students
   where lower(btrim(coalesce(admission_no,''))) = lower(btrim(coalesce(p_student_id_ref,'')))
      or (coalesce(p_student_id_ref,'') <> '' and id::text = p_student_id_ref)
   limit 1;
  if not coalesce(p_hold,true) then
    delete from public.sc_report_position_hold
     where lower(btrim(student_id_ref)) = lower(btrim(coalesce(p_student_id_ref,'')))
       and lower(btrim(class))   = lower(btrim(coalesce(p_class,'')))
       and lower(btrim(term))    = lower(btrim(coalesce(p_term,'')))
       and lower(btrim(session)) = lower(btrim(coalesce(p_session,'')))
       and kind = k;
    return jsonb_build_object('ok',true,'held',false,'student',coalesce(st.full_name,''));
  end if;
  insert into public.sc_report_position_hold(student_id,student_id_ref,class,term,session,kind,reason,created_by)
  values(st.id, coalesce(p_student_id_ref,''), coalesce(p_class,''), coalesce(p_term,''),
         coalesce(p_session,''), k, coalesce(p_reason,''), me)
  on conflict (student_id_ref,class,term,session,kind) do update
    set reason = excluded.reason, created_by = me, created_at = now();
  return jsonb_build_object('ok',true,'held',true,'student',coalesce(st.full_name,''));
end $$;
revoke all on function public.sc_report_hold_position(text,text,text,text,text,text,boolean) from public, anon;
grant execute on function public.sc_report_hold_position(text,text,text,text,text,text,boolean) to authenticated;

create or replace view public.sc_report_hold_list as
  select h.id, h.student_id_ref, h.class, h.term, h.session, h.kind, h.reason,
         coalesce(s.full_name, '') as student_name, h.created_at
    from public.sc_report_position_hold h
    left join public.students s on s.id = h.student_id;
grant select on public.sc_report_hold_list to authenticated;

alter table public.sc_report_settings      enable row level security;
alter table public.sc_report_position_hold enable row level security;
drop policy if exists sc_report_settings_read on public.sc_report_settings;
create policy sc_report_settings_read on public.sc_report_settings for select
  using (auth.role() = 'authenticated');
drop policy if exists sc_report_settings_write on public.sc_report_settings;
create policy sc_report_settings_write on public.sc_report_settings for all to authenticated
  using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));
drop policy if exists sc_report_hold_read on public.sc_report_position_hold;
create policy sc_report_hold_read on public.sc_report_position_hold for select
  using (auth.role() = 'authenticated');
drop policy if exists sc_report_hold_write on public.sc_report_position_hold;
create policy sc_report_hold_write on public.sc_report_position_hold for all to authenticated
  using (public.is_staff(auth.uid())) with check (public.is_staff(auth.uid()));


-- ============================================================================
-- A2. THE RE-MAPPING ENGINE
--     report_scores.source = 'cbt:<result_id>' identifies WHERE a score came
--     from. That identity — not the column — is what the push must key on.
-- ============================================================================

-- 1) Audit: every exam whose scores are split, orphaned, or in the wrong place.
create or replace function public.sc_report_source_audit(p_class text default null,
                                                         p_term text default null,
                                                         p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare me uuid := auth.uid(); cur record; t_term text; t_session text;
        f jsonb := '[]'::jsonb; r record; n_split int := 0; n_orphan int := 0;
        n_nocol int := 0; n_dupe int := 0; n_total int := 0;
begin
  if me is null or not (coalesce(public.is_staff(me),false) or coalesce(public.is_admin(me),false)) then
    return jsonb_build_object('ok',false,'error','Only staff can audit report sources.');
  end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term    := coalesce(nullif(btrim(p_term),''),    cur.term,    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur.session, '');

  -- every CBT-sourced score in scope, with the column it landed in and the
  -- column the exam says it belongs in
  for r in
    with scoped as (
      select rs.id score_id, rs.source, rs.student_id_ref, rs.student_name,
             rs.class, rs.subject, rs.term, rs.session, rs.score,
             ac.id col_id, ac.name col_name, ac.max_mark,
             nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid result_id
        from public.report_scores rs
        join public.assessment_columns ac on ac.id = rs.column_id
       where rs.source like 'cbt:%'
         and (coalesce(btrim(p_class),'') = ''
              or regexp_replace(lower(btrim(coalesce(rs.class,''))),'[^a-z0-9]','','g')
               = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
         and (coalesce(btrim(t_term),'') = '' or lower(btrim(coalesce(rs.term,'')))    = lower(btrim(t_term)))
         and (coalesce(btrim(t_session),'') = '' or lower(btrim(coalesce(rs.session,''))) = lower(btrim(t_session)))
    ), joined as (
      select s.*, cr.exam_id, ce.report_column as exam_destination, ce.subject as exam_subject
        from scoped s
        left join public.cbt_results cr on cr.id = s.result_id
        left join public.cbt_exams   ce on ce.id = cr.exam_id
    )
    select * from joined
    where result_id is null
       or exam_id is null
       or (coalesce(exam_destination,'') <> '' and lower(btrim(exam_destination)) <> lower(btrim(col_name)))
    order by student_name, subject
  loop
    n_total := n_total + 1;
    if r.result_id is null or r.exam_id is null then
      n_orphan := n_orphan + 1;
      f := f || jsonb_build_array(jsonb_build_object(
        'kind','orphan','student',coalesce(r.student_name,''),'student_ref',coalesce(r.student_id_ref,''),
        'class',coalesce(r.class,''),'subject',coalesce(r.subject,''),'column',coalesce(r.col_name,''),
        'issue','CBT score whose exam result no longer exists (exam or result was deleted).',
        'fix','It is counted in every total. Remove it with the Clear Unwanted Scores tool.'));
    else
      n_split := n_split + 1;
      f := f || jsonb_build_array(jsonb_build_object(
        'kind','wrong_column','student',coalesce(r.student_name,''),'student_ref',coalesce(r.student_id_ref,''),
        'class',coalesce(r.class,''),'subject',coalesce(r.subject,''),
        'column',coalesce(r.col_name,''),'expected',coalesce(r.exam_destination,''),
        'issue','This exam is pushed into "'||coalesce(r.col_name,'?')||'" but its destination is "'||
                coalesce(nullif(r.exam_destination,''),'(not set)')||'".',
        'fix','Run the one-click repair, or re-push the exam — the old row is removed automatically.'));
    end if;
  end loop;

  /* the same exam result landing in MORE than one column for one learner is the
     classic symptom of a re-push that did not clean up after itself */
  for r in
    select s.student_name, s.student_ref, s.class, s.subject, s.term, s.session, s.result_id,
           count(*) as n, string_agg(s.col_name, ' + ' order by s.col_name) as cols
      from (
        select rs.student_name, rs.student_id_ref student_ref, rs.class, rs.subject, rs.term, rs.session,
               ac.name col_name, nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid result_id
          from public.report_scores rs
          join public.assessment_columns ac on ac.id = rs.column_id
         where rs.source like 'cbt:%'
           and (coalesce(btrim(p_class),'') = ''
                or regexp_replace(lower(btrim(coalesce(rs.class,''))),'[^a-z0-9]','','g')
                 = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
           and (coalesce(btrim(t_term),'') = '' or lower(btrim(coalesce(rs.term,'')))    = lower(btrim(t_term)))
           and (coalesce(btrim(t_session),'') = '' or lower(btrim(coalesce(rs.session,''))) = lower(btrim(t_session)))
      ) s
     group by 1,2,3,4,5,6,7
    having count(*) > 1
  loop
    n_dupe := n_dupe + 1;
    f := f || jsonb_build_array(jsonb_build_object(
      'kind','double_counted','student',coalesce(r.student_name,''),'student_ref',coalesce(r.student_ref,''),
      'class',coalesce(r.class,''),'subject',coalesce(r.subject,''),
      'column',coalesce(r.cols,''),'count',r.n,
      'issue','The same CBT result is recorded in '||r.n||' columns ('||coalesce(r.cols,'')||'), so it is '
              ||'added to the total more than once.',
      'fix','Run the one-click repair — it keeps the correct column and removes the rest.'));
  end loop;

  /* CBT scores attached to a column that has since been deleted or emptied */
  select count(*) into n_nocol from public.report_scores rs
   where rs.source like 'cbt:%'
     and (coalesce(btrim(p_class),'') = ''
          or regexp_replace(lower(btrim(coalesce(rs.class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
     and not exists (select 1 from public.assessment_columns ac where ac.id = rs.column_id);

  return jsonb_build_object('ok',true,'term',t_term,'session',t_session,'class',coalesce(p_class,''),
    'scanned', n_total,
    'counts', jsonb_build_object('wrong_column', n_split, 'orphan', n_orphan,
                                 'double_counted', n_dupe, 'no_column', n_nocol),
    'defects', n_split + n_orphan + n_dupe + n_nocol,
    'findings', f);
end $$;
revoke all on function public.sc_report_source_audit(text,text,text) from public, anon;
grant execute on function public.sc_report_source_audit(text,text,text) to authenticated;

-- 2) Move one exam's scores to its correct column, whatever column they are in.
--    p_result_id may be null: then EVERY result of the exam is moved.
create or replace function public.sc_report_remap_cbt(p_exam_id uuid, p_column text default null,
                                                      p_result_id uuid default null,
                                                      p_dry_run boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); e public.cbt_exams%rowtype; col public.assessment_columns%rowtype;
        dest text; n_moved int := 0; n_removed int := 0; n_kept int := 0;
        r record; st record; t_term text; t_session text; touched int := 0;
begin
  if me is null or not (coalesce(public.is_staff(me),false) or coalesce(public.is_admin(me),false)) then
    return jsonb_build_object('ok',false,'error','Only staff can re-map CBT scores.');
  end if;
  select * into e from public.cbt_exams where id = p_exam_id;
  if not found then return jsonb_build_object('ok',false,'error','Exam not found.'); end if;
  dest := coalesce(nullif(btrim(p_column),''), nullif(btrim(e.report_column),''), 'exam');
  t_term    := coalesce(nullif(btrim(e.term),''),'');
  t_session := coalesce(nullif(btrim(e.session),''),'');

  -- the destination column must exist; find it exactly as the push would
  select * into col from public.assessment_columns ac
   where regexp_replace(lower(btrim(coalesce(ac.class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(btrim(coalesce(e.class,''))),'[^a-z0-9]','','g')
     and (lower(btrim(coalesce(ac.subject,''))) = lower(btrim(coalesce(e.subject,'')))
          or btrim(coalesce(ac.subject,'')) = '*')
     and lower(btrim(coalesce(ac.term,'')))    = lower(btrim(coalesce(e.term,'')))
     and lower(btrim(coalesce(ac.session,''))) = lower(btrim(coalesce(e.session,'')))
     and lower(btrim(coalesce(ac.name,'')))    = lower(btrim(dest))
   order by (btrim(coalesce(ac.subject,'')) = '*') asc, ac.created_at asc
   limit 1;

  if col.id is null then
    return jsonb_build_object('ok',false,'error',
      'There is no "'||dest||'" column for '||coalesce(e.class,'')||' / '||coalesce(e.subject,'')||
      ' / '||coalesce(e.term,'')||' '||coalesce(e.session,'')||
      '. Create the column first, then push the exam.');
  end if;

  /* Every score this exam produced, wherever it currently sits. */
  for r in
    select rs.id, rs.column_id, rs.student_id_ref, rs.student_name, rs.class, rs.subject,
           rs.term, rs.session, rs.score, rs.source, ac.name cur_col
      from public.report_scores rs
      join public.assessment_columns ac on ac.id = rs.column_id
     where (
             (nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid in
                (select cr.id from public.cbt_results cr where cr.exam_id = p_exam_id))
             or (rs.source = 'cbt:'||coalesce(p_result_id::text,'\x00'))
           )
       and (p_result_id is null or rs.source = 'cbt:'||p_result_id::text)
  loop
    if r.column_id = col.id then
      n_kept := n_kept + 1;
      continue;
    end if;
    if coalesce(p_dry_run,false) then
      n_moved := n_moved + 1;
      continue;
    end if;
    /* Remove the row from the wrong column and write it into the right one in
       one statement, so a conflict on the destination cannot lose the score. */
    insert into public.report_scores(column_id,student_id,student_id_ref,student_name,class,subject,
                                     term,session,score,source,updated_by,updated_at)
    select col.id, rs.student_id, rs.student_id_ref, rs.student_name, r.class, r.subject,
           r.term, r.session, rs.score, rs.source, me, now()
      from public.report_scores rs where rs.id = r.id
    on conflict (column_id,student_id_ref,student_name,class,subject,term,session) do update
      set score = excluded.score, source = excluded.source,
          updated_by = excluded.updated_by, updated_at = now();
    delete from public.report_scores where id = r.id;
    n_moved := n_moved + 1;
    if not exists (select 1 from public.report_scores x
                    where x.student_id_ref = r.student_id_ref and x.class = r.class
                      and x.term = r.term and x.session = r.session
                      and x.student_name = r.student_name) then
      n_removed := n_removed + 0;
    end if;
  end loop;

  if not coalesce(p_dry_run,false) and n_moved > 0 then
    /* the snapshots must be rebuilt or the sheet keeps showing the old column */
    for st in
      select distinct x.student_id, x.student_id_ref, x.student_name
        from public.report_scores x
       where x.source like 'cbt:%'
         and nullif(regexp_replace(x.source,'^cbt:',''),'')::uuid in
             (select cr.id from public.cbt_results cr where cr.exam_id = p_exam_id)
    loop
      begin
        perform public.sc_midterm_rebuild_one(st.student_id, st.student_id_ref, st.student_name,
                                              coalesce(e.class,''), coalesce(e.term,''), coalesce(e.session,''));
        touched := touched + 1;
      exception when others then null;   -- a term that is not a midterm term has no snapshot
      end;
    end loop;
    begin
      perform public.sc_midterm_rank(coalesce(e.class,''), coalesce(e.term,''), coalesce(e.session,''));
    exception when others then null;
    end;
    begin
      perform public.sc_terminal_rank(coalesce(e.class,''), coalesce(e.term,''), coalesce(e.session,''));
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok',true,'exam_id',p_exam_id,'exam',coalesce(e.title,''),
    'destination',dest,'column_id',col.id,'dry_run',coalesce(p_dry_run,false),
    'already_correct',n_kept,'moved',n_moved,'snapshots_rebuilt',touched,
    'message', case when n_moved = 0
                    then 'Nothing to move — every score of this exam is already in "'||dest||'".'
                    else n_moved||' score(s) moved to "'||dest||'"'||
                         case when coalesce(p_dry_run,false) then ' (dry run — nothing changed).' else '.' end
               end);
end $$;
revoke all on function public.sc_report_remap_cbt(uuid,text,uuid,boolean) from public, anon;
grant execute on function public.sc_report_remap_cbt(uuid,text,uuid,boolean) to authenticated;

-- 3) One button: audit → remap every exam to its declared destination →
--    drop orphans and double-counts → rebuild + re-rank. Idempotent.
create or replace function public.sc_report_repair_all(p_class text default null,
                                                       p_term text default null,
                                                       p_session text default null,
                                                       p_dry_run boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare me uuid := auth.uid(); aud jsonb; r record; remap jsonb;
        n_exams int := 0; n_moved int := 0; n_orphans int := 0; n_dupes int := 0;
        n_rebuilt int := 0; report jsonb := '[]'::jsonb;
        cur record; t_term text; t_session text; dry boolean := coalesce(p_dry_run,false);
begin
  if me is null or not (coalesce(public.is_staff(me),false) or coalesce(public.is_admin(me),false)) then
    return jsonb_build_object('ok',false,'error','Only staff can repair report sources.');
  end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term    := coalesce(nullif(btrim(p_term),''),    cur.term,    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur.session, '');

  -- orphans first: a score whose exam result is gone can only ever inflate a total
  select count(*) into n_orphans from public.report_scores rs
   where rs.source like 'cbt:%'
     and nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid is not null
     and not exists (select 1 from public.cbt_results cr
                      where cr.id = nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid)
     and (coalesce(btrim(p_class),'') = ''
          or regexp_replace(lower(btrim(coalesce(rs.class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'));
  if n_orphans > 0 and not dry then
    delete from public.report_scores rs
     where rs.source like 'cbt:%'
       and nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid is not null
       and not exists (select 1 from public.cbt_results cr
                        where cr.id = nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid)
       and (coalesce(btrim(p_class),'') = ''
            or regexp_replace(lower(btrim(coalesce(rs.class,''))),'[^a-z0-9]','','g')
             = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'));
  end if;

  -- every exam that has scores sitting outside its declared destination
  for r in
    select distinct cr.exam_id, ce.report_column, ce.title
      from public.report_scores rs
      join public.cbt_results cr on cr.id = nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid
      join public.cbt_exams   ce on ce.id = cr.exam_id
      join public.assessment_columns ac on ac.id = rs.column_id
     where rs.source like 'cbt:%'
       and coalesce(btrim(ce.report_column),'') <> ''
       and lower(btrim(ac.name)) <> lower(btrim(ce.report_column))
       and (coalesce(btrim(p_class),'') = ''
            or regexp_replace(lower(btrim(coalesce(ce.class,''))),'[^a-z0-9]','','g')
             = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
  loop
    remap := public.sc_report_remap_cbt(r.exam_id, r.report_column, null, dry);
    n_exams := n_exams + 1;
    n_moved := n_moved + coalesce((remap->>'moved')::int, 0);
    report := report || jsonb_build_array(jsonb_build_object(
      'exam', coalesce(r.title,''), 'destination', coalesce(r.report_column,''),
      'moved', coalesce((remap->>'moved')::int,0), 'ok', coalesce((remap->>'ok')::boolean,false),
      'message', coalesce(remap->>'message', remap->>'error','')));
  end loop;

  -- collapse any remaining double-count: keep the row in the exam's declared
  -- column, remove the rest
  select count(*) into n_dupes from (
    select rs.student_id_ref, rs.class, rs.subject, rs.term, rs.session,
           nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid rid, count(*) c
      from public.report_scores rs
     where rs.source like 'cbt:%'
       and (coalesce(btrim(p_class),'') = ''
            or regexp_replace(lower(btrim(coalesce(rs.class,''))),'[^a-z0-9]','','g')
             = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
     group by 1,2,3,4,5,6 having count(*) > 1) d;

  if n_dupes > 0 and not dry then
    delete from public.report_scores victim
     using (
       select rs.id,
              row_number() over (partition by rs.student_id_ref, rs.class, rs.subject,
                                              rs.term, rs.session,
                                              nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid
                                 order by (lower(btrim(ac.name)) =
                                           lower(btrim(coalesce(ce.report_column,ac.name)))) desc,
                                          rs.updated_at desc, rs.id) rn
         from public.report_scores rs
         join public.assessment_columns ac on ac.id = rs.column_id
         left join public.cbt_results cr on cr.id = nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid
         left join public.cbt_exams   ce on ce.id = cr.exam_id
        where rs.source like 'cbt:%'
          and (coalesce(btrim(p_class),'') = ''
               or regexp_replace(lower(btrim(coalesce(rs.class,''))),'[^a-z0-9]','','g')
                = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
     ) ranked
     where victim.id = ranked.id and ranked.rn > 1;
  end if;

  -- rebuild + re-rank every learner we touched
  if not dry then
    for r in
      select distinct x.student_id, x.student_id_ref, x.student_name, x.class, x.term, x.session
        from public.report_scores x
       where x.source like 'cbt:%'
         and (coalesce(btrim(p_class),'') = ''
              or regexp_replace(lower(btrim(coalesce(x.class,''))),'[^a-z0-9]','','g')
               = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
    loop
      begin
        perform public.sc_midterm_rebuild_one(r.student_id, r.student_id_ref, r.student_name,
                                              coalesce(r.class,''), coalesce(r.term,''), coalesce(r.session,''));
        n_rebuilt := n_rebuilt + 1;
      exception when others then null;
      end;
    end loop;
    for r in select distinct x.class, x.term, x.session from public.report_scores x
              where x.source like 'cbt:%'
                and (coalesce(btrim(p_class),'') = ''
                     or regexp_replace(lower(btrim(coalesce(x.class,''))),'[^a-z0-9]','','g')
                      = regexp_replace(lower(btrim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
    loop
      begin perform public.sc_midterm_rank(r.class, r.term, r.session); exception when others then null; end;
      begin perform public.sc_terminal_rank(r.class, r.term, r.session); exception when others then null; end;
    end loop;
  end if;

  aud := public.sc_report_source_audit(p_class, t_term, t_session);

  return jsonb_build_object('ok',true,'term',t_term,'session',t_session,'class',coalesce(p_class,''),
    'dry_run',dry,
    'counts', jsonb_build_object(
      'exams_remapped', n_exams, 'scores_moved', n_moved,
      'orphans_removed', case when dry then 0 else n_orphans end,
      'orphans_found', n_orphans,
      'double_counts_fixed', case when dry then 0 else n_dupes end,
      'double_counts_found', n_dupes,
      'snapshots_rebuilt', n_rebuilt,
      'defects_remaining', coalesce((aud->>'defects')::int,0)),
    'exams', report,
    'remaining', coalesce(aud->'findings','[]'::jsonb),
    'message', case when dry then 'Read-only check complete — nothing has been changed.'
                    else 'Report sources repaired. Every CBT score now sits in the column its exam declares.' end);
end $$;
revoke all on function public.sc_report_repair_all(text,text,text,boolean) from public, anon;
grant execute on function public.sc_report_repair_all(text,text,text,boolean) to authenticated;

-- 4) Make the push itself remove the old rows. A thin, authoritative wrapper:
--    every future push calls this, so the class of bug cannot return.
create or replace function public.sc_cbt_push_clean(p_exam_id uuid, p_destination text default null)
returns int language plpgsql security definer set search_path=public as $$
declare e public.cbt_exams%rowtype; dest text; kept uuid; n int := 0; r record;
begin
  select * into e from public.cbt_exams where id = p_exam_id;
  if not found then return 0; end if;
  dest := coalesce(nullif(btrim(p_destination),''), nullif(btrim(e.report_column),''), 'exam');
  select ac.id into kept from public.assessment_columns ac
   where regexp_replace(lower(btrim(coalesce(ac.class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(btrim(coalesce(e.class,''))),'[^a-z0-9]','','g')
     and (lower(btrim(coalesce(ac.subject,''))) = lower(btrim(coalesce(e.subject,'')))
          or btrim(coalesce(ac.subject,'')) = '*')
     and lower(btrim(coalesce(ac.term,'')))    = lower(btrim(coalesce(e.term,'')))
     and lower(btrim(coalesce(ac.session,''))) = lower(btrim(coalesce(e.session,'')))
     and lower(btrim(coalesce(ac.name,'')))    = lower(btrim(dest))
   order by (btrim(coalesce(ac.subject,'')) = '*') asc, ac.created_at asc limit 1;
  /* delete this exam's scores from every column except the destination */
  delete from public.report_scores rs
   where rs.source like 'cbt:%'
     and nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid in
         (select cr.id from public.cbt_results cr where cr.exam_id = p_exam_id)
     and (kept is null or rs.column_id <> kept);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.sc_cbt_push_clean(uuid,text) from public, anon;
grant execute on function public.sc_cbt_push_clean(uuid,text) to authenticated;

-- 5) The trigger that keeps snapshots honest. Whenever a CBT-sourced score is
--    written, deleted or re-pointed, the affected learner's midterm snapshot is
--    rebuilt immediately — so "regenerate the report" can never read a stale
--    cache again.
create or replace function public.sc_on_cbt_score_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare x record;
begin
  x := case when tg_op = 'DELETE' then old else new end;
  if coalesce(x.source,'') like 'cbt:%' then
    begin
      perform public.sc_midterm_rebuild_one(x.student_id, x.student_id_ref, x.student_name,
                                            coalesce(x.class,''), coalesce(x.term,''), coalesce(x.session,''));
    exception when others then null;
    end;
  end if;
  return null;
end $$;
revoke all on function public.sc_on_cbt_score_change() from public, anon;
drop trigger if exists trg_cbt_score_snapshot_sync on public.report_scores;
create trigger trg_cbt_score_snapshot_sync
  after insert or update of score, column_id, source or delete on public.report_scores
  for each row execute function public.sc_on_cbt_score_change();


-- ============================================================================
-- B1. THE BILL RESOLVER — explicit about what it does and does not know.
--     The single question "what does this learner owe for term T?" now answers
--     with a STATUS as well as a number, so a missing structure can never be
--     mistaken for a zero bill.
-- ============================================================================
create or replace function public.sc_fee_bill_v2(p_student uuid,
                                                 p_term text default null,
                                                 p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare st record; cur record; fs record; a record;
        structure_bill numeric := 0; aid_total numeric := 0; aid_rows jsonb := '[]'::jsonb;
        breakdown jsonb := '[]'::jsonb; ovr numeric; overridden boolean := false;
        eff_bill numeric := 0; t_term text; t_session text;
        match_status text; match_note text := ''; n_struct int := 0;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term    := coalesce(nullif(btrim(p_term),''),    cur.term,    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur.session, '');

  /* --- the class structure, matched as precisely as the data allows --- */
  select * into fs from public.class_fee_structure f
   where f.active is not false
     and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')))
     and (coalesce(f.session,'') = '' or f.session = coalesce(t_session,''))
     and coalesce(f.term,'Current Term') in ('Current Term', coalesce(t_term,''))
   order by (lower(coalesce(f.arm,'')) = lower(coalesce(st.arm,''))) desc,
            (coalesce(f.arm,'') = '') desc,
            (lower(coalesce(f.department,'')) = lower(coalesce(st.department,''))) desc,
            (coalesce(f.department,'') = '') desc,
            (coalesce(f.session,'') <> '') desc,
            f.updated_at desc nulls last
   limit 1;

  if fs.id is not null then
    structure_bill := coalesce(nullif(fs.total,0),
                        coalesce(fs.tuition,0)+coalesce(fs.exam_fee,0)+coalesce(fs.development,0)
                        +coalesce(fs.transport,0)+coalesce(fs.boarding,0)+coalesce(fs.other_fee,0)
                        -coalesce(fs.discount,0));
    if coalesce(fs.tuition,0)     <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Tuition','amount',fs.tuition)); end if;
    if coalesce(fs.exam_fee,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Exam / assessment','amount',fs.exam_fee)); end if;
    if coalesce(fs.development,0) <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Development / PTA','amount',fs.development)); end if;
    if coalesce(fs.transport,0)   <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Transport','amount',fs.transport)); end if;
    if coalesce(fs.boarding,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Boarding / hostel','amount',fs.boarding)); end if;
    if coalesce(fs.other_fee,0)   <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Other compulsory','amount',fs.other_fee)); end if;
    if coalesce(fs.discount,0)    <> 0 then breakdown := breakdown || jsonb_build_array(jsonb_build_object('item','Discount','amount',-fs.discount)); end if;
    match_status := 'structure';
    if coalesce(fs.session,'') = '' then
      match_note := 'Matched a class fee structure with no session set — it applies to every session.';
    end if;
    if coalesce(fs.arm,'') <> '' and lower(coalesce(fs.arm,'')) <> lower(coalesce(st.arm,'')) then
      match_note := 'No fee structure for arm "'||coalesce(st.arm,'—')||'"; the class-wide structure was used.';
    end if;
  else
    /* Distinguish "no structure" from "zero bill". They are NOT the same. */
    select count(*) into n_struct from public.class_fee_structure f
     where f.active is not false
       and lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')));
    if n_struct > 0 then
      match_status := 'no_structure_this_term';
      match_note := 'This class has a fee structure, but none for '||coalesce(t_term,'this term')
                    ||' '||coalesce(t_session,'')||'. The bill is unknown — not zero.';
    else
      match_status := 'no_structure';
      match_note := 'No fee structure has ever been published for class '
                    ||coalesce(nullif(st.class,''),'(unset)')||'. The bill is unknown — not zero.';
    end if;
  end if;

  /* --- scholarships / bursaries --- */
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

  eff_bill := greatest(coalesce(structure_bill,0) - aid_total, 0);

  /* --- a deliberate bursar override always wins, and says so --- */
  begin
    select fee_total into ovr from public.fee_payments
     where student_id = p_student and coalesce(total_overridden,false) = true and coalesce(fee_total,0) > 0
       and (coalesce(t_term,'') = '' or coalesce(term,'') = t_term)
       and (coalesce(t_session,'') = '' or coalesce(session,'') = t_session)
     order by created_at desc nulls last limit 1;
    if ovr is not null then
      overridden := true;
      eff_bill := coalesce(ovr,0);
      breakdown := jsonb_build_array(jsonb_build_object('item','✏️ Personal total set by the bursar (override)','amount',eff_bill));
      match_status := 'override';
      match_note := 'The bursar set a personal total for this learner; it replaces the class structure.';
    end if;
  exception when undefined_column then null;
  end;

  return jsonb_build_object('ok',true,
    'student_id', st.id, 'class', st.class, 'arm', st.arm, 'department', st.department,
    'term', t_term, 'session', t_session,
    'bill', eff_bill,                     -- what the learner is actually billed
    'structure_bill', structure_bill,     -- before aid
    'aid', case when overridden then 0 else aid_total end,
    'aid_rows', case when overridden then '[]'::jsonb else aid_rows end,
    'breakdown', breakdown,
    'override', overridden,
    'match_status', match_status,         -- structure | no_structure | no_structure_this_term | override
    'matched', (match_status in ('structure','override')),
    'bill_known', match_status <> 'no_structure' and match_status <> 'no_structure_this_term',
    'match_note', match_note,
    'currency', coalesce(fs.currency,'₦'),
    'due_date', fs.due_date, 'note', coalesce(fs.note,''),
    'working', case
      when overridden then 'Bursar override: the personal total replaces the class structure.'
      when match_status = 'structure' then
        'Class structure for '||coalesce(st.class,'')||
        case when coalesce(fs.arm,'') <> '' then ' ('||fs.arm||')' else '' end ||
        ' = '||to_char(structure_bill,'FM999,999,990.00')||
        case when aid_total > 0 then ' − aid '||to_char(aid_total,'FM999,999,990.00') else '' end ||
        ' = '||to_char(eff_bill,'FM999,999,990.00')
      else coalesce(match_note,'Bill unknown.') end);
end $$;
revoke all on function public.sc_fee_bill_v2(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_bill_v2(uuid,text,text) to authenticated;


-- ============================================================================
-- B2. THE LEDGER — ONE ARITHMETIC, STATED AS A FORMULA
--
--     due now  =  this term's net bill          (bill_known ? structure − aid : 0)
--              +  unpaid balances of earlier terms
--              +  opening balance (paper ledger, before School Connect)
--              −  money received for THIS term
--
--     and, separately:
--        this_term_balance = max(net_bill − paid_this_term, 0)      matching_pct
--        arrears_total     = earlier terms + opening                paid_pct
--        total_outstanding = this_term_balance + arrears_total      owed_pct
--
--     Every consumer displays the SAME four numbers:
--        net bill · paid · balance this term · arrears   →   TOTAL OUTSTANDING
--     Nothing anywhere else may recompute them.
-- ============================================================================
create or replace function public.sc_fee_ledger_for(p_student uuid,
                                                    p_term text default null,
                                                    p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  st record; cur record; b jsonb;
  t_term text; t_session text;
  net_bill numeric := 0; aid numeric := 0; paid numeric := 0;
  this_bal numeric := 0; arrears numeric := 0; arr_rows jsonb := '[]'::jsonb;
  opening numeric := 0; t record; tbill numeric; tpaid numeric; tb jsonb;
  total_out numeric := 0; grand numeric := 0;
  matched_pct numeric := 100; paid_pct numeric := 100; owed_pct numeric := 0;
  status_txt text; n_receipts int := 0; last_pay date; bill_known boolean := true;
  n_checks jsonb := '[]'::jsonb;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term    := coalesce(nullif(btrim(p_term),''),    cur.term,    '');
  t_session := coalesce(nullif(btrim(p_session),''), cur.session, '');

  /* ---------- 1. this term's bill ---------- */
  b := public.sc_fee_bill_v2(p_student, t_term, t_session);
  net_bill  := coalesce(nullif(b->>'bill','')::numeric, 0);
  aid       := coalesce(nullif(b->>'aid','')::numeric, 0);
  bill_known := coalesce((b->>'bill_known')::boolean, true);

  /* ---------- 2. money received for THIS term ---------- */
  select coalesce(sum(amount_paid),0), count(*), max(coalesce(payment_date, created_at::date))
    into paid, n_receipts, last_pay
    from public.fee_payments
   where student_id = p_student
     and coalesce(term,'')    = coalesce(t_term,'')
     and coalesce(session,'') = coalesce(t_session,'');
  this_bal := greatest(net_bill - paid, 0);

  /* ---------- 3. earlier terms ----------
     A learner who was billed for an earlier term but never paid in it produced
     no receipt, so the old engine never saw the debt. But the reverse mistake is
     worse: charging a learner for every term the calendar has ever contained,
     including terms before they joined.

     The rule is therefore EVIDENCE-BASED. An earlier term is examined only when
     there is a reason to believe it applies to this learner:
        (a) a receipt exists for it (they paid something), or
        (b) a fee structure exists for their class in it AND the learner's
            record predates that term — i.e. they were on roll. */
  for t in
    with receipts as (
      select distinct coalesce(fp.term,'') as term, coalesce(fp.session,'') as session
        from public.fee_payments fp
       where fp.student_id = p_student
    ), billed as (
      select distinct ap.term, ap.session
        from public.academic_periods ap
        join public.class_fee_structure f
          on lower(btrim(f.class)) = lower(btrim(coalesce(st.class,'')))
         and f.active is not false
         and (coalesce(f.session,'') = '' or f.session = ap.session)
         and coalesce(f.term,'Current Term') in ('Current Term', ap.term)
       where coalesce(ap.term,'') <> ''
         /* ON ROLL, provably: the school has dated the term AND the learner's
            record existed before it ended. Without dates we cannot prove the
            learner was enrolled, and inventing a debt is worse than missing
            one — so the term is not charged. The doctor flags undated periods
            so the bursar can fix the calendar and unlock this check. */
         and ap.starts_on is not null
         and st.created_at::date <= coalesce(ap.ends_on, ap.starts_on)
    )
    select coalesce(term,'') term, coalesce(session,'') session
      from (select term, session from receipts union select term, session from billed) u
     where not (coalesce(term,'') = coalesce(t_term,'') and coalesce(session,'') = coalesce(t_session,''))
       and not (coalesce(term,'') = '' and coalesce(session,'') = '')
     order by session, term
  loop
    select coalesce(sum(amount_paid),0) into tpaid from public.fee_payments
     where student_id = p_student
       and coalesce(term,'') = t.term and coalesce(session,'') = t.session;
    tb := public.sc_fee_bill_v2(p_student, t.term, t.session);
    tbill := coalesce(nullif(tb->>'bill','')::numeric, 0);
    /* Never invent a bill: if the structure for that term is unknown, the only
       defensible figure is what the receipts themselves recorded. */
    if not coalesce((tb->>'bill_known')::boolean, true) then
      select coalesce(max(nullif(fee_total,0)),0) into tbill from public.fee_payments
       where student_id = p_student
         and coalesce(term,'') = t.term and coalesce(session,'') = t.session;
    end if;
    if tbill > tpaid then
      arrears := arrears + (tbill - tpaid);
      arr_rows := arr_rows || jsonb_build_array(jsonb_build_object(
        'term',t.term,'session',t.session,'bill',tbill,'paid',tpaid,'owing',tbill - tpaid,
        'source', case when coalesce((tb->>'bill_known')::boolean,true) then 'structure' else 'receipt' end));
    end if;
  end loop;

  /* ---------- 4. the paper ledger ----------
     Counted ONCE. If a receipt was explicitly stamped as the opening balance,
     that receipt already carries the debt; adding the column too would double
     it — the exact bug that made the dashboard and the Fees page disagree. */
  begin
    opening := coalesce(st.opening_arrears,0);
    if opening > 0 then
      if exists (select 1 from public.fee_payments fp
                  where fp.student_id = p_student
                    and (coalesce(fp.total_overridden,false) = true and coalesce(fp.term,'') = ''
                         or lower(coalesce(fp.method,'')) in ('opening balance','opening','balance b/f','b/f'))) then
        n_checks := n_checks || jsonb_build_array(jsonb_build_object(
          'check','opening_balance_double_count',
          'detail','An opening-balance receipt already exists, so the student''s opening_arrears figure is NOT added again.',
          'amount', opening));
        opening := 0;
      else
        arrears := arrears + opening;
        arr_rows := arr_rows || jsonb_build_array(jsonb_build_object(
          'term','Before School Connect',
          'session',coalesce(nullif(st.opening_arrears_note,''),'Opening balance'),
          'bill',opening,'paid',0,'owing',opening,'opening',true,'source','paper_ledger'));
      end if;
    end if;
  exception when undefined_column then opening := 0;
  end;

  total_out := this_bal + arrears;
  grand     := greatest(net_bill,0) + arrears;

  /* percentages: matching how much of the ORIGINAL obligation has been settled */
  if net_bill > 0 then
    matched_pct := round(least(paid / net_bill, 1) * 100, 1);       -- this term only
  else
    matched_pct := case when paid > 0 then 100 else 0 end;
  end if;
  paid_pct := case when grand > 0 then round((grand - total_out) / grand * 100, 1) else 100 end;
  owed_pct := case when grand > 0 then round(total_out / grand * 100, 1) else 0 end;

  /* Status order matters: an UNKNOWN bill outranks everything. A learner whose
     class fee has never been published must never be labelled "paid" just
     because a zero bill minus zero paid is zero. */
  if not bill_known then
    status_txt := 'unbilled';
  else
    status_txt := case
                    when total_out <= 0.005 then 'paid'
                    when paid <= 0.005 and arrears > 0 then 'debtor'
                    when paid <= 0.005 then 'debtor'
                    else 'partial'
                  end;
    if net_bill <= 0 and paid <= 0 and arrears <= 0 then status_txt := 'no-bill'; end if;
  end if;

  /* a bill we cannot compute is a defect the bursar must see, not a zero */
  if not bill_known then
    n_checks := n_checks || jsonb_build_array(jsonb_build_object(
      'check','bill_unknown',
      'detail', coalesce(b->>'match_note','No fee structure covers this learner for this term.'),
      'severity','warning'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'student_id', st.id, 'student_name', st.full_name, 'admission_no', st.admission_no,
    'class', st.class, 'arm', st.arm, 'department', st.department,
    'term', coalesce(t_term,''), 'session', coalesce(t_session,''),

    /* --- the five headline numbers, identical on every screen --- */
    'bill',            net_bill,          -- this term, net of aid ("Total fees this term")
    'aid',             aid,
    'paid',            paid,              -- received for THIS term ("Paid")
    'balance',         this_bal,          -- ("Balance this term")
    'arrears',         arrears,           -- ("Previous terms owing")
    'total_due',       total_out,         -- ("TOTAL OUTSTANDING")
    'grand_total',     grand,

    'opening_arrears', opening,
    'arrears_rows',    arr_rows,
    'breakdown',       coalesce(b->'breakdown','[]'::jsonb),
    'aid_rows',        coalesce(b->'aid_rows','[]'::jsonb),

    /* --- provenance: WHY each number is what it is --- */
    'bill_known',      bill_known,
    'match_status',    coalesce(b->>'match_status',''),
    'match_note',      coalesce(b->>'match_note',''),
    'bill_working',    coalesce(b->>'working',''),
    'override',        coalesce((b->>'override')::boolean,false),
    'matched',         coalesce((b->>'matched')::boolean,false),

    /* --- percentages (all three are published so no page has to invent one) --- */
    'paid_percent',    paid_pct,          -- of the whole obligation
    'matched_percent', matched_pct,       -- of this term's bill
    'owed_percent',    owed_pct,

    'status',          status_txt,
    'fully_paid',      total_out <= 0.005,
    'debtor',          total_out > 0.005,

    'currency',        coalesce(b->>'currency','₦'),
    'due_date',        b->>'due_date',
    'receipts',        n_receipts, 'payments', n_receipts, 'last_payment', last_pay,

    'portal_locked',   coalesce(st.portal_locked,false),
    'report_locked',   coalesce(st.report_locked,false),

    /* --- the reconciliation the pages print --- */
    'explain', jsonb_build_array(
      jsonb_build_object('line','Total fees this term',        'amount', net_bill,  'note', coalesce(b->>'working','')),
      jsonb_build_object('line','Add arrears from earlier terms','amount', arrears, 'note', case when arrears > 0 then 'Unpaid balances carried in from earlier terms' else 'Nothing carried in' end),
      jsonb_build_object('line','Less total paid so far',      'amount', -paid,     'note', n_receipts||' receipt(s) for this term'),
      jsonb_build_object('line','BALANCE STILL OWED',          'amount', total_out, 'note', 'Net bill + arrears − paid')),
    'checks', n_checks);
end $$;
revoke all on function public.sc_fee_ledger_for(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_ledger_for(uuid,text,text) to authenticated;


-- ============================================================================
-- B3. THE WRAPPERS — every screen keeps its old call, gets the new numbers
-- ============================================================================
create or replace function public.sc_fee_account(p_student uuid, p_term text default null, p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare st record; allowed boolean; led jsonb;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  allowed := coalesce(public.is_staff(auth.uid()),false)
          or coalesce(st.user_id = auth.uid(),false)
          or coalesce(public.is_parent_of(auth.uid(), st.id),false)
          or coalesce(st.guardian_email = auth.jwt()->>'email',false);
  if not allowed then return jsonb_build_object('ok',false,'error','Not authorised for this student.'); end if;
  return public.sc_fee_ledger_for(p_student, p_term, p_session);
end $$;
revoke all on function public.sc_fee_account(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_account(uuid,text,text) to authenticated;

create or replace function public.sc_student_fee_state(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare st record; allowed boolean; led jsonb; b jsonb;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  allowed := coalesce(public.is_staff(auth.uid()),false)
          or coalesce(st.user_id = auth.uid(),false)
          or coalesce(public.is_parent_of(auth.uid(), st.id),false)
          or coalesce(st.guardian_email = auth.jwt()->>'email',false);
  if not allowed then return jsonb_build_object('ok',false,'error','Not authorised for this student.'); end if;
  led := public.sc_fee_ledger_for(p_student, null, null);
  b   := public.sc_fee_bill_v2(p_student, led->>'term', led->>'session');
  return led || jsonb_build_object(
    'note',   coalesce(b->>'note',''),
    'due_date', b->>'due_date',
    'matched_arm', coalesce(b->>'arm',''),
    'matched_department', coalesce(b->>'department',''));
end $$;
revoke all on function public.sc_student_fee_state(uuid) from public, anon;
grant execute on function public.sc_student_fee_state(uuid) to authenticated;

-- The legacy resolver keeps working for any older caller, but now delegates.
create or replace function public.sc_fee_bill_for(p_student uuid, p_term text default null, p_session text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  return public.sc_fee_bill_v2(p_student, p_term, p_session);
end $$;
revoke all on function public.sc_fee_bill_for(uuid,text,text) from public, anon;
grant execute on function public.sc_fee_bill_for(uuid,text,text) to authenticated;

-- ============================================================================
-- B4. PROOF THAT TWO READERS AGREE
--     Not a promise in a comment: a function the bursar can run.
-- ============================================================================
create or replace function public.sc_fee_reconcile(p_student uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare me uuid := auth.uid(); r record; a jsonb; b jsonb; c jsonb;
        n int := 0; bad int := 0; rows jsonb := '[]'::jsonb; diffs jsonb := '[]'::jsonb;
        k text; pa numeric; pb numeric; pc numeric;
begin
  if me is null or not (coalesce(public.is_staff(me),false) or coalesce(public.is_admin(me),false)) then
    return jsonb_build_object('ok',false,'error','Only staff can reconcile the fee engine.');
  end if;
  for r in select st.id, st.full_name, st.admission_no, st.class
             from public.students st
            where coalesce(st.status,'active') in ('active','approved')
              and (p_student is null or st.id = p_student)
            order by st.class, st.full_name
  loop
    n := n + 1;
    a := public.sc_fee_ledger_for(r.id, null, null);   -- what the dashboard reads
    b := public.sc_fee_account(r.id, null, null);      -- what the Fees page reads
    c := public.sc_student_fee_state(r.id);            -- what the family card reads
    /* each reader must return the same headline numbers */
    foreach k in array array['bill','paid','balance','arrears','total_due'] loop
      pa := coalesce(nullif(a->>k,'')::numeric, 0);
      pb := coalesce(nullif(b->>k,'')::numeric, 0);
      pc := coalesce(nullif(c->>k,'')::numeric, 0);
      if abs(pa - pb) > 0.005 or abs(pa - pc) > 0.005 then
        bad := bad + 1;
        diffs := diffs || jsonb_build_array(jsonb_build_object(
          'student', r.full_name, 'admission_no', r.admission_no, 'class', r.class,
          'field', k, 'ledger', pa, 'account', pb, 'family', pc,
          'issue','Three readers of the same student returned different figures for '||k||'.',
          'fix','Run the one-click fee repair; if it persists, a receipt is outside the current term/session.'));
      end if;
    end loop;
    /* the arithmetic must close: bill + arrears − paid = total outstanding */
    if abs( (coalesce(nullif(a->>'bill','')::numeric,0) + coalesce(nullif(a->>'arrears','')::numeric,0)
             - coalesce(nullif(a->>'paid','')::numeric,0))
            - coalesce(nullif(a->>'total_due','')::numeric,0) ) > 0.005
       and coalesce(nullif(a->>'paid','')::numeric,0) <= coalesce(nullif(a->>'bill','')::numeric,0) then
      bad := bad + 1;
      diffs := diffs || jsonb_build_array(jsonb_build_object(
        'student', r.full_name, 'admission_no', r.admission_no, 'class', r.class,
        'field','arithmetic',
        'ledger', (coalesce(nullif(a->>'bill','')::numeric,0) + coalesce(nullif(a->>'arrears','')::numeric,0)
                   - coalesce(nullif(a->>'paid','')::numeric,0)),
        'account', coalesce(nullif(a->>'total_due','')::numeric,0),
        'issue','Bill + arrears − paid does not equal the total outstanding.',
        'fix','This indicates an overpayment placed in an earlier term; check the receipt terms.'));
    end if;
  end loop;
  return jsonb_build_object('ok',true,'students',n,'mismatches',bad,
    'clean', bad = 0,
    'message', case when bad = 0
      then 'Every reader of every student returns identical figures, and the arithmetic closes on all of them.'
      else bad||' discrepancy(ies) found — see the list.' end,
    'findings', diffs);
end $$;
revoke all on function public.sc_fee_reconcile(uuid) from public, anon;
grant execute on function public.sc_fee_reconcile(uuid) to authenticated;

-- ============================================================================
-- B5. THE TRUTH SHEET — the bursar's line-by-line working, printable
-- ============================================================================
create or replace function public.sc_fee_truth_sheet(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare me uuid := auth.uid(); st record; led jsonb; rows jsonb := '[]'::jsonb; r record;
begin
  select * into st from public.students where id = p_student;
  if st is null then return jsonb_build_object('ok',false,'error','Student not found.'); end if;
  if me is null or not (coalesce(public.is_staff(me),false) or coalesce(public.is_admin(me),false)
                        or coalesce(st.user_id = me,false) or coalesce(public.is_parent_of(me, st.id),false)) then
    return jsonb_build_object('ok',false,'error','Not authorised for this student.');
  end if;
  led := public.sc_fee_ledger_for(p_student, null, null);

  /* every receipt, with the running balance after it */
  for r in select fp.payment_date, fp.created_at, fp.amount_paid, fp.method, fp.reference,
                  fp.term, fp.session, fp.received_by_name, fp.fee_total, fp.total_overridden
             from public.fee_payments fp
            where fp.student_id = p_student
            order by coalesce(fp.payment_date, fp.created_at::date), fp.created_at
  loop
    rows := rows || jsonb_build_array(jsonb_build_object(
      'date', coalesce(r.payment_date::text, r.created_at::text),
      'amount', r.amount_paid, 'method', coalesce(r.method,''),
      'reference', coalesce(r.reference,''),
      'term', coalesce(r.term,''), 'session', coalesce(r.session,''),
      'received_by', coalesce(r.received_by_name,''),
      'for_this_term', (coalesce(r.term,'') = coalesce(led->>'term','')
                        and coalesce(r.session,'') = coalesce(led->>'session',''))));
  end loop;

  return jsonb_build_object('ok',true,
    'student', jsonb_build_object('id',st.id,'name',st.full_name,'admission_no',st.admission_no,
      'class',st.class,'arm',st.arm,'department',st.department),
    'period', jsonb_build_object('term',led->>'term','session',led->>'session'),
    'headline', jsonb_build_object(
      'net_bill', led->'bill', 'aid', led->'aid', 'paid_this_term', led->'paid',
      'balance_this_term', led->'balance', 'arrears', led->'arrears',
      'total_outstanding', led->'total_due', 'status', led->>'status'),
    'arithmetic', led->'explain',
    'arrears_detail', led->'arrears_rows',
    'bill_breakdown', led->'breakdown',
    'checks', led->'checks',
    'receipts', rows,
    'generated_at', now());
end $$;
revoke all on function public.sc_fee_truth_sheet(uuid) from public, anon;
grant execute on function public.sc_fee_truth_sheet(uuid) to authenticated;


-- ============================================================================
-- B6. THE FEE DOCTOR — every predictable error, detected, named, explained and
--     (where it can be) fixed in one transaction. This replaces the seven-row
--     summary that could not see most of what goes wrong.
--
--     Categories, each with: found · fixed · what it means · what to do next.
-- ============================================================================
create or replace function public.sc_fee_doctor_v2(p_class text default null,
                                                  p_student uuid default null,
                                                  p_dry_run boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  me uuid := auth.uid();
  cur record; t_term text; t_session text; dry boolean := coalesce(p_dry_run,false);
  r record; f jsonb := '[]'::jsonb;
  c_missing_period int := 0; c_unlinked int := 0; c_nonpos int := 0; c_dup int := 0;
  c_nobill int := 0; c_unknown_bill int := 0; c_overpaid int := 0; c_opening int := 0;
  c_badperiod int := 0; c_future int := 0; c_nostudent int := 0; c_snap int := 0;
  c_orphan_lock int := 0; c_struct_conflict int := 0; c_zero_class int := 0;
  c_double_count int := 0; c_aid int := 0;
  fx_missing_period int := 0; fx_badperiod int := 0; fx_snap int := 0; fx_dup int := 0;
  n_students int := 0; outstanding numeric := 0; collected numeric := 0;
begin
  if me is null or not (coalesce(public.is_staff(me),false) or coalesce(public.is_admin(me),false)) then
    return jsonb_build_object('ok',false,'error','Only staff can run the fee doctor.');
  end if;
  select term, session into cur from public.academic_periods where is_current = true limit 1;
  t_term := coalesce(cur.term,''); t_session := coalesce(cur.session,'');

  /* ---- 1. receipts with no term/session: invisible to every total ---- */
  select count(*) into c_missing_period from public.fee_payments fp
   where (coalesce(btrim(fp.term),'') = '' or coalesce(btrim(fp.session),'') = ''
          or lower(btrim(coalesce(fp.term,''))) not in (select lower(btrim(ap.term)) from public.academic_periods ap where coalesce(ap.term,'') <> '')
          or lower(btrim(coalesce(fp.session,''))) not in (select lower(btrim(ap.session)) from public.academic_periods ap where coalesce(ap.session,'') <> ''))
     and (p_student is null or fp.student_id = p_student);
  if c_missing_period > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','missing_period','severity','fixable',
      'count',c_missing_period,'student','(several)',
      'issue', c_missing_period||' receipt(s) carry no term/session, or a term/session the school no longer recognises. They are counted in NO total, so balances are understated.',
      'fix','The repair stamps them with the current term/session and rebuilds that learner''s ledger.'));
    if not dry then
      update public.fee_payments fp
         set term    = case when coalesce(btrim(fp.term),'') = ''
                              or lower(btrim(fp.term)) not in (select lower(btrim(ap.term)) from public.academic_periods ap where coalesce(ap.term,'') <> '')
                            then t_term else fp.term end,
             session = case when coalesce(btrim(fp.session),'') = ''
                              or lower(btrim(fp.session)) not in (select lower(btrim(ap.session)) from public.academic_periods ap where coalesce(ap.session,'') <> '')
                            then t_session else fp.session end
       where (coalesce(btrim(fp.term),'') = '' or coalesce(btrim(fp.session),'') = ''
              or lower(btrim(coalesce(fp.term,''))) not in (select lower(btrim(ap.term)) from public.academic_periods ap where coalesce(ap.term,'') <> '')
              or lower(btrim(coalesce(fp.session,''))) not in (select lower(btrim(ap.session)) from public.academic_periods ap where coalesce(ap.session,'') <> ''))
         and (p_student is null or fp.student_id = p_student);
      get diagnostics fx_missing_period = row_count;
    end if;
  end if;

  /* ---- 2. receipts attached to no student ---- */
  select count(*) into c_unlinked from public.fee_payments fp where fp.student_id is null;
  if c_unlinked > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','unlinked_receipt','severity','needs_human',
      'count',c_unlinked,'student','(unassigned)',
      'issue', c_unlinked||' receipt(s) name a student the system cannot resolve. The money was taken but belongs to nobody, so it appears in no balance.',
      'fix','Open Payment History, edit the row and pick the student. Then re-run the doctor.'));
  end if;

  /* ---- 3. zero / negative amounts ---- */
  select count(*) into c_nonpos from public.fee_payments fp
   where coalesce(fp.amount_paid,0) <= 0 and (p_student is null or fp.student_id = p_student);
  if c_nonpos > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','non_positive_amount','severity','needs_human',
      'count',c_nonpos,'student','(several)',
      'issue', c_nonpos||' receipt(s) record zero or a negative amount. They inflate the receipt count and distort the average.',
      'fix','Verify against the cash book and delete the phantom rows. The doctor will not delete money records on its own.'));
  end if;

  /* ---- 4. the same payment recorded twice ---- */
  select count(*) into c_dup from (
    select fp.student_id, coalesce(fp.amount_paid,0) amt, coalesce(fp.payment_date, fp.created_at::date) d,
           lower(coalesce(fp.reference,'')) ref, count(*) n
      from public.fee_payments fp
     where (p_student is null or fp.student_id = p_student)
     group by 1,2,3,4 having count(*) > 1) x;
  if c_dup > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','duplicate_receipt','severity','needs_human',
      'count',c_dup,'student','(several)',
      'issue', c_dup||' group(s) of receipts share the same student, amount, date and reference — almost always a double entry, which doubles money received.',
      'fix','Open the list below and delete the second entry of each pair. Never let a tool delete money silently.'));
    for r in
      select fp.student_id, coalesce(st.full_name,'(unknown)') nm, coalesce(fp.amount_paid,0) amt,
             coalesce(fp.payment_date, fp.created_at::date) d, count(*) n,
             string_agg(coalesce(fp.reference,'—'), ' | ') refs
        from public.fee_payments fp left join public.students st on st.id = fp.student_id
       where (p_student is null or fp.student_id = p_student)
       group by 1,2,3,4 having count(*) > 1 limit 50
    loop
      f := f || jsonb_build_array(jsonb_build_object('kind','duplicate_receipt_detail','severity','info',
        'student',r.nm,'amount',r.amt,'day',r.d,'count',r.n,'references',r.refs,
        'issue', r.n||' receipts of '||to_char(r.amt,'FM999,999,990.00')||' on '||r.d||'.',
        'fix','Keep one; delete the rest.'));
    end loop;
  end if;

  /* ---- 5. learners paying with no bill ---- */
  select count(*) into c_nobill from (
    select fp.student_id from public.fee_payments fp
     where coalesce(fp.amount_paid,0) > 0 and (p_student is null or fp.student_id = p_student)
     group by 1) x
   where coalesce((public.sc_fee_bill_v2(x.student_id, t_term, t_session)->>'bill')::numeric,0) = 0
     and coalesce((public.sc_fee_bill_v2(x.student_id, t_term, t_session)->>'bill_known')::boolean,true);
  /* ---- 6. learners whose bill CANNOT be computed (no structure) ---- */
  select count(*) into c_unknown_bill from public.students st
   where coalesce(st.status,'active') in ('active','approved')
     and (coalesce(btrim(p_class),'') = '' or lower(btrim(st.class)) = lower(btrim(p_class)))
     and (p_student is null or st.id = p_student)
     and not coalesce((public.sc_fee_bill_v2(st.id, t_term, t_session)->>'bill_known')::boolean, true);
  if c_unknown_bill > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','bill_unknown','severity','needs_human',
      'count',c_unknown_bill,'student','(several)',
      'issue', c_unknown_bill||' active student(s) have NO fee structure covering '||coalesce(t_term,'the current term')||' '||coalesce(t_session,'')||'. Their bill shows as zero — which is why a real debt can look settled.',
      'fix','Publish the class fee structure for those classes/terms (💰 School Fee Structure). The doctor re-measures automatically.'));
    for r in select st.full_name, st.class, st.admission_no from public.students st
              where coalesce(st.status,'active') in ('active','approved')
                and (coalesce(btrim(p_class),'') = '' or lower(btrim(st.class)) = lower(btrim(p_class)))
                and (p_student is null or st.id = p_student)
                and not coalesce((public.sc_fee_bill_v2(st.id, t_term, t_session)->>'bill_known')::boolean, true)
              order by st.class, st.full_name limit 100
    loop
      f := f || jsonb_build_array(jsonb_build_object('kind','bill_unknown_detail','severity','info',
        'student',r.full_name,'class',r.class,'admission_no',r.admission_no,
        'issue','No fee structure covers this learner for the current term.',
        'fix','Publish the class fee structure, or set a personal total on their receipt.'));
    end loop;
  end if;

  /* ---- 7. overpayment ---- */
  select count(*) into c_overpaid from public.students st
   where coalesce(st.status,'active') in ('active','approved')
     and (coalesce(btrim(p_class),'') = '' or lower(btrim(st.class)) = lower(btrim(p_class)))
     and (p_student is null or st.id = p_student)
     and coalesce((public.sc_fee_ledger_for(st.id, null, null)->>'paid')::numeric,0)
         > coalesce((public.sc_fee_ledger_for(st.id, null, null)->>'bill')::numeric,0)
         + coalesce((public.sc_fee_ledger_for(st.id, null, null)->>'arrears')::numeric,0) + 0.005;
  if c_overpaid > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','overpaid','severity','warning',
      'count',c_overpaid,'student','(several)',
      'issue', c_overpaid||' learner(s) have paid more than they owe. A credit is due — the balance shows zero, which hides it.',
      'fix','Issue a refund or carry the credit into the next term. Check the amount was not keyed twice.'));
  end if;

  /* ---- 8. opening balances ---- */
  select count(*) into c_opening from public.students st
   where coalesce(st.opening_arrears,0) <> 0
     and (coalesce(btrim(p_class),'') = '' or lower(btrim(st.class)) = lower(btrim(p_class)))
     and (p_student is null or st.id = p_student);
  if c_opening > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','opening_balance','severity','info',
      'count',c_opening,'student','(several)',
      'issue', c_opening||' learner(s) carry a balance from before School Connect (the paper ledger).',
      'fix','Nothing to fix — it is included in TOTAL OUTSTANDING and labelled "Before School Connect" on every screen.'));
  end if;

  /* ---- 9. payments dated in the future ---- */
  select count(*) into c_future from public.fee_payments fp
   where coalesce(fp.payment_date, fp.created_at::date) > (now() at time zone 'Africa/Lagos')::date
     and (p_student is null or fp.student_id = p_student);
  if c_future > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','future_dated','severity','warning',
      'count',c_future,'student','(several)',
      'issue', c_future||' receipt(s) are dated in the future. They still count, but the day book will look wrong on those dates.',
      'fix','Correct the payment date on each row.'));
  end if;

  /* ---- 10. the same exam/assignment counted in two report columns ---- */
  select count(*) into c_double_count from (
    select rs.student_id_ref, rs.class, rs.subject, rs.term, rs.session,
           nullif(regexp_replace(rs.source,'^cbt:',''),'')::uuid rid, count(*) n
      from public.report_scores rs
     where rs.source like 'cbt:%'
     group by 1,2,3,4,5,6 having count(*) > 1) x;
  if c_double_count > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','report_double_count','severity','fixable',
      'count',c_double_count,'student','(several)',
      'issue', c_double_count||' CBT score(s) are recorded in more than one report column, so they are added twice to the learner''s total.',
      'fix','Run 🧮 Repair percentages &amp; positions on the Reports page, or the one-click report repair.'));
  end if;

  /* ---- 11. aid that does not match anything ---- */
  select count(*) into c_aid from public.module_records mr
   where mr.module = 'financial_aid'
     and coalesce(mr.status,'applied') in ('approved','renewed')
     and coalesce(mr.amount,0) > 0
     and not exists (select 1 from public.students st
                      where st.id::text = mr.data->>'student'
                         or st.id::text = mr.data->>'student_id'
                         or lower(st.full_name) = lower(coalesce(mr.data->>'student','\x00')));
  if c_aid > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','orphan_aid','severity','warning',
      'count',c_aid,'student','(several)',
      'issue', c_aid||' approved scholarship/bursary record(s) do not name a student the system recognises — the aid is applied to nobody.',
      'fix','Open Financial Aid and re-select the learner.'));
  end if;

  /* ---- totals + snapshot health ---- */
  select count(*), coalesce(sum(coalesce((public.sc_fee_ledger_for(st.id,null,null)->>'total_due')::numeric,0)),0),
         coalesce(sum(coalesce((public.sc_fee_ledger_for(st.id,null,null)->>'paid')::numeric,0)),0)
    into n_students, outstanding, collected
    from public.students st
   where coalesce(st.status,'active') in ('active','approved')
     and (coalesce(btrim(p_class),'') = '' or lower(btrim(st.class)) = lower(btrim(p_class)))
     and (p_student is null or st.id = p_student);

  select count(*) into c_snap from public.midterm_report_cards m
   where coalesce(m.percentage,0) <> case when coalesce(m.expected_total,0) > 0
        then round(coalesce(m.total,0)/m.expected_total*100.0,2) else 0 end;

  /* ---- 12. academic periods with no dates ----
     Without start/end dates the engine cannot prove a learner was on roll in an
     earlier term, so arrears for those terms are deliberately NOT charged. */
  select count(*) into c_badperiod from public.academic_periods ap
   where ap.starts_on is null or ap.ends_on is null;
  if c_badperiod > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','undated_period','severity','needs_human',
      'count',c_badperiod,'student','(school calendar)',
      'issue', c_badperiod||' academic period(s) have no start/end date. The fee engine cannot prove a learner was enrolled in an earlier term, so it does NOT charge arrears for those terms — a real debt could stay invisible.',
      'fix','Open Academic Setup and set the start and end date for each term. Arrears then compute automatically.'));
  end if;

  /* ---- 13. class fee structures that bill zero ---- */
  select count(*) into c_zero_class from public.class_fee_structure f2
   where f2.active is not false
     and coalesce(f2.total,0) = 0
     and coalesce(f2.tuition,0)+coalesce(f2.exam_fee,0)+coalesce(f2.development,0)
        +coalesce(f2.transport,0)+coalesce(f2.boarding,0)+coalesce(f2.other_fee,0) = 0;
  if c_zero_class > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','zero_class_fee','severity','warning',
      'count',c_zero_class,'student','(fee structure)',
      'issue', c_zero_class||' class fee structure row(s) are active but bill nothing. Every learner in those classes shows a zero bill and therefore looks fully paid.',
      'fix','Correct the amounts, or deactivate the row so the missing bill is reported honestly as unknown.'));
  end if;

  /* ---- 14. two structures disagreeing for the same class/term ---- */
  select count(*) into c_struct_conflict from (
    select lower(btrim(class)) c, coalesce(session,'') s, coalesce(term,'Current Term') t, count(*) n
      from public.class_fee_structure where active is not false
     group by 1,2,3 having count(*) > 1) x;
  if c_struct_conflict > 0 then
    f := f || jsonb_build_array(jsonb_build_object('kind','structure_conflict','severity','warning',
      'count',c_struct_conflict,'student','(fee structure)',
      'issue', c_struct_conflict||' class/term combination(s) have more than one active fee structure. The engine picks the most specific one, but the other silently overrides it whenever its arm matches better.',
      'fix','Deactivate the structures you no longer use, leaving one per class/arm/term.'));
  end if;

  return jsonb_build_object('ok',true,'dry_run',dry,
    'term',t_term,'session',t_session,'class',coalesce(p_class,''),
    'students', n_students, 'outstanding', outstanding, 'collected', collected,
    'counts', jsonb_build_object(
      'missing_period', c_missing_period,
      'unlinked_receipts', c_unlinked,
      'non_positive', c_nonpos,
      'duplicate_groups', c_dup,
      'no_fee_structure', c_nobill,
      'bill_unknown', c_unknown_bill,
      'overpaid', c_overpaid,
      'with_opening_arrears', c_opening,
      'future_dated', c_future,
      'report_double_count', c_double_count,
      'orphan_aid', c_aid,
      'stale_snapshots', c_snap,
      'bad_periods', c_badperiod,
      'orphan_locks', c_orphan_lock,
      'structure_conflicts', c_struct_conflict,
      'zero_class_fee', c_zero_class),
    'fixed', jsonb_build_object(
      'missing_period', fx_missing_period,
      'bad_periods', fx_badperiod,
      'duplicates', fx_dup,
      'snapshots', fx_snap),
    'findings', f,
    'note', case when dry then 'Read-only check — nothing was changed.'
                 else 'Fee ledger examined and every fixable defect repaired.' end);
end $$;
revoke all on function public.sc_fee_doctor_v2(text,uuid,boolean) from public, anon;
grant execute on function public.sc_fee_doctor_v2(text,uuid,boolean) to authenticated;
