# Demo Data Coverage

`database/demo-seed.sql` is idempotent and now covers the live storage model used by the pages—not invented table names.

## Identity and setup

- 4 academic periods, terms/sessions/arms/campuses, classes and departments.
- 18 students, 8 corrected staff records, guardians and verified parent-child links.
- School identity/settings, role/status log and controlled lookups.

## Academics

- Subjects, attendance, student/staff clock-ins, timetable and requirements.
- Results, global assessment template, report scores, comments, published report cards, domains and printable-record history.
- Scheme of work, lesson plans, assignments, diary, conduct, behaviour points, health, support plan and promotions.
- Digital/library books, reading score, book requests, transcripts, transfer and counselling examples.

## CBT

- Mathematics and English single-subject exams/results.
- `DEMO-UTME`: English Language + Mathematics, top tabs, per-subject metadata and sample attempts.
- MCQ, text-key equivalence, true/false, numeric and multi-select sample questions.

## Finance and HR

- Class fee structures, mixed payment/balance states, online payment intents and official receipt inputs.
- Finance income/expenses, payroll, staff loan, bonus, appraisal, leave and donation records.
- Financial-aid examples.

## Communications and community

- Announcements, notifications, inbox/messages, broadcast, events/calendar, poll/votes and survey/response.
- Complaints, helpdesk, parent meetings, gallery and alumni.

## Enterprise operations

- Admissions/application link, exam registrations, certificates and document builder.
- Hostel, transport/fleet, visitor/front desk, facilities, inventory audits, substitutions, cafeteria/menu, lost/found, compliance, rubrics, reports, career counselling and school products.

## Generic-page contract

The generic CRUD engine stores modules such as `financial_aid`, `parent_meeting`, `career_counseling`, `facility_booking`, `rubrics`, `transcripts` and `transfer_cert` in `module_records`. V5 seeds those exact module identifiers. This fixes the former failure where the seed referenced nonexistent plural tables while the page queried `module_records`.


## V5.6 automated coverage result

`tools/audit-demo-coverage.py` verifies **80/80 CRUD modules plus 16 specialised datasets covered**. In addition to the generic module contract, the seed includes dedicated examples for:

- e-resources and QR attendance check-ins
- CBT candidate roster and admission letters
- certificate designs
- teacher availability, timetable configuration and timetable runs
- punctuality awards and activity logs
- fee structures and published reports
- LMS courses, lessons and submissions
- security preferences, login audit and translated interface strings

## V5.6.1 execution safety

The specialised CBT block uses `v_exam_id` and qualified `st`/`cr` aliases, so PostgreSQL cannot confuse a PL/pgSQL variable with table column `exam_id`. The maintained execution harness runs `demo-users.sql` and then the full `demo-seed.sql` twice; both runs pass with roster and admission-letter records intact.

## Safe demo use

All names/data are synthetic. Do not enter real personal data. Use a Supabase project separate from production, review the five demo roles and reset periodically. See `demo-site/DEMO-SETUP.md`.
