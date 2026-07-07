/* ====================================================================
   app.js — School Connect Gen v9 (RBAC Fixed)
   ====================================================================
   Role hierarchy: admin → staff + teacher + parent + student
   staff/teacher → staff + teacher
   parent → parent
   student → student
   ==================================================================== */

const PUBLIC_PAGES = ['login','index','about','contact','apply','register','signup','cbt-exam','exam-register','offline',''];

/* ENTERPRISE V6 — global date helpers. School standard: dd/mm/yyyy everywhere. */
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

if (typeof window.SC !== 'undefined' && !window.SC.esc) {
  window.SC.esc = esc;
}

const App = {
  sb: null,

  init() {
    console.log('[App.init] Starting...');
    
    // Ensure sb is available from config.js
    if (window.sb && !this.sb) {
      this.sb = window.sb;
    }
    
    App.bindUI();
    App.installSelectDedupe();
    App.dedupeAllSelects();
    App.applyStoredTheme();
    App.loadRoleAccessMap();
    
    const page = currentPage();
    console.log('[App.init] Current page:', page);
    
    if (PUBLIC_PAGES.includes(page)) {
      App.initAuthTabs();
      try { if (window.PWAInstall) PWAInstall.init(); } catch(_) {}
      try { if (window.Notifications) {
        const currentSb = window.sb || this.sb || null;
        if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').then(reg => Notifications.init(currentSb, reg));
        else Notifications.init(currentSb);
      }} catch(_) {}
      try { if (window.Super) Super.init(window.sb || this.sb || null, window.SCHOOL); } catch(_) {}
      try { if (window.Enterprise) Enterprise.init(window.sb || this.sb || null); } catch(_) {}
      try { if (window.CRUD) CRUD.init(window.sb || this.sb || null); } catch(_) {}
      return;
    }
    
    App.applyRoleVisibility();
    App.loadSchoolSettings();
  },

  /* ENTERPRISE V6 (issue 10): pull school_settings (signature URL, principal
     name, admission prefix…) from the DB so signatures saved on ONE device
     appear on documents printed from ANY device. localStorage remains a
     fast local override. */
  async loadSchoolSettings() {
    try {
      const supabase = window.sb || this.sb || null; if (!supabase) return;
      const { data } = await supabase.from('school_settings').select('*').eq('id', 1).maybeSingle();
      if (data) {
        window.SC_SETTINGS = data;
        try {
          if (data.signature_url && !localStorage.getItem('sc-signature-url')) localStorage.setItem('sc-signature-url', data.signature_url);
          if (data.principal_name && !localStorage.getItem('sc-principal-name')) localStorage.setItem('sc-principal-name', data.principal_name);
        } catch (_) {}
      }
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
     CORE RBAC
     ================================================================= */
  applyRoleVisibility() {
    const currentSb = window.sb || this.sb || null;
    
    if (!currentSb) {
      console.error('[App] Supabase not configured!');
      const setupBanner = document.getElementById('sc-setup-required');
      if (setupBanner) setupBanner.style.display = 'flex';
      const setupDetail = document.getElementById('sc-setup-detail');
      if (setupDetail) setupDetail.textContent = ' Edit assets/js/config.js with your Supabase URL and anon key.';

      const page = currentPage();
      const effectiveRole = (page === 'dashboard') ? 'guest' : 'demo';
      App.applyRoleDashboard(effectiveRole, { full_name: effectiveRole === 'guest' ? 'Guest' : 'Demo User', role: effectiveRole });
      App.applyRoleNav(effectiveRole);
      App.loadPageData();
      return;
    }

    currentSb.auth.getUser().then(({ data: { user } }) => {
      if (!user) { location.href = 'login.html'; return; }
      console.log('[App] User logged in:', user.email);
      
      currentSb.from('profiles').select('full_name,email,role,status').eq('id', user.id).maybeSingle().then(({ data, error }) => {
        if (error) console.warn('Profile lookup failed:', error.message || error);
        const role = (data && data.role) || user.user_metadata?.role || 'student';
        const status = (data && data.status) || 'active';
        const name = (data && data.full_name) || user.user_metadata?.full_name || user.email || 'User';

        if (status === 'pending') {
          document.body.innerHTML = '<div style="min-height:100vh;display:flex;align-items:center;justify-content:center;padding:40px"><div style="max-width:440px;text-align:center;background:white;padding:40px;border-radius:16px"><h2 style="margin-bottom:12px">⏳ Account pending approval</h2><p>Your account is awaiting admin approval.</p></div></div>';
          return;
        }
        if (status === 'suspended') {
          document.body.innerHTML = '<div style="min-height:100vh;display:flex;align-items:center;justify-content:center;padding:40px"><div style="max-width:440px;text-align:center;background:white;padding:40px;border-radius:16px"><h2>🚫 Account suspended</h2><p>Please contact the school administrator.</p></div></div>';
          return;
        }

        App.currentRole = role;
        App.currentUserName = name;
        App.currentProfile = data || {};
        window.SC_PROFILE = Object.assign({ id: user.id, email: user.email }, data || {}, { role, status, full_name: name });

        console.log('[App] Role applied:', role);
        App.applyVisibilityTokens(role);
        App.applyRoleDashboard(role, { full_name: name, email: user.email, role });
        App.applyRoleNav(role);
        App.loadPageData();
      }).catch((err) => {
        console.warn('Profile load failed:', err && err.message ? err.message : err);
        const fallbackRole = user.user_metadata?.role || 'student';
        const fallbackName = user.user_metadata?.full_name || user.email || 'User';
        App.currentRole = fallbackRole;
        App.currentUserName = fallbackName;
        window.SC_PROFILE = { id: user.id, email: user.email, role: fallbackRole, status: 'active', full_name: fallbackName };
        App.applyVisibilityTokens(fallbackRole);
        App.applyRoleDashboard(fallbackRole, { full_name: fallbackName, email: user.email, role: fallbackRole });
        App.applyRoleNav(fallbackRole);
        App.loadPageData();
      });
    });
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
        ['Child Dashboard','student-profile.html'],['Fees','fees.html'],['Results','results.html'],
        ['Report Cards','report-cards.html'],['Attendance','attendance.html'],
        ['Assignments','assignments.html'],['Diary','diary.html'],['Timetable','timetable.html'],
        ['Inbox','inbox.html'],['Messages','messages.html'],['Announcements','announcements.html'],
        ['Complaints','complaints.html']
      ] : role === 'student' ? [
        ['Take CBT','cbt-exam.html'],['Assignments','assignments.html'],['Timetable','timetable.html'],
        ['Digital Library','digital_library.html'],['E-Resources','eresources.html'],
        ['My Results','results.html'],['Report Cards','report-cards.html'],
        ['My Profile','student-profile.html'],['Complaints','complaints.html'],['Announcements','announcements.html'],
        ['Inbox','inbox.html'],['Certificates','certificates.html']
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
      q.innerHTML = links.map(x => '<a class="btn btn-outline btn-sm" href="'+x[1]+'">'+x[0]+'</a>').join('');
    }
    App.injectAccessManager(role);
  },

  isAdminRole(role) {
    return ['super_admin','superadmin','admin','administrator','owner','director','principal','proprietor','head_teacher','headteacher','bursar'].includes(String(role || '').toLowerCase().replace(/\s+/g,'_'));
  },

  roleSet(role) {
    const r = String(role || '').toLowerCase();
    const set = new Set([r]);
    if (r === 'teacher') set.add('staff');
    if (r === 'staff') set.add('teacher');
    if (App.isAdminRole(r)) {
      ['admin','staff','teacher','parent','student'].forEach(x => set.add(x));
    }
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
      'feature-guide':'feature_guide', 'feature_guide':'feature_guide',
      'verify-certificate':'verify_certificate', 'verify_certificate':'verify_certificate'
    };
    return map[id] || id.replace(/-/g,'_');
  },

  ROLE_GROUPS: {
    staff: ['staff','teacher'],
    parent: ['parent'],
    student: ['student']
  },

  roleAccessMap: null,
  roleWriteMap: null,

  loadRoleAccessMap() {
    try {
      const saved = localStorage.getItem('sc-role-access-map');
      this.roleAccessMap = saved ? JSON.parse(saved) : null;
      const wsaved = localStorage.getItem('sc-role-write-map');
      this.roleWriteMap = wsaved ? JSON.parse(wsaved) : null;
    } catch (e) { this.roleAccessMap = null; }
    // Optional cross-device persistence through school_settings.role_access.
    // The platform still works if the column/table is not available yet.
    const supabase = window.sb || this.sb;
    if (supabase && supabase.from) {
      try {
        supabase.from('school_settings').select('role_access,role_write').eq('id', 1).maybeSingle().then(({data}) => {
          if (data) {
            if (data.role_access && typeof data.role_access === 'object') { this.roleAccessMap = data.role_access; try { localStorage.setItem('sc-role-access-map', JSON.stringify(data.role_access)); } catch(e) {} }
            if (data.role_write && typeof data.role_write === 'object') { this.roleWriteMap = data.role_write; try { localStorage.setItem('sc-role-write-map', JSON.stringify(data.role_write)); } catch(e) {} }
            this.applyRoleNav(this.currentRole || (window.SC_PROFILE && SC_PROFILE.role) || 'student');
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
      // Default write checkboxes mirror CRUD.WRITE_RULES so saving the manager does not accidentally remove built-in staff/family permissions.
      try {
        const rules = (window.CRUD && CRUD.WRITE_RULES) || {};
        const allow = rules[id] || rules[App.normalizeModuleId(id)] || [];
        if (r === 'staff') return allow.includes('staff') || allow.includes('teacher');
        return allow.includes(r);
      } catch(e) { return false; }
    };
    const html = '<section id="role-access-manager" class="card" style="margin-top:18px;border:2px solid rgba(79,70,229,.25)">' +
      '<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;flex-wrap:wrap">' +
      '<div><h2 style="margin:0 0 6px">🔐 Page Access & Permission Manager</h2>' +
      '<p style="margin:0;color:var(--gray-600);max-width:920px">Admin controls which portal pages appear for Staff, Parents and Students, and which roles can write. <b>Read</b> means the page appears and records can be viewed. <b>Write</b> means Add/Edit/Delete buttons are enabled where the page has a form. Admin/Super Admin always keeps full access to every page.</p></div>' +
      '<div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn btn-primary" onclick="App.saveAccessManager()">💾 Save permissions</button><button class="btn btn-outline" onclick="App.resetAccessManager()">↺ Reset defaults</button></div></div>' +
      '<div class="table-wrap" style="margin-top:14px;max-height:560px;overflow:auto"><table><thead><tr><th>Page / Module</th><th>Staff Read</th><th>Staff Write</th><th>Parent Read</th><th>Parent Write</th><th>Student Read</th><th>Student Write</th><th>File</th></tr></thead><tbody>' +
      rows.map(r => '<tr data-access-row="'+esc(r.id)+'"><td><strong>'+esc(r.label)+'</strong><br><small>'+esc(r.id)+'</small></td>' +
        ['staff','parent','student'].map(roleKey => '<td style="text-align:center"><input type="checkbox" data-access-role="'+roleKey+'" '+(readHas(r.allow, roleKey)?'checked':'')+'></td><td style="text-align:center"><input type="checkbox" data-write-role="'+roleKey+'" '+(writeHas(r.id, roleKey)?'checked':'')+'></td>').join('') +
        '<td><small>'+esc(r.href)+'</small></td></tr>').join('') +
      '</tbody></table></div></section>';
    content.insertAdjacentHTML('beforeend', html);
  },

  async saveAccessManager() {
    const readMap = {}, writeMap = {};
    document.querySelectorAll('#role-access-manager [data-access-row]').forEach(row => {
      const id = row.getAttribute('data-access-row');
      readMap[id] = [...row.querySelectorAll('[data-access-role]:checked')].map(c => c.getAttribute('data-access-role'));
      writeMap[id] = [...row.querySelectorAll('[data-write-role]:checked')].map(c => c.getAttribute('data-write-role'));
    });
    this.roleAccessMap = readMap;
    this.roleWriteMap = writeMap;
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


  canAccessAllowList(allowText, role) {
    const allow = String(allowText || '').toLowerCase().split(/\s+/).filter(Boolean);
    if (!allow.length) return App.isAdminRole(role);
    if (allow.some(x => ['any','all','public'].includes(x))) return true;
    const roles = App.roleSet(role);
    return allow.some(a => roles.has(a));
  },

  canWriteByAccess(moduleId, role) {
    if (App.isAdminRole(role)) return true;
    const id = App.normalizeModuleId(moduleId);
    const map = App.roleWriteMap || {};
    if (map[id] && Array.isArray(map[id])) return map[id].includes(String(role||'').toLowerCase()) || (['staff','teacher'].includes(String(role||'').toLowerCase()) && map[id].includes('staff'));
    return null; // null means use default CRUD rules
  },

  /* ENTERPRISE V6 (issue 3): deterministic navigation.
     1. Removes duplicate links pointing to the same page.
     2. Re-sorts links into the fixed catalog order stored in NAV_ORDER so the
        menu can never appear in a different order on different pages.
     3. Runs before role filtering on every page load. */
  NAV_ORDER: ['dashboard','profile','student-profile','change-password','notifications','academic_setup','students','staff','parents','classes','subjects','departments','attendance','timetable','timetable-generator','sow','lesson_plans','results','report-cards','academic-records','transcripts','rubrics','cbt','cbt-prompts','cbt-multi','cbt-exam','entrance','assignments','digital_library','library','book_request','eresources','lms','announcements','events','school_calendar','messages','inbox','broadcast','complaints','voting','surveys','gallery','birthdays','fees','payment-history','payments_online','finance','financial_aid','donations','hr','payroll','staff_loans','staff_bonus','appraisals','leave','substitutions','admissions','exam_registrations','promotion','alumni','certificates','transfer_cert','idcards','flyer','document_builder','conduct','behaviour','health','counselling','support_plans','diary','gamification','hostel','cafeteria','menu','transport','fleet_tracking','visitors','checkin','front_desk','lost_found','parent_meeting','facility_booking','library_borrowers','career_counseling','helpdesk','directory','reports','analytics','inventory','storage','compliance','activity_log','admin-data','approvals','settings','teacher-overview','feature-guide','developer'],
  /* ENTERPRISE V11 (issue 7): search bar at the top of the navigation pane.
     Filters menu items live as you type; Esc or ✕ clears; only searches the
     pages the current role can see. */
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
      // 1. dedupe by module id (keep first occurrence)
      const seen = new Set();
      links.forEach(a => {
        const id = a.getAttribute('data-module-id');
        if (seen.has(id)) a.remove(); else seen.add(id);
      });
      // 2. stable sort into canonical order (unknown ids keep insertion order at the end)
      const order = App.NAV_ORDER;
      const remaining = [...nav.querySelectorAll('a[data-module-id]')];
      const rank = (a) => { const i = order.indexOf(a.getAttribute('data-module-id')); return i === -1 ? order.length + remaining.indexOf(a) : i; };
      remaining.sort((a, b) => rank(a) - rank(b)).forEach(a => nav.appendChild(a));
    } catch (e) {}
  },

  applyRoleNav(role) {
    document.body.dataset.roleReady = '1';
    document.body.dataset.currentRole = String(role || '').toLowerCase();
    App.normalizeNavOrder();
    App.injectNavSearch();
    const links = [...document.querySelectorAll('[data-role-allow]')];
    const isAdmin = App.isAdminRole(role);

    links.forEach(el => {
      const ok = App.canAccessAllowList(App.allowTextForElement(el), role);
      if (isAdmin) {
        // Admin/Super Admin always gets full access; never lock admin navigation.
        el.style.display = '';
        el.dataset.navRoleHidden = '0';
        el.classList.remove('nav-locked');
      } else {
        // ENTERPRISE V9 (issue 3 — policy update by client): admin-only pages
        // must NOT appear on student/parent/staff navigation at all. Restricted
        // links are now REMOVED from the menu for non-admin roles.
        // Determinism is preserved by normalizeNavOrder(): for a given role the
        // menu is always the same, complete set, in the same canonical order.
        el.style.display = ok ? '' : 'none';
        el.dataset.navRoleHidden = ok ? '0' : '1';
        el.classList.remove('nav-locked');
      }
      if (!ok) {
        el.setAttribute('aria-disabled', 'true');
        el.setAttribute('title', 'Locked for your role (' + role + ')');
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
        App._crudRoleTimer = setTimeout(() => CRUD.renderList(page, { roleRefresh: true }), 150);
      }
    } catch(e) {}
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

    // FIX: Show sign out button for all authenticated users
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
    if (App.isAdminRole(role)) return;
    const shell = document.querySelector('.app-layout[data-require-role]');
    if (!shell) return;
    const active = document.querySelector('.app-nav a.active');
    const required = active ? App.allowTextForElement(active) : shell.getAttribute('data-require-role');
    const blockedByNav = active && active.style.display === 'none';
    const blockedByRole = required && !App.canAccessAllowList(required, role);

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

    // ENTERPRISE V8 (issue 20): allow sign-in with STUDENT ID / STAFF ID /
    // admission number instead of email. If the identifier has no '@', we
    // resolve it to the linked account email via a safe security-definer RPC.
    if (email && email.indexOf('@') === -1) {
      try {
        const { data: resolved, error: rerr } = await supabase.rpc('lookup_login_email', { p_identifier: email });
        if (!rerr && resolved) { email = String(resolved).toLowerCase(); console.log('[App.handleSignIn] ID resolved to account email.'); }
        else {
          if (btn) { btn.disabled = false; btn.textContent = btn.dataset.label || 'Sign in'; }
          e.target.dataset.signingIn = '0';
          alert('No account found for ID "' + email.toUpperCase() + '". Check the ID, or sign in with your email. (Admin: run database/update-v8-schema.sql and link the student/staff record to a login account.)');
          return;
        }
      } catch(_) {}
    }
    
    console.log('[App.handleSignIn] Attempting login…');
    
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    
    if (error) {
      console.error('[App.handleSignIn] Error:', error.message);
      if (btn) { btn.disabled = false; btn.textContent = btn.dataset.label || 'Sign in'; }
      e.target.dataset.signingIn = '0';
      alert('Sign-in failed: ' + (error.message || 'Check your email and password.'));
      return;
    }
    
    console.log('[App.handleSignIn] Success!');
    try { await App.ensureProfileAfterLogin(data && data.user, email); } catch(e) { console.warn('Profile bootstrap skipped:', e.message || e); }
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
    } catch(e) { /* RLS may prevent insert; login still continues and normal profile loader handles it */ }
  },

  async handleSignUp(e) {
    e.preventDefault();
    const fd = new FormData(e.target);
    
    const supabase = window.sb || this.sb || null;
    if (!supabase) { 
      alert('Database not configured. Please edit assets/js/config.js with your Supabase URL and anon key.'); 
      return; 
    }
    
    const btn = e.target.querySelector('button[type=submit]');
    if (btn) { btn.disabled = true; btn.dataset.label = btn.textContent; btn.textContent = 'Submitting…'; }
    
    console.log('[App.handleSignUp] Creating account...');
    
    const { data, error } = await supabase.auth.signUp({
      email: (fd.get('email') || '').trim(),
      password: fd.get('password') || '',
      options: { data: { full_name: fd.get('full_name'), phone: fd.get('phone'), role: fd.get('role') } }
    });
    
    if (btn) { btn.disabled = false; btn.textContent = btn.dataset.label || 'Request access'; }
    
    if (error) { 
      console.error('[App.handleSignUp] Error:', error.message);
      alert('Request failed: ' + (error.message || 'Could not create request.')); 
      return; 
    }
    
    console.log('[App.handleSignUp] Success! Account created.');
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
    console.log('[App.signOut] Signing out...');
    supabase.auth.signOut().then(() => {
      console.log('[App.signOut] Signed out successfully');
      location.href = 'login.html';
    });
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

  /* ============================================================
     ENTERPRISE V6 — LIVE DASHBOARD FEED (fixes: voting/polls, events,
     result broadcasts, surveys, lost & found, PTA meetings, cafeteria
     menu and hostel notices now appear on every role's dashboard).
     Previously this function was invoked but never defined, so the
     whole feed silently failed with a TypeError.
     ============================================================ */
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
      // 🗳 open polls / voting — students, staff and parents can vote right from here
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

      // Place inside every visible role section; fall back to appending after announcements.
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

  /* ENTERPRISE V6 — recent fee payments panel for parents/students (was
     referenced but missing). Renders into #dash-payments if present. */
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

  /* ENTERPRISE V6 (issue 11): visual gallery — photo & video previews in a
     responsive grid with a click-to-enlarge lightbox. Renders into
     #gallery-grid if present, otherwise injects one above the gallery table. */
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
      if (!rows.length) { grid.innerHTML = '<p style="color:var(--gray-500);grid-column:1/-1">No photos or videos yet. Click “+ Add new” and paste an image/video/YouTube/Drive link.</p>'; return; }
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


  /* ENTERPRISE V10: global dropdown de-duplication.
     Any select rendered by CRUD, custom pages or static templates is cleaned so
     users never see repeated option labels. Keeps the first option per label. */
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
  if (!c) return;
  const t = document.createElement('div');
  t.className = 'toast toast-' + (type || 'info');
  t.innerHTML = '<div class="toast-msg">' + esc(msg) + '</div>';
  c.appendChild(t);
  setTimeout(() => { t.style.animation = 'slideOut 0.3s ease forwards'; setTimeout(() => t.remove(), 300); }, ms);
}

/* Backwards-compatible global aliases */
function handleSignIn(e){ return App.handleSignIn(e); }
function handleSignUp(e){ return App.handleSignUp(e); }

/* Boot */
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', App.init);
else App.init();

console.log('[School Connect Gen v9] app.js loaded — RBAC role hierarchy fixed.', 'color:#10b981;font-weight:bold');