-- ============================================================================
-- School Connect V10.4 — CBT creation RLS root-cause fix (multi-subject aware)
-- ----------------------------------------------------------------------------
-- Run AFTER complete-schema.sql (or any earlier pack) on an EXISTING database.
-- Fresh installs get all of this from complete-schema.sql automatically.
--
-- THE BUG (reported): "Could not create: new row violates row-level security
-- policy for table cbt_exams" when creating a CBT — especially a multi-subject
-- package. Root causes, both proven against a live database:
--
--   1. The insert policy demanded teacher_can_manage_subject_class(uid,
--      subject, class) — but a multi-subject package stores the SYNTHETIC
--      subject string 'MULTI-SUBJECT: Mathematics, English, …'. No subject
--      row is ever named that, so the subject check ALWAYS failed and a
--      teacher could only create the package for the one class where they
--      are the class teacher. Every other class → 42501.
--   2. The client stamps teacher_id from SC_PROFILE, which loads
--      asynchronously; a fast click sent teacher_id = NULL and the
--      (teacher_id = auth.uid()) arm failed even for the right teacher.
--      (Fixed client-side in cbt-engine.js: createExam now falls back to
--      auth.getUser(). This pack fixes the server arm.)
--
-- WHAT THIS PACK DOES
--   1. sc_cbt_subject_allowed(uid, subject, class): understands the
--      'MULTI-SUBJECT: a, b, c' convention — a teacher qualifies when ANY
--      listed subject is theirs, or they class-teach the class. Single
--      subjects delegate to teacher_can_manage_subject_class unchanged.
--      Admin tier always passes. Scope stays tight: a teacher with NO
--      relationship to any listed subject and no class-teachership is
--      still refused.
--   2. teacher_can_manage_subject_class: staff.subjects array match is now
--      case/space-insensitive ('mathematics' vs 'Mathematics' no longer
--      silently fails).
--   3. cbt_exams insert + select policies rebuilt on the new helper.
--      Ownership rules unchanged: non-admins must still stamp
--      teacher_id = auth.uid(); update/delete stay owner-or-admin.
-- ============================================================================
select 'RUNNING: School Connect CBT multi-subject RLS pack V10.4' as running_version;

-- ---------------------------------------------------------------------------
-- 1. teacher_can_manage_subject_class — case-insensitive staff.subjects match
-- ---------------------------------------------------------------------------
create or replace function public.teacher_can_manage_subject_class(p_uid uuid,p_subject text default '',p_class text default '')
returns boolean language plpgsql security definer stable set search_path=public as $$
declare pname text:='';srec record;subject_ok boolean:=false;class_ok boolean:=false;
begin
 if public.is_admin(p_uid)then return true;end if;
 select full_name into pname from public.profiles where id=p_uid and role in('teacher','staff')and status in('approved','active');if not found then return false;end if;
 select * into srec from public.staff where user_id=p_uid and coalesce(status,'active')='active'limit 1;
 if coalesce(trim(p_subject),'')<>''then
  subject_ok:=exists(select 1 from public.subjects su where lower(trim(su.name))=lower(trim(p_subject))and(su.teacher_id=p_uid or lower(trim(coalesce(su.teacher,'')))=lower(trim(pname))or(srec.id is not null and lower(trim(coalesce(su.teacher,'')))=lower(trim(srec.full_name)))or(srec.id is not null and exists(select 1 from unnest(coalesce(srec.subjects,'{}'::text[]))x where lower(trim(x))=lower(trim(p_subject))))));
 end if;
 if coalesce(trim(p_class),'')<>''then class_ok:=exists(select 1 from public.classes c where lower(trim(c.name))=lower(trim(p_class))and(lower(trim(coalesce(c.class_teacher,'')))=lower(trim(pname))or(srec.id is not null and lower(trim(coalesce(c.class_teacher,'')))=lower(trim(srec.full_name)))));end if;
 return subject_ok or class_ok;
end$$;
revoke execute on function public.teacher_can_manage_subject_class(uuid,text,text)from public,anon;
grant execute on function public.teacher_can_manage_subject_class(uuid,text,text)to authenticated;

-- ---------------------------------------------------------------------------
-- 2. sc_cbt_subject_allowed — multi-subject aware CBT creation gate
-- ---------------------------------------------------------------------------
create or replace function public.sc_cbt_subject_allowed(p_uid uuid,p_subject text default '',p_class text default '')
returns boolean language plpgsql security definer stable set search_path=public as $$
declare s text; part text; rest text;
begin
 if public.is_admin(p_uid) then return true; end if;
 s:=coalesce(trim(p_subject),'');
 if upper(s) like 'MULTI-SUBJECT:%' then
   rest:=trim(substr(s,position(':'in s)+1));
   foreach part in array regexp_split_to_array(coalesce(rest,''),'\s*,\s*') loop
     if trim(part)<>'' and public.teacher_can_manage_subject_class(p_uid,trim(part),'') then return true; end if;
   end loop;
   -- none of the listed subjects is theirs — class-teachership still counts
   return public.teacher_can_manage_subject_class(p_uid,'',p_class);
 end if;
 return public.teacher_can_manage_subject_class(p_uid,s,p_class);
end$$;
revoke execute on function public.sc_cbt_subject_allowed(uuid,text,text)from public,anon;
grant execute on function public.sc_cbt_subject_allowed(uuid,text,text)to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Rebuild the cbt_exams insert + select policies on the new gate.
--    Ownership contract preserved: non-admin inserts must stamp their own
--    teacher_id; update/delete remain owner-or-admin (V5.6 form).
-- ---------------------------------------------------------------------------
drop policy if exists cbt_exam_scope_insert on public.cbt_exams;
create policy cbt_exam_scope_insert on public.cbt_exams for insert
 with check(public.is_admin(auth.uid())or(teacher_id=auth.uid()and public.sc_cbt_subject_allowed(auth.uid(),subject,class)));

drop policy if exists cbt_exam_scope_select on public.cbt_exams;
create policy cbt_exam_scope_select on public.cbt_exams for select
 using(public.is_admin(auth.uid())or teacher_id=auth.uid()or public.sc_cbt_subject_allowed(auth.uid(),subject,class));

-- ---------------------------------------------------------------------------
-- 4. DURATION BUG (found during this audit, proven live): creation paths
--    write `duration` only, while `duration_min` silently keeps its column
--    DEFAULT 45 — and the student getter prefers duration_min. Result: a
--    120-minute exam delivered a 45-minute timer to every candidate.
--    Fix: a sync trigger keeps the two columns coherent forever, plus a
--    one-time repair of existing rows caught in the default-45 trap.
-- ---------------------------------------------------------------------------
create or replace function public.sc_cbt_duration_sync()
returns trigger language plpgsql as $$
begin
 if tg_op='UPDATE' then
   if new.duration is distinct from old.duration and new.duration_min is not distinct from old.duration_min then
     new.duration_min:=new.duration;             -- duration edited alone → mirror
   elsif new.duration_min is distinct from old.duration_min and new.duration is not distinct from old.duration then
     new.duration:=new.duration_min;             -- duration_min edited alone → mirror
   end if;
 else
   if coalesce(new.duration,0)>0 and (new.duration_min is null or new.duration_min=45) and new.duration<>45 then
     new.duration_min:=new.duration;             -- insert set duration; duration_min stayed on default
   elsif coalesce(new.duration_min,0)>0 and (new.duration is null or new.duration=45) and new.duration_min<>45 then
     new.duration:=new.duration_min;
   end if;
 end if;
 if coalesce(new.duration,0)<=0 then new.duration:=coalesce(nullif(new.duration_min,0),45); end if;
 if coalesce(new.duration_min,0)<=0 then new.duration_min:=coalesce(nullif(new.duration,0),45); end if;
 return new;
end$$;
drop trigger if exists trg_cbt_duration_sync on public.cbt_exams;
create trigger trg_cbt_duration_sync before insert or update on public.cbt_exams
for each row execute function public.sc_cbt_duration_sync();

-- One-time repair: rows whose duration_min is the untouched default while
-- duration carries the teacher's real figure.
update public.cbt_exams set duration_min=duration
 where coalesce(duration,0)>0 and duration<>45 and coalesce(duration_min,45)=45;

notify pgrst,'reload schema'; select pg_notify('pgrst','reload schema');
select 'V10.4 CBT multi-subject RLS pack installed' as status;
