# School Connect — Complete Feature Reference

**Version:** 12.76 · **Date:** 8 November 2026
**Applies to:** the generator (`schoolconnect`), and both deployments (`gosaportal`, `schoolconnectdemo`).

This document explains **every feature in the platform**: what it does, how it works, who may use it, and what the system guarantees about it. Nothing here is aspirational — every item listed exists in the shipped code and is exercised by the regression suite.

---

## 1. What School Connect is

A **complete, self-hosted school management SaaS** that runs on two free services and needs no server of its own:

| Layer | What it is | Cost |
|---|---|---|
| Front end | 134 static HTML pages + vanilla JavaScript (no build step, no framework) | free (any static host: Netlify, Vercel, Cloudflare Pages, GitHub Pages) |
| Database | 134 tables · 269 functions · 315 row-level-security policies in one 974 KB SQL file | free (Supabase free tier) |
| Third-party runtime | **none at run time** — supabase-js, Chart.js, jsQR and JSZip are vendored in `assets/vendor/` and precached | free |
| Data + auth + API | Supabase (PostgreSQL + PostgREST + GoTrue) | free tier |
| Scheduled work | `pg_cron` inside the same database | free |
| Reports / PDFs | Generated **in the browser** (vector PDF writer, no server) | free |
| QR codes | Generated in the browser by a bundled encoder | free |

There is **no AI API, no paid service, and no per-seat licence** anywhere in the stack. The only recurring cost of a deployment is whatever the school chooses to pay Supabase and a static host — both of which have a workable free tier.

### The three roles of the codebase

1. **The generator** (`schoolconnect/`) — a browser-only wizard that asks for a school's name, colours, logo, and modules, and writes a complete, branded, ready-to-deploy site.
2. **A deployment** (`gosaportal/`, `schoolconnectdemo/`) — the same site, generated. Same logic, different branding. `tools/audit-repo-parity.py` proves that the two deployments carry the generator's logic and differ only in branding.
3. **The database** (`database/complete-schema.sql`) — one file, one paste, ~999 KB, idempotent. It creates every table, function, policy, trigger and index the platform uses.

---

## 2. Identity, roles and permissions

**How a person gets in.** Supabase Auth handles sign-up, sign-in, password reset and session refresh. A trigger (`handle_new_user`) creates the matching profile row.

**Roles.** `super_admin`, `admin`, `principal`, `proprietor`, `head_teacher`, `bursar`, `staff`, `teacher`, `parent`, `student`. Every page declares `data-role-allow="..."`; the navigation, the page shell, and the database policies all read the same list. A role that is not allowed sees no link, and a role that reaches the URL directly is refused by the page *and* by row-level security.

**Approvals.** A new staff account is inert until an administrator approves it (`approvals.html`). This is deliberate: a school's data must never be reachable by whoever typed a valid email.

**Parent ↔ child linkage.** `parent_child` rows connect a guardian to a learner. Every family-facing read (`get_midterm_report`, report cards, fees, attendance) resolves through `is_parent_of(auth.uid(), child)` — a `SECURITY DEFINER` function. **As of V12.75 that function runs with `search_path` pinned to `public`**, which closes a privilege-escalation path in which a caller able to create a schema could shadow `parent_child` and answer "yes, this parent owns that child".

**Teacher scoping.** `teacher_can_manage_subject_class()` limits a teacher to the subjects and classes assigned to them. Insert/update policies on `report_scores` call it, so a teacher cannot write marks for a class they do not teach, even with a hand-crafted API call.

---

## 3. The academic core

### 3.1 Setup (`academic_setup.html`)

Defines the school's skeleton: sessions, terms, classes, arms, subjects, departments, grading bands, and the **assessment structure** (how many CA columns, their maxima, and the exam column). Everything downstream — reports, CBT, midterms, transcripts — reads that structure rather than hard-coding a number.

### 3.2 Students, staff, parents, classes, subjects

Full CRUD over the roster. Each record supports a photo URL (Google Drive share links are converted to direct image URLs automatically, with a second-chance fallback host and an initial-letter avatar as the final resort — a card never prints a broken image).

Demographics captured for students include date of birth, gender, blood group, admission number, admission year and guardian contacts. The **admission year** is the only source a lifetime ID card will trust for "Admitted"; the system refuses to guess it from an admission-number pattern or a record's creation date.

### 3.3 Attendance (`attendance.html`, `checkin.html`, `checkin-staff.html`)

Per-class, per-day register with present/absent/late/excused, plus a shared scanner engine that reads the QR and Code-39 barcode printed on every ID card. It uses the native `BarcodeDetector` where available and falls back to a bundled QR decoder on iOS/Safari — the QR is on every card precisely so that fallback always works.

### 3.4 Timetable (`timetable.html`, `exam_timetable.html`, `timetable-generator.html`)

Period grid per class and per teacher, subject/teacher clash detection, and an automatic generator that fills a valid timetable from the school's subject, teacher and period constraints.

### 3.5 Scheme of work and lesson plans (`sow.html`, `lesson_plans.html`)

Week-by-week scheme of work per subject/class/term and dated lesson plans against it.

### 3.6 Results and report cards

The largest engine in the product; four screens share one truth.

- **`results.html`** — the broadsheet: every learner × every subject, entered once.
- **`report-cards.html`** — the official card: per-assessment columns with their maxima, totals, percentages, grades, class and subject positions, affective and psychomotor traits, comments, and a print/PDF layout.
- **`midterm-reports.html`** — a separate document built **only** from midterm assessments, with its own publish switch and its own position policy.
- **`prep-exam-reports.html`** — practice exams, reported but deliberately never able to reach a report card.

**How a mark becomes a report.** `report_scores` holds one row per (column, learner, subject, term, session). The column owns the maximum (`assessment_columns.max_mark`). The report engine groups the columns by their token (`CA1`, `Exam`, …), sums them, and computes totals, averages, grades and positions from the same numbers the card prints. There is no second arithmetic path anywhere in the UI.

**Guarantees added in this release (V12.75):**
- A mark can **never** exceed its column's maximum. A `BEFORE INSERT/UPDATE` trigger on `report_scores` refuses it on every write path — the RPC, the legacy upsert, a CSV import or a direct PostgREST call — and names the learner, the subject and both numbers.
- The CBT→report push can no longer manufacture an impossible mark: the percentage is clamped to 0–100 and the written value is capped at the destination maximum.
- `sc_report_mark_audit(class, term, session)` reports (never deletes) any mark already stored above its maximum; the **Report Cards → Score Audit** panel shows them and the **Midterm Reports** page shows a banner before a sheet is generated.

### 3.7 Affective and psychomotor traits, comments, bands

Trait scoring per learner per term, comment banks with automatic banding by score range (`report_comment_bands`), and per-learner comments with a staff-author check.

### 3.8 Transcripts and academic records

Cumulative records across sessions, transfer certificates, and a verification page (`verify-certificate.html`) that validates a certificate code without revealing the learner's data.

---

## 4. CBT — computer-based testing

### 4.1 Authoring (`cbt.html`, `cbt-prompts.html`, `cbt-multi.html`)

Question banks, structured and legacy formats, multiple question types, per-question marks, and a multi-subject exam builder. The editor decodes legacy JSON/CSV banks and preserves structured advanced questions.

### 4.2 Sitting (`cbt-exam.html`)

Timed delivery, per-question navigation, autosave, resume, anti-cheat configuration (tab-switch and focus-loss logging into `violation_log`), and a **pending-answer queue** that survives a lost connection. `missOf` / `recoverPending` / `replayPending` / `flushServer` guarantee that an answer typed before a network drop is never silently lost, and that a recovery audit clears once the queue drains.

### 4.3 Grading (`cbt-engine.js` + `cbt_submit_v5`)

Fraction-aware marking, partial credit, negative marking, per-subject sub-scores for multi-subject papers, and an answer-key completeness check that refuses to grade a paper with missing keys rather than scoring those questions as wrong.

### 4.4 Pushing marks to a report card

`sc_cbt_bulk_push_exam_v2` merges overlapping exams, deduplicates by student + subject under a **best** or **latest** attempt policy, and writes into a named report column. It is transaction-safe, uses one lookup per destination column, and stays inside the statement timeout. Each push reports how many results were saved, skipped as unverified, skipped as manually graded, or skipped as unidentified.

---

## 5. Fees and finance

- **Fee structures** (`fees.html`, `school_fees.html`) — per class, term and session, with items and amounts, and a sync trigger that re-derives bills on edit or delete but **never** on a re-publish (a re-run of the schema must not rewrite money that was already invoiced).
- **Billing** — `sc_fee_bill_v2` creates one bill per learner per term from the structure plus any per-learner adjustments.
- **Accounts** — `sc_fee_account` and `sc_student_fee_state` are the single source for balances, arrears and the dashboard tile. One engine, so the card, the fees page and the school-wide total can never disagree.
- **Payments** — cash, transfer, POS, and an online-payment log (`payments_online.html`) with a payment-history view per learner, receipts, and an invoice ledger.
- **Reports** — aged arrears, collection summary, adjustments register, and a financial panel whose bands are unit-tested.
- **Also present:** products/shop, financial aid and scholarships, donations, payroll, staff loans, staff bonus, and a bursar role scoped to money screens only.

---

## 6. ID cards (rebuilt in V12.75)

### 6.1 What it produces

A **two-sided physical card** at exact ISO/IEC 7810 dimensions (ID-1 85.60 × 53.98 mm by default, also ID-2, ID-3, or any custom size from 30 to 250 mm), in the orientation the school chooses. Nine front designs (Horizontal, Premium, Executive, Minimal, Gradient, Elegant, Compact, Badge, Vertical) and one data-complete back.

### 6.2 The one-box rule (the core guarantee)

Front and back are **one physical box**. Not "usually the same", not "the same unless a template does something odd" — the same, by construction:

1. The page reads the chosen size in millimetres and the orientation.
2. `Super.idcard.faceBox()` converts it to one pixel box.
3. `Super.idcard.fitFace()` renders the front on a canvas that is **retuned to the card's aspect ratio**, then scales that canvas — uniformly, never cropped, never distorted — into the box.
4. `Super.idcard.backHtml()` draws the back into the same box and re-lays itself out for the shape it is given (wide cards get two columns, tall cards stack).
5. Both faces are emitted as `[data-face]` elements of identical size, and `tools/verification/t24-idcard-parity.mjs` measures 16 size × template combinations in a real browser to prove it.

### 6.3 What is on a card

**Front:** school logo, name and motto; the design's own colour scheme; photograph (with Drive/Dropbox link resolution, a second-chance host and an initial-letter avatar); full name; ID number; and only **permanent** facts — date of birth, admission year, gender, blood group, emergency contact. No class, no arm, no expiry: the card is a **lifetime card** and must not contradict itself in two years' time.

**Back:** the card rules, a verification QR code, the school's contact block, an authorised signature, the issue year, a Code-39 barcode of the ID number, and the "if found, return to…" line.

### 6.4 Rendering guarantees

- **Nothing is clipped.** The face scopes its own stylesheet (`.sc-idcard-face`) that lets card text wrap instead of punching through the edge, and the fit is measured against the real face context, not a proxy.
- **Nothing overlaps.** The canvas is measured before it is scaled, so the QR cannot land on top of the initial-letter tile and the name cannot ghost behind the rows.
- **One label per card.** A card says "STUDENT IDENTITY CARD" or "STAFF IDENTITY CARD" and never both, on any design.
- **A staff card never inherits a student's identity.** Switching Student ↔ Staff clears every identity field, so the ID number, name, photo, gender and phone cannot leak across.
- **A design that cannot fill the chosen shape says so.** Flipping to Portrait moves a landscape design to one drawn for portrait (Vertical/Badge) once, visibly; if a design still leaves a margin, the page names it and offers the one-click cure.
- **Print = preview = PDF.** There is one vector PDF engine; the Print button builds the same PDF and sends it to the printer, so the paper and the file cannot differ.

---

## 7. Communication and community

Announcements, broadcast, messages with an inbox, notifications with a bell and unread counts, events and a school calendar, complaints, voting, surveys with real result tabulation, a gallery, and a messaging centre that unifies them.

## 8. Welfare, conduct and operations

Admissions (application → entrance exam → offer), exam registrations, promotion, alumni, certificates, transfer certificates, conduct, behaviour, health, counselling and support plans, hostel, cafeteria, menu, transport with fleet tracking, visitors, front desk, lost and found, parent meetings, facility booking, career counselling, helpdesk, and a staff directory.

## 9. Staff administration

Appraisals, leave, substitutions, payroll, loans, bonuses, a teacher overview, and a punctuality record.

## 10. Library and learning resources

Catalogue, lending, reservations, book requests, e-resources, digital library, an LMS module, and assignments (physical and CBT-linked).

## 11. Analytics, compliance and administration

Dashboards per role, analytics with trend charts, a report builder, inventory, storage, compliance checklists, an activity log, an approvals queue, advanced admin data tools, settings, a feature guide for staff, a status manager, a developer console, and data portability (export/import of the whole school's data).

## 12. The public and family surfaces

Public site (about, contact, apply, admissions, news), a parent portal, a student portal, a certificate verification page, an ID-card verification page, and a read-only family view everywhere — parents and students are structurally prevented from editing marks, regardless of which page they open.

---

## 13. Platform engineering features

### 13.1 Offline-first PWA

A service worker with a per-deployment cache name, a visible install banner, and a **"New version available"** bar whose **Update now** button:

1. asks the running worker for its version (`GET_VERSION` over a `MessageChannel`),
2. refuses to offer a version that is already applied (`localStorage.sc_pwa_applied_ver`),
3. activates the waiting worker, and — if the new one is still installing — waits for it,
4. calls `registration.update()` and performs a cache-busted reload,
5. **never reappears once the platform is on that version**.

`tools/verification/t38-update-now.mjs` asserts all of that in a browser, including that the banner does not return after the update is applied.

### 13.2 Auto-save, recovery and honest UI

Long forms save drafts locally; CBT answers queue and replay; every destructive action asks; and **nothing fails silently** — a control that reports a problem stops reporting it once the problem is fixed, which is asserted by the recovery tests rather than assumed.

### 13.3 The database as one file

`database/complete-schema.sql` is generated from a cumulative source by `tools/build-complete-schema.py`, which:

- strips comments, banner rules and progress chatter,
- removes superseded definitions (a later `create or replace` wins),
- de-duplicates identical grants and statements,
- **moves the PostgREST reload notification to the last statement**, so no object is created after the catalogue is announced,
- refuses to write a file above the 1,000,000-byte Supabase SQL Editor cap.

`tools/verify-complete-schema.mjs` then proves the built file is **object-identical** to the cumulative source — tables, views, functions, triggers, policies, indexes, constraints, grants and RLS flags.

### 13.4 Security posture

- Row-level security is **enabled on every table**, with 315 policies. The three internal log tables
  (`cbt_edit_log`, `cbt_results_recovery_log`, `cbt_retake_allowances`) are readable by administrators
  only and written solely by `SECURITY DEFINER` functions, so the school keeps an audit trail and a
  learner, parent or teacher gets nothing.
- **Privileged functions are pinned.** Every `SECURITY DEFINER` function carries
  `search_path = public, pg_temp`, so an unqualified name inside it can never be made to resolve
  somewhere an attacker controls.
- **The anonymous role holds EXECUTE on 35 documented public endpoints** — the RPCs a signed-out
  page genuinely needs (admission application, certificate verification, login lookup, the public
  CBT family, the licence banner, the keep-alive heartbeat) plus the predicates row-level security
  evaluates. Every other function requires a signed-in session.
- **Messages and notifications are private.** A message is readable by its sender, its recipient, or
  an account whose email matches a legacy row; a notification is readable by its owner or staff, with
  broadcast rows (`user_id` null) visible to everyone as the bell expects.
- **No third-party runtime.** The four JavaScript libraries live in `assets/vendor/`, are precached by
  the service worker, and no page loads anything from a CDN — a school with a dead connection still
  opens its own site.
- Marks, money and identities are validated in the database, not only in the browser.
- No AI API, no third-party analytics, no external script CDN: the page loads nothing it does not ship, which is also why the product works offline. (Google Fonts is the sole remaining external reference; a missing font degrades to the system face and cannot break a page.)

**The school can prove it without a developer.** `sc_security_posture()` returns the same seven checks
as rows — row-level security, pinned `search_path`, the anonymous execution surface, foreign-key
indexes, primary keys, private policy on the private tables, and impossible report marks — reading the
**live** catalogue rather than a snapshot. `platform-health.html` renders it as a green/amber/red table
and can copy the report into a compliance file. The gate cross-checks it against
`t40-security-audit.mjs`, so the dashboard and the audit can never disagree: if the function ever
reports a failure the gate fails too.

Two audits answer to all of the above and run in the gate: `tools/verification/t40-security-audit.mjs` reads the live catalogue of a database built from the shipped SQL, and `tools/audit-client-hardening.py` reads the shipped files.

### 13.5 Verification

`bash /home/user/work/run-all-tests.sh` runs the whole gate: schema identity, ~50 SQL engine tests, browser tests for the ID card, PWA, CBT, positions and policies, plus static audits for page wiring, phantom columns, RPC signatures, template drift across the three repos, and a 513-assertion platform audit, and a security posture function that
must agree with it.
