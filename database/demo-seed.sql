-- ============================================================================
-- SCHOOL CONNECT DEMO — COMPLETE SIMULATED SCHOOL DATASET
-- ----------------------------------------------------------------------------
-- Populates a demo deployment with a realistic, fully-interconnected school:
-- academic periods, subjects, 18 students, 8 staff, fee structures & payments,
-- attendance, check-ins, results + report-card columns/scores/comments/traits,
-- a published CBT exam with real questions + submissions, announcements,
-- events, a live poll, gallery, diary, conduct, health, assignments, survey,
-- leave, visitors, helpdesk, hostel, staff clock-ins, timetable requirements,
-- school shop products, ID cards and sample generic-module records.
--
-- RUN ORDER (see DEMO-SETUP.md):
--   1) database/complete-schema.sql   2) database/demo-users.sql   3) THIS FILE
-- Everything is guarded and idempotent — re-running only tops up what is
-- missing. Demo person accounts (from demo-users.sql):
--   a1 admin  a2 teacher(Funke Alabi)  a3 parent(Mr. Okafor)
--   a4 student(Adanna Okafor)  a5 bursar
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0) Resolve the five demo account ids BY EMAIL
--    Works however the accounts were created: demo-users.sql (fixed UUIDs),
--    Supabase Dashboard "Add user", or the Admin API (random UUIDs).
--    Missing accounts simply degrade those links to NULL — the seed always
--    completes; run demo-users.sql v6 (after Dashboard Add user × 5) to approve the profiles.
--    Account emails are @scdemo.school — created via Dashboard "Add user"
--    (v6 rationale: dashboard-created accounts log in perfectly on the
--    newest GoTrue; SQL-created auth rows cannot; login itself never
--    validates domains — only the public signup API does).
-- ----------------------------------------------------------------------------
-- Session-scoped (NOT `on commit drop`): the SQL Editor commits each statement
-- separately, and this table must survive every statement of the whole run.
create temporary table if not exists sc_demo_ids (role text primary key, id uuid);
insert into sc_demo_ids (role, id) values
  ('admin',   (select id from public.profiles where email='admin@scdemo.school'   limit 1)),
  ('teacher', (select id from public.profiles where email='teacher@scdemo.school' limit 1)),
  ('parent',  (select id from public.profiles where email='parent@scdemo.school'  limit 1)),
  ('student', (select id from public.profiles where email='student@scdemo.school' limit 1)),
  ('bursar',  (select id from public.profiles where email='bursar@scdemo.school'  limit 1))
on conflict (role) do update set id = excluded.id;

-- ----------------------------------------------------------------------------
-- 0) Constants used everywhere (current period = Third Term 2025/2026)
-- ----------------------------------------------------------------------------
-- session: '2025/2026'  term: 'Third Term'  next term begins: 2026-09-07

-- 1) Academic periods ---------------------------------------------------------
insert into public.academic_periods (session, term, starts_on, ends_on, is_current)
values
 ('2025/2026','First Term','2025-09-08','2025-12-12',false),
 ('2025/2026','Second Term','2026-01-12','2026-04-03',false),
 ('2025/2026','Third Term','2026-04-27','2026-07-24',true),
 ('2026/2027','First Term','2026-09-07','2026-12-11',false)
on conflict (session, term) do nothing;

-- 2) School settings polish (safe: updates the seeded singleton row) ----------
-- NOTE: names the simulated school. Prospects see this everywhere in the demo.
update public.school_settings set
  school_name = 'School Connect Demonstration College',
  short_name = 'SCD',
  motto = 'A fully simulated school — explore every feature',
  address = 'HMG Demo Campus, Lagos, Nigeria',
  phone = '+234 810 086 6322',
  email = 'buildingmyictcareer@gmail.com',
  site_url = 'https://schoolconnectdemo.vercel.app/',
  logo_url = 'assets/img/logo.svg',
  admission_acronym = 'SCD',
  admission_prefix = 'SCD',
  staff_prefix = 'SCD-STF',
  principal_name = 'Mrs. Funke Alabi',
  next_term_begins = '2026-09-07',
  next_term_fees = 225000,
  next_term_fees_currency = '₦',
  next_term_fees_note = 'Boarding students add ₦60,000 boarding fee. PTA levy ₦5,000 per family.',
  checkin_deadline = coalesce(nullif(checkin_deadline,''),'07:45'),
  checkin_grace_minutes = greatest(coalesce(checkin_grace_minutes,0),15),
  stamp_enabled = true,
  stamp_text = coalesce(nullif(stamp_text,''),'OFFICIAL SCHOOL SEAL')
where id = 1;

-- 3) Subjects ------------------------------------------------------------------
do $$
declare s text[][] := array[
 ['Mathematics','MTH','Mathematics'],['English Language','ENG','Languages'],
 ['Physics','PHY','Sciences'],['Chemistry','CHM','Sciences'],['Biology','BIO','Sciences'],
 ['Economics','ECO','Commercial'],['Government','GOV','Arts'],['Literature in English','LIT','Arts'],
 ['Computer Science','CSC','Technology'],['Civic Education','CIV','General'],
 ['Further Mathematics','FMT','Mathematics'],['Yoruba Language','YOR','Languages']];
 x text[];
begin
  foreach x slice 1 in array s loop
    if not exists (select 1 from public.subjects where name = x[1]) then
      insert into public.subjects (name, code, department, level, teacher) values (x[1], x[2], x[3], 'All', null);
    end if;
  end loop;
end $$;

-- 3b) Classes, departments and controlled dropdowns used across the portal ----
do $$
begin
  insert into public.classes (name, arm, level, class_teacher, capacity, next_term_fees, next_term_fees_currency, next_term_fees_note)
  select x.name,x.arm,x.level,x.teacher,x.capacity,225000,'₦','Payable before 7 September 2026'
  from (values
    ('Nursery 1','','Nursery','Ngozi Chukwu',25),('Primary 1','','Primary','Ngozi Chukwu',30),
    ('JSS 1','A/B','JSS','Ngozi Chukwu',40),('JSS 2','A','JSS','Chukwuemeka Nwachukwu',40),
    ('JSS 3','A','JSS','Ikechukwu Obasi',40),('SS 1','A','SSS','Olumide Ajayi',35),
    ('SS 2','A/B','SSS','Funke Alabi',35),('SS 3','A','SSS','Hauwa Suleiman',35)
  ) as x(name,arm,level,teacher,capacity)
  where not exists (select 1 from public.classes c where lower(c.name)=lower(x.name));

  insert into public.departments (name, head, members)
  select x.name,x.head,x.members from (values
    ('Administration','Mrs. Grace Obi',array['Sunday Etim']::text[]),
    ('Languages','Chukwuemeka Nwachukwu',array['Chukwuemeka Nwachukwu']::text[]),
    ('Mathematics','Funke Alabi',array['Funke Alabi']::text[]),
    ('Sciences','Hauwa Suleiman',array['Hauwa Suleiman','Olumide Ajayi']::text[]),
    ('Technology','Ikechukwu Obasi',array['Ikechukwu Obasi']::text[]),
    ('Finance','Mariam Danladi',array['Mariam Danladi']::text[]),
    ('General','Ngozi Chukwu',array['Ngozi Chukwu']::text[])
  ) as x(name,head,members)
  where not exists (select 1 from public.departments d where lower(d.name)=lower(x.name));
end $$;

insert into public.lookups (kind,value,position,active) values
 ('term','First Term',1,true),('term','Second Term',2,true),('term','Third Term',3,true),
 ('session','2025/2026',1,true),('session','2026/2027',2,true),
 ('arm','A',1,true),('arm','B',2,true),('arm','C',3,true),
 ('gender','Female',1,true),('gender','Male',2,true),
 ('campus','Main Campus',1,true),('campus','Annex Campus',2,true)
on conflict (kind,value) do update set active=true, position=excluded.position;

-- 4) Students (18) — classes: JSS 1A/B, JSS 2A, JSS 3A, SS 1A, SS 2A/B, arms AB
do $$
declare st text[][] := array[
 -- admission_no, full_name, class, arm, department, gender, dob, guardian, guardian_phone
 ['SCD-00001','Adaeze Nwosu','JSS 1','A','General','Female','2015-03-14','Mrs. Ngozi Nwosu','+234 803 111 0001'],
 ['SCD-00002','Tobi Adeyemi','JSS 1','A','General','Male','2015-06-02','Mr. Kunle Adeyemi','+234 803 111 0002'],
 ['SCD-00003','Chiamaka Eze','JSS 1','A','General','Female','2015-01-23','Mr. Adewale Okafor','+234 803 111 0003'],
 ['SCD-00004','Ibrahim Musa','JSS 1','B','General','Male','2014-11-30','Alhaji Musa Ibrahim','+234 803 111 0004'],
 ['SCD-00005','Somto Okonkwo','JSS 1','B','General','Female','2015-05-18','Mrs. Adaeze Okonkwo','+234 803 111 0005'],
 ['SCD-00006','Femi Ogunleye','JSS 2','A','General','Male','2014-04-09','Chief B. Ogunleye','+234 803 111 0006'],
 ['SCD-00007','Ngozi Umeh','JSS 2','A','General','Female','2014-08-27','Dr. Ify Umeh','+234 803 111 0007'],
 ['SCD-00008','Yusuf Bello','JSS 2','A','General','Male','2014-02-15','Mr. Garba Bello','+234 803 111 0008'],
 ['SCD-00009','Kelechi Obi','JSS 3','A','General','Male','2013-07-19','Mrs. Uche Obi','+234 803 111 0009'],
 ['SCD-00010','Zainab Lawal','JSS 3','A','General','Female','2013-10-05','Barr. H. Lawal','+234 803 111 0010'],
 ['SCD-00011','Chidera Nnamdi','SS 1','A','Science','Female','2012-12-11','Engr. P. Nnamdi','+234 803 111 0011'],
 ['SCD-00012','Emeka Eze','SS 1','A','Science','Male','2012-09-21','Mr. Tony Eze','+234 803 111 0012'],
 ['SCD-00013','Blessing Adebayo','SS 1','A','Science','Female','2013-01-08','Pastor S. Adebayo','+234 803 111 0013'],
 ['SCD-00014','Adanna Okafor','SS 2','A','Science','Female','2011-05-26','Mr. Adewale Okafor','+234 803 111 0014'],
 ['SCD-00015','Ikenna Okoro','SS 2','A','Science','Male','2011-08-13','Chief O. Okoro','+234 803 111 0015'],
 ['SCD-00016','Fatima Usman','SS 2','A','Science','Female','2011-03-30','Dr. Aisha Usman','+234 803 111 0016'],
 ['SCD-00017','Tunde Bakare','SS 2','B','Commercial','Male','2011-07-07','Alhaji R. Bakare','+234 803 111 0017'],
 ['SCD-00018','Amara Obi','SS 2','B','Commercial','Female','2011-12-01','Mrs. Ebere Obi','+234 803 111 0018']
];
 x text[]; n int := 0;
begin
  foreach x slice 1 in array st loop
    n := n + 1;
    if not exists (select 1 from public.students where admission_no = x[1]) then
      insert into public.students (id, admission_no, full_name, class, arm, department, gender, date_of_birth, guardian_name, guardian_phone, address, campus, status, user_id)
      values (('d4000000-0000-4000-8000-00000000'||lpad(to_hex(n),4,'0'))::uuid,
              x[1], x[2], x[3], x[4], x[5], x[6], x[7]::date, x[8], x[9], '12 Demo Crescent, Lagos', 'Main Campus', 'active',
              case when x[1]='SCD-00014' then (select id from sc_demo_ids where role='student') else null end);
    end if;
  end loop;
end $$;

-- 4b) Parent / guardian registry (the parent portal account links below) --------
insert into public.parents (full_name,email,phone,occupation,address,status,date_of_birth)
select x.full_name,x.email,x.phone,x.occupation,x.address,'active',x.dob::date
from (values
 ('Mr. Adewale Okafor','parent@scdemo.school','+234 803 111 0014','Civil Engineer','12 Demo Crescent, Lagos','1980-05-19'),
 ('Mrs. Ngozi Nwosu','ngozi.nwosu@example.com','+234 803 111 0001','Pharmacist','14 Unity Road, Lagos','1982-09-03'),
 ('Dr. Aisha Usman','aisha.usman@example.com','+234 803 111 0016','Medical Doctor','8 College Avenue, Lagos','1979-02-11'),
 ('Chief O. Okoro','okoro.family@example.com','+234 803 111 0015','Business Owner','21 Admiralty Way, Lagos','1975-12-08'),
 ('Mrs. Ebere Obi','ebere.obi@example.com','+234 803 111 0018','Chartered Accountant','17 School View, Lagos','1984-07-27')
) as x(full_name,email,phone,occupation,address,dob)
where not exists (select 1 from public.parents p where lower(p.full_name)=lower(x.full_name));

-- 5) Staff (8) -----------------------------------------------------------------
do $$
declare sf text[][] := array[
 ['SCD-STF-00001','Funke Alabi','Mathematics Teacher','Mathematics','Mathematics, Further Mathematics','funke.alabi@scdemo.school'],
 ['SCD-STF-00002','Chukwuemeka Nwachukwu','English Teacher','Languages','English Language, Literature in English','c.nwachukwu@scdemo.school'],
 ['SCD-STF-00003','Hauwa Suleiman','Physics Teacher','Sciences','Physics, Basic Technology','h.suleiman@scdemo.school'],
 ['SCD-STF-00004','Olumide Ajayi','Biology Teacher','Sciences','Biology, Agricultural Science','o.ajayi@scdemo.school'],
 ['SCD-STF-00005','Ngozi Chukwu','Class Teacher (JSS 1)','General','Civic Education, Social Studies','n.chukwu@scdemo.school'],
 ['SCD-STF-00006','Ikechukwu Obasi','ICT / CBT Coordinator','Technology','Computer Science','i.obasi@scdemo.school'],
 ['SCD-STF-00007','Mariam Danladi','Bursar','Finance','', 'm.danladi@scdemo.school'],
 ['SCD-STF-00008','Sunday Etim','Admin Officer','Administration','','s.etim@scdemo.school']];
 x text[]; n int := 0;
begin
  foreach x slice 1 in array sf loop
    n := n + 1;
    insert into public.staff (id, staff_no, full_name, email, phone, role, department, subjects, subject_taught, staff_type, part_time, status, user_id)
    values (('d5000000-0000-4000-8000-00000000'||lpad(to_hex(n),4,'0'))::uuid,
            x[1], x[2], x[6], '+234 805 222 00'||lpad(n::text,2,'0'), x[3], x[4],
            case when x[5] = '' then null else string_to_array(x[5], ', ')::text[] end, x[5],
            case when x[5] = '' then 'non-teaching' else 'teaching' end, false, 'active',
            case when x[1]='SCD-STF-00001' then (select id from sc_demo_ids where role='teacher') else null end)
    on conflict (staff_no) do update set full_name=excluded.full_name, email=excluded.email, phone=excluded.phone,
      role=excluded.role, department=excluded.department, subjects=excluded.subjects,
      subject_taught=excluded.subject_taught, staff_type=excluded.staff_type,
      user_id=coalesce(excluded.user_id,staff.user_id), status='active';
  end loop;
end $$;

-- Demo teacher-owned signature (synthetic SVG; proves class-teacher report signing).
update public.profiles set signature_url='assets/img/demo-signature.svg'
where email='teacher@scdemo.school';
update public.staff set signature_url=(select signature_url from public.profiles where email='teacher@scdemo.school' limit 1)where staff_no='SCD-STF-00001';

-- 6) Parent-child links: demo parent (a3) → Adanna (SS 2A) & Chiamaka (JSS 1A)
do $$
begin
    insert into public.parent_child (parent_id, student_id, relationship, verified)
    select p.id, s.id, 'parent', true
    from sc_demo_ids p, public.students s
    where p.role='parent' and p.id is not null and s.admission_no in ('SCD-00014','SCD-00003')
    on conflict do nothing;
end $$;

-- 7) Class fee structures (Third Term 2025/2026) --------------------------------
do $$
declare fs text[][] := array[
 -- class, arm, dept, tuition, exam, development, other, total
 ['JSS 1','A','General','185000','15000','10000','5000','215000'],
 ['JSS 1','B','General','185000','15000','10000','5000','215000'],
 ['JSS 2','A','General','190000','15000','10000','5000','220000'],
 ['JSS 3','A','General','195000','18000','10000','5000','228000'],
 ['SS 1','A','Science','215000','20000','12000','8000','255000'],
 ['SS 2','A','Science','225000','22000','12000','8000','267000'],
 ['SS 2','B','Commercial','215000','22000','12000','8000','257000']];
 x text[];
begin
  foreach x slice 1 in array fs loop
    insert into public.class_fee_structure (class, arm, department, term, session, tuition, exam_fee, development, other_fee, total, amount, currency, next_term_begins, note, fee_items, active)
    values (x[1], x[2], x[3], 'Third Term', '2025/2026', x[4]::numeric, x[5]::numeric, x[6]::numeric, x[7]::numeric, x[8]::numeric, x[8]::numeric, '₦', '2026-09-07',
            'Boarding students add ₦60,000. Sibling discount 5% on tuition from 3rd child.',
            jsonb_build_array(
              jsonb_build_object('item','Tuition','amount',x[4]::numeric),
              jsonb_build_object('item','Examination','amount',x[5]::numeric),
              jsonb_build_object('item','Development levy','amount',x[6]::numeric),
              jsonb_build_object('item','ICT & e-learning','amount',x[7]::numeric)), true)
    on conflict (class, arm, department, term) do nothing;
  end loop;
end $$;

-- 8) Fee payments — mix of fully paid, half paid and a few outstanding --------
do $$
declare
  s record; idx int := 0; bill numeric; pay numeric; meth text;
begin
  for s in select st.id, st.admission_no, st.class, st.arm, coalesce(st.department,'General') dept,
                  coalesce(cfs.total,210000) total
           from public.students st
           left join public.class_fee_structure cfs
             on cfs.class=st.class and cfs.arm=st.arm and cfs.department=coalesce(st.department,'General') and cfs.term='Third Term'
           order by st.admission_no loop
    idx := idx + 1;
    pay := case when idx % 3 = 0 then s.total            -- every 3rd: full
                when idx % 3 = 1 then round(s.total/2)   -- half
                else 0 end;                              -- every 3rd from 0: owing
    if pay > 0 and not exists (select 1 from public.fee_payments where student_id=s.id and term='Third Term' and session='2025/2026') then
      insert into public.fee_payments (student_id, amount_paid, fee_total, method, reference, term, session, received_by)
      values (s.id, pay, s.total, case when idx%2=0 then 'Bank Transfer' else 'POS' end,
              'DEMO-PAY-2026-'||lpad(idx::text,3,'0'), 'Third Term', '2025/2026',
              (select id from sc_demo_ids where role='bursar'));
    end if;
  end loop;
end $$;

-- 9) Attendance — last 12 school days, deterministic realistic pattern --------
do $$
declare
  s record; d date; idx int; dow int; stat text;
begin
  for s in select id, admission_no, class, arm from public.students order by admission_no loop
    for d in select gs::date from generate_series(current_date - 18, current_date - 1, interval '1 day') gs loop
      dow := extract(isodow from d);
      if dow > 5 then continue; end if;                     -- school days only
      idx := (substring(s.admission_no from 5))::int;
      stat := case
                when (idx + extract(day from d)::int) % 17 = 0 then 'absent'
                when (idx + extract(day from d)::int) % 9  = 0 then 'late'
                when (idx + extract(day from d)::int) % 23 = 0 then 'excused'
                else 'present' end;
      insert into public.attendance (student_id, class, date, status, time_in)
      values (s.id, s.class||' '||s.arm, d, stat,
              case when stat in ('present','late') then (d + time '07:3'|| (idx%9)::text)::timestamptz end)
      on conflict (student_id, date) do nothing;
      if stat in ('present','late') and not exists (select 1 from public.student_clock where student_id=s.id and date=d) then
        insert into public.student_clock (student_id, clock_in, date)
        values (s.id, (d + time '07:2' || (idx%10)::text)::timestamptz, d);
      end if;
    end loop;
  end loop;
end $$;

-- 10) Results — SS 2 A Science, 5 subjects (feeds Results + Broadsheets) -------
do $$
declare
  subs text[] := array['Mathematics','English Language','Physics','Chemistry','Biology'];
  s record; sub text; idx int; c1 int; c2 int; ex int; tot int; gr text;
begin
  for s in select id, admission_no from public.students where admission_no in ('SCD-00014','SCD-00015','SCD-00016') order by admission_no loop
    idx := 0;
    foreach sub in array subs loop
      idx := idx + 1;
      if exists (select 1 from public.results where student_id=s.id and subject=sub and class='SS 2' and term='Third Term' and session='2025/2026') then continue; end if;
      c1 := 8 + ((substring(s.admission_no from 5))::int + idx*3) % 12;       -- 8..19
      c2 := 9 + ((substring(s.admission_no from 5))::int + idx*5) % 11;       -- 9..19
      ex := 38 + ((substring(s.admission_no from 5))::int + idx*7) % 21;      -- 38..58
      tot := c1 + c2 + ex;
      gr := case when tot>=70 then 'A' when tot>=60 then 'B' when tot>=50 then 'C' when tot>=45 then 'D' when tot>=40 then 'E' else 'F' end;
      insert into public.results (student_id, subject, class, term, session, ca1, ca2, exam, grade, remark)
      values (s.id, sub, 'SS 2', 'Third Term', '2025/2026', c1, c2, ex, gr,
              case when tot>=60 then 'Excellent' when tot>=50 then 'Very good' when tot>=40 then 'Fair' else 'Needs improvement' end);
    end loop;
  end loop;
end $$;

-- 11) Report card: ONE school-wide assessment template, exactly like samples --
--     CA1 10 + CA2 10 + CA3/CBT 10 + Project 10 + Exam 60 = 100.
do $$
begin
  -- Remove only the known obsolete demo columns from previous seed versions.
  delete from public.assessment_columns where id::text like 'd6100000-0000-4000-8000-%';
  insert into public.assessment_columns (id,class,subject,term,session,name,max_mark,weight,position,source) values
    ('d6100000-0000-4000-8000-000000000001','SS 2','*','Third Term','2025/2026','CA 1',10,1,1,'teacher'),
    ('d6100000-0000-4000-8000-000000000002','SS 2','*','Third Term','2025/2026','CA 2',10,1,2,'teacher'),
    ('d6100000-0000-4000-8000-000000000003','SS 2','*','Third Term','2025/2026','CA 3 / CBT',10,1,3,'cbt'),
    ('d6100000-0000-4000-8000-000000000004','SS 2','*','Third Term','2025/2026','Project',10,1,4,'teacher'),
    ('d6100000-0000-4000-8000-000000000005','SS 2','*','Third Term','2025/2026','Exam',60,1,5,'teacher')
  on conflict do nothing;
end $$;

-- 12) Report-card scores: every seeded learner × subject × sample column -------
do $$
declare
  s record; col record; sub text; base numeric;
  subs text[] := array['Mathematics','English Language','Physics','Chemistry','Biology'];
begin
  for s in select id, admission_no, full_name from public.students where admission_no in ('SCD-00014','SCD-00015','SCD-00016') order by admission_no loop
    foreach sub in array subs loop
      for col in select id,name,max_mark from public.assessment_columns where class='SS 2' and subject='*' and term='Third Term' and session='2025/2026' order by position loop
        base := round(col.max_mark * (0.62 + (((substring(s.admission_no from 5))::int + length(sub) + length(col.name)) % 24) / 100.0));
        insert into public.report_scores (column_id,student_id,student_id_ref,student_name,class,subject,term,session,score,source)
        values (col.id,s.id,s.admission_no,s.full_name,'SS 2',sub,'Third Term','2025/2026',least(base,col.max_mark),'demo-seed-v5')
        on conflict (column_id,student_id_ref,student_name,class,subject,term,session)
        do update set score=excluded.score,source=excluded.source,student_id=excluded.student_id,updated_at=now();
      end loop;
    end loop;
  end loop;
end $$;

-- 13) Report comments + affective & psychomotor traits -------------------------
do $$
declare
  s record;
begin
  for s in select id from public.students where admission_no in ('SCD-00014','SCD-00015','SCD-00016') loop
    insert into public.report_comments (student_id, term, session, class_teacher_comment, principal_comment, next_term_begins)
    values (s.id, 'Third Term', '2025/2026',
            'A focused and consistent term. Keep up the excellent study culture.',
            'A solid term of hard work — the school is proud of this performance.',
            '2026-09-07')
    on conflict (student_id, term, session) do nothing;
    insert into public.affective_traits (student_id, term, session, ratings, data)
    values (s.id, 'Third Term', '2025/2026',
            jsonb_build_object('Punctuality',5,'Neatness',4,'Honesty',5,'Relationship with others',4,'Attentiveness',5),
            jsonb_build_object('punctuality',5,'neatness',4,'honesty',5,'cooperation',4,'attentiveness',5))
    on conflict (student_id, term, session) do update set ratings=excluded.ratings,data=excluded.data;
    insert into public.psychomotor_traits (student_id, term, session, ratings, data)
    values (s.id, 'Third Term', '2025/2026',
            jsonb_build_object('Handwriting',4,'Sports & games',5,'Drawing & painting',3,'Crafts',4,'Musical skills',3),
            jsonb_build_object('handwriting',4,'sports',5,'drawing',3,'crafts',4,'music',3))
    on conflict (student_id, term, session) do update set ratings=excluded.ratings,data=excluded.data;
    insert into public.report_cards (student_id,student_name,student_id_ref,class,term,session,teacher_comment,head_comment,attendance_present,attendance_total,affective,psychomotor,next_term_begins,position,published)
    select s.id,st.full_name,st.admission_no,st.class,'Third Term','2025/2026',
      'A focused and consistent term. Keep up the excellent study culture.',
      'A solid term of hard work — the school is proud of this performance.',56,60,
      jsonb_build_object('Punctuality',5,'Neatness',4,'Honesty',5,'Attentiveness',5),
      jsonb_build_object('Handwriting',4,'Sports',5,'Crafts',4,'Music',3),'2026-09-07',
      case st.admission_no when 'SCD-00014' then 1 when 'SCD-00015' then 2 else 3 end,true
    from public.students st where st.id=s.id
    on conflict (student_id_ref,class,term,session) do update set teacher_comment=excluded.teacher_comment,head_comment=excluded.head_comment,published=true;
  end loop;
end $$;

-- 14) CBT exams (fixed ids) with REAL embedded questions -------------------------
do $$
begin
  if not exists (select 1 from public.cbt_exams where code='DEMO-MATH1') then
    insert into public.cbt_exams (id, teacher_id, code, title, subject, class, term, session, topic, assessment_type, max_score, duration_min, attempt_limit, randomise, is_open, is_archived, pass_mark, release_results, instructions, certificate_enabled, questions)
    values ('d6000000-0000-4000-8000-000000000001', coalesce((select id from sc_demo_ids where role='teacher'), (select id from public.profiles where role in ('admin','teacher') order by role limit 1)),
      'DEMO-MATH1','JSS 1 Mathematics Speed Test','Mathematics','JSS 1','Third Term','2025/2026','Number & Algebra','CA',
      100, 10, 1, true, true, false, 50, true,
      'Answer all questions. Each question carries 10 marks. No calculator.', true,
      '[
        {"question":"What is the value of 2x + 3 when x = 4?","options":["5","11","13","23"],"answer":"B","explanation":"2(4)+3 = 8+3 = 11.","mark":10},
        {"question":"Simplify: 3/5 + 1/5","options":["4/10","4/5","2/5","1"],"answer":"B","explanation":"Same denominators: (3+1)/5 = 4/5.","mark":10},
        {"question":"What is the LCM of 4 and 6?","options":["10","24","12","8"],"answer":"C","explanation":"Multiples of 4: 4,8,12…; of 6: 6,12… ⇒ 12.","mark":10},
        {"question":"A triangle has angles 50° and 60°. The third angle is?","options":["70°","80°","60°","90°"],"answer":"A","explanation":"Angles in a triangle sum to 180°.","mark":10},
        {"question":"Write 0.75 as a fraction in lowest terms.","options":["3/4","7/5","75/10","1/4"],"answer":"A","explanation":"0.75 = 75/100 = 3/4.","mark":10},
        {"question":"What is 15% of 200?","options":["20","30","25","35"],"answer":"B","explanation":"0.15 × 200 = 30.","mark":10},
        {"question":"Solve: 5y = 45","options":["y = 8","y = 9","y = 7","y = 40"],"answer":"B","explanation":"y = 45 ÷ 5 = 9.","mark":10},
        {"question":"The perimeter of a square of side 7 cm is?","options":["14 cm","21 cm","28 cm","49 cm"],"answer":"C","explanation":"P = 4 × 7 = 28 cm.","mark":10},
        {"question":"Which of these is a prime number?","options":["9","15","17","21"],"answer":"C","explanation":"17 has exactly two factors: 1 and 17.","mark":10},
        {"question":"Round 4.467 to 1 decimal place.","options":["4.4","4.5","4.47","5.0"],"answer":"B","explanation":"The second decimal (6) rounds the first up.","mark":10}
      ]'::jsonb);
  end if;
  if not exists (select 1 from public.cbt_exams where code='DEMO-ENG2') then
    insert into public.cbt_exams (id, teacher_id, code, title, subject, class, term, session, topic, assessment_type, max_score, duration_min, attempt_limit, randomise, is_open, is_archived, pass_mark, release_results, instructions, certificate_enabled, questions)
    values ('d6000000-0000-4000-8000-000000000002', coalesce((select id from sc_demo_ids where role='teacher'), (select id from public.profiles where role in ('admin','teacher') order by role limit 1)),
      'DEMO-ENG2','SS 2 English Lexis & Structure','English Language','SS 2','Third Term','2025/2026','Lexis and Structure','Exam',
      100, 8, 2, false, true, false, 60, true,
      'Choose the option that best completes each sentence.', false,
      '[
        {"question":"Neither the teacher nor the students ___ present.","options":["was","were","is","has been"],"answer":"B","explanation":"Proximity rule: the nearer subject (students) is plural.","mark":20},
        {"question":"The synonym of FRUGAL is","options":["wasteful","thrifty","generous","careless"],"answer":"B","explanation":"Frugal = economical/thrifty.","mark":20},
        {"question":"Choose the correctly spelt word.","options":["Occurence","Ocurrence","Occurrence","Ocurrance"],"answer":"C","explanation":"Double c, double r: occurrence.","mark":20},
        {"question":"The principal addressed the assembly, ___?","options":["did he","didn''t he","doesn''t he","wasn''t he"],"answer":"B","explanation":"Positive statement → negative tag; past tense → didn''t.","mark":20},
        {"question":"''To let the cat out of the bag'' means","options":["to free a pet","to reveal a secret","to cause trouble","to buy a pet"],"answer":"B","explanation":"Idiom: reveal a secret.","mark":20}
      ]'::jsonb);
  end if;
  if not exists (select 1 from public.cbt_exams where code='DEMO-UTME') then
    insert into public.cbt_exams (id,teacher_id,code,title,subject,class,term,session,topic,assessment_type,max_score,duration,duration_min,attempt_limit,select_count,randomise,is_open,is_archived,pass_mark,release_results,instructions,anti_cheat_config,certificate_enabled,csv_data,questions)
    values ('d6000000-0000-4000-8000-000000000003',coalesce((select id from sc_demo_ids where role='teacher'),(select id from public.profiles where role in ('admin','teacher') order by role limit 1)),
      'DEMO-UTME','Demo UTME — English & Mathematics','MULTI-SUBJECT: English Language, Mathematics','SS 2','Third Term','2025/2026','UTME Practice','Exam',100,20,20,3,0,true,true,false,50,true,
      'Use the subject tabs at the top to switch freely. Your progress is retained in every subject.',
      '{"multi_subject":true,"subjects":["English Language","Mathematics"],"subject_breakdown":[{"name":"English Language","start":0,"count":4,"end":3},{"name":"Mathematics","start":4,"count":4,"end":7}],"window_blur":true,"copy_paste":true,"right_click":true,"fullscreen":false,"watermark":true,"max_violations":8}'::jsonb,true,
      '[
       {"question":"Choose the word nearest in meaning to DILIGENT.","type":"mcq","options":["Lazy","Hard-working","Noisy","Careless"],"answer":"B","mark":10,"section":"English Language","subject":"English Language"},
       {"question":"She has lived in Lagos ___ 2020.","type":"mcq","options":["for","since","from","during"],"answer":"B","mark":10,"section":"English Language","subject":"English Language"},
       {"question":"A sentence that asks a question is interrogative.","type":"true_false","options":["True","False"],"answer":"True","mark":10,"section":"English Language","subject":"English Language"},
       {"question":"Select BOTH nouns.","type":"multi_select","options":["quickly","teacher","beautiful","school"],"answer":["B","D"],"mark":10,"section":"English Language","subject":"English Language"},
       {"question":"Solve 3x + 4 = 19.","type":"mcq","options":["3","4","5","6"],"answer":"C","mark":15,"section":"Mathematics","subject":"Mathematics"},
       {"question":"What is 25% of 80?","type":"mcq","options":["15","20","25","30"],"answer":"B","mark":15,"section":"Mathematics","subject":"Mathematics"},
       {"question":"Enter the square root of 144.","type":"numeric","answer":"12","tolerance":"0","mark":15,"section":"Mathematics","subject":"Mathematics"},
       {"question":"The angles in a triangle add up to 180 degrees.","type":"true_false","options":["True","False"],"answer":"True","mark":15,"section":"Mathematics","subject":"Mathematics"}
      ]'::jsonb,
      '[
       {"question":"Choose the word nearest in meaning to DILIGENT.","type":"mcq","options":["Lazy","Hard-working","Noisy","Careless"],"answer":"B","mark":10,"section":"English Language","subject":"English Language"},
       {"question":"She has lived in Lagos ___ 2020.","type":"mcq","options":["for","since","from","during"],"answer":"B","mark":10,"section":"English Language","subject":"English Language"},
       {"question":"A sentence that asks a question is interrogative.","type":"true_false","options":["True","False"],"answer":"True","mark":10,"section":"English Language","subject":"English Language"},
       {"question":"Select BOTH nouns.","type":"multi_select","options":["quickly","teacher","beautiful","school"],"answer":["B","D"],"mark":10,"section":"English Language","subject":"English Language"},
       {"question":"Solve 3x + 4 = 19.","type":"mcq","options":["3","4","5","6"],"answer":"C","mark":15,"section":"Mathematics","subject":"Mathematics"},
       {"question":"What is 25% of 80?","type":"mcq","options":["15","20","25","30"],"answer":"B","mark":15,"section":"Mathematics","subject":"Mathematics"},
       {"question":"Enter the square root of 144.","type":"numeric","answer":"12","tolerance":"0","mark":15,"section":"Mathematics","subject":"Mathematics"},
       {"question":"The angles in a triangle add up to 180 degrees.","type":"true_false","options":["True","False"],"answer":"True","mark":15,"section":"Mathematics","subject":"Mathematics"}
      ]'::jsonb);
  end if;
end $$;

-- 15) CBT submissions (realistic student attempts) ------------------------------
do $$
declare
  exam1 uuid := 'd6000000-0000-4000-8000-000000000001';
  exam2 uuid := 'd6000000-0000-4000-8000-000000000002';
  exam3 uuid := 'd6000000-0000-4000-8000-000000000003';
  s record; idx int := 0; sc int; att int;
begin
  for s in select id, admission_no, full_name, class, arm from public.students order by admission_no loop
    idx := idx + 1;
    if s.class='JSS 1' and exists (select 1 from public.cbt_exams where id=exam1)
       and not exists (select 1 from public.cbt_results where exam_id=exam1 and student_id_ref=s.admission_no) then
      sc := 30 + (idx*13) % 71;  -- 30..100
      insert into public.cbt_results (exam_id, student_id, student_name, student_class, student_id_ref, student_type, score, total, percent, correct_count, wrong_count, attempt_number, time_taken, submitted_at)
      values (exam1, s.id, s.full_name, s.class||' '||s.arm, s.admission_no, 'student', sc, 100, sc, sc/10, 10 - sc/10, 1, 300 + (idx*37)%240, now() - ((idx%5)::text||' days')::interval);
    end if;
    if s.class='SS 2' and s.arm='A' and exists (select 1 from public.cbt_exams where id=exam2)
       and not exists (select 1 from public.cbt_results where exam_id=exam2 and student_id_ref=s.admission_no) then
      att := 1 + (idx % 2);
      sc := 40 + (idx*17) % 61;
      insert into public.cbt_results (exam_id, student_id, student_name, student_class, student_id_ref, student_type, score, total, percent, correct_count, wrong_count, attempt_number, time_taken, submitted_at)
      values (exam2, s.id, s.full_name, s.class||' '||s.arm, s.admission_no, 'student', sc, 100, sc, sc/20, 5 - sc/20, att, 240 + (idx*29)%180, now() - ((idx%4)::text||' days')::interval);
    end if;
    if s.class='SS 2' and exists (select 1 from public.cbt_exams where id=exam3)
       and not exists (select 1 from public.cbt_results where exam_id=exam3 and student_id_ref=s.admission_no) then
      sc := 55 + (idx*11) % 41;
      insert into public.cbt_results (exam_id,student_id,student_name,student_class,student_id_ref,student_type,score,total,percent,correct_count,wrong_count,skipped_count,attempt_number,time_taken,submitted_at,subject_scores,answers_data,client_ref)
      values (exam3,s.id,s.full_name,s.class||' '||s.arm,s.admission_no,'student',sc,100,sc,5,2,1,1,620+(idx*17)%160,now()-((idx%3)::text||' days')::interval,
       jsonb_build_object('English Language',jsonb_build_object('score',30,'total',40,'correct',3,'wrong',1,'skipped',0),'Mathematics',jsonb_build_object('score',sc-30,'total',60,'correct',2,'wrong',1,'skipped',1)),
       '[]'::jsonb,'DEMO-UTME-'||s.admission_no);
    end if;
  end loop;
end $$;

-- 16) Announcements --------------------------------------------------------------
do $$
declare a text[][] := array[
 ['Welcome to Third Term!','We warmly welcome all students and parents to Third Term 2025/2026. Check the portal for the updated fee bills and the academic calendar.','high','true'],
 ['PTA Meeting — Saturday 25 July','All parents are invited to the termly PTA meeting in the school hall at 10:00 AM. Agenda: results review, next-term fees, security update.','normal','false'],
 ['Mid-Term Break Notice','School closes for the mid-term break on Thursday and Friday. Boarding students return on Sunday by 5 PM.','urgent','false']];
 x text[];
begin
  foreach x slice 1 in array a loop
    if not exists (select 1 from public.announcements where title = x[1]) then
      insert into public.announcements (title, body, priority, pinned, audience, posted_by)
      values (x[1], x[2], x[3], x[4]::boolean, 'all', null);
    end if;
  end loop;
end $$;

-- 17) Events & school calendar ---------------------------------------------------
do $$
begin
  if not exists (select 1 from public.events where title='Inter-House Sports') then
    insert into public.events (title, description, date, venue, organiser) values
      ('Inter-House Sports','Annual inter-house athletics competition. Parents are welcome.','2026-07-31','School Sports Complex','Games Department'),
      ('Open Day','Prospective parents tour the school and meet teachers.','2026-08-14','Main Campus','Admissions Office'),
      ('Cultural Day','Students showcase Nigeria''s rich cultures — dress code: traditional wear.','2026-08-28','School Hall','Social Committee');
  end if;
  if not exists (select 1 from public.module_records where module='school_calendar' and title='Third Term Ends') then
    insert into public.module_records (module, title, ref_date, body, data) values
      ('school_calendar','Third Term Ends','2026-07-24','Students vacate for the session break.','{"category":"term-end"}'::jsonb),
      ('school_calendar','First Term 2026/2027 Begins','2026-09-07','Resumption — all students and staff.','{"category":"term-start"}'::jsonb);
  end if;
end $$;

-- 18) Live poll + votes ------------------------------------------------------------
do $$
declare pid uuid;
begin
  if not exists (select 1 from public.polls where title='Vote: Best Teacher of the Term') then
    insert into public.polls (title, type, candidates, allow_multiple, anonymous, audience, status, created_by)
    values ('Vote: Best Teacher of the Term','single_choice',
            '[{"id":"c1","name":"Mrs. Funke Alabi (Mathematics)"},{"id":"c2","name":"Mr. C. Nwachukwu (English)"},{"id":"c3","name":"Mrs. Hauwa Suleiman (Physics)"}]'::jsonb,
            false, true, 'all', 'open', null)
    returning id into pid;
    insert into public.poll_votes (poll_id, candidate_id, voter_id)
    select pid, case d.role when 'parent' then 'c3' else 'c1' end, d.id
    from sc_demo_ids d
    where d.role in ('teacher','student','parent','bursar') and d.id is not null
    on conflict do nothing;
  end if;
end $$;

-- 19) Gallery ----------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.gallery where album='School Life 2026') then
    insert into public.gallery (album, caption, media_url, media_type, uploaded_by) values
      ('School Life 2026','Interactive whiteboard session in the ICT lab','assets/img/og-cover.svg','image',null),
      ('School Life 2026','Inter-house sports — final lap of the 100m race','assets/img/logo.png','image',null),
      ('School Life 2026','Science practical: titration experiment in the chemistry lab','assets/img/og-cover.svg','image',null);
  end if;
end $$;

-- 20) Diary, conduct, health, assignments, lesson plans ---------------------------
do $$
declare
  adanna uuid := (select id from public.students where admission_no='SCD-00014' limit 1);
  chiamaka uuid := (select id from public.students where admission_no='SCD-00003' limit 1);
begin
  if adanna is not null and (select count(*) from public.student_diary) < 3 then
    insert into public.student_diary (student_id, student_name, class, subject, date, entry_type, title, body, created_by) values
      (adanna,'Adanna Okafor','SS 2 A','English Language',current_date - 1,'homework','Essay assignment reminder','Adanna is to submit her argumentative essay on Friday. Please ensure she revises the outline shared in class.',coalesce((select id from sc_demo_ids where role='teacher'), (select id from public.profiles where role in ('admin','teacher') order by role limit 1))),
      (chiamaka,'Chiamaka Eze','JSS 1 A','Mathematics',current_date - 2,'commendation','Excellent mental maths today','Chiamaka answered five mental-maths questions correctly in class today. Well done!',coalesce((select id from sc_demo_ids where role='teacher'), (select id from public.profiles where role in ('admin','teacher') order by role limit 1))),
      (adanna,'Adanna Okafor','SS 2 A','Class Teacher',current_date - 5,'general','Reading culture','Encourage Adanna to complete the class novel before the literature quiz next week.',coalesce((select id from sc_demo_ids where role='teacher'), (select id from public.profiles where role in ('admin','teacher') order by role limit 1)));
  end if;
  if (select count(*) from public.conduct) < 3 then
    insert into public.conduct (student_id, type, description, reporter, date) values
      ((select id from public.students where admission_no='SCD-00014'),'merit','Won the inter-class science quiz for SS 2 A.','Mrs. Funke Alabi',current_date - 3),
      ((select id from public.students where admission_no='SCD-00015'),'demerit','Late to morning assembly twice this week.','Mr. Sunday Etim',current_date - 2),
      ((select id from public.students where admission_no='SCD-00016'),'merit','Volunteered as lab assistant for the JSS practicals.','Mrs. Hauwa Suleiman',current_date - 1);
  end if;
  if (select count(*) from public.health) < 2 then
    insert into public.health (student_id, complaint, treatment, date, recorded_by) values
      ((select id from public.students where admission_no='SCD-00003'),'Mild headache after break','Rested in sickbay; paracetamol given after phoning guardian. Recovered and returned to class.',current_date - 4,'Sickbay Nurse'),
      ((select id from public.students where admission_no='SCD-00002'),'Graze on the knee during games','Cleaned and dressed. No further attention required.',current_date - 6,'Sickbay Nurse');
  end if;
  if (select count(*) from public.assignments) < 3 then
    insert into public.assignments (title, description, class, subject, due_date, posted_by) values
      ('Argumentative Essay: Social Media','Write a 400-word argumentative essay on "Social media does more good than harm".','SS 2','English Language','2026-08-01', null),
      ('Algebra Worksheet 3','Complete questions 1–15 on linear equations (textbook page 42).','JSS 1','Mathematics','2026-07-28', null),
      ('Cell Structure Diagram','Draw and label a plant cell; list three differences between plant and animal cells.','SS 1','Biology','2026-07-30', null);
  end if;
  if (select count(*) from public.lesson_plans) < 3 then
    insert into public.lesson_plans (teacher, subject, class, week, term, session, objectives, content, resources, status) values
      ('Funke Alabi','Mathematics','SS 2',10,'Third Term','2025/2026','Students will solve simultaneous equations by elimination and substitution.','Introduction (5 min) → worked examples (20 min) → guided practice (15 min) → exit quiz (5 min).','Whiteboard, worksheet pack, graph board','approved'),
      ('Chukwuemeka Nwachukwu','English Language','SS 2',10,'Third Term','2025/2026','Master summary writing: topic sentences and concision.','Passage analysis, group summary, peer review.','New Oxford Secondary English Course','submitted'),
      ('Olumide Ajayi','Biology','SS 1',10,'Third Term','2025/2026','Identify cell organelles and state their functions.','Microscope practical + labelled diagram exercise.','Microscopes, prepared slides','approved');
  end if;
end $$;

-- 21) Survey, leave, visitors, helpdesk, hostel, staff clock ----------------------
do $$
begin
  if not exists (select 1 from public.surveys where title='End-of-Term Parent Satisfaction Survey') then
    insert into public.surveys (title, description, audience, questions, anonymous, is_open, created_by)
    values ('End-of-Term Parent Satisfaction Survey','Two-minute survey — help us serve your children better.','parent',
            '[{"q":"How satisfied are you with communication this term?","type":"rating"},{"q":"Rate the quality of teaching.","type":"rating"},{"q":"Any suggestions?","type":"text"}]'::jsonb, true, true, null);
  end if;
  if (select count(*) from public.leave_requests) = 0 then
    insert into public.leave_requests (staff_id, type, start_date, end_date, days, reason, status)
    values ((select id from public.staff where staff_no='SCD-STF-00002'),'casual','2026-08-05','2026-08-07',3,'Family engagement in Ibadan.','pending');
  end if;
  if (select count(*) from public.visitors) = 0 then
    insert into public.visitors (full_name, phone, purpose, host, check_in, check_out, badge_no) values
      ('Mrs. Titilayo Bello','+234 806 555 0101','Parent — collect report card','Front Desk',now() - interval '3 hours',now() - interval '2 hours','V-0041'),
      ('Engr. S. Okon','+234 806 555 0102','Prospective parent — school tour','Admissions Office',now() - interval '26 hours',now() - interval '25 hours','V-0042'),
      ('WAEC Supervisor','+234 806 555 0103','Official inspection','Principal''s Office',now() - interval '1 day',null,'V-0043');
  end if;
  if (select count(*) from public.helpdesk_tickets) = 0 then
    insert into public.helpdesk_tickets (submitted_by, category, subject, body, priority, status)
    values (coalesce((select id from sc_demo_ids where role='teacher'), (select id from public.profiles where role in ('admin','teacher') order by role limit 1)),'Facilities','Projector in SS 2 A not displaying','The classroom projector powers on but shows no image. Tried HDMI and VGA cables. Needed for Friday revision class.','normal','open');
  end if;
  if (select count(*) from public.hostel_allocations) = 0 then
    insert into public.hostel_allocations (student_id, block, room, bed, status) values
      ((select id from public.students where admission_no='SCD-00004'),'Block A','Room 12','Bed 3','active'),
      ((select id from public.students where admission_no='SCD-00016'),'Block C','Room 04','Bed 1','active');
  end if;
  if (select count(*) from public.staff_clock) = 0 then
    insert into public.staff_clock (staff_id, staff_no, staff_name, status, clock_in, clock_out, date)
    select st.id, st.staff_no, st.full_name,
           case when extract(isodow from d.gs::date) in (1,4) then 'on_time' else 'on_time' end,
           (d.gs::date + make_interval(hours=>7, mins=>(10+extract(isodow from d.gs::date)::int)))::timestamptz,
           (d.gs::date + time '15:45')::timestamptz, d.gs::date
    from public.staff st cross join (select gs from generate_series(current_date - 6, current_date - 1, interval '1 day') gs) d
    where st.staff_no in ('SCD-STF-00001','SCD-STF-00002') and extract(isodow from d.gs::date) <= 5;
  end if;
end $$;

-- 22) Timetable requirements + school shop products + ID cards -------------------
do $$
begin
  insert into public.timetable_requirements (class, subject, teacher, periods_per_week, available_days, is_part_time) values
    ('SS 2','Mathematics','Funke Alabi',5,array['Mon','Tue','Wed','Thu','Fri']::text[],false),
    ('SS 2','English Language','Chukwuemeka Nwachukwu',4,array['Mon','Tue','Wed','Thu','Fri']::text[],false),
    ('SS 2','Physics','Hauwa Suleiman',4,array['Mon','Tue','Thu']::text[],false),
    ('SS 2','Chemistry','Hauwa Suleiman',3,array['Tue','Wed','Fri']::text[],false),
    ('SS 2','Biology','Olumide Ajayi',4,array['Mon','Wed','Fri']::text[],false),
    ('JSS 1','Mathematics','Funke Alabi',5,array['Mon','Tue','Wed','Thu','Fri']::text[],false)
  on conflict (class, subject) do nothing;
  if (select count(*) from public.school_products) = 0 then
    insert into public.school_products (name, description, price, active) values
      ('Exercise Book (80 leaves)','Custom-branded school exercise book','500', true),
      ('School Crested Badge','Iron-on crest for school uniform','1500', true);
  end if;
  if (select count(*) from public.idcards) = 0 then
    insert into public.idcards (person_id, person_type, card_no, qr_data) values
      ((select id from public.students where admission_no='SCD-00014'),'student','SCD-CARD-0001','{"adm":"SCD-00014","name":"Adanna Okafor"}'),
      ((select id from public.staff where staff_no='SCD-STF-00001'),'staff','SCD-CARD-1001','{"stf":"SCD-STF-00001","name":"Funke Alabi"}');
  end if;
end $$;

-- 23) Sample generic-module records (broadcast, cafeteria menu, lost & found, fleet)
do $$
begin
  if not exists (select 1 from public.module_records where module='broadcast') then
    insert into public.module_records (module, title, body, data) values
      ('broadcast','Third Term Results Published','Dear parents, third-term results are now live on the portal. Log in to view report cards and download them as PDF.','{"channel":"whatsapp","audience":"parent"}'::jsonb),
      ('cafeteria','Jollof rice & chicken','Served with steamed vegetables','{"category":"lunch"}'::jsonb),
      ('cafeteria','Fried yam & egg sauce','With fresh fruit juice','{"category":"breakfast"}'::jsonb),
      ('lost_found','HP calculator found in SS 2 A','Found after the mock exam. Collect from the front desk with identification.','{"kind":"found","location":"SS 2 A classroom"}'::jsonb),
      ('fleet_tracking','Route A — Agbado ↔ School','Bus departs 6:30 AM; returns 3:45 PM daily. Driver: Mr. Bassey (+234 806 555 0200).','{"driver":"Mr. Bassey"}'::jsonb);
  end if;
end $$;

select 'School Connect DEMO data installed ✅ — students, staff, parents, fees, attendance, results, report cards, CBT, polls and more.' as status;

-- 24) TASK 4: ENHANCED — populate ALL remaining pages with sample data ------
do $$
begin
  -- E-Resources / Notes
  if not exists (select 1 from public.module_records where module='eresources') then
    insert into public.module_records (module, title, body, data) values
      ('eresources','Mathematics — Simultaneous Equations Notes','Step-by-step guide to solving simultaneous equations by elimination and substitution methods.','{"subject":"Mathematics","class":"SS 2","uploaded_by":"Funke Alabi","file_type":"pdf"}'::jsonb),
      ('eresources','English — Essay Writing Guide','Complete guide to writing argumentative, expository and narrative essays.','{"subject":"English Language","class":"SS 2","uploaded_by":"Chukwuemeka Nwachukwu","file_type":"pdf"}'::jsonb),
      ('eresources','Biology — Cell Structure Revision Notes','Labelled diagrams of plant and animal cells with functions.','{"subject":"Biology","class":"SS 1","uploaded_by":"Olumide Ajayi","file_type":"pdf"}'::jsonb),
      ('eresources','Physics — Newton Laws of Motion','Comprehensive notes with real-life examples and calculation practice.','{"subject":"Physics","class":"SS 2","uploaded_by":"Hauwa Suleiman","file_type":"pdf"}'::jsonb),
      ('eresources','Chemistry — Periodic Table Trends','Study guide covering periodic table groups, periods, and trends.','{"subject":"Chemistry","class":"SS 2","uploaded_by":"Hauwa Suleiman","file_type":"pdf"}'::jsonb);
  end if;

  -- Complaints / Grievances
  if (select count(*) from public.complaints) = 0 then
    insert into public.complaints (submitted_by, type, subject, body, status, urgency) values
      (coalesce((select id from sc_demo_ids where role='parent'),'00000000-0000-0000-0000-000000000000'::uuid),'Academic','Concern about Mathematics performance','My child has been struggling with Mathematics this term. Could we arrange extra coaching?','in_progress','normal'),
      (coalesce((select id from sc_demo_ids where role='parent'),'00000000-0000-0000-0000-000000000000'::uuid),'Facilities','Broken desk in JSS 1 classroom','The desk in row 3 has a broken leg and is unsafe.','submitted','low'),
      (coalesce((select id from sc_demo_ids where role='student'),'00000000-0000-0000-0000-000000000000'::uuid),'General','Request for additional library books','We would appreciate more WAEC preparation materials.','resolved','normal');
  end if;

  -- Alumni
  if (select count(*) from public.alumni) = 0 then
    insert into public.alumni (full_name, graduation_year, last_class, current_occupation, email, phone) values
      ('Adebayo Johnson',2020,'SS 3','Software Engineer at Google','adebayo.j@email.com','+234 801 234 5678'),
      ('Chioma Eze',2019,'SS 3','Medical Doctor — LUTH','chioma.e@email.com','+234 802 345 6789'),
      ('Ibrahim Musa',2021,'SS 3','Law Student — University of Lagos','ibrahim.m@email.com','+234 803 456 7890'),
      ('Funmilayo Adeyemi',2018,'SS 3','Chartered Accountant — PwC','funmilayo.a@email.com','+234 804 567 8901');
  end if;

  -- Inventory / Assets
  if (select count(*) from public.inventory) = 0 then
    insert into public.inventory (item_name, category, quantity, condition, location, last_audit) values
      ('Desktop Computer','ICT Equipment',25,'Good','Computer Lab 1',current_date - 30),
      ('Projector','Teaching Aid',6,'Good','Various classrooms',current_date - 15),
      ('Microscope','Science Equipment',10,'Good','Biology Lab',current_date - 20),
      ('Fire Extinguisher','Safety Equipment',12,'Good','All floors',current_date - 10),
      ('School Bus (Toyota Hiace)','Vehicle',2,'Good','School premises',current_date - 7);
  end if;

  -- Staff Appraisals
  if (select count(*) from public.staff_appraisals) = 0 then
    insert into public.staff_appraisals (staff_name, appraiser, period, punctuality, teaching_quality, student_results, teamwork, conduct, total_score, recommendation, comments) values
      ('Funke Alabi','Mrs. Grace Obi','2025/2026 Third Term',9,9,8,9,10,'45/50 — Outstanding','commend','Consistently strong lesson delivery, punctuality and learner outcomes.'),
      ('Chukwuemeka Nwachukwu','Mrs. Grace Obi','2025/2026 Third Term',8,7,7,8,8,'38/50 — Very Good','retain','Strong teamwork; next-term target is more differentiated classroom assessment.');
  end if;

  -- Certificates
  if (select count(*) from public.certificates) = 0 then
    insert into public.certificates (student_id, type, serial_no, issued_on, signed_by) values
      ((select id from public.students where admission_no='SCD-00014'),'testimonial','CERT-2026-001',current_date - 10,'Mrs. Grace Obi — Principal'),
      ((select id from public.students where admission_no='SCD-00015'),'merit','CERT-2026-002',current_date - 5,'Mrs. Grace Obi — Principal');
  end if;

  -- Parent Meetings (generic module_records is the live table used by CRUD)
  if not exists (select 1 from public.module_records where module='parent_meeting') then
    insert into public.module_records (module, title, ref_date, body, status, data) values
      ('parent_meeting','PTA General Meeting — Third Term','2026-07-18','End-of-term PTA meeting to discuss results and next-term plans.','completed','{"venue":"School Hall","attendees":"All parents"}'::jsonb),
      ('parent_meeting','Open Day — Prospective Parents','2026-08-15','School tour and meet-the-teachers event.','scheduled','{"venue":"Main Campus","attendees":"Prospective parents"}'::jsonb),
      ('parent_meeting','Career Day','2026-09-20','Annual career guidance day with invited professionals.','scheduled','{"venue":"School Hall","attendees":"SS 1–3 parents"}'::jsonb);
  end if;

  -- Career Counseling (generic module_records is the live table used by CRUD)
  if not exists (select 1 from public.module_records where module='career_counseling') then
    insert into public.module_records (module, title, ref_date, body, status, data) values
      ('career_counseling','Adanna Okafor — Medicine pathway','2026-07-10','Interested in Medicine. Advised to focus on Biology, Chemistry and Physics.','closed','{"student":"Adanna Okafor","counsellor":"Mrs. Grace Obi"}'::jsonb),
      ('career_counseling','Ikenna Okoro — Engineering pathway','2026-07-12','Strong in Mathematics and interested in Engineering. Advised to take Further Mathematics.','ongoing','{"student":"Ikenna Okoro","counsellor":"Mrs. Grace Obi"}'::jsonb);
  end if;

  -- Donations
  if (select count(*) from public.donations) = 0 then
    insert into public.donations (campaign, donor_name, donor_email, amount, method, note, anonymous) values
      ('Library Renovation','Chief and Mrs. Adeyemi','adebayo.family@example.com',500000,'bank transfer','Library renovation fund — acknowledged by the school.',false),
      ('Science Laboratory','Old Students Association (Class of 2015)','alumni2015@example.com',1000000,'bank transfer','Science laboratory equipment donation.',false),
      ('Scholarship Fund','Anonymous','',200000,'cash','Scholarship support for two learners.',true);
  end if;

  -- Financial Aid (generic module_records is the live table used by CRUD)
  if not exists (select 1 from public.module_records where module='financial_aid') then
    insert into public.module_records (module, title, amount, body, status, data) values
      ('financial_aid','Fatima Usman — Merit Scholarship',50000,'Third Term 2025/2026 scholarship award.','approved','{"student":"Fatima Usman","type":"scholarship","term":"Third Term","session":"2025/2026"}'::jsonb),
      ('financial_aid','Tunde Bakare — Needs Bursary',30000,'Third Term 2025/2026 bursary support.','approved','{"student":"Tunde Bakare","type":"bursary","term":"Third Term","session":"2025/2026"}'::jsonb);
  end if;

  -- Gamification (generic module_records is the live table used by CRUD)
  if not exists (select 1 from public.module_records where module='gamification') then
    insert into public.module_records (module, title, ref_date, body, data) values
      ('gamification','Adanna Okafor — Quiz Champion',current_date - 5,'Won the inter-class science quiz.','{"student":"Adanna Okafor","points":50,"badge":"Quiz Champion"}'::jsonb),
      ('gamification','Ikenna Okoro — Attendance Star',current_date - 1,'Perfect attendance this month.','{"student":"Ikenna Okoro","points":30,"badge":"Attendance Star"}'::jsonb),
      ('gamification','Fatima Usman — Assignment Hero',current_date - 3,'Submitted every assignment on time.','{"student":"Fatima Usman","points":20,"badge":"Assignment Hero"}'::jsonb);
  end if;

  -- Substitutions
  if (select count(*) from public.substitutions) = 0 then
    insert into public.substitutions (date, period, class, absent_teacher, substitute_teacher, reason) values
      (current_date - 2,'3rd Period','SS 2','Funke Alabi','Chukwuemeka Nwachukwu','Medical appointment'),
      (current_date - 1,'1st Period','JSS 1','Olumide Ajayi','Hauwa Suleiman','Personal leave');
  end if;
end $$;

select 'School Connect DEMO ENHANCED data installed - all pages populated.' as status;

-- 25) Library books and book requests
do $$
begin
  if (select count(*) from public.library) = 0 then
    insert into public.library (title, author, isbn, category, copies, lent, drive_link) values
      ('New Oxford Secondary English Course','Adebayo A. et al','978-019-823-456','English',12,4,'https://drive.google.com/'),
      ('Essential Mathematics for SS','A.J.S. Oluwasanmi','978-978-123-789','Mathematics',10,5,'https://drive.google.com/'),
      ('Modern Biology for SS','S.T. Ramalingam','978-978-456-123','Science',10,4,'https://drive.google.com/'),
      ('Comprehensive Chemistry','O. Adeniji','978-978-789-456','Science',8,4,'https://drive.google.com/'),
      ('Things Fall Apart','Chinua Achebe','978-043-527-891','Literature',15,5,'https://drive.google.com/'),
      ('Purple Hibiscus','Chimamanda N. Adichie','978-000-718-234','Literature',10,3,'https://drive.google.com/');
  end if;
  if not exists (select 1 from public.module_records where module='book_request') then
    insert into public.module_records (module, title, ref_date, status, body, data) values
      ('book_request','Advanced Calculus for SS 3',current_date - 3,'pending','Requested by Adanna Okafor for advanced revision.','{"student":"Adanna Okafor","type":"borrow"}'::jsonb),
      ('book_request','Past WAEC Questions — Physics',current_date - 7,'approved','Approved request for Ikenna Okoro.','{"student":"Ikenna Okoro","type":"borrow"}'::jsonb);
  end if;
end $$;

-- 26) COMPLETE PAGE-COVERAGE PACK — every operational page gets sample rows --
do $$
declare
  adanna uuid := (select id from public.students where admission_no='SCD-00014');
  ikenna uuid := (select id from public.students where admission_no='SCD-00015');
  funke uuid := (select id from public.staff where staff_no='SCD-STF-00001');
  admin_id uuid := (select id from sc_demo_ids where role='admin');
  teacher_id uuid := (select id from sc_demo_ids where role='teacher');
  parent_id uuid := (select id from sc_demo_ids where role='parent');
  student_user uuid := (select id from sc_demo_ids where role='student');
begin
  -- Real inbox/messages rows (specialised pages read public.messages).
  if (select count(*) from public.messages)=0 and admin_id is not null and coalesce(parent_id,student_user) is not null then
    insert into public.messages (from_id,to_id,body,read,thread_id) values
      (admin_id,coalesce(parent_id,student_user),'Welcome to the School Connect demonstration portal. Your linked learner records are ready to explore.',true,'d9000000-0000-4000-8000-000000000001'),
      (coalesce(parent_id,student_user),admin_id,'Thank you. I can see the report card, fees and attendance pages.',false,'d9000000-0000-4000-8000-000000000001');
  end if;

  if (select count(*) from public.notifications)=0 then
    insert into public.notifications (title,body,url,audience,priority,channels) values
      ('Third-term reports are available','Published report cards can now be viewed and printed.','report-cards.html','all','high','["inapp","push"]'::jsonb),
      ('Demo UTME is open','Use code DEMO-UTME to experience English and Mathematics subject tabs.','cbt-exam.html?code=DEMO-UTME','student','normal','["inapp"]'::jsonb),
      ('PTA meeting reminder','The PTA meeting starts at 10:00 AM in the school hall.','events.html','parent','normal','["inapp","email"]'::jsonb);
  end if;

  if (select count(*) from public.finance_entries)=0 then
    insert into public.finance_entries (type,category,amount,description,date,recorded_by) values
      ('income','School Fees',1850000,'Third-term school-fee collections',current_date-6,coalesce(admin_id,teacher_id)),
      ('expense','Utilities',185000,'Electricity, internet and water',current_date-4,coalesce(admin_id,teacher_id)),
      ('expense','Laboratory',240000,'Chemicals and practical consumables',current_date-2,coalesce(admin_id,teacher_id));
  end if;

  if (select count(*) from public.payroll)=0 then
    insert into public.payroll (staff_id,staff_name,month,year,basic,allowances,bonus,overtime,tax,pension,loan_deduction,other_deductions,net_pay,method,status) values
      (funke,'Funke Alabi','July',2026,180000,25000,10000,5000,12000,14400,0,0,193600,'bank transfer','paid'),
      ((select id from public.staff where staff_no='SCD-STF-00002'),'Chukwuemeka Nwachukwu','July',2026,170000,20000,5000,0,11000,13600,0,0,170400,'bank transfer','approved');
  end if;
  if (select count(*) from public.staff_loans)=0 then
    insert into public.staff_loans (staff_name,loan_type,principal,monthly_repayment,months,amount_repaid,date_taken,status,notes) values
      ('Chukwuemeka Nwachukwu','salary advance',120000,20000,6,40000,current_date-65,'active','Approved emergency salary advance.');
  end if;
  if (select count(*) from public.staff_bonus)=0 then
    insert into public.staff_bonus (staff_name,bonus_type,amount,reason,award_date,status) values
      ('Funke Alabi','performance',25000,'Outstanding SS 2 Mathematics results.',current_date-12,'approved'),
      ('Ikechukwu Obasi','performance',20000,'Successful CBT laboratory upgrade.',current_date-10,'paid');
  end if;

  if (select count(*) from public.scheme_of_work)=0 then
    insert into public.scheme_of_work (subject,class,term,session,week,topic,status,covered_at,teacher,confirmed) values
      ('Mathematics','SS 2','Third Term','2025/2026',10,'Simultaneous Equations','covered',current_date-8,'Funke Alabi',true),
      ('English Language','SS 2','Third Term','2025/2026',10,'Summary Writing','covered',current_date-7,'Chukwuemeka Nwachukwu',true),
      ('Physics','SS 2','Third Term','2025/2026',10,'Simple Machines','pending',null,'Hauwa Suleiman',false);
  end if;
  if (select count(*) from public.timetable)=0 then
    insert into public.timetable (class,day,period,subject,teacher,room,session,term) values
      ('SS 2','Monday','1','Mathematics','Funke Alabi','SS2-A','2025/2026','Third Term'),
      ('SS 2','Monday','2','English Language','Chukwuemeka Nwachukwu','SS2-A','2025/2026','Third Term'),
      ('SS 2','Monday','3','Physics','Hauwa Suleiman','Physics Lab','2025/2026','Third Term'),
      ('SS 2','Tuesday','1','Chemistry','Hauwa Suleiman','Chemistry Lab','2025/2026','Third Term'),
      ('SS 2','Tuesday','2','Biology','Olumide Ajayi','Biology Lab','2025/2026','Third Term');
  end if;

  if (select count(*) from public.transport)=0 then
    insert into public.transport (route_name,driver,vehicle_no,capacity,assigned_students) values
      ('Agbado Route','Mr. Bassey','SCD BUS 01',28,array[adanna,ikenna]::uuid[]),
      ('Ikeja Route','Mr. Lawal','SCD BUS 02',24,'{}'::uuid[]);
  end if;
  if (select count(*) from public.behaviour_points)=0 then
    insert into public.behaviour_points (student_id,student_name,points,reason,badge,awarded_by) values
      (adanna,'Adanna Okafor',50,'Won the inter-class science quiz','Quiz Champion',teacher_id),
      (ikenna,'Ikenna Okoro',30,'Perfect monthly attendance','Attendance Star',teacher_id);
  end if;
  if (select count(*) from public.support_plans)=0 then
    insert into public.support_plans (student_id,need_type,intervention,goal,review_date,outcome,status) values
      (ikenna,'Mathematics enrichment','Weekly advanced problem-solving clinic','Reach 80% in Further Mathematics',current_date+30,'Progressing well','active');
  end if;
  if (select count(*) from public.promotions)=0 then
    insert into public.promotions (student_id,student_name,from_class,to_class,action,session,term,approved_by,average,status) values
      (adanna,'Adanna Okafor','SS 2','SS 3','promote','2025/2026','Third Term',admin_id,78.4,'approved'),
      (ikenna,'Ikenna Okoro','SS 2','SS 3','promote','2025/2026','Third Term',admin_id,72.1,'approved');
  end if;
  if (select count(*) from public.birthdays)=0 then
    insert into public.birthdays (person_name,type,date,class,student_ref) values
      ('Adanna Okafor','student','2011-05-26','SS 2',adanna),
      ('Ikenna Okoro','student','2011-08-13','SS 2',ikenna);
  end if;

  if (select count(*) from public.digital_library)=0 then
    insert into public.digital_library (title,author,subject,class,read_link,teacher,instructions,has_quiz,questions,max_score,due_date) values
      ('Algebra Revision Workbook','HMG Academy Mathematics Unit','Mathematics','SS 2','https://drive.google.com/','Funke Alabi','Read chapters 1–3 and complete the quiz.',true,'[{"q":"Solve x+3=9","options":["4","5","6","7"],"answer":"C"}]'::jsonb,10,current_date+7),
      ('Effective Summary Writing','Languages Department','English Language','SS 2','https://drive.google.com/','Chukwuemeka Nwachukwu','Read the guide before Friday.',false,'[]'::jsonb,0,current_date+5);
  end if;
  if (select count(*) from public.reading_scores)=0 then
    insert into public.reading_scores (student_name,subject,class,book_id,score,max_score,source,pushed_to_results) values
      ('Adanna Okafor','Mathematics','SS 2',(select id from public.digital_library order by created_at limit 1),8,10,'digital_library',false);
  end if;

  if (select count(*) from public.menu_planner)=0 then
    insert into public.menu_planner (week_start,day,meal,description,allergens) values
      (date_trunc('week',current_date)::date,'Monday','Lunch','Jollof rice, grilled chicken and vegetables','None declared'),
      (date_trunc('week',current_date)::date,'Tuesday','Lunch','Beans, plantain and fruit','Legumes');
  end if;
  if (select count(*) from public.survey_responses)=0 and exists(select 1 from public.surveys) then
    insert into public.survey_responses (survey_id,respondent,answers) values
      ((select id from public.surveys order by created_at limit 1),parent_id,'{"q0":{"value":"5"},"q1":{"value":"4"},"q2":"Excellent communication; add more weekend revision."}'::jsonb);
  end if;

  if (select count(*) from public.payment_intents)=0 then
    insert into public.payment_intents (student_id,amount,provider,reference,checkout_url,status) values
      (adanna,225000,'bank_transfer','SCD-DEMO-PAY-001','https://example.com/demo-payment','paid'),
      (ikenna,225000,'paystack','SCD-DEMO-PAY-002','https://example.com/demo-payment','pending');
  end if;

  if (select count(*) from public.admissions)=0 then
    insert into public.admissions (full_name,dob,gender,parent_name,parent_email,parent_phone,applying_for_class,status,notes,data) values
      ('David Adekunle','2015-09-14','Male','Mrs. Yetunde Adekunle','yetunde@example.com','+234 802 555 0101','JSS 1','reviewing','Entrance interview scheduled.','{"nationality":"Nigerian","state_origin":"Ogun","entry_session":"2026/2027"}'::jsonb),
      ('Zara Mohammed','2016-03-22','Female','Mr. Musa Mohammed','musa@example.com','+234 802 555 0102','Primary 6','accepted','Passed entrance assessment.','{"nationality":"Nigerian","state_origin":"Kano","entry_session":"2026/2027"}'::jsonb);
  end if;
  if (select count(*) from public.admission_links)=0 then
    insert into public.admission_links (label,title,applying_for_class,class_applied,session,exam_code,expires_at,notes,active,created_by) values
      ('2026/2027 JSS 1 Intake','JSS 1 Admission Form','JSS 1','JSS 1','2026/2027','DEMO-MATH1',now()+interval '60 days','Public demonstration admission link.',true,admin_id);
  end if;
  if (select count(*) from public.exam_registrations)=0 then
    insert into public.exam_registrations (school_id,student_id,student_name,admission_no,class,exam_type,exam_year,status,payload) values
      ((select school_id from public.school_settings where id=1),adanna,'Adanna Okafor','SCD-00014','SS 2','WAEC',2027,'approved','{"subjects":["English","Mathematics","Physics","Chemistry","Biology"]}'::jsonb),
      ((select school_id from public.school_settings where id=1),ikenna,'Ikenna Okoro','SCD-00015','SS 2','JAMB',2027,'pending','{"subjects":["English","Mathematics","Physics","Chemistry"]}'::jsonb);
  end if;

  if (select count(*) from public.academic_print_records)=0 then
    insert into public.academic_print_records (record_type,title,class,subject,term,session,generated_by,data) values
      ('student_record_card','Adanna Okafor — Third Term Report','SS 2','All Subjects','Third Term','2025/2026',teacher_id,'{"student":"Adanna Okafor","published":true}'::jsonb),
      ('class_broadsheet','SS 2 Third Term Broadsheet','SS 2','All Subjects','Third Term','2025/2026',teacher_id,'{"students":3,"subjects":5}'::jsonb),
      ('subject_broadsheet','SS 2 Mathematics Scoresheet','SS 2','Mathematics','Third Term','2025/2026',teacher_id,'{"teacher":"Funke Alabi"}'::jsonb);
  end if;
  if (select count(*) from public.role_status_log)=0 and student_user is not null then
    insert into public.role_status_log (person_id,person_name,person_email,previous_role,new_role,previous_status,new_status,action,reason,changed_by,changed_by_name) values
      (student_user,'Adanna Okafor','student@scdemo.school','student','student','pending','approved','approve','Demo account approved for portal access.',admin_id,'Demo Administrator');
  end if;

  -- Generic CRUD modules all use module_records. One insert statement makes the
  -- population contract explicit and keeps each public demo page non-empty.
  insert into public.module_records (module,title,body,status,audience,ref_date,amount,data)
  select x.module,x.title,x.body,x.status,x.audience,x.ref_date,x.amount::numeric,x.data
  from (values
    ('messages','Welcome message','Your School Connect demo inbox is active.','sent','all',current_date,null,'{"channel":"inapp"}'::jsonb),
    ('inbox','Parent enquiry thread','A parent asked about next-term resumption and received a reply.','open','private',current_date,null,'{"from":"Mr. Adewale Okafor","to":"Admin"}'::jsonb),
    ('reports','Monthly Management Summary','Enrollment, fees, attendance and academic KPIs compiled for management.','ready','staff',current_date,null,'{"format":"dashboard","period":"July 2026"}'::jsonb),
    ('lms','SS 2 Mathematics Revision Course','Five lessons, two assignments and a revision quiz.','published','student',current_date,null,'{"teacher":"Funke Alabi","class":"SS 2"}'::jsonb),
    ('front_desk','Visitor pass V-0043','WAEC supervisor checked in for an official inspection.','checked_in','staff',current_date,null,'{"visitor":"WAEC Supervisor","badge":"V-0043"}'::jsonb),
    ('document_builder','SS 2 Fee Clearance Letter','Official fee-clearance letter prepared for Adanna Okafor.','final','private',current_date,null,'{"student":"Adanna Okafor","type":"fee clearance"}'::jsonb),
    ('facility_booking','Science Laboratory Booking','SS 2 Chemistry practical reservation.','approved','staff',current_date+2,null,'{"time":"10:00","bookedby":"Hauwa Suleiman"}'::jsonb),
    ('compliance','Annual Fire Safety Inspection','Fire extinguishers and evacuation routes checked.','passed','staff',current_date-10,null,'{"category":"inspection"}'::jsonb),
    ('rubrics','Science Practical Rubric','Accuracy, method, observation and safety — four-level scale.','active','staff',current_date,null,'{"subject":"Chemistry","class":"SS 2","scale":"1-4"}'::jsonb),
    ('transcripts','Adanna Okafor — Academic Transcript','Cumulative 2024–2026 academic record prepared.','final','private',current_date,null,'{"student":"Adanna Okafor","gpa":"4.2"}'::jsonb),
    ('transfer_cert','Transfer Certificate SCD/TC/2026/004','Good conduct; leaving due to family relocation.','issued','private',current_date,null,'{"student":"Sample Learner","last_class":"JSS 3"}'::jsonb),
    ('counselling','Examination Anxiety Support','Two-session wellbeing plan with breathing and study strategies.','ongoing','private',current_date-3,null,'{"student":"Ikenna Okoro","counsellor":"Mrs. Grace Obi"}'::jsonb)
  ) as x(module,title,body,status,audience,ref_date,amount,data)
  where not exists (select 1 from public.module_records m where m.module=x.module and m.title=x.title);
end $$;

select 'School Connect DEMO V5 page-coverage pack installed — every operational module now has interconnected sample data ✅' as status;

-- V5.4 beginning-of-term physical metrics (synthetic demo values).
insert into public.student_term_metrics(student_id,student_id_ref,student_name,class,term,session,height_cm,weight_kg,blood_pressure,vision,blood_group,genotype,medical_note,measured_on)
select s.id,s.admission_no,s.full_name,s.class,'Third Term','2025/2026',
  150+(substring(s.admission_no from 5)::int%18),42+(substring(s.admission_no from 5)::int%20),
  case when substring(s.admission_no from 5)::int%2=0 then'110/70'else'108/68'end,'Normal','O+','AA','Synthetic demonstration measurement','2026-04-28'
from public.students s where s.admission_no in('SCD-00014','SCD-00015','SCD-00016')
on conflict(student_id_ref,student_name,class,term,session)do update set height_cm=excluded.height_cm,weight_kg=excluded.weight_kg,blood_pressure=excluded.blood_pressure,vision=excluded.vision,blood_group=excluded.blood_group,genotype=excluded.genotype,measured_on=excluded.measured_on,updated_at=now();
select 'School Connect demo V5.4 metrics installed ✅'as status;

-- V5.6 demo coverage completion for specialised/enterprise sections.
do $$
declare admin_id uuid:=(select id from sc_demo_ids where role='admin');teacher_id uuid:=(select id from sc_demo_ids where role='teacher');student_user uuid:=(select id from sc_demo_ids where role='student');adanna uuid:=(select id from public.students where admission_no='SCD-00014');course_id uuid;v_exam_id uuid:=(select ce.id from public.cbt_exams ce where ce.code='DEMO-UTME');begin
 update public.schools set name='School Connect Demonstration College',short_name='SCD',admission_acronym='SCD',motto='A fully simulated school — explore every feature',address='HMG Demo Campus, Lagos, Nigeria',phone='+234 810 086 6322',email='buildingmyictcareer@gmail.com' where id=(select school_id from public.school_settings where id=1);
 if(select count(*)from public.eresources)=0 then insert into public.eresources(title,description,subject,class,term,drive_link,uploaded_by)values('SS 2 Mathematics Revision Pack','Worked examples and practice questions for simultaneous equations.','Mathematics','SS 2','Third Term','https://drive.google.com/',teacher_id),('English Summary-Writing Notes','Passages, rules and model summaries.','English Language','SS 2','Third Term','https://drive.google.com/',teacher_id),('JSS 1 Basic Science Video','Matter and its properties revision link.','Basic Science','JSS 1','Third Term','https://example.com/demo-resource',teacher_id);end if;
 if(select count(*)from public.attendance_checkins)=0 then insert into public.attendance_checkins(student_id_ref,student_name,class,checkin_at,method,device,recorded_by)select s.admission_no,s.full_name,s.class,(current_date-1+time '07:20')::timestamptz,'qr','Demo gate tablet',teacher_id from public.students s where s.admission_no in('SCD-00014','SCD-00015','SCD-00016');end if;
 if v_exam_id is not null then insert into public.cbt_roster(exam_id,student_id_ref,full_name,class)select v_exam_id,st.admission_no,st.full_name,st.class from public.students st where st.class='SS 2'on conflict do nothing;end if;
 if(select count(*)from public.admission_letters)=0 and v_exam_id is not null then insert into public.admission_letters(candidate_name,candidate_class,exam_id,result_id,percent,decision,letter_ref,session,notes)select cr.student_name,cr.student_class,cr.exam_id,cr.id,cr.percent,case when cr.percent>=50 then'admitted'else'waitlist'end,'SCD/ADM/2026/'||lpad(row_number()over()::text,3,'0'),'2026/2027','Synthetic demo admission decision'from public.cbt_results cr where cr.exam_id=v_exam_id limit 3;end if;
 if(select count(*)from public.certificate_designs)=0 then insert into public.certificate_designs(name,title,primary_color,accent_color,font,layout,body_text,signatory,border_style)values('Demo Merit Certificate','CERTIFICATE OF MERIT','#0506ae','#964eec','Georgia','classic','is recognised for excellent academic performance and character.','Mrs. Grace Obi — Principal','double'),('Demo Completion Certificate','CERTIFICATE OF COMPLETION','#0f766e','#d4af37','Georgia','modern','has successfully completed the prescribed programme.','Head of School','solid');end if;
 insert into public.teacher_availability(teacher,is_part_time,available_days,notes)values('Funke Alabi',false,array['Monday','Tuesday','Wednesday','Thursday','Friday'],'Available throughout the school week'),('Hauwa Suleiman',true,array['Monday','Tuesday','Thursday'],'Part-time Physics/Chemistry teacher')on conflict(teacher)do update set is_part_time=excluded.is_part_time,available_days=excluded.available_days,notes=excluded.notes;
 if(select count(*)from public.timetable_config)=0 then insert into public.timetable_config(class,period_no,label,start_time,end_time,is_break,position)values('ALL',1,'Period 1','08:00','08:40',false,1),('ALL',2,'Period 2','08:40','09:20',false,2),('ALL',2.1,'Short Break','09:20','09:35',true,3),('ALL',3,'Period 3','09:35','10:15',false,4),('ALL',4,'Period 4','10:15','10:55',false,5),('ALL',4.2,'Long Break','10:55','11:25',true,6);end if;
 if(select count(*)from public.timetable_runs)=0 then insert into public.timetable_runs(class,session,term,generated_at,conflicts,notes)values('SS 2','2025/2026','Third Term',now()-interval'2 days',0,'Demo conflict-free run: 25 periods placed');end if;
 if(select count(*)from public.punctuality_awards)=0 then insert into public.punctuality_awards(student_id,student_id_ref,student_name,class,date,checkin_at,checkout_at,points,rule)select s.id,s.admission_no,s.full_name,s.class,current_date-1,(current_date-1+time'07:20')::timestamptz,(current_date-1+time'15:30')::timestamptz,2,'full'from public.students s where s.admission_no in('SCD-00014','SCD-00015','SCD-00016')on conflict(student_id,date)do nothing;end if;
 if(select count(*)from public.activity_log)=0 then insert into public.activity_log(actor_id,actor_email,action,entity,entity_id,details,created_at)values(admin_id,'admin@scdemo.school','create','students','SCD-00014','{"summary":"Created demo learner"}'::jsonb,now()-interval'5 days'),(teacher_id,'teacher@scdemo.school','bulk-push-cbt','report_scores','DEMO-UTME','{"rows":6}'::jsonb,now()-interval'1 day');end if;
 if(select count(*)from public.fee_structures)=0 then insert into public.fee_structures(class,term,session,amount,description,due_date)values('SS 2','Third Term','2025/2026',225000,'Tuition, assessment, development and digital-learning fees','2026-05-15'),('JSS 1','Third Term','2025/2026',180000,'Tuition and assessment fees','2026-05-15');end if;
 if(select count(*)from public.reports)=0 then insert into public.reports(title,type,payload,generated_by)values('Third Term Management Summary','management','{"students":18,"attendance_rate":92,"fee_signal":"improving"}'::jsonb,admin_id);end if;
 if(select count(*)from public.lms_courses)=0 then insert into public.lms_courses(title,description,subject,class,teacher,cover_url)values('SS 2 Mathematics Revision','Five structured revision lessons for third-term examination.','Mathematics','SS 2','Funke Alabi','https://example.com/course-cover')returning id into course_id;else select id into course_id from public.lms_courses order by created_at limit 1;end if;
 if course_id is not null and(select count(*)from public.lms_lessons)=0 then insert into public.lms_lessons(course_id,title,content,video_url,resource_link,position)values(course_id,'Simultaneous Equations','Elimination and substitution with worked examples.','https://example.com/demo-video','https://drive.google.com/',1),(course_id,'Revision Quiz','Ten mixed algebra questions.','','https://drive.google.com/',2);end if;
 if(select count(*)from public.lms_submissions)=0 and adanna is not null then insert into public.lms_submissions(assignment_id,student_id,submission_link,note,score,feedback,status)values((select id from public.assignments order by created_at limit 1),adanna,'https://drive.google.com/','Synthetic demo submission',84,'Clear argument and good evidence.','graded');end if;
 if admin_id is not null then insert into public.security_prefs(user_id,two_factor,recovery_email,updated_at)values(admin_id,true,'admin-recovery@scdemo.school',now())on conflict(user_id)do update set two_factor=excluded.two_factor,recovery_email=excluded.recovery_email,updated_at=now();end if;
 if(select count(*)from public.login_audit)=0 and admin_id is not null then insert into public.login_audit(user_id,email,event,ip,user_agent,created_at)values(admin_id,'admin@scdemo.school','login','127.0.0.1','Synthetic demo browser',now()-interval'3 hours');end if;
 insert into public.i18n_strings(lang,key,value)values('en','dashboard.welcome','Welcome to the School Connect demonstration portal'),('yo','dashboard.welcome','Ẹ káàbọ̀ sí ojú-òpó àpẹẹrẹ School Connect')on conflict(lang,key)do update set value=excluded.value;
end$$;
select 'School Connect demo V5.6 specialised page coverage installed ✅'as status;

-- V5.7 signatories, editable public campaign and educator comment bands.
update school_settings set principal_name='Mrs. Grace Obi',proprietor_name='Dr. Samuel Adeyemi',examination_officer_name='Mr. Chinedu Okafor',principal_signature_bg_removed=true,proprietor_signature_bg_removed=true,examination_officer_signature_bg_removed=true where id=1;
insert into report_comment_bands(label,min_percent,max_percent,class,term,session,class_teacher_comment,principal_comment,priority)select*from(values('Outstanding',80::numeric,100::numeric,'*','*','*','[NAME] has demonstrated outstanding mastery and exemplary study habits. Maintain this excellent standard.','An exceptional [GRADE] performance at [PERCENT]. Continue to pursue excellence.',60),('Very Good',70,79.99,'*','*','*','[NAME] produced a very good performance. Greater consistency can move this result to distinction level.','A strong performance. Keep building accuracy and independent study habits.',50),('Good',60,69.99,'*','*','*','[NAME] made good progress. Regular revision and careful assignment completion will strengthen weaker areas.','A creditable result. Act on subject feedback and target a higher band next term.',40),('Satisfactory',50,59.99,'*','*','*','[NAME] achieved a satisfactory result but needs a structured study timetable and active participation.','A fair foundation. Home and school should support clear weekly improvement targets.',30),('Developing',40,49.99,'*','*','*','[NAME] requires focused support in core subjects, regular attendance and monitored practice.','Improvement is required. A teacher-parent support plan is recommended.',20),('Priority Support',0,39.99,'*','*','*','[NAME] requires immediate diagnostic review, remedial teaching and close home-school follow-up.','Performance is below expectation. Arrange an intervention meeting and track agreed actions.',10))x(label,min_percent,max_percent,class,term,session,class_teacher_comment,principal_comment,priority)where not exists(select 1 from report_comment_bands b where b.label=x.label and b.class='*');
insert into exam_registration_links(token,title,intro,exam_types,session,term,registration_deadline,exam_date,venue,fee_note,requirements,instructions,contact_name,contact_phone,contact_email,consent_text,success_message,active,created_by)select'DEMO-EXAM-2026','2026/2027 Public Examination Registration','Complete this official demonstration form carefully.',array['WAEC SSCE (School)','NECO SSCE (School)','UTME (JAMB)','Common Entrance (NCEE)'],'2026/2027','First Term',now()+interval'60 days',current_date+75,'School Connect Demo Examination Centre','Confirm fees with the examination office.','Passport photograph, NIN and examination-specific documents.','Use official names exactly as shown on identity documents.','Mr. Chinedu Okafor','+234 810 086 6322','buildingmyictcareer@gmail.com','I certify that this information is accurate.','Registration received. Keep your reference.',true,(select id from sc_demo_ids where role='admin')where not exists(select 1 from exam_registration_links where token='DEMO-EXAM-2026');
select 'School Connect demo V5.7 professional data installed ✅'as status;

-- ============================================================
-- V6.5 DEMO ENRICHMENT — richer sample data on EVERY page
-- (idempotent guards per table; safe to re-run; demo ONLY)
-- ============================================================
do $$
declare
  admin_id uuid:=(select id from sc_demo_ids where role='admin');
  teacher_id uuid:=(select id from sc_demo_ids where role='teacher');
  parent_id uuid:=(select id from sc_demo_ids where role='parent');
  student_user uuid:=(select id from sc_demo_ids where role='student');
  adanna uuid:=(select id from public.students where admission_no='SCD-00014');
  bello uuid:=(select id from public.students where admission_no='SCD-00015');
  chiamaka uuid:=(select id from public.students where admission_no='SCD-00016');
  st3 uuid;
begin
  select id into st3 from public.students where admission_no='SCD-00001';

  -- Payroll: full month run for several staff (page previously looked empty)
  if (select count(*) from public.payroll) < 4 then
    insert into public.payroll (staff_id,staff_name,month,year,basic,allowances,bonus,overtime,tax,pension,loan_deduction,other_deductions,net_pay,method,status)
    select s.id, s.full_name,'June',2026,
           150000+(row_number()over())*10000, 20000, 0, 0, 10000, 12000, 0, 0,
           148000+(row_number()over())*10000,'bank transfer','paid'
      from public.staff s limit 4;
  end if;

  -- Inventory: a believable asset register
  if (select count(*) from public.inventory) < 6 then
    insert into public.inventory (item_name,category,asset_tag,quantity,location,condition,unit_cost,last_audit,next_audit) values
      ('HP ProBook laptop','ICT','SCD-ICT-001',6,'ICT Laboratory','good',420000,'2026-05-02','2026-11-02'),
      ('Epson projector','ICT','SCD-ICT-002',2,'Staff Room','good',250000,'2026-05-02','2026-11-02'),
      ('Science microscope','Laboratory','SCD-LAB-014',8,'Science Lab','fair',95000,'2026-04-20','2026-10-20'),
      ('Student desk & chair set','Furniture','SCD-FUR-101',120,'Classrooms','good',18000,'2026-03-15','2027-03-15'),
      ('55-seater school bus','Transport','SCD-TRN-001',1,'Car park','good',28000000,'2026-06-01','2026-12-01'),
      ('Standby generator 20KVA','Facilities','SCD-FAC-003',1,'Generator house','needs service',3500000,'2026-06-10','2026-09-10');
  end if;

  -- Admission links: an active public application link + one closed
  if (select count(*) from public.admission_links) < 2 then
    insert into public.admission_links (label,applying_for_class,session,active) values
      ('2026/2027 JSS 1 Entrance Intake','JSS 1','2026/2027',true),
      ('2025/2026 SS 1 Transfer Window (closed)','SS 1','2025/2026',false);
  end if;

  -- Messages: a fuller two-way thread set
  if (select count(*) from public.messages) < 5 and admin_id is not null then
    insert into public.messages (from_id,to_id,body,read,thread_id) values
      (teacher_id,parent_id,'Good afternoon. Adanna performed excellently in the Mathematics revision test — 17/20. Keep encouraging her.',true,'d9000000-0000-4000-8000-000000000002'),
      (parent_id,teacher_id,'Thank you for the update! We will keep supporting her at home.',false,'d9000000-0000-4000-8000-000000000002'),
      (student_user,teacher_id,'Good evening ma. Please can you re-share the summary-writing notes link?',false,'d9000000-0000-4000-8000-000000000003'),
      (admin_id,teacher_id,'Reminder: submit third-term scheme-of-work coverage before Friday.',true,'d9000000-0000-4000-8000-000000000004');
  end if;

  -- Assignments: one per level with due dates and links
  if (select count(*) from public.assignments) < 4 then
    insert into public.assignments (title,description,class,subject,due_date,posted_by,drive_link) values
      ('Essay: My Role Model','Write a 400-word argumentative essay. Submit as a Drive link.','SS 2','English Language',current_date+5,teacher_id,'https://drive.google.com/'),
      ('Simultaneous Equations Worksheet','Questions 1–15, elimination and substitution methods.','SS 2','Mathematics',current_date+3,teacher_id,'https://drive.google.com/'),
      ('Basic Science: States of Matter Poster','Draw and label the three states of matter with examples.','JSS 1','Basic Science',current_date+7,teacher_id,''),
      ('Civic Education Project','Group project: rights and duties of a citizen (submit one link per group).','JSS 3','Civic Education',current_date+10,teacher_id,'https://drive.google.com/');
  end if;

  -- Behaviour points: positive + corrective examples
  if (select count(*) from public.behaviour_points) < 4 and adanna is not null then
    insert into public.behaviour_points (student_id,points,reason,badge,awarded_by) values
      (adanna,10,'Led the class study group all week','⭐ Star Leader',teacher_id),
      (coalesce(bello,adanna),5,'Volunteered to clean the laboratory','🤝 Helping Hand',teacher_id),
      (coalesce(chiamaka,adanna),8,'Perfect punctuality this month','⏰ Always Early',teacher_id),
      (coalesce(st3,adanna),-3,'Late submission of two assignments','',teacher_id);
  end if;

  -- Support plans: SEN/intervention examples
  if (select count(*) from public.support_plans) < 3 and adanna is not null then
    insert into public.support_plans (student_id,need_type,intervention,goal,review_date,outcome,status) values
      (coalesce(bello,adanna),'Reading fluency','20 minutes guided reading, three times weekly with the literacy coordinator.','Reach age-appropriate fluency by end of first term.',current_date+30,'Improving — moved up one reading band.','active'),
      (coalesce(chiamaka,adanna),'Mathematics anxiety','Small-group numeracy club + weekly confidence check-in.','Attempt all test questions without skipping.',current_date+21,'','review'),
      (coalesce(st3,adanna),'Speech support','External speech-therapist referral; classroom seating adjustment.','Clear participation in class reading.',current_date+45,'Closed after successful review.','closed');
  end if;

  -- Library: a proper catalogue shelf
  if (select count(*) from public.library) < 6 then
    insert into public.library (title,author,isbn,category,copies,lent,drive_link) values
      ('Things Fall Apart','Chinua Achebe','978-0385474542','Literature',12,3,''),
      ('New General Mathematics SS2','M. F. Macrae','978-9781255429','Mathematics',30,11,''),
      ('Intensive English for SSS','P. O. Olatunbosun','978-9781234567','English',25,6,''),
      ('Essential Biology','M. C. Michael','978-9785401234','Sciences',20,4,''),
      ('Junior Atlas for Nigerian Schools','Macmillan','978-0333456789','Reference',15,0,''),
      ('Civic Education for Secondary Schools','S. A. Adeyemi','978-9788765432','Humanities',18,2,'');
  end if;

  -- Helpdesk: tickets across categories/statuses (matches the new category dropdown)
  if (select count(*) from public.helpdesk_tickets) < 4 then
    insert into public.helpdesk_tickets (category,subject,body,priority,status,submitted_by) values
      ('IT / computer','Projector in SS2 not displaying','Screen flickers then goes blank after 5 minutes.','high','in_progress',teacher_id),
      ('plumbing','Leaking tap in junior block','Water wastage near the JSS toilets.','normal','open',teacher_id),
      ('electrical','Faulty socket in science lab','Sparks when the microscope charger is plugged in.','urgent','resolved',teacher_id),
      ('furniture','Broken chairs in JSS 1B','Four chairs need repair before resumption.','low','open',teacher_id);
  end if;

  -- Gamification / house points as module records (module_records powers the page)
  if (select count(*) from public.module_records where module='gamification') = 0 then
    insert into public.module_records (module,title,body,status,data,created_by) values
      ('gamification','Blue House — Inter-house Quiz Champions','Blue House won the third-term inter-house quiz.','awarded','{"house":"Blue","points":50}'::jsonb,teacher_id),
      ('gamification','Reading Challenge — 1000 Pages Club','Twelve students completed the 1000-page reading challenge.','awarded','{"badge":"1000 Pages","points":25}'::jsonb,teacher_id);
  end if;
  if (select count(*) from public.module_records where module='cafeteria') = 0 then
    insert into public.module_records (module,title,body,status,ref_date,data,created_by) values
      ('cafeteria','Jollof rice & grilled chicken','Wednesday lunch — contains groundnut oil.','planned',current_date+1,'{"allergens":["groundnut"]}'::jsonb,admin_id),
      ('cafeteria','Beans porridge & plantain','Friday lunch — vegetarian option available.','planned',current_date+3,'{"allergens":[]}'::jsonb,admin_id);
  end if;
  if (select count(*) from public.module_records where module='lost_found') = 0 then
    insert into public.module_records (module,title,body,status,data,created_by) values
      ('lost_found','Blue water bottle (found)','Found near the assembly ground after Friday sports.','unclaimed','{"location":"Front desk"}'::jsonb,admin_id),
      ('lost_found','Casio fx-991 calculator (lost)','Reported missing by an SS2 student.','searching','{"reward":"none"}'::jsonb,admin_id);
  end if;
  if (select count(*) from public.module_records where module='parent_meeting') = 0 then
    insert into public.module_records (module,title,body,status,ref_date,data,created_by) values
      ('parent_meeting','Third-Term PTA General Meeting','Agenda: results review, resumption dates, development levy update.','scheduled',current_date+14,'{"venue":"School hall","time":"10:00"}'::jsonb,admin_id);
  end if;

  -- Staff appraisal + bonus rows so HR pages feel alive
  if (select count(*) from public.staff_bonus) = 0 then
    insert into public.staff_bonus (staff_name,bonus_type,amount,reason,award_date,status)
    values ('Funke Alabi','performance',25000,'Best WAEC Mathematics results in three years',current_date-20,'paid'),
           ('Chukwuemeka Nwachukwu','extra duty',10000,'Coordinated inter-house sports',current_date-12,'approved');
  end if;
exception when others then
  raise notice 'V6.5 demo enrichment partial skip: %', sqlerrm;
end$$;
select 'School Connect demo V6.5 enrichment installed ✅' as status;
