-- ============================================================
-- DEMO SAMPLE DATA PACK — standalone, one-paste, idempotent
-- ------------------------------------------------------------
-- Fills EVERY showcase page with believable rows: payroll,
-- inventory, application links, messages, assignments, behaviour,
-- support plans, library, help-desk, bonuses, gamification,
-- cafeteria, lost & found, PTA meetings.
-- • Independent: needs only complete-schema.sql (resolves people
--   from whatever students/staff/profiles already exist).
-- • Idempotent: each block skips when the table already has rows.
-- • DEMO ONLY — never run on a production school.
-- HOW TO RUN: Supabase Dashboard → SQL Editor → paste → Run.
-- ============================================================
do $$
declare
  any_admin uuid := (select id from public.profiles where role in ('super_admin','admin','proprietor') and status in ('approved','active') limit 1);
  any_teacher uuid := coalesce((select id from public.profiles where role in ('teacher','staff') and status in ('approved','active') limit 1),
                              (select id from public.profiles limit 1));
  any_parent uuid := (select id from public.profiles where role='parent' limit 1);
  s1 record; s2 record; s3 record;
begin
  select id, full_name, class into s1 from public.students order by created_at limit 1;
  select id, full_name, class into s2 from public.students order by created_at offset 1 limit 1;
  select id, full_name, class into s3 from public.students order by created_at offset 2 limit 1;
  if s2.id is null then s2 := s1; end if;
  if s3.id is null then s3 := s1; end if;

  -- Payroll (June run for up to 4 staff)
  if (select count(*) from public.payroll) < 4 then
    insert into public.payroll (staff_id,staff_name,month,year,basic,allowances,tax,pension,net_pay,method,status)
    select id, full_name,'June',2026,150000+(row_number()over())*10000,20000,10000,12000,148000+(row_number()over())*10000,'bank transfer','paid'
      from public.staff limit 4;
  end if;

  -- Inventory (asset register)
  if (select count(*) from public.inventory) < 6 then
    insert into public.inventory (item_name,category,asset_tag,quantity,location,condition,unit_cost,last_audit,next_audit) values
      ('HP ProBook laptop','ICT','ICT-001',6,'ICT Laboratory','good',420000,current_date-60,current_date+120),
      ('Epson projector','ICT','ICT-002',2,'Staff Room','good',250000,current_date-60,current_date+120),
      ('Science microscope','Laboratory','LAB-014',8,'Science Lab','fair',95000,current_date-70,current_date+110),
      ('Student desk & chair set','Furniture','FUR-101',120,'Classrooms','good',18000,current_date-100,current_date+265),
      ('55-seater school bus','Transport','TRN-001',1,'Car park','good',28000000,current_date-30,current_date+150),
      ('Standby generator 20KVA','Facilities','FAC-003',1,'Generator house','needs service',3500000,current_date-20,current_date+70);
  end if;

  -- Application links
  if (select count(*) from public.admission_links) < 2 then
    insert into public.admission_links (label,applying_for_class,session,active) values
      ('2026/2027 JSS 1 Entrance Intake','JSS 1','2026/2027',true),
      ('2025/2026 SS 1 Transfer Window (closed)','SS 1','2025/2026',false);
  end if;

  -- Messages (two-way threads)
  if (select count(*) from public.messages) < 3 and any_teacher is not null then
    insert into public.messages (from_id,to_id,body,read,thread_id) values
      (any_teacher,coalesce(any_parent,any_admin,any_teacher),'Good afternoon. Your child performed excellently in the Mathematics revision test — 17/20.',true,'d9100000-0000-4000-8000-000000000001'),
      (coalesce(any_parent,any_admin,any_teacher),any_teacher,'Thank you for the update! We will keep supporting at home.',false,'d9100000-0000-4000-8000-000000000001'),
      (coalesce(any_admin,any_teacher),any_teacher,'Reminder: submit third-term scheme-of-work coverage before Friday.',true,'d9100000-0000-4000-8000-000000000002');
  end if;

  -- Assignments
  if (select count(*) from public.assignments) < 4 then
    insert into public.assignments (title,description,class,subject,due_date,posted_by,drive_link) values
      ('Essay: My Role Model','Write a 400-word argumentative essay. Submit as a Drive link.',coalesce(s1.class,'SS 2'),'English Language',current_date+5,any_teacher,'https://drive.google.com/'),
      ('Simultaneous Equations Worksheet','Questions 1–15, elimination and substitution methods.',coalesce(s1.class,'SS 2'),'Mathematics',current_date+3,any_teacher,'https://drive.google.com/'),
      ('States of Matter Poster','Draw and label the three states of matter with examples.','JSS 1','Basic Science',current_date+7,any_teacher,null),
      ('Civic Education Group Project','Rights and duties of a citizen — one link per group.','JSS 3','Civic Education',current_date+10,any_teacher,'https://drive.google.com/');
  end if;

  -- Behaviour points
  if (select count(*) from public.behaviour_points) < 4 and s1.id is not null then
    insert into public.behaviour_points (student_id,points,reason,badge,awarded_by) values
      (s1.id,10,'Led the class study group all week','⭐ Star Leader',any_teacher),
      (s2.id,5,'Volunteered to clean the laboratory','🤝 Helping Hand',any_teacher),
      (s3.id,8,'Perfect punctuality this month','⏰ Always Early',any_teacher),
      (s1.id,-3,'Late submission of two assignments',null,any_teacher);
  end if;

  -- Support plans
  if (select count(*) from public.support_plans) < 3 and s1.id is not null then
    insert into public.support_plans (student_id,need_type,intervention,goal,review_date,outcome,status) values
      (s2.id,'Reading fluency','20 minutes guided reading, three times weekly.','Reach age-appropriate fluency by end of first term.',current_date+30,'Improving — moved up one reading band.','active'),
      (s3.id,'Mathematics anxiety','Small-group numeracy club + weekly confidence check-in.','Attempt all test questions without skipping.',current_date+21,null,'review'),
      (s1.id,'Speech support','External speech-therapist referral; seating adjustment.','Clear participation in class reading.',current_date+45,'Closed after successful review.','closed');
  end if;

  -- Library catalogue
  if (select count(*) from public.library) < 6 then
    insert into public.library (title,author,isbn,category,copies,lent) values
      ('Things Fall Apart','Chinua Achebe','978-0385474542','Literature',12,3),
      ('New General Mathematics SS2','M. F. Macrae','978-9781255429','Mathematics',30,11),
      ('Intensive English for SSS','P. O. Olatunbosun','978-9781234567','English',25,6),
      ('Essential Biology','M. C. Michael','978-9785401234','Sciences',20,4),
      ('Junior Atlas for Nigerian Schools','Macmillan','978-0333456789','Reference',15,0),
      ('Civic Education for Secondary Schools','S. A. Adeyemi','978-9788765432','Humanities',18,2);
  end if;

  -- Help-desk tickets
  if (select count(*) from public.helpdesk_tickets) < 4 then
    insert into public.helpdesk_tickets (category,subject,body,priority,status,submitted_by) values
      ('IT / computer','Projector in SS2 not displaying','Screen flickers then goes blank after 5 minutes.','high','in_progress',any_teacher),
      ('plumbing','Leaking tap in junior block','Water wastage near the JSS toilets.','normal','open',any_teacher),
      ('electrical','Faulty socket in science lab','Sparks when the microscope charger is plugged in.','urgent','resolved',any_teacher),
      ('furniture','Broken chairs in JSS 1B','Four chairs need repair before resumption.','low','open',any_teacher);
  end if;

  -- Staff bonuses
  if (select count(*) from public.staff_bonus) < 2 then
    insert into public.staff_bonus (staff_name,bonus_type,amount,reason,award_date,status)
    select full_name,'performance',25000,'Best exam results in three years',current_date-20,'paid' from public.staff limit 1;
    insert into public.staff_bonus (staff_name,bonus_type,amount,reason,award_date,status)
    select full_name,'extra duty',10000,'Coordinated inter-house sports',current_date-12,'approved' from public.staff offset 1 limit 1;
  end if;

  -- module_records-powered pages
  if (select count(*) from public.module_records where module='gamification') = 0 then
    insert into public.module_records (module,title,body,status,data,created_by) values
      ('gamification','Blue House — Inter-house Quiz Champions','Blue House won the third-term inter-house quiz.','awarded','{"house":"Blue","points":50}'::jsonb,any_teacher),
      ('gamification','Reading Challenge — 1000 Pages Club','Twelve students completed the reading challenge.','awarded','{"badge":"1000 Pages","points":25}'::jsonb,any_teacher);
  end if;
  if (select count(*) from public.module_records where module='cafeteria') = 0 then
    insert into public.module_records (module,title,body,status,ref_date,data,created_by) values
      ('cafeteria','Jollof rice & grilled chicken','Wednesday lunch — contains groundnut oil.','planned',current_date+1,'{"allergens":["groundnut"]}'::jsonb,any_admin),
      ('cafeteria','Beans porridge & plantain','Friday lunch — vegetarian option available.','planned',current_date+3,'{"allergens":[]}'::jsonb,any_admin);
  end if;
  if (select count(*) from public.module_records where module='lost_found') = 0 then
    insert into public.module_records (module,title,body,status,created_by) values
      ('lost_found','Blue water bottle (found)','Found near the assembly ground after Friday sports.','unclaimed',any_admin),
      ('lost_found','Casio fx-991 calculator (lost)','Reported missing by an SS2 student.','searching',any_admin);
  end if;
  if (select count(*) from public.module_records where module='parent_meeting') = 0 then
    insert into public.module_records (module,title,body,status,ref_date,data,created_by) values
      ('parent_meeting','Third-Term PTA General Meeting','Agenda: results review, resumption dates, development levy update.','scheduled',current_date+14,'{"venue":"School hall","time":"10:00"}'::jsonb,any_admin);
  end if;
  if (select count(*) from public.module_records where module='inbox') < 3 then
    insert into public.module_records (module,title,body,audience,status,created_by) values
      ('inbox','Welcome to the portal','Explore results, fees, CBT and report cards — everything is live sample data.','all','read',any_admin),
      ('inbox','PTA meeting reminder','The third-term PTA meeting holds next Saturday at 10:00 in the school hall.','parent','unread',any_admin),
      ('inbox','Submit scheme of work','All teachers should tick their covered topics before Friday.','staff','unread',any_admin);
  end if;
  raise notice 'Demo sample data pack applied.';
exception when others then
  raise notice 'Demo sample pack partial skip: %', sqlerrm;
end $$;
select 'Demo sample data pack installed ✅ — open any page to see rows' as status;

-- ===================== V7.5 breadth additions ==========================
do $$
declare
  any_admin uuid := (select id from public.profiles where role in ('super_admin','admin','proprietor') and status in ('approved','active') limit 1);
  s1 record; s2 record; nm1 text; nm2 text;
begin
  select id, full_name, class into s1 from public.students order by created_at limit 1;
  select id, full_name, class into s2 from public.students order by created_at offset 1 limit 1;
  if s2.id is null then s2 := s1; end if;
  select full_name into nm1 from public.staff order by created_at limit 1;
  select full_name into nm2 from public.staff order by created_at offset 1 limit 1;
  nm2 := coalesce(nm2, nm1);

  -- Staff loans (requires v7.5 RLS policies)
  if nm1 is not null and (select count(*) from public.staff_loans) < 2 then
    insert into public.staff_loans (staff_name,loan_type,principal,monthly_repayment,months,amount_repaid,date_taken,status,notes) values
      (nm1,'personal loan',150000,15000,10,60000,current_date-120,'active','Laptop purchase support, approved by proprietor.'),
      (nm2,'emergency',80000,10000,8,80000,current_date-300,'completed','Medical advance, fully repaid.');
  end if;

  -- Staff appraisals
  if nm1 is not null and (select count(*) from public.staff_appraisals) < 2 then
    insert into public.staff_appraisals (staff_name,period,punctuality,teaching_quality,student_results,teamwork,conduct,total_score,recommendation,comments) values
      (nm1,'Current session',9,10,9,9,10,'9.4 — Outstanding','commend','Outstanding lesson delivery; class average rose 14% this session.'),
      (nm2,'Current session',7,8,8,9,9,'8.2 — Very Good','train','Strong classroom management; recommend ICT-integration training.');
  end if;

  -- Promotion drafts (auto-fillable showcase for the promotion page)
  if s1.id is not null and (select count(*) from public.promotions) < 3 then
    insert into public.promotions (student_id,student_name,from_class,to_class,action,average,status,term,session)
    select id, full_name, class, class, 'promote', 74, 'pending',
           (select term from public.academic_periods where is_current limit 1),
           (select session from public.academic_periods where is_current limit 1)
      from public.students order by created_at limit 5;
  end if;

  -- E-resources
  if (select count(*) from public.eresources) < 3 then
    insert into public.eresources (title,description,subject,class,term,drive_link) values
      ('WAEC Past Questions — Mathematics','Five years of past questions with chief examiner reports.','Mathematics','SS 3','Third Term','https://drive.google.com/'),
      ('Phonics drill audio pack','Daily 10-minute drills for early readers.','English Language','JSS 1','Third Term','https://drive.google.com/');
  end if;

  -- module_records breadth: one guard per module keeps this idempotent
  if (select count(*) from public.module_records where module='front_desk') = 0 then
    insert into public.module_records (module,title,body,ref_date,data,created_by) values
      ('front_desk','Prospectus enquiry — walk-in','Parent asked about JSS 1 admission requirements; prospectus issued.',current_date,'{"kind":"walk-in","contact":"0803 555 1122"}'::jsonb,any_admin),
      ('front_desk','Courier dispatch — WAEC forms','WAEC registration forms dispatched to zonal office via courier.',current_date,'{"kind":"dispatch","contact":"Courier waybill 4491"}'::jsonb,any_admin);
  end if;
  if (select count(*) from public.module_records where module='broadcast') = 0 then
    insert into public.module_records (module,title,body,status,data,created_by) values
      ('broadcast','Results released','Dear parents, term results are now on the portal. Log in to view your child''s report card.','sent','{"channel":"whatsapp","audience":"parents"}'::jsonb,any_admin),
      ('broadcast','Resumption reminder','School resumes soon — the fees portal is open.','queued','{"channel":"sms","audience":"all"}'::jsonb,any_admin);
  end if;
  if (select count(*) from public.module_records where module='reports') = 0 then
    insert into public.module_records (module,title,body,ref_date,data,created_by) values
      ('reports','Termly enrolment summary','Active students, staff strength, attendance rate and fee collection at a glance.',current_date,'{"type":"termly"}'::jsonb,any_admin);
  end if;
  if (select count(*) from public.module_records where module='lms') = 0 then
    insert into public.module_records (module,title,body,data,created_by) values
      ('lms','Quadratic Equations — video lesson','Watch the worked examples then attempt the practice set.',jsonb_build_object('subject','Mathematics','class',coalesce(s1.class,'SS 2'),'video','https://drive.google.com/'),any_admin),
      ('lms','Photosynthesis explained','Full topic notes with diagram labelling task.',jsonb_build_object('subject','Biology','class',coalesce(s2.class,'SS 1'),'video','https://drive.google.com/'),any_admin);
  end if;
  if (select count(*) from public.module_records where module='document_builder') = 0 then
    insert into public.module_records (module,title,body,status,data,created_by) values
      ('document_builder','Fee clearance letter','This is to certify that [NAME] of [CLASS] has cleared all fees for [TERM], [SESSION].','issued',jsonb_build_object('type','fee clearance','student',coalesce(s1.full_name,''),'class',coalesce(s1.class,''),'signatory_role','Principal','reference','FC/2026/014'),any_admin);
  end if;
  if (select count(*) from public.module_records where module='facility_booking') = 0 then
    insert into public.module_records (module,title,ref_date,status,data,created_by) values
      ('facility_booking','School hall — PTA meeting',current_date+9,'approved','{"time":"10:00","bookedby":"PTA Secretary"}'::jsonb,any_admin),
      ('facility_booking','Football pitch — inter-house practice',current_date+14,'requested','{"time":"14:00","bookedby":"Games Master"}'::jsonb,any_admin);
  end if;
  if (select count(*) from public.module_records where module='compliance') = 0 then
    insert into public.module_records (module,title,body,ref_date,status,data,created_by) values
      ('compliance','Fire extinguisher service','Annual service of all extinguishers.',current_date+26,'due','{"category":"fire drill"}'::jsonb,any_admin),
      ('compliance','Ministry of Education inspection','Passed with commendation on record keeping.',current_date-60,'passed','{"category":"inspection"}'::jsonb,any_admin);
  end if;
  if (select count(*) from public.module_records where module='fleet_tracking') = 0 then
    insert into public.module_records (module,title,body,ref_date,data,created_by) values
      ('fleet_tracking','Bus 1 — morning route','Morning run completed 07:42; evening run departs 15:30.',current_date,'{"driver":"School driver"}'::jsonb,any_admin);
  end if;
  if (select count(*) from public.module_records where module='transcripts') = 0 then
    insert into public.module_records (module,title,body,data,created_by) values
      ('transcripts','Session transcript','Mathematics A, English B2, Physics B3, Chemistry A, Biology B2.',jsonb_build_object('student',coalesce(s1.full_name,''),'term','Third Term','gpa','4.2 / 5.0','remark','Excellent — top 5% of class'),any_admin);
  end if;
  if (select count(*) from public.module_records where module='transfer_cert') = 0 then
    insert into public.module_records (module,title,body,ref_date,data,created_by) values
      ('transfer_cert','TC/2026/003','Family relocated. All fees cleared.',current_date,jsonb_build_object('student',coalesce(s2.full_name,''),'last_class',coalesce(s2.class,''),'reason','relocation','conduct','good'),any_admin);
  end if;
  if (select count(*) from public.module_records where module='counselling') = 0 then
    insert into public.module_records (module,title,body,status,data,created_by) values
      ('counselling','Exam anxiety session','Two sessions held; coping strategies working well.','closed',jsonb_build_object('student',coalesce(s2.full_name,''),'counsellor','School counsellor'),any_admin);
  end if;
  if (select count(*) from public.module_records where module='rubrics') = 0 then
    insert into public.module_records (module,title,body,data,created_by) values
      ('rubrics','Argumentative essay rubric','Used for all continuous-assessment essays.',jsonb_build_object('subject','English Language','class',coalesce(s1.class,'SS 2'),'criteria',E'Thesis clarity\nEvidence & examples\nOrganisation\nGrammar & mechanics','scale','1-4 (Beginning–Exceeding)'),any_admin);
  end if;
  if (select count(*) from public.module_records where module='career_counseling') = 0 then
    insert into public.module_records (module,title,body,data,created_by) values
      ('career_counseling','University guidance — sciences','JAMB subject combination confirmed; mock UTME booked.',jsonb_build_object('student',coalesce(s1.full_name,''),'university','University of Lagos — Medicine'),any_admin);
  end if;
  if (select count(*) from public.module_records where module='financial_aid') = 0 then
    insert into public.module_records (module,title,body,amount,status,data,created_by) values
      ('financial_aid','Proprietor''s Scholarship','50% tuition waiver for academic excellence.',75000,'approved',jsonb_build_object('student',coalesce(s2.full_name,'')),any_admin);
  end if;
  if (select count(*) from public.module_records where module='book_request') = 0 then
    insert into public.module_records (module,title,ref_date,status,data,created_by) values
      ('book_request','Further Mathematics — Egbe et al',current_date,'reserved',jsonb_build_object('student',coalesce(s2.full_name,'')),any_admin);
  end if;
  if (select count(*) from public.module_records where module='messages') < 3 then
    insert into public.module_records (module,title,body,audience,data,created_by) values
      ('messages','Revision groups announced','Revision groups meet in the library every Tuesday before mock exams.','student','{"to":"All students"}'::jsonb,any_admin),
      ('messages','Fee balance reminder','Dear parents, kindly clear outstanding balances before the PTA meeting.','parent','{"to":"All parents"}'::jsonb,any_admin);
  end if;
  raise notice 'V7.5 breadth sample pack applied.';
exception when others then
  raise notice 'V7.5 breadth pack partial skip: %', sqlerrm;
end $$;
select 'Demo sample data pack V7.5 (full breadth) installed ✅' as status;
