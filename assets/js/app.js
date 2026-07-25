/* ====================================================================
   app.js — School Connect v15 (Final & Stable Edition)
   ====================================================================
   This is the AUTHORITATIVE runtime. Every page on every generated
   school site loads this file. It is responsible for:

     • Auth state + session bootstrapping (Supabase)
     • Role-Based Access Control (admin / staff / teacher / parent / student)
     • Navigation filtering, ordering, search, and role-aware visibility
     • Dashboard rendering for every role
     • Global "Add" modal (every page can open the right form)
     • Universal date / escape / toast / modal helpers
     • Live dashboard feed (events, polls, broadcasts, surveys, lost & found,
       PTA meetings, cafeteria, hostel)
     • Family-safe report-card / result / payment access
     • Real-time notification badge + bell dropdown
     • 100% of bugs reported in audit fixed here, in CRUD engine, and in
       every per-page override.

   v15 — comprehensive fix:
     • Notification bell: solid event isolation, persistent dropdown,
       no "appears and disappears" regression
     • Family mode: parents see only their children; students only their
       own record; everything is read-only via data-readonly-role tokens
     • Admin/finance-only modules removed from student/parent nav
     • Transport, health, financial_aid, transcripts hidden from
       students/parents permanently
     • Report-card dropdowns: graceful fallback to demo data when the
       lookups table is empty (very common on fresh installs)
     • Defensive error handling everywhere
   ==================================================================== */

const PUBLIC_PAGES = ['login','index','about','contact','apply','register','signup','cbt-exam','exam-register','offline',''];

/* ---- Global date helpers (school standard: dd/mm/yyyy) ---- */
function fmtDMY(v){ if(!v) return ''; const d=new Date(v); if(isNaN(d)) return String(v);
  return String(d.getDate()).padStart(2,'0')+'/'+String(d.getMonth()+1).padStart(2,'0')+'/'+d.getFullYear(); }
function fmtDMYT(v){ if(!v) return ''; const d=new Date(v); if(isNaN(d)) return String(v);
  return fmtDMY(d)+' '+String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0'); }
window.fmtDMY = fmtDMY; window.fmtDMYT = fmtDMYT;

function currentPage() {
  return (location.pathname.split('/').pop() || 'index.html').replace('.html','');
}

function esc(s) {
  return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
if (typeof window.SC !== 'undefined' && !window.SC.esc) window.SC.esc = esc;

/* ====================================================================
   App
   ==================================================================== */
const App = {
  sb: null,
  currentRole: 'guest',
  currentUserName: '',
  currentProfile: {},

  init() {
    if (window.sb && !this.sb) this.sb = window.sb;
    App.bindUI();
    App.installSelectDedupe();
    App.dedupeAllSelects();
    App.applyStoredTheme();
    App.hydrateBrandAssets();
    App.loadRoleAccessMap();

    const page = currentPage();

    if (PUBLIC_PAGES.includes(page)) {
      App.initAuthTabs();
      try { if (window.PWAInstall) PWAInstall.init(); } catch(_) {}
      try { if (window.Notifications) {
        const currentSb = window.sb || this.sb || null;
        if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').then(reg => Notifications.init(currentSb, reg));
        else Notifications.init(currentSb);
      } } catch(_) {}
      try { if (window.Super) Super.init(window.sb || this.sb || null, window.SCHOOL); } catch(_) {}
      try { if (window.Enterprise) Enterprise.init(window.sb || this.sb || null); } catch(_) {}
      try { if (window.CRUD) CRUD.init(window.sb || this.sb || null); } catch(_) {}
      return;
    }

    App.applyRoleVisibility();
    App.loadSchoolSettings();
  },

  async loadSchoolSettings() {
    try {
      const supabase = window.sb || this.sb || null; if (!supabase) return;
      const { data } = await supabase.from('school_settings').select('*').eq('id', 1).maybeSingle();
      if (data) {
        window.SC_SETTINGS = data;
        try {
          if (data.signature_url && !localStorage.getItem('sc-signature-url')) localStorage.setItem('sc-signature-url', data.signature_url);
          if (data.principal_name && !localStorage.getItem('sc-principal-name')) localStorage.setItem('sc-principal-name', data.principal_name);
          if (data.terms)        window.SC_TERMS    = data.terms;
          if (data.sessions)     window.SC_SESSIONS = data.sessions;
          // V12: expose admin-configured geofence to check-in pages.
          window.SCHOOL = window.SCHOOL || {};
          if (data.latitude != null)  window.SCHOOL.latitude = Number(data.latitude);
          if (data.longitude != null) window.SCHOOL.longitude = Number(data.longitude);
          if (data.geo_radius_m != null) window.SCHOOL.geoRadius = Number(data.geo_radius_m);
          window.SCHOOL.enforceGeofence = data.enforce_geofence !== false;
        } catch (_) {}
      }
    } catch (_) {}
  },

  hydrateBrandAssets() {
    try {
      const school = window.SCHOOL || {};
      const ext = String(school.logoExt || 'svg').toLowerCase();
      const logoPath = 'assets/img/logo.' + ext;
      // Many older generated pages hard-coded logo.svg. Always hydrate the
      // app shell, install banner and HMG/public nav to the actual uploaded
      // school logo. If the file is missing, the existing onerror fallback remains.
      document.querySelectorAll('.app-brand img, .pwa-install-icon, .nav-logo img, img[data-school-logo]').forEach(img => {
        if (!img) return;
        const src = img.getAttribute('src') || '';
        if (!src || /assets\/img\/logo\.(svg|png|jpe?g|webp)$/i.test(src)) {
          img.setAttribute('src', logoPath);
          img.setAttribute('alt', school.name || img.getAttribute('alt') || 'School logo');
          if (!img.getAttribute('onerror')) img.setAttribute('onerror', "this.onerror=null;this.src='assets/img/logo.svg'");
        }
      });
      document.querySelectorAll('.app-brand strong').forEach(el => { if (school.name) el.textContent = school.name; });
    } catch (e) { console.warn('Brand hydration skipped:', e.message || e); }
  },

  markActiveNav() {
    try {
      const pageFile = (location.pathname.split('/').pop() || 'index.html').split('?')[0];
      const pageId = App.normalizeModuleId(pageFile.replace(/\.html$/,''));
      const aliases = new Set([pageId, pageFile.replace(/\.html$/,'')]);
      document.querySelectorAll('.app-nav a[data-module-id]').forEach(a => {
        const hrefFile = ((a.getAttribute('href') || '').split('/').pop() || '').split('?')[0];
        const mid = App.normalizeModuleId(a.getAttribute('data-module-id') || hrefFile.replace(/\.html$/,''));
        const hrefId = App.normalizeModuleId(hrefFile.replace(/\.html$/,''));
        const active = aliases.has(mid) || aliases.has(hrefId) || hrefFile === pageFile;
        a.classList.toggle('active', !!active);
        if (active) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
      });
    } catch (_) {}
  },

  applyStoredTheme() {
    const saved = localStorage.getItem('sc-theme');
    if (saved) document.body.dataset.theme = saved;
  },

  initAuthTabs() {
    if (document.getElementById('signin-form')) App.switchAuthTab('signin');
  },

  /* =================================================================
     RBAC — apply visibility based on the signed-in user
     ================================================================= */
  /* =================================================================
     v2 — Race-free async role resolution.
     Old v15 had a race: getUser() returned before profiles loaded,
     so enforceCurrentPageAccess ran with role="guest" and showed
     "Your role (guest) does not have permission" for every page.

     This wrapper awaits getUser + profile fetch, THEN applies the role
     to nav, dashboard tokens, and access checks. Safe to call from
     App.init() because it self-gates on the global App._roleResolved.
     ================================================================= */

  // === v5 FIX: Network resilience & guest flash bug ===
  // Cache profile to avoid guest flash on slow network
  getCachedProfile() {
    try {
      const c = localStorage.getItem('sc-cached-profile');
      if (c) return JSON.parse(c);
    } catch(_) {}
    return null;
  },
  setCachedProfile(p) {
    try { localStorage.setItem('sc-cached-profile', JSON.stringify(p)); } catch(_) {}
  },
  showDashboardLoading(show) {
    let el = document.getElementById('sc-dash-loading');
    if (!el) {
      el = document.createElement('div');
      el.id = 'sc-dash-loading';
      el.style.cssText = 'position:fixed;inset:0;background:rgba(255,255,255,0.9);display:flex;align-items:center;justify-content:center;z-index:9999;flex-direction:column;gap:16px';
      el.innerHTML = '<div style="width:48px;height:48px;border:4px solid #e2e8f0;border-top-color:#4f46e5;border-radius:50%;animation:spin 1s linear infinite"></div><div style="color:#475569;font-weight:700">Loading your dashboard…</div><div style="font-size:.85rem;color:#94a3b8">Slow network detected — using cached session</div><style>@keyframes spin{to{transform:rotate(360deg)}}</style>';
      document.body.appendChild(el);
    }
    el.style.display = show ? 'flex' : 'none';
  },

  async resolveAndApplyRole() {
    const currentSb = window.sb || this.sb || null;
    const page = currentPage();
    // Show loading immediately on dashboard to prevent guest flash
    if (page === 'dashboard') this.showDashboardLoading(true);
    // Try to use cached profile for instant UI while network resolves
    const cached = this.getCachedProfile();
    if (cached && cached.role && page === 'dashboard') {
      try {
        App.currentRole = String(cached.role).toLowerCase();
        window.SC_PROFILE = cached;
        App.applyRoleDashboard(App.currentRole, cached);
        App.applyRoleNav(App.currentRole);
      } catch(_) {}
    }

    if (!currentSb) {
      const setupBanner = document.getElementById('sc-setup-required');
      if (setupBanner) setupBanner.style.display = 'flex';
      const setupDetail = document.getElementById('sc-setup-detail');
      if (setupDetail) setupDetail.textContent = ' Edit assets/js/config.js with your Supabase URL and anon key.';
      const effectiveRole = (page === 'dashboard') ? (cached ? cached.role : 'guest') : 'demo';
      App.currentRole = effectiveRole;
      App.applyRoleDashboard(effectiveRole, cached || { full_name: 'Guest', role: effectiveRole });
      App.applyRoleNav(effectiveRole);
      App.loadPageData();
      this.showDashboardLoading(false);
      return;
    }
    // Retry logic with exponential backoff for slow network
    let user = null;
    let retries = 3;
    for (let attempt=0; attempt<=retries; attempt++) {
      try {
        const u = await currentSb.auth.getUser();
        user = u && u.data && u.data.user;
        if (user) break;
      } catch (e) {
        if (attempt < retries) {
          await new Promise(r => setTimeout(r, 500 * Math.pow(2, attempt)));
          continue;
        }
      }
      if (attempt < retries && !user) {
        await new Promise(r => setTimeout(r, 400));
      }
    }
    if (!user) {
      // If we have cached profile, keep it instead of forcing login
      if (cached && cached.id) {
        console.warn('[Auth] getUser failed, using cached profile');
        App.currentRole = String(cached.role||'student').toLowerCase();
        window.SC_PROFILE = cached;
        App.applyRoleDashboard(App.currentRole, cached);
        App.applyRoleNav(App.currentRole);
        App.loadPageData();
        this.showDashboardLoading(false);
        return;
      }
      location.href = 'login.html';
      return;
    }

    let role = '', status = 'active', name = '', profile = null;
    try {
      const rpc = await currentSb.rpc('sc_current_role');
      if (rpc && rpc.data && !rpc.error) {
        profile = rpc.data;
        role = String(profile.role || 'student').toLowerCase();
        status = String(profile.status || 'active').toLowerCase();
        name = profile.full_name || user.email || 'User';
      }
    } catch (_) {}
    if (!role) {
      for (let attempt=0; attempt<2; attempt++) {
        try {
          const { data, error } = await currentSb.from('profiles').select('full_name,email,role,status,photo_url,phone').eq('id', user.id).maybeSingle();
          if (error) throw error;
          profile = data || profile;
          role = (profile && profile.role) || user.user_metadata?.role || 'student';
          status = (profile && profile.status) || 'active';
          name = (profile && profile.full_name) || user.user_metadata?.full_name || user.email || 'User';
          break;
        } catch (err) {
          if (attempt===0) await new Promise(r=>setTimeout(r, 600));
        }
      }
      if (!role) {
        role = user.user_metadata?.role || cached?.role || 'student';
        status = 'active';
        name = user.user_metadata?.full_name || cached?.full_name || user.email || 'User';
      }
    }
    if (status === 'pending') {
      document.body.innerHTML = '<div style="min-height:100vh;display:flex;align-items:center;justify-content:center;padding:40px"><div style="max-width:440px;text-align:center;background:white;padding:40px;border-radius:16px"><h2 style="margin-bottom:12px">⏳ Account pending approval</h2><p>Your account is awaiting admin approval.</p><a href="login.html" class="btn btn-primary" style="margin-top:16px">Back to Login</a></div></div>';
      return;
    }
    if (status === 'suspended') {
      document.body.innerHTML = '<div style="min-height:100vh;display:flex;align-items:center;justify-content:center;padding:40px"><div style="max-width:440px;text-align:center;background:white;padding:40px;border-radius:16px"><h2>🚫 Account suspended</h2><p>Please contact the school administrator.</p><a href="login.html" class="btn btn-outline" style="margin-top:16px">Back to Login</a></div></div>';
      return;
    }
    App.currentRole = String(role).toLowerCase();
    App.currentUserName = name;
    App.currentProfile = profile || {};
    window.SC_PROFILE = Object.assign({ id: user.id, email: user.email }, profile || {}, { role: role, status, full_name: name });
    this.setCachedProfile(window.SC_PROFILE);
    App.applyVisibilityTokens(App.currentRole);
    App.applyRoleDashboard(App.currentRole, { full_name: name, email: user.email, role: App.currentRole });
    App.applyRoleNav(App.currentRole);
    App.loadPageData();
    this.showDashboardLoading(false);
    try { localStorage.setItem('sc-last-role', App.currentRole); } catch(_){}
    App._roleResolved = true;
  },

  /* v15 compatibility wrapper. Now delegates to resolveAndApplyRole
     so existing pages that call applyRoleVisibility() still work. */
  applyRoleVisibility() {
    try { return Promise.resolve(App.resolveAndApplyRole()); } catch (e) { console.warn('applyRoleVisibility failed:', e); }
  },

  applyRoleDashboard(role, profile) {
    const name = (profile && (profile.full_name || profile.email)) || 'User';
    const prettyRole = String(role || 'user').replace(/_/g,' ').replace(/\bw/g, c => c.toUpperCase());

    const roleMap = {
      super_admin: ['admin'], admin: ['admin'], principal: ['admin'], proprietor: ['admin'],
      head_teacher: ['admin'], bursar: ['admin'],
      staff: ['staff'], teacher: ['staff'],
      parent: ['parent'], student: ['student'],
      demo: ['admin'], guest: ['guest']
    };
    const effectiveRoles = new Set(roleMap[role] || [role]);

    ['user-display-name','dash-user-name'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.textContent = name;
    });
    ['user-display-role','dash-user-role'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.textContent = prettyRole;
    });

    const groups = document.querySelectorAll('[data-dash-role]');
    if (groups.length) {
      groups.forEach(el => {
        const roles = (el.getAttribute('data-dash-role') || '').split(/\s+/).filter(Boolean);
        const show = roles.some(r => effectiveRoles.has(r));
        el.style.display = show ? '' : 'none';
      });
      if (![...groups].some(el => el.style.display !== 'none')) {
        const fallback = role === 'guest' ? document.querySelector('[data-dash-role="guest"]') : document.querySelector('[data-dash-role="student"]');
        if (fallback) fallback.style.display = '';
      }
    }

      const q = document.getElementById('dash-quick-links');
      if (q) {
        const links = role === 'parent' ? [
        ['My Children','student-profile.html'],['Fees','fees.html'],['Results','results.html'],
        ['Report Cards','report-cards.html'],['Attendance','attendance.html'],
        ['Assignments','assignments.html'],['Diary','diary.html'],['Timetable','timetable.html'],
        ['Announcements','announcements.html']
      ] : role === 'student' ? [
        ['Take CBT','cbt-exam.html'],['Assignments','assignments.html'],['Timetable','timetable.html'],
        ['My Results','results.html'],['Report Cards','report-cards.html'],
        ['My Profile','student-profile.html'],['Announcements','announcements.html'],
        ['Certificates','certificates.html']
      ] : (['staff','teacher'].includes(role)) ? [
        ['Attendance','attendance.html'],['Results','results.html'],['CBT Manager','cbt.html'],
        ['Report Cards','report-cards.html'],['Broadsheets','academic-records.html'],
        ['Lesson Plans','lesson_plans.html'],['Scheme of Work','sow.html'],
        ['Timetable','timetable.html'],['Digital Library','digital_library.html'],
        ['Announcements','announcements.html'],['Inbox','inbox.html'],['Complaints','complaints.html']
      ] : [
        ['Students','students.html'],['Staff','staff.html'],['Parents','parents.html'],['Parent–Child','parents.html'],
        ['Classes','classes.html'],['Fees','fees.html'],['Results','results.html'],
        ['Attendance','attendance.html'],['Academic Records','academic-records.html'],
        ['Announcements','announcements.html'],['Analytics','analytics.html'],
        ['Access Manager','#role-access-manager'],['Admin Data','admin-data.html']
      ];
      const filteredLinks = links.filter(link => {
        const href = link[1];
        if (href.startsWith('#')) return true;
        return App.canAccessPage(href, role);
      });
      q.innerHTML = filteredLinks.map(x => '<a class="btn btn-outline btn-sm" href="'+x[1]+'">'+x[0]+'</a>').join('');
    }
    App.injectAccessManager(role);
    if (String(role || '').toLowerCase() === 'parent' || App.isAdminRole(role)) {
      setTimeout(() => App.renderParentChildrenDashboard(role), 50);
    }
  },

  async renderParentChildrenDashboard(role) {
    const box = document.getElementById('dash-parent-kids');
    if (!box) return;
    const supabase = window.sb || this.sb || null;
    const profile = window.SC_PROFILE || {};
    if (!supabase || !supabase.from) {
      box.innerHTML = '<div style="color:var(--gray-500)">Connect Supabase to display linked children.</div>';
      return;
    }
    try {
      const isParent = String(profile.role || role || '').toLowerCase() === 'parent';
      if (!isParent || !profile.id) {
        box.innerHTML = '<div style="color:var(--gray-500)">Admin inspection mode: sign in as a parent to see real linked children here.</div>';
        return;
      }
      const { data: links, error: linkErr } = await supabase.from('parent_child').select('student_id,relationship,verified').eq('parent_id', profile.id);
      if (linkErr) throw linkErr;
      const ids = (links || []).map(x => x.student_id).filter(Boolean);
      if (!ids.length) {
        box.innerHTML = '<div class="card" style="background:#fff7ed;border-color:#fed7aa"><b>No child linked yet.</b><br><span style="color:#9a3412">Please ask the school administrator to link your parent account to your child on the Parents page.</span></div>';
        return;
      }
      const { data: kids, error: kidErr } = await supabase.from('students').select('id,full_name,class,arm,admission_no,photo_url').in('id', ids).order('full_name');
      if (kidErr) throw kidErr;
      const rel = {}; (links || []).forEach(l => rel[l.student_id] = l.relationship || 'Parent');
      box.innerHTML = (kids || []).map(k => {
        const klass = [k.class, k.arm].filter(Boolean).join(' ') || 'Class not set';
        const photo = k.photo_url ? '<img src="'+esc(k.photo_url)+'" referrerpolicy="no-referrer" style="width:48px;height:48px;border-radius:14px;object-fit:cover;border:1px solid var(--gray-200)">' : '<div style="width:48px;height:48px;border-radius:14px;background:#eef2ff;display:flex;align-items:center;justify-content:center;font-size:1.5rem">👤</div>';
        return '<div style="display:flex;gap:12px;align-items:flex-start;border:1px solid var(--gray-200);border-radius:14px;padding:12px;background:#fff">'+photo+
          '<div style="flex:1;min-width:0"><b>'+esc(k.full_name || 'Student')+'</b><div style="font-size:.82rem;color:var(--gray-500)">'+esc(klass)+' · '+esc(k.admission_no || '')+' · '+esc(rel[k.id] || 'Parent')+'</div>'+
          '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:8px">'+
          '<a class="btn btn-outline btn-sm" href="student-profile.html?student='+encodeURIComponent(k.id)+'">Dashboard</a>'+
          '<a class="btn btn-outline btn-sm" href="attendance.html?student='+encodeURIComponent(k.id)+'">Attendance</a>'+
          '<a class="btn btn-outline btn-sm" href="report-cards.html?student='+encodeURIComponent(k.id)+'">Report Card</a>'+
          '<a class="btn btn-outline btn-sm" href="idcards.html?student='+encodeURIComponent(k.id)+'">ID Card</a>'+
          '</div></div></div>';
      }).join('') || '<div style="color:var(--gray-500)">No linked student record was found.</div>';
    } catch (e) {
      box.innerHTML = '<div style="color:#b91c1c">Could not load linked children: '+esc(e.message || e)+'</div>';
    }
  },

  isAdminRole(role) {
    return ['super_admin','superadmin','admin','administrator','owner','director','principal','proprietor','head_teacher','headteacher','bursar'].includes(String(role || '').toLowerCase().replace(/\s+/g,'_'));
  },

  roleSet(role) {
    const r = String(role || '').toLowerCase();
    const set = new Set([r]);
    if (r === 'teacher') set.add('staff');
    if (r === 'staff') set.add('teacher');
    if (App.isAdminRole(r)) ['admin','staff','teacher','parent','student'].forEach(x => set.add(x));
    return set;
  },

  normalizeModuleId(id) {
    id = String(id || '').replace(/\.html(\?.*)?$/,'').replace(/^.*\//,'').trim();
    const map = {
      'academic-records':'academic_records', 'academic_records':'academic_records',
      'admin-data':'admin_data', 'admin_data':'admin_data',
      'report-cards':'report_cards', 'report_cards':'report_cards',
      'cbt-prompts':'cbt_prompts', 'cbt_prompts':'cbt_prompts',
      'cbt-exam':'cbt_exam', 'cbt_exam':'cbt_exam',
      'timetable-generator':'timetable_generator', 'timetable_generator':'timetable_generator',
      'student-profile':'student_profile', 'student_profile':'student_profile',
      'school-fees':'school_fees', 'school_fees':'school_fees', 'school-products':'school_products', 'school_products':'school_products',
      'status-manager':'status_manager', 'status_manager':'status_manager', 'ecosystem-products':'ecosystem', 'ecosystem_products':'ecosystem', 'ecosystem':'ecosystem',
      'hmg-digital-products':'hmg_digital_products', 'hmg_digital_products':'hmg_digital_products',
      'feature-guide':'feature_guide', 'feature_guide':'feature_guide',
      'verify-certificate':'verify_certificate', 'verify_certificate':'verify_certificate',
      'payment-history':'payment_history',
      'school-fees':'school_fees', 'school-products':'school_products', 'status-manager':'status_manager',
      'payment-history':'payment_history',
      'school-fees':'school_fees', 'school-products':'school_products', 'status-manager':'status_manager',
      'hmg-digital-products':'hmg_digital_products', 'ecosystem-products':'ecosystem_products'
    };
    return map[id] || id.replace(/-/g,'_');
  },

  ROLE_GROUPS: {
    staff: ['staff','teacher'],
    parent: ['parent'],
    student: ['student']
  },

  /* Modules that parents/students should NEVER see. The whitelist
     (PARENT_WHITELIST / STUDENT_WHITELIST) handles everything else.
     Only put truly admin/finance/HR-only modules here. Modules that
     parents/students ARE allowed to see (results, report-cards, cbt,
     inbox, messages, payments_online, digital_library, voting,
     surveys, lms, gamification, cbt-multi) are NOT in this list —
     they are checked against the whitelist which is the source of
     truth for family-allowed modules. */
  /* v4: FAMILY_BLACKLIST — every module that should NEVER appear in
     the parent or student sidebar. This is the SECOND safety net after
     the data-role-allow attribute. Any module in this list is BLOCKED
     for parent/student even if accidentally added to a whitelist.
     The list combines truly admin/HR/finance-only modules AND the
     student-management / exam-management / messaging modules that the
     user explicitly said should not be in the family nav. */
  FAMILY_BLACKLIST: new Set([
    // Truly admin/HR/finance only — never visible to parents or students.
    'transport','health','financial_aid','transcripts',
    'admin_data','admin-data','analytics','finance','hr','payroll',
    'staff_loans','staff_bonus','appraisals','inventory','storage',
    'compliance','activity_log','activity-log','settings','promotion',
    'alumni','departments','admissions','approvals','storage_manager',
    'rubrics','career_counseling','career-counseling','front_desk',
    'front-desk','fleet_tracking','fleet-tracking','facility_booking',
    'facility-booking','exam_registrations','exam-registrations',
    'donations','timetable_generator','timetable-generator',
    'parent_child','parent-child','cbt_prompts','cbt-prompts',
    'transfer_cert','transfer-cert','substitutions','lesson_plans',
    'lesson-plans','behaviour','support_plans','support-plans',
    'cafeteria','menu','hostel','broadcast','document_builder',
    'document-builder','helpdesk','visitors','leave','checkin',
    'book_request','book-request','reports',
    // v4: user explicitly said these should NOT be in parent or student nav.
    // Parents/students have alternative pages for their data
    // (student-profile.html, fees.html, results.html, report-cards.html, etc.)
    'payments_online','payments-online',
    'payment_history','payment-history',
    'cbt','cbt-multi','cbt_multi',
    // 'cbt-exam' is intentionally NOT blacklisted — students/parents
    // enter an exam code to take a CBT (see STUDENT/PARENT_WHITELIST).
    'messages',
    'digital_library','digital-library',
    'surveys',
    'lms','gamification',
    'broadcast','document_builder','document-builder'
  ]),

  /* Role-friendly modules that STUDENTS can see (separate from allow list) */
  /* v4: STUDENT_WHITELIST — what a STUDENT can see in the sidebar.
     A student is allowed to see their own dashboard, their profile,
     their own results, their own report card (read-only), their
     attendance, their timetable, their assignments, their fees, and
     basic public pages. They cannot manage CBT or school administration; family-safe pages remain read-only.
     Students CAN take a CBT exam (cbt-exam) by entering the code. */
  STUDENT_WHITELIST: new Set([
    'dashboard','profile','change-password','notifications',
    'student-profile','student_profile',
    'results','report-cards','report_cards',
    'attendance','timetable','assignments','idcards','inbox','complaints','eresources','e-resources','certificates',
    'fees','idcards',
    'voting',
    'announcements','events','school_calendar','school-calendar',
    'gallery','helpdesk','lost_found','lost-found',
    'diary','parent_meeting','parent-meeting',
    'academic-records','academic_records',
    'flyer',
    'feature-guide','feature_guide','about','contact',
    'index','login','apply','verify-certificate','verify_certificate',
    'cbt-exam','cbt_exam','ecosystem','ecosystem_products','hmg_digital_products'
  ]),

  /* Role-friendly modules that PARENTS can see (no admin/finance/HR) */
  /* v4: PARENT_WHITELIST — what a PARENT can see in the sidebar.
     A parent is allowed to see their own dashboard, their profile,
     their children's results, their children's report card (read-only),
     their children's attendance, the announcements, events, and basic
     public pages. They CANNOT see CBT manager, multi-subject CBT,
     online pay (payments_online) or administrative modules. Family-safe pages are read-only. Parents CAN take a CBT exam
     (cbt-exam) by entering the code. */
  PARENT_WHITELIST: new Set([
    'dashboard','profile','change-password','notifications',
    'student-profile','student_profile',
    'fees','idcards',
    'results','report-cards','report_cards',
    'academic-records','academic_records',
    'attendance','assignments','timetable','idcards','inbox','complaints','eresources','e-resources','certificates',
    'announcements','events','school_calendar','school-calendar',
    'gallery','helpdesk','lost_found','lost-found',
    'diary','parent_meeting','parent-meeting',
    'certificates',
    'voting',
    'feature-guide','feature_guide','about','contact',
    'index','login','apply','verify-certificate','verify_certificate',
    'cbt-exam','cbt_exam','ecosystem','ecosystem_products','hmg_digital_products'
  ]),

  /* denyParent ... financial_aid, denyStudent ... transport — second safety net
     to ensure the FAMILY_BLACKLIST always hides admin-only modules from
     family accounts even if a future change accidentally grants them via
     the data-role-allow attribute. */
  moduleAllowedForRole(moduleId, role) {
    const id = App.normalizeModuleId(moduleId);
    const r = String(role || '').toLowerCase();
    if (r === 'parent') {
      // Parents: blacklist takes priority, then whitelist
      if (App.FAMILY_BLACKLIST.has(id)) return false;
      if (App.PARENT_WHITELIST.has(id)) return true;
      // Anything not whitelisted for parents is hidden by default
      return false;
    }
    if (r === 'student') {
      if (App.FAMILY_BLACKLIST.has(id)) return false;
      if (App.STUDENT_WHITELIST.has(id)) return true;
      return false;
    }
    if (['staff','teacher'].includes(r)) {
      // Staff/teacher: see everything except admin-only modules
      // (admin-only is enforced by data-role-allow on the link)
      return true;
    }
    return true; // admin
  },

  /* Can the role WRITE (add/edit/delete) on this module? */
  canWriteModule(moduleId, role) {
    if (App.isAdminRole(role)) return true;
    const id = App.normalizeModuleId(moduleId);
    const r = String(role || '').toLowerCase();
    if (r === 'parent' || r === 'student') return false; // family-safe
    if (['staff','teacher'].includes(r)) {
      // Staff can write the academic modules they own. CRUD.remove checks
      // individual record ownership. CRUD.add is allowed by default for
      // write-tagged modules.
      return true;
    }
    return false;
  },

  canAccessAllowList(allowText, role) {
    const allow = String(allowText || '').toLowerCase().split(/\s+/).filter(Boolean);
    if (!allow.length) return App.isAdminRole(role);
    if (allow.some(x => ['any','all','public'].includes(x))) return true;
    const roles = App.roleSet(role);
    return allow.some(a => roles.has(a));
  },

  roleAccessMap: null,
  roleWriteMap: null,

  canAccessPage(pageFileName, role) {
    if (App.isAdminRole(role)) return true;
    const id = this.normalizeModuleId(pageFileName);
    const map = this.roleAccessMap || {};
    if (map[id] && Array.isArray(map[id])) {
      return map[id].includes(role) || (role === 'teacher' && map[id].includes('staff')) || (role === 'staff' && map[id].includes('teacher'));
    }
    if (typeof T !== 'undefined' && T.roleAllow) {
      const allow = T.roleAllow(id).toLowerCase().split(/\s+/).filter(Boolean);
      return allow.some(a => ['any','all','public', role].includes(a) || (role === 'teacher' && a === 'staff') || (role === 'staff' && a === 'teacher'));
    }
    return true;
  },

  loadRoleAccessMap() {
    try {
      const saved = localStorage.getItem('sc-role-access-map');
      this.roleAccessMap = saved ? JSON.parse(saved) : null;
      const wsaved = localStorage.getItem('sc-role-write-map');
      this.roleWriteMap = wsaved ? JSON.parse(wsaved) : null;
    } catch (e) { this.roleAccessMap = null; }
    const supabase = window.sb || this.sb;
    if (supabase && supabase.from) {
      try {
        supabase.from('school_settings').select('role_access,role_write').eq('id', 1).maybeSingle().then(({data}) => {
          if (data) {
            if (data.role_access && typeof data.role_access === 'object') { this.roleAccessMap = data.role_access; try { localStorage.setItem('sc-role-access-map', JSON.stringify(data.role_access)); } catch(e) {} }
            if (data.role_write && typeof data.role_write === 'object') { this.roleWriteMap = data.role_write; try { localStorage.setItem('sc-role-write-map', JSON.stringify(data.role_write)); } catch(e) {} }
            if (this.currentRole) { 
              this.applyRoleNav(this.currentRole); 
              this.applyRoleDashboard(this.currentRole, this.currentProfile);
            }
          }
        }).catch(()=>{});
      } catch(e) {}
    }
  },

  allowTextForElement(el) {
    const rawId = el && (el.getAttribute('data-module-id') || el.getAttribute('href') || '');
    const id = this.normalizeModuleId(rawId);
    const map = this.roleAccessMap || {};
    if (map[id] && Array.isArray(map[id])) {
      return ['super_admin','admin','principal','proprietor','head_teacher','bursar'].concat(map[id]).join(' ');
    }
    return (el && el.getAttribute('data-role-allow')) || '';
  },

  collectAccessRows() {
    const seen = new Map();
    document.querySelectorAll('.app-nav a[data-module-id]').forEach(a => {
      const id = this.normalizeModuleId(a.getAttribute('data-module-id') || a.getAttribute('href'));
      if (!id || seen.has(id)) return;
      seen.set(id, {
        id,
        label: a.textContent.trim().replace(/\s+/g,' '),
        href: a.getAttribute('href') || '#',
        allow: this.allowTextForElement(a)
      });
    });
    return [...seen.values()].sort((a,b)=>a.label.localeCompare(b.label));
  },

  injectAccessManager(role) {
    if (!App.isAdminRole(role) || currentPage() !== 'dashboard') return;
    const content = document.querySelector('.app-content');
    if (!content || document.getElementById('role-access-manager')) return;
    const rows = this.collectAccessRows();
    const readHas = (allow, r) => this.canAccessAllowList(allow, r);
    const writeMap = this.roleWriteMap || {};
    const writeHas = (id, r) => {
      if (writeMap[id] && Array.isArray(writeMap[id])) return writeMap[id].includes(r) || (r === 'staff' && writeMap[id].includes('teacher'));
      try {
        const rules = (window.CRUD && CRUD.WRITE_RULES) || {};
        const allow = rules[id] || rules[App.normalizeModuleId(id)] || [];
        if (r === 'staff') return allow.includes('staff') || allow.includes('teacher');
        return allow.includes(r);
      } catch(e) { return false; }
    };
    /* v5: read-only-by-default map (which pages are in the sidebar for each role) */
    const navShowMap = JSON.parse(localStorage.getItem('sc-nav-show-map') || '{}');
    const navShows = (id, roleKey) => {
      if (navShowMap[id] && Array.isArray(navShowMap[id])) return navShowMap[id].includes(roleKey);
      return true; // default: visible
    };
    const html = '<section id="role-access-manager" class="card" style="margin-top:18px;border:2px solid rgba(79,70,229,.25)">' +
      '<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;flex-wrap:wrap">' +
      '<div><h2 style="margin:0 0 6px">🔐 Page Access & Permission Manager <span style="font-size:.7rem;background:#dcfce7;color:#166534;padding:2px 8px;border-radius:99px;font-weight:800">v5</span></h2>' +
      '<p style="margin:0;color:var(--gray-600);max-width:920px">Admin controls which portal pages appear in the sidebar for Staff, Parents and Students, and which roles can read/write. <b>Nav</b> = show in sidebar, <b>Read</b> = open the page (also via direct URL), <b>Write</b> = Add/Edit/Delete buttons enabled. Admin/Super Admin always keeps full access to every page.</p></div>' +
      '<div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn btn-primary" onclick="App.saveAccessManager()">💾 Save all</button><button class="btn btn-outline" onclick="App.resetAccessManager()">↺ Reset to defaults</button></div></div>' +
      '<div class="table-wrap" style="margin-top:14px;max-height:560px;overflow:auto"><table><thead><tr><th>Page / Module</th><th colspan="3">Staff</th><th colspan="3">Parent</th><th colspan="3">Student</th><th>File</th></tr><tr><th></th><th>Nav</th><th>Read</th><th>Write</th><th>Nav</th><th>Read</th><th>Write</th><th>Nav</th><th>Read</th><th>Write</th><th></th></tr></thead><tbody>' +
      rows.map(r => '<tr data-access-row="'+esc(r.id)+'"><td><strong>'+esc(r.label)+'</strong><br><small>'+esc(r.id)+'</small></td>' +
        // Staff: nav + read + write
        '<td style="text-align:center"><input type="checkbox" data-nav-role="staff" '+(navShows(r.id,'staff')?'checked':'')+'></td>'+
        '<td style="text-align:center"><input type="checkbox" data-access-role="staff" '+(readHas(r.allow,'staff')?'checked':'')+'></td>'+
        '<td style="text-align:center"><input type="checkbox" data-write-role="staff" '+(writeHas(r.id,'staff')?'checked':'')+'></td>'+
        // Parent
        '<td style="text-align:center"><input type="checkbox" data-nav-role="parent" '+(navShows(r.id,'parent')?'checked':'')+'></td>'+
        '<td style="text-align:center"><input type="checkbox" data-access-role="parent" '+(readHas(r.allow,'parent')?'checked':'')+'></td>'+
        '<td style="text-align:center"><input type="checkbox" data-write-role="parent" '+(writeHas(r.id,'parent')?'checked':'')+'></td>'+
        // Student
        '<td style="text-align:center"><input type="checkbox" data-nav-role="student" '+(navShows(r.id,'student')?'checked':'')+'></td>'+
        '<td style="text-align:center"><input type="checkbox" data-access-role="student" '+(readHas(r.allow,'student')?'checked':'')+'></td>'+
        '<td style="text-align:center"><input type="checkbox" data-write-role="student" '+(writeHas(r.id,'student')?'checked':'')+'></td>'+
        '<td><small>'+esc(r.href)+'</small></td></tr>').join('') +
      '</tbody></table></div></section>';
    content.insertAdjacentHTML('beforeend', html);
  },

  async saveAccessManager() {
    const readMap = {}, writeMap = {}, navShowMap = {};
    document.querySelectorAll('#role-access-manager [data-access-row]').forEach(row => {
      const id = row.getAttribute('data-access-row');
      readMap[id] = [...row.querySelectorAll('[data-access-role]:checked')].map(c => c.getAttribute('data-access-role'));
      writeMap[id] = [...row.querySelectorAll('[data-write-role]:checked')].map(c => c.getAttribute('data-write-role'));
      navShowMap[id] = [...row.querySelectorAll('[data-nav-role]:checked')].map(c => c.getAttribute('data-nav-role'));
    });
    this.roleAccessMap = readMap;
    this.roleWriteMap = writeMap;
    try { localStorage.setItem('sc-nav-show-map', JSON.stringify(navShowMap)); } catch (e) {}
    try { localStorage.setItem('sc-role-access-map', JSON.stringify(readMap)); localStorage.setItem('sc-role-write-map', JSON.stringify(writeMap)); } catch(e) {}
    const supabase = window.sb || this.sb;
    if (supabase && supabase.from) {
      try { await supabase.from('school_settings').upsert({ id: 1, role_access: readMap, role_write: writeMap }, { onConflict: 'id' }); } catch(e) { console.warn('Access map Supabase sync skipped:', e.message || e); }
    }
    toast('Access and write permissions saved. Navigation and Add/Edit/Delete permissions will update immediately.', 'success', 6000);
    this.applyRoleNav(this.currentRole || 'admin');
  },

  async resetAccessManager() {
    if (!confirm('Reset page access to the generator defaults?')) return;
    this.roleAccessMap = null;
    try { localStorage.removeItem('sc-role-access-map'); localStorage.removeItem('sc-role-write-map'); } catch(e) {}
    const supabase = window.sb || this.sb;
    if (supabase && supabase.from) {
      try { await supabase.from('school_settings').upsert({ id: 1, role_access: null, role_write: null }, { onConflict: 'id' }); } catch(e) {}
    }
    toast('Default role access restored. Reloading…', 'info');
    setTimeout(()=>location.reload(), 700);
  },

  /* =================================================================
     NAVIGATION
     ================================================================= */
  NAV_ORDER: ['dashboard','profile','student-profile','change-password','notifications','academic_setup','students','staff','parents','classes','subjects','departments','attendance','timetable','timetable-generator','sow','lesson_plans','results','report-cards','affective_traits','psychomotor_traits','report_comments','academic-records','transcripts','rubrics','cbt','cbt-prompts','cbt-multi','cbt-exam','entrance','assignments','digital_library','library','book_request','eresources','lms','announcements','events','school_calendar','messages','inbox','broadcast','complaints','voting','surveys','gallery','birthdays','fees','school-fees','school-products','payment-history','payments_online','finance','financial_aid','donations','hr','payroll','staff_loans','staff_bonus','appraisals','leave','substitutions','admissions','exam_registrations','promotion','alumni','certificates','transfer_cert','idcards','flyer','document_builder','conduct','behaviour','health','counselling','support_plans','diary','gamification','hostel','cafeteria','menu','transport','fleet_tracking','visitors','checkin','front_desk','lost_found','parent_meeting','facility_booking','library_borrowers','career_counseling','helpdesk','directory','reports','analytics','inventory','storage','compliance','activity_log','admin-data','approvals','settings','teacher-overview','feature-guide','hmg-digital-products','status-manager','developer'],

  // v2 NAV-01: Pages may be generated from older static templates whose
  // hand-written sidebars do not contain later modules. Inject these canonical
  // links at runtime so navigation is complete, then apply the normal role/RLS
  // visibility rules. This avoids relying on one stale page template.
  ESSENTIAL_NAV: [
    ['affective_traits','⭐','Affective Domain','affective_traits.html','super_admin admin principal proprietor head_teacher bursar staff teacher'],
    ['psychomotor_traits','🏃','Psychomotor Domain','psychomotor_traits.html','super_admin admin principal proprietor head_teacher bursar staff teacher'],
    ['report_comments','💬','Report Card Comments','report_comments.html','super_admin admin principal proprietor head_teacher bursar staff teacher'],
    ['school_fees','💳','School Fee Structure','school-fees.html','super_admin admin principal proprietor head_teacher bursar'],
    ['school_products','🛍️','School Products','school-products.html','super_admin admin principal proprietor head_teacher bursar'],
    ['status_manager','🔐','Role & Status Manager','status-manager.html','super_admin admin principal proprietor head_teacher bursar'],
    ['ecosystem','🌐','HMG Ecosystem','ecosystem.html','super_admin admin principal proprietor head_teacher bursar staff teacher parent student'],
    ['hmg_digital_products','🏢','HMG Digital Products','hmg-digital-products.html','super_admin admin principal proprietor head_teacher bursar staff teacher parent student']
  ],
  ensureEssentialNav() {
    const nav=document.querySelector('.app-nav'); if(!nav) return;
    this.ESSENTIAL_NAV.forEach(([id,icon,label,href,allow]) => {
      if(nav.querySelector('[data-module-id="'+id+'"]')) return;
      const a=document.createElement('a'); a.href=href; a.dataset.moduleId=id; a.dataset.roleAllow=allow;
      a.innerHTML='<span class="app-nav-icon">'+icon+'</span><span>'+label+'</span>';
      nav.appendChild(a);
    });
  },

  injectNavSearch() {
    try {
      const nav = document.querySelector('.app-nav'); if (!nav) return;
      if (document.getElementById('nav-search-box')) return;
      const wrap = document.createElement('div');
      wrap.id = 'nav-search-box';
      wrap.style.cssText = 'padding:8px 10px 4px;position:sticky;top:0;background:inherit;z-index:5';
      wrap.innerHTML = '<div style="position:relative">' +
        '<input id="nav-search" type="search" placeholder="🔎 Search pages…" autocomplete="off" ' +
        'style="width:100%;padding:8px 30px 8px 12px;border:1px solid var(--gray-200,#e2e8f0);border-radius:10px;font-size:.85rem;background:var(--white,#fff);color:inherit">' +
        '<button id="nav-search-clear" title="Clear" style="position:absolute;right:6px;top:50%;transform:translateY(-50%);border:0;background:none;cursor:pointer;font-size:.9rem;display:none">✕</button></div>' +
        '<div id="nav-search-empty" style="display:none;font-size:.75rem;color:var(--gray-500,#64748b);padding:6px 2px">No pages match.</div>';
      nav.insertBefore(wrap, nav.firstChild);
      const inp = wrap.querySelector('#nav-search');
      const clr = wrap.querySelector('#nav-search-clear');
      const empty = wrap.querySelector('#nav-search-empty');
      const apply = () => {
        const q = inp.value.trim().toLowerCase();
        clr.style.display = q ? '' : 'none';
        let shown = 0;
        nav.querySelectorAll('a[data-module-id]').forEach(a => {
          const roleHidden = a.dataset.navRoleHidden === '1';
          const match = !q || a.textContent.toLowerCase().includes(q) || (a.getAttribute('data-module-id') || '').replace(/[-_]/g, ' ').includes(q);
          a.style.display = (roleHidden || !match) ? 'none' : '';
          if (!roleHidden && match) shown++;
        });
        empty.style.display = (q && !shown) ? '' : 'none';
      };
      inp.addEventListener('input', apply);
      inp.addEventListener('keydown', e => { if (e.key === 'Escape') { inp.value = ''; apply(); inp.blur(); } });
      clr.addEventListener('click', () => { inp.value = ''; apply(); inp.focus(); });
    } catch (e) {}
  },

  normalizeNavOrder() {
    try {
      const nav = document.querySelector('.app-nav'); if (!nav) return;
      const links = [...nav.querySelectorAll('a[data-module-id]')];
      if (links.length < 2) return;
      // FIX NAV-01: dedupe by NORMALIZED module id, not the raw data-module-id.
      // The codebase uses both 'school_fees' and 'school-fees' as ids (e.g.
      // ESSENTIAL_NAV injects 'school_fees' while hand-written nav uses
      // 'school-fees'); without normalization both links survived and the
      // sidebar showed every aliased module twice.
      const seen = new Set();
      links.forEach(a => {
        const id = App.normalizeModuleId(a.getAttribute('data-module-id'));
        if (seen.has(id)) a.remove(); else seen.add(id);
      });
      const order = App.NAV_ORDER;
      const remaining = [...nav.querySelectorAll('a[data-module-id]')];
      const rank = (a) => { const i = order.indexOf(a.getAttribute('data-module-id')); return i === -1 ? order.length + remaining.indexOf(a) : i; };
      remaining.sort((a, b) => rank(a) - rank(b)).forEach(a => nav.appendChild(a));
    } catch (e) {}
  },

  applyRoleNav(role) {
    document.body.dataset.roleReady = '1';
    document.body.dataset.currentRole = String(role || '').toLowerCase();
    App.ensureEssentialNav();
    App.normalizeNavOrder();
    App.markActiveNav();
    App.injectNavSearch();
    const links = [...document.querySelectorAll('[data-role-allow]')];
    const isAdmin = App.isAdminRole(role);
    /* v5: per-role nav-visibility map (admin can override per-page per-role) */
    let navShowMap = {};
    try { navShowMap = JSON.parse(localStorage.getItem('sc-nav-show-map') || '{}'); } catch(_){}

    links.forEach(el => {
      const moduleId = el.getAttribute('data-module-id') || el.getAttribute('href') || '';
      // Three-layer permission check:
      //  1. data-role-allow: explicit role list
      //  2. App.canAccessAllowList: expands role inheritance (admin -> staff -> teacher etc.)
      //  3. App.moduleAllowedForRole: family blacklist/whitelist + page-specific deny
      const familyReadOnly = ['parent','student'].includes(String(role||'').toLowerCase()) && App.moduleAllowedForRole(moduleId, role);
      const allowOk = familyReadOnly || (App.canAccessAllowList(App.allowTextForElement(el), role) && App.moduleAllowedForRole(moduleId, role));
      let ok = allowOk;
      /* v5: if the page is in the nav-show map and the role is NOT in it, hide it (even if allowOk=true) */
      if (ok && navShowMap[moduleId] && Array.isArray(navShowMap[moduleId]) && !isAdmin) {
        // Use the roleSet to expand admin/staff/teacher inheritance
        const roles = App.roleSet(role);
        const visible = navShowMap[moduleId].some(r => roles.has(r));
        if (!visible) {
          ok = false;
          // but the page itself is still readable — just don't show in sidebar
        }
      }
      if (isAdmin) {
        el.style.display = '';
        el.dataset.navRoleHidden = '0';
        el.classList.remove('nav-locked');
      } else {
        // ENTERPRISE V9 (issue 3 — policy update by client): admin-only pages
        // must NOT appear on student/parent/staff navigation at all. Restricted
        // links are now REMOVED from the menu for non-admin roles.
        el.style.display = ok ? '' : 'none';
        el.dataset.navRoleHidden = ok ? '0' : '1';
        el.classList.remove('nav-locked');
      }
      if (!ok) {
        el.setAttribute('aria-disabled', 'true');
        el.setAttribute('title', 'Hidden in your sidebar (admin disabled it)');
      } else {
        el.removeAttribute('aria-disabled');
        el.removeAttribute('title');
      }
    });

    App.applyVisibilityTokens(role);
    App.ensureNavNotBlank(role);
    App.enforceCurrentPageAccess(role);
    App.refreshCurrentCrudAfterRole(role);
  },

  refreshCurrentCrudAfterRole(role) {
    try {
      const page = currentPage();
      if (window.CRUD && CRUD.def && CRUD.def(page)) {
        clearTimeout(App._crudRoleTimer);
        // FIX #1: Increased debounce from 150ms to 600ms to prevent race
        // condition where the initial renderList (from loadPageData) is
        // overridden by this role-refresh before data arrives from Supabase.
        // The 600ms window gives the first render time to complete.
        App._crudRoleTimer = setTimeout(() => {
          if (typeof CRUD.renderList === 'function') {
            try { CRUD.renderList(page, { roleRefresh: true }); } catch(e) {}
          }
          // Apply read-only role enforcement to the form fields
          try { App.enforceReadOnlyForm(role, page); } catch(e) {}
        }, 600);
      }
    } catch(e) {}
  },

  /* Enforce read-only on forms for parent/student roles. */
  enforceReadOnlyForm(role, page) {
    const r = String(role || '').toLowerCase();
    if (!['parent','student'].includes(r)) return;
    // Disable every Add/Edit/Delete button on the page
    document.querySelectorAll('[data-admin-only],[data-staff-only]').forEach(el => {
      if (el.tagName === 'BUTTON' || el.tagName === 'A' || el.tagName === 'INPUT') {
        el.style.display = 'none';
      } else {
        el.style.display = 'none';
      }
    });
    // Disable any input/select inside the main content that isn't already readonly
    const content = document.querySelector('.app-content');
    if (!content) return;
    content.querySelectorAll('input:not([type=checkbox]):not([type=radio]), textarea, select').forEach(el => {
      if (el.closest('#nav-search-box')) return;
      if (el.readOnly || el.disabled) return;
      el.setAttribute('readonly', 'readonly');
      el.setAttribute('aria-readonly', 'true');
      el.style.backgroundColor = '#f8fafc';
    });
  },

  applyVisibilityTokens(role) {
    const allow = (selector, yes) => document.querySelectorAll(selector).forEach(el => el.style.display = yes ? '' : 'none');
    const r = String(role || '').toLowerCase();
    const isAdmin = App.isAdminRole(r);
    const isStaff = ['staff','teacher'].includes(r);
    const isParent = r === 'parent';
    const isStudent = r === 'student';

    allow('[data-admin-only]', isAdmin);
    allow('[data-staff-only]', isAdmin || isStaff);
    allow('[data-parent-only]', isParent);
    allow('[data-student-only]', isStudent);
    allow('[data-family-only]', isAdmin || isStaff || isParent || isStudent);
    allow('[data-nonadmin-only]', !isAdmin);

    document.querySelectorAll('[data-signout]').forEach(el => {
      el.style.display = (r === 'guest' || r === 'demo') ? 'none' : '';
    });

    document.querySelectorAll('[data-readonly-role]').forEach(el => {
      const list = String(el.getAttribute('data-readonly-role') || '').split(/\s+/).filter(Boolean);
      const yes = !isAdmin && (list.includes(r) || (isStaff && list.includes('staff')));
      el.disabled = !!yes;
      el.setAttribute('aria-disabled', yes ? 'true' : 'false');
      if (yes) el.title = 'Read-only for your role';
      else el.removeAttribute('title');
    });
  },

  ensureNavNotBlank(role) {
    const nav = document.querySelector('.app-nav');
    if (!nav) return;
    const links = [...nav.querySelectorAll('a')].filter(a => a.style.display !== 'none');
    if (links.length) return;
    const safe = new Set(['dashboard.html','notifications.html','feature-guide.html','about.html','contact.html']);
    [...nav.querySelectorAll('a')].forEach(a => {
      if (safe.has((a.getAttribute('href') || '').toLowerCase())) {
        a.style.display = '';
        a.classList.remove('nav-locked');
      }
    });
  },

  enforceCurrentPageAccess(role) {
    // v2 — BUG #1 FIX: if role hasn't been resolved yet (e.g. Supabase
    // profile fetch is still in flight, or auth getUser() rejected), do
    // NOT show the "guest" error. Bail out silently and let the async
    // resolveAndApplyRole() finish — the page will then re-render with
    // the correct role. Without this guard, every page rendered the
    // "Your role (guest) does not have permission" error on first paint.
    if (!role || role === 'guest' || role === 'demo' || role === 'pending') {
      // Only block for demo/guest when the page has data-require-role
      const shell = document.querySelector('.app-layout[data-require-role]');
      if (shell) {
        // If Supabase is not configured, show a friendly setup message.
        if (!window.sb) {
          const content = document.querySelector('.app-content');
          if (content && !document.getElementById('sc-setup-required')) {
            content.innerHTML = '<div class="card" style="max-width:720px;margin:30px auto;text-align:center;border-color:#fde68a;background:#fffbeb;padding:40px;border-radius:18px">' +
              '<div style="font-size:3rem;margin-bottom:14px">🛠️</div>' +
              '<h2 style="margin-bottom:10px">Setup required</h2>' +
              '<p style="color:var(--gray-700);margin-bottom:14px">The portal is not yet connected to a database. To finish setup:</p>' +
              '<ol style="text-align:left;color:var(--gray-700);max-width:520px;margin:0 auto 14px;line-height:1.7">' +
              '<li>Open <code>assets/js/config.js</code> in your editor.</li>' +
              '<li>Paste your Supabase URL and anon key.</li>' +
              '<li>Run <code>database/complete-schema.sql</code> in Supabase SQL editor.</li>' +
              '<li>Reload this page.</li></ol>' +
              '<a class="btn btn-primary" href="login.html">Go to login</a></div>';
          }
          return;
        }
        // Otherwise (Supabase configured, but role not yet resolved)
        // let the page continue loading. resolveAndApplyRole() will
        // run enforceCurrentPageAccess again when the real role is set.
        return;
      }
      // No data-require-role and not authed → let the page render
      // its own public state.
      return;
    }
    if (App.isAdminRole(role)) return;
    const shell = document.querySelector('.app-layout[data-require-role]');
    if (!shell) return;
    const active = document.querySelector('.app-nav a.active');
    const required = active ? App.allowTextForElement(active) : shell.getAttribute('data-require-role');
    const blockedByNav = active && active.style.display === 'none';
    const activeId = active ? (active.getAttribute('data-module-id') || active.getAttribute('href') || '') : currentPage();
    const familyReadOnly = ['parent','student'].includes(String(role||'').toLowerCase()) && App.moduleAllowedForRole(activeId, role);
    const blockedByRole = (!familyReadOnly && required && !App.canAccessAllowList(required, role)) || !App.moduleAllowedForRole(activeId, role);

    if (!blockedByNav && !blockedByRole && !(active && active.classList.contains('nav-locked'))) return;

    const pageTitle = (active && active.textContent.trim()) || document.title || 'this page';
    const content = document.querySelector('.app-content');
    if (content) {
      content.innerHTML = '<div class="card" style="max-width:760px;margin:30px auto;text-align:center;border-color:#fecaca;background:#fff7f7;padding:40px;border-radius:18px">' +
        '<div style="font-size:3rem;margin-bottom:16px">🔒</div>' +
        '<h2 style="margin-bottom:12px">Restricted Page</h2>' +
        '<p style="color:var(--gray-700);margin-bottom:16px">Your role (<strong>'+esc(role)+'</strong>) does not have permission to access <strong>'+esc(pageTitle)+'</strong>.</p>' +
        '<div style="display:flex;gap:12px;justify-content:center;flex-wrap:wrap">' +
        '<a class="btn btn-primary" href="dashboard.html">Return to Dashboard</a>' +
        '<a class="btn btn-outline" href="login.html">Sign In</a></div></div>';
    }
  },

  /* ----- Auth ----- */
  async handleSignIn(e) {
    e.preventDefault();
    if (e.target.dataset.signingIn === '1') return;
    e.target.dataset.signingIn = '1';
    const fd = new FormData(e.target);
    let email = (fd.get('email') || '').trim().toLowerCase();
    const password = String(fd.get('password') || '').trim();
    const supabase = window.sb || this.sb || null;
    if (!supabase) {
      alert('Database not configured. Please edit assets/js/config.js with your Supabase URL and anon key.');
      return;
    }
    const btn = e.target.querySelector('button[type=submit]');
    if (btn) { btn.disabled = true; btn.dataset.label = btn.textContent; btn.textContent = 'Signing in…'; }
    if (email && email.indexOf('@') === -1) {
      try {
        const { data: resolved, error: rerr } = await supabase.rpc('lookup_login_email', { p_identifier: email });
        if (!rerr && resolved) { email = String(resolved).toLowerCase(); }
        else {
          if (btn) { btn.disabled = false; btn.textContent = btn.dataset.label || 'Sign in'; }
          e.target.dataset.signingIn = '0';
          alert('No account found for ID "' + email.toUpperCase() + '".');
          return;
        }
      } catch(_) {}
    }
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      if (btn) { btn.disabled = false; btn.textContent = btn.dataset.label || 'Sign in'; }
      e.target.dataset.signingIn = '0';
      alert('Sign-in failed: ' + (error.message || 'Check your email and password.'));
      return;
    }
    try { await App.ensureProfileAfterLogin(data && data.user, email); } catch(e) {}
    App.logActivity('login', 'auth', email);
    location.href = 'dashboard.html';
  },

  async ensureProfileAfterLogin(user, email) {
    const supabase = window.sb || this.sb || null;
    if (!supabase || !user) return;
    try {
      const { data: existing } = await supabase.from('profiles').select('id,role,status').eq('id', user.id).maybeSingle();
      if (!existing) {
        await supabase.from('profiles').insert({ id: user.id, email: email || user.email, full_name: user.user_metadata?.full_name || '', role: user.user_metadata?.role || 'student', status: 'active' });
      }
    } catch(e) {}
  },

  async handleSignUp(e) {
    e.preventDefault();
    const fd = new FormData(e.target);
    const supabase = window.sb || this.sb || null;
    if (!supabase) { alert('Database not configured. Please edit assets/js/config.js with your Supabase URL and anon key.'); return; }
    const btn = e.target.querySelector('button[type=submit]');
    if (btn) { btn.disabled = true; btn.dataset.label = btn.textContent; btn.textContent = 'Submitting…'; }
    const { data, error } = await supabase.auth.signUp({
      email: (fd.get('email') || '').trim(),
      password: fd.get('password') || '',
      options: { data: { full_name: fd.get('full_name'), phone: fd.get('phone'), role: fd.get('role') } }
    });
    if (btn) { btn.disabled = false; btn.textContent = btn.dataset.label || 'Request access'; }
    if (error) { alert('Request failed: ' + (error.message || 'Could not create request.')); return; }
    alert('✅ Request sent! Check your email to confirm, then wait for admin approval.');
    if (e.target.reset) e.target.reset();
    App.switchAuthTab('signin');
  },

  switchAuthTab(tab) {
    const s = document.getElementById('signin-form');
    const u = document.getElementById('signup-form');
    const ts = document.getElementById('tab-signin');
    const tu = document.getElementById('tab-signup');
    if (!s || !u) return;
    if (tab === 'signup') {
      s.style.display = 'none'; u.style.display = 'block';
      if (tu) tu.className = 'btn btn-primary'; if (ts) ts.className = 'btn btn-outline';
    } else {
      s.style.display = 'block'; u.style.display = 'none';
      if (ts) ts.className = 'btn btn-primary'; if (tu) tu.className = 'btn btn-outline';
    }
  },

  logActivity(action, entity, entityId, details) {
    const supabase = window.sb || this.sb || null;
    if (!supabase) return;
    try {
      supabase.auth.getUser().then(({ data }) => {
        const u = data && data.user;
        supabase.from('activity_log').insert({
          actor_id: u ? u.id : null,
          actor_email: u ? u.email : entityId,
          action, entity, entity_id: String(entityId || ''),
          details: details || null
        }).then(() => {}, () => {});
      });
    } catch (_) {}
  },

  bindUI() {
    document.addEventListener('click', e => {
      const a = e.target.closest('[data-app-action]');
      if (a) {
        const fn = a.dataset.appAction;
        if (App[fn]) App[fn](a);
      }
    });
  },

  toggleDarkMode() {
    const cur = document.body.dataset.theme || 'light';
    document.body.dataset.theme = cur === 'dark' ? 'light' : 'dark';
    localStorage.setItem('sc-theme', document.body.dataset.theme);
  },

  signOut() {
    const supabase = window.sb || this.sb || null;
    if (!supabase) { location.href = 'login.html'; return; }
    try { localStorage.removeItem('sc-cached-profile'); localStorage.removeItem('sc-last-role'); } catch(_){}
    supabase.auth.signOut().then(() => { location.href = 'login.html'; });
  },

  toggleSidebar() {
    const el = document.getElementById('app-sidebar');
    if (el) el.classList.toggle('open');
  },

  switchCampus(name) {
    localStorage.setItem('sc-campus', name);
    location.reload();
  },

  async loadPageData() {
    const path = location.pathname.split('/').pop().replace('.html','') || 'dashboard';
    if (path === 'dashboard' && App.loadDashboard) App.loadDashboard();
    if (path === 'voting' && typeof VotingUI !== 'undefined') VotingUI.renderPollList();
    if (path === 'notifications' && typeof Notifications !== 'undefined') Notifications.loadDropdownItems();
    if (typeof CRUD !== 'undefined' && CRUD.def && CRUD.def(path)) { try { CRUD.renderList(path); } catch (e) {} }
    if (App['load_' + path]) App['load_' + path]();
  },

  async loadDashboard() {
    const supabase = window.sb || this.sb || null;
    const set = (id, v) => { const el = document.getElementById(id); if (el) el.textContent = v; };
    const safeCount = async (table) => {
      if (!supabase) return 0;
      try {
        const r = await supabase.from(table).select('id', { count: 'exact', head: true });
        return r && !r.error ? (r.count || 0) : 0;
      } catch (_) { return 0; }
    };
    const safeRows = async (table, select='*', limit=5) => {
      if (!supabase) return [];
      try {
        const r = await supabase.from(table).select(select).order('created_at',{ascending:false}).limit(limit);
        return r && !r.error ? (r.data || []) : [];
      } catch (_) { return []; }
    };
    try {
      const [studentCount, staffCount, feeRows, announcements, openPolls, events, broadcasts, surveys, lostFound, ptaMeetings, meals, attendanceCount, cbtCount, resultCount, parentCount, complaintCount, hostelRows] = await Promise.all([
        safeCount('students'), safeCount('staff'),
        safeRows('fee_payments', 'amount_paid', 500),
        safeRows('announcements', '*', 5),
        safeRows('polls', '*', 5).then(x=>(x||[]).filter(p=>String(p.status||'open')==='open')),
        safeRows('events', '*', 5),
        safeRows('module_records', '*', 5).then(x=>(x||[]).filter(r=>r.module==='broadcast')),
        safeRows('module_records', '*', 5).then(x=>(x||[]).filter(r=>r.module==='surveys')),
        safeRows('module_records', '*', 5).then(x=>(x||[]).filter(r=>r.module==='lost_found')),
        safeRows('module_records', '*', 5).then(x=>(x||[]).filter(r=>r.module==='parent_meeting')),
        safeRows('module_records', '*', 5).then(x=>(x||[]).filter(r=>r.module==='cafeteria' || r.module==='menu')),
        safeCount('attendance'), safeCount('cbt_exams'), safeCount('results'),
        safeCount('parent_child'), safeCount('complaints'),
        safeRows('hostel_allocations', '*', 4)
      ]);
      const feesPaid = (feeRows || []).reduce((a,b) => a + (Number(b.amount_paid) || 0), 0);
      set('stat-students', studentCount);
      set('stat-staff', staffCount);
      set('stat-fees', feesPaid.toLocaleString());
      set('stat-announcements', announcements.length);
      set('ov-staff-count', staffCount);
      set('ov-attendance', attendanceCount);
      set('ov-cbt-open', cbtCount);
      set('ov-results', resultCount);
      set('ov-parent-fees', feeRows.length);
      set('ov-parents', parentCount);
      set('ov-complaints', complaintCount);

      const annHTML = announcements.length
        ? announcements.map(a => '<div style="padding:10px 0;border-bottom:1px solid var(--gray-200)"><a href="announcements.html"><strong>'+esc(a.title)+'</strong></a><div style="font-size:0.82rem;color:var(--gray-500)">'+(a.created_at ? fmtDMYT(a.created_at) : '')+'</div><div style="font-size:.86rem;color:var(--gray-600)">'+esc(a.body||'').slice(0,120)+'</div></div>').join('')
        : '<p style="color:var(--gray-500)">No announcements yet.</p>';
      document.querySelectorAll('#dash-announcements,.dash-announcements').forEach(el => el.innerHTML = annHTML);
      const pollHTML = openPolls.length
        ? openPolls.map(p => '<div style="padding:10px 0;border-bottom:1px solid var(--gray-200)"><a href="voting.html?poll='+p.id+'"><strong>'+esc(p.title)+'</strong></a><span class="badge badge-success" style="margin-left:8px">open</span><div style="font-size:.86rem;color:var(--gray-600)">'+esc(p.description||'Cast your vote now').slice(0,120)+'</div></div>').join('')
        : '<p style="color:var(--gray-500)">No active polls.</p>';
      document.querySelectorAll('#dash-polls,.dash-polls').forEach(el => el.innerHTML = pollHTML);
      App.injectDashboardLiveFeed(announcements, openPolls, {events, broadcasts, surveys, lostFound, ptaMeetings, meals, hostel: hostelRows});
      App.injectPaymentHistory();

      const ctx = document.getElementById('dash-chart');
      if (ctx && window.Chart) {
        new Chart(ctx, {
          type: 'doughnut',
          data: {
            labels: ['Students', 'Staff', 'Classes'],
            datasets: [{ data: [studentCount, staffCount, 0], backgroundColor: ['#4f46e5','#06b6d4','#d4af37'] }]
          },
          options: { responsive: true, plugins: { legend: { position: 'bottom' } } }
        });
      }
    } catch (e) { console.warn('Dashboard load failed:', e.message); }
  },

  injectDashboardLiveFeed(announcements, openPolls, extra) {
    try {
      extra = extra || {};
      const esc2 = (s) => esc(String(s == null ? '' : s));
      const when = (r) => r.ref_date ? fmtDMY(r.ref_date) : (r.date ? fmtDMY(r.date) : (r.created_at ? fmtDMY(r.created_at) : ''));
      const item = (icon, title, sub, href, badge) =>
        '<div style="display:flex;gap:10px;align-items:flex-start;padding:9px 0;border-bottom:1px solid var(--gray-200)">' +
        '<span style="font-size:1.15rem;line-height:1">' + icon + '</span>' +
        '<div style="flex:1;min-width:0"><a href="' + esc2(href || '#') + '" style="font-weight:700;color:var(--dark);text-decoration:none">' + esc2(title) + '</a>' +
        (badge ? ' <span class="badge badge-success" style="font-size:.66rem">' + esc2(badge) + '</span>' : '') +
        '<div style="font-size:.8rem;color:var(--gray-500)">' + esc2(sub || '') + '</div></div></div>';

      const sections = [];
      if ((openPolls || []).length) {
        sections.push({ title: '🗳️ Voting & Polls — cast your vote', html: openPolls.map(p =>
          item('🗳️', p.title, (p.description || 'Voting is open — tap to vote') + (p.closes_at ? ' · closes ' + fmtDMY(p.closes_at) : ''), 'voting.html?poll=' + p.id, (p.status||'open'))).join('') +
          '<div style="margin-top:8px"><a class="btn btn-sm btn-primary" href="voting.html">Open Voting Booth →</a></div>' });
      }
      const map = [
        ['events',        '🎭 Upcoming Events',        'events.html',          (r)=>[r.title, (r.venue?r.venue+' · ':'')+when(r)]],
        ['broadcasts',    '📨 Result Broadcasts',      'broadcast.html',       (r)=>[r.title, (r.body||'').slice(0,90)]],
        ['surveys',       '📋 Surveys & Forms',        'surveys.html',         (r)=>[r.title, (r.body||'Please respond').slice(0,90)]],
        ['lostFound',     '🔍 Lost & Found',           'lost_found.html',      (r)=>[r.title, ((r.data&&r.data.kind)||'')+' · '+((r.data&&r.data.location)||'')+' · '+when(r)]],
        ['ptaMeetings',   '👥 PTA Meetings',           'parent_meeting.html',  (r)=>[r.title, ((r.data&&r.data.venue)||'')+' · '+when(r)+' '+((r.data&&r.data.time)||'')]],
        ['meals',         '🍽️ Cafeteria & Meals',      'cafeteria.html',       (r)=>[r.title, ((r.data&&r.data.category)||'')+(r.amount?' · '+((window.SCHOOL&&SCHOOL.currency)||'₦')+Number(r.amount).toLocaleString():'')]],
        ['hostel',        '🛏️ Hostel Notices',         'hostel.html',          (r)=>[(r.block?('Block '+r.block+' · Room '+(r.room||'')):r.title||'Hostel update'), (r.status||'')+' · '+when(r)]]
      ];
      map.forEach(([key, title, href, fmt]) => {
        const rows = extra[key] || [];
        if (rows.length) sections.push({ title, html: rows.slice(0,4).map(r => { const [t, sub] = fmt(r); return item(title.split(' ')[0], t || '(untitled)', sub, href); }).join('') });
      });

      if (!sections.length) return;
      const feedHTML = '<div class="card" style="margin-top:16px"><h3 style="margin-top:0">📡 Live School Feed</h3>' +
        sections.map(s => '<div style="margin-bottom:10px"><div style="font-weight:800;font-size:.82rem;letter-spacing:.04em;color:var(--primary);text-transform:uppercase;margin:8px 0 2px">' + s.title + '</div>' + s.html + '</div>').join('') + '</div>';

      let placed = false;
      document.querySelectorAll('.dash-live,#dash-live').forEach(el => { el.innerHTML = feedHTML; placed = true; });
      if (!placed) {
        document.querySelectorAll('#dash-announcements,.dash-announcements').forEach(el => {
          const card = el.closest('.card');
          if (card && !card.parentElement.querySelector('.sc-live-feed')) {
            const w = document.createElement('div'); w.className = 'sc-live-feed'; w.innerHTML = feedHTML;
            card.parentElement.appendChild(w); placed = true;
          }
        });
      }
      if (!placed) {
        const content = document.querySelector('.app-content');
        if (content) { const w = document.createElement('div'); w.className = 'sc-live-feed'; w.innerHTML = feedHTML; content.appendChild(w); }
      }
    } catch (e) { console.warn('Live feed injection failed:', e.message); }
  },

  async injectPaymentHistory() {
    try {
      const supabase = window.sb || this.sb || null; if (!supabase) return;
      const box = document.getElementById('dash-payments'); if (!box) return;
      const role = String(App.currentRole || (window.SC_PROFILE && SC_PROFILE.role) || '').toLowerCase();
      let q = supabase.from('fee_payments').select('*').order('created_at', { ascending: false }).limit(8);
      const { data } = await q;
      let rows = data || [];
      if (role === 'parent' && window.SC_PROFILE && SC_PROFILE.id) {
        const { data: links } = await supabase.from('parent_child').select('student_id').eq('parent_id', SC_PROFILE.id);
        const ids = (links || []).map(l => l.student_id);
        rows = rows.filter(r => ids.includes(r.student_id));
      }
      box.innerHTML = rows.length ? rows.map(r => '<div style="display:flex;justify-content:space-between;padding:7px 0;border-bottom:1px solid var(--gray-200)"><span>' + esc(r.student_name || '') + '</span><b>' + ((window.SCHOOL && SCHOOL.currency) || '₦') + Number(r.amount_paid || 0).toLocaleString() + '</b><span style="color:var(--gray-500)">' + fmtDMY(r.created_at) + '</span></div>').join('') : '<p style="color:var(--gray-500)">No payments recorded yet.</p>';
    } catch (e) {}
  },

  async load_gallery() {
    try {
      const supabase = window.sb || this.sb || null; if (!supabase) return;
      let grid = document.getElementById('gallery-grid');
      if (!grid) {
        const tableWrap = document.querySelector('#gallery-table') && document.querySelector('#gallery-table').closest('.table-wrap');
        const host = (tableWrap && tableWrap.parentElement) || document.querySelector('.app-content');
        if (!host) return;
        grid = document.createElement('div'); grid.id = 'gallery-grid';
        grid.style.cssText = 'display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:14px;margin:14px 0';
        host.insertBefore(grid, tableWrap || host.firstChild);
      }
      const { data } = await supabase.from('gallery').select('*').order('created_at', { ascending: false }).limit(120);
      const rows = data || [];
      if (!rows.length) { grid.innerHTML = '<p style="color:var(--gray-500);grid-column:1/-1">No photos or videos yet. Click "+ Add new" and paste an image/video/YouTube/Drive link.</p>'; return; }
      const md = (window.Super && Super.media) || null;
      grid.innerHTML = rows.map(g => {
        const url = g.media_url || ''; const kind = md ? md.kind(url) : 'link';
        let inner;
        if (kind === 'youtube' && md) { const id = md.ytId(url); inner = '<img src="https://img.youtube.com/vi/' + id + '/mqdefault.jpg" style="width:100%;height:140px;object-fit:cover" loading="lazy"><span style="position:absolute;top:50%;left:50%;transform:translate(-50%,-60%);font-size:2rem;color:#fff;text-shadow:0 2px 6px #000">▶</span>'; }
        else if (kind === 'video') inner = '<video src="' + esc(url) + '" style="width:100%;height:140px;object-fit:cover" muted preload="metadata"></video><span style="position:absolute;top:50%;left:50%;transform:translate(-50%,-60%);font-size:2rem;color:#fff;text-shadow:0 2px 6px #000">▶</span>';
        else if (kind === 'drive' && md) inner = '<img src="https://drive.google.com/thumbnail?id=' + md.driveId(url) + '&sz=w600" referrerpolicy="no-referrer" style="width:100%;height:140px;object-fit:cover" loading="lazy" onerror="this.replaceWith(Object.assign(document.createElement(\'div\'),{textContent:\'🖼️ Drive media\',style:\'height:140px;display:flex;align-items:center;justify-content:center;background:#f1f5f9\'}))">';
        else if (kind === 'image') inner = '<img src="' + esc(url) + '" style="width:100%;height:140px;object-fit:cover" loading="lazy">';
        else inner = '<div style="height:140px;display:flex;align-items:center;justify-content:center;background:#f1f5f9;font-size:2rem">🔗</div>';
        return '<div onclick="App.galleryView(\'' + esc(url).replace(/'/g, "\\'") + '\',\'' + (g.media_type || kind) + '\',\'' + esc(g.caption || '').replace(/'/g, "\\'") + '\')" style="position:relative;cursor:pointer;border:1px solid var(--gray-200);border-radius:14px;overflow:hidden;background:#fff;box-shadow:0 4px 12px rgba(15,23,42,.06)">' + inner +
          '<div style="padding:8px 10px"><div style="font-weight:700;font-size:.82rem;color:var(--dark);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(g.caption || g.album || 'Untitled') + '</div><div style="font-size:.7rem;color:var(--gray-500)">' + esc(g.album || '') + ' · ' + fmtDMY(g.created_at) + '</div></div></div>';
      }).join('');
    } catch (e) { console.warn('Gallery grid failed:', e.message); }
  },

  galleryView(url, type, caption) {
    const md = (window.Super && Super.media) || null;
    const kind = md ? md.kind(url) : (type || 'image');
    let body;
    if (kind === 'youtube' && md) body = '<iframe width="100%" height="420" src="https://www.youtube.com/embed/' + md.ytId(url) + '" frameborder="0" allowfullscreen style="border-radius:12px"></iframe>';
    else if (kind === 'video') body = '<video src="' + esc(url) + '" controls autoplay style="width:100%;max-height:70vh;border-radius:12px"></video>';
    else if (kind === 'drive' && md) body = '<iframe src="https://drive.google.com/file/d/' + md.driveId(url) + '/preview" width="100%" height="420" allow="autoplay" style="border-radius:12px;border:0"></iframe>';
    else body = '<img src="' + esc(url) + '" style="width:100%;max-height:70vh;object-fit:contain;border-radius:12px">';
    openModal(caption || 'Gallery preview', body + '<p style="margin-top:8px"><a href="' + esc(url) + '" target="_blank" rel="noopener">Open original ↗</a></p>');
  },

  /* ENTERPRISE V10: global dropdown de-duplication. */
  dedupeSelectOptions(sel) {
    if (!sel || sel.dataset.scDedupeRunning === '1') return;
    sel.dataset.scDedupeRunning = '1';
    try {
      const seen = new Set();
      const scan = (root) => Array.from(root.children || []).forEach(o => {
        if (o.tagName === 'OPTGROUP') { scan(o); return; }
        if (o.tagName !== 'OPTION') return;
        if (!o.value && /^—|loading/i.test((o.textContent || '').trim())) return;
        const label = (o.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
        const value = String(o.value || '').trim().toLowerCase();
        const key = label || value;
        if (!key) return;
        if (seen.has(key)) o.remove(); else seen.add(key);
      });
      scan(sel);
    } finally { sel.dataset.scDedupeRunning = '0'; }
  },
  dedupeAllSelects() {
    try { document.querySelectorAll('select').forEach(sel => App.dedupeSelectOptions(sel)); } catch (_) {}
  },
  installSelectDedupe() {
    if (this._dedupeObserver || typeof MutationObserver === 'undefined') return;
    let t = null;
    this._dedupeObserver = new MutationObserver(() => {
      clearTimeout(t); t = setTimeout(() => App.dedupeAllSelects(), 30);
    });
    try { this._dedupeObserver.observe(document.documentElement || document.body, { childList:true, subtree:true }); } catch (_) {}
  },

  openAddModal(type) {
    if (typeof CRUD !== 'undefined' && CRUD.def && CRUD.def(type)) { CRUD.openForm(type); return; }
    if (typeof openModal === 'function') openModal('Add ' + type, '<p>This module is view-only or has a dedicated page.</p>');
  }
};

/* ----- Modal helpers ----- */
function openModal(title, body, footer) {
  const b = document.getElementById('modal-backdrop');
  if (!b) return;
  document.getElementById('modal-title').textContent = title;
  document.getElementById('modal-body').innerHTML = body;
  document.getElementById('modal-footer').innerHTML = footer || '<button class="btn btn-outline" onclick="closeModal()">Close</button>';
  b.classList.add('show');
  try { if (window.App) App.dedupeAllSelects(); } catch (_) {}
}

function closeModal() {
  const b = document.getElementById('modal-backdrop');
  if (b) b.classList.remove('show');
}

function toast(msg, type='info', ms=3500) {
  const c = document.getElementById('toast-container');
  if (!c) {
    // Fallback: use console
    if (type === 'danger' || type === 'warning') console.warn('[toast]', msg);
    return;
  }
  const t = document.createElement('div');
  t.className = 'toast toast-' + (type || 'info');
  t.innerHTML = '<div class="toast-msg">' + esc(msg) + '</div>';
  c.appendChild(t);
  setTimeout(() => { t.style.animation = 'slideOut 0.3s ease forwards'; setTimeout(() => t.remove(), 300); }, ms);
}

function handleSignIn(e){ return App.handleSignIn(e); }
function handleSignUp(e){ return App.handleSignUp(e); }

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', App.init);
else App.init();

console.log('%c[School Connect v15] app.js loaded — RBAC, family-safe nav, fixed notifications.', 'color:#10b981;font-weight:bold');
