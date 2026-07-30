# 🎓 Onboarding Guide — Welcome to Your School Portal
**School Connect (HMG Concepts) · For new admins, staff, parents and students**

Every page of this portal explains itself in three ways:
1. **"ℹ️ What is this page?"** — a collapsible card at the top of each page: what it does, who uses it, step-by-step how-to.
2. **"❓ Page Help"** button (bottom-left) — a quick summary of the current page.
3. **💬 School Assistant** (chat bubble) — ask anything in plain language: *"How do I record fees?"*, *"Is my portal healthy?"*, *"Delete old audit logs"*. It answers with steps and takes you to the right page.

---

## 🧑‍💼 If you are the ADMIN / PROPRIETOR

**First-week setup sequence (do these in order):**
1. **Settings** — school identity: logo, motto, signatures, ID-number formats, colours.
2. **Academic Setup** — register your sessions, terms, arms and assessment columns (these feed every dropdown on the platform), then set the current Academic Period from the dropdowns.
3. **Classes → Subjects → Departments** — define the academic structure; map subjects to teachers.
4. **Staff → Students → Parents** — register people (CSV import available for students); link parents to children so the family portal works.
5. **Approvals** — every self-signup starts as *pending*; approve only people you recognise (this auto-generates their member ID).
6. **Fees** — set fee structures per class; start recording payments and printing e-receipts.
7. **🛡️ Platform Health Console** — confirm all tiles are green: keep-alive heartbeat, database space, Google Drive backup, license. Configure idle auto-lock. This page is your weekly 10-second health check.

**Your five data-safety duties (all built in, mostly automatic):**
| Duty | Where | How often |
|---|---|---|
| Confirm keep-alive is healthy | Health Console (heartbeat tile) | Weekly glance |
| Press 💓 manual heartbeat | Health Console | Weekly **during long holidays** |
| Google Drive auto-backup ON | Admin Data → Drive card | Once (then automatic) |
| Vault-archive + purge old logs | Storage Manager / Activity Log | Once a term |
| Export a local JSON archive | Admin Data | Once a term |

**Emergencies:** account compromised or exam leak → Health Console → 🚨 Lockdown ON (non-admins locked out instantly). Database lost forever → follow `docs/DISASTER-RECOVERY-RUNBOOK.md` (your Google Drive backups restore everything into a fresh database with one 🚑 button).

## 🧑‍🏫 If you are STAFF / A TEACHER
1. Sign up on the login page → wait for admin approval (you'll get your staff ID).
2. **Your daily pages:** Attendance (mark your class), Results (enter CA/exam scores — enter once, report cards build themselves), Scheme of Work (term plan, tick topics weekly), Assignments, Diary.
3. **CBT** — create online exams (17 question types), share the exam code; scores can flow into report-card columns automatically. Use **AI Question Prompts** to generate question banks with any free AI chat.
4. **Messages** — write to parents/students or the whole class; complaints assigned to you appear with status tracking.
5. You can only edit records you authored — other teachers' records are read-only to you (this protects everyone).

## 👪 If you are a PARENT
1. Sign up → the school links you to your child(ren) and approves you.
2. Your portal is **read-only and family-safe**: you see ONLY your own children — their results, report cards, attendance, homework diary, fees and receipts (print e-receipts yourself), announcements and events.
3. Use **Messages/Complaints** to write to the school; track the response status.
4. Install the portal as an app: your browser will offer **Install** / "Add to Home screen" — works offline for reading.

## 🧑‍🎓 If you are a STUDENT
1. Sign up → the school approves you and issues your admission number.
2. See your subjects, timetable, results and report cards; submit assignments; read Digital Library books (with scored comprehension quizzes); take **CBT exams** with your exam code.
3. **QR Check-in** — scan your ID card when you arrive at school.
4. Vote in school elections on the Voting page; your dashboard shows announcements, events and birthdays.

---

## The promise behind this platform
**"Recurring payments should not keep your schools from having online presences."** — HMG Concepts.
Your school paid once. The portal runs on free-tier infrastructure protected by six anti-pause safeguards, every export is cryptographically sealed, backups sync to the school's own Google Drive, and even total database loss is recoverable with one button. The data is, and always will be, yours.
