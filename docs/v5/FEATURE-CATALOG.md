# School Connect V5.1 — Complete Feature Catalogue

**Total selectable modules: 97.** This catalogue is generated from `assets/js/catalog.js`, the builder’s source of truth. School Connect uses no paid AI API; all workflows run in the browser plus Supabase/PostgreSQL/Auth/RLS.

## How modules work together

- **Identity and access:** Supabase Auth creates the login; `profiles`, role/status approval, page guards and database RLS jointly control access.
- **Academic chain:** setup → students/staff/classes/subjects → attendance and subject scores → class/subject broadsheets → report cards, promotion, transcripts and certificates.
- **CBT chain:** validated/diagnosed teacher question bank → public answer-redacted exam → `cbt_submit_v5` server grade → verified result/per-subject scores → optional report-card mapping.
- **Finance chain:** class fee structure → payment/intent → balance trigger → e-receipt → finance analytics.
- **Communication chain:** announcements/messages/polls/results/complaints → in-app notification and optional device-native email/WhatsApp/SMS links.

## Core (28)

### Academic Setup (`academic_setup`) — Enhanced
Enter/manage departments, terms, sessions, arms and academic periods used across the platform.

**Operational use:** Open `academic-setup.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Students & Profiles (`students`)
Central student information system with guardian info and Drive-linked photos.

**Operational use:** Open `students.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Staff / Teachers (`staff`)
Full staff records: teaching/non-teaching, subject taught, qualification, religion, marital status, photo (Drive link) and auto staff number. Approved teacher sign-ups are auto-added here.

**Operational use:** Open `staff.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Classes (`classes`)
Create each class/arm and assign a class teacher by choosing from a staff dropdown — no typing. Set level and capacity.

**Operational use:** Open `classes.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Subjects (`subjects`) — Enhanced
Register every subject once, give it a code/department/level, and map it to a teacher (chosen from staff). Used everywhere subjects are picked.

**Operational use:** Open `subjects.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Attendance (`attendance`) — Enhanced
Daily/class attendance. Pull a whole class PRESENT automatically from QR check-ins — no one-by-one typing. Parent alerts.

**Operational use:** Open `attendance.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Punctuality Points (`punctuality`) — Enhanced
Rewards students who check in before the deadline AND check out during closing — daily points, term leaderboard, one-click push into any Results report-card column. Builds punctuality culture.

**Operational use:** Open `punctuality.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Results / Scores (`results`)
Enter CA + exam scores per student/subject/term/session (all chosen from dropdowns). Grades auto-suggested. Feeds report cards & promotion.

**Operational use:** Open `results.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Timetable (`timetable`) — Enhanced
Class & exam timetables with auto-conflict detection.

**Operational use:** Open `timetable.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Scheme of Work (`sow`) — Enhanced
Termly planning + weekly progress tracking with proprietor dashboard.

**Operational use:** Open `sow.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### CBT / Online Exams (`cbt`) — Popular
V5.1 server-verified CBT: legacy answer-key diagnosis/repair, pre-publish validation, CSV upload, UTME tabs, timer, original-index randomisation, negative marking, anti-cheat, certificates and report-card mapping. Missing keys fail loudly—never a silent false zero.

**Operational use:** Open `cbt.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### AI Question Prompts (`cbt-prompts`) — Enhanced
Ready-made Simple/Intermediate/Advanced prompts you paste into any free AI chat to draft CBT questions in the exact CSV format — copy, edit, upload. The platform itself uses no paid AI.

**Operational use:** Open `cbt-prompts.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Report Cards (flexible) (`report-cards`) — Enhanced
Define custom assessment columns per subject (CA1, CA2, Assignment, Project, Exam) with apportioned max marks. CBT/online results auto-map into the right column. Totals, grades & positions computed.

**Operational use:** Open `report-cards.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Timetable Generator (`timetable-generator`) — Enhanced
Auto-builds a conflict-free timetable (no class/teacher double-booking) from each subject weekly period demand — deterministic, no AI.

**Operational use:** Open `timetable-generator.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### QR Check-in (`checkin`) — Enhanced
Students self-check-in by scanning their ID-card QR (or typing admission no). No biometric hardware needed.

**Operational use:** Open `checkin.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Assignments / Homework (`assignments`) — Popular
Post & track assignments with submission and grading.

**Operational use:** Open `assignments.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Library (`library`) — Enhanced
Book catalogue, lending records, barcode scanning, due-date alerts.

**Operational use:** Open `library.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Digital Library (`digital_library`) — Enhanced
Teachers assign online books/links + optional comprehension questions; auto-scored marks count toward grades.

**Operational use:** Open `digital-library.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Conduct / Behaviour (`conduct`) — Enhanced
Merit/demerit, incidents, pattern tracking.

**Operational use:** Open `conduct.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Health / Clinic (`health`) — Enhanced
Sick-bay visits, medical history, allergy alerts.

**Operational use:** Open `health.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Promotion / Graduation (`promotion`) — Enhanced
Automated promotion: from each student's term average vs a benchmark you set, the system drafts promote/repeat/graduate decisions. Admin reviews/edits, then applies. Graduates move to Alumni.

**Operational use:** Open `promotion.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Integrated LMS (`lms`) — Enterprise
Unified learning platform for course tracking, video lessons, and online assignment submissions.

**Operational use:** Open `lms.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Rewards & Badges (PBIS) (`gamification`) — Enterprise
Give students points for good behaviour/effort and award badges. A simple, transparent positive-reinforcement tracker — every point is logged and visible.

**Operational use:** Open `gamification.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Career & Placement (`career_counseling`) — Enterprise
Track college applications, university offers, and career guidance.

**Operational use:** Open `career-counseling.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Lesson Plans & Curriculum (`lesson_plans`) — Enhanced
Teachers author weekly lesson plans with objectives & resources; HODs approve (Chalk parity).

**Operational use:** Open `lesson-plans.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Behaviour & PBIS Points (`behaviour`) — Enhanced
Award merit points and badges for positive behaviour; live leaderboards (ClassDojo parity).

**Operational use:** Open `behaviour.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Special Education / Support (`support_plans`) — Enterprise, Enhanced
Track learning needs, interventions, goals and review dates per student (Provision Map parity).

**Operational use:** Open `support-plans.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Substitute / Cover (`substitutions`) — Enhanced
Assign cover teachers when staff are absent; daily cover sheet & history.

**Operational use:** Open `substitutions.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

## Enterprise (24)

### Entrance & Assessments (`entrance`) — Enterprise, Enhanced
Run entrance/common-entrance/placement exams that anonymous candidates can sit. Instant result slips, certificates and admission letters — single or bulk.

**Operational use:** Open `entrance.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Storage Manager (`storage`) — Enterprise, Enhanced
See how much Supabase space each table uses and safely purge old, low-value rows (after exporting) to make room — keeps you on the free tier.

**Operational use:** Open `storage.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Analytics Dashboard (`analytics`) — Enterprise, Enhanced
Live, platform-wide KPIs & charts across every module to support informed decisions.

**Operational use:** Open `analytics.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Approvals (`approvals`) — Enterprise, Enhanced
Approve/reject prospective students, parents and staff (and admissions applications) right from the admin dashboard. Set roles, approve, suspend or delete.

**Operational use:** Open `approvals.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Admin Data Console (`admin-data`) — Enterprise, Enhanced
Admin-only: read, delete, full backup (JSON) and restore of every table on the client site. All actions logged.

**Operational use:** Open `admin-data.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Settings (2FA · Language · A11y) (`settings`) — Enterprise, Enhanced
Free email-OTP 2FA, multi-language UI (incl. Hausa/Yoruba/Igbo), and accessibility (font scaling, high contrast).

**Operational use:** Open `settings.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Admissions & Enrollment (`admissions`) — Enterprise
Public application form → review funnel → enrollment.

**Operational use:** Open `admissions.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Salary & Payslips (`hr`) — Enterprise
Run staff salaries: basic, allowances, bonus, overtime, tax, pension & loan deductions with AUTO net-pay and printable professional payslips.

**Operational use:** Open `hr.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Payroll Register (`payroll`) — Enterprise, Enhanced
The full salary register — pick staff from a list, auto-compute net pay, approve/pay status, and print a payslip for every month.

**Operational use:** Open `payroll.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Staff Loans & Advances (`staff_loans`) — Enterprise, Enhanced
Track staff loans/salary advances with monthly EMI repayment schedules, amount repaid and status (active/completed/defaulted).

**Operational use:** Open `staff-loans.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Staff Bonuses (`staff_bonus`) — Enterprise, Enhanced
Record performance, 13th-month, holiday and long-service bonuses per staff with citations and pay status.

**Operational use:** Open `staff-bonus.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Staff Appraisals (`appraisals`) — Enterprise, Enhanced
Structured performance appraisals with weighted 1–10 criteria (punctuality, teaching quality, results, teamwork, conduct), AUTO score & band, and a recommendation.

**Operational use:** Open `appraisals.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Hostel / Boarding (`hostel`) — Enterprise
Block/room/bed tracking with active/vacated status.

**Operational use:** Open `hostel.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Alumni Network (`alumni`) — Enterprise
Graduation-year directory, mentorship, fundraising.

**Operational use:** Open `alumni.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Inventory & Assets (`inventory`) — Enterprise
Equipment/supplies register with location and condition.

**Operational use:** Open `inventory.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Certificates & Documents (`certificates`) — Enterprise
Issue branded, printable certificates (achievement, graduation, testimonial) with a unique verification code.

**Operational use:** Open `certificates.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Role & Status Manager (`status_manager`) — Enterprise, Enhanced
Authorized administrators search people and change role/status with an audit trail. Use for approved, suspended, active and cross-role changes.

**Operational use:** Open `status-manager.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Custom Document Builder (`document_builder`) — Enterprise
Drag-and-drop builder for hall tickets, bonafide letters, and custom IDs.

**Operational use:** Open `document-builder.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Advanced Fleet GPS (`fleet_tracking`) — Enterprise
Bus route optimization, live tracking placeholder, driver logs.

**Operational use:** Open `fleet-tracking.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Facility Booking (`facility_booking`) — Enterprise
Schedule science labs, sports fields, and auditorium usage.

**Operational use:** Open `facility-booking.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Compliance & Audit (`compliance`) — Enterprise
Track accreditation metrics, fire drills, and statutory inspections.

**Operational use:** Open `compliance.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Audit / Activity Log (`activity_log`) — Enterprise, Enhanced
Tamper-evident log of every create/update/delete/login — who did what, when (PowerSchool/Infinite Campus parity).

**Operational use:** Open `activity-log.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Academic Records & Broadsheets (`academic_records`) — Enterprise, Enhanced
Generate student record cards, class broadsheets and subject broadsheets for print/PDF.

**Operational use:** Open `academic-records.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### About the Developer (`developer`) — Enhanced
The developer & HMG Concepts brand bio — the last page of the site.

**Operational use:** Open `developer.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

## Comm (12)

### Student Diary (`diary`) — Enhanced
Daily homework/classwork/behaviour log; parents view & acknowledge.

**Operational use:** Open `diary.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Surveys & Forms (`surveys`) — Enhanced
Anonymous-optional feedback forms & surveys with response collection.

**Operational use:** Open `surveys.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Announcements (`announcements`)
School-wide notices with priority levels and pinning.

**Operational use:** Open `announcements.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Events & Calendar (`events`) — Popular
Term calendar with RSVP, venue booking.

**Operational use:** Open `events.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Messaging (WA/Email) (`messages`)
Free bulk WhatsApp + email + SMS to parents/staff.

**Operational use:** Open `messages.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### In-App Inbox (`inbox`)
Private staff↔admin↔parent threaded messaging.

**Operational use:** Open `inbox.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Complaints & Grievance (`complaints`) — Enhanced
Submit→route→track→resolve with evidence and status.

**Operational use:** Open `complaints.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Results Broadcast (`broadcast`) — Popular
One-click send results to parents via free channels.

**Operational use:** Open `broadcast.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Voting & Polls (`voting`) — Enhanced
Class prefects, head boy/girl, staff polls, anonymous ballots.

**Operational use:** Open `voting.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### PTA Meeting Scheduler (`parent_meeting`) — Enhanced
Schedule parent-teacher meetings, send reminders, log minutes.

**Operational use:** Open `parent-meeting.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Front Desk / Dispatch (`front_desk`) — Enterprise
Track postal dispatch, calls, and walk-in admission inquiries.

**Operational use:** Open `front-desk.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### IT / Help Desk (`helpdesk`) — Enhanced
Internal ticketing for IT, maintenance and admin requests with priority & status.

**Operational use:** Open `helpdesk.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

## Media (13)

### Menu / Meal Planner (`menu`) — Enhanced
Weekly meal planner with allergen notes for parents.

**Operational use:** Open `menu.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Photo & Video Gallery (`gallery`)
Albums, Google Drive image linking, YouTube embeds.

**Operational use:** Open `gallery.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### E-Resources / Notes (`eresources`) — Enhanced
Lesson notes, past questions, Drive-linked documents.

**Operational use:** Open `eresources.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Birthdays (`birthdays`)
Celebrate with auto-reminders and wish lists.

**Operational use:** Open `birthdays.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Digital ID Cards (`idcards`) — Enhanced
Generate & print branded student/staff cards with a scannable QR code (encodes the ID for attendance). Pick a student or enter manually.

**Operational use:** Open `idcards.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Marketing Flyer (`flyer`) — Enhanced
Generate a printable, branded promotional flyer/poster for admissions and parent outreach — free lead-gen.

**Operational use:** Open `flyer.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Reports & Export (`reports`)
CSV / PDF / Excel exports + analytics dashboard.

**Operational use:** Open `reports.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Directory (`directory`)
Searchable people directory with role filters.

**Operational use:** Open `directory.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Departments & Offices (`departments`)
Per-department coordination, resource management.

**Operational use:** Open `departments.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Parent–Child Mapping (`parents`) — Enhanced
Link parents to children for results, fees, complaints.

**Operational use:** Open `parents.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### School Calendar (`school_calendar`) — Enhanced
Academic calendar with holidays, mid-terms and term dates.

**Operational use:** Open `school-calendar.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Lost & Found (`lost_found`) — Enhanced
Log lost & found items, claim with photo evidence.

**Operational use:** Open `lost-found.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Book Reservation (`book_request`) — Enhanced
Students reserve library books; auto-queue when returned.

**Operational use:** Open `book-request.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

## Finance (11)

### Fees & Payments (`fees`)
Fee structures, balances, print-ready receipts, payment tracking.

**Operational use:** Open `fees.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### School Finance (`finance`) — Enhanced
Income/expense ledger with charts and KPI analytics.

**Operational use:** Open `finance.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Leave Management (`leave`) — Enhanced
Staff leave requests with approval workflows and calendar.

**Operational use:** Open `leave.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Visitor Management (`visitors`) — Enhanced
Gate-pass, check-in/out, host notifications, badges.

**Operational use:** Open `visitors.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Transport / Bus (`transport`) — Enhanced
Routes, GPS tracking, pick-up records.

**Operational use:** Open `transport.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### School Fee Structure (`school_fees`) — Enterprise, Enhanced
Set current and next-term fee structures by class and arm. Each student dashboard and report card receives the matching bill and prior balance.

**Operational use:** Open `school-fees.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### School Products (`school_products`) — Enterprise, Enhanced
Manage school uniform, books, stationery and required products with price, category and stock notes for family dashboards.

**Operational use:** Open `school-products.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Cafeteria & Meals (`cafeteria`) — Enterprise
Student meal plans, dietary restrictions tracking, and pre-paid wallets.

**Operational use:** Open `cafeteria.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Scholarships & Aid (`financial_aid`) — Enterprise
Manage fee waivers, sponsor tracking, and scholarship renewals.

**Operational use:** Open `financial-aid.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Fundraising & Donations (`donations`) — Enterprise, Enhanced
Run campaigns, log donor pledges & gifts, generate thank-you receipts (Blackbaud/FreshSchools parity).

**Operational use:** Open `donations.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Online Fee Payments (`payments_online`) — Enterprise, Enhanced
Generate Paystack/Flutterwave checkout links or bank-transfer instructions — free integrations, no monthly fee.

**Operational use:** Open `payments-online.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

## Academics (7)

### Grading Rubrics (`rubrics`) — Enterprise, Enhanced
Standards-based rubrics (PowerSchool/Edsby parity): define skills/criteria and a scale so assessment aligns to learning objectives.

**Operational use:** Open `rubrics.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Academic Transcripts (`transcripts`) — Enterprise, Enhanced
Cumulative academic records / transcripts per student across sessions — international standard for transfers and applications.

**Operational use:** Open `transcripts.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Transfer Certificates (`transfer_cert`) — Enterprise, Enhanced
Issue transfer/leaving certificates (National Records Exchange parity) with conduct and reason for leaving.

**Operational use:** Open `transfer-cert.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Counselling & Wellbeing (`counselling`) — Enterprise, Enhanced
Confidential student counselling/wellbeing session log with status tracking and referrals.

**Operational use:** Open `counselling.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Affective Domain (`affective_traits`) — Enterprise, Enhanced
Record punctuality, neatness, politeness, honesty, leadership, cooperation and attentiveness ratings for each learner. These flow into report cards.

**Operational use:** Open `affective-traits.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Psychomotor Domain (`psychomotor_traits`) — Enterprise, Enhanced
Record handwriting, verbal fluency, sports, crafts, drawing and music ratings for each learner. These flow into report cards.

**Operational use:** Open `psychomotor-traits.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### Report Card Comments (`report_comments`) — Enterprise, Enhanced
Enter class-teacher comments, principal comments and next-term begins dates for each learner report card.

**Operational use:** Open `report-comments.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

## HMG Concepts (2)

### HMG Ecosystem (`ecosystem_products`) — Enterprise, Enhanced
Lead-generation page for the HMG Concepts ecosystem and client-school visibility. Distinct from the HMG Digital Products catalogue.

**Operational use:** Open `ecosystem-products.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

### HMG Digital Products (`hmg_digital_products`) — Enterprise, Enhanced
HMG Concepts Ecosystem product catalogue with official flyers and contact paths. Visible in every portal navigation.

**Operational use:** Open `hmg-digital-products.html` from role-filtered navigation. Authorised users update records; read-only roles receive a scoped view enforced again by PostgreSQL RLS. Data is reusable by dashboards, reports, notifications and exports rather than being re-entered.

## Cross-cutting enterprise capabilities

- Installable PWA with offline fallback and literal cache-version invalidation.
- Supabase PostgreSQL, Auth, RLS, server functions, storage links and realtime-ready tables.
- CBT V5.1 answer-key diagnosis/repair, pre-publish validation and missing-key fail-safe.
- Printable report cards, class/subject broadsheets, receipts, IDs, certificates and admission documents.
- Traditional static and optional Next.js modern wrapper; see the architecture assessment.
