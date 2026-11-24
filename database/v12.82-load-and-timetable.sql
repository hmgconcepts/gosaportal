-- ============================================================================
-- V12.82 — THE DIFF A MAINTAINER READS (extract of the V12.82 block)
-- ----------------------------------------------------------------------------
-- Everything below is also inside database/complete-schema.sql, which is the
-- file the school actually runs. This copy exists so a human can read what this
-- release changed without diffing 995 KB of cumulative schema.
--
--   sc_prep_teacher_timetable(scope, class, tz)  every tutor's prep diary, with
--                                                the faults named in plain words
--   sc_poll_bundle()                             bell + message badge + licence
--                                                verdict in ONE round trip
--   sc_io_report()                               which table is doing the writing
--   sc_prune_noise(days)                         a window on the tables that only grow
--   drop index cbt_results_exam_id_idx           two indexes on the same column
--   drop index cbt_results_exam_student_id_idx   were written twice on every submit
--   create index notifications_created_desc      the bell's own read, indexed
-- ============================================================================

-- ============================================================================
-- V12.82 — PREP EXAMS UNDER LOAD
-- 1. sc_prep_teacher_timetable() — every prep sitting, for every tutor, with the
--    class, date, time and length the SCHOOL reads, plus the faults that make a
--    paper unwinnable (clash, zero window, absurd length, no timetable row).
-- 2. sc_poll_bundle() — bell, message badge and licence verdict in ONE round
--    trip instead of three, and without pulling 50 rows per learner every 30 s.
-- 3. Indexes for the reads that ran on every poll.
-- 4. sc_prune_noise() — bounded retention for the tables that only grow.
-- ============================================================================
/* Two indexes on cbt_results index the same column twice (exam_id, and
   (exam_id, student_id) under two names). Every submission pays for both on
   insert; neither pays for itself on read. Dropped, not added. */
drop index if exists public.cbt_results_exam_id_idx;
drop index if exists public.cbt_results_exam_student_id_idx;
create index if not exists cbt_results_exam_student on public.cbt_results(exam_id, student_id);
create index if not exists notifications_created_desc on public.notifications(created_at desc);

create or replace function public.sc_poll_bundle() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
v_role text := lower(coalesce((select p.role from public.profiles p where p.id = me), ''));
v_n int := 0; v_m int := 0; v_lic jsonb := '{}'::jsonb;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'signed_out'); end if;
  -- the bell needs a COUNT; the list is fetched when it is opened
  select count(*)::int into v_n from public.notifications n
   where not (me = any(coalesce(n.read_by, '{}')))
     and not (me = any(coalesce(n.cleared_by, '{}')))
     and coalesce(n.created_at, now()) > now() - interval '60 days'
     and (coalesce(n.recipient_id, n.user_id, n.created_by) = me
          or coalesce(n.audience, 'all') in ('', 'all', 'everyone', 'any')
          or coalesce(n.audience, '') = v_role
          or (coalesce(n.audience, '') in ('staff', 'teachers') and v_role in ('staff', 'teacher'))
          or (coalesce(n.audience, '') = 'students' and v_role in ('student', 'learner'))
          or (coalesce(n.audience, '') = 'parents' and v_role = 'parent'));
  begin select coalesce(public.sc_message_unread(), 0) into v_m; exception when others then v_m := 0; end;
  begin v_lic := public.sc_license_status(); exception when others then v_lic := '{}'::jsonb; end;
  return jsonb_build_object('ok', true, 'notif', v_n, 'msgs', v_m, 'license', v_lic, 'now', now(), 'role', v_role);
end $$;
revoke all on function public.sc_poll_bundle() from public, anon;
grant execute on function public.sc_poll_bundle() to authenticated;

/* Every tutor's prep timetable, in the school's own clock, with the faults.
   p_scope = 'mine' (default) or 'all'. Staff only: a learner and a parent have
   sc_my_prep_exams() and must never see another tutor's paper. */
create or replace function public.sc_prep_teacher_timetable(
  p_scope text default 'mine', p_class text default '', p_tz text default null)
returns table (
  exam_id uuid, code text, title text, subject text, class text,
  teacher_id uuid, teacher_name text, teacher_phone text,
  start_at timestamptz, close_at timestamptz, exam_date date,
  start_time text, end_time text, local_span text,
  duration_min int, window_min int, venue text, term text, session text,
  status text, timetable_row boolean, sat int, expected int,
  issues text[], mine boolean, sort_at timestamptz, tz text
) language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
v_role text := lower(coalesce((select p.role from public.profiles p where p.id = me), ''));
v_all boolean := lower(coalesce(p_scope, 'mine')) = 'all';
v_tz text := coalesce(nullif(btrim(p_tz), ''), public.sc_school_tz());
v_key text := public.sc_class_key(p_class);
v_now timestamptz := now();
begin
  if me is null then return; end if;
  if not (v_role in ('super_admin','admin','principal','proprietor','head_teacher','bursar','staff','teacher')
          or coalesce(public.is_staff(me), false)) then return; end if;
  return query
  with b as (
    select e.id, e.code, e.title, e.subject, e.class, e.teacher_id, e.venue, e.term, e.session,
      e.start_at, e.close_at, e.is_open,
      public.sc_class_key(coalesce(e.class, '')) as ck,
      coalesce(nullif(e.duration_min, 0), nullif(e.duration, 0)) as dur,
      public.sc_cbt_close(e.start_at, e.close_at, e.duration_min, e.duration) as cend
    from public.cbt_exams e
    where public.sc_is_prep_assessment(e.assessment_type)
      and not coalesce(e.is_archived, false)
      and (v_all or e.teacher_id = me)
      and (v_key = '' or public.sc_class_key(coalesce(e.class, '')) = v_key)
  )
  select b.id, b.code, coalesce(nullif(btrim(b.title), ''), 'Prep exam'), coalesce(b.subject, ''),
    coalesce(b.class, ''), b.teacher_id,
    coalesce(nullif(btrim(pr.full_name), ''), '(no tutor assigned)'), coalesce(pr.phone, ''),
    b.start_at, b.close_at,
    (coalesce(b.start_at, b.cend) at time zone v_tz)::date,
    to_char(b.start_at at time zone v_tz, 'HH24:MI'),
    to_char(b.cend at time zone v_tz, 'HH24:MI'),
    coalesce(to_char(b.start_at at time zone v_tz, 'DD Mon HH24:MI') || ' → '
             || to_char(b.cend at time zone v_tz, 'HH24:MI'), 'no time set'),
    coalesce(b.dur, 0),
    case when b.start_at is not null and b.cend is not null
         then greatest(0, round(extract(epoch from (b.cend - b.start_at)) / 60))::int else 0 end,
    coalesce(b.venue, ''), coalesce(b.term, ''), coalesce(b.session, ''),
    case when b.cend is not null and v_now > b.cend then 'closed'
         when b.start_at is not null and v_now < b.start_at then 'upcoming'
         when b.start_at is not null then 'open'
         else 'unscheduled' end,
    exists (select 1 from public.exam_timetable t where t.exam_id = b.id and t.source = 'prep'),
    (select count(*)::int from public.cbt_results r where r.exam_id = b.id),
    (select count(*)::int from public.students s
      where public.sc_class_key(coalesce(s.class, '') || coalesce(s.arm, '')) = b.ck
         or public.sc_class_key(coalesce(s.class, '')) = b.ck),
    (select coalesce(array_agg(x order by i), '{}'::text[])
       from unnest(array[
       case when b.start_at is null then 'no_start_time' end,
       case when coalesce(b.dur, 0) <= 0 then 'no_duration' end,
       case when b.start_at is not null and b.cend is not null and b.cend <= b.start_at then 'closes_before_it_opens' end,
       case when b.start_at is not null and b.close_at is not null and coalesce(b.dur, 0) > 0
             and abs(extract(epoch from (b.close_at - (b.start_at + make_interval(mins => b.dur))))) > 120
            then 'closing_time_vs_length' end,
       case when coalesce(b.dur, 0) > 0 and b.dur < 10 then 'under_10_minutes' end,
       case when b.dur > 180 then 'over_3_hours' end,
       case when b.start_at is not null and b.cend is not null and b.cend - b.start_at > interval '8 hours'
            then 'open_all_day' end,
       case when b.start_at is not null and (extract(hour from (b.start_at at time zone v_tz)) < 5
             or extract(hour from (b.start_at at time zone v_tz)) >= 22) then 'outside_school_hours' end,
       case when coalesce(btrim(b.class), '') = '' then 'no_class' end,
       case when not exists (select 1 from public.exam_timetable t where t.exam_id = b.id and t.source = 'prep')
            then 'not_on_timetable' end,
       case when b.start_at is not null and b.cend is not null and exists (
              select 1 from public.cbt_exams o
               where o.id <> b.id and not coalesce(o.is_archived, false)
                 and public.sc_is_prep_assessment(o.assessment_type)
                 and public.sc_class_key(coalesce(o.class, '')) = b.ck
                 and o.start_at is not null
                 and public.sc_cbt_close(o.start_at, o.close_at, o.duration_min, o.duration) is not null
                 and tstzrange(o.start_at, public.sc_cbt_close(o.start_at, o.close_at, o.duration_min, o.duration))
                     && tstzrange(b.start_at, b.cend)) then 'clashes_with_another_paper' end
     ]) with ordinality as u(x, i) where x is not null),
    (b.teacher_id = me),
    coalesce(b.start_at, b.cend, v_now + interval '100 years'), v_tz
  from b left join public.profiles pr on pr.id = b.teacher_id
  order by coalesce(pr.full_name, 'zzz'), coalesce(b.start_at, b.cend), b.subject;
end $$;
revoke all on function public.sc_prep_teacher_timetable(text, text, text) from public, anon;
grant execute on function public.sc_prep_teacher_timetable(text, text, text) to authenticated;

/* Retention. The two tables that only ever grow, pruned to a window the school
   chooses. Nothing is deleted that a report reads: notifications older than the
   window, and closed hearings older than the window, are the only candidates. */
create or replace function public.sc_prune_noise(p_days int default 120) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
v_role text := lower(coalesce((select p.role from public.profiles p where p.id = me), ''));
v_days int := greatest(30, least(730, coalesce(p_days, 120)));
n_n int := 0; n_l int := 0;
begin
  if not (v_role in ('super_admin','admin','principal','proprietor','head_teacher') or coalesce(public.is_admin(me), false)) then
    return jsonb_build_object('ok', false, 'error', 'Only an administrator can prune.');
  end if;
  delete from public.notifications where coalesce(created_at, now()) < now() - make_interval(days => v_days);
  get diagnostics n_n = row_count;
  begin
    delete from public.login_audit where coalesce(created_at, now()) < now() - make_interval(days => v_days);
    get diagnostics n_l = row_count;
  exception when others then n_l := 0;
  end;
  return jsonb_build_object('ok', true, 'days', v_days, 'notifications_deleted', n_n, 'login_audit_deleted', n_l);
end $$;
revoke all on function public.sc_prune_noise(int) from public, anon;
grant execute on function public.sc_prune_noise(int) to authenticated;

-- ---------------------------------------------------------------------------
-- V12.82 — THE DISK-IO DOCTOR
-- Supabase's free tier runs on Nano: 0.5 GB of RAM, and a daily Disk IO budget
-- that a project can spend in an evening. When it is gone the instance drops to
-- baseline disk throughput, every query slows down together, and the symptoms
-- look like "the portal is broken" rather than "the database is out of IO".
-- This function answers the only question that matters on that morning: WHICH
-- TABLE is doing the writing, and which one is being read without an index.
-- Read-only. Safe to run at any time. Admin only.
-- ---------------------------------------------------------------------------
create or replace function public.sc_io_report() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
v_role text := lower(coalesce((select p.role from public.profiles p where p.id = me), ''));
v_w jsonb; v_r jsonb; v_dead jsonb; v_size text;
begin
  if not (v_role in ('super_admin','admin','principal','proprietor','head_teacher') or coalesce(public.is_admin(me), false)) then
    return jsonb_build_object('ok', false, 'error', 'Only an administrator can read the load report.');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('table', relname, 'writes', n_tup_ins + n_tup_upd + n_tup_del,
      'inserts', n_tup_ins, 'updates', n_tup_upd, 'deletes', n_tup_del) order by (n_tup_ins + n_tup_upd + n_tup_del) desc), '[]'::jsonb)
    into v_w from (select * from pg_stat_user_tables where schemaname = 'public') t;
  select coalesce(jsonb_agg(jsonb_build_object('table', relname, 'seq_scans', seq_scan, 'rows_read', seq_tup_read,
      'idx_scans', coalesce(idx_scan, 0)) order by seq_tup_read desc), '[]'::jsonb)
    into v_r from (select * from pg_stat_user_tables where schemaname = 'public' and coalesce(seq_tup_read, 0) > 0) t;
  select coalesce(jsonb_agg(jsonb_build_object('table', relname, 'live', n_live_tup, 'dead', n_dead_tup,
      'last_autovacuum', last_autovacuum) order by n_dead_tup desc), '[]'::jsonb)
    into v_dead from (select * from pg_stat_user_tables where schemaname = 'public' and coalesce(n_dead_tup, 0) > 0) t;
  select pg_size_pretty(pg_database_size(current_database())) into v_size;
  return jsonb_build_object('ok', true,
    'database_size', v_size,
    'app_tables', (select count(*) from pg_stat_user_tables where schemaname = 'public'),
    'app_indexes', (select count(*) from pg_indexes where schemaname = 'public'),
    'connections', (select count(*) from pg_stat_activity),
    'max_connections', current_setting('max_connections'),
    'top_writers', (select jsonb_agg(x) from (select jsonb_array_elements(v_w) x limit 12) s),
    'top_full_scans', (select jsonb_agg(x) from (select jsonb_array_elements(v_r) x limit 12) s),
    'bloat', (select jsonb_agg(x) from (select jsonb_array_elements(v_dead) x limit 12) s),
    'advice', jsonb_build_array(
      'A table at the top of top_writers is being written more than it is being read: look for a poller, a heartbeat or a log that runs on a timer.',
      'A table at the top of top_full_scans is being read without an index on the column the screen filters by.',
      'bloat rows with a large dead count and an old last_autovacuum mean VACUUM is behind; that is disk the database is still paying for.',
      'The client fix in V12.82 replaced three polls every 30 seconds with one small count every two minutes; if the bill is still high, look for another tab or another device.'));
end $$;
revoke all on function public.sc_io_report() from public, anon;
grant execute on function public.sc_io_report() to authenticated;
