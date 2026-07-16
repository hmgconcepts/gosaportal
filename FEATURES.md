# 📚 FEATURES — School Connect Final v8 Enterprise Suite

> **School Connect Final v8** delivers a consolidated ecosystem of **71 enterprise modules**, super features, and specialized tools. Built by **Adewale Samson Adeagbo** (Founder of HMG Concepts, AI-Augmented Solutions Developer, Data Scientist & STEM Educator), this platform operates entirely in the browser while connecting to a secure Supabase database instance.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                      THE SCHOOL CONNECT 7 FEATURE SUITE                      │
├──────────────────────────────┬──────────────────────────────┬────────────────┤
│    ACADEMIC & ASSESSMENT     │   ENTERPRISE & MANAGEMENT    │ SUPER FEATURES │
├──────────────────────────────┼──────────────────────────────┼────────────────┤
│ • CBT Engine & Tolerance     │ • Part-Time Timetable Gen    │ • Help Chatbot │
│ • AI Prompts for CBT CSV     │ • Attendance QR Check-In     │ • Ctrl+K Search│
│ • Anonymous Entrance Exams   │ • Dynamic Student Diary      │ • ID Card Gen  │
│ • Report Cards & Broadsheets │ • Menu Planner & Cafeteria   │ • Cert Builder │
│ • Digital Library & Quizzes  │ • HR, Payroll & Staff Loans  │ • Flyer Creator│
│ • Automated Exam Promotion   │ • Admin Data Backup/Restore  │ • Notification │
│ • Scheme of Work Sign-Off    │ • Storage Manager & Purge    │   Fan-Out Hook │
└──────────────────────────────┴──────────────────────────────┴────────────────┘
```

---

## ⭐ Advanced Academic & Assessment Suite

### 💻 Computer-Based Testing (CBT) Engine (`cbt-engine.js`)
An advanced, browser-based exam runner mirroring HMG Academy Standalone CBT standards. Supports **17 distinct question types** (including exact/tolerant numerical input, assertion-reason, case studies, matrix grids, and code algorithms). Features automated grading, countdown timers, and strict anti-cheat monitoring (tab-switching, focus loss, copy-paste blocks).

### 🧩 Downloadable AI Prompt Templates (`cbt-prompts.html`)
Provides structured, ready-to-copy AI prompts (Simple, Intermediate, Advanced) instructing external AI assistants (ChatGPT/Claude) to generate downloadable CSV question banks covering all 17 question types. Zero runtime AI API keys are required.

### 🎓 Anonymous Entrance Examinations (`entrance.html`)
Allows candidates to sit admissions assessments without user accounts. Administrators receive instant performance scores and can generate branded result slips, verifiable certificates, and official admission letters individually or in bulk.

### 🧾 Unified Scoresheet, Broadsheet, & Report Cards (`report-cards.html`)
Seamlessly maps class marks and CBT results into three executive reporting tiers:
1. **Subject Scoresheets:** Editable exclusively by the designated subject teacher.
2. **Class Broadsheets:** Collating all subject marks across an entire class arm.
3. **Student Report Cards:** Termly academic transcripts embedded with official principal signatures.

### 📚 Digital Library & E-Resources (`digital_library.html`)
Catalogs e-books, past papers, and instructional media via direct Google Drive integration. Features auto-marked reading quizzes that flow directly into student report cards as continuous assessment scores.

---

## 🏛️ Enterprise Management & Institutional Control

### 👁️ Admin Portal Oversight & Role Switching
The Super Admin dashboard features an interactive oversight hub allowing executives to instantly view and experience the full **Main Admin Command Centre**, **Staff/Teacher Portal**, **Parent Portal**, and **Student Portal** without creating distinct logins.

### 👨‍👩‍👧 Dedicated Parent Registry (`parents.html`)
Equipped with a standalone `parents` database table and full CRUD management interface (recording full name, email, phone, occupation, address, status), complemented by an intuitive parent-child linking engine.

### 📊 Executive Analytics Console (`analytics.html`)
A live, platform-wide visual telemetry center powered by Chart.js. Features 6 high-fidelity visualizations:
* **CBT Score Distribution:** Breaks down student performance across grading bands.
* **Enrollment Trends:** Visualizes student intake over the trailing 6 months.
* **Monthly Attendance Trends:** Maps student attendance percentages across academic terms.
* **Fee Collection Status:** Illustrates the ratio of fully paid, partial installment, and overdue accounts.
* **Subject Performance Comparison:** Identifies high-performing departments and academic bottlenecks.
* **Community Demographics:** Visualizes gender distributions and staff-to-student ratios.

### 📱 Two-Way In-App Messaging (`messages.html` & `inbox.html`)
Facilitates seamless two-way messaging between students/parents and teachers/staff/admins. Messages route securely to `module_records` (`module: 'inbox'`).

### 💰 Finance, Fee Tracking, & E-Receipts (`fees.html` & `student-profile.html`)
Provides secure school-fee payment tracking with automated balance calculations. Includes "Print E-Receipt" functionality across parent fee tables and student profiles, embedding official bursar signatures and school logos.

---

## 🚀 "Super Features" (Built into Every Generated Site)

* **💬 Help Chatbot (`Super.chatbot`):** A rules-based assistant embedded on every page, featuring 29 topics, scored fuzzy matching, direct deep-links, and tappable quick-reply chips.
* **🔎 Global Command Palette (`Super.palette`):** Activated via `Ctrl + K`, providing instant global searching across modules, live students, staff members, and exam records.
* **🔔 Notification Fan-Out Hooks (`Super.notify`):** Simultaneously writes in-app alerts, triggers browser Web Push notifications, and generates free pre-formatted WhatsApp, Email, and SMS deep-links.
* **🪪 Digital ID-Card Generator (`Super.idcard`):** Dynamically designs professional corporate/vertical ID cards featuring scannable QR codes, student photos, and emergency contacts.
* **📜 Certificate Generator (`Super.cert`):** A visual certificate designer generating secure credentials embedded with cryptographic verification codes verifiable on `verify-certificate.html`.
* **📰 Marketing Flyer Creator (`Super.flyer`):** A professional publishing tool for school announcements and admissions campaigns, supporting custom palettes and typography presets.

---
*© 2026 Adewale Samson Adeagbo · Powered by HMG Concepts*
