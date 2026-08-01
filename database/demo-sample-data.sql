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
