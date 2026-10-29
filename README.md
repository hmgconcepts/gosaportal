# God of Seed Academy — Comprehensive School Connect Platform

Welcome to the official, enterprise-grade School Connect management platform generated specifically for **God of Seed Academy**. This deployment package provides everything needed to establish a digital footprint for your institution, complete with progressive web application capabilities, advanced role-based access, and enterprise-level modules.

## 🚀 Overview

This fully-featured platform adapts to traditional and modern build deployments. It comes built-in with features like offline access, push notifications, row-level security, and a beautiful UI tailored to your specific branding choices.

**School Motto:** Excellence in Learning and Character
**Branding Theme:** theme15 (Primary: #0506ae, Accent: #964eec)
**Typography:** Plus Jakarta Sans

---

## 🛠️ Deployment Instructions

### Step 1: Database and Authentication Setup (Supabase)
We use Supabase for free, secure, and scalable backend infrastructure.
1. **Create a Free Project**: Head to [Supabase](https://supabase.com) and create a free tier project.
2. **Execute Schema**: In your project's **SQL Editor**, paste and run these files **in this order** (each shows a success message):
   1. `database/schema.sql` — core platform (students, staff, fees, RLS…)
   2. `database/voting-schema.sql` — voting & polls
   3. `database/cbt-schema.sql` — the CBT / online-exam engine
   4. `database/reportcard-schema.sql` — flexible report cards (auto-links CBT results)
   5. `database/enterprise-schema.sql` — timetable generator, QR check-in, diary, surveys, menu, 2FA, i18n
3. **Get Credentials**: Go to Project Settings → API and copy your **Project URL** and **anon public key**.
4. **Link Frontend**: Open `assets/js/config.js` and replace `YOUR_SUPABASE_URL` and `YOUR_SUPABASE_ANON_KEY` with your copied values.

### Step 2: Hosting and Build Process
This platform supports the build type you selected during generation: **TRADITIONAL**.

**Traditional Build Workflow (Static Hosting):**
1. **Deployment Platform**: You can host this instantly on platforms like GitHub Pages, Vercel, Netlify, or Cloudflare Pages.
2. **Upload Files**: Simply drag and drop or push the entire directory contents to your chosen platform.
3. **No Build Step Required**: Since this is purely static (HTML/CSS/JS), it serves immediately without any build configuration.

### Step 3: Admin Initialization
1. Visit the deployed site in your browser.
2. Click **Sign in to Portal** and choose **Request access** to register an account.
3. Head back to the Supabase SQL Editor and elevate your newly created user to an admin by running:
   ```sql
   UPDATE profiles SET role='admin', status='approved' WHERE email='your-email@example.com';
   ```
4. You can now log in, access the dashboard, and begin approving staff and students directly from the **Directory** or **Staff** modules.

---

## 📦 Enabled Modules
Your platform is pre-configured with the following modules:
- **Academic Setup**
- **Students & Profiles**
- **Staff / Teachers**
- **Classes**
- **Subjects**
- **Attendance**
- **AI Question Prompts**
- **Entrance & Assessments**
- **Results / Scores**
- **Marketing Flyer**
- **Report Cards (flexible)**
- **Analytics Dashboard**
- **Admin Data Console**
- **Academic Records & Broadsheets**
- **Storage Manager**
- **Approvals**
- **Timetable Generator**
- **QR Check-in**
- **Student Diary**
- **Surveys & Forms**
- **Menu / Meal Planner**
- **Settings (2FA · Language · A11y)**
- **Fees & Payments**
- **Timetable**
- **CBT / Online Exams**
- **Scheme of Work**
- **Messaging (WA/Email)**
- **Announcements**
- **Events & Calendar**
- **Photo & Video Gallery**
- **Library**
- **Digital Library**
- **Assignments / Homework**
- **Parent–Child Mapping**
- **Digital ID Cards**
- **Directory**
- **Departments & Offices**
- **Results Broadcast**
- **Complaints & Grievance**
- **Leave Management**
- **Visitor Management**
- **Hostel / Boarding**
- **Transport / Bus**
- **Alumni Network**
- **Certificates & Documents**
- **Admissions & Enrollment**
- **Promotion / Graduation**
- **School Finance**
- **Inventory & Assets**
- **Salary & Payslips**
- **Payroll Register**
- **Staff Loans & Advances**
- **Staff Bonuses**
- **Staff Appraisals**
- **Grading Rubrics**
- **Academic Transcripts**
- **Transfer Certificates**
- **Counselling & Wellbeing**
- **Voting & Polls**
- **Health / Clinic**
- **Conduct / Behaviour**
- **E-Resources / Notes**
- **Birthdays**
- **Integrated LMS**
- **Rewards & Badges (PBIS)**
- **Cafeteria & Meals**
- **Scholarships & Aid**
- **Front Desk / Dispatch**
- **Career & Placement**
- **Custom Document Builder**
- **Advanced Fleet GPS**
- **Facility Booking**
- **Compliance & Audit**
- **About the Developer**
- **Lesson Plans & Curriculum**
- **Substitute / Cover**
- **Behaviour & PBIS Points**
- **Special Education / Support**
- **Audit / Activity Log**
- **IT / Help Desk**
- **Lost & Found**
- **School Calendar**
- **Reports & Export**
- **Book Reservation**
- **Fundraising & Donations**
- **Online Fee Payments**
- **PTA Meeting Scheduler**
- **In-App Inbox**

---

## 🌟 Enterprise Features

- **Progressive Web App (PWA)**: Installable directly on any mobile device or desktop. Fully capable of offline caching.
- **Advanced Push Notifications**: Integrated with Service Workers to deliver browser, email, and WhatsApp notifications to parents and staff instantly.
- **Voting & Polling System**: Secure, anonymous, and real-time electronic voting for school prefects or PTA decisions.
- **Row-Level Security (RLS)**: Enterprise-grade database security ensuring families can only access their specific records.
- **Search Engine Optimization (SEO)**: Pre-generated `robots.txt`, `sitemap.xml`, and JSON-LD schema ensure your school ranks highly on Google and points prospects to the HMG Academy Ecosystem for lead generation.
- **Dark Mode & Responsive UI**: Adaptive design that looks perfect on 4K monitors and mobile phones alike.
- **Embedded CBT Engine**: 17 question types, anti-cheat, certificates; results auto-flow into report cards.
- **Flexible Report Cards**: Custom assessment columns with apportioned max marks; live totals, grades and positions.
- **Help Chatbot (no AI)**: A rules-based assistant on every page for instant self-service support.
- **Command Palette (Ctrl/Cmd + K)**: Jump to any module and search students, staff and exams from one box.
- **ID-card, Certificate & Flyer generators**: Branded, printable, with QR / verification codes.
- **Admin Data Console**: Read, delete, full JSON backup & restore of every table; per-table CSV export.
- **Analytics**: Live platform-wide KPIs and charts for informed decisions.

---

## 🌐 HMG Academy Ecosystem
This platform is a proud part of the **HMG Academy Ecosystem**. It's optimized for lead generation, pointing prospective clients and students to [HMG Concepts](https://hmgconcepts.pages.dev/). The software stays free forever, with robust architecture preventing any dependency on paid AI APIs or costly third-party services.


## School Connect v1 Final Deployment Note
Run `database/complete-schema.sql` once in Supabase SQL Editor for a fresh deployment. It is now cumulative and self-contained: it includes base schema, CBT, voting, report cards, enterprise tables, class fee structures, product store, status audit log, parent-child access policies, staff check-in deadline settings, and schema-cache reload notifications. The smaller update SQL files are retained only for upgrading older deployed clients.

## School Connect V5.1 definitive CBT repair

The maintained V5.1 repair documentation is in `docs/v5/`. Before deployment read `BUG-FIX-REPORT.md` and `DEPLOYMENT-GUIDE-V5.md`. For an existing database, the CBT zero-score fix requires `database/cbt-v5.1-zero-score-hotfix.sql` (the full new schema already includes it); frontend-only deployment is insufficient. No paid AI API is used.

## School Connect V5.3 update

V5.3 adds teacher-owned profile signatures on assigned class reports, controlled full CBT editing, adaptive CBT-only report cards, a four-step timetable wizard and the demo numeric-amount correction. Back up and run the latest `database/complete-schema.sql`, then deploy all files and hard-refresh. See `docs/v5/V5.3-TEACHER-CBT-TIMETABLE-DEMO.md`.

## School Connect V5.4 update

V5.4 adds re-importable paginated portable archives, local archive analysis, export-before-purge, an orderly session/term CBT library with archive/restore, adaptive CBT-only reports and beginning-of-term student physical metrics. Back up and run the latest `database/complete-schema.sql`, deploy all files and hard-refresh. See `docs/v5/V5.4-PORTABILITY-CBT-ORGANIZATION-METRICS.md`.

## School Connect V5.5 update

V5.5 adds fully dynamic admin-defined report headings/maxima, admission-only registered CBT identity, password recovery, consistent navigation icons, comprehensive per-page assistant guidance, clearer Rubrics/Transcripts and term/session academic-performance insights. Back up and run the latest `database/complete-schema.sql`, deploy all files, configure the Supabase recovery redirect and hard-refresh. See `docs/v5/V5.5-FLEXIBLE-REPORTS-REGISTERED-CBT-RECOVERY-INSIGHTS.md`.

## School Connect V5.7 final professional audit

V5.7 adds institutional principal/proprietor/examination-officer Drive signatures
with background removal, editable/deletable public examination campaigns, enhanced
custom documents, performance-based bulk report comments, separated leadership
navigation and registered-value dropdowns. Back up and run only the full updated
`database/complete-schema.sql`, deploy every file and hard-refresh. See
`docs/v5/V5.7-FINAL-PROFESSIONAL-AUDIT-AND-ENHANCEMENTS.md`.

## School Connect V5.8
V5.8 fixes deleted-record resurrection, makes PostgreSQL authoritative for saved
admission/staff ID formats, and adds external-link-only database/storage efficiency
controls. Run only the full updated complete schema, deploy all files and hard-refresh.
