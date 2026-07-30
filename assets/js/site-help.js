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
    'report-cards': '🎓 **Report Cards** — Auto-generated student report cards. Shows all subjects, grades, positions, affective/psychomotor traits, teacher comments. Printable with school stamp.',
    'timetable': '🗓️ **Timetable** — Class and teacher timetables. Conflict detection. Print schedules.',
    'fees': '💰 **School Fees** — Fee structure per class. Track payments, balances. Generate e-receipts. View fee reports.',
    'payment-history': '🧾 **Payment History** — Student payment records. Print e-receipts with school logo and authorized signature.',
    'cbt': '💻 **CBT Exams** — Computer-Based Testing. Create exams with 17 question types (MCQ, true/false, fill-blank, essay, numeric, etc.). Anti-cheat features. Auto-grading. Multi-subject support with tabs.',
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
    'default': "ℹ️ **Help** — This is the School Assistant. Ask me about any page or feature. I'll explain what it does and how to use it."
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
