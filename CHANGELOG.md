# 📋 CHANGELOG — School Connect Final v8 Enterprise

**Lead Developer:** Adewale Samson Adeagbo (Founder of HMG Concepts, AI-Augmented Solutions Developer, Data Scientist & STEM Educator)

---

## [Final v8 Enterprise Cumulative Release] — 2026-06-29

### 🏛️ Executive Portal Control & RLS Perfecting
* **NEW (Item 1 & 7):** Admin Portal Oversight mode. Added an interactive tab bar to the Super Admin dashboard to instantly switch between the **Main Admin Command Centre**, **Staff/Teacher Portal**, **Parent Portal**, and **Student Portal** without creating distinct user logins.
* **FIXED (Item 2 & 15):** Academic Periods RLS Error. Updated `is_admin` and `is_staff` database helpers to recognize `status in ('approved', 'active')`. Expanded `academic_periods` and `lookups` write policies to authorize both admins and staff, permanently eliminating `"new row violates row-level security policy for table 'academic_periods'"`.
* **NEW (Item 3 & 17):** Dedicated Parent Registry (`parents.html`). Introduced a standalone `parents` database table and full CRUD management interface (recording full name, email, phone, occupation, address, status) alongside a robust parent-child linking engine.
* **NEW (Item 12):** Subject Teacher Record Isolation. Enforced strict record isolation across `results`, `attendance`, `scheme_of_work`, `lesson_plans`, and `assignments`. Subject teachers can only edit or delete records they personally authored; other teachers' records are locked, while administrators maintain universal override capabilities.

### 💻 Advanced Academic, CBT, & Analytics Engines
* **NEW (Item 4):** Structured AI CBT Prompt Templates (`cbt-prompts.html`). Fully aligned with HMG Academy CBT Pro standards. Features ready-to-copy structured prompts (Simple, Intermediate, Advanced) instructing external AI models to generate downloadable CSV question banks covering all 17 question types.
* **FIXED (Item 6):** Entrance & Assessments Certificate Fix (`entrance.html`). Corrected `window.open` printing workflows to utilize `document.open()`, `w.focus()`, and `setTimeout`, eliminating blank certificate popups. Updated `en-session` to operate as a `<select>` dropdown populated from `lookups`.
* **NEW (Item 8):** Unified Scoresheet, Broadsheet, & Report Cards (`report-cards.html`). Consolidated academic reporting into three distinct outputs: **Subject Scoresheets** (editable solely by the subject teacher), **Class Broadsheets** (collating all subject marks for an entire class), and **Student Report Cards**. All parameter inputs use dynamic `<select>` dropdowns.
* **NEW (Item 9):** Executive Analytics Console (`analytics.html`). Expanded platform analytics to feature 6 advanced Chart.js visualizations: CBT Score Distribution, Enrollment Trends, Monthly Attendance Trends, Fee Collection Status, Subject Performance Comparison, and Community Demographics.
* **NEW (Item 10):** Scheme of Work Confirmation (`sow.html`). Added `confirmed boolean default false` to `public.scheme_of_work`, enabling teachers to log weekly topics and verify classroom delivery.
* **FIXED (Item 14):** Complete CBT Examination Repair (`cbt-exam.html`). Resolved the `?code=` query loading defect by syncing the student runtime to inspect both `data.questions` and `data._questions`. Students can take shared exam codes instantly without user accounts.

### 📱 Enterprise Operations & General Bug Fixes
* **FIXED (Item 11 & 21):** Google Drive Media & Signature Rendering (`gallery.html` & `settings.html`). Refactored Google Drive URL parsing to utilize direct viewing exports (`/uc?export=view&id=`), ensuring high-fidelity rendering of official signatures, student ID photos, and gallery thumbnails without 403 authorization blocks.
* **NEW (Item 13):** Developer Branding Affirmation (`developer.html`). Ensured the lead developer's full name (**Adewale Samson Adeagbo**) precedes his official title (*AI-Augmented Solutions Developer, Data Scientist & STEM Educator*).
* **NEW (Item 16, 18, 19, 20):** Granular Privilege Mapping. Refactored `T.modulePage` and `crud.js` action columns to grant students and parents read-only access to announcements, timetables, and calendars while retaining write access to complaints, messaging, and parent meetings.
* **NEW (Item 22):** Two-Way In-App Messaging (`messages.html` & `inbox.html`). Established seamless two-way communication between students/parents and teachers/staff/admins. All in-app messages route to `module_records` (`module: 'inbox'`).
* **NEW (Item 23):** E-Receipt Printing (`fees.html` & `student-profile.html`). Embedded "Print E-Receipt" functionality across parent fee tables and student 360° dashboards, featuring dynamic school logos and official bursar/principal signatures.
* **FIXED (Item 24):** Automated Verification Alignment. Executed a comprehensive repository file audit. All 168 automated verification tests pass with 100% success.

---
*© 2026 Adewale Samson Adeagbo · Powered by HMG Concepts*

## v7.0.0 — Enterprise v7 (2026-07-04)
- Premium ID card refined to match the new sample exactly: larger bold name, navy bold field labels (Class/Student ID/D.O.B./Valid Thru), navy SCAN TO VERIFY.
- ID-card photo pipeline (issue 10 final): dual-endpoint Google-Drive fallback (thumbnail → lh3.googleusercontent) on ALL card templates before initial-letter avatar.
- Print windows fixed globally: every popup (ID cards, certificates, receipts, payslips, report cards, entrance letters, exam tickets, documents, exports) now injects <base href> so relative logos/photos resolve, and waits for ALL images to load before window.print() — logos/photos can no longer print blank.
- dd/mm/yyyy completion: voting closes-at, CBT watermark, PDF export stamps.
- Report-card & entrance signatures: server-synced (school_settings) + Drive-direct + background removal now applied in the page-level print paths too.

## v8.0.0 — Enterprise v8 (2026-07-04)
- Voting access fixed at the SHELL level: page data-require-role now matches nav role-allow on all pages/templates — students/parents/staff can open the booth and cast votes (no more false "Restricted Page").
- Login with Student ID / Staff ID / admission number OR email (lookup_login_email security-definer RPC; database/update-v8-schema.sql).
- Entrance & Assessment: bulk result-slip printing; premium GOLD result certificate (same design family as Certificates page); offline exam backup (JSON) re-import with duplicate guard (cbt_import_backup RPC) on Entrance AND CBT Manager pages.
- Universal export: shared _printWindow helper (base-href + wait-for-images → browser Save-as-PDF); admission form single PDF export + Print/PDF ALL applications.
- Multi-subject CBT listed in its OWN section (UTME badge) separate from ordinary CBT.
- Dropdown duplicates fixed: case-insensitive dedupe in CRUD + CBT/multi-subject pickers.
- Weak-network mode (issue 14): SW navigations race a 4s timeout then serve cache; assets use stale-while-revalidate; CBT submits: 6 retries capped at 8s + auto-resubmit queue flushed on next load (100+ concurrent candidates).
- Entrance slip/letter hard-coded logo.svg → school's real logo extension.

## v9.0.0 — Enterprise v9 (2026-07-04)
- Navigation policy update (client request): admin-only pages are now REMOVED from student/parent/staff navigation entirely (previously padlocked). Admin menu remains complete & deterministic via normalizeNavOrder; ensureNavNotBlank safety net retained.
- 400+ concurrent CBT: exam-load retries (5× backoff+jitter) + 10-minute local exam cache (refreshes never re-hit the DB) + v8 submit queue; database/update-v9-schema.sql adds covering/BRIN indexes + ANALYZE.
- All v6–v8 fixes retained and regression-verified (41-point interconnection audit).

## v10.0.0 — Enterprise v10 (2026-07-04)
- NAV ROOT CAUSE FOUND & FIXED (issue 2): cbt.html, cbt-prompts.html, entrance.html (and site parents.html) shipped a hand-written sparse nav — ~87 of 90 links had NO data-module-id/data-role-allow, so role filtering + canonical ordering never applied there ("sometimes complete, sometimes incomplete"). Navs rebuilt from the canonical attributed nav (98–101 links) in BOTH the generator templates and the generated site.
- Parent/student navigation audited (issue 3): parents += transport, health, transcripts, financial_aid; students += transport, transcripts.
- dd/mm/yyyy sweep (issue 4): fixed entrance letter date, cbt-exam "opens at", student-profile fee dates.
- student-profile.html E-Receipt rebuilt through the fixed pipeline (logo + server-synced signature + bg removal + dd/mm/yyyy + base-href/image-wait) — it had its own bypassing copy (issues 16/21).
- academic-records print + settings signature preview now use driveDirect + background removal (issue 16).
- Page-level dropdown loaders (attendance/digital-library/timetable) deduped case-insensitively (issue 22).

## v11.0.0 — Enterprise v11 (2026-07-04)
- PARENT-LINK "NOTHING HAPPENS" ROOT CAUSE (issue 11): Supabase query builders are PromiseLike (.then only) — 27 call sites chained .catch() directly on builders, throwing a TypeError that silently aborted CRUD.save() (incl. the parent_child duplicate guard). All converted to .then(r=>r, fallback); CRUD.save also wrapped so any future exception surfaces as an error toast.
- NOTIFICATIONS ROOT CAUSE (issues 16/19): Notifications.allowedForMe() was CALLED but NEVER DEFINED → every fetch threw inside .filter() → recipients saw nothing. Implemented with full audience semantics (all/private/role/recipient_id). create() now stamps created_by and supports targeted recipient_id; in-app messages notify the CHOSEN audience/recipient (was hard-coded 'all' on private messages). notif_mark_read RPC lets parents/students clear their unread badge under RLS.
- ADMISSION PREFIX ROOT CAUSE (issue 8): the settings ROW could predate the acronym default → update-v11-schema.sql backfills row id=1 (generator rewrites it to the school acronym; GOSA set for the demo site).
- Fee balance on e-receipts (issue 13): fee_total/balance fields, auto-compute (total − paid), balance + FULLY PAID flag printed on receipts.
- Navigation search bar (issue 7): live page search at the top of the nav pane; respects role visibility.
- Premium ID card (issue 1): authorised-person signature block (server-synced, Drive-direct, bg-removed) added under the crest; address/phone/email/motto footer already present.
- Dropdown duplicates 2nd root cause (issues 15/18): pickers appended without clearing on re-init (certificates, entrance, ID cards, student-profile) — now clear-first + dedupe.

## FINAL — Enterprise (2026-07-05)
- Full-chat compliance audit: every prompt line re-checked against the build; omissions restored.
- NEW #4: samples/ folder — sample report card, class broadsheet, subject broadsheet and fee e-receipt (SAMPLE-watermarked, print-ready) shipped in the builder, the demo site and every generated ZIP; linked from Report Cards / Academic Records / Fees pages.
- NEW #5: dedicated payment-history.html — daily/weekly/monthly/termly/session/custom-range tracking with KPIs, per-day summary, bulk report print/PDF, bulk one-per-page receipts (with balances), CSV export; nav link + fees-page shortcut; ships in every ZIP.
- NEW #6 completion: remaining balance now also on the student-profile receipt (last bypass) and throughout bulk receipts.
- Nav: payment-history registered in pageFileName/NAV_ORDER/dedicated pages; admin/bursar-only.

## FINAL V2 — Enterprise Final v2 (2026-07-05)
- #5: Entrance result slip now carries EXAMINATION OFFICER + principal signature lines (auto signature, bg-removed).
- #6: slip date leak fixed (dd/mm/yyyy) — full re-sweep clean.
- #7: samples rebranded to HMG ACADEMY; platform e-receipt rebuilt to match the sample exactly (header contact lines, dashed rows, green AMOUNT PAID box, red balance box / FULLY PAID); report-engine restyled to the sample navy palette.
- #8/#16: balance auto-computed and reflected in every record (list view computes legacy rows) and every receipt.
- #9/#10: authorised signature now on ALL ID templates via shared signBlock(); SIX new professional templates added (Executive, Minimal, Gradient, Badge, Smart Card, Heritage) — every card carries logo, address/phone/email strip, QR verify, photo chain and signature. 10 templates total.
- #11: last un-deduped pickers fixed (idcards by record id, student-profile grouped).
- #21: Admission application expanded to 28 fields (bio-data, origin, religion, address, medical, previous school, guardian, documents via Drive links, special needs, marketing source).
- #22: NEW module + page “External Exam Registrations” — WAEC/NECO SSCE, UTME (JAMB), IGCSE, Common Entrance, BECE, GCE…: candidates, subjects/courses, fees & balances, exam numbers, centres, status funnel, CSV/PDF extraction. In catalog (89 modules), nav, generator ZIP.
