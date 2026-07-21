/* ====================================================================
   crud.js — School Connect generic CRUD engine
   --------------------------------------------------------------------
   Turns every module page into a REAL working list + add/edit/delete
   screen backed by Supabase. Replaces the old placeholder
   "Form will be generated for ..." behaviour. 100% free, no AI.

   SCHEMA[moduleId] = { table, title, cols:[{key,label,type,options?,required?}] }
   - type: text | textarea | number | date | datetime | select | checkbox | email | tel
   ==================================================================== */
const CRUD = {
  sb: null,
  WRITE_RULES: {
    // Admin/Super Admin is always full read/write in canWrite(). These rules define
    // non-admin write capability only; read access is controlled by app.js + RLS.
    students:['staff','teacher'],
    staff:[], parents:[], parent_child:[],
    classes:['staff','teacher'], subjects:['staff','teacher'], attendance:['staff','teacher'],
    results:['staff','teacher'], academic_records:['staff','teacher'], report_cards:['staff','teacher'],
    cbt:['staff','teacher'], cbt_prompts:['staff','teacher'], assignments:['staff','teacher'],
    timetable:['staff','teacher'], timetable_generator:['staff','teacher'], sow:['staff','teacher'],
    lesson_plans:['staff','teacher'], announcements:['staff','teacher'], events:['staff','teacher'],
    gallery:['staff','teacher'], library:['staff','teacher'], digital_library:['staff','teacher'],
    eresources:['staff','teacher'], directory:['staff','teacher'], broadcast:['staff','teacher'],
    complaints:['staff','teacher','parent','student'], inbox:['staff','teacher','parent'],
    messages:['staff','teacher','parent','student'], leave:['staff','teacher'], visitors:['staff','teacher'],
    hostel:['staff','teacher'], transport:['staff','teacher'], certificates:['staff','teacher'],
    behaviour:['staff','teacher'], conduct:['staff','teacher'], health:['staff','teacher'],
    support_plans:['staff','teacher'], diary:['staff','teacher'], checkin:['staff','teacher'],
    rubrics:['staff','teacher'], counselling:['staff','teacher'], substitutions:['staff','teacher'],
    helpdesk:['staff','teacher','parent','student'], book_request:['staff','teacher','student'],
    // Admin-only write modules
    academic_setup:[], approvals:[], admin_data:[], analytics:[], finance:[], hr:[], payroll:[],
    staff_loans:[], staff_bonus:[], appraisals:[], inventory:[], compliance:[], activity_log:[],
    storage:[], settings:[], promotion:[], alumni:[], financial_aid:[], donations:[], payments_online:[],
    admissions:[], admission_links:[], exam_registrations:['staff','teacher'], departments:[], front_desk:[], document_builder:[], fleet_tracking:[], facility_booking:[],
    menu:[], cafeteria:[], idcards:[], flyer:[], school_calendar:[], lost_found:[], parent_meeting:[]
  },
  init(supabaseClient) { this.sb = supabaseClient || (typeof sb !== 'undefined' ? sb : null); },

  /* Field schema per module. Only columns a human edits are listed; the DB
     fills ids/timestamps/generated columns automatically. */
  SCHEMA: {
    students: { table:'students', title:'Student', cols:[
      {key:'full_name',label:'Full name',type:'text',required:true},
      {key:'user_id',label:'Student login account (optional)',type:'ref',refTable:'profiles',refValue:'full_name',refExtra:['email'],refStore:'id',refFilter:{role:'student'},searchable:true,help:"Link this student record to the student account so My Profile/My Results work."},
      {key:'admission_no',label:'Admission No',type:'text',readonly:true,help:'AUTO-GENERATED on save — leave blank',placeholder:'(auto)'},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'arm',label:'Arm',type:'text'},
      {key:'gender',label:'Gender',type:'select',options:['male','female']},
      {key:'date_of_birth',label:'Date of birth',type:'date'},
      {key:'guardian_name',label:'Guardian name',type:'text'},
      {key:'guardian_phone',label:'Guardian phone',type:'tel'},
      {key:'guardian_email',label:'Guardian email',type:'email'},
      {key:'address',label:'Address',type:'textarea'},
      {key:'campus',label:'Campus',type:'text'},
      {key:'status',label:'Status',type:'select',options:['active','inactive','graduated']}
    ]},
    staff: { table:'staff', title:'Staff', cols:[
      {key:'full_name',label:'Full name',type:'text',required:true},
      {key:'user_id',label:'Staff login account (optional)',type:'ref',refTable:'profiles',refValue:'full_name',refExtra:['email'],refStore:'id',refFilter:{role:'staff'},searchable:true,help:'Link this staff record to the staff/teacher login so Teacher Overview works.'},
      {key:'staff_no',label:'Staff No',type:'text',readonly:true,help:'AUTO-GENERATED on save — leave blank',placeholder:'(auto)'},
      {key:'email',label:'Email',type:'email'},
      {key:'phone',label:'Phone',type:'tel'},
      {key:'staff_type',label:'Staff type',type:'select',options:['teaching','non-teaching']},
      {key:'role',label:'Role / Designation',type:'text',help:'e.g. Class teacher, Bursar, Registrar'},
      {key:'department',label:'Department',type:'ref',refTable:'departments',refValue:'name'},
      {key:'subject_taught',label:'Subject(s) taught',type:'ref',refTable:'subjects',refValue:'name',refStore:'value',help:'Leave blank for non-teaching staff'},
      {key:'qualification',label:'Highest qualification',type:'select',options:['SSCE','OND','HND','NCE','B.Sc','B.Ed','B.A','PGDE','M.Sc','M.Ed','M.A','Ph.D','Other']},
      {key:'gender',label:'Gender',type:'select',options:['male','female']},
      {key:'religion',label:'Religion',type:'select',options:['Christianity','Islam','Traditional','Other']},
      {key:'marital_status',label:'Marital status',type:'select',options:['single','married','divorced','widowed']},
      {key:'dob_day',label:'Birth day',type:'select',options:['1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','18','19','20','21','22','23','24','25','26','27','28','29','30','31'],help:'For privacy, staff DOB stores day & month only (no year)'},
      {key:'dob_month',label:'Birth month',type:'select',options:['January','February','March','April','May','June','July','August','September','October','November','December']},
      {key:'address',label:'Address',type:'textarea'},
      {key:'photo_url',label:'Photo (Google Drive / link)',type:'text',help:'Paste a Drive link — no upload (saves storage)'},
      {key:'part_time',label:'Part-time',type:'checkbox'},
      {key:'leave_balance',label:'Leave balance',type:'number'},
      {key:'status',label:'Status',type:'select',options:['active','inactive']}
    ]},
    classes: { table:'classes', title:'Class', cols:[
      {key:'name',label:'Class name',type:'text',required:true},
      {key:'arm',label:'Arm',type:'text'},
      {key:'level',label:'Level',type:'select',options:['Pre-Nursery','Nursery','Primary','JSS','SSS','Other']},
      {key:'class_teacher',label:'Class teacher (pick from staff)',type:'ref',refTable:'staff',refValue:'full_name',refStore:'value',refFilter:{staff_type:'teaching'}},
      {key:'capacity',label:'Capacity',type:'number'},
      {key:'next_term_fees',label:'Next term fee bill amount',type:'number'},
      {key:'next_term_fees_currency',label:'Currency',type:'select',options:['₦', '$', '£', '€']},
      {key:'next_term_fees_note',label:'Next term fees payment note',type:'text'}
    ]},
    subjects: { table:'subjects', title:'Subject', cols:[
      {key:'name',label:'Subject',type:'text',required:true},
      {key:'code',label:'Code',type:'text'},
      {key:'department',label:'Department',type:'ref',refTable:'departments',refValue:'name'},
      {key:'level',label:'Level',type:'select',options:['Nursery','Primary','JSS','SSS','All']},
      {key:'teacher',label:'Subject teacher (pick from staff)',type:'ref',refTable:'staff',refValue:'full_name',refStore:'value',refFilter:{staff_type:'teaching'},help:'Maps this subject to a teacher'}
    ]},
    attendance: { table:'attendance', title:'Attendance', cols:[
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class','admission_no'],refStore:'id',groupBy:'class',searchable:true,autofill:{student_name:'full_name',class:'class'}},
      {key:'student_name',label:'Student name (auto)',type:'text',readonly:true},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'date',label:'Date',type:'date',required:true},
      {key:'status',label:'Status',type:'select',options:['present','absent','late','excused']},
      {key:'time_in',label:'Time in',type:'time'}
    ]},
    results: { table:'results', title:'Result / Subject Score Sheet Row', cols:[
      {key:'student_id',label:'Student (pick from registered list)',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class','admission_no'],refStore:'id',groupBy:'class',searchable:true,autofill:{student_name:'full_name',class:'class'}},
      {key:'student_name',label:'Student name (auto)',type:'text',readonly:true},
      {key:'subject',label:'Subject',type:'ref',refTable:'subjects',refValue:'name',refStore:'value',required:true},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term'},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session'},
      {key:'ca1',label:'CA1',type:'number'},{key:'ca2',label:'CA2',type:'number'},
      {key:'ca3',label:'CA3',type:'number'},{key:'exam',label:'Exam',type:'number'},
      {key:'grade',label:'Grade',type:'text',help:'auto-suggested from total'},{key:'remark',label:'Remark',type:'text'}
    ]},
    timetable: { table:'timetable', title:'Timetable slot', cols:[
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'day',label:'Day',type:'select',options:['Monday','Tuesday','Wednesday','Thursday','Friday']},
      {key:'period',label:'Period',type:'text'},
      {key:'subject',label:'Subject',type:'ref',refTable:'subjects',refValue:'name',refStore:'value'},
      {key:'teacher',label:'Teacher',type:'ref',refTable:'staff',refValue:'full_name',refStore:'value'},
      {key:'room',label:'Room',type:'text'},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session'},{key:'term',label:'Term',type:'lookup',lookupKind:'term'}
    ]},
    sow: { table:'scheme_of_work', title:'Scheme of Work', cols:[
      {key:'subject',label:'Subject',type:'ref',refTable:'subjects',refValue:'name',refStore:'value'},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term'},{key:'session',label:'Session',type:'lookup',lookupKind:'session'},
      {key:'week',label:'Week',type:'number'},{key:'topic',label:'Topic',type:'text',required:true},
      {key:'status',label:'Status',type:'select',options:['pending','covered','uncovered']},
      {key:'confirmed',label:'Taught this week (confirm)',type:'checkbox'},
      {key:'teacher',label:'Teacher',type:'ref',refTable:'staff',refValue:'full_name',refStore:'value'}
    ]},
    assignments: { table:'assignments', title:'Assignment', cols:[
      {key:'title',label:'Title',type:'text',required:true},{key:'description',label:'Description',type:'textarea'},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'subject',label:'Subject',type:'ref',refTable:'subjects',refValue:'name',refStore:'value'},
      {key:'due_date',label:'Due date',type:'date'},{key:'drive_link',label:'Drive link',type:'text'}
    ]},
    library: { table:'library', title:'Book', cols:[
      {key:'title',label:'Title',type:'text',required:true},{key:'author',label:'Author',type:'text'},
      {key:'isbn',label:'ISBN',type:'text'},{key:'category',label:'Category',type:'text'},
      {key:'copies',label:'Copies',type:'number'},{key:'lent',label:'Lent',type:'number'},
      {key:'drive_link',label:'Drive link',type:'text'}
    ]},
    conduct: { table:'conduct', title:'Conduct record', cols:[
      {key:'student_name',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class'],refStore:'value',groupBy:'class',searchable:true},
      {key:'type',label:'Type',type:'select',options:['merit','demerit','incident']},
      {key:'description',label:'Description',type:'textarea'},{key:'reporter',label:'Reporter',type:'text'},
      {key:'date',label:'Date',type:'date'}
    ]},
    health: { table:'health', title:'Health record', cols:[
      {key:'student_name',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class'],refStore:'value',groupBy:'class',searchable:true},
      {key:'complaint',label:'Complaint',type:'text'},
      {key:'treatment',label:'Treatment',type:'textarea'},{key:'date',label:'Date',type:'date'},
      {key:'recorded_by',label:'Recorded by',type:'text'}
    ]},
    promotion: { table:'promotions', title:'Promotion', cols:[
      {key:'student_name',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class'],refStore:'value',groupBy:'class',searchable:true,autofill:{from_class:'class'}},
      {key:'from_class',label:'From class',type:'text'},
      {key:'to_class',label:'To class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'average',label:'Term average %',type:'number',help:'auto-filled by Auto-promote'},
      {key:'action',label:'Action',type:'select',options:['promote','graduate','repeat','pending','delete']},
      {key:'status',label:'Status',type:'select',options:['draft','approved','applied']},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session'},{key:'term',label:'Term',type:'lookup',lookupKind:'term'}
    ]},
    digital_library: { table:'digital_library', title:'Digital Book / Reading', cols:[
      {key:'title',label:'Book / Resource title',type:'text',required:true},
      {key:'author',label:'Author',type:'text'},
      {key:'subject',label:'Subject',type:'ref',refTable:'subjects',refValue:'name',refStore:'value'},
      {key:'class',label:'Assigned class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'read_link',label:'Read link (Google Drive / web)',type:'text',required:true,help:'Paste a Drive/web link — no upload (saves storage)'},
      {key:'teacher',label:'Set by (teacher)',type:'ref',refTable:'staff',refValue:'full_name',refStore:'value',refFilter:{staff_type:'teaching'}},
      {key:'instructions',label:'Reading instructions',type:'textarea'},
      {key:'has_quiz',label:'Has comprehension questions',type:'checkbox'},
      {key:'max_score',label:'Max score (counts to grade)',type:'number',help:'e.g. 10 — added to results as CA'},
      {key:'due_date',label:'Due date',type:'date'}
    ]},
    fees: { table:'fee_payments', title:'Fee payment', cols:[
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class','admission_no'],refStore:'id',groupBy:'class',searchable:true,required:true,autofill:{student_name:'full_name'}},
      {key:'student_name',label:'Student name (auto)',type:'text',readonly:true},
      {key:'fee_total',label:'Total fee for the term (optional)',type:'number',help:'If entered, balance auto-computes when left blank.'},
      {key:'amount_paid',label:'Amount paid',type:'number',required:true},
      {key:'balance',label:'Remaining balance',type:'number',help:'ENTERPRISE V11 (issue 13): shows on the e-receipt. Leave blank to auto-compute (total − paid).'},
      {key:'method',label:'Method',type:'select',options:['cash','transfer','pos','online']},
      {key:'reference',label:'Reference',type:'text'},{key:'term',label:'Term',type:'lookup',lookupKind:'term'},{key:'session',label:'Session',type:'lookup',lookupKind:'session'}
    ]},
    payments_online: { table:'payment_intents', title:'Online Fee Payment', cols:[
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class','admission_no'],refStore:'id',groupBy:'class',searchable:true,required:true},
      {key:'amount',label:'Amount',type:'number',required:true},
      {key:'provider',label:'Provider',type:'select',options:['paystack','flutterwave','bank_transfer']},
      {key:'reference',label:'Reference',type:'text'},{key:'checkout_url',label:'Checkout URL',type:'text'},{key:'status',label:'Status',type:'select',options:['pending','paid','failed','cancelled']}
    ]},
    finance: { table:'finance_entries', title:'Finance entry', cols:[
      {key:'type',label:'Type',type:'select',options:['income','expense']},
      {key:'category',label:'Category',type:'text'},{key:'amount',label:'Amount',type:'number',required:true},
      {key:'description',label:'Description',type:'textarea'},{key:'date',label:'Date',type:'date'}
    ]},
    leave: { table:'leave_requests', title:'Leave request', cols:[
      {key:'type',label:'Type',type:'select',options:['sick','casual','earned','study','maternity']},
      {key:'start_date',label:'Start',type:'date'},{key:'end_date',label:'End',type:'date'},
      {key:'days',label:'Days',type:'number'},{key:'reason',label:'Reason',type:'textarea'},
      {key:'status',label:'Status',type:'select',options:['pending','approved','rejected']}
    ]},
    visitors: { table:'visitors', title:'Visitor', cols:[
      {key:'full_name',label:'Name',type:'text',required:true},{key:'phone',label:'Phone',type:'tel'},
      {key:'purpose',label:'Purpose',type:'text'},{key:'host',label:'Host',type:'text'},{key:'badge_no',label:'Badge No',type:'text'}
    ]},
    transport: { table:'transport', title:'Transport route', cols:[
      {key:'route_name',label:'Route',type:'text',required:true},{key:'driver',label:'Driver',type:'text'},
      {key:'vehicle_no',label:'Vehicle No',type:'text'},{key:'capacity',label:'Capacity',type:'number'}
    ]},
    announcements: { table:'announcements', title:'Announcement', cols:[
      {key:'title',label:'Title',type:'text',required:true},{key:'body',label:'Body',type:'textarea'},
      {key:'priority',label:'Priority',type:'select',options:['normal','high','urgent']},
      {key:'pinned',label:'Pinned',type:'checkbox'},
      {key:'audience',label:'Audience',type:'lookup',lookupKind:'audience'}
    ]},
    events: { table:'events', title:'Event', cols:[
      {key:'title',label:'Title',type:'text',required:true},{key:'description',label:'Description',type:'textarea'},
      {key:'date',label:'Date',type:'date'},{key:'venue',label:'Venue',type:'text'},{key:'organiser',label:'Organiser',type:'text'}
    ]},
    complaints: { table:'complaints', title:'Complaint / Grievance', help:'Anyone (parent, student, staff) can lodge a complaint. It is routed to the admin team, tracked through statuses and closed with a resolution note. Attach evidence with a Drive link.', cols:[
      {key:'type',label:'Category',type:'select',options:['academic','welfare','bullying','fees/billing','facility','staff conduct','transport','other']},
      {key:'subject',label:'Subject (short summary)',type:'text',required:true},
      {key:'body',label:'Full details — what happened, when, who was involved',type:'textarea',required:true},
      {key:'attachment_link',label:'Evidence link (photo/doc on Google Drive — optional)',type:'text',help:'Paste a Drive/web link. No upload needed.'},
      {key:'urgency',label:'Urgency',type:'select',options:['low','normal','high','critical']},
      {key:'status',label:'Status (admin updates this)',type:'select',options:['submitted','reviewing','in_progress','resolved','rejected']},
      {key:'assigned_to',label:'Assigned to (admin only)',type:'ref',refTable:'staff',refValue:'full_name',refStore:'value'},
      {key:'resolution',label:'Resolution note (filled when closing)',type:'textarea'}
    ]},
    gallery: { table:'gallery', title:'Gallery item', cols:[
      {key:'album',label:'Album',type:'text'},{key:'caption',label:'Caption',type:'text'},
      {key:'media_url',label:'Media URL',type:'text',required:true},
      {key:'media_type',label:'Type',type:'select',options:['image','video','youtube']}
    ]},
    eresources: { table:'eresources', title:'E-Resource', cols:[
      {key:'title',label:'Title',type:'text',required:true},{key:'description',label:'Description',type:'textarea'},
      {key:'subject',label:'Subject',type:'text'},{key:'class',label:'Class',type:'text'},
      {key:'term',label:'Term',type:'text'},{key:'drive_link',label:'Drive link',type:'text'}
    ]},
    birthdays: { table:'birthdays', title:'Birthday', help:'Track birthdays for students, staff AND parents. Change the Type dropdown to Student/Staff/Parent, then pick the person from the correct list or type their name manually.', cols:[
      {key:'type',label:'Type (choose first — changes the person picker)',type:'select',options:['student','staff','parent'],required:true},
      {key:'person_name',label:'Person name (or pick from list)',type:'text',required:true,help:'Type a name or use the picker below for auto-fill.'},
      {key:'student_ref',label:'Pick Student (for student birthdays)',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class','date_of_birth'],refStore:'value',autofill:{person_name:'full_name',date:'date_of_birth',class:'class'},help:'Only for student type — auto-fills name, DOB and class.'},
      {key:'staff_ref',label:'Pick Staff (for staff birthdays)',type:'ref',refTable:'staff',refValue:'full_name',refExtra:['dob_day','dob_month','role'],refStore:'value',autofill:{person_name:'full_name'},help:'Only for staff type — auto-fills name.'},
      {key:'parent_ref',label:'Pick Parent (for parent birthdays)',type:'ref',refTable:'parents',refValue:'full_name',refStore:'value',autofill:{person_name:'full_name'},help:'Only for parent type — auto-fills name.'},
      {key:'date',label:'Date of birth',type:'date'},{key:'class',label:'Class / Role',type:'text'}
    ]},
    departments: { table:'departments', title:'Department', cols:[
      {key:'name',label:'Name',type:'text',required:true},{key:'head',label:'Head',type:'text'}
    ]},
    /* ENTERPRISE FINAL V2 (#21): comprehensive admission application. */
    admissions: { table:'admissions', title:'Admission Application', help:'Full applicant record: bio-data, origin, previous school, guardian, medical and documents. Extra fields are stored safely in data{} even on older databases.', cols:[
      {key:'full_name',label:'Applicant full name (surname first)',type:'text',required:true},
      {key:'dob',label:'Date of birth',type:'date'},
      {key:'gender',label:'Gender',type:'select',options:['male','female']},
      {key:'data.nationality',label:'Nationality',type:'text'},
      {key:'data.state_origin',label:'State of origin',type:'text'},
      {key:'data.lga',label:'LGA / County',type:'text'},
      {key:'data.religion',label:'Religion',type:'select',options:['Christianity','Islam','Traditional','Other']},
      {key:'data.home_address',label:'Home address',type:'textarea'},
      {key:'data.blood_group',label:'Blood group',type:'select',options:['A+','A-','B+','B-','AB+','AB-','O+','O-','Unknown']},
      {key:'data.genotype',label:'Genotype',type:'select',options:['AA','AS','SS','AC','Unknown']},
      {key:'data.medical_conditions',label:'Known medical conditions / allergies',type:'textarea'},
      {key:'data.previous_school',label:'Previous school attended',type:'text'},
      {key:'data.previous_class',label:'Last class completed',type:'text'},
      {key:'data.reason_for_leaving',label:'Reason for leaving previous school',type:'text'},
      {key:'applying_for_class',label:'Class applying for',type:'ref',refTable:'classes',refValue:'name'},
      {key:'data.entry_term',label:'Entry term',type:'lookup',lookupKind:'term'},
      {key:'data.entry_session',label:'Entry session',type:'lookup',lookupKind:'session'},
      {key:'parent_name',label:'Parent / Guardian full name',type:'text'},
      {key:'data.parent_relationship',label:'Relationship',type:'select',options:['father','mother','guardian','sponsor','other']},
      {key:'data.parent_occupation',label:'Parent occupation',type:'text'},
      {key:'parent_email',label:'Parent email',type:'email'},
      {key:'parent_phone',label:'Parent phone',type:'tel'},
      {key:'data.parent_phone_alt',label:'Alternative phone',type:'tel'},
      {key:'data.emergency_contact',label:'Emergency contact (name & phone)',type:'text'},
      {key:'data.photo_link',label:'Passport photo (Drive link)',type:'text',help:'Share as “anyone with the link”'},
      {key:'data.birth_cert_link',label:'Birth certificate (Drive link)',type:'text'},
      {key:'data.last_result_link',label:'Last result / transcript (Drive link)',type:'text'},
      {key:'data.special_needs',label:'Special needs / support required',type:'textarea'},
      {key:'data.how_heard',label:'How did you hear about us?',type:'select',options:['referral','social media','website','flyer','drive-past','event','other']},
      {key:'status',label:'Status',type:'select',options:['submitted','reviewing','accepted','enrolled','rejected']}
    ]},

    /* ENTERPRISE FINAL V2 (#22): external examination registrations —
       SSCE (WAEC/NECO), UTME/JAMB, IGCSE, Common Entrance, BECE, others. */
    exam_registrations: { table:'module_records', generic:true, module:'exam_registrations', title:'External Exam Registration', help:'Register candidates for SSCE (WAEC/NECO), UTME/JAMB, IGCSE, Common Entrance, BECE and more.', cols:[
      {key:'data.exam_type',label:'Examination',type:'select',options:['WAEC SSCE','NECO SSCE','UTME (JAMB)','IGCSE (Cambridge)','Common Entrance (NCEE)','BECE (Junior WAEC)','GCE','NABTEB','Other'],required:true},
      {key:'title',label:'Candidate Full Name',type:'text',required:true},
      {key:'data.student_id',label:'Link to student record',type:'ref',refTable:'students',refValue:'full_name',refStore:'id',searchable:true,autofill:{'data.dob':'date_of_birth','data.gender':'gender'}},
      {key:'data.dob',label:'Date of Birth',type:'date'},
      {key:'data.gender',label:'Gender',type:'select',options:['male','female']},
      {key:'data.nin',label:'NIN (National Identity Number)',type:'text'},
      {key:'data.exam_year',label:'Exam Year',type:'number',default:new Date().getFullYear()},
      {key:'data.subjects',label:'Subjects (comma-separated)',type:'textarea',help:'e.g. English, Mathematics, Physics...'},
      {key:'data.jamb_profile_code',label:'JAMB Profile Code / Number',type:'text'},
      {key:'data.course_choice_1',label:'1st Choice Course (UTME)',type:'text'},
      {key:'data.institution_1',label:'1st Choice Institution',type:'text'},
      {key:'data.course_choice_2',label:'2nd Choice Course (UTME)',type:'text'},
      {key:'data.institution_2',label:'2nd Choice Institution',type:'text'},
      {key:'data.centre',label:'Exam Centre',type:'text'},
      {key:'data.exam_no',label:'Exam/Reg Number',type:'text'},
      {key:'amount',label:'Fee Paid',type:'number'},
      {key:'status',label:'Status',type:'select',options:['collecting-details','paid','processing','registered','completed']}
    ]},

    /* AFFECTIVE & PSYCHOMOTOR DOMAINS (v9) */
    affective_traits: { table:'affective_traits', title:'Affective Domain', cols:[
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refStore:'id',groupBy:'class',searchable:true,required:true},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term',required:true},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session',required:true},
      {key:'data.punctuality',label:'Punctuality',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.neatness',label:'Neatness',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.politeness',label:'Politeness',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.honesty',label:'Honesty',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.leadership',label:'Leadership',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.cooperation',label:'Cooperation',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.attentiveness',label:'Attentiveness',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']}
    ]},
    psychomotor_traits: { table:'psychomotor_traits', title:'Psychomotor Domain', cols:[
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refStore:'id',groupBy:'class',searchable:true,required:true},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term',required:true},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session',required:true},
      {key:'data.handwriting',label:'Handwriting',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.verbal_fluency',label:'Verbal Fluency',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.sports',label:'Games & Sports',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.crafts',label:'Crafts / Handiwork',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.drawing',label:'Drawing / Painting',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']},
      {key:'data.music',label:'Music / Singing',type:'select',options:['5 - Excellent','4 - Very Good','3 - Good','2 - Fair','1 - Poor']}
    ]},
    report_comments: { table:'report_comments', title:'Report Card Comments', cols:[
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refStore:'id',groupBy:'class',searchable:true,required:true},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term',required:true},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session',required:true},
      {key:'class_teacher_comment',label:'Class Teacher\'s Comment',type:'textarea'},
      {key:'principal_comment',label:'Principal\'s Comment',type:'textarea'},
      {key:'next_term_begins',label:'Next Term Begins',type:'date'}
    ]},
    hr: { table:'payroll', title:'Salary / Payslip', alias:'payroll', cols:[
      {key:'staff_name',label:'Staff (pick from list)',type:'ref',refTable:'staff',refValue:'full_name',refExtra:['role'],refStore:'value',searchable:true,required:true},
      {key:'month',label:'Month',type:'select',options:['January','February','March','April','May','June','July','August','September','October','November','December'],required:true},
      {key:'year',label:'Year',type:'number',default:new Date().getFullYear()},
      {key:'basic',label:'Basic salary',type:'number',required:true},
      {key:'allowances',label:'Allowances',type:'number'},
      {key:'bonus',label:'Bonus / Incentive',type:'number'},
      {key:'overtime',label:'Overtime pay',type:'number'},
      {key:'tax',label:'Tax (PAYE)',type:'number'},
      {key:'pension',label:'Pension',type:'number'},
      {key:'loan_deduction',label:'Loan repayment',type:'number'},
      {key:'other_deductions',label:'Other deductions',type:'number'},
      {key:'net_pay',label:'Net pay (computed by database)',type:'number',readonly:true,computeOnly:true,help:'Auto: basic+allowances+bonus+overtime − tax/pension/loan/other'},
      {key:'method',label:'Payment method',type:'select',options:['bank transfer','cash','cheque','mobile money']},
      {key:'status',label:'Status',type:'select',options:['draft','approved','paid']}
    ]},
    hostel: { table:'hostel_allocations', title:'Hostel allocation', cols:[
      {key:'block',label:'Block',type:'text'},{key:'room',label:'Room',type:'text'},{key:'bed',label:'Bed',type:'text'},
      {key:'status',label:'Status',type:'select',options:['active','vacated']}
    ]},
    alumni: { table:'alumni', title:'Alumnus', cols:[
      {key:'full_name',label:'Name',type:'text',required:true},{key:'graduation_year',label:'Graduation year',type:'number'},
      {key:'last_class',label:'Last class',type:'text'},{key:'current_occupation',label:'Occupation',type:'text'},
      {key:'email',label:'Email',type:'email'},{key:'phone',label:'Phone',type:'tel'}
    ]},
    inventory: { table:'inventory', title:'Inventory item', cols:[
      {key:'item_name',label:'Item',type:'text',required:true},{key:'category',label:'Category',type:'text'},
      {key:'quantity',label:'Quantity',type:'number'},{key:'location',label:'Location',type:'text'},
      {key:'condition',label:'Condition',type:'text'}
    ]},
    lesson_plans: { table:'lesson_plans', title:'Lesson plan', cols:[
      {key:'teacher',label:'Teacher',type:'ref',refTable:'staff',refValue:'full_name',refStore:'value',searchable:true},{key:'subject',label:'Subject',type:'ref',refTable:'subjects',refValue:'name',refStore:'value'},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},{key:'week',label:'Week',type:'number'},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term'},{key:'session',label:'Session',type:'lookup',lookupKind:'session'},
      {key:'objectives',label:'Objectives',type:'textarea'},{key:'content',label:'Content',type:'textarea'},
      {key:'resources',label:'Resources',type:'textarea'},
      {key:'status',label:'Status',type:'select',options:['draft','submitted','approved']}
    ]},
    behaviour: { table:'behaviour_points', title:'Behaviour point', cols:[
      {key:'student_name',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class'],refStore:'value',groupBy:'class',searchable:true},
      {key:'points',label:'Points',type:'number'},
      {key:'reason',label:'Reason',type:'text'},{key:'badge',label:'Badge',type:'text'}
    ]},
    support_plans: { table:'support_plans', title:'Support plan', cols:[
      {key:'need_type',label:'Need type',type:'text'},{key:'intervention',label:'Intervention',type:'textarea'},
      {key:'goal',label:'Goal',type:'text'},{key:'review_date',label:'Review date',type:'date'},
      {key:'outcome',label:'Outcome',type:'text'},{key:'status',label:'Status',type:'select',options:['active','review','closed']}
    ]},
    donations: { table:'donations', title:'Donation', cols:[
      {key:'campaign',label:'Campaign',type:'text'},{key:'donor_name',label:'Donor',type:'text'},
      {key:'donor_email',label:'Donor email',type:'email'},{key:'amount',label:'Amount',type:'number',required:true},
      {key:'method',label:'Method',type:'text'},{key:'note',label:'Note',type:'text'},
      {key:'anonymous',label:'Anonymous',type:'checkbox'}
    ]},
    substitutions: { table:'substitutions', title:'Substitution', cols:[
      {key:'date',label:'Date',type:'date'},{key:'absent_teacher',label:'Absent teacher',type:'text'},
      {key:'substitute_teacher',label:'Substitute',type:'text'},{key:'class',label:'Class',type:'text'},
      {key:'subject',label:'Subject',type:'text'},{key:'period',label:'Period',type:'text'},
      {key:'status',label:'Status',type:'select',options:['planned','done','cancelled']}
    ]},
    helpdesk: { table:'helpdesk_tickets', title:'Help-desk ticket', cols:[
      {key:'category',label:'Category',type:'text'},{key:'subject',label:'Subject',type:'text',required:true},
      {key:'body',label:'Details',type:'textarea'},
      {key:'priority',label:'Priority',type:'select',options:['low','normal','high','urgent']},
      {key:'status',label:'Status',type:'select',options:['open','in_progress','resolved','closed']}
    ]},
    directory: { table:'profiles', title:'Person', cols:[
      {key:'full_name',label:'Name',type:'text',required:true},
      {key:'email',label:'Email',type:'email',readonly:true,help:'Email login address (cannot be edited)'},
      {key:'role',label:'Role',type:'select',options:['super_admin','admin','principal','proprietor','head_teacher','bursar','staff','teacher','parent','student'],required:true},
      {key:'status',label:'Status',type:'select',options:['pending','approved','suspended','rejected'],required:true},
      {key:'phone',label:'Phone',type:'text'}
    ]},
    activity_log: { table:'activity_log', title:'Activity', readOnly:true, cols:[
      {key:'created_at',label:'When',type:'text'},
      {key:'actor_email',label:'Who',type:'text'},
      {key:'action',label:'Action',type:'text'},
      {key:'entity',label:'Module/Table',type:'text'},
      {key:'entity_id',label:'Record',type:'text'}
    ]},
    cbt: { table:'cbt_exams', title:'CBT Exam / Assessment', cols:[
      {key:'title',label:'Exam title',type:'text',required:true},
      {key:'subject',label:'Subject',type:'ref',refTable:'subjects',refValue:'name',refStore:'value',required:true},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term'},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session'},
      {key:'assessment_type',label:'Assessment type',type:'select',options:['exam','test','assignment','project','quiz','ca','practical']},
      {key:'is_entrance',label:'Entrance / placement assessment',type:'checkbox'},
      {key:'pass_mark',label:'Entrance pass mark (%)',type:'number'},
      {key:'report_column',label:'Report-card column',type:'select',options:['Project','CA1','CA2','CBT Exam','Paper Exam','Exam','Practical']},
      {key:'max_score',label:'Max score contribution',type:'number',help:'Score to scale into report card, e.g. 20 for CBT Exam.'},
      {key:'duration',label:'Duration (minutes)',type:'number'},
      {key:'attempt_limit',label:'Attempt limit',type:'number'},
      {key:'select_count',label:'Select N questions (0 = all)',type:'number'},
      {key:'randomise',label:'Randomise questions',type:'checkbox'},
      {key:'negative_mark',label:'Negative mark per wrong answer',type:'number'},
      {key:'exam_mode',label:'Exam mode',type:'select',options:['open','anonymous','registered'],help:'Open: anyone with link, no login. Anonymous: candidates hide identity, results anonymized. Registered: only logged-in students of assigned class.'},
      {key:'is_open',label:'Open for candidates',type:'checkbox'},
      {key:'release_results',label:'Release results instantly',type:'checkbox'},
      {key:'instructions',label:'Candidate instructions',type:'textarea'},
      {key:'csv_data',label:'Question bank JSON',type:'textarea',help:'Use CBT page CSV import for best results. Supports 17 question types.'}
    ]},
    admission_links: { table:'admission_links', title:'Admission / Entrance Link', cols:[
      {key:'title',label:'Link title',type:'text',required:true},
      {key:'token',label:'Token / slug',type:'text',help:'Leave blank if your SQL trigger/RPC generates one.'},
      {key:'class_applied',label:'Class applied for',type:'ref',refTable:'classes',refValue:'name'},
      {key:'exam_code',label:'Entrance CBT code',type:'text'},
      {key:'active',label:'Active',type:'checkbox'},
      {key:'expires_at',label:'Expires at',type:'datetime'},
      {key:'notes',label:'Notes',type:'textarea'}
    ]},
    report_cards: { table:'report_cards', title:'Report Card', cols:[
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class','admission_no'],refStore:'id',groupBy:'class',searchable:true,autofill:{student_name:'full_name',class:'class'}},
      {key:'student_name',label:'Student name (auto)',type:'text',readonly:true},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term'},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session'},
      {key:'teacher_comment',label:'Teacher comment',type:'textarea'},
      {key:'head_comment',label:'Head comment',type:'textarea'},
      {key:'attendance_present',label:'Attendance present',type:'number'},
      {key:'attendance_total',label:'Attendance total',type:'number'},
      {key:'position',label:'Position',type:'number'},
      {key:'published',label:'Published',type:'checkbox'}
    ]},
    academic_records: { table:'academic_print_records', title:'Academic Record / Broadsheet', cols:[
      {key:'record_type',label:'Record type',type:'select',options:['student_record_card','class_broadsheet','subject_broadsheet'],required:true},
      {key:'title',label:'Title',type:'text',required:true},
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name'},
      {key:'subject',label:'Subject',type:'ref',refTable:'subjects',refValue:'name',refStore:'value'},
      {key:'term',label:'Term',type:'lookup',lookupKind:'term'},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session'}
    ]},
    certificates: { table:'certificates', title:'Certificate', cols:[
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class','admission_no'],refStore:'id',groupBy:'class',searchable:true},
      {key:'type',label:'Certificate type',type:'select',options:['completion','graduation','merit','testimonial','transfer','custom']},
      {key:'serial_no',label:'Serial No',type:'text'},
      {key:'issued_on',label:'Issued on',type:'date'},
      {key:'signed_by',label:'Signed by',type:'text'}
    ]},
    parents: { table:'parents', title:'Parent / Guardian Registry', cols:[
      {key:'full_name',label:'Full Name',type:'text',required:true},
      {key:'date_of_birth',label:'Date of birth (for birthday list)',type:'date'},
      {key:'email',label:'Email Address',type:'email'},
      {key:'phone',label:'Phone Number',type:'text'},
      {key:'occupation',label:'Occupation',type:'text'},
      {key:'address',label:'Home Address',type:'text'},
      {key:'status',label:'Status',type:'select',options:['active','pending','suspended']}
    ]},
    parent_child: { table:'parent_child', listTable:'parent_child_view', listOrder:'parent_name', title:'Parent–Child Link', help:'Link a parent ACCOUNT to a student RECORD. One parent can be linked to many children; the same pair can only be linked once. Use the Unlink button on a row to remove a link.', listCols:[
      {key:'parent_name',label:'Parent',type:'text'},{key:'parent_email',label:'Parent Email',type:'text'},
      {key:'student_name',label:'Student',type:'text'},{key:'student_class',label:'Class',type:'text'},
      {key:'relationship',label:'Relationship',type:'text'},{key:'verified',label:'Verified',type:'checkbox'}
    ], cols:[
      {key:'parent_id',label:'Parent account',type:'ref',refTable:'profiles',refValue:'full_name',refExtra:['email'],refStore:'id',refFilter:{role:'parent'},searchable:true,required:true},
      {key:'student_id',label:'Student',type:'ref',refTable:'students',refValue:'full_name',refExtra:['class','admission_no'],refStore:'id',groupBy:'class',searchable:true,required:true},
      {key:'relationship',label:'Relationship',type:'select',options:['father','mother','guardian','sponsor','other']},
      {key:'verified',label:'Verified',type:'checkbox'}
    ]},

    /* ===== Issue 5: Staff HR / Payroll suite (salary, bonus, loans, appraisal) ===== */
    payroll: { table:'payroll', title:'Salary / Payslip', cols:[
      {key:'staff_name',label:'Staff (pick from list)',type:'ref',refTable:'staff',refValue:'full_name',refExtra:['role'],refStore:'value',searchable:true,required:true},
      {key:'month',label:'Month',type:'select',options:['January','February','March','April','May','June','July','August','September','October','November','December'],required:true},
      {key:'year',label:'Year',type:'number',default:new Date().getFullYear()},
      {key:'basic',label:'Basic salary',type:'number',required:true},
      {key:'allowances',label:'Allowances',type:'number',help:'Housing, transport, etc.'},
      {key:'bonus',label:'Bonus / Incentive',type:'number'},
      {key:'overtime',label:'Overtime pay',type:'number'},
      {key:'tax',label:'Tax (PAYE)',type:'number'},
      {key:'pension',label:'Pension',type:'number'},
      {key:'loan_deduction',label:'Loan repayment (this month)',type:'number'},
      {key:'other_deductions',label:'Other deductions',type:'number'},
      {key:'net_pay',label:'Net pay (auto)',type:'number',readonly:true,computeOnly:true,help:'Generated by database/payroll logic; not typed manually.'},
      {key:'method',label:'Payment method',type:'select',options:['bank transfer','cash','cheque','mobile money']},
      {key:'status',label:'Status',type:'select',options:['draft','approved','paid']}
    ]},
    staff_loans: { table:'staff_loans', title:'Staff loan / advance', cols:[
      {key:'staff_name',label:'Staff (pick from list)',type:'ref',refTable:'staff',refValue:'full_name',refExtra:['role'],refStore:'value',searchable:true,required:true},
      {key:'loan_type',label:'Type',type:'select',options:['salary advance','personal loan','emergency','cooperative']},
      {key:'principal',label:'Amount borrowed',type:'number',required:true},
      {key:'monthly_repayment',label:'Monthly repayment (EMI)',type:'number'},
      {key:'months',label:'Repayment months',type:'number'},
      {key:'amount_repaid',label:'Amount repaid so far',type:'number'},
      {key:'date_taken',label:'Date taken',type:'date'},
      {key:'status',label:'Status',type:'select',options:['active','completed','defaulted','written-off']},
      {key:'notes',label:'Notes',type:'textarea'}
    ]},
    staff_bonus: { table:'staff_bonus', title:'Bonus / Allowance award', cols:[
      {key:'staff_name',label:'Staff (pick from list)',type:'ref',refTable:'staff',refValue:'full_name',refExtra:['role'],refStore:'value',searchable:true,required:true},
      {key:'bonus_type',label:'Type',type:'select',options:['performance','13th month','holiday','long-service','referral','other']},
      {key:'amount',label:'Amount',type:'number',required:true},
      {key:'reason',label:'Reason / Citation',type:'textarea'},
      {key:'award_date',label:'Award date',type:'date'},
      {key:'status',label:'Status',type:'select',options:['pending','approved','paid']}
    ]},
    appraisals: { table:'staff_appraisals', title:'Staff appraisal', cols:[
      {key:'staff_name',label:'Staff (pick from list)',type:'ref',refTable:'staff',refValue:'full_name',refExtra:['role'],refStore:'value',searchable:true,required:true},
      {key:'period',label:'Appraisal period',type:'text',help:'e.g. 2025/2026 Term 1'},
      {key:'punctuality',label:'Punctuality (1-10)',type:'number'},
      {key:'teaching_quality',label:'Teaching quality (1-10)',type:'number'},
      {key:'student_results',label:'Student results (1-10)',type:'number'},
      {key:'teamwork',label:'Teamwork (1-10)',type:'number'},
      {key:'conduct',label:'Conduct & ethics (1-10)',type:'number'},
      {key:'total_score',label:'Total / Grade (auto)',type:'text',help:'auto-computed average & band'},
      {key:'recommendation',label:'Recommendation',type:'select',options:['promote','retain','train','warn','commend']},
      {key:'comments',label:'Appraiser comments',type:'textarea'},
      {key:'appraiser',label:'Appraised by',type:'ref',refTable:'staff',refValue:'full_name',refStore:'value',searchable:true}
    ]},
    school_fees: { table:'class_fee_structure', title:'Class / Department Fee Structure', help:'Define current-term and next-term bills by class, arm and department. The matching next-term bill is printed automatically on each student report card; previous balances come from fee payment records.', cols:[
      {key:'class',label:'Class',type:'ref',refTable:'classes',refValue:'name',required:true},
      {key:'arm',label:'Arm / Stream (select from dropdown — no typing)',type:'lookup',lookupKind:'arm',help:'Pick from existing arms (A/B/C/D) — created in Academic Setup > Lookups. No manual typing — prevents typos.'},
      {key:'department',label:'Department / Section',type:'ref',refTable:'departments',refValue:'name',refStore:'value',help:'Optional: Nursery, Primary, Junior Secondary, Science, Arts, Boarding, etc.'},
      {key:'term',label:'Term scope',type:'select',options:['Current Term','Next Term'],required:true},
      {key:'session',label:'Session',type:'lookup',lookupKind:'session'},
      {key:'tuition',label:'Tuition fee',type:'number'},
      {key:'exam_fee',label:'Exam / assessment fee',type:'number'},
      {key:'development',label:'Development / PTA levy',type:'number'},
      {key:'transport',label:'Transport fee',type:'number'},
      {key:'boarding',label:'Boarding / hostel fee',type:'number'},
      {key:'other_fee',label:'Other compulsory fee',type:'number'},
      {key:'discount',label:'Discount amount',type:'number'},
      {key:'total',label:'Total bill (auto-fill or override)',type:'number',help:'If left 0, report cards calculate the total from the fee components.'},
      {key:'due_date',label:'Due date',type:'date'},
      {key:'next_term_begins',label:'Next term begins',type:'date'},
      {key:'note',label:'Payment note / bank instruction',type:'textarea'}
    ]},
    school_products: { table:'school_products', title:'School Product', cols:[
      {key:'name',label:'Product name',type:'text',required:true},
      {key:'category',label:'Category',type:'select',options:['Uniform','Textbook','Exercise Book','Stationery','Bag','Other'],required:true},
      {key:'price',label:'Price',type:'number'},
      {key:'size_option',label:'Size / Options (e.g. M, L, XL or 40-leaves)',type:'text'},
      {key:'stock_note',label:'Stock status / Note',type:'text'}
    ]},
    status_manager: { table:'role_status_log', title:'Role & Status Manager', help:'Clear, unambiguous workflow: pick an existing platform user from dropdown (no typing), system auto-fills previous role and email. Assign new role, choose action, save. Every change is audited (who changed, when, why). First-time admin guide: 1) Select person. 2) Review auto-filled previous role. 3) Pick new role & action. 4) Add reason. 5) Save — profile updates instantly + activity log recorded.', cols:[
      {key:'person_id',label:'Select Person (from existing platform users — dropdown)',type:'ref',refTable:'profiles',refValue:'full_name',refExtra:['email','role','status'],refStore:'id',searchable:true,required:true,help:'Dropdown of all registered users — mandatory. Auto-fills name and previous role below — no manual typing.',autofill:{person_name:'full_name',previous_role:'role'}},
      {key:'person_name',label:'Person full name (auto-filled from selection)',type:'text',readonly:true,help:'Auto-filled; you can manually override only if creating audit for non-user'},
      {key:'previous_role',label:'Previous / Current role (auto-filled)',type:'text',readonly:true,help:'Auto-filled from selected profile — shows role before change'},
      {key:'new_role',label:'New role to assign',type:'select',options:['super_admin','admin','principal','proprietor','head_teacher','staff','teacher','parent','student','bursar'],required:true,help:'Choose the target role'},
      {key:'action',label:'Action type',type:'select',options:['promote','demote','convert','suspend','reactivate','deactivate'],required:true,help:'Why changing? Promote, convert, suspend, etc.'},
      {key:'reason',label:'Reason for change (audit)',type:'textarea',help:'Explain reason for audit trail — e.g. Appointment letter reference'},
      {key:'changed_by',label:'Authorized by (auto)',type:'text',help:'Leave blank — auto-filled with current admin name'}
    ]}
  },

  fid(key){ return String(key).replace(/[^a-z0-9_-]/gi,'_'); },
  formatDate(v){ if(!v) return ''; const d=new Date(v); if(isNaN(d)) return v; return String(d.getDate()).padStart(2,'0')+'/'+String(d.getMonth()+1).padStart(2,'0')+'/'+d.getFullYear(); },

  /* ---- Generic (module_records-backed) modules: every previously "no form"
     module (issue 8) now has a working Add/Edit/Delete screen. The shared
     columns (title/body/status/ref_date/amount) cover most needs; extra fields
     go into data{}. ---- */
  GENERIC: {
    messages:    { title:'Message',      cols:[['title','Subject','text',true],['body','Message','textarea'],['recipient_id','Recipient account (optional)','ref-profiles'],['audience','Audience','select',['private','all','staff','parent','student']],['data.to','To (name/role)','text']] },
    inbox:       { title:'Inbox message',cols:[['title','Subject','text',true],['body','Message','textarea'],['recipient_id','Recipient account (optional)','ref-profiles'],['audience','Audience','select',['private','all','staff','parent','student']],['data.from','From','text'],['status','Status','select',['unread','read','archived']]] },
    broadcast:   { title:'Result Broadcast',cols:[['title','Title','text',true],['body','Message','textarea'],['data.channel','Channel','select',['whatsapp','email','sms','in-app']],['data.audience','Audience','lookup','audience']] },
    reports:     { title:'Report',       cols:[['title','Report title','text',true],['data.type','Type','text'],['body','Summary / notes','textarea'],['ref_date','Date','date']] },
    school_calendar:{ title:'Calendar event',cols:[['title','Event','text',true],['ref_date','Date','date',true],['body','Details','textarea'],['data.category','Category','select',['holiday','exam','mid-term','term-start','term-end','event']]] },
    lost_found:  { title:'Lost & Found item',cols:[['title','Item','text',true],['data.kind','Kind','select',['lost','found']],['body','Description','textarea'],['data.location','Location','text'],['ref_date','Date','date'],['status','Status','select',['open','claimed','returned']]] },
    parent_meeting:{ title:'PTA Meeting',cols:[['title','Topic','text',true],['ref_date','Date','date',true],['data.time','Time','time'],['data.venue','Venue','text'],['body','Agenda / minutes','textarea']] },
    book_request:{ title:'Book request', cols:[['title','Book title','text',true],['data.student','Student','ref-students'],['status','Status','select',['requested','reserved','issued','returned']],['ref_date','Date','date']] },
    lms:         { title:'LMS course/lesson',cols:[['title','Title','text',true],['data.subject','Subject','ref-subjects'],['data.class','Class','ref-classes'],['body','Content / description','textarea'],['data.video','Video/Drive link','text']] },
    gamification:{ title:'Reward / badge',cols:[['title','Badge/Reward','text',true],['data.student','Student','ref-students'],['amount','Points','number'],['body','Reason','textarea']] },
    cafeteria:   { title:'Cafeteria item',cols:[['title','Item','text',true],['amount','Price','number'],['data.category','Category','select',['breakfast','snack','lunch','drink']],['body','Notes','textarea']] },
    financial_aid:{ title:'Scholarship/Aid',cols:[['title','Scheme','text',true],['data.student','Student','ref-students'],['amount','Amount/Waiver','number'],['status','Status','select',['applied','approved','renewed','ended']],['body','Notes','textarea']] },
    front_desk:  { title:'Front-desk log',cols:[['title','Subject','text',true],['data.kind','Type','select',['call','dispatch','walk-in','inquiry']],['body','Details','textarea'],['data.contact','Contact','text'],['ref_date','Date','date']] },
    career_counseling:{ title:'Career record',cols:[['title','Title','text',true],['data.student','Student','ref-students'],['body','Guidance / offers','textarea'],['data.university','University/Placement','text']] },
    document_builder:{ title:'Custom Document', help:'Build any official school document (hall ticket, bonafide letter, testimonial…): 1) Pick the document type. 2) Choose who it is for. 3) Type the body text — use [NAME], [CLASS], [DATE] placeholders. 4) Save, then press Print on the row to output a letterheaded, signed document.', cols:[['title','Document title (e.g. Bonafide Letter — Ada Obi)','text',true],['data.type','Document type','select',['hall ticket','bonafide certificate','recommendation letter','transfer letter','testimonial','invitation letter','fee clearance','custom']],['data.student','For (student — optional)','ref-students'],['data.recipient','Addressed to (e.g. The Embassy, Parent)','text'],['body','Body text — placeholders [NAME] [CLASS] [DATE] are replaced at print time','textarea',true],['status','Status','select',['draft','final','issued']]] },
    fleet_tracking:{ title:'Fleet log',cols:[['title','Vehicle/Route','text',true],['data.driver','Driver','text'],['body','Notes / location','textarea'],['ref_date','Date','date']] },
    facility_booking:{ title:'Facility booking',cols:[['title','Facility','text',true],['ref_date','Date','date',true],['data.time','Time','time'],['data.bookedby','Booked by','text'],['status','Status','select',['requested','approved','cancelled']]] },
    compliance:  { title:'Compliance item',cols:[['title','Item','text',true],['data.category','Category','select',['accreditation','fire drill','inspection','statutory']],['ref_date','Date','date'],['status','Status','select',['pending','passed','failed','due']],['body','Notes','textarea']] },
    payments_online:{ title:'Online payment',cols:[['title','Reference','text',true],['data.student','Student','ref-students'],['amount','Amount','number',true],['data.provider','Provider','select',['paystack','flutterwave','bank_transfer']],['status','Status','select',['pending','paid','failed','cancelled']]],},
    /* update v4: international-standard additions */
    rubrics:     { title:'Grading rubric (standards-based)',cols:[['title','Skill / standard','text',true],['data.subject','Subject','ref-subjects'],['data.class','Class','ref-classes'],['data.criteria','Criteria (one per line)','textarea'],['data.scale','Scale','select',['1-4 (Beginning–Exceeding)','A-F','1-10','Pass/Merit/Distinction']],['body','Descriptor / notes','textarea']] },
    transcripts: { title:'Transcript / academic record',cols:[['data.student','Student','ref-students'],['title','Session / year','text',true],['data.term','Term','lookup','term'],['data.gpa','GPA / Average','text'],['body','Subjects & grades (summary)','textarea'],['data.remark','Cumulative remark','text']] },
    transfer_cert:{ title:'Transfer / leaving certificate',cols:[['data.student','Student','ref-students'],['title','Certificate No','text',true],['data.last_class','Last class','ref-classes'],['data.reason','Reason for leaving','select',['relocation','graduation','transfer','withdrawal','other']],['ref_date','Date of leaving','date'],['data.conduct','Conduct','select',['excellent','good','satisfactory','fair']],['body','Remarks','textarea']] },
    counselling: { title:'Counselling / wellbeing session',cols:[['data.student','Student','ref-students'],['title','Topic','text',true],['data.counsellor','Counsellor','text'],['ref_date','Date','date'],['body','Notes (confidential)','textarea'],['status','Status','select',['open','ongoing','closed','referred']]] }
  },

  /* Resolve a module to a normalized definition. Generic modules are backed by
     the shared module_records table; their compact [key,label,type,...] tuples
     are expanded into full column objects with relational helpers. */
  canonicalId(moduleId){
    const map = {'academic-records':'academic_records','admin-data':'admin_data','report-cards':'report_cards','cbt-prompts':'cbt_prompts','cbt-exam':'cbt_exam','timetable-generator':'timetable_generator','student-profile':'student_profile','feature-guide':'feature_guide','verify-certificate':'verify_certificate'};
    return map[moduleId] || String(moduleId || '').replace(/-/g,'_');
  },

  def(moduleId){
    const key = this.canonicalId(moduleId);
    if (this.SCHEMA[key]) return this.SCHEMA[key];
    const g = this.GENERIC[key] || this.GENERIC[moduleId];
    if (!g) return null;
    const cols = g.cols.map(t => {
      const [key, label, type, extra, extra2] = t;
      const c = { key, label, type: type || 'text' };
      if (type === 'select') c.options = extra;
      else if (type === 'lookup') c.lookupKind = extra;
      else if (type === 'ref-students') { c.type='ref'; c.refTable='students'; c.refValue='full_name'; c.refStore='value'; }
      else if (type === 'ref-classes') { c.type='ref'; c.refTable='classes'; c.refValue='name'; }
      else if (type === 'ref-subjects') { c.type='ref'; c.refTable='subjects'; c.refValue='name'; c.refStore='value'; }
      else if (type === 'ref-profiles') { c.type='ref'; c.refTable='profiles'; c.refValue='full_name'; c.refExtra=['email','role']; c.refStore='id'; c.searchable=true; }
      if (extra === true || extra2 === true) c.required = true;
      return c;
    });
    return { table:'module_records', title:g.title, generic:true, module:(this.canonicalId(moduleId)), cols };
  },

  /* FIX v9: canWrite — use SC_PROFILE.role as fallback for async timing */
  canWrite(moduleId) {
    // Use both App.currentRole and SC_PROFILE.role as fallbacks
    // This ensures role is always available, even before async profile load
    const role = String(
      (window.App && App.currentRole) ||
      (window.SC_PROFILE && SC_PROFILE.role) ||
      document.body.dataset.currentRole ||
      ''
    ).toLowerCase().replace(/\s+/g,'_');
    const key = this.canonicalId(moduleId);
    const allow = this.WRITE_RULES[key];
    const adminAliases = ['super_admin','superadmin','admin','administrator','owner','director','principal','proprietor','head_teacher','headteacher','bursar'];
    if (adminAliases.includes(role) || (window.App && App.isAdminRole && App.isAdminRole(role))) return true;
    if (window.App && App.canWriteByAccess) { const mapped = App.canWriteByAccess(key, role); if (mapped !== null) return mapped; }
    if (!allow) return ['staff','teacher'].includes(role);
    return allow.includes(role);
  },

  /* Render the list table for a module page */
  /* FIX v9: renderList now supports role-based filtering
     - Students see only their own data (filtered by student_id)
     - Parents see only their linked children's data
     - Staff/Admin see all data (no filter)
  */
  // The last visible records are session-scoped by user/role/module; never use a shared cache.
  stableTableCacheKey(moduleId, suffix='') {
    const uid = (window.SC_PROFILE && SC_PROFILE.id) || 'guest';
    const role = (window.SC_PROFILE && SC_PROFILE.role) || (window.App && App.currentRole) || 'guest';
    return 'sc-table-cache:' + role + ':' + uid + ':' + moduleId + ':' + suffix;
  },

  async renderList(moduleId, options = {}) {
    const d = this.def(moduleId);
    const key = this.canonicalId(moduleId);
    const tableEl = document.getElementById(moduleId + '-table') || document.getElementById(key + '-table');
    if (!tableEl) return;
    if (!d) { tableEl.querySelector('thead').innerHTML = '<tr><th>Not available</th></tr>'; return; }
    if (!this.sb) {
      tableEl.querySelector('thead').innerHTML = '<tr><th>Database not configured</th></tr>';
      tableEl.querySelector('tbody').innerHTML = '<tr><td>Add your Supabase keys in assets/js/config.js</td></tr>';
      return;
    }

    // Get current user and role for filtering
    const currentUserId = window.SC_PROFILE?.id || null;
    const currentRole = String(window.SC_PROFILE?.role || window.App?.currentRole || '').toLowerCase();
    const isStudent = currentRole === 'student';
    const isParent = currentRole === 'parent';

    // Non-admin data scoping: never show another learner/family's private records.
    // strictStudentModules = one learner only; classAssignedModules = class-wide resources like assignments/e-resources.
    const strictStudentModules = ['results', 'attendance', 'fees', 'report_cards', 'certificates', 'payments_online'];
    // Identity documents are also learner-owned, but kept separate so fee/payment scoping stays explicit and regression-testable.
    const identityScopedModules = ['idcards'];
    const strictStudentLikeModules = strictStudentModules.concat(identityScopedModules);
    const classAssignedModules = ['assignments', 'eresources', 'digital_library', 'library_borrowers', 'timetable'];
    const messageModules = ['messages', 'inbox', 'complaints', 'helpdesk'];
    const studentOwnedModules = strictStudentLikeModules.concat(classAssignedModules, messageModules);
    const parentViewModules = strictStudentLikeModules.concat(['assignments', 'messages', 'inbox', 'complaints', 'helpdesk']);
    const requestedStudentId = new URLSearchParams(location.search).get('student') || '';
    const cacheKey = this.stableTableCacheKey(moduleId, requestedStudentId || 'all');

    // Build query with role-based filtering
    const listTable = d.listTable || d.table;
    const listCols = d.listCols || d.cols;
    const orderCol = d.listOrder || (d.listTable ? 'id' : 'created_at');
    let query = d.generic
      ? this.sb.from(listTable).select('*').eq('module', d.module).order(orderCol, { ascending: false }).limit(500)
      : this.sb.from(listTable).select('*').order(orderCol, { ascending: false }).limit(500);

    // Role-based filtering is applied after fetching because different tables use
    // either student_id, student_name or class-level fields. Supabase RLS remains the
    // final security layer.

    let { data, error } = await query;
    // ENTERPRISE V6 (issue 17): some views (e.g. parent_child_view on older
    // schemas) lack the order column — retry unordered instead of erroring.
    if (error && /column .* does not exist/i.test(error.message || '')) {
      const rq = d.generic
        ? this.sb.from(listTable).select('*').eq('module', d.module).limit(500)
        : this.sb.from(listTable).select('*').limit(500);
      ({ data, error } = await rq);
    }
    const cols = d.listCols || d.cols;
    const writable = this.canWrite(moduleId) && (!d.readOnly || (window.App && App.isAdminRole && App.isAdminRole(currentRole)));
    const cellVal = (row, c) => c.key.indexOf('data.') === 0 ? ((row.data || {})[c.key.slice(5)]) : row[c.key];
    const head = '<tr>' + cols.map(c => '<th>' + esc(c.label) + '</th>').join('') + (writable ? '<th>Actions</th>' : '') + '</tr>';
    tableEl.querySelector('thead').innerHTML = head;
    const tb = tableEl.querySelector('tbody');
    if (error) {
      let cached = null; try { cached = JSON.parse(sessionStorage.getItem(cacheKey) || 'null'); } catch(_) {}
      if (cached && cached.html) { tb.innerHTML = cached.html + '<tr><td colspan="' + (cols.length + (writable ? 1 : 0)) + '" style="color:#b45309;background:#fffbeb">Live refresh failed; showing the last visible records so they do not disappear. ' + esc(error.message) + '</td></tr>'; return; }
      tb.innerHTML = '<tr><td colspan="' + (cols.length + (writable ? 1 : 0)) + '">' + esc(error.message) + '</td></tr>'; return;
    }

    // Additional filtering for students and parents - get linked IDs/names and filter data
    let filteredData = data || [];
    if (isStudent && studentOwnedModules.includes(key) && currentUserId) {
      try {
        const { data: st } = await this.sb.from('students').select('id,full_name,class,admission_no,user_id').eq('user_id', currentUserId).maybeSingle();
        if (!st) { filteredData = []; }
        else {
          const stName = String(st.full_name || '').toLowerCase();
          const stClass = String(st.class || '').toLowerCase();
          const stAdm = String(st.admission_no || '').toLowerCase();
          const ownRecord = (r) => r.student_id === st.id || r.student_id_ref === st.id || r.person_id === st.id || r.user_id === currentUserId ||
            (r.student_name && String(r.student_name).toLowerCase() === stName) ||
            (r.admission_no && String(r.admission_no).toLowerCase() === stAdm) ||
            (r.data && r.data.student && String(r.data.student).toLowerCase() === stName) ||
            (r.data && r.data.student_name && String(r.data.student_name).toLowerCase() === stName) ||
            (r.data && r.data.admission_no && String(r.data.admission_no).toLowerCase() === stAdm) ||
            (r.data && r.data.person_id && String(r.data.person_id) === String(st.id));
          const classRecord = (r) => (r.class && String(r.class).toLowerCase() === stClass) ||
            (r.student_class && String(r.student_class).toLowerCase() === stClass) ||
            (r.data && r.data.class && String(r.data.class).toLowerCase() === stClass);
          const myMessage = (r) => r.created_by === currentUserId || r.submitted_by === currentUserId || r.recipient_id === currentUserId ||
            (r.data && (r.data.recipient_id === currentUserId || String(r.data.to || '').toLowerCase().includes(stName) || String(r.data.student || '').toLowerCase() === stName || String(r.data.admission_no || '').toLowerCase() === stAdm));
          filteredData = (data || []).filter(r => strictStudentLikeModules.includes(key) ? ownRecord(r) : (classAssignedModules.includes(key) ? (ownRecord(r) || classRecord(r)) : myMessage(r)));
        }
      } catch(e) { console.warn('Student filter failed:', e); filteredData = []; }
    }
    if (isParent && parentViewModules.includes(key) && currentUserId) {
      try {
        const { data: links } = await this.sb.from('parent_child').select('student_id').eq('parent_id', currentUserId);
        if (links && links.length > 0) {
          let childIds = links.map(l => l.student_id).filter(Boolean);
          if (requestedStudentId && childIds.includes(requestedStudentId)) childIds = [requestedStudentId];
          const { data: kids } = await this.sb.from('students').select('id,full_name,class,admission_no').in('id', childIds).then(r=>r, ()=>({data:[]}));
          const childNames = (kids || []).map(k => String(k.full_name || '').toLowerCase()).filter(Boolean);
          const childClasses = (kids || []).flatMap(k => [k.class]).map(x => String(x || '').toLowerCase()).filter(Boolean);
          const childAdm = (kids || []).map(k => String(k.admission_no || '').toLowerCase()).filter(Boolean);
          const childOwn = (r) => childIds.includes(r.student_id) || childIds.includes(r.student_id_ref) || childIds.includes(r.person_id) ||
            (r.student_name && childNames.includes(String(r.student_name).toLowerCase())) ||
            (r.admission_no && childAdm.includes(String(r.admission_no).toLowerCase())) ||
            (r.data && r.data.student && childNames.includes(String(r.data.student).toLowerCase())) ||
            (r.data && r.data.student_name && childNames.includes(String(r.data.student_name).toLowerCase())) ||
            (r.data && r.data.person_id && childIds.includes(String(r.data.person_id)));
          const childClass = (r) => (r.class && childClasses.includes(String(r.class).toLowerCase())) ||
            (r.student_class && childClasses.includes(String(r.student_class).toLowerCase())) ||
            (r.data && r.data.class && childClasses.includes(String(r.data.class).toLowerCase()));
          const myMessage = (r) => r.created_by === currentUserId || r.submitted_by === currentUserId || r.recipient_id === currentUserId || (r.data && (r.data.recipient_id === currentUserId || childNames.includes(String(r.data.student || '').toLowerCase()) || childAdm.includes(String(r.data.admission_no || '').toLowerCase())));
          filteredData = (data || []).filter(r => strictStudentLikeModules.includes(key) ? childOwn(r) : (key === 'assignments' ? (childOwn(r) || childClass(r)) : (messageModules.includes(key) ? myMessage(r) : childOwn(r))));
        } else filteredData = [];
      } catch(e) { console.warn('Parent filter failed:', e); filteredData = []; }
    }

    // FIX V2.1 — Persistent table: never clear existing rows when filtered result is empty.
    // This resolves issue #1 where parent/student pages flashed data then disappeared.
    // Strategy: keep cached HTML or existing DOM, show informative banner above table.
    if (!filteredData || !filteredData.length) {
      let cached = null;
      try { cached = JSON.parse(sessionStorage.getItem(cacheKey) || 'null'); } catch(_) {}
      const wrap = tableEl.closest('.table-wrap') || tableEl.parentNode;
      let infoBox = wrap ? wrap.querySelector('.sc-table-persist-info') : null;
      if (!infoBox && wrap) {
        infoBox = document.createElement('div');
        infoBox.className = 'sc-table-persist-info';
        infoBox.style.cssText = 'background:#eff6ff;border:1px solid #bfdbfe;padding:12px 14px;border-radius:10px;margin-bottom:14px;color:#1e40af;font-size:.9rem;line-height:1.5';
        wrap.insertBefore(infoBox, wrap.firstChild);
      }
      const dataCount = (data || []).length;
      let msg = '';
      if (isParent) {
        msg = dataCount > 0
          ? `ℹ️ <strong>No linked records found</strong> — Database has ${dataCount} record(s) but none are linked to your children. Ask admin to link via <em>Parents → Parent-Child Link</em>. Previous records (if any) are preserved below so you can continue reading.`
          : 'ℹ️ No records yet — Ask admin to create records and link your children via Parents page.';
      } else if (isStudent) {
        msg = dataCount > 0
          ? `ℹ️ <strong>No records linked to your profile</strong> — Database has ${dataCount} record(s) but your student profile is not linked. Ask admin to set your <em>user_id</em> in Students table. Previous records preserved below.`
          : 'ℹ️ No records yet.';
      } else {
        msg = dataCount > 0
          ? `ℹ️ Database has ${dataCount} record(s) but none match the current filter. Showing previously cached records if available.`
          : 'No records yet.' + (writable ? ' Click “+ Add new”.' : '');
      }
      if (infoBox) infoBox.innerHTML = msg;

      if (cached && cached.html) {
        tb.innerHTML = cached.html;
        // inject search again
        try { CRUD.injectTableSearch(moduleId, tableEl, (dataCount || 0)); } catch(_) {}
        return;
      }
      // If table already has real rows (not loading placeholder), keep them
      const existingHasRows = tb.querySelectorAll('tr').length > 0 && !tb.querySelector('tr td')?.textContent?.includes('No records yet');
      const existingHTML = tb.innerHTML;
      const hasRealRows = existingHTML && !existingHTML.includes('No records yet') && !existingHTML.includes('pulse') && existingHTML.trim().length > 20;
      if (hasRealRows) {
        // Keep existing rows, do not clear
        return;
      }
      tb.innerHTML = '<tr><td colspan="' + (cols.length + (writable ? 1 : 0)) + '" style="color:var(--gray-500);padding:20px;text-align:center" class="empty-msg">' + msg + '</td></tr>';
      return;
    }
    
    const isLinkCol = (key) => /(_link|link|media_url|photo_url|video|image|thumbnail|read_link|drive)$/i.test(key) || /^(media_url|read_link|drive_link|photo_url)$/i.test(key);
    const renderedRows = filteredData.map(row => '<tr>' + cols.map(c => {
      let v = cellVal(row, c);
      // ENTERPRISE FINAL V2 (#8): fee balance reflects in every record —
      // auto-compute for display when the stored value is missing.
      if (c.key === 'balance' && v == null && row.fee_total != null) v = Math.max(0, (Number(row.fee_total) || 0) - (Number(row.amount_paid) || 0));
      if (c.type === 'checkbox') v = v ? '✓' : '';
      if (v && (c.type === 'date' || c.type === 'datetime' || /(^|_)(date|dob|created_at|issued_on|due_date|ref_date)$/i.test(c.key))) v = CRUD.formatDate(v);
      // Issue 11: render link columns as image/video thumbnails when possible.
      if (v && isLinkCol(c.key) && window.Super && Super.media) {
        const k = Super.media.kind(String(v));
        if (k !== 'none' && k !== 'link') return '<td>' + Super.media.thumb(String(v), { w: 96, h: 64 }) + '</td>';
        return '<td><a href="' + esc(String(v)) + '" target="_blank" rel="noopener">🔗 link</a></td>';
      }
      return '<td>' + esc(String(v == null ? '' : v)).slice(0, 80) + '</td>';
    }).join('') + (!writable ? '' :
      '<td style="white-space:nowrap">' +
        (moduleId === 'students' ? '<a class="btn btn-sm btn-primary" href="student-profile.html?student=' + row.id + '">Dashboard</a> ' : '') +
        (moduleId === 'staff' ? '<a class="btn btn-sm btn-primary" href="teacher-overview.html?staff=' + row.id + '">Teacher overview</a> ' : '') +
        (moduleId === 'parent_child' ? '<button class="btn btn-sm btn-outline" onclick="CRUD.remove(\'parent_child\',\'' + row.id + '\')">Unlink</button> ' : '') +
        ((moduleId === 'payroll' || moduleId === 'hr') ? '<button class="btn btn-sm btn-primary" onclick="CRUD.printPayslip(\'' + row.id + '\')">Payslip</button> ' : '') +
        (moduleId === 'fees' ? '<button class="btn btn-sm btn-primary" onclick="CRUD.printReceipt(\'' + row.id + '\')">Print E-Receipt</button> ' : '') +
        (moduleId === 'admissions' ? '<button class="btn btn-sm btn-primary" onclick="CRUD.previewAdmission(\'' + row.id + '\')">Preview</button> ' : '') +
        (moduleId === 'document_builder' ? '<button class="btn btn-sm btn-primary" onclick="CRUD.printDocument(\'' + row.id + '\')">🖨 Print</button> ' : '') +
        '<button class="btn btn-sm btn-outline" onclick="CRUD.openForm(\'' + moduleId + '\',\'' + row.id + '\')">Edit</button> ' +
        '<button class="btn btn-sm btn-outline" onclick="CRUD.remove(\'' + moduleId + '\',\'' + row.id + '\')">Delete</button>' +
      '</td>') + '</tr>').join('');
    tb.innerHTML = renderedRows;
    try { sessionStorage.setItem(cacheKey, JSON.stringify({ at: Date.now(), html: renderedRows })); } catch(_) {}
    // re-apply role visibility to the freshly-rendered action buttons
    if (window.App && App.applyVisibilityTokens) try { App.applyVisibilityTokens(App.currentRole || (window.SC_PROFILE && SC_PROFILE.role) || ''); } catch (e) {}
    // ENHANCEMENT (#2): inject a live instant-search box above every module
    // table so recipients can find any record instantly. Persists the query.
    CRUD.injectTableSearch(moduleId, tableEl, filteredData.length);
  },

  /** Instant per-table search — enhances EVERY CRUD module page at once. */
  injectTableSearch(moduleId, tableEl, rowCount) {
    if (!tableEl) return;
    const wrap = tableEl.closest('.table-wrap') || tableEl.parentNode;
    if (!wrap || wrap.querySelector('.sc-table-search')) {
      // already injected — just refresh the count
      const count = wrap.querySelector('.sc-table-count');
      if (count) count.textContent = rowCount + ' record' + (rowCount === 1 ? '' : 's');
      return;
    }
    const box = document.createElement('div');
    box.className = 'sc-table-search';
    box.style.cssText = 'display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:12px';
    const saved = '';
    try { /* q lives for the session per module */ } catch(_) {}
    box.innerHTML =
      '<input class="form-input sc-table-q" placeholder="🔍 Search this table…" ' +
      'style="flex:1;min-width:200px;max-width:420px;padding:9px 12px;border:1px solid var(--gray-200,#e2e8f0);border-radius:10px;font-size:.9rem" ' +
      'data-module="' + moduleId + '">' +
      '<span class="sc-table-count" style="font-size:.8rem;color:var(--gray-500,#64748b);font-weight:700">' + rowCount + ' record' + (rowCount === 1 ? '' : 's') + '</span>';
    wrap.insertBefore(box, wrap.firstChild === tableEl ? tableEl : (wrap.querySelector('table') || tableEl));
    const q = box.querySelector('.sc-table-q');
    q.addEventListener('input', function () {
      const term = this.value.trim().toLowerCase();
      const rows = tableEl.querySelectorAll('tbody tr');
      let shown = 0;
      rows.forEach(function (r) {
        if (r.querySelector('.pulse')) return;            // skip loading / error rows
        const match = !term || r.textContent.toLowerCase().indexOf(term) !== -1;
        r.style.display = match ? '' : 'none';
        if (match) shown++;
      });
      const count = box.querySelector('.sc-table-count');
      if (count) count.textContent = term ? (shown + ' of ' + rows.length + ' match') : (rowCount + ' record' + (rowCount === 1 ? '' : 's'));
    });
  },

  /* Open the add/edit modal with a REAL form */
  /* ---- option-source cache so dropdowns load once per form ---- */
  _optCache: {},
  dedupeOptions(options) { const seen=new Set(); return (options||[]).filter(o=>{ const label=String(o.label==null?'':o.label).replace(/\s+/g,' ').trim().toLowerCase(); const value=String(o.value==null?'':o.value).trim().toLowerCase(); const key=label||value; if(!key) return false; if(seen.has(key)) return false; seen.add(key); return true; }); },

  async loadOptions(c) {
    // c.type 'ref'    -> {refTable, refValue(col used as text), refExtra?}
    // c.type 'lookup' -> {lookupKind}
    if (!this.sb) return [];
    try {
      if (c.type === 'ref') {
        const extra = c.refExtra || [];
        const grpCols = c.groupBy ? [c.groupBy] : [];
        const allExtra = Array.from(new Set(extra.concat(grpCols)));
        const cols = ['id', c.refValue].concat(allExtra).join(',');
        let q = this.sb.from(c.refTable).select(cols).order(c.refValue, { ascending: true }).limit(2000);
        // refFilter: only show matching rows (e.g. only teaching staff as class teachers)
        if (c.refFilter) Object.keys(c.refFilter).forEach(k => { try { q = q.eq(k, c.refFilter[k]); } catch (e) {} });
        const { data } = await q;
        return this.dedupeOptions((data || []).map(r => ({
          value: c.refStore === 'id' ? r.id : r[c.refValue],
          label: r[c.refValue] + (extra.length && r[extra[0]] ? ' (' + r[extra[0]] + ')' : ''),
          group: c.groupBy ? (r[c.groupBy] || 'Unassigned') : null,
          row: r
        })));
      }
      if (c.type === 'lookup') {
        const { data } = await this.sb.from('lookups').select('value').eq('kind', c.lookupKind).order('position');
        return this.dedupeOptions((data || []).map(r => ({ value: r.value, label: r.value })));
      }
    } catch (e) { /* table may be empty/missing */ }
    return this.dedupeOptions((c.options || []).map(o => ({ value: o, label: o })));
  },

  isOwnedByCurrent(row) {
    if (!row) return true;
    const uid = window.SC_PROFILE?.id || '';
    const uname = String(window.SC_PROFILE?.full_name || '').toLowerCase();
    const checks = [row.teacher_id, row.posted_by, row.recorded_by_id, row.created_by, row.submitted_by, row.generated_by, row.assignee];
    if (checks.some(v => v && uid && String(v) === String(uid))) return true;
    if (row.teacher && uname && String(row.teacher).toLowerCase() === uname) return true;
    if (row.recorded_by && uname && String(row.recorded_by).toLowerCase() === uname) return true;
    if (row.data && row.data.created_by && uid && String(row.data.created_by) === String(uid)) return true;
    return false;
  },

  hasOwnershipMarker(row) {
    if (!row) return false;
    return !!(row.teacher_id || row.posted_by || row.recorded_by_id || row.created_by || row.submitted_by || row.generated_by || row.assignee || row.teacher || row.recorded_by || (row.data && row.data.created_by));
  },

  async openForm(moduleId, id) {
    const d = this.def(moduleId);
    if (!d) { toast('This module has no editable form.', 'warning'); return; }
    if (!this.canWrite(moduleId)) { toast('Read-only for your role on this page.', 'warning', 5000); return; }
    if (!this.sb) { toast('Database not configured (add Supabase keys in assets/js/config.js).', 'warning', 6000); return; }
    let row = {};
    if (id) { const { data } = await this.sb.from(d.table).select('*').eq('id', id).maybeSingle(); row = data || {}; }
    if (window.App && !App.isAdminRole(App.currentRole) && row && this.hasOwnershipMarker(row) && !this.isOwnedByCurrent(row)) {
      toast('Access Denied: You can read this record, but only the creator/assigned owner or an admin can edit it.', 'danger', 7000);
      return;
    }
    // Pre-load any ref/lookup/select option sources
    const getVal = (k) => k.indexOf('data.') === 0 ? ((row.data || {})[k.slice(5)]) : row[k];
    const fields = [];
    for (const c of d.cols) {
      const rv = getVal(c.key);
      const val = rv != null ? rv : (c.default != null ? c.default : '');
      const req = c.required ? ' required' : '';
      let field;
      if (c.type === 'textarea') {
        field = '<textarea class="form-input" id="cf-' + CRUD.fid(c.key) + '" rows="2"' + req + '>' + esc(val) + '</textarea>';
      } else if (c.type === 'ref' || c.type === 'lookup' || c.type === 'select') {
        const opts = this.dedupeOptions((c.type === 'select') ? (c.options || []).map(o => ({ value: o, label: o })) : await this.loadOptions(c));
        const onchg = (c.type === 'ref' && c.autofill) ? ' onchange="CRUD.onRefChange(\'' + moduleId + '\',\'' + c.key + '\',this)"' : '';
        const optHtml = (o) => '<option value="' + esc(o.value) + '"' + (String(val) === String(o.value) ? ' selected' : '') + (o.row ? ' data-row=\'' + esc(JSON.stringify(o.row)) + '\'' : '') + '>' + esc(o.label) + '</option>';
        let inner;
        if (c.groupBy && opts.some(o => o.group)) {
          // Group options by class (issue 11) for compact, easy navigation.
          const groups = {};
          opts.forEach(o => { const g = o.group || 'Unassigned'; (groups[g] = groups[g] || []).push(o); });
          inner = Object.keys(groups).sort().map(g => '<optgroup label="' + esc(g) + '">' + groups[g].map(optHtml).join('') + '</optgroup>').join('');
        } else {
          inner = opts.map(optHtml).join('');
        }
        const selId = 'cf-' + CRUD.fid(c.key);
        const selectHtml = '<select class="form-select" id="' + selId + '"' + onchg + '><option value="">— select —</option>' + inner + '</select>';
        if (c.groupBy && c.searchable && opts.some(o => o.group)) {
          // Issue 7: pick a class first, then only that class's students show;
          // plus a search box to find a student by typing a few letters.
          const classes = Array.from(new Set(opts.map(o => o.group || 'Unassigned'))).sort();
          const classFilter = '<select class="form-select" style="margin-bottom:6px" onchange="CRUD.filterRefByClass(\'' + selId + '\',this.value)"><option value="">— all classes —</option>' + classes.map(g => '<option>' + esc(g) + '</option>').join('') + '</select>';
          const searchBox = '<input class="form-input" style="margin-bottom:6px" placeholder="🔎 type a few letters of the name…" oninput="CRUD.filterRefBySearch(\'' + selId + '\',this.value)">';
          field = '<div data-ref-wrap="' + selId + '">' + classFilter + searchBox + selectHtml + '</div>';
        } else {
          field = selectHtml;
        }
      } else if (c.type === 'checkbox') {
        field = '<label style="display:inline-flex;gap:8px;align-items:center"><input type="checkbox" id="cf-' + CRUD.fid(c.key) + '"' + (val ? ' checked' : '') + '> ' + esc(c.label) + '</label>';
      } else if (c.type === 'time') {
        field = '<input class="form-input" id="cf-' + CRUD.fid(c.key) + '" type="time" value="' + esc(val) + '"' + req + '>';
      } else {
        field = '<input class="form-input" id="cf-' + CRUD.fid(c.key) + '" type="' + (c.type || 'text') + '" value="' + esc(val) + '"' + (c.readonly ? ' readonly' : '') + req + (c.placeholder ? ' placeholder="' + esc(c.placeholder) + '"' : '') + '>';
      }
      const labelHtml = (c.type === 'checkbox') ? '' : '<label>' + esc(c.label) + (c.required ? ' *' : '') + (c.help ? ' <span style="color:var(--gray-500);font-weight:400;font-size:.8rem">— ' + esc(c.help) + '</span>' : '') + '</label>';
      fields.push('<div class="form-group">' + labelHtml + field + '</div>');
    }
    openModal((id ? 'Edit ' : 'Add ') + d.title, fields.join(''),
      '<button class="btn btn-outline" onclick="closeModal()">Cancel</button>' +
      '<button class="btn btn-primary" onclick="CRUD.save(\'' + moduleId + '\',' + (id ? '\'' + id + '\'' : 'null') + ')">Save</button>');
    try { if (window.App && App.dedupeAllSelects) App.dedupeAllSelects(); } catch (_) {}
  },

  /* When a ref dropdown with autofill changes (e.g. pick a student), copy
     extra fields like the student's name and DOB into the form (issues 1 & 10). */
  onRefChange(moduleId, key, sel) {
    try {
      const opt = sel.options[sel.selectedIndex];
      const rowJson = opt && opt.getAttribute('data-row');
      if (!rowJson) return;
      const r = JSON.parse(rowJson);
      const d = this.def(moduleId);
      const c = d.cols.find(x => x.key === key);
      if (c && c.autofill) Object.keys(c.autofill).forEach(targetKey => {
        const srcCol = c.autofill[targetKey];
        const el = document.getElementById('cf-' + CRUD.fid(targetKey));
        if (el && r[srcCol] != null) el.value = r[srcCol];
      });
    } catch (e) {}
  },

  async save(moduleId, id) {
    try { return await this._saveInner(moduleId, id); }
    catch (e) {
      // ENTERPRISE V11 (issue 11): never fail silently — every unexpected
      // exception during save now surfaces as a visible error toast.
      console.error('[CRUD.save] unexpected error:', e);
      toast('Could not save: ' + (e && e.message ? e.message : 'unexpected error — see console'), 'danger', 8000);
    }
  },
  async _saveInner(moduleId, id) {
    const d = this.def(moduleId);
    if (!this.canWrite(moduleId)) { toast('Read-only for your role on this page.', 'warning', 5000); return; }
    if (!d || !this.sb) { toast('Database not configured.', 'warning'); return; }
    const payload = {};
    const dataObj = {};
    let missing = '';
    d.cols.forEach(c => {
      const el = document.getElementById('cf-' + CRUD.fid(c.key)); if (!el) return;
      let v = c.type === 'checkbox' ? el.checked : el.value;
      if (c.type === 'number') v = v === '' ? null : Number(v);
      if (c.type !== 'checkbox' && v === '') v = null;
      if (c.required && (v === null || v === '')) missing = c.label;
      if (c.computeOnly) return; // display-only helper field, not stored
      if (c.key.indexOf('data.') === 0) dataObj[c.key.slice(5)] = v; else payload[c.key] = v;
    });
    if (missing) { toast(missing + ' is required.', 'warning'); return; }
    if (d.generic) { payload.module = d.module; payload.data = dataObj; if (!payload.title && dataObj.title) payload.title = dataObj.title; if (!id && window.SC_PROFILE && SC_PROFILE.id) payload.created_by = SC_PROFILE.id; }
    if (!id && ['complaints','helpdesk_tickets'].includes(d.table) && window.SC_PROFILE && SC_PROFILE.id) payload.submitted_by = SC_PROFILE.id;
    if (!id && d.table === 'health' && window.SC_PROFILE && SC_PROFILE.id) { payload.recorded_by_id = SC_PROFILE.id; if (!payload.recorded_by && SC_PROFILE.full_name) payload.recorded_by = SC_PROFILE.full_name; }
    if (!id && ['academic_print_records','reports'].includes(d.table) && window.SC_PROFILE && SC_PROFILE.id) payload.generated_by = SC_PROFILE.id;
    // V6/V4: teacher-owned academic records. Admin can supervise all, but subject teachers
    // should not edit/delete another teacher's records.
    if (!id && window.SC_PROFILE && SC_PROFILE.id && !(window.App && App.isAdminRole && App.isAdminRole(App.currentRole))) {
      const ownedTables = ['results','assignments','scheme_of_work','lesson_plans','cbt_exams','attendance','health','helpdesk_tickets','reports'];
      if (ownedTables.includes(d.table)) {
        if (!payload.teacher_id) payload.teacher_id = SC_PROFILE.id;
        if (!payload.posted_by) payload.posted_by = SC_PROFILE.id;
        if (!payload.recorded_by && d.table === 'attendance') payload.recorded_by = SC_PROFILE.id;
        const hasTeacherCol = (d.cols || []).some(c => c.key === 'teacher');
        if (!payload.teacher && SC_PROFILE.full_name && hasTeacherCol) payload.teacher = SC_PROFILE.full_name;
      }
    }
    if (d.table === 'results' && !id) {
      payload.assessment_source = payload.assessment_source || 'manual';
    }
    // ENTERPRISE V6 (issue 27): net_pay is a DB-computed column (GENERATED or
    // trigger). Sending it caused: cannot insert a non-DEFAULT value into
    // column "net_pay". We now NEVER send it — the database computes it.
    if (d.table === 'payroll') { delete payload.net_pay; }
    // ENTERPRISE V11 (issue 13): auto-compute fee balance when blank
    if (d.table === 'fee_payments' && payload.balance == null && payload.fee_total != null) {
      payload.balance = Math.max(0, (Number(payload.fee_total) || 0) - (Number(payload.amount_paid) || 0));
    }
    // ENTERPRISE FINAL V2 (#8): normalise balance to a number when present
    if (d.table === 'fee_payments' && payload.balance != null) payload.balance = Number(payload.balance) || 0;
    // Issue 5: auto-compute appraisal average score + band
    if (d.table === 'staff_appraisals') {
      const keys = ['punctuality', 'teaching_quality', 'student_results', 'teamwork', 'conduct'];
      const vals = keys.map(k => Number(payload[k])).filter(v => !isNaN(v));
      if (vals.length) {
        const avg = Math.round((vals.reduce((a, b) => a + b, 0) / vals.length) * 10) / 10;
        const band = avg >= 8 ? 'Excellent' : avg >= 6.5 ? 'Very Good' : avg >= 5 ? 'Good' : avg >= 4 ? 'Fair' : 'Needs Improvement';
        payload.total_score = avg + '/10 — ' + band;
      }
    }
    // (res declared below by the self-healing save wrapper)
    
    // === v5 FIX: Auto-generate admission_no and staff_no starting with school acronym ===
    const getAcronym = () => {
      try {
        const cfg = window.SCHOOL || {};
        let ac = (cfg.admissionAcronym || cfg.shortName || cfg.name || 'SCH').toString().toUpperCase().replace(/[^A-Z0-9]/g,'').slice(0,8) || 'SCH';
        return ac;
      } catch(_) { return 'SCH'; }
    };
    if (d.table === 'students' && !id && (!payload.admission_no || String(payload.admission_no).trim()==='')) {
      try {
        const ac = getAcronym();
        const { data: maxRows } = await this.sb.from('students').select('admission_no').ilike('admission_no', ac+'/%').order('admission_no', {ascending:false}).limit(1);
        let nextNum = 1;
        if (maxRows && maxRows[0] && maxRows[0].admission_no) {
          const m = String(maxRows[0].admission_no).match(/\/(\d+)$/);
          if (m) nextNum = parseInt(m[1],10)+1;
        } else {
          const { count } = await this.sb.from('students').select('id', {count:'exact', head:true});
          nextNum = (count||0)+1;
        }
        payload.admission_no = ac + '/' + String(nextNum).padStart(4,'0');
      } catch(e) { console.warn('auto-admission failed', e.message); }
    }
    if (d.table === 'staff' && !id && (!payload.staff_no || String(payload.staff_no).trim()==='')) {
      try {
        const ac = getAcronym();
        const { data: maxRows } = await this.sb.from('staff').select('staff_no').ilike('staff_no', ac+'-%').order('staff_no', {ascending:false}).limit(1);
        let nextNum = 1;
        if (maxRows && maxRows[0] && maxRows[0].staff_no) {
          const m = String(maxRows[0].staff_no).match(/-(\d+)$/);
          if (m) nextNum = parseInt(m[1],10)+1;
        } else {
          const { count } = await this.sb.from('staff').select('id', {count:'exact', head:true});
          nextNum = (count||0)+1;
        }
        payload.staff_no = ac + '-STF-' + String(nextNum).padStart(4,'0');
      } catch(e) {}
    }
    // Auto-fill changed_by for role_status_log
    if (d.table === 'role_status_log' && !payload.changed_by) {
      try { payload.changed_by = (window.SC_PROFILE && SC_PROFILE.full_name) || (window.SC_PROFILE && SC_PROFILE.email) || ''; } catch(_){}
    }


    // parent_child duplicate guard: show a friendly message instead of Supabase unique constraint error.
    if (!id && d.table === 'parent_child' && payload.parent_id && payload.student_id) {
      const ex = await this.sb.from('parent_child').select('id').eq('parent_id', payload.parent_id).eq('student_id', payload.student_id).maybeSingle().then(r=>r, ()=>({data:null}));
      if (ex.data) { toast('This parent is already linked to this child. Choose another child or update the existing link.', 'warning', 7000); return; }
    }
    const sharedTables = ['library', 'digital_library', 'gallery', 'eresources', 'events', 'announcements'];
    if (id && window.App && !App.isAdminRole(App.currentRole) && !sharedTables.includes(d.table)) {
      const { data: row } = await this.sb.from(d.table).select('*').eq('id', id).maybeSingle();
      if (row && this.hasOwnershipMarker(row) && !this.isOwnedByCurrent(row)) {
        toast('Access Denied: You can read this record, but only the creator/assigned owner or an admin can modify it.', 'danger', 7000);
        return;
      }
    }
    const runSave = async (pl) => id ? await this.sb.from(d.table).update(pl).eq('id', id) : await this.sb.from(d.table).insert(pl);
    let res = await runSave(payload);
    // ENTERPRISE V6 (issues 16, 26, 32, 35): self-healing writes. If the target
    // database is missing a column (older schema), strip the unknown column —
    // for module_records tables tuck it into data{} instead — and retry.
    let guard = 0;
    while (res.error && guard < 6) {
      const m = String(res.error.message || '').match(/find the '([A-Za-z0-9_]+)' column|column "?([A-Za-z0-9_]+)"? (?:of|does not exist)/i);
      const bad = m && (m[1] || m[2]);
      if (!bad || !(bad in payload)) break;
      if (d.generic || d.table === 'module_records') { payload.data = payload.data || {}; payload.data[bad] = payload[bad]; }
      console.warn('[CRUD] Column "' + bad + '" missing in DB — retrying without it. Run database/update-v6-schema.sql to add it permanently.');
      delete payload[bad]; guard++;
      res = await runSave(payload);
    }
    if (res.error) { toast(res.error.message, 'danger', 6000); return; }
    if (window.App && App.logActivity) App.logActivity(id ? 'update' : 'create', d.table, id || d.title);
    try {
      if (!id && window.Notifications && Notifications.create) {
        if (moduleId === 'announcements') {
          await Notifications.create({ title: '📢 New Announcement: ' + (payload.title || d.title), body: payload.body || '', url: 'announcements.html', audience: payload.audience || 'all', channels: ['inapp','push'] });
        }
        if (moduleId === 'inbox' || moduleId === 'messages') {
          // ENTERPRISE V11 (issue 16): deliver to the CHOSEN audience — a
          // specific recipient gets a private notification; 'all'/role
          // audiences broadcast accordingly. Previously hard-coded to 'all'
          // yet stored the message as private → recipients saw nothing.
          const aud = payload.recipient_id ? 'private' : (payload.audience || 'all');
          const note = { title: '💬 New Message: ' + (payload.title || d.title), body: (payload.body || '').slice(0,160), url: 'inbox.html', audience: aud, channels: ['inapp','push'] };
          if (payload.recipient_id) note.recipient_id = payload.recipient_id;
          await Notifications.create(note);
        }
        // ENTERPRISE V6 (issue 8): every dashboard-worthy module now fires an
        // in-app + push notification so students/parents/staff see it at once.
        const notifyMap = {
          events:         { icon:'🎭', label:'New Event',            url:'events.html' },
          broadcast:      { icon:'📨', label:'Result Broadcast',     url:'broadcast.html' },
          surveys:        { icon:'📋', label:'New Survey',           url:'surveys.html' },
          cafeteria:      { icon:'🍽️', label:'Cafeteria Update',     url:'cafeteria.html' },
          menu:           { icon:'🍽️', label:'Meal Menu Update',     url:'menu.html' },
          lost_found:     { icon:'🔍', label:'Lost & Found',         url:'lost_found.html' },
          parent_meeting: { icon:'👥', label:'PTA Meeting',          url:'parent_meeting.html', audience:'parent' },
          hostel:         { icon:'🛏️', label:'Hostel Update',        url:'hostel.html' },
          assignments:    { icon:'📝', label:'New Assignment',       url:'assignments.html', audience:'student' },
          school_calendar:{ icon:'📅', label:'Calendar Update',      url:'school_calendar.html' },
          digital_library:{ icon:'📚', label:'New Reading',          url:'digital_library.html', audience:'student' },
          results:        { icon:'📊', label:'Result Update',        url:'results.html', audience:'parent' },
          fees:           { icon:'💰', label:'Fee/Payment Update',    url:'fees.html', audience:'parent' },
          report_cards:   { icon:'🧾', label:'Report Card Update',   url:'report-cards.html', audience:'parent' },
          cbt:            { icon:'🧪', label:'CBT/Exam Update',       url:'cbt-exam.html', audience:'student' },
          entrance:       { icon:'🎯', label:'Assessment Update',    url:'entrance.html', audience:'student' },
          attendance:     { icon:'📋', label:'Attendance Update',    url:'attendance.html', audience:'parent' }
        };
        const nm = notifyMap[this.canonicalId(moduleId)] || notifyMap[moduleId];
        if (nm) {
          await Notifications.create({ title: nm.icon + ' ' + nm.label + ': ' + (payload.title || d.title), body: (payload.body || '').slice(0, 160), url: nm.url, audience: nm.audience || (payload.audience || 'all'), channels: ['inapp','push'] });
        }
      }
    } catch(e) { console.warn('Notification hook skipped:', e.message || e); }
    closeModal();
    if (!id && (moduleId === 'students' || moduleId === 'staff')) {
      const email = moduleId === 'students' ? payload.guardian_email : payload.email;
      if (email) {
        const role = moduleId === 'students' ? 'student/parent' : 'staff';
        const invite = 'Login invitation for '+(payload.full_name||d.title)+'\nEmail: '+email+'\nRole: '+role+'\nOpen login.html → Request access → use this email → create password → admin approves in Approvals.';
        try { navigator.clipboard && navigator.clipboard.writeText(invite); } catch(e) {}
        toast('✅ Saved. Login invitation copied. The user must request access, then admin approves.', 'success', 8000);
      } else toast('✅ Saved. Add an email to generate login invitation details.', 'success', 6000);
    } else toast('✅ Saved.', 'success');
    this.renderList(moduleId);
  },

  /* ENTERPRISE V6 (issue 31): print a Custom Document on school letterhead.
     Replaces [NAME], [CLASS], [DATE] placeholders, adds logo, address and the
     principal's signature automatically. */
  async printDocument(id) {
    if (!this.sb) return;
    const { data: doc } = await this.sb.from('module_records').select('*').eq('id', id).maybeSingle();
    if (!doc) { toast('Document not found', 'warning'); return; }
    const d = doc.data || {}; const sc = window.SCHOOL || {}; const st = window.SC_SETTINGS || {};
    let studentName = d.student || '', studentClass = '';
    if (studentName) {
      try { const { data: stu } = await this.sb.from('students').select('full_name,class').ilike('full_name', studentName).maybeSingle(); if (stu) { studentName = stu.full_name; studentClass = stu.class || ''; } } catch(_){}
    }
    const today = CRUD.formatDate(new Date().toISOString());
    let body = String(doc.body || '').replace(/\[NAME\]/g, studentName || '[NAME]').replace(/\[CLASS\]/g, studentClass || '[CLASS]').replace(/\[DATE\]/g, today);
    const rawSig = (function(){ try { return localStorage.getItem('sc-signature-url') || ''; } catch(_) { return ''; } })() || st.signature_url || '';
    const sig = (window.Super && Super.idcard && Super.idcard.driveDirect) ? Super.idcard.driveDirect(rawSig) : rawSig;
    const pn = (function(){ try { return localStorage.getItem('sc-principal-name') || ''; } catch(_) { return ''; } })() || st.principal_name || 'Principal';
    const sign = sig ? '<div style="margin-top:34px;text-align:right"><img src="' + esc(sig) + '" referrerpolicy="no-referrer" style="max-width:150px;max-height:70px;object-fit:contain;mix-blend-mode:multiply;filter:contrast(1.3) brightness(1.05)"><br><b>' + esc(pn) + '</b><br><span style="font-size:.8rem">' + esc(d.type || 'Authorised') + '</span></div>'
                     : '<div style="margin-top:44px;text-align:right">____________________<br><b>' + esc(pn) + '</b></div>';
    const html = '<div style="max-width:720px;margin:0 auto;font-family:Georgia,serif;color:#111">' +
      '<div style="display:flex;align-items:center;gap:14px;border-bottom:3px double ' + (sc.primary || '#1e2a5e') + ';padding-bottom:12px;margin-bottom:6px">' +
      '<img src="assets/img/logo.' + (sc.logoExt || 'svg') + '" style="width:70px;height:70px;object-fit:contain" onerror="this.style.display=\'none\'">' +
      '<div><h1 style="margin:0;color:' + (sc.primary || '#1e2a5e') + '">' + esc(sc.name || 'School') + '</h1>' +
      '<div style="font-size:.82rem;color:#334155">' + esc(sc.address || '') + (sc.phone ? ' · Tel: ' + esc(sc.phone) : '') + (sc.email ? ' · ' + esc(sc.email) : '') + '</div>' +
      (sc.motto ? '<div style="font-size:.78rem;font-style:italic;color:#7c2d12">Motto: ' + esc(sc.motto) + '</div>' : '') + '</div></div>' +
      '<div style="text-align:right;font-size:.85rem">Date: ' + esc(today) + '</div>' +
      (d.recipient ? '<p style="margin:14px 0 4px"><b>To:</b> ' + esc(d.recipient) + '</p>' : '') +
      '<h2 style="text-align:center;text-decoration:underline;margin:22px 0 14px;font-size:1.15rem;letter-spacing:1px">' + esc((d.type || doc.title || 'DOCUMENT').toUpperCase()) + '</h2>' +
      '<div style="line-height:1.9;white-space:pre-wrap;text-align:justify">' + esc(body) + '</div>' + sign +
      '<p style="margin-top:30px;font-size:.68rem;color:#94a3b8;text-align:center">Generated electronically by ' + esc(sc.name || '') + ' · School Connect</p></div>';
    const w = window.open('', '_blank');
    if (!w) { toast('Popup blocked! Please allow popups.', 'warning'); return; }
    w.document.open();
    w.document.write('<!DOCTYPE html><html><head><title>' + esc(doc.title || 'Document') + '</title><base href="'+document.baseURI.replace(/[^/]*$/,'')+'"></head><body style="padding:34px">' + html + '<script>window.onload=function(){setTimeout(function(){window.print()},250)};<\/script></body></html>');
    w.document.close(); w.focus();
  },

  /* ENTERPRISE V8 (issue 9): letterheaded PDF export of one admission form. */
  async printAdmissionPDF(id) {
    if (!this.sb) return;
    const { data: a } = await this.sb.from('admissions').select('*').eq('id', id).maybeSingle();
    if (!a) { toast('Application not found', 'warning'); return; }
    const sc = window.SCHOOL || {}; const d = a.data || {};
    const rows = Object.entries(Object.assign({}, d, a)).filter(([k]) => !['data','id'].includes(k))
      .map(([k, v]) => '<tr><th style="text-align:left;padding:7px;border:1px solid #cbd5e1;background:#f1f5f9;width:220px">' + esc(k.replace(/_/g, ' ').toUpperCase()) + '</th><td style="padding:7px;border:1px solid #cbd5e1">' + esc(v == null ? '' : (/date|dob|created/i.test(k) ? CRUD.formatDate(v) : String(v))) + '</td></tr>').join('');
    const html = '<div style="max-width:720px;margin:0 auto;font-family:Georgia,serif;color:#111">' +
      '<div style="display:flex;align-items:center;gap:14px;border-bottom:3px double ' + (sc.primary || '#1e2a5e') + ';padding-bottom:12px;margin-bottom:14px">' +
      '<img src="assets/img/logo.' + (sc.logoExt || 'svg') + '" style="width:64px;height:64px;object-fit:contain" onerror="this.style.display=\'none\'">' +
      '<div><h1 style="margin:0;color:' + (sc.primary || '#1e2a5e') + ';font-size:1.3rem">' + esc(sc.name || 'School') + '</h1>' +
      '<div style="font-size:.8rem;color:#334155">ADMISSION APPLICATION FORM · ' + esc(a.status || 'submitted').toUpperCase() + '</div></div></div>' +
      '<table style="width:100%;border-collapse:collapse;font-size:.9rem">' + rows + '</table>' +
      '<p style="margin-top:24px;font-size:.7rem;color:#94a3b8;text-align:center">Generated ' + CRUD.formatDate(new Date().toISOString()) + ' · ' + esc(sc.name || '') + ' · School Connect</p></div>';
    this._printWindow('Admission — ' + (a.full_name || ''), html);
  },

  /* ENTERPRISE V8 (issue 7): shared print-window helper — <base href> + wait-for-images
     so any exported document prints complete with logos/photos. Browser's
     "Save as PDF" destination turns every print into a PDF (100% free). */
  _printWindow(title, bodyHtml) {
    const w = window.open('', '_blank');
    if (!w) { toast('Popup blocked! Please allow popups.', 'warning'); return; }
    w.document.open();
    w.document.write('<!DOCTYPE html><html><head><title>' + esc(title) + '</title><base href="' + document.baseURI.replace(/[^/]*$/, '') + '"></head><body style="padding:24px">' + bodyHtml +
      '<script>window.onload=function(){var i=[].slice.call(document.images),n=i.length;if(!n)return window.print();var d=function(){if(--n<=0)setTimeout(function(){window.print()},300)};i.forEach(function(m){if(m.complete)d();else{m.onload=d;m.onerror=d}})};<\/script></body></html>');
    w.document.close(); w.focus();
  },

  /* ENTERPRISE V8 (issue 7): bulk-print ALL admission applications (one per page). */
  async bulkPrintAdmissions() {
    if (!this.sb) return;
    const { data } = await this.sb.from('admissions').select('*').order('created_at', { ascending: false }).limit(500);
    if (!data || !data.length) { toast('No applications to print.', 'warning'); return; }
    const sc = window.SCHOOL || {};
    const one = (a) => { const d = a.data || {};
      const rows = Object.entries(Object.assign({}, d, a)).filter(([k]) => !['data','id'].includes(k))
        .map(([k, v]) => '<tr><th style="text-align:left;padding:6px;border:1px solid #cbd5e1;background:#f1f5f9;width:200px">' + esc(k.replace(/_/g, ' ').toUpperCase()) + '</th><td style="padding:6px;border:1px solid #cbd5e1">' + esc(v == null ? '' : String(v)) + '</td></tr>').join('');
      return '<div style="page-break-after:always;font-family:Georgia,serif"><h2 style="color:' + (sc.primary || '#1e2a5e') + '">' + esc(sc.name || 'School') + ' — Admission Form: ' + esc(a.full_name || '') + '</h2><table style="width:100%;border-collapse:collapse;font-size:.88rem">' + rows + '</table></div>'; };
    this._printWindow('All Admission Applications', data.map(one).join(''));
  },

  async previewAdmission(id) {
    if (!this.sb) return;
    const { data: a } = await this.sb.from('admissions').select('*').eq('id', id).maybeSingle();
    if (!a) { toast('Application not found', 'warning'); return; }
    const d = a.data || {};
    const rows = Object.entries(Object.assign({}, d, a)).filter(([k])=>!['data'].includes(k)).map(([k,v]) => '<tr><th style="text-align:left;padding:6px;border:1px solid #e2e8f0">'+esc(k.replace(/_/g,' '))+'</th><td style="padding:6px;border:1px solid #e2e8f0">'+esc(v==null?'':String(v))+'</td></tr>').join('');
    openModal('Admission Application Preview', '<div class="table-wrap"><table style="width:100%;border-collapse:collapse">'+rows+'</table></div>', '<button class="btn btn-outline" onclick="CRUD.printAdmissionPDF(\''+id+'\')">📄 Export PDF</button><button class="btn btn-primary" onclick="closeModal()">Close</button>');
  },

  async printReceipt(id) {
    if (!this.sb) return;
    const { data: f } = await this.sb.from('fee_payments').select('*').eq('id', id).maybeSingle();
    if (!f) return;
    let stu = null;
    try { if (f.student_id) { const r = await this.sb.from('students').select('full_name,class,admission_no').eq('id', f.student_id).maybeSingle(); stu = r.data; } } catch(_) {}
    const sc = window.SCHOOL || {}, stg = window.SC_SETTINGS || {};
    const cur = sc.currency || '₦';
    const fmtMoney = n => cur + Number(n || 0).toLocaleString();
    const rawSig = localStorage.getItem('sc-signature-url') || stg.signature_url || sc.signatureUrl || sc.signature_url || '';
    const sig = (window.Super && Super.idcard && Super.idcard.driveDirect) ? Super.idcard.driveDirect(rawSig) : rawSig;
    const pn = localStorage.getItem('sc-principal-name') || stg.principal_name || sc.principalName || sc.principal_name || 'Bursar / Principal';
    const total = Number(f.fee_total || 0) || 0;
    const paid = Number(f.amount_paid || 0) || 0;
    const bal = Math.max(0, (f.balance != null ? Number(f.balance) : (total ? total - paid : 0)) || 0);
    // Persist auto-computed balance back to DB so every record and future e-receipt reflects it.
    try { if (f.balance == null || Number(f.balance) !== bal) await this.sb.from('fee_payments').update({ balance: bal }).eq('id', id); } catch(_) {}
    const rdate = CRUD.formatDate(f.created_at || new Date().toISOString());
    const logo = '<img src="assets/img/logo.' + (sc.logoExt || 'svg') + '" class="logo" onerror="this.replaceWith(Object.assign(document.createElement(\'div\'),{className:\'logo\',textContent:\'' + esc((sc.shortName||sc.name||'S').slice(0,2).toUpperCase()) + '\'}))">';
    const row = (k, v) => '<div class="row"><span>' + esc(k) + '</span><b>' + v + '</b></div>';
    const html = '<div class="receipt">' +
      '<div class="rh">' + logo + '<div style="text-align:center"><h2>' + esc(sc.name || 'School') + '</h2><p class="sub">' + esc(sc.address || '') + (sc.phone ? ' · ' + esc(sc.phone) : '') + (sc.email ? ' · ' + esc(sc.email) : '') + '</p><p class="sub" style="letter-spacing:3px;font-weight:800">OFFICIAL E-RECEIPT</p></div></div>' +
      row('Receipt No.', esc(f.reference || ('RCP-' + String(f.id || '').slice(0, 8).toUpperCase()))) +
      row('Date', esc(rdate)) +
      row('Student', esc((stu && stu.full_name) || f.student_name || '') + ((stu && stu.class) ? ' (' + esc(stu.class) + ')' : '')) +
      ((stu && stu.admission_no) ? row('Admission No.', esc(stu.admission_no)) : '') +
      row('Term / Session', esc(f.term || '-') + ' · ' + esc(f.session || '-')) +
      row('Payment Method', esc(f.method || '-') + (f.reference ? ' · Ref: ' + esc(f.reference) : '')) +
      (total ? row('Total Fee for Term', fmtMoney(total)) : '') +
      '<div class="paid"><div style="font-size:.75rem;color:#334155">AMOUNT PAID</div><div class="amt">' + fmtMoney(paid) + '</div></div>' +
      (bal === 0 ? '<div class="bal full">Remaining Balance: ' + cur + '0 — FULLY PAID ✔</div>' : '<div class="bal">Remaining Balance: <b>' + fmtMoney(bal) + '</b></div>') +
      '<div class="sig">' + (sig ? '<img src="' + esc(sig) + '" referrerpolicy="no-referrer" style="max-width:150px;max-height:60px;object-fit:contain;mix-blend-mode:multiply;filter:contrast(1.3) brightness(1.05)">' : '<span class="script">' + esc((pn||'').split(/\s+/).map(x=>x[0]||'').join('').slice(0,3) || 'Sign') + '</span>') + '<div style="border-top:1px solid #111;width:180px;margin:2px auto 0;padding-top:2px"><b>' + esc(pn) + '</b> — Bursar / Principal</div></div>' +
      '<p class="note">This is an official computer-generated e-receipt. It carries the school logo, authorised signature, and is valid without a physical stamp. Generated by School Connect · Powered by HMG Concepts.</p></div>';
    const css = '<style>body{font-family:Arial,sans-serif;color:#111;background:#f1f5f9;margin:0;padding:18px;display:flex;justify-content:center}.receipt{width:520px;max-width:100%;border:2px solid #111;padding:26px;background:#fff;box-shadow:0 8px 30px rgba(0,0,0,.15)}.rh{display:flex;align-items:center;justify-content:center;gap:12px;border-bottom:2px solid #111;padding-bottom:10px}.logo{width:58px;height:58px;border-radius:12px;background:linear-gradient(135deg,#1e2a5e,#4f46e5);color:#fff;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:1.5rem;object-fit:contain}h2{margin:0;font-size:1.15rem}.sub{margin:2px 0 0;font-size:.72rem;color:#334155}.row{display:flex;justify-content:space-between;padding:7px 0;border-bottom:1px dashed #cbd5e1;font-size:.9rem}.row b{color:#0f172a;text-align:right}.paid{background:#f0fdf4;border:1px dashed #16a34a;border-radius:10px;padding:10px;text-align:center;margin-top:12px}.paid .amt{font-size:1.5rem;font-weight:900;color:#16a34a}.bal{background:#fef2f2;border:1px dashed #dc2626;border-radius:10px;padding:8px;text-align:center;margin-top:8px;font-size:.9rem}.bal b{color:#dc2626;font-size:1.1rem}.full{background:#f0fdf4;border:1px solid #16a34a;color:#16a34a;font-weight:800}.sig{margin-top:22px;text-align:center;font-size:.8rem}.sig .script{font-family:\'Segoe Script\',cursive;font-size:1.3rem;color:#1e2a5e}.note{margin-top:12px;font-size:.62rem;color:#94a3b8;text-align:center}@media print{body{background:#fff;padding:0}.receipt{box-shadow:none}}</style>';
    const w = window.open('', '_blank');
    if (!w) { toast('Popup blocked! Please allow popups.', 'warning'); return; }
    w.document.open();
    w.document.write('<!DOCTYPE html><html><head><title>E-Receipt</title><base href="'+document.baseURI.replace(/[^/]*$/,'')+'">' + css + '</head><body>' + html + '<script>window.onload=function(){var i=[].slice.call(document.images),n=i.length;if(!n)return window.print();var d=function(){if(--n<=0)setTimeout(function(){window.print()},300)};i.forEach(function(m){if(m.complete)d();else{m.onload=d;m.onerror=d}});setTimeout(function(){window.print()},2200)};<\/script></body></html>');
    w.document.close(); w.focus();
  },
  async remove(moduleId, id) {
    const d = this.def(moduleId);
    if (!this.canWrite(moduleId)) { toast('Read-only for your role on this page.', 'warning', 5000); return; }
    if (!d || !this.sb) return;
    // ENTERPRISE V6 (issue 15): library books are SHARED resources — any staff
    // member with write access may delete them; ownership lock only applies to
    // personal academic records (results, lesson plans, CBT…).
    const sharedTables = ['library', 'digital_library', 'gallery', 'eresources', 'events', 'announcements'];
    if (window.App && !App.isAdminRole(App.currentRole) && !sharedTables.includes(d.table)) {
      const { data: row } = await this.sb.from(d.table).select('*').eq('id', id).maybeSingle();
      if (row && this.hasOwnershipMarker(row) && !this.isOwnedByCurrent(row)) {
        toast('Access Denied: You can read this record, but only the creator/assigned owner or an admin can delete it.', 'danger', 7000);
        return;
      }
    }
    if (!confirm('Delete this ' + d.title.toLowerCase() + '?')) return;
    const { error } = await this.sb.from(d.table).delete().eq('id', id);
    if (error) { toast(error.message, 'danger'); return; }
    if (window.App && App.logActivity) App.logActivity('delete', d.table, id);
    toast('Deleted.', 'info'); this.renderList(moduleId);
  },

  /* Issue 10: bulk-import student birthdays from the students table */
  async importBirthdays() {
    if (!this.sb) { toast('Database not configured.', 'warning'); return; }
    // ENTERPRISE V6 (issue 29): import STUDENT + STAFF + PARENT birthdays.
    // Staff DOB is stored privacy-safe as day+month only — we synthesize a
    // sortable date (year 2000) so they appear in the month groups.
    const [studRes, staffRes, staffDm, parentRes, adminRes, adminDm, existingRes] = await Promise.all([
      this.sb.from('students').select('full_name,class,date_of_birth').not('date_of_birth', 'is', null).then(r=>r, ()=>({data:[]})),
      this.sb.from('staff').select('full_name,role,date_of_birth').not('date_of_birth', 'is', null).then(r=>r, ()=>({data:[]})),
      this.sb.from('staff').select('full_name,role,dob_day,dob_month').not('dob_month', 'is', null).then(r=>r, ()=>({data:[]})),
      this.sb.from('parents').select('full_name,occupation,date_of_birth').not('date_of_birth', 'is', null).then(r=>r, ()=>({data:[]})),
      this.sb.from('profiles').select('full_name,role,date_of_birth').in('role',['super_admin','admin','principal','proprietor','head_teacher','bursar']).not('date_of_birth', 'is', null).then(r=>r, ()=>({data:[]})),
      this.sb.from('profiles').select('full_name,role,dob_day,dob_month').in('role',['super_admin','admin','principal','proprietor','head_teacher','bursar']).not('dob_month', 'is', null).then(r=>r, ()=>({data:[]})),
      this.sb.from('birthdays').select('person_name').then(r=>r, ()=>({data:[]}))
    ]);
    const have = new Set((existingRes.data || []).map(b => b.person_name));
    const rows = [];
    const months = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    (studRes.data||[]).forEach(s => { if(!have.has(s.full_name)) { rows.push({ person_name:s.full_name, type:'student', date:s.date_of_birth, class:s.class }); have.add(s.full_name); } });
    (staffRes.data||[]).forEach(s => { if(!have.has(s.full_name)) { rows.push({ person_name:s.full_name, type:'staff', date:s.date_of_birth, class:s.role||'Staff' }); have.add(s.full_name); } });
    (staffDm.data||[]).forEach(s => { const mi = months.indexOf(s.dob_month); if(!have.has(s.full_name) && mi >= 0) { rows.push({ person_name:s.full_name, type:'staff', date:'2000-'+String(mi+1).padStart(2,'0')+'-'+String(parseInt(s.dob_day)||1).padStart(2,'0'), class:s.role||'Staff' }); have.add(s.full_name); } });
    (parentRes.data||[]).forEach(s => { if(!have.has(s.full_name)) { rows.push({ person_name:s.full_name, type:'parent', date:s.date_of_birth, class:s.occupation||'Parent' }); have.add(s.full_name); } });
    (adminRes.data||[]).forEach(s => { if(!have.has(s.full_name)) { rows.push({ person_name:s.full_name, type:'admin', date:s.date_of_birth, class:s.role||'Admin' }); have.add(s.full_name); } });
    (adminDm.data||[]).forEach(s => { const mi = months.indexOf(s.dob_month); if(!have.has(s.full_name) && mi >= 0) { rows.push({ person_name:s.full_name, type:'admin', date:'2000-'+String(mi+1).padStart(2,'0')+'-'+String(parseInt(s.dob_day)||1).padStart(2,'0'), class:s.role||'Admin' }); have.add(s.full_name); } });
    if (!rows.length) { toast('All available student, staff, parent and admin birthdays are already imported.', 'info'); return; }
    const { error } = await this.sb.from('birthdays').insert(rows);
    if (error) { toast(error.message, 'danger'); return; }
    toast('✅ Imported ' + rows.length + ' birthday record(s).', 'success'); this.renderList('birthdays');
  },

  /* Issue 7: filter a grouped student <select> by class (hides other optgroups). */
  filterRefByClass(selId, cls) {
    const sel = document.getElementById(selId); if (!sel) return;
    Array.from(sel.querySelectorAll('optgroup')).forEach(g => {
      g.style.display = (!cls || g.label === cls) ? '' : 'none';
      Array.from(g.children).forEach(o => { o.style.display = g.style.display; o.disabled = (g.style.display === 'none'); });
    });
    sel.value = '';
  },
  /* Issue 7: filter the student <select> by typed letters of the name. */
  filterRefBySearch(selId, term) {
    const sel = document.getElementById(selId); if (!sel) return;
    term = (term || '').toLowerCase();
    Array.from(sel.options).forEach(o => {
      if (!o.value) return;
      const show = !term || o.textContent.toLowerCase().indexOf(term) !== -1;
      o.style.display = show ? '' : 'none'; o.disabled = !show;
    });
    Array.from(sel.querySelectorAll('optgroup')).forEach(g => {
      const anyVisible = Array.from(g.children).some(o => o.style.display !== 'none');
      g.style.display = anyVisible ? '' : 'none';
    });
  },

  /* Issue 14: show birthdays grouped by birth MONTH with name + class. */
  async renderBirthdaysByMonth() {
    const box = document.getElementById('birthdays-bymonth'); if (!box) return;
    if (!this.sb) { box.innerHTML = '<p>Database not configured.</p>'; return; }
    const { data } = await this.sb.from('birthdays').select('person_name,class,date,type').limit(5000);
    if (!data || !data.length) { box.innerHTML = '<div class="card"><p style="color:var(--gray-500)">No birthdays yet — click “Import birthdays” to pull admin, staff, parent and student birth details.</p></div>'; return; }
    const months = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    const byMonth = {}; months.forEach(m => byMonth[m] = []);
    data.forEach(b => {
      if (!b.date) return;
      const mi = parseInt(String(b.date).slice(5, 7), 10) - 1;
      if (mi >= 0 && mi < 12) byMonth[months[mi]].push(b);
    });
    box.innerHTML = '<div class="card" style="margin-bottom:16px"><h3 style="margin-top:0">🎂 Birthdays by month</h3><div class="grid grid-2">' +
      months.map(m => {
        const list = byMonth[m].sort((a, b) => String(a.date).slice(8) - String(b.date).slice(8));
        return '<div style="border:1px solid var(--gray-200);border-radius:10px;padding:10px;margin-bottom:8px">' +
          '<strong style="color:var(--primary)">' + m + '</strong> <span style="color:var(--gray-500)">(' + list.length + ')</span>' +
          (list.length ? '<ul style="margin:6px 0 0;padding-left:18px;line-height:1.6">' + list.map(b => '<li>' + esc(b.person_name) + ' <span style="color:var(--gray-500)">— ' + esc(b.class || b.type || '') + ' (day ' + String(b.date).slice(8, 10) + ')</span></li>').join('') + '</ul>' : '<p style="color:var(--gray-400);margin:6px 0 0;font-size:.85rem">—</p>') +
          '</div>';
      }).join('') + '</div></div>';
  },

  /* Issue 8: pull Digital-Library reading scores into Results so they count
     toward the report card. Adds each unmatched reading score as a CA-style
     result row (or you can push to a chosen CA column). */
  async pullReadingScoresToResults(opts) {
    if (!this.sb) { toast('Database not configured.', 'warning'); return; }
    opts = opts || {};
    const { data: scores } = await this.sb.from('reading_scores').select('*').eq('pushed_to_results', false).limit(5000);
    if (!scores || !scores.length) { toast('No new reading scores to pull.', 'info'); return; }
    let ok = 0;
    for (const s of scores) {
      // scale reading score to the chosen CA max (default 10)
      const caMax = Number(opts.caMax || 10);
      const scaled = s.max_score ? Math.round((Number(s.score) / Number(s.max_score)) * caMax * 10) / 10 : Number(s.score);
      const row = { student_name: s.student_name, subject: s.subject, class: s.class, term: opts.term || null, session: opts.session || null };
      row[opts.column || 'ca3'] = scaled;
      const { error } = await this.sb.from('results').insert(row);
      if (!error) { await this.sb.from('reading_scores').update({ pushed_to_results: true }).eq('id', s.id); ok++; }
    }
    if (window.App && App.logActivity) App.logActivity('pull-reading-scores', 'results', ok + ' rows');
    toast('✅ Pulled ' + ok + ' reading score(s) into Results (column ' + (opts.column || 'ca3') + ').', 'success', 6000);
    this.renderList('results');
  },

  /* ============================================================
     ENTERPRISE V6 (issue 25): END-OF-SESSION CLASS MIGRATION.
     After third-term exams, admin opens Promotion page → "Promote whole
     class". Every student in the FROM class is moved to the TO class in ONE
     action (their results/fees history stays attached to their student id).
     Repeat-list students can be excluded by unticking them.
     ============================================================ */
  async promoteWholeClass() {
    if (!this.sb) { toast('Database not configured.', 'warning'); return; }
    const [{ data: classes }, { data: lookups }] = await Promise.all([this.sb.from('classes').select('name').order('name'), this.sb.from('lookups').select('kind,value').in('kind',['term','session']).order('position')]);
    const opts = (classes || []).map(c => '<option>' + esc(c.name) + '</option>').join('');
    const terms = [...new Set((lookups||[]).filter(x=>x.kind==='term').map(x=>x.value).filter(Boolean))];
    const sessions = [...new Set((lookups||[]).filter(x=>x.kind==='session').map(x=>x.value).filter(Boolean))];
    const termOpts = (terms.length?terms:['First Term','Second Term','Third Term']).map(v=>'<option>'+esc(v)+'</option>').join('');
    const sessionOpts = (sessions.length?sessions:['2025/2026','2026/2027']).map(v=>'<option>'+esc(v)+'</option>').join('');
    openModal('🎓 End-of-Session Class Migration',
      '<p style="color:var(--gray-600)">Move every student from one class to the next after the 3rd-term exams. Results, fees and records remain attached to each student automatically.</p>' +
      '<div class="grid grid-2"><div class="form-group"><label>From class</label><select id="pm-from" class="form-select" onchange="CRUD._pmLoad()"><option value="">— select —</option>' + opts + '</select></div>' +
      '<div class="form-group"><label>To class (next class)</label><select id="pm-to" class="form-select"><option value="">— select —</option>' + opts + '<option value="__graduated__">🎓 Graduated / Alumni</option></select></div></div>' +
      '<div id="pm-list" style="max-height:260px;overflow:auto;border:1px solid var(--gray-200);border-radius:8px;padding:8px;margin-top:6px"><p style="color:var(--gray-500)">Pick a “From class” to load its students…</p></div>',
      '<button class="btn btn-outline" onclick="closeModal()">Cancel</button><button class="btn btn-primary" onclick="CRUD._pmApply()">Promote selected →</button>');
  },
  async _pmLoad() {
    const from = document.getElementById('pm-from').value; const box = document.getElementById('pm-list');
    if (!from) { box.innerHTML = ''; return; }
    const { data } = await this.sb.from('students').select('id,full_name,admission_no').eq('class', from).order('full_name').limit(1000);
    box.innerHTML = (data && data.length)
      ? '<label style="display:block;font-weight:700;margin-bottom:6px"><input type="checkbox" checked onchange="document.querySelectorAll(\'.pm-stu\').forEach(c=>c.checked=this.checked)"> Select all (' + data.length + ')</label>' +
        data.map(st => '<label style="display:block;padding:3px 0"><input type="checkbox" class="pm-stu" value="' + st.id + '" checked> ' + esc(st.full_name) + ' <span style="color:var(--gray-500)">' + esc(st.admission_no || '') + '</span></label>').join('')
      : '<p style="color:var(--gray-500)">No students in that class.</p>';
  },
  async _pmApply() {
    const from = document.getElementById('pm-from').value, to = document.getElementById('pm-to').value;
    if (!from || !to) { toast('Choose both classes.', 'warning'); return; }
    const ids = [...document.querySelectorAll('.pm-stu:checked')].map(c => c.value);
    if (!ids.length) { toast('No students selected.', 'warning'); return; }
    if (!confirm('Promote ' + ids.length + ' student(s) from ' + from + ' to ' + (to === '__graduated__' ? 'Alumni (graduated)' : to) + '?')) return;
    let ok = 0;
    for (const id of ids) {
      const patch = to === '__graduated__' ? { status: 'graduated' } : { class: to };
      const { error } = await this.sb.from('students').update(patch).eq('id', id);
      if (!error) { ok++; await this.sb.from('promotions').insert({ student_name: '', from_class: from, to_class: to === '__graduated__' ? 'GRADUATED' : to, action: to === '__graduated__' ? 'graduate' : 'promote', status: 'applied' }).then(()=>{},()=>{}); }
    }
    if (window.App && App.logActivity) App.logActivity('bulk-promote', 'students', from + '→' + to + ' (' + ok + ')');
    toast('✅ Promoted ' + ok + ' student(s) to ' + (to === '__graduated__' ? 'Alumni' : to) + '.', 'success', 6000);
    closeModal(); this.renderList('students'); this.renderList('promotion');
  },

  exportCSV(moduleId) {
    const d = this.def(moduleId); if (!d || !this.sb) return;
    let q = this.sb.from(d.table).select('*');
    if (d.generic) q = q.eq('module', d.module);
    q.then(({ data }) => {
      if (!data || !data.length) { toast('Nothing to export.', 'warning'); return; }
      const keys = Object.keys(data[0]);
      const csv = [keys.join(',')].concat(data.map(r => keys.map(k => '"' + String(r[k] == null ? '' : (typeof r[k] === 'object' ? JSON.stringify(r[k]) : r[k])).replace(/"/g, '""') + '"').join(','))).join('\n');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); a.download = d.table + '.csv'; a.click();
    });
  },

  /* Issue 12: Export the visible/queried records as a printable PDF (uses the
     browser's "Save as PDF" print engine — no paid library, no AI). */
  /* Issue 5: print a professional payslip for one payroll row. */
  async printPayslip(id) {
    if (!this.sb) return;
    const { data: p } = await this.sb.from('payroll').select('*').eq('id', id).maybeSingle();
    if (!p) { toast('Payslip not found.', 'warning'); return; }
    const sc = (window.SCHOOL || {}); const cur = sc.currency || '₦';
    const n = (x) => Number(p[x]) || 0;
    const earnings = [['Basic salary', n('basic')], ['Allowances', n('allowances')], ['Bonus / Incentive', n('bonus')], ['Overtime', n('overtime')]].filter(r => r[1]);
    const deductions = [['Tax (PAYE)', n('tax')], ['Pension', n('pension')], ['Loan repayment', n('loan_deduction')], ['Other deductions', n('other_deductions')]].filter(r => r[1]);
    const gross = earnings.reduce((a, b) => a + b[1], 0);
    const totalDed = deductions.reduce((a, b) => a + b[1], 0);
    const net = p.net_pay != null ? Number(p.net_pay) : gross - totalDed;
    const fmt = (v) => cur + Number(v).toLocaleString();
    const rows = (arr) => arr.map(r => '<tr><td style="padding:4px 8px">' + esc(r[0]) + '</td><td style="padding:4px 8px;text-align:right">' + fmt(r[1]) + '</td></tr>').join('');
    const html = '<div style="width:720px;max-width:96vw;font-family:Arial,sans-serif;border:1px solid #cbd5e1;border-radius:10px;overflow:hidden">' +
      '<div style="background:' + (sc.primary || '#4f46e5') + ';color:#fff;padding:18px 22px;display:flex;align-items:center;gap:12px">' +
      '<img src="assets/img/logo.' + (sc.logoExt || 'svg') + '" style="width:48px;height:48px;border-radius:8px;background:#fff;padding:3px;object-fit:contain" onerror="this.style.display=\'none\'">' +
      '<div><h2 style="margin:0">' + esc(sc.name || 'School') + '</h2><div style="font-size:.78rem;opacity:.9">' + esc(sc.address || '') + ' · ' + esc(sc.phone || '') + '</div></div>' +
      '<div style="margin-left:auto;text-align:right"><strong style="font-size:1.1rem">PAYSLIP</strong><div style="font-size:.8rem">' + esc(p.month || '') + ' ' + esc(p.year || '') + '</div></div></div>' +
      '<div style="padding:16px 22px"><table style="width:100%;font-size:.9rem;margin-bottom:12px"><tr><td><b>Staff:</b> ' + esc(p.staff_name || '-') + '</td><td style="text-align:right"><b>Status:</b> ' + esc(p.status || 'draft') + '</td></tr><tr><td><b>Method:</b> ' + esc(p.method || '-') + '</td><td style="text-align:right"><b>Slip ref:</b> ' + esc(String(id).slice(0, 8)) + '</td></tr></table>' +
      '<div style="display:flex;gap:16px;flex-wrap:wrap">' +
      '<div style="flex:1;min-width:240px"><h4 style="margin:6px 0;border-bottom:2px solid #16a34a;color:#16a34a">Earnings</h4><table style="width:100%;font-size:.88rem">' + rows(earnings) + '<tr><td style="padding:6px 8px;font-weight:700;border-top:1px solid #e2e8f0">Gross</td><td style="padding:6px 8px;text-align:right;font-weight:700;border-top:1px solid #e2e8f0">' + fmt(gross) + '</td></tr></table></div>' +
      '<div style="flex:1;min-width:240px"><h4 style="margin:6px 0;border-bottom:2px solid #dc2626;color:#dc2626">Deductions</h4><table style="width:100%;font-size:.88rem">' + (deductions.length ? rows(deductions) : '<tr><td style="padding:4px 8px;color:#94a3b8">None</td><td></td></tr>') + '<tr><td style="padding:6px 8px;font-weight:700;border-top:1px solid #e2e8f0">Total</td><td style="padding:6px 8px;text-align:right;font-weight:700;border-top:1px solid #e2e8f0">' + fmt(totalDed) + '</td></tr></table></div></div>' +
      '<div style="margin-top:16px;background:' + (sc.primary || '#4f46e5') + '10;border:1px dashed ' + (sc.primary || '#4f46e5') + ';border-radius:8px;padding:12px;text-align:center"><span style="font-size:.85rem;color:#64748b">NET PAY</span><div style="font-size:1.6rem;font-weight:800;color:' + (sc.primary || '#4f46e5') + '">' + fmt(net) + '</div></div>' +
      '<div style="display:flex;justify-content:space-between;margin-top:30px;font-size:.8rem"><div>____________________<br>Prepared by (Bursar)</div><div>____________________<br>Authorised (Proprietor)</div></div>' +
      '<p style="margin-top:18px;font-size:.7rem;color:#94a3b8;text-align:center">This is a computer-generated payslip · ' + esc(sc.name || '') + ' · Powered by HMG Concepts</p></div></div>';
    const w = window.open('', '_blank');
    w.document.write('<html><head><title>Payslip</title><base href="'+document.baseURI.replace(/[^/]*$/,'')+'"></head><body style="display:flex;justify-content:center;padding:20px">' + html + '<script>window.onload=function(){setTimeout(function(){window.print()},250)};<\/script></body></html>');
    w.document.close();
  },

  exportPDF(moduleId) {
    const d = this.def(moduleId); if (!d || !this.sb) return;
    let q = this.sb.from(d.table).select('*');
    if (d.generic) q = q.eq('module', d.module);
    q.then(({ data }) => {
      if (!data || !data.length) { toast('Nothing to export.', 'warning'); return; }
      const cols = d.listCols || d.cols;
      const sc = (window.SCHOOL || {});
      const cellVal = (row, c) => c.key.indexOf('data.') === 0 ? ((row.data || {})[c.key.slice(5)]) : row[c.key];
      const head = '<tr>' + cols.map(c => '<th>' + esc(c.label) + '</th>').join('') + '</tr>';
      const rows = data.map(r => '<tr>' + cols.map(c => '<td>' + esc(String(cellVal(r, c) == null ? '' : cellVal(r, c))) + '</td>').join('') + '</tr>').join('');
      const w = window.open('', '_blank');
      w.document.write('<html><head><title>' + esc(d.title) + ' export</title><style>body{font-family:Arial,sans-serif;padding:18px;color:#111}h2{margin:0}small{color:#666}table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}th,td{border:1px solid #ccc;padding:6px 8px;text-align:left}th{background:#f1f5f9}</style><base href="'+document.baseURI.replace(/[^/]*$/,'')+'"></head><body><h2>' + esc(sc.name || 'School') + ' — ' + esc(d.title) + ' records</h2><small>Generated ' + (window.fmtDMYT?fmtDMYT(new Date()):new Date().toLocaleString()) + ' · ' + data.length + ' record(s)</small><table>' + head + rows + '</table><script>window.onload=()=>window.print()<\/script></body></html>');
      w.document.close();
    });
  },

  /* Issue 11: Bulk-import students (or any module) from a CSV file. The CSV is
     parsed in-browser and ONLY the extracted records are stored — the file
     itself is NEVER uploaded/saved (keeps Supabase storage free). */
  importCSV(moduleId) {
    const d = this.def(moduleId); if (!d) { toast('Import not available here.', 'warning'); return; }
    if (!this.sb) { toast('Database not configured.', 'warning'); return; }
    const inp = document.createElement('input'); inp.type = 'file'; inp.accept = '.csv,text/csv';
    inp.onchange = () => {
      const f = inp.files[0]; if (!f) return;
      const reader = new FileReader();
      reader.onload = async () => {
        const rows = CRUD._parseCSV(String(reader.result));
        if (!rows.length) { toast('CSV is empty or unreadable.', 'warning'); return; }
        const header = rows[0].map(h => h.trim());
        const valid = new Set(d.cols.filter(c => c.key.indexOf('data.') !== 0).map(c => c.key));
        const dataCols = new Set(d.cols.filter(c => c.key.indexOf('data.') === 0).map(c => c.key.slice(5)));
        const records = rows.slice(1).filter(r => r.some(x => x && x.trim())).map(r => {
          const rec = {}; const dataObj = {};
          header.forEach((h, i) => {
            const v = (r[i] == null ? '' : r[i].trim());
            if (v === '') return;
            if (valid.has(h)) rec[h] = v;
            else if (dataCols.has(h)) dataObj[h] = v;
          });
          if (d.generic) { rec.module = d.module; rec.data = dataObj; if (!rec.title && dataObj.title) rec.title = dataObj.title; }
          return rec;
        }).filter(r => Object.keys(r).length);
        if (!records.length) { toast('No valid rows found. Check column headers match field keys.', 'warning', 7000); return; }
        // chunked insert to stay within free-tier request sizes
        let ok = 0, fail = 0;
        for (let i = 0; i < records.length; i += 200) {
          const { error } = await this.sb.from(d.table).insert(records.slice(i, i + 200));
          if (error) { fail += Math.min(200, records.length - i); } else { ok += Math.min(200, records.length - i); }
        }
        if (window.App && App.logActivity) App.logActivity('import', d.table, ok + ' rows');
        toast('✅ Imported ' + ok + ' record(s).' + (fail ? ' ' + fail + ' failed.' : '') + ' (CSV file not stored)', fail ? 'warning' : 'success', 6000);
        this.renderList(moduleId);
      };
      reader.readAsText(f);
    };
    inp.click();
  },

  _parseCSV(text) {
    // RFC-4180-ish CSV parser supporting quoted fields, commas & newlines.
    const rows = []; let row = [], field = '', inQ = false;
    text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (inQ) {
        if (ch === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQ = false; }
        else field += ch;
      } else {
        if (ch === '"') inQ = true;
        else if (ch === ',') { row.push(field); field = ''; }
        else if (ch === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
        else field += ch;
      }
    }
    if (field !== '' || row.length) { row.push(field); rows.push(row); }
    return rows;
  },

  /* Issue 9: Digital library — when a teacher sets reading questions on a book,
     the student's auto-marked score can be pushed into the results table so it
     counts toward the final grade. */
  async pushReadingScore(studentName, subject, cls, score, label) {
    if (!this.sb) return;
    try {
      await this.sb.from('reading_scores').insert({ student_name: studentName, subject, class: cls, score, source: label || 'digital_library' });
    } catch (e) {}
  },

  /* Issue 10: Auto-promotion. Computes promote/repeat/graduate for every active
     student from their results vs a pass benchmark, then writes draft promotion
     rows the admin can review & alter before applying. */
  async autoPromote(opts) {
    if (!this.sb) { toast('Database not configured.', 'warning'); return; }
    opts = opts || {};
    const benchmark = Number(opts.benchmark != null ? opts.benchmark : 40);
    const session = opts.session || '';
    const term = opts.term || '';
    const graduatingClass = (opts.graduatingClass || '').trim();
    const { data: studs } = await this.sb.from('students').select('id,full_name,class,status').eq('status', 'active').limit(5000);
    if (!studs || !studs.length) { toast('No active students found.', 'warning'); return; }
    let rq = this.sb.from('results').select('student_name,class,subject,ca1,ca2,ca3,exam');
    if (session) rq = rq.eq('session', session);
    if (term) rq = rq.eq('term', term);
    const { data: results } = await rq.limit(50000);
    const byStudent = {};
    (results || []).forEach(r => {
      const t = (Number(r.ca1) || 0) + (Number(r.ca2) || 0) + (Number(r.ca3) || 0) + (Number(r.exam) || 0);
      (byStudent[r.student_name] = byStudent[r.student_name] || []).push(t);
    });
    // class progression map (override via opts.nextClass)
    const nextClassMap = opts.nextClass || CRUD._defaultNextClass();
    const drafts = [];
    studs.forEach(s => {
      const scores = byStudent[s.full_name] || [];
      const avg = scores.length ? scores.reduce((a, b) => a + b, 0) / scores.length : null;
      let action, to_class = '';
      if (graduatingClass && s.class === graduatingClass) { action = 'graduate'; }
      else if (avg == null) { action = 'pending'; }
      else if (avg >= benchmark) { action = 'promote'; to_class = nextClassMap[s.class] || ''; }
      else { action = 'repeat'; to_class = s.class; }
      drafts.push({ student_name: s.full_name, from_class: s.class, to_class, action, average: avg == null ? null : Math.round(avg * 10) / 10, session, term, status: 'draft' });
    });
    // store as draft promotions (admin can edit before applying)
    let ok = 0;
    for (let i = 0; i < drafts.length; i += 200) {
      const { error } = await this.sb.from('promotions').insert(drafts.slice(i, i + 200).map(d => ({ student_name: d.student_name, from_class: d.from_class, to_class: d.to_class, action: d.action, session: d.session, term: d.term, status: d.status, average: d.average })));
      if (!error) ok += Math.min(200, drafts.length - i);
    }
    if (window.App && App.logActivity) App.logActivity('auto-promote', 'promotions', ok + ' drafts @ ' + benchmark + '%');
    toast('✅ Generated ' + ok + ' promotion draft(s) at ' + benchmark + '% benchmark. Review & edit, then Apply.', 'success', 8000);
    this.renderList('promotion');
    return drafts;
  },

  _defaultNextClass() {
    // Sensible Nigerian-style progression; admin can override anytime.
    return {
      'Nursery 1': 'Nursery 2', 'Nursery 2': 'Primary 1',
      'Primary 1': 'Primary 2', 'Primary 2': 'Primary 3', 'Primary 3': 'Primary 4',
      'Primary 4': 'Primary 5', 'Primary 5': 'Primary 6', 'Primary 6': 'JSS1',
      'JSS1': 'JSS2', 'JSS2': 'JSS3', 'JSS3': 'SSS1',
      'SSS1': 'SSS2', 'SSS2': 'SSS3'
    };
  },

  /* Apply approved/draft promotions: move each student to their to_class. */
  async applyPromotions() {
    if (!this.sb) { toast('Database not configured.', 'warning'); return; }
    if (!confirm('Apply all promotions? This updates each student\'s class (graduates become "graduated").')) return;
    const { data: proms } = await this.sb.from('promotions').select('*').in('status', ['draft', 'approved']).limit(5000);
    if (!proms || !proms.length) { toast('No promotions to apply.', 'warning'); return; }
    let done = 0;
    for (const p of proms) {
      if (p.action === 'pending') continue;
      const upd = p.action === 'graduate' ? { status: 'graduated' } : (p.action === 'promote' ? { class: p.to_class } : {});
      if (Object.keys(upd).length) { await this.sb.from('students').update(upd).eq('full_name', p.student_name); }
      await this.sb.from('promotions').update({ status: 'applied' }).eq('id', p.id);
      done++;
    }
    if (window.App && App.logActivity) App.logActivity('apply-promotions', 'students', done + ' applied');
    toast('✅ Applied ' + done + ' promotion(s).', 'success'); this.renderList('promotion');
  },

  /* Issue 6: Build today's attendance from QR self check-ins so teachers don't
     hand-enter each student. Anyone scanned = present; the rest of their class
     are written as absent (admin can edit). */
  async importAttendanceFromCheckin() {
    if (!this.sb) { toast('Database not configured.', 'warning'); return; }
    const today = new Date().toISOString().slice(0, 10);
    const { data: checkins } = await this.sb.from('attendance_checkins').select('student_name,student_id_ref,class,checkin_at').gte('checkin_at', today + 'T00:00:00').limit(5000);
    if (!checkins || !checkins.length) { toast('No QR check-ins recorded today yet.', 'warning', 6000); return; }
    const present = {}; checkins.forEach(c => { const n = c.student_name || c.student_id_ref; if (n) present[n] = c.class || ''; });
    // avoid duplicating existing attendance rows for today
    const { data: existing } = await this.sb.from('attendance').select('student_name').eq('date', today);
    const have = new Set((existing || []).map(a => a.student_name));
    const rows = Object.keys(present).filter(n => !have.has(n)).map(n => ({ student_name: n, class: present[n], date: today, status: 'present', time_in: new Date().toTimeString().slice(0, 5) }));
    if (!rows.length) { toast('All scanned students are already in today\'s attendance.', 'info'); return; }
    const { error } = await this.sb.from('attendance').insert(rows);
    if (error) { toast(error.message, 'danger'); return; }
    if (window.App && App.logActivity) App.logActivity('attendance-from-checkin', 'attendance', rows.length + ' present');
    toast('✅ Marked ' + rows.length + ' student(s) PRESENT from QR check-ins.', 'success', 6000);
    this.renderList('attendance');
  },

  /* ============================================================
     ENTERPRISE V10: BULK TRAITS FILL
     Easy interface to fill Affective/Psychomotor domains for a 
     whole class at once.
     ============================================================ */
  async bulkFillTraits(kind) {
    if (!this.sb) { toast('Database not configured.', 'warning'); return; }
    const [{ data: classes }, { data: lookups }] = await Promise.all([this.sb.from('classes').select('name').order('name'), this.sb.from('lookups').select('kind,value').in('kind',['term','session']).order('position')]);
    const opts = (classes || []).map(c => '<option>' + esc(c.name) + '</option>').join('');
    const terms = [...new Set((lookups||[]).filter(x=>x.kind==='term').map(x=>x.value).filter(Boolean))];
    const sessions = [...new Set((lookups||[]).filter(x=>x.kind==='session').map(x=>x.value).filter(Boolean))];
    const termOpts = (terms.length?terms:['First Term','Second Term','Third Term']).map(v=>'<option>'+esc(v)+'</option>').join('');
    const sessionOpts = (sessions.length?sessions:['2025/2026','2026/2027']).map(v=>'<option>'+esc(v)+'</option>').join('');
    const title = kind === 'affective' ? '⭐ Bulk Fill Affective Domain' : '🏃 Bulk Fill Psychomotor Domain';
    openModal(title,
      '<div class="grid grid-2"><div class="form-group"><label>Class</label><select id="bf-class" class="form-select" onchange="CRUD._bfLoad(\''+kind+'\')"><option value="">— select —</option>' + opts + '</select></div>' +
      '<div class="form-group"><label>Term</label><select id="bf-term" class="form-select">'+termOpts+'</select></div><div class="form-group"><label>Session</label><select id="bf-session" class="form-select">'+sessionOpts+'</select></div></div>' +
      '<div id="bf-list" style="max-height:400px;overflow:auto;margin-top:10px"><p style="color:var(--gray-500)">Pick a class to load students...</p></div>',
      '<button class="btn btn-outline" onclick="closeModal()">Cancel</button><button class="btn btn-primary" onclick="CRUD._bfSave(\''+kind+'\')">Save All</button>');
  },

  async _bfLoad(kind) {
    const cls = document.getElementById('bf-class').value;
    const box = document.getElementById('bf-list');
    if (!cls) return;
    const { data: studs } = await this.sb.from('students').select('id,full_name').eq('class', cls).order('full_name');
    if (!studs || !studs.length) { box.innerHTML = '<p>No students found.</p>'; return; }
    
    const traits = kind === 'affective' 
      ? ['Punctuality','Neatness','Politeness','Honesty','Leadership','Cooperation','Attentiveness']
      : ['Handwriting','Verbal Fluency','Sports','Crafts','Drawing','Music'];

    let html = '<table class="form-table"><thead><tr><th>Student</th>' + traits.map(t => '<th>'+t+'</th>').join('') + '</tr></thead><tbody>';
    studs.forEach(s => {
      html += '<tr data-student-id="'+s.id+'"><td><b>'+esc(s.full_name)+'</b></td>' + traits.map(t => '<td><select class="form-select bf-val" data-trait="'+t+'"><option value="5">5</option><option value="4">4</option><option value="3" selected>3</option><option value="2">2</option><option value="1">1</option></select></td>').join('') + '</tr>';
    });
    html += '</tbody></table>';
    box.innerHTML = html;
  },

  async _bfSave(kind) {
    const cls = document.getElementById('bf-class').value;
    const term = document.getElementById('bf-term').value;
    const session = (document.getElementById('bf-session')||{}).value || new Date().getFullYear() + '/' + (new Date().getFullYear()+1);
    const table = kind === 'affective' ? 'affective_traits' : 'psychomotor_traits';
    const rows = [];
    document.querySelectorAll('#bf-list tr[data-student-id]').forEach(tr => {
      const student_id = tr.dataset.studentId;
      const ratings = {};
      tr.querySelectorAll('.bf-val').forEach(sel => { ratings[sel.dataset.trait] = sel.value; });
      rows.push({ student_id, term, session, ratings, teacher_id: window.SC_PROFILE?.id });
    });
    const { error } = await this.sb.from(table).upsert(rows, { onConflict: 'student_id,term,session' });
    if (error) { toast(error.message, 'danger'); return; }
    toast('✅ Saved traits for ' + rows.length + ' students.', 'success');
    closeModal();
  }
};

/* ---- Auto-promotion modal UI (issue 10) ---- */
const PromoUI = {
  async open() {
    if (!window.CRUD || !CRUD.sb) { toast('Database not configured.', 'warning'); return; }
    let sessions = [], terms = [];
    try { const { data } = await CRUD.sb.from('lookups').select('value,kind').in('kind', ['session', 'term']); (data || []).forEach(r => { if (r.kind === 'session') sessions.push(r.value); else terms.push(r.value); }); } catch (e) {}
    const opt = (arr) => ['<option value="">— any —</option>'].concat(arr.map(v => '<option>' + esc(v) + '</option>')).join('');
    openModal('Auto-promote students by exam result',
      '<div class="form-group"><label>Pass benchmark (% of total)</label><input class="form-input" id="pp-bm" type="number" value="40" min="0" max="100"></div>' +
      '<div class="form-group"><label>Session</label><select class="form-select" id="pp-sess">' + opt(sessions) + '</select></div>' +
      '<div class="form-group"><label>Term</label><select class="form-select" id="pp-term">' + opt(terms) + '</select></div>' +
      '<div class="form-group"><label>Graduating class (students here → graduate)</label><input class="form-input" id="pp-grad" placeholder="e.g. SSS3"></div>' +
      '<p style="color:var(--gray-500);font-size:.85rem">This creates editable DRAFTS only. Review them, then click “Apply promotions”.</p>',
      '<button class="btn btn-outline" onclick="closeModal()">Cancel</button>' +
      '<button class="btn btn-primary" onclick="PromoUI.run()">Generate drafts</button>');
  },
  run() {
    const benchmark = Number(document.getElementById('pp-bm').value || 40);
    const session = document.getElementById('pp-sess').value;
    const term = document.getElementById('pp-term').value;
    const graduatingClass = document.getElementById('pp-grad').value;
    closeModal();
    CRUD.autoPromote({ benchmark, session, term, graduatingClass });
  }
};
if (typeof window !== 'undefined') window.PromoUI = PromoUI;
if (typeof window !== 'undefined') window.CRUD = CRUD;
if (typeof console !== 'undefined') console.log('%c[School Connect] CRUD engine loaded — real add/edit/delete for every module.', 'color:#0d9488;font-weight:bold');
