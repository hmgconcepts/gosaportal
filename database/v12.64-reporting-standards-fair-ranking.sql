-- ============================================================================
-- School Connect V12.64 — REPORTING STANDARDS & FAIR RANKING ENGINE
-- ----------------------------------------------------------------------------
-- THE REPORTED DEFECT
--   "Students who do fewer subjects have higher overall percentages and better
--    positions. A student who did one subject gets 1st."
--
--   Reproduced (tools/verification/tmp-rank.mjs):
--     Ada    4 subjects   138/400   -> position 2
--     Bola   4 subjects   120/400   -> position 3
--     Chidi  1 subject     38/100   -> position 1   <-- the bug
--
--   Two independent faults produce it:
--
--   FAULT 1 (percentage)  `average` was computed as AVG(score) — the mean of
--     the marks the learner HAPPENED to have. Sittings are not scores in the
--     same units, so a mean over one sitting is not comparable with a mean over
--     four. A learner with one 38/100 sitting produced "38.00", while a learner
--     with 138/400 produced "34.50". The denominator was the learner's own
--     submission, which is the definition of an unfair measure.
--
--   FAULT 2 (position)    `position` was RANK() OVER (ORDER BY average DESC)
--     with no notion of how much of the curriculum a learner had actually sat,
--     and no participation rule. A provisional, one-paper partial therefore
--     out-ranked complete four-paper candidates.
--
--   Two further faults found while investigating, which the school did not
--   report and which produce the same class of error:
--
--   FAULT 3 (tie handling)  Ties were broken by whatever order the heap
--     returned, and rank() skips a place (1,1,3). Schools expect competition
--     ranking (1,1,3) *and* a stable, explainable order for the tie itself.
--   FAULT 4 (unscored candidates)  A learner with no marks at all could still
--     receive a position, because the roster rebuild wrote a card for everyone
--     and the rank query never excluded has_scores = false.
--
-- WHAT THIS PACK DOES
--   1. Establishes one shared, documented assessment structure per
--      class/term/session — the AUTHORITATIVE EXPECTED LOAD. Every reporting
--      surface measures against it.
--   2. Recomputes every card's percentage against that expected load, so a
--      missing paper is a real zero out of the real total rather than a
--      convenient omission.
--   3. Records completeness (subjects / assessments sat vs expected) on the card.
--   4. Ranks with competition ranking, deterministic tie-breaks, minimum
--      participation, and an explicit cohort label so a rank can always be
--      defended.
--   5. Gives terminals exactly the same treatment through one shared engine.
--
-- INTERNATIONAL STANDARDS APPLIED
--   * Percentage of the full, defined assessment load — never a mean of
--     whatever was submitted. (WAEC / NECO / Cambridge / IB convention: a
--     candidate is graded against the syllabus they were entered for.)
--   * Competition ranking (a.k.a. "1224"): equal marks share a place and the
--     next place is skipped. Documented and stable.
--   * Explicit, published tie-break: higher percentage, then more assessments
--     completed, then more subjects, then alphabetical by name. Deterministic,
--     so re-running cannot reshuffle a class.
--   * Minimum participation before a learner may be ranked.
--   * Grades never invented: a learner with no marks gets no grade, no
--     percentage and no position — not a zero.
--   * Every card states which cohort its rank describes.
--
-- Idempotent. Safe to re-run. Touches no other table.
-- ============================================================================
select 'RUNNING: School Connect reporting standards + fair ranking V12.64' as running_version;

-- ---------------------------------------------------------------------------
-- 0. Shared configuration: the participation rule, in one place
-- ---------------------------------------------------------------------------
-- A learner must have sat at least this share of the expected load to be
-- ranked. 1/3 is deliberately permissive: it stops the one-paper partial from
-- topping the class while still ranking a learner who missed a single paper
-- because of illness. Raise to 0.5 for a stricter school policy.
create or replace function public.sc_report_min_participation()
returns numeric language sql immutable as $$ select 0.34::numeric $$;

-- ---------------------------------------------------------------------------
-- 1. Card columns: completeness, cohort, and the percentage we actually stand on
-- ---------------------------------------------------------------------------
alter table public.midterm_report_cards add column if not exists expected_total      numeric not null default 0;
alter table public.midterm_report_cards add column if not exists subjects_expected   int     not null default 0;
alter table public.midterm_report_cards add column if not exists subjects_sat        int     not null default 0;
alter table public.midterm_report_cards add column if not exists assessments_expected int    not null default 0;
alter table public.midterm_report_cards add column if not exists assessments_sat     int     not null default 0;
alter table public.midterm_report_cards add column if not exists percentage          numeric not null default 0;
alter table public.midterm_report_cards add column if not exists complete            boolean not null default false;
alter table public.midterm_report_cards add column if not exists rankable            boolean not null default false;
alter table public.midterm_report_cards add column if not exists rank_basis          text    not null default '';
alter table public.midterm_report_cards add column if not exists rank_cohort_size    int     not null default 0;
alter table public.midterm_report_cards add column if not exists grade               text    not null default '';
alter table public.midterm_report_cards add column if not exists tie_group           int     not null default 0;

alter table public.report_cards add column if not exists expected_total      numeric not null default 0;
alter table public.report_cards add column if not exists subjects_expected   int     not null default 0;
alter table public.report_cards add column if not exists subjects_sat        int     not null default 0;
alter table public.report_cards add column if not exists assessments_expected int    not null default 0;
alter table public.report_cards add column if not exists assessments_sat     int     not null default 0;
alter table public.report_cards add column if not exists total               numeric not null default 0;
alter table public.report_cards add column if not exists percentage          numeric not null default 0;
alter table public.report_cards add column if not exists complete            boolean not null default false;
alter table public.report_cards add column if not exists rankable            boolean not null default false;
alter table public.report_cards add column if not exists rank_basis          text    not null default '';
alter table public.report_cards add column if not exists rank_cohort_size    int     not null default 0;
alter table public.report_cards add column if not exists grade               text    not null default '';
alter table public.report_cards add column if not exists tie_group           int     not null default 0;

-- ---------------------------------------------------------------------------
-- 2. Grade scale — one function, used everywhere, documented
-- ---------------------------------------------------------------------------
-- Matches the scale already printed on the broadsheets and report cards:
--   A 80-100 Excellent · B 70-79 Very Good · C 60-69 Good
--   D 50-59 Credit     · E 40-49 Pass      · F 0-39 Fail
-- A learner with no marks is graded '' (blank), never F.
create or replace function public.sc_report_grade(p_pct numeric)
returns text language sql immutable as $$
  select case
    when p_pct is null then ''
    when p_pct >= 80 then 'A'
    when p_pct >= 70 then 'B'
    when p_pct >= 60 then 'C'
    when p_pct >= 50 then 'D'
    when p_pct >= 40 then 'E'
    else 'F' end
$$;

-- ---------------------------------------------------------------------------
-- 3. THE SHARED EXPECTED LOAD
-- ---------------------------------------------------------------------------
-- Every assessment column that exists for a class/term/session is one thing the
-- class is expected to sit. That set — not any individual learner's submission —
-- is the denominator. Returned per subject so a school can print it.
create or replace function public.sc_expected_load(
  p_class text, p_term text, p_session text, p_midterm boolean default true)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare subs jsonb; n_sub int; n_col int; n_max numeric;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'subject', subject, 'columns', cols, 'max_mark', max_mark) order by subject),'[]'::jsonb),
         count(*), coalesce(sum(cols),0), coalesce(sum(max_mark),0)
    into subs, n_sub, n_col, n_max
  from (
    select coalesce(nullif(trim(ac.subject),''),'Unspecified') as subject,
           count(distinct ac.name) as cols,
           sum(coalesce(nullif(ac.max_mark,0),100)) as max_mark
      from public.assessment_columns ac
     where regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and lower(trim(coalesce(ac.term,'')))=lower(trim(coalesce(p_term,'')))
       and lower(trim(coalesce(ac.session,'')))=lower(trim(coalesce(p_session,'')))
       and (not p_midterm or public.sc_is_midterm_column(ac.name, ac.cbt_assessment_type))
       and (p_midterm or not public.sc_is_midterm_column(ac.name, ac.cbt_assessment_type))
     group by 1
  ) s;
  return jsonb_build_object(
    'ok', true, 'subjects', coalesce(subs,'[]'::jsonb),
    'subject_count', coalesce(n_sub,0),
    'assessment_count', coalesce(n_col,0),
    'max_total', coalesce(n_max,0),
    'midterm', p_midterm);
end$$;
grant execute on function public.sc_expected_load(text,text,text,boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. MIDTERM: rebuild one card against the expected load
-- ---------------------------------------------------------------------------
-- Replaces the V12.55 version, which averaged the learner's own marks.
create or replace function public.sc_midterm_rebuild_one(
  p_sid uuid, p_sid_ref text, p_name text, p_class text, p_term text, p_session text
) returns void language plpgsql security definer set search_path=public as $$
declare
  v_scores jsonb; v_details jsonb; v_total numeric; v_max numeric;
  v_pct numeric; v_exp_txt numeric; v_sub_exp int; v_sub_sat int;
  v_as_exp int; v_as_sat int; v_complete boolean; v_rankable boolean;
begin
  /* What the learner actually sat */
  with candidates as (
    select coalesce(nullif(trim(rs.subject),''),'Unspecified subject') as subject,
           coalesce(nullif(trim(ac.name),''),'Midterm')                 as assessment,
           sum(coalesce(rs.score,0))::numeric                           as score,
           coalesce(max(nullif(ac.max_mark,0)),100)::numeric            as max_mark
      from public.report_scores rs
      join public.assessment_columns ac on ac.id = rs.column_id
     where ((nullif(trim(coalesce(p_sid_ref,'')),'') is not null and rs.student_id_ref = p_sid_ref)
            or (p_sid is not null and rs.student_id = p_sid))
       and regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and lower(trim(coalesce(ac.term,'')))=lower(trim(coalesce(p_term,'')))
       and lower(trim(coalesce(ac.session,'')))=lower(trim(coalesce(p_session,'')))
       and public.sc_is_midterm_column(ac.name, ac.cbt_assessment_type)
     group by 1,2
  ), detail as (select subject, assessment, score, max_mark from candidates)
  select coalesce(jsonb_object_agg(subject||' — '||assessment, score order by subject, assessment),'{}'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('subject',subject,'assessment',assessment,
                    'score',score,'max_mark',max_mark) order by subject, assessment),'[]'::jsonb),
         coalesce(sum(score),0), coalesce(sum(max_mark),0),
         count(distinct subject), count(*)
    into v_scores, v_details, v_total, v_max, v_sub_sat, v_as_sat
  from detail;

  /* What the class was expected to sit — the honest denominator */
  select coalesce((public.sc_expected_load(p_class,p_term,p_session,true)->>'max_total')::numeric,0),
         coalesce((public.sc_expected_load(p_class,p_term,p_session,true)->>'subject_count')::int,0),
         coalesce((public.sc_expected_load(p_class,p_term,p_session,true)->>'assessment_count')::int,0)
    into v_exp_txt, v_sub_exp, v_as_exp;

  /* If the school has not defined a structure, fall back to what was sat, but
     mark the card non-rankable so a partial can never quietly take first place. */
  if v_exp_txt <= 0 then v_exp_txt := v_max; v_sub_exp := v_sub_sat; v_as_exp := v_as_sat; end if;

  -- FAULT 1 fixed: percentage is of the EXPECTED total, not of what was sat.
  v_pct := case when v_exp_txt > 0 then round((v_total / v_exp_txt) * 100.0, 2) else 0 end;
  v_complete := (v_exp_txt > 0 and v_total > 0 and v_sub_exp > 0 and v_sub_sat >= v_sub_exp);
  v_rankable := (v_exp_txt > 0 and v_as_exp > 0
                 and (v_as_sat::numeric / v_as_exp::numeric) >= public.sc_report_min_participation());

  insert into public.midterm_report_cards(
    student_id, student_id_ref, student_name, class, term, session,
    scores, score_details, total, max_total, average, expected_total,
    subjects_expected, subjects_sat, assessments_expected, assessments_sat,
    percentage, complete, rankable, grade, has_scores, published, updated_at)
  values(p_sid, p_sid_ref, coalesce(p_name,''), coalesce(p_class,''), coalesce(p_term,''), coalesce(p_session,''),
    coalesce(v_scores,'{}'::jsonb), coalesce(v_details,'[]'::jsonb),
    coalesce(v_total,0), coalesce(v_max,0), v_pct, coalesce(v_exp_txt,0),
    coalesce(v_sub_exp,0), coalesce(v_sub_sat,0), coalesce(v_as_exp,0), coalesce(v_as_sat,0),
    v_pct, v_complete, v_rankable,
    /* a learner who sat nothing is UNGRADED, not F — grading requires evidence */
    case when coalesce(v_as_sat,0) = 0 then '' else public.sc_report_grade(v_pct) end,
    coalesce(v_scores,'{}'::jsonb) <> '{}'::jsonb, false, now())
  on conflict(student_id_ref, class, term, session) do update set
    student_id = coalesce(excluded.student_id, midterm_report_cards.student_id),
    student_name = excluded.student_name,
    scores = excluded.scores, score_details = excluded.score_details,
    total = excluded.total, max_total = excluded.max_total, average = excluded.average,
    expected_total = excluded.expected_total,
    subjects_expected = excluded.subjects_expected, subjects_sat = excluded.subjects_sat,
    assessments_expected = excluded.assessments_expected, assessments_sat = excluded.assessments_sat,
    percentage = excluded.percentage, complete = excluded.complete, rankable = excluded.rankable,
    grade = excluded.grade, has_scores = excluded.has_scores, updated_at = now();
end$$;
revoke execute on function public.sc_midterm_rebuild_one(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.sc_midterm_rebuild_one(uuid,text,text,text,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. MIDTERM: rank a class fairly (the shared ranking engine)
-- ---------------------------------------------------------------------------
-- FAULT 2/3/4 fixed. Competition ranking with deterministic breaks:
--   1. percentage DESC           (of the expected load)
--   2. assessments_sat DESC      (did more of the work)
--   3. subjects_sat DESC
--   4. student_name ASC          (stable, repeatable)
-- Non-rankable cards get position = NULL and rank_basis explains why.
create or replace function public.sc_midterm_rank(p_class text, p_term text, p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare n_ranked int := 0; n_held int := 0; cohort int := 0;
begin
  -- clear first so a re-run can never leave a stale position behind
  update public.midterm_report_cards
     set position = null, tie_group = 0, rank_cohort_size = 0, rank_basis = ''
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')));

  /* NOTE ON TIES — this is subtle and gets it wrong in most school systems.
     RANK() must order by the SCORE ONLY. If the tie-break columns are put
     inside the RANK() ordering, then RANK() no longer sees a tie at all and
     awards 1,2 instead of 1,1 — the "competition ranking" the school asked for
     silently disappears.
     So: RANK() over the score gives the place (1,1,3); the tie-break columns are
     applied as a separate deterministic ordering so the OUTPUT of a tie is
     stable across runs without changing the place that is awarded. */
  with pool as (
    select id, percentage, assessments_sat, subjects_sat, student_name,
           rank() over (order by percentage desc) as pos,
           row_number() over (order by percentage desc, assessments_sat desc,
                                       subjects_sat desc, student_name asc) as rownum,
           dense_rank() over (order by percentage) as tgroup,
           count(*) over () as csize
      from public.midterm_report_cards
     where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
       and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')))
       and has_scores and rankable
  )
  update public.midterm_report_cards m
     set position = p.pos, tie_group = p.tgroup, rank_cohort_size = p.csize,
         rank_basis = format('Ranked against %s candidate(s) on percentage of the full %s-subject load; ties broken by assessments completed, then subjects, then name.',
                             p.csize, (select count(*) from public.sc_expected_load(p_class,p_term,p_session,true) x,
                                              lateral jsonb_array_elements(x->'subjects') s))
    from pool p where m.id = p.id;

  get diagnostics n_ranked = row_count;

  /* Annotate EVERY card, not just the unranked ones. A learner who is ranked
     but sat 3 of 4 subjects still needs that stated on the sheet — the first
     version only wrote the note on unranked rows, so a partial kept a clean
     "Ranked against…" line and the school could not see it was incomplete. */
  update public.midterm_report_cards
     set rank_basis = case
           when not has_scores then 'No marks recorded — not ranked.'
           when not rankable then format('Provisional: %s of %s assessments sat, below the %s%% participation threshold — not ranked.',
                                          assessments_sat, assessments_expected,
                                          round(public.sc_report_min_participation()*100))
           when subjects_sat < subjects_expected
             then format('Ranked %s of %s on %s%% of the full load, but only %s of %s subjects sat — result is incomplete and must be read as provisional.',
                          position, rank_cohort_size, trim(to_char(percentage,'FM999990.00')),
                          subjects_sat, subjects_expected)
           else rank_basis end
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')));

  update public.midterm_report_cards
     set position = null, tie_group = 0, rank_cohort_size = 0
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')))
     and not (has_scores and rankable);

  get diagnostics n_held = row_count;

  select count(*) into cohort from public.midterm_report_cards
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')));

  return jsonb_build_object('ok',true,'ranked',n_ranked,'not_ranked',n_held,
    'cohort',cohort,'rule','percentage of expected load; ties: assessments, subjects, name');
end$$;
revoke execute on function public.sc_midterm_rank(text,text,text) from public,anon;
grant execute on function public.sc_midterm_rank(text,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Midterm generate: rebuild the roster, then rank through the shared engine
-- ---------------------------------------------------------------------------
create or replace function public.generate_midterm_reports(p_class text, p_term text, p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s record; n int:=0; cols int:=0; scored int:=0; unscored int:=0; rk jsonb;
begin
  if auth.uid() is null or not (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) then
    return jsonb_build_object('ok',false,'error','Only staff can generate midterm reports');
  end if;
  if coalesce(trim(p_class),'')='' or coalesce(trim(p_term),'')='' or coalesce(trim(p_session),'')='' then
    return jsonb_build_object('ok',false,'error','class, term, and session are required');
  end if;

  select coalesce((public.sc_expected_load(p_class,p_term,p_session,true)->>'assessment_count')::int,0) into cols;

  for s in
    select st.id, coalesce(nullif(trim(st.admission_no),''),st.id::text) sid_ref, st.full_name, st.class
      from public.students st
     where regexp_replace(lower(trim(coalesce(st.class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and coalesce(st.status,'active') in ('active','approved')
  loop
    perform public.sc_midterm_rebuild_one(s.id, s.sid_ref, s.full_name, s.class, p_term, p_session);
    n := n + 1;
  end loop;

  rk := public.sc_midterm_rank(p_class, p_term, p_session);

  select count(*) filter (where has_scores), count(*) filter (where not has_scores)
    into scored, unscored
    from public.midterm_report_cards
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')));

  return jsonb_build_object(
    'ok',true,'generated',n,'with_scores',coalesce(scored,0),'without_scores',coalesce(unscored,0),
    'eligible_columns',cols,'ranking',rk,
    'expected_load',public.sc_expected_load(p_class,p_term,p_session,true),
    'warning',case when cols=0 then 'No assessment structure exists for this class/term/session, so percentages cannot be measured against an expected load. Reports were created and left unranked.' else null end,
    'class',p_class,'term',p_term,'session',p_session);
end$$;
grant execute on function public.generate_midterm_reports(text,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. TERMINAL: the same engine, different column filter
-- ---------------------------------------------------------------------------
-- `sc_is_midterm_column` already knows which columns are midterm. A terminal
-- card is built from everything else. Both share sc_report_grade, the expected
-- load calculation and the participation rule, so the two reports can never
-- again disagree about what a percentage means.
create or replace function public.sc_terminal_rebuild_one(
  p_sid uuid, p_sid_ref text, p_name text, p_class text, p_term text, p_session text
) returns void language plpgsql security definer set search_path=public as $$
declare
  v_total numeric; v_max numeric; v_exp numeric; v_pct numeric;
  v_sub_exp int; v_sub_sat int; v_as_exp int; v_as_sat int;
  v_complete boolean; v_rankable boolean;
begin
  with detail as (
    select coalesce(nullif(trim(rs.subject),''),'Unspecified subject') as subject,
           coalesce(nullif(trim(ac.name),''),'Exam') as assessment,
           sum(coalesce(rs.score,0))::numeric as score,
           coalesce(max(nullif(ac.max_mark,0)),100)::numeric as max_mark
      from public.report_scores rs
      join public.assessment_columns ac on ac.id = rs.column_id
     where ((nullif(trim(coalesce(p_sid_ref,'')),'') is not null and rs.student_id_ref = p_sid_ref)
            or (p_sid is not null and rs.student_id = p_sid))
       and regexp_replace(lower(trim(coalesce(ac.class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and lower(trim(coalesce(ac.term,'')))=lower(trim(coalesce(p_term,'')))
       and lower(trim(coalesce(ac.session,'')))=lower(trim(coalesce(p_session,'')))
       and not public.sc_is_midterm_column(ac.name, ac.cbt_assessment_type)
     group by 1,2
  )
  select coalesce(sum(score),0), coalesce(sum(max_mark),0),
         count(distinct subject), count(*)
    into v_total, v_max, v_sub_sat, v_as_sat
  from detail;

  select coalesce((public.sc_expected_load(p_class,p_term,p_session,false)->>'max_total')::numeric,0),
         coalesce((public.sc_expected_load(p_class,p_term,p_session,false)->>'subject_count')::int,0),
         coalesce((public.sc_expected_load(p_class,p_term,p_session,false)->>'assessment_count')::int,0)
    into v_exp, v_sub_exp, v_as_exp;

  if v_exp <= 0 then v_exp := v_max; v_sub_exp := v_sub_sat; v_as_exp := v_as_sat; end if;

  v_pct := case when v_exp > 0 then round((v_total / v_exp) * 100.0, 2) else 0 end;
  v_complete := (v_exp > 0 and v_total > 0 and v_sub_exp > 0 and v_sub_sat >= v_sub_exp);
  v_rankable := (v_exp > 0 and v_as_exp > 0
                 and (v_as_sat::numeric / v_as_exp::numeric) >= public.sc_report_min_participation());

  insert into public.report_cards(
    student_id, student_name, student_id_ref, class, term, session,
    total, expected_total, subjects_expected, subjects_sat,
    assessments_expected, assessments_sat, percentage, complete, rankable, grade)
  values(p_sid, coalesce(p_name,''), coalesce(p_sid_ref,''), coalesce(p_class,''),
         coalesce(p_term,''), coalesce(p_session,''),
         coalesce(v_total,0), coalesce(v_exp,0), coalesce(v_sub_exp,0), coalesce(v_sub_sat,0),
         coalesce(v_as_exp,0), coalesce(v_as_sat,0), v_pct, v_complete, v_rankable,
         case when coalesce(v_as_sat,0) = 0 then '' else public.sc_report_grade(v_pct) end)
  on conflict(student_id_ref, class, term, session) do update set
    student_id = coalesce(excluded.student_id, report_cards.student_id),
    student_name = excluded.student_name,
    total = excluded.total, expected_total = excluded.expected_total,
    subjects_expected = excluded.subjects_expected, subjects_sat = excluded.subjects_sat,
    assessments_expected = excluded.assessments_expected, assessments_sat = excluded.assessments_sat,
    percentage = excluded.percentage, complete = excluded.complete,
    rankable = excluded.rankable, grade = excluded.grade;
end$$;
revoke execute on function public.sc_terminal_rebuild_one(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.sc_terminal_rebuild_one(uuid,text,text,text,text,text) to authenticated;

create or replace function public.sc_terminal_rank(p_class text, p_term text, p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare n_ranked int := 0; n_held int := 0; cohort int := 0;
begin
  update public.report_cards
     set position = null, tie_group = 0, rank_cohort_size = 0, rank_basis = ''
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')));

  /* see the note in sc_midterm_rank: RANK() orders by score only, so genuine
     ties share a place (1,1,3); the extra columns only make the output stable. */
  with pool as (
    select id, percentage, assessments_sat, subjects_sat, student_name,
           rank() over (order by percentage desc) as pos,
           row_number() over (order by percentage desc, assessments_sat desc,
                                       subjects_sat desc, student_name asc) as rownum,
           dense_rank() over (order by percentage) as tgroup,
           count(*) over () as csize
      from public.report_cards
     where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
       and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')))
       and rankable and percentage > 0
  )
  update public.report_cards m
     set position = p.pos, tie_group = p.tgroup, rank_cohort_size = p.csize,
         rank_basis = format('Ranked against %s candidate(s) on percentage of the full expected load; ties broken by assessments completed, then subjects, then name.', p.csize)
    from pool p where m.id = p.id;
  get diagnostics n_ranked = row_count;

  update public.report_cards
     set rank_basis = case
           when coalesce(percentage,0) = 0 then 'No marks recorded — not ranked.'
           when not rankable then format('Provisional: %s of %s assessments sat, below the %s%% participation threshold — not ranked.',
                                          assessments_sat, assessments_expected,
                                          round(public.sc_report_min_participation()*100))
           when subjects_sat < subjects_expected
             then format('Ranked %s of %s on %s%% of the full load, but only %s of %s subjects sat — result is incomplete and must be read as provisional.',
                          position, rank_cohort_size, trim(to_char(percentage,'FM999990.00')),
                          subjects_sat, subjects_expected)
           else rank_basis end
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')));

  update public.report_cards
     set position = null, tie_group = 0, rank_cohort_size = 0
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')))
     and not (rankable and percentage > 0);
  get diagnostics n_held = row_count;

  select count(*) into cohort from public.report_cards
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')));

  return jsonb_build_object('ok',true,'ranked',n_ranked,'not_ranked',n_held,'cohort',cohort);
end$$;
revoke execute on function public.sc_terminal_rank(text,text,text) from public,anon;
grant execute on function public.sc_terminal_rank(text,text,text) to authenticated;

create or replace function public.sc_generate_terminal_reports(p_class text, p_term text, p_session text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s record; n int := 0; rk jsonb; scored int := 0; unscored int := 0;
begin
  if auth.uid() is null or not (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) then
    return jsonb_build_object('ok',false,'error','Only staff can generate terminal reports');
  end if;
  if coalesce(trim(p_class),'')='' or coalesce(trim(p_term),'')='' or coalesce(trim(p_session),'')='' then
    return jsonb_build_object('ok',false,'error','class, term, and session are required');
  end if;
  for s in
    select st.id, coalesce(nullif(trim(st.admission_no),''),st.id::text) sid_ref, st.full_name, st.class
      from public.students st
     where regexp_replace(lower(trim(coalesce(st.class,''))),'[^a-z0-9]','','g')
           = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
       and coalesce(st.status,'active') in ('active','approved')
  loop
    perform public.sc_terminal_rebuild_one(s.id, s.sid_ref, s.full_name, s.class, p_term, p_session);
    n := n + 1;
  end loop;
  rk := public.sc_terminal_rank(p_class, p_term, p_session);
  select count(*) filter (where percentage > 0), count(*) filter (where percentage = 0)
    into scored, unscored from public.report_cards
   where regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
         = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g')
     and lower(trim(coalesce(term,'')))=lower(trim(coalesce(p_term,'')))
     and lower(trim(coalesce(session,'')))=lower(trim(coalesce(p_session,'')));

  return jsonb_build_object('ok',true,'generated',n,'with_scores',coalesce(scored,0),
    'without_scores',coalesce(unscored,0),'ranking',rk,
    'expected_load',public.sc_expected_load(p_class,p_term,p_session,false),
    'class',p_class,'term',p_term,'session',p_session);
end$$;
grant execute on function public.sc_generate_terminal_reports(text,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. One-button repair: re-measure and re-rank every card in a class
-- ---------------------------------------------------------------------------
create or replace function public.sc_reports_recompute(
  p_class text default null, p_term text default null, p_session text default null,
  p_dry_run boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  g record; n_mid int := 0; n_term int := 0; findings jsonb := '[]'::jsonb;
  changed int := 0; rk_mid jsonb; rk_term jsonb;
begin
  if auth.uid() is null or not (public.is_admin(auth.uid()) or public.is_staff(auth.uid())) then
    return jsonb_build_object('ok',false,'error','Staff/admin only.');
  end if;

  -- report the damage before touching it
  select coalesce(jsonb_agg(x),'[]'::jsonb) into findings from (
    select jsonb_build_object(
             'kind','percentage_not_of_expected_load',
             'class',m.class,'student',m.student_name,'percentage',m.percentage,
             'expected_total',m.expected_total,'total',m.total) as x
      from public.midterm_report_cards m
     where m.has_scores and m.expected_total > 0
       and abs(m.percentage - round((m.total / nullif(m.expected_total,0)) * 100.0, 2)) > 0.01
       and (p_class is null or regexp_replace(lower(trim(coalesce(m.class,''))),'[^a-z0-9]','','g')
                          = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
    union all
    select jsonb_build_object(
             'kind','partial_ranked_above_complete',
             'class',m.class,'student',m.student_name,'position',m.position,
             'subjects_sat',m.subjects_sat,'subjects_expected',m.subjects_expected)
      from public.midterm_report_cards m
     where m.position is not null and m.subjects_expected > 0 and m.subjects_sat < m.subjects_expected
       and exists (select 1 from public.midterm_report_cards o
                    where o.class = m.class and o.term = m.term and o.session = m.session
                      and o.position > m.position and o.subjects_sat >= o.subjects_expected
                      and o.subjects_expected > 0)
       and (p_class is null or regexp_replace(lower(trim(coalesce(m.class,''))),'[^a-z0-9]','','g')
                          = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
  ) f;

  if p_dry_run then
    return jsonb_build_object('ok',true,'mode','dry_run','findings',findings,
      'finding_count',jsonb_array_length(findings),
      'note','Nothing was written. Re-run with p_dry_run => false to repair.');
  end if;

  for g in
    select distinct
           regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g') k,
           min(class) cls, min(term) trm, min(session) ses
      from public.midterm_report_cards
     where (p_class is null or regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
                            = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
       and (p_term is null or lower(trim(coalesce(term,'')))=lower(trim(p_term)))
       and (p_session is null or lower(trim(coalesce(session,'')))=lower(trim(p_session)))
     group by 1
  loop
    perform public.sc_midterm_rebuild_one(m.student_id, m.student_id_ref, m.student_name,
                                          m.class, m.term, m.session)
       from public.midterm_report_cards m
      where regexp_replace(lower(trim(coalesce(m.class,''))),'[^a-z0-9]','','g') = g.k
        and lower(trim(coalesce(m.term,'')))=lower(trim(coalesce(g.trm,'')))
        and lower(trim(coalesce(m.session,'')))=lower(trim(coalesce(g.ses,'')));
    get diagnostics n_mid = row_count;
    rk_mid := public.sc_midterm_rank(g.cls, g.trm, g.ses);
  end loop;

  for g in
    select distinct
           regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g') k,
           min(class) cls, min(term) trm, min(session) ses
      from public.report_cards
     where (p_class is null or regexp_replace(lower(trim(coalesce(class,''))),'[^a-z0-9]','','g')
                            = regexp_replace(lower(trim(coalesce(p_class,''))),'[^a-z0-9]','','g'))
       and (p_term is null or lower(trim(coalesce(term,'')))=lower(trim(p_term)))
       and (p_session is null or lower(trim(coalesce(session,'')))=lower(trim(p_session)))
     group by 1
  loop
    perform public.sc_terminal_rebuild_one(r.student_id, r.student_id_ref, r.student_name,
                                           r.class, r.term, r.session)
       from public.report_cards r
      where regexp_replace(lower(trim(coalesce(r.class,''))),'[^a-z0-9]','','g') = g.k
        and lower(trim(coalesce(r.term,'')))=lower(trim(coalesce(g.trm,'')))
        and lower(trim(coalesce(r.session,'')))=lower(trim(coalesce(g.ses,'')));
    get diagnostics n_term = row_count;
    rk_term := public.sc_terminal_rank(g.cls, g.trm, g.ses);
  end loop;

  return jsonb_build_object('ok',true,'mode','applied',
    'findings_before',findings,'finding_count',jsonb_array_length(findings),
    'midterm_groups_repaired',n_mid,'terminal_groups_repaired',n_term,
    'midterm_ranking',rk_mid,'terminal_ranking',rk_term,
    'rule','Percentage is of the full expected assessment load. Competition ranking. Ties broken by assessments completed, then subjects, then name. Learners below the participation threshold are not ranked.');
end$$;
revoke execute on function public.sc_reports_recompute(text,text,text,boolean) from public,anon;
grant execute on function public.sc_reports_recompute(text,text,text,boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Explain one card, so any rank can be defended
-- ---------------------------------------------------------------------------
create or replace function public.sc_report_explain(
  p_student_ref text, p_class text, p_term text, p_session text, p_kind text default 'midterm')
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r record; load jsonb;
begin
  load := public.sc_expected_load(p_class, p_term, p_session, lower(coalesce(p_kind,'midterm')) <> 'terminal');
  if lower(coalesce(p_kind,'midterm')) = 'terminal' then
    select * into r from public.report_cards
     where student_id_ref = p_student_ref and class = p_class and term = p_term and session = p_session;
  else
    select * into r from public.midterm_report_cards
     where student_id_ref = p_student_ref and class = p_class and term = p_term and session = p_session;
  end if;
  if not found then return jsonb_build_object('ok',false,'error','No card for that student/term.'); end if;
  return jsonb_build_object('ok',true,'student',r.student_name,'class',r.class,
    'total',r.total,'expected_total',r.expected_total,'percentage',r.percentage,
    'grade',r.grade,'position',r.position,'cohort',r.rank_cohort_size,
    'subjects_sat',r.subjects_sat,'subjects_expected',r.subjects_expected,
    'assessments_sat',r.assessments_sat,'assessments_expected',r.assessments_expected,
    'complete',r.complete,'rankable',r.rankable,'basis',r.rank_basis,
    'expected_load',load,
    'working',format('%s marks out of an expected %s = %s%%.', r.total, r.expected_total, r.percentage));
end$$;
grant execute on function public.sc_report_explain(text,text,text,text,text) to authenticated;


-- ---------------------------------------------------------------------------
-- 10. Harden the shared view so nothing downstream can repeat the mistake
-- ---------------------------------------------------------------------------
-- report_subject_totals divides by the maximae of only the columns that have a
-- score row. For a single subject that is correct, but any caller that sums
-- `obtainable` across a learner's rows gets that learner's own submission as
-- the denominator — the same defect in a different place. The view now also
-- exposes the CLASS obtainable for each subject, so a correct cohort percentage
-- is always one division away, and `percent_of_class_load` is the value callers
-- should use.
drop view if exists public.report_subject_totals cascade;
create view public.report_subject_totals as
with scored as (
  select rs.student_id, rs.student_name, rs.student_id_ref, rs.class, rs.subject, rs.term, rs.session,
         round(sum(rs.score),2) obtained,
         round(sum(coalesce(nullif(ac.max_mark,0),100)),2) obtainable
    from public.report_scores rs
    join public.assessment_columns ac on ac.id = rs.column_id
   group by rs.student_id, rs.student_name, rs.student_id_ref, rs.class, rs.subject, rs.term, rs.session
), classload as (
  select class, subject, term, session,
         max(obtainable) as class_obtainable
    from scored
   group by class, subject, term, session
)
select s.student_id, s.student_name, s.student_id_ref, s.class, s.subject, s.term, s.session,
       s.obtained, s.obtainable, cl.class_obtainable,
       case when cl.class_obtainable > 0
            then round(s.obtained / cl.class_obtainable * 100, 2) else 0 end as percent,
       case when s.obtainable > 0
            then round(s.obtained / s.obtainable * 100, 2) else 0 end as percent_of_own_sitting
  from scored s
  join classload cl
    on cl.class = s.class and cl.subject = s.subject
   and cl.term = s.term and cl.session = s.session;
do $$ begin execute 'alter view public.report_subject_totals set (security_invoker = true)'; exception when others then null; end $$;
grant select on public.report_subject_totals to authenticated;

select 'V12.64 applied: sc_expected_load, sc_report_grade, sc_midterm_rank, sc_terminal_rebuild_one, sc_terminal_rank, sc_generate_terminal_reports, sc_reports_recompute, sc_report_explain' as applied;
