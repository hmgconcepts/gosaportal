/* Enhanced School Assistant - Comprehensive Page Descriptions */
const SiteHelp = {
  descriptions: {
    'dashboard': '🏠 **Dashboard** — Your central hub. View key metrics: total students, staff, attendance rates, fee collection, upcoming events. Quick actions for common tasks. Real-time notifications.',
    'students': '👨‍🎓 **Students** — Manage all student records. Add new students, edit profiles, view academic history, track attendance. Auto-generates admission numbers starting with school acronym.',
    'staff': '👨‍🏫 **Staff** — Teacher and staff management. Add/edit staff profiles, assign subjects and classes, track leave, manage payroll. Auto-generates staff IDs.',
    'classes': '📚 **Classes** — Define class structure (JSS 1, SS 2, etc.). Assign class teachers, set capacity, manage arms/sections.',
    'subjects': '📖 **Subjects** — Subject management. Define subjects per class, assign teachers, set credit units.',
    'attendance': '📋 **Attendance** — Daily attendance tracking. Mark students present/absent/late. View attendance reports and trends. Supports bulk marking.',
    'results': '📊 **Results / Mark Entry** — **WORKFLOW:** 1) Teachers enter marks in Subject Broadsheet (per subject). 2) Class Broadsheet auto-populates (all subjects × all students). 3) Report Cards auto-generate. Enter marks ONCE — no re-entry needed!',
    'academic-records': '📈 **Academic Records** — View class broadsheets (all students × all subjects) and subject broadsheets (one subject, all students). Auto-calculates totals, averages, positions, grades.',
    'report-cards': '🎓 **Report Cards** — Auto-generated student report cards: all subjects, grades, positions, affective/psychomotor traits, teacher comments, school stamp and signatures. Print one student, or use **🖨️ Bulk Print ALL Report Cards (per class)** — the whole class builds with a progress bar and prints one-per-page in a single job (or Save as PDF).',
    'timetable': '🗓️ **Timetable** — Class and teacher timetables. Conflict detection. Print schedules.',
    'fees': '💰 **School Fees** — Fee structure per class; record payments, track balances, print e-receipts. Privacy built in: students see ONLY their own payments, parents only their children\'s; bursar and staff have full read/write.',
    'payment-history': '🧾 **Payment History** — Student payment records. Print e-receipts with school logo and authorized signature.',
    'cbt': '💻 **CBT Exams** — Computer-Based Testing: 17 question types, anti-cheat (tab/copy/fullscreen watch), auto-grading, multi-subject tabs. NEW: optional **📸 camera snapshots** and **🎙️ audio monitoring** per exam (great for take-home CBT assignments) — review pictures via the 📸 button on each exam row and delete them all with one click after marking.',
    'cbt-exam': '📝 **CBT Exam Taking** — Students take exams here. Timer, question navigation, flag questions, calculator, math keyboard. Multi-subject exams show tabs at top. Auto-submits when time expires.',
    'assignments': '📝 **Assignments** — Post homework/assignments. Track submissions. Grade and provide feedback. Students and parents can view.',
    'eresources': '📚 **E-Resources / Notes** — Upload and share study materials, notes, PDFs. Organized by subject and class. Students and parents can access.',
    'complaints': '📨 **Complaints & Grievance** — Parents/students submit complaints. Track status (open → in progress → resolved). Admin responds and resolves.',
    'announcements': '📢 **Announcements** — School-wide notices. Priority levels (normal/urgent). Pin important announcements. Push notifications.',
    'events': '🎉 **Events** — School calendar and events. RSVP tracking. Venue booking. Reminders.',
    'gallery': '📸 **Gallery** — Photo albums from school events. Upload and organize photos.',
    'library': '📖 **Library** — Book catalog. Lending records. Due date tracking. Barcode scanning support.',
    'voting': '🗳️ **Voting & Polls** — Student elections (prefects, head boy/girl). Anonymous ballots. Live results. Staff polls.',
    'analytics': '📊 **Analytics** — Data visualization. Enrollment trends, performance charts, fee collection graphs, attendance patterns.',
    'settings': '⚙️ **Settings** — School configuration. Logo, colors, academic sessions, fee defaults. **Admission/Staff ID settings** — customize prefix, format, starting number.',
    'profile': '👤 **Profile** — Your personal profile. Update contact info, change password.',
    'admissions': '🚪 **Admissions** — Public application form. Track applications (submitted → reviewing → accepted → enrolled).',
    'alumni': '🎓 **Alumni** — Graduate database. Track career paths. Networking.',
    'inventory': '📦 **Inventory** — Asset tracking. Equipment, supplies. Location and condition.',
    'certificates': '📜 **Certificates** — Generate testimonials, graduation certificates, transfer letters. Branded with school logo.',
    'hostel': '🛏️ **Hostel** — Boarding management. Room allocation. Bed tracking.',
    'hr': '💼 **HR** — Human resources. Staff records, contracts, appraisals.',
    'payroll': '💵 **Payroll** — Salary calculation. Allowances, deductions. Net pay. Payslips.',
    'leave': '🏖️ **Leave** — Staff leave requests. Approval workflow. Balance tracking.',
    'transport': '🚌 **Transport** — School bus routes. Student allocation. Driver info.',
    'health': '🏥 **Health** — Student medical records. Sick bay visits. Health alerts.',
    'storage': '🗄️ **Storage Manager** — Guardian of your free 500 MB database. Shows how much space every table uses, analyses health against your quota, and lists purgeable old rows. Includes the **📦 Archive Vault**: move old rows (logs, old CBT attempts, read notifications) into the separate 1 GB File Storage as sealed, restorable archives — then purge them from the database. Termly 10-minute routine keeps the school on the free tier for years.',
    'admin-data': '🗃️ **Admin Data** — The data-sovereignty centre. ① Full local backup/restore (JSON). ② Portable Archive Center: sealed, re-importable exports of any table. ③ **☁️ Google Drive Backup & Sync**: one-click backup to the school\'s own Drive, one-click restore, scheduled auto-sync, and 🚑 disaster recovery into a brand-new database. ④ Browse & delete any table. Everything is SHA-256 sealed so tampering/corruption is detected on import.',
    'platform-health': '🛡️ **Platform Health Console** — The owner cockpit. One page confirms: keep-alive heartbeat (anti-pause, with a 💓 manual heartbeat button for holidays), database space vs 500 MB, Google Drive backup status, lifetime license, security controls (idle auto-lock, 🚨 emergency lockdown) and the login audit trail. If every tile is green, the school is healthy.',
    'activity_log': '🧮 **Activity Log** — Read-only audit trail: every create, update, delete, import and login is recorded automatically (who, what, when). No manual entries. Owners can EXPORT then PURGE entries older than a chosen period (1 week → 2 years) in the Retention & Purge card so the log never eats the database.',
    'helpdesk': '🛠️ **Help Desk** — Internal ticketing for non-academic issues: IT/computers, network, electrical, plumbing, furniture, equipment, security, cleaning, admin requests. Pick a category, give the ticket a short title, describe the issue, set priority. Admin tracks open → in progress → resolved → closed.',
    'parents': '👪 **Parents** — Dedicated parent registry (name, contact, occupation) plus the parent–child linking engine. Linking a parent to a student is what makes the family portal work: the parent then sees ONLY their own children\'s results, attendance, fees and report cards.',
    'messages': '💬 **Messages / Inbox** — Two-way in-app communication. Staff message parents/students or broadcast to an audience; parents and students can write to the school. Everything is recorded, routed to the notification bell, and tracked unread → read → archived.',
    'approvals': '✅ **Approvals** — The security gate for new accounts. Everyone who signs up starts as *pending* and can see nothing sensitive until an admin approves them here (which also auto-generates their member ID). Reject strangers; approve only people you recognise.',
    'promotion': '🎓 **Promotion** — End-of-session engine. Auto-drafts promote/repeat/graduate decisions from exam averages against your pass benchmark; admin reviews and applies. Graduating students can flow to Alumni.',
    'checkin': '📍 **QR Check-in** — Students scan their ID-card QR (or type their admission number) to record arrival. Supports geofencing so check-ins only count on school premises. Feeds punctuality analytics.',
    'digital_library': '📚 **Digital Library** — Post online books/resources as Google Drive or web LINKS (never uploads — protects your storage). Optional comprehension questions turn reading into a scored activity.',
    'entrance': '🚪 **Entrance & Assessments** — Public exams that candidates sit WITHOUT an account (entrance, placement). Create the exam in CBT, tick entrance, share the code/link. Results appear under the exam register.',
    'transcripts': '📄 **Transcripts** — Multi-term/multi-session academic transcripts per student, compiled from stored results. For leavers, university applications and transfers.',
    'developer': '👨‍💻 **About the Developer** — Adewale Samson Adeagbo, founder of HMG Concepts. The ecosystem promise: “Recurring payments should not keep your schools from having online presences.” One-time payment, lifetime platform, your data always exportable.',
    'leave': '🏖️ **Leave Management** — Staff submit leave requests (sick, casual, earned, study, maternity); every request starts as PENDING. **Only an administrator can approve or reject** — the status box is hidden from staff and the database stamps who decided and when.',
    'idcards': '🪪 **ID Cards** — Branded student/staff cards with photo and scannable QR. Print one card, or type a class in the Class box and click **🖨 Print ALL** to bulk-print that class in one job (empty box = whole school).',
    'substitutions': '🔁 **Substitutions / Cover** — When a teacher is absent, ADMIN assigns the cover teacher here (only admin can create/edit). Staff see the plan read-only so everyone knows who covers which period.',
    'default': "ℹ️ **Help** — I'm the School Assistant. Every page also has: ① this **❓ Page Help** button (what the page does, who uses it, why it matters), ② the **ℹ️ Help** button in the top bar, and ③ the 💬 chat assistant for step-by-step questions. New here? Start at the **Dashboard**, and admins should visit the **🛡️ Platform Health Console** to confirm backups, keep-alive and security are all green."
  },
  
  init() {
    const page = (location.pathname.split('/').pop() || 'dashboard').replace('.html', '');
    this.currentPage = page;
    this.attachHelpButton();
  },
  
  attachHelpButton() {
    const existing = document.getElementById('page-help-btn');
    if (existing) existing.remove();
    
    const btn = document.createElement('button');
    btn.id = 'page-help-btn';
    btn.innerHTML = '❓ Page Help';
    btn.style.cssText = 'position:fixed;bottom:20px;left:20px;z-index:9998;background:linear-gradient(135deg,#3b82f6,#8b5cf6);color:white;border:none;border-radius:50px;padding:12px 20px;font-size:14px;font-weight:700;cursor:pointer;box-shadow:0 4px 15px rgba(59,130,246,0.4)';
    btn.onclick = () => this.showHelp();
    document.body.appendChild(btn);
  },
  
  showHelp() {
    let desc=this.descriptions[this.currentPage];
    if(!desc&&window.Super&&Super.chatbot){try{Super.chatbot.ensurePageInfoCoverage();desc=Super.chatbot.renderPageInfo(this.currentPage);}catch(_){}}
    desc=desc||this.descriptions['default'];
    const modal = document.createElement('div');
    modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:10000;display:flex;align-items:center;justify-content:center;padding:20px';
    modal.innerHTML = '<div style="background:white;border-radius:16px;max-width:600px;width:100%;max-height:80vh;overflow-y:auto;padding:24px;position:relative">' +
      '<button type="button" data-help-close style="position:absolute;top:12px;right:12px;background:none;border:none;font-size:24px;cursor:pointer;color:#64748b" aria-label="Close help">×</button>' +
      '<div style="font-size:1.1rem;line-height:1.7">' + desc.replace(/\n/g, '<br>').replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>') + '</div>' +
      '<div style="margin-top:20px;padding-top:16px;border-top:1px solid #e2e8f0;font-size:.85rem;color:#64748b">Need more help? Contact your school administrator or visit the Feature Guide.</div>' +
      '</div>';
    modal.querySelector('[data-help-close]').addEventListener('click',()=>modal.remove());
    modal.onclick = (e) => { if (e.target === modal) modal.remove(); };
    document.body.appendChild(modal);
  },
  
  explainPage() { this.showHelp(); }
};

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => SiteHelp.init());
} else {
  SiteHelp.init();
}

window.SiteHelp = SiteHelp;
