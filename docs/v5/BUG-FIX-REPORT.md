# School Connect V5 — Diagnosis and Bug-Fix Report

## Critical CBT mark failure

### Root causes

1. Candidates selected `A/B/C/D`, while many question banks stored the correct **option text** (`4`, `True`, etc.). The SQL scorer performed only lowercase exact-text comparison, so correct answers became wrong.
2. Candidate questions could be randomised, but the legacy `cbt_submit` function graded payload position 0 against bank position 0. It ignored each answer’s `_orig_index`.
3. The page called the old RPC even though a newer `v2` function existed. The newer function still used exact-text comparison.
4. The browser getter correctly removed private answer keys, so client-side grading was necessarily zero; the faulty server result therefore became the visible final result.
5. Submissions had no stable `client_ref`, permitting duplicate inserts during retries.

### Fix

- Added canonical server functions `sc_cbt_norm`, `sc_cbt_canonical_option` and `sc_cbt_answer_matches`.
- Supports letter↔option-text equivalence, true/false aliases, numeric tolerance, accepted short-answer alternatives and complete multi-select set comparison.
- Added the distinct `cbt_submit_v5` endpoint so PostgREST/browser caches cannot silently resolve an old overload. Canonical `cbt_submit` and `cbt_submit_v2` delegate to V5.1.
- Preserves decimal total marks, counts correct/wrong/skipped, applies negative marks, resolves the registered student and stores `subject_scores`.
- Added stable browser `client_ref`, keyed draft recovery and terminal-error handling.
- Added pre-publish answer-key validation, manager **Diagnose Scoring**/**Repair Scoring**, a focused existing-database hotfix, and an executed SQL-engine test covering `CorrectAnswer`, `Correct Answer`, `answer_key`, `correct_option`, `rightAnswer`, option text, true/false, numeric tolerance and multi-select.
- Missing objective answer keys now return `answer_key_missing`; they cannot be inserted as a silent zero.
- Added `cbt_regrade_exam_results_v5` and **Regrade Saved Results** so historical zero rows are recalculated when their `answers_data` is available.

## Missing UTME/JAMB subject tabs

### Root causes

1. The generator’s `assets/templates/pages/cbt-exam.html` was older than the working root page, so a new client ZIP could reintroduce the old behaviour.
2. “Repair Tabs” inspected only `csv_data`; older exams stored the bank in `questions`.
3. Repair updated only `csv_data`, leaving the active legacy bank and metadata divergent.
4. Candidate exam loading was cache-first for ten minutes. A successful repair could remain invisible on the same device.
5. The page contained a stale inline `Exam.go(...)` reference even though `Exam` was scoped inside an IIFE.

### Fix

- Made root/template parity a tested contract.
- Repair reads either bank, writes both banks, stamps all section aliases and updates `updated_at`.
- Candidate load is network-first with a 24-hour offline fallback rather than stale cache-first.
- Multi builder rejects empty banks and duplicate subject names.
- Tabs are sticky, keyboard/button accessible, show answered/total progress and retain independent subject navigation.
- Added `DEMO-UTME` with English and Mathematics tabs, including MCQ, true/false, numeric and multi-select questions.

## Exam identity/header incomplete

- Replaced the generic logo/title with generated school logo, name, motto, address, phone and email.
- The safe public exam RPC can return current school settings; generated `config.js` remains the fallback.
- Each active question card shows examination title, candidate, class and term/session.
- Logo extension is dynamic with an SVG fallback; default builds without uploaded data can no longer point to a nonexistent PNG.

## Report card, class broadsheet, subject broadsheet and receipt mismatch

### Root causes

- Report Cards had a separate plain printer, while Academic Records used `ReportEngine`; outputs therefore did not match samples.
- Score entry used `report_scores`, but printing primarily queried legacy `results`.
- Demo columns were subject-specific while the current page loaded only the global `subject='*'` template.
- Attendance queried nonexistent `term` and `session` columns.
- Stamp/signature blocks could be appended twice.
- `fmtDMY` was called but not defined.
- Student Profile maintained another, visually different receipt renderer.

### Fix

- All three Report Cards print actions now route through `ReportEngine`.
- Added adapter from `assessment_columns`/`report_scores` to sample CA1/CA2/CA3-CBT/Project/Exam bands.
- Modern global template is preferred; legacy subject columns remain supported.
- Output classes, typography, rotated class columns, statistics, domains, comments, signatures and seals follow the supplied samples.
- Grading scale is consistently A 80+, B 70+, C 60+, D 50+, E 40+, F below 40.
- Attendance resolves date bounds from `academic_periods`.
- Added `fmtDMY`; duplicate official blocks are suppressed.
- Student Profile delegates receipt printing to the canonical sample-matched CRUD receipt.
- Added database fee-balance trigger so browser and database inserts print the same balance.

## Demo seed failure and empty pages

### Errors found

- `alumni.occupation` did not exist; the live column/CRUD field is `current_occupation` (reported PostgreSQL 42703).
- Subsequent seed blocks referenced other nonexistent tables/columns (`library_books`, `book_requests`, `parent_meetings`, `financial_aid`, certificate aliases, etc.).
- Staff seed values were shifted: job title was inserted as email, department as role and email as a subject.
- Staff clock timestamp concatenation could create an invalid timestamp.
- Classes, parents, departments, lookups, multi-subject CBT and many operational pages had no sample rows.
- Old demo report columns did not match the current global report template.

### Fix

- Corrected `current_occupation` and every seed/schema column contract; automated audit reports zero missing seed columns.
- Generic pages now seed `module_records`, the table the CRUD engine actually uses.
- Corrected staff mapping with idempotent upsert.
- Added valid timestamp construction.
- Added classes, guardians, departments, terms/sessions/arms, global report bands, published report cards, multi-subject CBT and a complete page-coverage pack.
- Added rows for finance, payroll, staff loans/bonuses, timetable, scheme, transport, behaviour, support plans, promotion, birthdays, digital library, menu, survey responses, payments, admissions, exam registrations, documents, status logs, notifications and every generic module.

## Generator/build faults

- JPEG flyers were fetched as UTF-8 text and could be corrupt in generated ZIPs. Added binary loader; tests verify JPEG magic bytes.
- Modern scaffold copied the portal before logo/README creation, leaving `modern/public` incomplete. Copy now occurs last.
- Generator template drift could emit its own marketing index and dead builder links into a client ZIP. Client templates were restored; rich critical templates are parity-tested.
- Integrity auditor did not normalise `./` paths in modern output. Fixed path normalisation.
- Traditional build: 183 entries, 0 broken links, 0 orphans.
- Modern build: 387 entries, 0 broken links, 0 orphans.
- Module counter was corrected from 96 to the actual 97 catalogue records.

## Other runtime faults

- `site-help.js` contained two unescaped single-quote syntax errors; the help assistant could fail on every page. Fixed and removed the inline close handler.
- Static service workers reused an old literal cache and JavaScript could remain stale. Cache version was bumped and JS/HTML now revalidate.
- Browser/schema contract columns were reconciled additively for staff, parents, conduct, health, promotion, complaints, birthdays, behaviour, inventory, substitutions, trait data and admission links.

## Files requiring redeployment

At minimum deploy the complete repositories. The critical runtime set is:

- `cbt-exam.html`, `cbt-multi.html`, `cbt.html`
- `assets/js/cbt-engine.js`
- `database/complete-schema.sql`
- `report-cards.html`, `academic-records.html`, `student-profile.html`
- `assets/js/report-engine.js`, `assets/js/crud.js`
- `database/demo-seed.sql` (demo only)
- `sw.js`, `_headers`, `vercel.json`

Running the new frontend without rerunning `complete-schema.sql` leaves the old scorer in the database and will not solve zero marks.
