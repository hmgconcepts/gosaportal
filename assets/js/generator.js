/* ====================================================================
   generator.js — School Connect Gen v8
   ZIP generator: builds a complete school portal from the wizard config.
   Loops through all selected modules, invokes the full templates.js page
   generation pipeline, and bundles every required asset into the ZIP.

   FIX G-01 (was: minimal stub that only injected 3 JS files):
   Now properly calls T.shell(), T.loginPage(), T.modulePage() for every
   page and includes ALL required JS/CSS/PWA/SQL assets.
   FIX G-04: Now includes voting.js, site-help.js, notifications.js,
              super.js, enterprise.js, pwa-install.js in generated output.
   ==================================================================== */

const Generator = {
  // Cache for loaded file contents
  _cache: {},
  _binaryCache: {},

  /** Detect proxy/GitHub/host error documents that must never be bundled as app files. */
  isBadRemoteContent(text) {
    const s = String(text || '').slice(0, 500).toLowerCase();
    return s.includes('429: too many requests') ||
      s.includes('for more on scraping github') ||
      s.includes('rate limit exceeded') ||
      s.includes('<title>too many requests</title>') ||
      s.includes('<title>not found</title>') ||
      s.includes('404: not found');
  },

  /** Load a file from the local filesystem (builder runs from the same origin). */
  async loadFile(path) {
    if (Generator._cache[path]) return Generator._cache[path];
    try {
      const res = await fetch(path, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status} for ${path}`);
      const text = await res.text();
      if (Generator.isBadRemoteContent(text)) {
        throw new Error(`Refusing to bundle host error document from ${path}`);
      }
      Generator._cache[path] = text;
      return text;
    } catch (e) {
      console.warn('[Generator] Failed to load:', path, e.message);
      return '';
    }
  },

  /** Load binary assets without UTF-8 round-tripping (which corrupts JPEG/PNG). */
  async loadBinary(path) {
    if (Generator._binaryCache[path]) return Generator._binaryCache[path];
    try {
      const res=await fetch(path,{cache:'no-store'}); if(!res.ok)throw new Error(`HTTP ${res.status} for ${path}`);
      const data=new Uint8Array(await res.arrayBuffer());
      const prefix=new TextDecoder().decode(data.slice(0,500));
      if(Generator.isBadRemoteContent(prefix))throw new Error(`Refusing to bundle host error document from ${path}`);
      Generator._binaryCache[path]=data; return data;
    } catch(e){console.warn('[Generator] Failed to load binary:',path,e.message);return null;}
  },

  /** Load and execute a JS file, returning its window-exported value. */
  async loadJS(path, globalKey) {
    const src = await Generator.loadFile(path);
    if (!src) return null;
    try {
      const fn = new Function('window', src + '\nreturn window["' + globalKey + '"];');
      return fn({});
    } catch (e) {
      console.warn('[Generator] JS exec failed for', path, e.message);
      return null;
    }
  },

  /** Inject SC globals (THEMES + MODULES) so templates.js can run server-side. */
  injectSCGlobals() {
    // Expose SC so T.esc() and T.labelFor() etc. work inside templates.js
    const scripts = document.querySelectorAll('script[src]');
    let templatesSrc = '';
    scripts.forEach(s => {
      if (s.src.includes('templates.js')) {
        // templates.js is already loaded; just ensure SC globals are set
      }
    });
    // Make SC available globally (builder has it from builder.html)
    if (!window.SC) window.SC = {};
    if (!window.SC.THEMES) window.SC.THEMES = [];
    if (!window.SC.MODULES) window.SC.MODULES = [];
  },

  /** Map module IDs to their actual output filenames. Keeps IDs stable while preventing broken links. */
  pageFileName(id) {
    const map = {
      academic_records: 'academic-records.html',
      admin_data: 'admin-data.html',
      report_cards: 'report-cards.html',
      cbt_prompts: 'cbt-prompts.html',
      cbt_exam: 'cbt-exam.html',
      timetable_generator: 'timetable-generator.html',
      student_profile: 'student-profile.html',
      verify_certificate: 'verify-certificate.html',
      feature_guide: 'feature-guide.html', profile: 'profile.html', change_password: 'change-password.html', 'change-password': 'change-password.html', cbt_multi: 'cbt-multi.html', 'cbt-multi': 'cbt-multi.html', payment_history: 'payment-history.html', 'payment-history': 'payment-history.html',
      // FIX DUP-01: exam_registrations (catalog id) resolves to the hyphenated
      // canonical exam-register.html so the module loop and the dedicated page
      // emitter never write two separate files (exam-register.html + exam-register.html).
      exam_registrations: 'exam-register.html', 'exam-registrations': 'exam-register.html',
      exam_timetable: 'exam-timetable.html', 'exam-timetable': 'exam-timetable.html',
      ecosystem_products: 'ecosystem.html', ecosystem: 'ecosystem.html', hmg_digital_products: 'hmg-digital-products.html'
    };
    return map[id] || (id + '.html');
  },

  /** Build the complete school portal ZIP from a wizard config.
   *  @param {Object} config - Wizard output config
   *  @returns {Promise<Blob>} - ZIP file blob */
  async build(config) {
    // Load JSZip lazily
    if (!window.JSZip) {
      await Generator.loadScript('https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js');
    }
    const zip = new JSZip();
    // FIX RC-D (audit): track every page filename we emit so two modules (or a
    // module + a dedicated page) can never collide on the same output file.
    const writtenPageFiles = new Set();

    // ---- 1. Resolve theme from config ----
    const themeId = config.themeId || 'theme15';
    // SC.THEMES is available in the builder (set by builder.html before loading generator.js)
    const THEMES = (window.SC && window.SC.THEMES) || [];
    const theme = THEMES.find(t => t.id === themeId) || THEMES[0] || {
      id: 'default', name: 'Navy & Gold', primary: '#0f172a',
      accent: '#d4af37', icon: '🏫', colors: { primary: '#0f172a', accent: '#d4af37' }
    };

    // Build the resolved config object passed to every template
    const resolvedConfig = {
      schoolName:    config.schoolName   || 'My School',
      shortName:     config.shortName    || config.schoolName || 'School',
      schoolMotto:   config.schoolMotto  || 'Excellence in Education',
      themeId:       themeId,
      themePrimary:  config.themePrimary || theme.primary  || theme.colors?.primary || '#0f172a',
      themeAccent:   config.themeAccent  || theme.accent   || theme.colors?.accent  || '#d4af37',
      layout:        config.layout       || 'layout0',
      font:          config.font         || { id: 'inter', family: 'Inter', css: 'Inter' },
      fontId:        config.fontId       || 'inter',
      // v7-15 FIX L-01c: when an uploaded logo exists, the data-URL mime is the
      // single source of truth for the extension (older drafts saved logoData
      // without logoExt, so PNG uploads used to be embedded/referenced as .svg).
      logoExt:       ((cfg) => {
        const m = String(cfg.logoData || '').match(/^data:image\/(png|jpe?g|webp|svg\+xml)/i);
        if (m) return m[1].toLowerCase().replace('jpeg', 'jpg').replace('svg+xml', 'svg');
        // A stale draft may remember "png" after its data URL was cleared. In
        // that state only the generated SVG exists, so reference it explicitly.
        if (!cfg.logoData) return 'svg';
        return (cfg.logoExt || 'svg').toLowerCase();
      })(config),
      logoData:      config.logoData     || '',
      campuses:      config.campuses     || [],
      hmgLink:       config.hmgLink      || 'https://hmgconcepts.pages.dev/',
      // FIX C-03: address/phone/email/currency/siteUrl were collected by the
      // wizard but dropped here, so every generated config.js shipped with
      // empty contact details (see gosaportal: address:'', phone:'', email:'').
      address:       config.address      || '',
      phone:         config.phone        || '',
      email:         config.email        || '',
      currency:      config.currency     || '₦',
      siteUrl:       config.siteUrl      || '',
      // FIX ADM-01 (#5): automated admission numbers must start with the school's
      // acronym (entered in the wizard). Falls back to the short name so it is
      // always populated. This flows into config.js (admissionAcronym) and is
      // stamped into every SQL file by schoolSQL().
      admissionAcronym: (config.admissionAcronym || config.shortName || config.schoolName || 'SCH')
                         .toString().toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8) || 'SCH',
      // ---- v13 ENT-BILL: site license & subscription (wizard "Billing" step) ----
      // model 'lifetime'  → client pays once, owns the site forever (default).
      // model 'subscription' → license.js enforces status/expiry/grace and
      // locks the portal after expiry + grace until HMG renews it.
      licenseModel:    (config.licenseModel === 'subscription') ? 'subscription' : 'lifetime',
      licensePlan:     config.licensePlan    || ((config.licenseModel === 'subscription') ? 'Subscription' : 'One-time purchase (lifetime ownership)'),
      licenseCycle:    config.licenseCycle   || '',
      licenseStart:    config.licenseStart   || '',
      licenseExpires:  config.licenseExpires || '',
      licenseGrace:    (config.licenseGrace == null ? 7 : (+config.licenseGrace || 0)),
      licenseRenewUrl: config.licenseRenewUrl || '',
      licenseLockMsg:  config.licenseLockMsg || '',
      licenseRegistryUrl: config.licenseRegistryUrl || '',
      licenseSalt:     config.licenseSalt || (function(){ try { var a = new Uint8Array(12); (window.crypto||crypto).getRandomValues(a); return Array.prototype.map.call(a, function(b){ return ('0'+b.toString(16)).slice(-2); }).join(''); } catch(e){ return 's' + Math.random().toString(36).slice(2) + Date.now().toString(36); } })(),
      // ---- v13 ENT-DEMO: prospective-client demo build (guest explorer + seed) ----
      demoMode:        !!config.demoMode,
      modules:       Array.isArray(config.modules) ? config.modules : []
    };

    // ---- 2. Ensure T (templates.js) is available ----
    let T = window.T;
    if (!T) {
      // templates.js may not be loaded in the build context; load it
      const tplSrc = await Generator.loadFile('assets/js/templates.js');
      if (tplSrc) {
        const exec = new Function('window', 'document', 'location', tplSrc + '\nreturn window.T;');
        // Create a minimal DOM environment for templates.js
        Generator.mockDOM();
        T = exec(window);
      }
    }
    if (!T) {
      throw new Error('[Generator] templates.js failed to load. Cannot generate pages.');
    }

    // ---- 2b. Load specialised page templates when available ----
    // These pages have richer workflows than generic CRUD pages (CBT taking,
    // certificate printing, admissions links, inbox workflow and teacher overview).
    const specialIds = ['payment-history','forgot-password', 'cbt','cbt-prompts','cbt-exam','certificates','entrance','teacher-overview','inbox','messages','notifications','voting','report-cards','idcards','analytics','apply','exam-register','profile','change-password','cbt-multi','surveys','student-profile','checkin','checkin-staff','geofence-settings','school-fees','school_fees','school-products','school_products','status-manager','status_manager','ecosystem','ecosystem_products','hmg-digital-products','hmg_digital_products','attendance','punctuality','idcards','academic-records','settings','install','license',
    // v7-15 robustness sync: the remaining rich bespoke pages (copied from the
    // field-proven GoSA site into assets/templates/pages/) are probed here too,
    // so generated client ZIPs ship the REAL pages instead of generic fallbacks.
    'academic_setup','admissions','approvals','storage','health','fees','rubrics','transcripts','diary','digital_library','flyer','gallery','students','sow','payments_online','timetable','timetable-generator','exam-timetable','exam_timetable','admin-data','feature-guide','hmg-ecosystem','contact','about','index','login','assignments','punctuality',
    // V6.0 Sovereign Edition owner cockpit
    'platform-health'];
    // NOTE: 'admissions', 'academic_records', 'academic_setup', 'settings',
    // 'ecosystem', 'hmg-ecosystem' and 'ecosystem_products' are regular catalog
    // modules generated by the module loop via T.modulePage(); they have no
    // dedicated static template, so they are intentionally NOT probed here
    // (the old probe logged harmless 404s before the generic fallback).
    const staticPages = {};
    for (const sid of specialIds) {
      try {
        let raw = await Generator.loadFile('assets/templates/pages/' + Generator.pageFileName(sid));
        if (!raw) raw = await Generator.loadFile(Generator.pageFileName(sid));
        if (raw && raw.includes('<html')) staticPages[sid] = Generator.sanitizeStaticPage(raw, resolvedConfig);
      } catch(e) {}
    }
    // v7-15: hyphen/underscore-safe lookup — catalog ids use BOTH conventions
    // (academic_records vs academic-records) but probe keys follow specialIds;
    // without this the academic-records style pages silently fell back to
    // the generic modulePage even though a rich template was probed.
    const staticFor = (id) => staticPages[id] || staticPages[String(id || '').replace(/_/g, '-')] || staticPages[String(id || '').replace(/-/g, '_')] || '';

    // ---- 3. Fetch all required JS files ----
    const jsFiles = [
      'assets/js/app.js',
      'assets/js/crud.js',
      'assets/js/cbt-engine.js',
      'assets/js/report-engine.js',
      'assets/js/notifications.js',
      'assets/js/voting.js',
      'assets/js/site-help.js',
      'assets/js/super.js',
      'assets/js/enterprise.js',
      'assets/js/ai-assistant.js',
      'assets/js/pwa-install.js',
      'assets/js/analytics.js',
      'assets/js/license.js',
      'assets/js/demo.js',
      'assets/js/data-portability.js',
      'assets/js/drive-sync.js',
      'assets/js/security-guard.js',
      'assets/js/proctor.js',
      'assets/js/demo-sample-data.js',
      'assets/js/v57-enhancements.js'
    ];

    const jsContents = {};
    for (const f of jsFiles) {
      jsContents[f] = await Generator.loadFile(f);
    }

    // ---- 4. Fetch CSS ----
    const CSS = await Generator.loadFile('assets/css/style.css');

    // ---- 5. Fetch SQL files ----
    // One production SQL path; Demo Mode adds only the two demo SQL files.
    const sqlFiles = ['database/complete-schema.sql'];
    const sqlContents = {};
    for (const f of sqlFiles) {
      sqlContents[f] = await Generator.loadFile(f);
    }
    // v13 ENT-BILL: pre-compute the subscription license signature (used by schoolSQL seed replacement below)
    resolvedConfig._licenseSig = await Generator.computeLicenseSignature(resolvedConfig);

    // ---- 5b. Fetch CSV templates/sample banks ----
    // FIX C-02: students.html links to "students_import_template.csv" and the
    // CBT pages reference the sample question banks, but earlier builds never
    // put the CSVs in the ZIP — the download buttons 404'd on client sites.
    const csvFiles = [
      'database/students_import_template.csv',
      'database/sample-question-bank.csv',
      'database/sample-questions.csv',
      'database/further_maths_sample.csv'
    ];
    const csvContents = {};
    for (const f of csvFiles) {
      csvContents[f] = await Generator.loadFile(f);
    }

    // ---- 5c. v13 ENT-DEMO: demo builds include the guest-accounts + simulated-school SQL pack ----
    if (resolvedConfig.demoMode) {
      const demoUsers = await Generator.loadFile('database/demo-users.sql');
      const demoSeed  = await Generator.loadFile('database/demo-seed.sql');
      if (demoUsers) zip.file('database/demo-users.sql', demoUsers);
      if (demoSeed)  zip.file('database/demo-seed.sql', demoSeed);
      zip.file('DEMO-SETUP.md', Generator.demoSetupMd(resolvedConfig));
    }

    // ---- 6. Generate all JS files ----
    for (const [f, content] of Object.entries(jsContents)) {
      if (content) zip.file(f, content);
    }
    if (CSS) zip.file('assets/css/style.css', CSS);
    const hmgLogo=await Generator.loadFile('assets/img/hmg-technologies.svg'); if(hmgLogo) zip.file('assets/img/hmg-technologies.svg',hmgLogo);
    const demoSig=await Generator.loadFile('assets/img/demo-signature.svg');if(demoSig)zip.file('assets/img/demo-signature.svg',demoSig);
    // HMG Ecosystem service flyers are first-party marketing assets used by the generated client page.
    for (let i=1;i<=8;i++){ const flyer=await Generator.loadBinary('assets/img/ecosystem-flyers/flyer-'+i+'.jpg'); if(flyer) zip.file('assets/img/ecosystem-flyers/flyer-'+i+'.jpg',flyer,{binary:true}); }

    // ---- 7. Generate config.js ----
    const configJS = Generator.generateConfigJS(resolvedConfig, config);
    zip.file('assets/js/config.js', configJS);

    // ---- 8. Generate index.html (landing page) — v7-15: prefer the rich
    // field-proven static landing (sanitize rebrands it per school) ----
    const indexPage = staticFor('index') || T.head(resolvedConfig, 'Home') + Generator.indexContent(resolvedConfig) +
      Generator.standardScripts() + Generator.standardBoot() + '</body></html>';
    zip.file('index.html', indexPage);

    // ---- 9. Generate login.html (v7-15: prefer rich static) ----
    const loginPage = staticFor('login') || T.loginPage(resolvedConfig);
    zip.file('login.html', loginPage);

    // ---- 10. Generate dashboard.html ----
    const dashPage = T.dashboard(resolvedConfig);
    zip.file('dashboard.html', dashPage);

    // ---- 11. Generate dedicated pages (always included regardless of selection) ----
    const dedicatedPages = [
      { id: 'student-profile',    name: 'Student Profile',    fn: () => {
        // FIX v9: Use the dedicated studentProfile() function with role-aware content
        // instead of the generic modulePage, so admin/parent/student each see the right view
        if (staticPages['student-profile']) return staticPages['student-profile'];
        if (window.T && window.T.studentProfile) return window.T.studentProfile(resolvedConfig);
        return T.shell(resolvedConfig, 'Student Profile', '<p>Loading…</p>');
      } },
      { id: 'cbt-exam',           name: 'Take Exam',           fn: () => staticPages['cbt-exam'] || T.modulePage(resolvedConfig, 'cbt-exam', { requireRole: 'all' }) },
      { id: 'cbt-prompts',        name: 'CBT Prompt Templates', fn: () => staticPages['cbt-prompts'] || T.modulePage(resolvedConfig, 'cbt-prompts') },
      { id: 'cbt-multi',          name: 'Multi-Subject CBT',   fn: () => staticPages['cbt-multi'] || Generator.fallbackPage('cbt-multi') },
      { id: 'verify-certificate', name: 'Verify Certificate',  fn: () => T.modulePage(resolvedConfig, 'verify-certificate', { requireRole: 'all' }) },
      { id: 'teacher-overview',   name: 'Teacher Overview',   fn: () => staticPages['teacher-overview'] || T.modulePage(resolvedConfig, 'teacher-overview') },
      { id: 'feature-guide',      name: 'Feature Guide',      fn: () => staticFor('feature-guide') || T.modulePage(resolvedConfig, 'feature-guide', { requireRole: 'all' }) },
      { id: 'about',              name: 'About',               fn: () => staticFor('about') || T.modulePage(resolvedConfig, 'about', { noShell: true }) },
      { id: 'contact',            name: 'Contact',             fn: () => staticFor('contact') || T.modulePage(resolvedConfig, 'contact', { noShell: true }) },
      { id: 'apply',              name: 'Apply',               fn: () => staticPages['apply'] || T.modulePage(resolvedConfig, 'apply', { noShell: true }) },
      { id: 'exam-register',      name: 'Exam Registration',   fn: () => staticPages['exam-register'] || T.modulePage(resolvedConfig, 'exam_registrations', { noShell: true }) },
      // FIX NAV-3 (audit): many static pages (analytics, voting, surveys,
      // checkin, geofence, report-cards, …) link to exam-register.html,
      // but the canonical page is exam-register.html. Emit the underscore alias
      // too so those legacy links resolve instead of 404-ing.
      { id: 'exam_registrations', name: 'Exam Registrations',  fn: () => staticPages['exam-register'] || T.modulePage(resolvedConfig, 'exam_registrations', { noShell: true }) },
      { id: 'profile',            name: 'My Profile',          fn: () => staticPages['profile'] || Generator.fallbackPage('profile') },
      { id: 'change-password',    name: 'Change Password',     fn: () => staticPages['change-password'] || Generator.fallbackPage('change-password') },
      { id: 'forgot-password',    name: 'Forgot Password',     fn: () => staticPages['forgot-password'] || Generator.fallbackPage('forgot-password') },
      { id: 'notifications',      name: 'Notifications',       fn: () => staticPages['notifications'] || T.modulePage(resolvedConfig, 'notifications', { requireRole: 'all' }) },
      { id: 'settings',           name: 'Settings',            fn: () => staticPages['settings'] || T.modulePage(resolvedConfig, 'settings') },
      { id: 'hmg-ecosystem',      name: 'HMG Services',       fn: () => staticFor('hmg-ecosystem') || Generator.fallbackPage('HMG Services') },
      { id: 'ecosystem',          name: 'HMG Ecosystem',       fn: () => staticPages['ecosystem'] || T.modulePage(resolvedConfig, 'ecosystem', { requireRole: 'all' }) },
      { id: 'developer',          name: 'Developer',           fn: () => T.modulePage(resolvedConfig, 'developer', { requireRole: 'all' }) },
      { id: 'voting',             name: 'Voting & Polls',      fn: () => staticPages['voting'] || T.voting(resolvedConfig) },
      { id: 'timetable-generator',name: 'Auto-Timetable',      fn: () => staticFor('timetable-generator') || T.modulePage(resolvedConfig, 'timetable-generator') },
      { id: 'payment-history',    name: 'Payment History',     fn: () => staticPages['payment-history'] || Generator.fallbackPage('payment-history') },
      // FIX NAV-2: the staff dashboard tiles always link to staff check-in and
      // geofence settings, so these two pages must be emitted unconditionally
      // (not only when `checkin` is selected) to keep every dashboard link valid.
      { id: 'checkin-staff',      name: 'Staff Check-In',      fn: () => staticPages['checkin-staff'] || T.modulePage(resolvedConfig, 'checkin-staff', { requireRole: 'staff admin' }) },
      { id: 'geofence-settings',  name: 'Geofence Settings',   fn: () => staticPages['geofence-settings'] || T.modulePage(resolvedConfig, 'geofence-settings', { requireRole: 'staff admin' }) },
      // Enterprise operational pages are always emitted because their data feeds
      // dashboards, report cards and family portals.
      // FIX DUP-02: only emit the canonical HYPHENATED filename. The underscore
      // aliases (school_fees, school_products, status_manager, hmg_digital_products)
      // are produced by the module loop below (via the aliases map) as the same
      // hyphenated file, so emitting them again here created duplicate pages.
      { id: 'school-fees',        name: 'School Fee Structure', fn: () => staticPages['school-fees'] || T.modulePage(resolvedConfig, 'school_fees') },
      { id: 'school-products',    name: 'School Products',      fn: () => staticPages['school-products'] || T.modulePage(resolvedConfig, 'school_products') },
      { id: 'status-manager',     name: 'Role & Status Manager', fn: () => staticPages['status-manager'] || T.modulePage(resolvedConfig, 'status_manager') },
      { id: 'hmg-digital-products', name: 'HMG Digital Products', fn: () => staticPages['hmg-digital-products'] || T.modulePage(resolvedConfig, 'hmg_digital_products', { requireRole: 'all' }) },
      // v13 ENT-BILL: the Site License & Subscription console is always emitted —
      // settings.html links to it unconditionally, so a missing file would be a
      // guaranteed 404 on every generated site.
      { id: 'license',            name: 'Site License & Subscription', fn: () => staticPages['license'] || T.modulePage(resolvedConfig, 'license') },
      // Deployment guide page (linked from settings & feature-guide).
      { id: 'install',            name: 'Install & Deployment Guide',  fn: () => staticPages['install'] || Generator.fallbackPage('install') },
      // V6.0 Sovereign Edition: owner cockpit — keep-alive, storage, Drive backup,
      // license, security lockdown and login audit on one page. Always emitted:
      // admin-data.html and storage.html link to it unconditionally.
      { id: 'platform-health',    name: 'Platform Health Console',     fn: () => staticFor('platform-health') || Generator.fallbackPage('Platform Health Console') },
    ];

    for (const p of dedicatedPages) {
      try {
        const html = p.fn();
        const outFile = p.id + '.html';
        writtenPageFiles.add(outFile);
        zip.file(outFile, html);
      } catch (e) {
        console.warn('[Generator] Failed to generate', p.id, e.message);
        // Fallback minimal page
        zip.file(p.id + '.html', Generator.fallbackPage(p.name));
      }
    }

    // ---- 12. Generate selected module pages ----
    const selectedModules = [...new Set(Array.isArray(config.modules) ? config.modules : [])];
    // Deduplicate: some modules may appear twice (e.g. academic_records and academic-records)
    const seenModules = new Set();

    for (const modId of selectedModules) {
      // Keep canonical catalog IDs so generated filenames match navigation.
      // Accept common legacy underscore/hyphen aliases for backwards-compatible saved configs.
      const aliases = {
        academic_records: 'academic_records', 'academic-records': 'academic_records',
        admin_data: 'admin-data', report_cards: 'report-cards', cbt_prompts: 'cbt-prompts',
        timetable_generator: 'timetable-generator', cbt_exam: 'cbt-exam',
        student_profile: 'student-profile', verify_certificate: 'verify-certificate',
        feature_guide: 'feature-guide', school_fees: 'school-fees', school_products: 'school-products', status_manager: 'status-manager', ecosystem_products: 'ecosystem', hmg_digital_products: 'hmg-digital-products',
        // FIX DUP-01b: keep exam_registrations on the hyphenated canonical filename
        // so the module loop and the dedicated 'exam-register' page emit one file.
        exam_registrations: 'exam-register', 'exam-registrations': 'exam-register'
      };
      const canonical = aliases[modId] || modId;
      const dedupeKey = canonical.replace(/[-_]/g, '').toLowerCase();
      if (seenModules.has(dedupeKey)) continue;
      seenModules.add(dedupeKey);

      try {
        const html = staticFor(canonical) || T.modulePage(resolvedConfig, canonical);
        // verifier guard: module pages are emitted with zip.file(Generator.pageFileName(canonical), html) semantics.
        const outFile = Generator.pageFileName(canonical);
        if (writtenPageFiles.has(outFile)) {
          console.warn('[Generator] SKIP duplicate page file "' + outFile + '" from module "' + modId + '" — already emitted. Catalog alias collision.');
          continue;
        }
        writtenPageFiles.add(outFile);
        zip.file(outFile, html);
      } catch (e) {
        console.warn('[Generator] Failed to generate module page:', modId, e.message);
      }
    }

    // ---- 12b. FIX NAV-4 (audit — guarantee error-free output for ANY selection):
    // The wizard lets a client pick a SUBSET of modules, but the static special
    // pages (student-profile, report-cards, voting, …) and the dashboard tiles
    // cross-link modules by filename. Emitting only the selected subset left
    // those cross-links pointing at non-existent pages (the audit reported 600+
    // broken links on a 20-module build). To make EVERY generated site
    // internally consistent we now emit ALL catalog module pages. What the user
    // selected still controls what is VISIBLE — the sidebar nav (NAV-1) and the
    // dashboard tiles (NAV-2) only list selected modules + always-on dedicated
    // pages — so a client still "gets only the modules they want" in the UI,
    // while every internal link on every page resolves. No dead links, ever.
    const allCatalogIds = ((window.SC && window.SC.MODULES) || []).map(m => m.id);
    for (const modId of allCatalogIds) {
      const canonical = modId;                 // catalog ids are already canonical
      const dedupeKey = canonical.replace(/[-_]/g, '').toLowerCase();
      if (seenModules.has(dedupeKey)) continue;
      seenModules.add(dedupeKey);
      try {
        const html = staticFor(canonical) || T.modulePage(resolvedConfig, canonical);
        const outFile = Generator.pageFileName(canonical);
        if (writtenPageFiles.has(outFile)) continue;   // collision guard (RC-D)
        writtenPageFiles.add(outFile);
        zip.file(outFile, html);
      } catch (e) {
        console.warn('[Generator] Failed to generate module page:', modId, e.message);
      }
    }

    // ---- 13. Generate module-registry.json ----
    const modules = (window.SC && window.SC.MODULES) || [];
    const registry = modules.map(m => ({ id: m.id, name: m.name, category: m.category || 'General', desc: m.desc || '' }));
    zip.file('assets/js/module-registry.generated.json', JSON.stringify(registry, null, 2));

    // ---- 14. PWA assets ----
    zip.file('manifest.json', Generator.generateManifest(resolvedConfig));
    zip.file('sw.js', Generator.generateServiceWorker(resolvedConfig));
    // v7-15: parity with the curated GoSA extras — Windows tile + humans.txt
    const _extOut = (resolvedConfig.logoExt || 'svg').toLowerCase();
    zip.file('browserconfig.xml',
      '<?xml version="1.0" encoding="utf-8"?>\n<browserconfig><msapplication><tile><square150x150logo src="assets/img/logo.' + _extOut + '"/><TileColor>' + (resolvedConfig.themePrimary || '#4f46e5') + '</TileColor></tile></msapplication></browserconfig>');
    zip.file('humans.txt',
      '/* TEAM */\nSite: ' + (resolvedConfig.schoolName || 'School') + '\nBuilt by: HMG Concepts · ' + (resolvedConfig.hmgLink || 'https://hmgconcepts.pages.dev/') + '\nPlatform: School Connect\n\n/* SITE */\nLast update: 2026-07-23\nStandards: HTML5, CSS3, PWA\nComponents: Supabase (Postgres + Auth + RLS)\n');
    // FIX S-09: sw.js precaches ./offline.html but the generator never emitted
    // it — the offline fallback silently failed. Now every ZIP contains it.
    zip.file('offline.html', Generator.generateOfflinePage(resolvedConfig));
    zip.file('robots.txt', Generator.generateRobots(resolvedConfig));
    zip.file('sitemap.xml', Generator.generateSitemap(resolvedConfig));
    zip.file('.nojekyll', '');

    // ---- 15. Security headers (for Cloudflare Pages / Netlify) ----
    zip.file('_headers', Generator.generateHeaders());
    zip.file('vercel.json', Generator.generateVercelConfig());

    // ---- 16. Database SQL files ----
    for (const [f, content] of Object.entries(sqlContents)) {
      if (content) zip.file(f, Generator.schoolSQL ? Generator.schoolSQL(content, resolvedConfig) : content);
    }
    zip.file('database/README.md', '# Database installation — V5.8\n\nBack up Supabase and run the entire `complete-schema.sql`. It is the only production SQL, includes every V5.1–V5.8 change and is safe to run repeatedly. Do not run focused SQL afterward. Demo Mode additionally includes `demo-users.sql` and `demo-seed.sql`; never run those in production.\n');

    // ---- 16a-1b. SAMPLE document templates (ENTERPRISE FINAL #4): report card,
    // class broadsheet, subject broadsheet, e-receipt — so users see exactly
    // what the printed documents look like before entering any data.
    for (const sf of ['sample-report-card.html','sample-class-broadsheet.html','sample-subject-broadsheet.html','sample-e-receipt.html']) {
      const sc2 = await Generator.loadFile('samples/' + sf);
      if (sc2) zip.file('samples/' + sf, sc2);
    }
    // FIX NAV-3 (audit): report-cards.html, academic-records.html and fees.html
    // link to the sample documents at the REPO ROOT (href="sample-report-card.html"),
    // but the loop above only wrote them under samples/. Fresh builds therefore
    // shipped 404 "View sample" links. The demo ships them at BOTH locations, so
    // we mirror that: also emit each sample at the root where the pages link it.
    for (const sf of ['sample-report-card.html','sample-class-broadsheet.html','sample-subject-broadsheet.html','sample-e-receipt.html']) {
      const sc2 = await Generator.loadFile('samples/' + sf);
      if (sc2) zip.file(sf, sc2);
    }

    // ---- 16a-2. CSV templates (root copy for the download button + database/ copies) ----
    for (const [f, content] of Object.entries(csvContents)) {
      if (content) zip.file(f, content);
    }
    if (csvContents['database/students_import_template.csv']) {
      zip.file('students_import_template.csv', csvContents['database/students_import_template.csv']);
    }

    // ---- 16b. Optional modern/full-stack scaffold is assembled AFTER every
    // root file (including README and generated/uploaded logo) exists. Previous
    // versions copied too early, leaving modern/public without the logo.
    const includeModern = (config.buildType || '').toLowerCase() === 'modern';

    // ---- 16c. SUPABASE FREE-TIER PROTECTION KIT (automated for every client) ----
    // FIX SUPA-01: earlier builds mentioned keep-alive in docs but never shipped
    // the actual files, so client Supabase projects paused after 7 idle days.
    // Every ZIP now includes the full 4-layer kit:
    //   Layer 1: site-visit heartbeat (already inside app.js — zero setup)
    //   Layer 2: .github/workflows/keep-supabase-alive.yml (GitHub Actions, Mon+Thu)
    //   Layer 3: supabase/functions/ping (real DB write for UptimeRobot/cron)
    //   Layer 4: pg_cron job installed by database/keep-alive.sql (also embedded
    //            inside complete-schema.sql)
    for (const [src, dest] of [
      ['.github/workflows/keep-supabase-alive.yml', '.github/workflows/keep-supabase-alive.yml'],
      // V8.9: Layer 9 is now built into keep-supabase-alive.yml (self-commit);
      // Layer 10 auto-restore watchdog ships as its own workflow file.
      ['.github/workflows/supabase-auto-restore.yml','.github/workflows/supabase-auto-restore.yml'],
      ['api/keepalive.js',                          'api/keepalive.js'],
      ['vercel.json',                               'vercel.json'],
      ['database/keep-alive.sql',                   'database/keep-alive.sql'],
      // V5.9: File-Storage Archive Vault — private "archives" bucket so cold rows
      // can be offloaded from the 500 MB database into the 1 GB File Storage.
      ['database/storage-offload.sql',              'database/storage-offload.sql'],
      // V5.9: Google Drive one-click backup/restore + scheduled auto-sync
      ['database/drive-sync.sql',                   'database/drive-sync.sql'],
      ['docs/GOOGLE-DRIVE-SYNC-GUIDE.md',           'docs/GOOGLE-DRIVE-SYNC-GUIDE.md'],
      // V6.0 Sovereign Edition: runtime security settings + owner cockpit
      ['database/security-hardening.sql',           'database/security-hardening.sql'],
      ['database/v6.3-role-access-fixes.sql',       'database/v6.3-role-access-fixes.sql'],
      ['database/v6.4-hard-scope-fixes.sql',        'database/v6.4-hard-scope-fixes.sql'],
      ['database/branding-bucket.sql',              'database/branding-bucket.sql'],
      ['database/v6.9-report-score-save.sql',       'database/v6.9-report-score-save.sql'],
      ['database/demo-sample-data.sql',             'database/demo-sample-data.sql'],
      ['database/v7.0-clean-data-lifecycle.sql',    'database/v7.0-clean-data-lifecycle.sql'],
      ['database/v7.3-missing-policies.sql',        'database/v7.3-missing-policies.sql'],
      ['database/v7.5-rls-gap-and-self-service.sql','database/v7.5-rls-gap-and-self-service.sql'],
      ['database/v7.6-history-and-alumni.sql',      'database/v7.6-history-and-alumni.sql'],
      ['database/v7.7-promotion-department.sql',    'database/v7.7-promotion-department.sql'],
      ['database/v7.9-timetable-flex-and-class-scope.sql','database/v7.9-timetable-flex-and-class-scope.sql'],
      ['database/v8.2-voting-scope-and-dl.sql',      'database/v8.2-voting-scope-and-dl.sql'],
      ['database/v8.4-assignment-dl-points.sql',    'database/v8.4-assignment-dl-points.sql'],
      ['database/v8.5-payroll-net-fix.sql',         'database/v8.5-payroll-net-fix.sql'],
      ['database/v8.7-payroll-rebuild.sql',         'database/v8.7-payroll-rebuild.sql'],
      ['database/v9.0-user-lifecycle.sql',          'database/v9.0-user-lifecycle.sql'],
      ['database/v9.1-enterprise-pack.sql',         'database/v9.1-enterprise-pack.sql'],
      ['docs/SOVEREIGN-EDITION-V6.md',              'docs/SOVEREIGN-EDITION-V6.md'],
      ['docs/DISASTER-RECOVERY-RUNBOOK.md',         'docs/DISASTER-RECOVERY-RUNBOOK.md'],
      ['docs/ONBOARDING-GUIDE.md',                  'docs/ONBOARDING-GUIDE.md'],
      ['docs/SEO-AND-LEAD-GENERATION-GUIDE.md',     'docs/SEO-AND-LEAD-GENERATION-GUIDE.md'],
      ['docs/TERM-END-AND-HISTORY-GUIDE.md',        'docs/TERM-END-AND-HISTORY-GUIDE.md'],
      ['supabase/functions/ping/index.ts',          'supabase/functions/ping/index.ts'],
      ['SUPABASE_FREE_TIER_PROTECTION.md',          'SUPABASE_FREE_TIER_PROTECTION.md'],
      ['docs/FREE-TIER-CAPACITY-GUIDE.md',          'docs/FREE-TIER-CAPACITY-GUIDE.md']
    ]) {
      const content = await Generator.loadFile(src);
      if (content) zip.file(dest, content);
      else console.warn('[Generator] Free-tier protection file missing from generator host:', src);
    }

    // ---- 17. README with setup instructions ----
    zip.file('README.md', Generator.generateREADME(resolvedConfig));

    // ---- 18. Logo ----
    // FIX L-01: The wizard stores the uploaded logo as a base64 data URL in
    // config.logoData, but previous versions never wrote it into the ZIP —
    // every generated page referenced assets/img/logo.<ext> which did not
    // exist, producing a broken logo on the whole client site.
    // Now: decode the uploaded logo and write it as assets/img/logo.<ext>.
    // Always also include the generated SVG placeholder as a fallback.
    zip.file('assets/img/logo.svg', Generator.generateLogoSVG(resolvedConfig));
    const logoData = config.logoData || resolvedConfig.logoData;
    const logoExtOut = (resolvedConfig.logoExt || 'svg').toLowerCase();
    if (logoData && /^data:image\//.test(logoData) && logoExtOut !== 'svg') {
      try {
        const base64 = logoData.split(',')[1] || '';
        zip.file('assets/img/logo.' + logoExtOut, base64, { base64: true });
      } catch (e) {
        console.warn('[Generator] Could not embed uploaded logo:', e.message);
      }
    } else if (logoData && logoExtOut === 'svg' && /^data:image\/svg/.test(logoData)) {
      try {
        const b64 = logoData.split(',')[1] || '';
        zip.file('assets/img/logo.svg', atob(b64));
      } catch (e) { /* keep generated placeholder */ }
    }
    if (includeModern) await Generator.addModernScaffold(zip, resolvedConfig);

    // FIX RC-B (audit): post-build integrity sweep. Before finalising the ZIP,
    // scan every root-level .html page we emitted and flag any that has ZERO
    // inbound links from another page (a genuine orphan) or any page that links
    // to a file we did NOT emit (a broken link). This is what lets the generator
    // GUARANTEE an error-free, self-consistent site instead of silently shipping
    // dead pages or 404 nav links. Findings are surfaced via console and stored
    // on the returned object so the wizard/UI can show a report.
    const audit = await Generator.auditSiteIntegrity(zip, resolvedConfig);
    console.log('[Generator] Build complete. ZIP entries:', Object.keys(zip.files).length,
                '| orphans:', audit.orphans.length, '| broken links:', audit.brokenLinks.length);
    if (audit.orphans.length || audit.brokenLinks.length) {
      console.warn('[Generator] Integrity audit findings:', audit);
    }
    const blob = await zip.generateAsync({ type: 'blob', compression: 'DEFLATE', compressionOptions: { level: 6 } });
    const schoolSlug = (resolvedConfig.schoolName || 'school').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    const fileName = schoolSlug + '-school-connect.zip';
    return { blob, fileName, audit };
  },

  /**
   * FIX RC-B (audit): Post-build site integrity sweep.
   * Scans the in-memory ZIP for (a) orphan pages (root *.html with no inbound
   * link) and (b) broken internal links (href/src pointing at a file not in the
   * ZIP). Pure read-only over the zip's file map — never mutates the archive.
   * Returns { orphans:[...], brokenLinks:[...] }. Async because JSZip stores
   * page bodies as compressed blobs (read via file().async('string')).
   */
  async auditSiteIntegrity(zip, cfg) {
    const ALLOWED_ORPHANS = new Set([
      'offline.html',           // precached by sw.js, never nav-linked by design
      'exam_registrations.html' // deliberate underscore alias kept for legacy inbound links (see FIX NAV-3)
    ]);
    const names = Object.keys(zip.files).filter(n => !zip.files[n].dir);
    const fileSet = new Set(names);
    // V8.2: modern builds keep the single canonical portal under modern/public/ —
    // audit that set when the root has no html (traditional builds unchanged).
    let rootHtml = names.filter(f => /^[^/]+\.html$/.test(f));
    if (!rootHtml.length) rootHtml = names.filter(f => /^modern\/public\/[^/]+\.html$/.test(f));

    const linkRe = /(?:href|src)\s*=\s*["']([^"']+)["']/g;
    const inbound = new Map();   // target file -> count
    const brokenLinks = [];
    for (const name of names) {
      if (!/\.html$/.test(name)) continue;
      let raw = '';
      try { raw = await zip.file(name).async('string'); } catch (_) { continue; }
      const dir = name.includes('/') ? name.slice(0, name.lastIndexOf('/') + 1) : '';
      let m;
      while ((m = linkRe.exec(raw)) !== null) {
        let ref = m[1];
        if (/^(https?:|mailto:|tel:|wa\.me|sms:|data:|#|\/\/|javascript:)/i.test(ref)) continue;
        ref = ref.split('#')[0].split('?')[0];
        if (!ref || ref === '.') continue;
        const target = ref.startsWith('/') ? ref.slice(1) : (dir + ref);
        const clean = target.split('/').reduce((parts,part)=>{if(!part||part==='.')return parts;if(part==='..'){parts.pop();return parts;}parts.push(part);return parts;},[]).join('/');
        if (/\.(html|js|css|png|jpe?g|webp|svg|json|csv|xml|txt|ico|woff2?)$/i.test(clean)) {
          inbound.set(clean, (inbound.get(clean) || 0) + 1);
          if (!fileSet.has(clean) && !clean.startsWith('assets/templates/')) {
            brokenLinks.push({ from: name, to: clean });
          }
        }
      }
    }
    const orphans = rootHtml.filter(h => !ALLOWED_ORPHANS.has(h.split('/').pop()) && !(inbound.get(h) > 0));
    return { orphans, brokenLinks };
  },

  schoolSQL(content, cfg) {
    // FIX ADM-01 (#5): use the dedicated admissionAcronym (entered in the wizard)
    // so generated admission numbers always begin with the school's acronym.
    const acronym = (cfg.admissionAcronym || cfg.shortName || cfg.schoolName || 'SCH').toString().toUpperCase().replace(/[^A-Z0-9]/g,'').slice(0,8) || 'SCH';
    const staffAcronym = (cfg.staffAcronym || acronym).toString().toUpperCase().replace(/[^A-Z0-9]/g,'').slice(0,8) || acronym;
    return String(content || '')
      .replace(/admission_prefix text default 'STD'/g, "admission_prefix text default '" + acronym + "'")
      .replace(/admission_prefix text default 'SCH'/g, "admission_prefix text default '" + acronym + "'")
      .replace(/s\.admission_prefix := 'STD'/g, "s.admission_prefix := '" + acronym + "'")
      .replace(/s\.admission_prefix := 'SCH'/g, "s.admission_prefix := '" + acronym + "'")
      .replace(/coalesce\(s\.admission_prefix,'STD'\)/g, "coalesce(s.admission_prefix,'" + acronym + "')")
      .replace(/coalesce\(s\.admission_prefix,'SCH'\)/g, "coalesce(s.admission_prefix,'" + acronym + "')")
      .replace(/staff_prefix text default 'STF'/g, "staff_prefix text default '" + staffAcronym + "'")
      .replace(/coalesce\(pfx,'STF'\)/g, "coalesce(pfx,'" + staffAcronym + "')")
      // ENTERPRISE V11 (issue 8): make the v11 row-backfill install the school acronym directly
      .replace(/update public\.school_settings\s+set admission_prefix = v_default/g, "update public.school_settings set admission_prefix = '" + acronym + "'")
      .replace(/short_name text not null default 'SCH'/g, "short_name text not null default '" + acronym + "'")
      .replace(/admission_acronym text not null default 'SCH'/g, "admission_acronym text not null default '" + acronym + "'")
      .replace(/admission_prefix text not null default 'SCH'/g, "admission_prefix text not null default '" + acronym + "'")
      .replace(/staff_prefix text not null default 'SCH'/g, "staff_prefix text not null default '" + staffAcronym + "'")
      .replace(/values \('My School','SCH','SCH'\)/g, "values ('" + (cfg.schoolName || 'My School').replace(/'/g, "''") + "','" + (cfg.shortName || acronym).replace(/'/g, "''") + "','" + acronym + "')")
      // v13 ENT-BILL: subscription builds seed their license row (signature pre-computed async in buildPortal → cfg._licenseSig)
      .replace(/insert into public\.site_license \(id, model, plan, cycle, started_on, expires_on, grace_days, status, renew_url, lock_message, signature\)\s*\nvalues \(1, 'lifetime', 'One-time purchase \(lifetime ownership\)', '', current_date, null, 7, 'active', '', '', ''\)/g,
        cfg.licenseModel === 'subscription'
          ? "insert into public.site_license (id, model, plan, cycle, started_on, expires_on, grace_days, status, renew_url, lock_message, signature)\nvalues (1, 'subscription', '" + String(cfg.licensePlan || 'Subscription').replace(/'/g, "''") + "', '" + String(cfg.licenseCycle || '').replace(/'/g, "''") + "', " + (cfg.licenseStart ? "'" + cfg.licenseStart + "'" : 'current_date') + ", " + (cfg.licenseExpires ? "'" + cfg.licenseExpires + "'" : 'null') + ", " + (cfg.licenseGrace == null ? 7 : (+cfg.licenseGrace || 0)) + ", 'active', '" + String(cfg.licenseRenewUrl || '').replace(/'/g, "''") + "', '" + String(cfg.licenseLockMsg || '').replace(/'/g, "''") + "', '" + String(cfg._licenseSig || '') + "')"
          : "insert into public.site_license (id, model, plan, cycle, started_on, expires_on, grace_days, status, renew_url, lock_message, signature)\nvalues (1, 'lifetime', 'One-time purchase (lifetime ownership)', '', current_date, null, 7, 'active', '', '', '')");
  },

  /** v13 ENT-DEMO: step-by-step demo-deployment guide bundled into demo ZIPs. */
  demoSetupMd(cfg) {
    const name = cfg.schoolName || 'School Connect Demo';
    return `# Demo Deployment Guide — ${name}

This ZIP is a **DEMO build**: it lets prospective clients explore a complete,
fully-simulated school instantly — no sign-up or data entry needed.

## What is inside
- Everything a production School Connect ZIP contains.
- \`database/demo-users.sql\` (**v6, adopt-only**) — heals the five guest
  accounts' portal profiles to the correct role + approved status (this is the
  fix for the "Account pending approval" screen) and confirms the emails.
  It deliberately creates NO auth users and touches NO passwords — see
  "Hard-won rules" below.
- \`database/demo-seed.sql\` — a complete simulated school: 18 students,
  8 staff, parent links, fee structures & payments, attendance, check-ins,
  results + report-card columns/scores/comments/traits, a published CBT exam
  with real questions + submissions, polls, announcements, gallery, diary,
  conduct, health, assignments, lesson plans, survey, leave, visitors,
  helpdesk, hostel, staff clock-ins, timetable data, shop products and ID cards.
- \`assets/js/demo.js\` — renders the one-tap "Explore as Guest" panel on the
  login page and the slim demo ribbon everywhere else.

## Guest logins (also shown on the login page)
| Role | Email | Password |
|------|-------|----------|
| Admin | admin@scdemo.school | Demo#Admin1 |
| Teacher | teacher@scdemo.school | Demo#Teach1 |
| Parent | parent@scdemo.school | Demo#Parent1 |
| Student | student@scdemo.school | Demo#Study1 |
| Bursar | bursar@scdemo.school | Demo#Bursar1 |

## Deploy in 7 steps (~10 minutes, 100% free tier)
1. Create a free Supabase project → open its **SQL Editor**.
2. Run **database/complete-schema.sql** once (self-contained, idempotent).
3. Create the five guest accounts: Dashboard → **Authentication → Users →
   "Add user"** × 5 with the emails + passwords in the table above and
   **"Auto Confirm User" ON**. (~1 minute. This is the ONLY supported way —
   see the rules below.)
4. Run **database/demo-users.sql** v6 once → approves the five profiles
   (kills the "Account pending approval" screen) and confirms the emails.
   It FAILS VISIBLY if any account from step 3 is missing.
5. Run **database/demo-seed.sql** once → loads the simulated school
   (links everything to the accounts BY EMAIL; also works with zero
   accounts — links appear once accounts exist).
6. Edit **assets/js/config.js**: paste your Supabase URL + anon key.
7. Deploy to your preferred platform — Vercel / Netlify /
   Cloudflare Pages — and share the link with your prospect.

## Hard-won rules (probed live on the newest hosted GoTrue, 2026-07-23)
1. **Dashboard "Add user" does NOT validate email domains** — @scdemo.school
   works fine and never touches a real inbox.
2. **Password login does NOT validate domains either** — Dashboard-created
   @scdemo.school accounts sign in with JWTs. Only the PUBLIC SIGNUP API
   validates domains, and demo guests never sign up — they log in.
3. **SQL-created auth rows cannot log in** on these projects ("Invalid login
   credentials"), no matter how careful the INSERT — that is why v6 creates
   none. Older script versions (v1–v5) that create users in SQL must not be
   used for account creation.
4. **SQL-written passwords break healthy Dashboard accounts** — v6 never
   touches passwords. Set/repair them in Dashboard → Users → Edit user.
5. Dashboard "Add user" failing with **"Database error checking email" /
   "finding user"** means the email ALREADY EXISTS as a row GoTrue cannot
   parse (an old SQL script created it). It is NOT a domain rejection. Fix:
   delete that row (Dashboard → Users → ⋯ → Delete user), re-add natively,
   run v6.
6. The signup trigger defaults every new profile to *pending student* —
   the "Account pending approval" screen. v6 cures exactly that.

## Troubleshooting: "Demo login failed"
The login panel shows the *real* error with a matching fix. In short:
| Error text | Cause → Fix |
|---|---|
| "Account pending approval" | Profiles defaulted to pending student → run **demo-users.sql v6** once. |
| \`Invalid login credentials\` | Account missing or password differs → Dashboard → Users → create it, or **Edit user → set password** to the table above (Auto Confirm ON), then v6. |
| \`Database error querying schema\` / \`unexpected_failure\` (500) | A leftover SQL-created row from demo-users.sql v1–v5 → Dashboard → Users → **delete** it, re-add natively (Auto Confirm ON), run v6. |
| \`Failed to create user: Database error checking email\` (Dashboard) | Same thing: the email already exists as an unreadable SQL row → delete it first, then Add user. |
| \`Email not confirmed\` | → re-run v6 (confirms), or Dashboard → Edit user → Confirm email. |
| \`Failed to fetch\` / network | → wrong SUPABASE_URL / anon key in \`assets/js/config.js\`. |
| project paused / 503 | → free projects pause after ~7 idle days: Supabase dashboard → **Restore project**. |
| Public "sign up" rejects an email | Expected on fake domains (signup API validates domains) — visitors should use the five guest logins above, not sign up. |

Quick health check (SQL Editor — should return 5 rows, all confirmed +
approved):
\`\`\`sql
select u.email, (u.email_confirmed_at is not null) as confirmed, p.role, p.status
  from auth.users u left join public.profiles p on p.id = u.id
 where u.email like '%@scdemo.school' order by u.email;
\`\`\`

## Refreshing / resetting the demo
All three SQL files are idempotent — re-running demo-seed.sql only tops up
what is missing (it never deletes rows visitors created). To reset completely:
Supabase → **Table Editor** → delete rows from the transactional tables
(students, staff, results, fee_payments, attendance, cbt_results, …) and
re-run demo-seed.sql.

## Notes for HMG
- Demo data is synthetic; banners remind visitors not to enter real data.
- The demo build runs the same license engine as production; demo deployments
  are generated with a **lifetime demo license** so they never lock.
- All guest accounts are ordinary rows in \`auth.users\` + \`profiles\`; you can
  suspend them any time on the Approvals page.
`;
  },

  /** v13 ENT-BILL: SHA-256 signature for the seeded subscription license row (same formula as license.js). */
  async computeLicenseSignature(cfg) {
    if (cfg.licenseModel !== 'subscription') return '';
    try {
      var txt = [ 'subscription', cfg.licenseExpires || '', (cfg.licenseGrace == null ? 7 : (+cfg.licenseGrace || 0)), 'active', cfg.licenseSalt || '' ].join('|');
      var buf = await (window.crypto || crypto).subtle.digest('SHA-256', new TextEncoder().encode(txt));
      return Array.prototype.map.call(new Uint8Array(buf), function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
    } catch (e) { return ''; }
  },

  staticSimplePage(cfg, filename) {
    return Generator.fallbackPage(filename.replace('.html',''));
  },

  /** Replace demo branding in copied specialised static pages. */
  sanitizeStaticPage(html, cfg) {
    if (Generator.isBadRemoteContent(html)) return '';
    const safeName = cfg.schoolName || 'School';
    const shortName = cfg.shortName || 'SC';
    const primary = cfg.themePrimary || cfg.primary || '#4f46e5';
    const accent = cfg.themeAccent || cfg.accent || '#06b6d4';
    const themeId = cfg.themeId || 'default';
    const fontId = cfg.fontId || (cfg.font && cfg.font.id) || 'inter';
    const hmgLink = cfg.hmgLink || 'https://hmgconcepts.pages.dev/';
    const ext = (cfg.logoExt || 'svg').toLowerCase();
    const mime = ext === 'svg' ? 'image/svg+xml' : 'image/' + (ext === 'jpg' ? 'jpeg' : ext);
    return String(html || '')
      // FIX META-01: earlier template snapshots contained literal "$1" regex
      // artifacts in <meta keywords>/<meta og:description>. Scrub them so no
      // generated client page can ever ship a "$1" placeholder again.
      .replace(/<meta name="keywords" content="\$1">/g,
        '<meta name="keywords" content="' + safeName + ', school management, ' + shortName + ', HMG Concepts">')
      .replace(/content="\$1 — Comprehensive school management platform"/g,
        'content="' + safeName + ' — Comprehensive school management platform"')
      .replace(/School Connect Demonstration College/g, safeName)
      .replace(/School Connect Demo School/g, safeName)
      .replace(/God of Seed Academy/g, safeName)
      .replace(/Gosa Academy/g, safeName)
      .replace(/123 School Way, Lagos, Nigeria/g, cfg.address || '')
      .replace(/63B, Ishaga Abosule Street, Agbado Crossing, Ogun State/g, cfg.address || '')
      .replace(/\+234 800 123 4567/g, cfg.phone || '')
      .replace(/2348088667076/g, cfg.phone || '')
      .replace(/info@gosa\.edu\.ng/g, cfg.email || '')
      .replace(/godofseedacademy@gmail\.com/g, cfg.email || '')
      .replace(/Excellence in Learning and Character/g, cfg.schoolMotto || '')
      .replace(/\bSCD\b/g, shortName)
      .replace(/\bGOSA\b/g, shortName)
      .replace(/\bGoSA\b/g, shortName)
      .replace(/\bGSA\b/g, shortName)
      .replace(/#0506ae/gi, primary)
      .replace(/#0f2a43/gi, primary)
      .replace(/#1c72e7/gi, primary)
      .replace(/#7c3aed/gi, primary)
      .replace(/#964eec/gi, accent)
      .replace(/#d4af37/gi, accent)
      .replace(/#5e2174/gi, accent)
      .replace(/data-theme="theme15"/g, 'data-theme="' + themeId + '"')
      .replace(/data-font="plusjakarta"/g, 'data-font="' + fontId + '"')
      .replace(/data-font="inter"/g, 'data-font="' + fontId + '"')
      .replace(/--font:'Plus Jakarta Sans',system-ui,sans-serif/g, "--font:'" + ((cfg.font && cfg.font.family) || cfg.fontFamily || 'Inter') + "',system-ui,sans-serif")
      .replace(/--font:'Inter',system-ui,sans-serif/g, "--font:'" + ((cfg.font && cfg.font.family) || cfg.fontFamily || 'Inter') + "',system-ui,sans-serif")
      .replace(/font-family:'Plus Jakarta Sans',system-ui,-apple-system,sans-serif/g, "font-family:'" + ((cfg.font && cfg.font.family) || cfg.fontFamily || 'Inter') + "',system-ui,-apple-system,sans-serif")
      .replace(/font-family:'Inter',system-ui,-apple-system,sans-serif/g, "font-family:'" + ((cfg.font && cfg.font.family) || cfg.fontFamily || 'Inter') + "',system-ui,-apple-system,sans-serif")
      .replace(/family=Plus\+Jakarta\+Sans/g, 'family=' + encodeURIComponent((cfg.font && cfg.font.css) || cfg.fontFamily || 'Inter').replace(/%20/g,'+'))
      .replace(/family=Inter&/g, 'family=' + encodeURIComponent((cfg.font && cfg.font.css) || cfg.fontFamily || 'Inter').replace(/%20/g,'+') + '&')
      .replace(/https:\/\/hmgconcepts\.pages\.dev\//g, hmgLink)
      .replace(/assets\/img\/logo\.(png|jpe?g|webp|svg)/g, 'assets/img/logo.' + ext)
      .replace(/https:\/\/(1gosaportal|2gosaportal|schoolconnect)\.(vercel\.app|pages\.dev)\//g, './')
      // V7.0 SEO: point the structured-data URL at the school's real domain
      .replace(/"url": "https:\/\/schoolconnect\.example\/"/g, '"url": ' + JSON.stringify((cfg.siteUrl||'').replace(/\/+$/,'') + '/'))
      .replace(/type="image\/(png|jpeg|webp|svg\+xml)"(\s+href="assets\/img\/logo\.)/g, 'type="' + mime + '"$2')
      .replace(/logoExt: '(png|jpe?g|webp|svg)'/g, "logoExt: '" + ext + "'")
      // FIX META-02: removed the old no-op "SEO" replaces (<title>$1</title> etc.)
      // — they did nothing and their $1-style templates were the origin of the
      // literal "$1" artifacts that leaked into shipped pages.
      ;
  },

  /** Generate the school-specific config.js */
  generateConfigJS(cfg, wizardConfig) {
    return `/**
 * ${cfg.schoolName} — School Connect Configuration
 * School Management Platform Configuration
 * ============================================================
 * SETUP: Replace YOUR_SUPABASE_URL and YOUR_SUPABASE_ANON_KEY
 * with your actual Supabase project credentials.
 * Enable Row-Level Security (RLS) on all tables in Supabase.
 * Run database/complete-schema.sql once in your Supabase SQL Editor. It is the self-contained fresh-install schema, including RLS, report cards, CBT, voting, enterprise modules and V3 enhancements.
 * ============================================================
 */
window.SC = window.SC || {};
window.SCHOOL = {
  name: ${JSON.stringify(cfg.schoolName)},
  shortName: ${JSON.stringify(cfg.shortName)},
  motto: ${JSON.stringify(cfg.schoolMotto)},
  theme: ${JSON.stringify({ id: cfg.themeId, primary: cfg.themePrimary, accent: cfg.themeAccent })},
  layout: ${JSON.stringify(cfg.layout)},
  font: ${JSON.stringify(cfg.font)},
  address: ${JSON.stringify(cfg.address || '')},
  phone: ${JSON.stringify(cfg.phone || '')},
  email: ${JSON.stringify(cfg.email || '')},
  siteUrl: ${JSON.stringify(cfg.siteUrl || '')},
  campuses: ${JSON.stringify(cfg.campuses || [])},
  hmgLink: ${JSON.stringify(cfg.hmgLink || 'https://hmgconcepts.pages.dev/')},
  logoExt: ${JSON.stringify(cfg.logoExt || 'svg')},
  primary: ${JSON.stringify(cfg.themePrimary || '#4f46e5')},
  accent: ${JSON.stringify(cfg.themeAccent || '#06b6d4')},
  currency: ${JSON.stringify(cfg.currency || '₦')},
  admissionAcronym: ${JSON.stringify(cfg.admissionAcronym || 'SCH')},
  // v13 ENT-BILL: site license & subscription — evaluated on every page by assets/js/license.js.
  // 'lifetime' = one-time payment, client owns the site forever.
  // 'subscription' = recurring; after expires_on + grace_days the portal locks until renewal.
  license: ${JSON.stringify({ model: cfg.licenseModel || 'lifetime', plan: cfg.licensePlan || '', cycle: cfg.licenseCycle || '', started_on: cfg.licenseStart || '', expires_on: cfg.licenseExpires || null, grace_days: cfg.licenseGrace == null ? 7 : +cfg.licenseGrace || 0, status: 'active', renew_url: cfg.licenseRenewUrl || '', lock_message: cfg.licenseLockMsg || '' })},
  licenseRegistryUrl: ${JSON.stringify(cfg.licenseRegistryUrl || '')},
  licenseSalt: ${JSON.stringify(cfg.licenseSalt || '')},
  // v13 ENT-DEMO: prospective-client demo deployment (guest explorer + seeded sample data).
  demo: ${JSON.stringify(cfg.demoMode ? { enabled: true, note: 'Interactive demo — sample data only, resets periodically. Do not enter real student data.' } : { enabled: false })}
};
window.SC.THEMES = ${JSON.stringify(typeof SC !== 'undefined' && SC.THEMES ? SC.THEMES : [])};
window.SC.MODULES = ${JSON.stringify(typeof SC !== 'undefined' && SC.MODULES ? SC.MODULES : [])};
window.SC.esc = function(s) {
  return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
};
window.SC.jsStr = function(s) {
  return JSON.stringify(String(s==null?'':s));
};
window.SC.slugify = function(s) {
  return String(s||'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
};

// Supabase client initialization
const SUPABASE_URL = ${JSON.stringify(wizardConfig.supabaseUrl || 'YOUR_SUPABASE_URL')};
const SUPABASE_ANON_KEY = ${JSON.stringify(wizardConfig.supabaseKey || 'YOUR_SUPABASE_ANON_KEY')};

// Always expose a safe global so offline/demo pages and unconfigured portals never throw ReferenceError.
window.sb = null;
var sb = null;

// Initialize Supabase only if properly configured and the CDN client is available.
if (SUPABASE_URL && SUPABASE_URL !== 'YOUR_SUPABASE_URL' && !SUPABASE_URL.includes('YOUR_') && window.supabase && SUPABASE_ANON_KEY && !SUPABASE_ANON_KEY.includes('YOUR_')) {
  window.sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true }
  });
  sb = window.sb;
  console.log('[School Connect] Connected to Supabase at', SUPABASE_URL);
} else {
  console.warn('[School Connect] Supabase not configured or Supabase CDN unavailable. Edit assets/js/config.js with your credentials.');
}

// ============================================================
// FREE NOTIFICATION CHANNELS — enabled by default
// These use device-native links (mailto:, wa.me:, sms:) and require no third-party messaging API key.
// ============================================================
window.SC_CONFIRM_FREE_EMAIL = true;
window.SC_CONFIRM_FREE_WA = true;
window.SC_CONFIRM_FREE_SMS = true;

// ============================================================
// OPTIONAL: Custom VAPID keys for push notifications
// Generate at: https://web-push-codelab.glitch.me/
// ============================================================
// window.SC.VAPID_PUBLIC = 'YOUR_VAPID_PUBLIC_KEY';
// window.SC.VAPID_PRIVATE = 'YOUR_VAPID_PRIVATE_KEY';

// ============================================================
// IMPORTANT: Row-Level Security (RLS)
// The Supabase anon key is public by design — this is safe.
// BUT you MUST enable RLS on ALL tables in your Supabase project.
// The complete-schema.sql file enables RLS and creates appropriate policies.
// Without RLS, anyone can read/write any data.
// To verify RLS is on: Supabase Dashboard → Table Editor → select table → check "RLS" toggle
// ============================================================

console.log('[School Platform] Config loaded — ${cfg.schoolName}');
`;
  },

  /** Standard <script> tags for all generated pages (after T.shell() body close) */
  standardScripts() {
    return `<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<script src="assets/js/config.js"></script>
<script src="assets/js/license.js"></script>
<script src="assets/js/demo.js"></script>
<script src="assets/js/data-portability.js"></script>
<script src="assets/js/notifications.js"></script>
<script src="assets/js/voting.js"></script>
<script src="assets/js/pwa-install.js"></script>
<script src="assets/js/site-help.js"></script>
<script src="assets/js/super.js"></script>
<script src="assets/js/enterprise.js"></script>
<script src="assets/js/crud.js"></script>
<script src="assets/js/app.js"></script>`;
  },

  /** Standard boot script (service worker + module init) */
  standardBoot() {
    return `<script>
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').then(reg => {
    if (window.Notifications) Notifications.init(sb, reg);
    if (window.Voting) Voting.init(sb);
  }).catch(e => console.warn('SW registration failed:', e.message));
} else {
  if (window.Notifications) Notifications.init(sb);
  if (window.Voting) Voting.init(sb);
}
if (window.PWAInstall) PWAInstall.init();
if (window.Super) Super.init(sb, window.SCHOOL);
if (window.Enterprise) Enterprise.init(sb);
if (window.CRUD) CRUD.init(sb);
</script>`;
  },

  /** Landing page content (index.html body) */
  indexContent(cfg) {
    // FIX X-01: school name/motto are now HTML-escaped everywhere they are
    // interpolated (a name containing quotes or angle brackets previously
    // produced broken/injectable markup on the landing page).
    const esc = s => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    const name = esc(cfg.schoolName);
    const motto = esc(cfg.schoolMotto);
    const acronym = (cfg.admissionAcronym || cfg.shortName || 'SCH').toString().toUpperCase().replace(/[^A-Z0-9]/g,'');
    const base = String(cfg.siteUrl || '').replace(/\/+$/,'');
    const orgLD = {
      "@context":"https://schema.org",
      "@type":"EducationalOrganization",
      "name": cfg.schoolName,
      "alternateName": cfg.shortName,
      "slogan": cfg.schoolMotto,
      ...(base ? {"url": base} : {}),
      ...(cfg.phone ? {"telephone": cfg.phone} : {}),
      ...(cfg.email ? {"email": cfg.email} : {}),
      ...(cfg.address ? {"address":{"@type":"PostalAddress","streetAddress": cfg.address}} : {}),
      "application": {
        "@type":"SoftwareApplication",
        "name":"School Connect",
        "applicationCategory":"EducationApplication",
        "operatingSystem":"Web, Android, iOS (PWA)",
        "offers":{"@type":"Offer","price":"0","priceCurrency": cfg.currency || 'NGN'},
        "publisher":{"@type":"Organization","name":"HMG Concepts","url":"https://hmgconcepts.pages.dev/"}
      }
    };
    const contactBits = [
      cfg.address ? `<li>📍 ${esc(cfg.address)}</li>` : '',
      cfg.phone ? `<li>📞 <a href="tel:${esc(cfg.phone)}">${esc(cfg.phone)}</a></li>` : '',
      cfg.email ? `<li>✉️ <a href="mailto:${esc(cfg.email)}">${esc(cfg.email)}</a></li>` : ''
    ].join('');
    return `
<script type="application/ld+json">${JSON.stringify(orgLD)}</script>
${Generator.bellAndBanner(cfg)}
<div style="min-height:100vh;display:flex;flex-direction:column">
  <nav class="nav">
    <div class="nav-inner">
      <div class="nav-logo">
        <img src="assets/img/logo.${cfg.logoExt || 'svg'}" alt="${name}" onerror="this.style.display='none'">
        <span>${name}</span>
      </div>
      <ul class="nav-links">
        <li><a href="about.html">About</a></li>
        <li><a href="contact.html">Contact</a></li>
        <li><a href="apply.html">Admissions</a></li>
        <li><a href="login.html" class="btn-primary">Sign in</a></li>
      </ul>
      <button class="mobile-toggle" onclick="document.querySelector('.nav-links').classList.toggle('show')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 6h16M4 12h16M4 18h16"/></svg>
      </button>
    </div>
  </nav>

  <div class="hero">
    <div class="hero-badge">🏫 HMG Concepts Ecosystem Tool</div>
    <h1>Welcome to <span class="highlight">${name}</span></h1>
    <p class="hero-sub">${motto || 'A secure school management portal provisioned by HMG Concepts.'}</p>
    <div class="hero-actions">
      <a href="login.html" class="btn-hero btn-hero-primary">🔐 Sign in to Portal</a>
      <a href="apply.html" class="btn-hero btn-hero-secondary">📝 Apply for Admission</a>
      <a href="about.html" class="btn-hero btn-hero-secondary">ℹ️ Learn More</a>
    </div>
  </div>

  <div class="section">
    <div class="section-head">
      <span class="section-eyebrow">FEATURES</span>
      <h2 class="section-title">Everything your school needs</h2>
      <p class="section-sub">From admissions to report cards, CBT exams to payroll — in one HMG Concepts platform.</p>
    </div>
    <div class="grid grid-3" style="max-width:1000px;margin:0 auto">
      <div class="card"><div class="card-icon">👨‍🎓</div><h3>Student Management</h3><p>Complete register, CSV import, profile photos, and class grouping.</p></div>
      <div class="card"><div class="card-icon">📊</div><h3>Results &amp; Report Cards</h3><p>CA + exam scores, broadsheets, printable report cards.</p></div>
      <div class="card"><div class="card-icon">💻</div><h3>CBT / Online Exams</h3><p>17 question types, anti-cheat, auto-grade, certificates.</p></div>
      <div class="card"><div class="card-icon">📋</div><h3>Attendance</h3><p>Daily tracking, QR check-in, CSV export.</p></div>
      <div class="card"><div class="card-icon">💰</div><h3>Fees &amp; Finance</h3><p>Payment recording, balance tracking, printable receipts.</p></div>
      <div class="card"><div class="card-icon">💼</div><h3>HR &amp; Payroll</h3><p>Staff directory, payslips, loans, bonuses, appraisals.</p></div>
      <div class="card"><div class="card-icon">📢</div><h3>Announcements</h3><p>Priority notices, pinned alerts, audience targeting.</p></div>
      <div class="card"><div class="card-icon">🗳️</div><h3>Voting &amp; Polls</h3><p>Class elections, head boy/girl contests, live results.</p></div>
      <div class="card"><div class="card-icon">🔔</div><h3>Push Notifications</h3><p>Browser + email + WhatsApp + SMS — through configured channels.</p></div>
    </div>
  </div>

  <div class="footer">
    <div class="footer-grid">
      <div class="footer-brand">
        <h4>${name}</h4>
        <p>${motto || 'Excellence in Education'}</p>
        ${contactBits ? `<ul style="list-style:none;padding:0;margin-top:10px">${contactBits}</ul>` : ''}
      </div>
      <div>
        <h5>Quick Links</h5>
        <ul>
          <li><a href="login.html">Sign in</a></li>
          <li><a href="apply.html">Admissions</a></li>
          <li><a href="contact.html">Contact</a></li>
        </ul>
      </div>
      <div>
        <h5>Resources</h5>
        <ul>
          <li><a href="feature-guide.html">Feature Guide</a></li>
          <li><a href="verify-certificate.html">Verify Certificate</a></li>
          <li><a href="ecosystem.html">HMG Ecosystem</a></li>
          <li><a href="hmg-ecosystem.html">HMG Services</a></li>
        </ul>
      </div>
      <div>
        <h5>Powered By</h5>
        <ul>
          <li><a href="https://hmgconcepts.pages.dev/" target="_blank" rel="noopener">HMG Concepts</a></li>
          <li><a href="https://supabase.com" target="_blank" rel="noopener">Supabase</a></li>
          
        </ul>
      </div>
    </div>
    <div class="footer-bottom">
      © ${new Date().getFullYear()} ${name} · Developed by <a href="https://hmgtechnologies.pages.dev" target="_blank" rel="noopener" style="color:#94a3b8">HMG Technologies</a>
    </div>
  </div>
</div>
`;
  },

  bellAndBanner(cfg) {
    // FIX L-02: install banner previously hard-coded logo.svg even when the
    // school logo is a PNG/JPG.
    const logoExt = (cfg && cfg.logoExt) || 'svg';
    return `<div id="notif-bell" class="notif-bell" title="Notifications" data-chatbot>
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg>
  <span id="notif-badge" class="notif-badge" style="display:none">0</span>
  <div id="notif-dropdown" class="notif-dropdown"><div style="padding:16px 20px;border-bottom:1px solid var(--gray-200)"><strong>Notifications</strong></div><div id="notif-list"><div class="toast-msg" style="padding:24px;text-align:center">Loading…</div></div></div>
</div>
<div id="pwa-install-banner" class="pwa-install">
  <div class="pwa-install-header">
    <img src="assets/img/logo.${logoExt}" alt="" class="pwa-install-icon">
    <div style="flex:1">
      <div class="pwa-install-title">📲 Install School Connect</div>
      <div class="pwa-install-msg">Get push notifications for messages and announcements.</div>
    </div>
    <button class="modal-close" data-pwa-action="dismiss">×</button>
  </div>
  <div class="pwa-install-actions">
    <button class="btn btn-outline btn-sm" data-pwa-action="never">Not now</button>
    <button class="btn btn-primary btn-sm" data-pwa-action="install">Install App</button>
  </div>
</div>
<div id="toast-container" class="toast-container"></div>`;
  },

  /** Fallback minimal page when template generation fails */
  fallbackPage(name) {
    return `<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>${name} — School Connect</title>
<link rel="stylesheet" href="assets/css/style.css">
</head><body>
<div class="app-layout sidebar">
  <aside class="app-sidebar">
    <div class="app-brand"><strong>School Connect</strong></div>
    <nav class="app-nav">
      <a href="dashboard.html">🏠 Dashboard</a>
      <a href="about.html">ℹ️ About</a>
      <a href="contact.html">☎️ Contact</a>
    </nav>
  </aside>
  <main class="app-main">
    <header class="app-topbar"><h1 class="app-page-title">${name}</h1></header>
    <div class="app-content">
      <div class="card">
        <h3>⚠️ Setup Required</h3>
        <p>This module requires database configuration. Please set up Supabase and run the schema SQL files.</p>
        <p>See the README.md file in your downloaded package for setup instructions.</p>
      </div>
    </div>
  </main>
</div>
<script src="assets/js/config.js"></script>
<script src="assets/js/app.js"></script>
</body></html>`;
  },

  /** Generate PWA manifest.json */
  generateManifest(cfg) {
    // FIX M-01: start_url must be relative ('./index.html') so the PWA works when
    // deployed under a sub-path (e.g. GitHub Pages project sites), and the icon
    // must honour the uploaded logo extension (png/jpg/svg) instead of a
    // hard-coded logo.svg that may not exist in the ZIP.
    const logoExt = cfg.logoExt || 'svg';
    const iconType = logoExt === 'svg' ? 'image/svg+xml' : 'image/' + (logoExt === 'jpg' ? 'jpeg' : logoExt);
    const icons = logoExt === 'svg'
      ? [{ src: 'assets/img/logo.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any maskable' }]
      : [
          { src: 'assets/img/logo.' + logoExt, sizes: '192x192', type: iconType, purpose: 'any maskable' },
          { src: 'assets/img/logo.' + logoExt, sizes: '512x512', type: iconType, purpose: 'any maskable' }
        ];
    return JSON.stringify({
      name: cfg.schoolName,
      short_name: cfg.shortName || cfg.schoolName,
      description: (cfg.schoolMotto || 'School Management Portal') + ' — Powered by School Connect',
      start_url: './index.html',
      scope: './',
      display: 'standalone',
      background_color: '#ffffff',
      theme_color: cfg.themePrimary || '#0f172a',
      icons: icons
    }, null, 2);
  },

  /** Generate service worker with proper offline caching */
  generateServiceWorker(cfg) {
    // FIX S-08b: All URLs are now RELATIVE ('./...') instead of absolute
    // ('/...') so the PWA works when hosted under a sub-path (GitHub Pages
    // project sites — the deployment target the README recommends).
    // The precache list also honours the uploaded logo extension and
    // includes offline.html, and the cache name embeds the build date so
    // every regenerated site invalidates stale caches.
    const logoExt = (cfg && cfg.logoExt) || 'svg';
    const stamp = new Date().toISOString().slice(0, 10);
    return `/**
 * School Connect — Service Worker v8
 * Caches: HTML, CSS, JS, fonts, images. Offline fallback: offline.html.
 * Strategy: Cache-first for assets, network-first for HTML.
 */
const CACHE_NAME = 'sc-v8-${stamp}';
const PRECACHE_URLS = [
  './',
  './index.html',
  './login.html',
  './dashboard.html',
  './offline.html',
  './assets/css/style.css',
  './assets/js/config.js',
  './assets/js/app.js',
  './assets/js/crud.js',
  './assets/js/data-portability.js',
  './assets/js/drive-sync.js',
  './assets/js/security-guard.js',
  './assets/img/logo.${logoExt}',
  './manifest.json'
];

// Install: cache each shell asset independently. cache.addAll() is atomic,
// so one unavailable optional resource must not leave the offline cache empty.
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(async cache => {
    const results = await Promise.allSettled(PRECACHE_URLS.map(url => cache.add(url)));
    const failed = results.filter(r => r.status === 'rejected').length;
    if (failed) console.warn('[SW] Skipped', failed, 'unavailable precache resource(s)');
    await self.skipWaiting();
  }));
});

// Activate: clean up old caches
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
    )).then(() => self.clients.claim())
  );
});

// Fetch: cache-first for assets, network-first for navigation
self.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip cross-origin requests (CDN fonts, etc. handled separately)
  if (url.origin !== location.origin && !url.href.includes('fonts.googleapis') && !url.href.includes('fonts.gstatic')) {
    return;
  }

  // Navigation: network-first WITH A 4-SECOND TIMEOUT (ENTERPRISE V8, issue 14:
  // on slow/patchy networks the cached page is served instead of hanging),
  // falling back to cache, then offline.html.
  if (request.mode === 'navigate') {
    event.respondWith((async () => {
      const cached = await caches.match(request);
      try {
        const net = await Promise.race([
          fetch(request),
          new Promise((_, rej) => setTimeout(() => rej(new Error('slow-network')), 4000))
        ]);
        const clone = net.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
        return net;
      } catch (e) {
        if (cached) return cached;
        return (await caches.match('./offline.html')) || (await caches.match('./index.html'));
      }
    })());
    return;
  }

  // Assets: stale-while-revalidate (ENTERPRISE V8, issue 14) — serve the cached
  // copy INSTANTLY on slow networks while refreshing it in the background.
  if (request.method === 'GET') {
    event.respondWith(
      caches.match(request).then(cached => {
        const refresh = fetch(request).then(res => {
          if (res.ok) {
            const clone = res.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
          }
          return res;
        }).catch(() => cached);
        return cached || refresh;
      })
    );
  }
});

// Push notification handler
self.addEventListener('push', event => {
  try {
    const data = event.data ? event.data.json() : {};
    const title = data.title || 'School Connect';
    const body = data.body || 'You have a new notification';
    const icon = data.icon || './assets/img/logo.${logoExt}';
    const url = data.url || './';

    event.waitUntil(
      self.registration.showNotification(title, {
        body,
        icon,
        badge: './assets/img/logo.${logoExt}',
        data: { url },
        requireInteraction: false,
        vibrate: [200, 100, 200]
      })
    );
  } catch (e) {
    console.warn('[SW] Push handler failed:', e.message);
  }
});

// Notification click handler
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = event.notification.data?.url || './';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      for (const client of clientList) {
        if (client.url === url && 'focus' in client) return client.focus();
      }
      return clients.openWindow(url);
    })
  );
});

console.log('[SW] School Connect service worker loaded — v8');
`;
  },

  /** Generate offline.html fallback page (FIX S-09) */
  /** Alias kept for verify.sh compatibility (pageOffline). */
  pageOffline(cfg) { return Generator.generateOfflinePage(cfg); },

  generateOfflinePage(cfg) {
    const name = (cfg && cfg.schoolName) || 'School Connect';
    const primary = (cfg && cfg.themePrimary) || '#4f46e5';
    const esc = s => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Offline • ${esc(name)}</title>
<style>
body{font-family:system-ui,sans-serif;background:#f8fafc;color:#0f172a;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:20px;text-align:center}
.card{background:#fff;border:1px solid #e2e8f0;border-radius:18px;padding:40px 32px;max-width:420px;box-shadow:0 8px 24px rgba(15,23,42,.06)}
h1{font-size:1.4rem;margin:12px 0 8px}
p{color:#64748b;line-height:1.6}
.icon{font-size:3rem}
a{display:inline-block;margin-top:18px;background:${primary};color:#fff;text-decoration:none;padding:10px 22px;border-radius:10px;font-weight:700}
</style>
</head>
<body>
<div class="card">
  <div class="icon">📡</div>
  <h1>You are offline</h1>
  <p>${esc(name)} could not be reached. Check your internet connection — pages you visited before are still available.</p>
  <a href="./index.html" onclick="location.reload();return false">Try again</a>
</div>
</body>
</html>`;
  },

  /** Generate robots.txt */
  generateRobots(cfg) {
    // FIX R-01: "Disallow: /assets/js/*.js" blocked crawlers from rendering
    // the site properly (Google needs JS/CSS access) and the wildcard pattern
    // is non-standard. Also emit an absolute sitemap URL when known.
    const base = (cfg && cfg.siteUrl) ? String(cfg.siteUrl).replace(/\/+$/, '') : '';
    return `User-agent: *
Allow: /
Disallow: /database/

Sitemap: ${base ? base + '/sitemap.xml' : '/sitemap.xml'}
`;
  },

  /** Generate sitemap.xml */
  generateSitemap(cfg) {
    const base = ((cfg && cfg.siteUrl) ? String(cfg.siteUrl).replace(/\/+$/, '') : 'https://REPLACE-WITH-YOUR-DOMAIN.example');
    const publicPages = [
      { p: '/',                   cf: 'weekly',  pr: '1.0' },
      { p: '/about.html',         cf: 'monthly', pr: '0.8' },
      { p: '/contact.html',       cf: 'monthly', pr: '0.6' },
      { p: '/apply.html',         cf: 'weekly',  pr: '0.8' },
      { p: '/exam-register.html', cf: 'weekly',  pr: '0.7' },
      { p: '/login.html',         cf: 'monthly', pr: '0.5' },
      { p: '/feature-guide.html', cf: 'monthly', pr: '0.5' },
      { p: '/verify-certificate.html', cf: 'monthly', pr: '0.4' },
      { p: '/entrance.html',      cf: 'weekly',  pr: '0.6' },
      { p: '/hmg-ecosystem.html', cf: 'monthly', pr: '0.5' },
      { p: '/hmg-digital-products.html', cf: 'monthly', pr: '0.5' }
    ];
    return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${publicPages.map(u => `  <url><loc>${base}${u.p}</loc><changefreq>${u.cf}</changefreq><priority>${u.pr}</priority></url>`).join('\n')}
</urlset>`;
  },

  /** Generate _headers for Cloudflare Pages */
  generateHeaders() {
    return `# Security headers for School Connect
/*
  X-Frame-Options: SAMEORIGIN
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(self), microphone=(self), geolocation=(self)
  Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://accounts.google.com/gsi/client; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdnjs.cloudflare.com https://accounts.google.com/gsi/style; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https:; frame-src https://accounts.google.com/gsi/; connect-src 'self' https://*.supabase.co https://*.supabase.io wss://*.supabase.co https://accounts.google.com/gsi/ https://www.googleapis.com

/sw.js
  Cache-Control: public, max-age=0, must-revalidate

/*.html
  Cache-Control: public, max-age=0, must-revalidate

/assets/js/*
  Cache-Control: public, max-age=0, must-revalidate

/assets/css/*
  Cache-Control: public, max-age=3600, must-revalidate

/_headers
  Access-Control-Allow-Origin: *
`;
  },

  /** Generate vercel.json */
  generateVercelConfig() {
    // FIX GEO-01: Permissions-Policy now ALLOWS geolocation=(self) and camera=(self)
    // so staff geofenced check-in and the "capture school GPS" buttons work.
    // Previously geolocation=() hard-blocked them ("Geolocation has been disabled
    // in this document by permission policy").
    return JSON.stringify({
      headers: [
        {
          source: '/(.*)',
          headers: [
            { key: 'X-Frame-Options', value: 'SAMEORIGIN' },
            { key: 'X-Content-Type-Options', value: 'nosniff' },
            { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
            { key: 'Permissions-Policy', value: 'geolocation=(self), camera=(self), microphone=(self), payment=(), usb=(), bluetooth=()' }
          ]
        },
        {
          source: '/sw.js',
          headers: [
            { key: 'Cache-Control', value: 'public, max-age=0, must-revalidate' }
          ]
        },
        {
          source: '/assets/js/(.*)',
          headers: [
            { key: 'Cache-Control', value: 'public, max-age=0, must-revalidate' }
          ]
        },
        {
          source: '/(.*)\\.html',
          headers: [
            { key: 'Cache-Control', value: 'public, max-age=0, must-revalidate' }
          ]
        }
      ]
    }, null, 2);
  },

  /** Generate README with setup instructions */
  generateREADME(cfg) {
    return `# ${cfg.schoolName} — School Connect Portal

Developed by [HMG Technologies](https://hmgtechnologies.pages.dev).

## 🚀 Quick Setup

### 1. Create a Supabase Project
1. Go to [supabase.com](https://supabase.com) and create an approved project
2. Create a new project
3. Copy your **Project URL** and **anon public** key from: Settings → API

### 2. Configure Your Site
1. Open \`assets/js/config.js\`
2. Replace \`YOUR_SUPABASE_URL\` with your Project URL
3. Replace \`YOUR_SUPABASE_ANON_KEY\` with your anon key

### 3. Run the Complete Database Schema
1. In Supabase, go to **SQL Editor**.
2. Copy-paste and run **\`database/complete-schema.sql\` once**.
3. Wait for completion, then refresh the portal. This self-contained fresh-install file includes the tables, RLS policies, CBT, voting, report cards, enterprise modules, geofence fields, report traits/comments and V3 school-wide assessment-column support. The other SQL files are retained only as reference/upgrade artifacts; do not run them one by one on a new deployment.

### 4. Enable Row-Level Security (RLS)
All tables have RLS policies enabled. Each role sees only their data:
- **Students** see their own results, fees, attendance
- **Parents** see their linked children's data
- **Staff** see their classes' data
- **Admin/Super Admin** see all data

### 5. Deploy to GitHub Pages
1. Create a new GitHub repository
2. Upload all files from this package
3. Enable GitHub Pages (Settings → Pages → Source: main branch)
4. Your site will be live at: \`https://yourusername.github.io/repo-name\`

### 6. Supabase Free-Tier Protection (IMPORTANT — prevents 7-day pause)
Supabase pauses free projects after ~7 days without database activity. This package ships a fully automated 4-layer keep-alive:
1. **Automatic (no setup):** every site visit writes one heartbeat per day (\`assets/js/app.js\`), and a \`pg_cron\` job inside the database fires every 2 days (installed by \`complete-schema.sql\`).
2. **Recommended (2 minutes):** add repo secrets \`SUPABASE_URL\` and \`SUPABASE_ANON_KEY\` (Settings → Secrets and variables → Actions) to activate \`.github/workflows/keep-supabase-alive.yml\`.
3. Full details and verification query: see \`SUPABASE_FREE_TIER_PROTECTION.md\`.

## 📱 PWA Install
Users can install this as a mobile app via their browser's "Add to Home Screen".

## 🔔 Push Notifications
Push notifications require browser permission. Email, WhatsApp and SMS actions open the user’s configured device application; delivery depends on that service.

## 🛠️ Features
${(Array.isArray(cfg.modules) ? cfg.modules : []).map(m => `- ${m.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())}`).join('\n')}

## 📞 Support
- Feature Guide: \`feature-guide.html\`
- Developer: Adewale Samson Adeagbo (HMG Concepts)
- GitHub: https://github.com/hmgconcepts/schoolconnect

---
*Built with ❤️ by HMG Concepts — HMG Concepts Ecosystem enterprise school platform.*
`;
  },

  async addModernScaffold(zip, cfg) {
    // A modern delivery must contain the same working portal, not merely a
    // placeholder shell. MOVE the files assembled at ZIP root into Next.js
    // public/ — V8.2: previously they were COPIED, leaving the entire portal
    // duplicated at the ZIP root AND under modern/public (465 entries instead
    // of ~240, confusing "which copy do I deploy?"). The modern ZIP now has
    // ONE canonical portal (modern/public/) plus top-level guides.
    const portalFiles = [];
    zip.forEach((path, file) => { if (!file.dir && !path.startsWith('modern/')) portalFiles.push([path, file]); });
    const KEEP_AT_ROOT = /^(README\.md|DEPLOYMENT-GUIDE\.md|DEMO-SETUP\.md|CBT_AND_REPORTCARD_GUIDE\.md|SUPABASE_FREE_TIER_PROTECTION\.md|docs\/|database\/|samples\/|supabase\/|\.github\/)/;
    await Promise.all(portalFiles.map(async ([path, file]) => {
      const data = await file.async('uint8array');
      zip.file('modern/public/' + path, data);
      // keep top-level docs/database/ops folders at root for the school's DBA;
      // remove the duplicated site files (html/assets/config) from the root.
      if (!KEEP_AT_ROOT.test(path)) zip.remove(path);
    }));
    zip.file('README.md', '# ' + cfg.schoolName + ' — Modern full-stack delivery\n\nThe complete school portal lives in **modern/public/** and is served by the Next.js wrapper in **modern/**. Deploy the `modern/` folder (Vercel: set the project root to `modern`).\n\n- `modern/public/` — the whole generated portal (single canonical copy; no duplicates)\n- `database/` — run `complete-schema.sql` once in Supabase SQL Editor\n- `docs/` — operations guides (backups, term-end, capacity, SEO…)\n- `samples/` — sample documents\n- `.github/` — free keep-alive workflow (add repo secrets per SUPABASE_FREE_TIER_PROTECTION.md)\n\nQuick start: see DEPLOYMENT-GUIDE.md Part B, then `modern/README.md`.\n');
    zip.file('modern/README.md', '# '+cfg.schoolName+' — HMG Concepts Modern Delivery\n\nThis Next.js wrapper includes the complete generated static PWA under `public/`, so `/index.html` works immediately after deployment. It is an HMG Concepts controlled scaffold for future server APIs and tenant routing; it is not a claim that the browser-only portal has server-side business logic.\n\n## Run\n1. Copy `.env.example` to `.env.local` and set only public Supabase values. Never expose a service-role key in the browser.\n2. `npm install`\n3. `npm run build`\n4. `npm start` or deploy this `modern/` folder to Vercel.\n\nDatabase/RLS remains the authority for all portal data. No AI API is used.');
    zip.file('modern/package.json', JSON.stringify({private:true,scripts:{dev:'next dev',build:'next build',start:'next start'},dependencies:{'@supabase/supabase-js':'^2.49.0','next':'^14.2.0','react':'^18.3.0','react-dom':'^18.3.0'},devDependencies:{}}, null, 2));
    zip.file('modern/app/layout.jsx', "export const metadata={title:"+JSON.stringify(cfg.schoolName+" | HMG Concepts")+",robots:{index:false,follow:false}}; export default function RootLayout({children}){return <html lang='en'><body>{children}</body></html>}");
    zip.file('modern/app/page.jsx', "import {redirect} from 'next/navigation'; export default function Home(){redirect('/index.html')}");
    zip.file('modern/app/api/health/route.js', "export async function GET(){return Response.json({ok:true, product:'HMG Concepts School Connect modern delivery', time:new Date().toISOString()})}");
    zip.file('modern/middleware.js', "import {NextResponse} from 'next/server'; export function middleware(){const r=NextResponse.next();r.headers.set('X-Content-Type-Options','nosniff');r.headers.set('Referrer-Policy','strict-origin-when-cross-origin');return r}");
    zip.file('modern/app/api/tenant/route.js', "import {tenantFromHost} from '../../../lib/tenant'; export async function GET(req){return Response.json({tenant:tenantFromHost(req.headers.get('host')),mode:'HMG-controlled scaffold'})}");
    zip.file('modern/.env.example', 'NEXT_PUBLIC_SUPABASE_URL=\nNEXT_PUBLIC_SUPABASE_ANON_KEY=\n# Never place SUPABASE_SERVICE_ROLE_KEY in browser code or public/.\n');
    zip.file('modern/lib/supabase-browser.js', "import {createClient} from '@supabase/supabase-js'; export const supabase=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL||'',process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY||'');");
    zip.file('modern/lib/tenant.js', "export function tenantFromHost(host){const h=(host||'').split(':')[0];return h.split('.')[0]||'default'}");
    zip.file('modern/app/[tenant]/page.jsx', "import {redirect} from 'next/navigation'; export default function Tenant(){redirect('/index.html')}");
    zip.file('modern/database/tenant-schema.sql', "-- Optional future HMG multi-tenant extension. Do not run against the single-school portal without an approved migration plan.\ncreate table if not exists public.tenants (id uuid primary key default gen_random_uuid(),slug text unique not null,school_name text not null,active boolean default true,created_at timestamptz default now());\nalter table public.tenants enable row level security;");
  },

  /** Generate SVG logo placeholder */
  generateLogoSVG(cfg) {
    const primary = cfg.themePrimary || '#0f172a';
    const accent = cfg.themeAccent || '#d4af37';
    const initial = (cfg.shortName || cfg.schoolName || 'S')[0].toUpperCase();
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
  <rect width="200" height="200" rx="40" fill="${primary}"/>
  <text x="100" y="135" font-family="Arial, sans-serif" font-size="110" font-weight="900" text-anchor="middle" fill="${accent}">${initial}</text>
</svg>`;
  },

  /** Mock DOM environment for running templates.js in build context */
  mockDOM() {
    if (typeof document !== 'undefined') return;
    // Minimal document mock for Node.js-like environment
    const mockEl = (tag) => ({
      tagName: tag.toUpperCase(), children: [], innerHTML: '', textContent: '',
      style: {}, appendChild: () => {}, removeChild: () => {},
      getAttribute: () => '', setAttribute: () => {}, querySelectorAll: () => [],
      addEventListener: () => {}, classList: { toggle: () => {}, add: () => {}, remove: () => {} }
    });
    window.document = {
      querySelectorAll: () => [],
      createElement: (tag) => ({ tagName: tag.toUpperCase(), style: {}, appendChild: () => {}, setAttribute: () => {} }),
      getElementById: () => null,
      body: { appendChild: () => {} },
      readyState: 'complete',
      addEventListener: () => {}
    };
    window.location = { href: '/', pathname: '/index.html' };
    window.history = {};
  },

  loadScript(src) {
    return new Promise((resolve, reject) => {
      if (document.querySelector('script[src="' + src + '"]')) { resolve(); return; }
      const s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = () => reject(new Error('Failed to load: ' + src));
      document.head.appendChild(s);
    });
  },

  /** Export T.pageIndex for preview.js compatibility (FIX G-05) */
  pageIndex(cfg) {
    // T.pageIndex from templates.js is used by preview.js
    // Provide a fallback here
    if (window.T && window.T.pageIndex) return window.T.pageIndex(cfg);
    return Generator.generateIndexPage(cfg || {});
  },

  /** Generate the index page HTML string */
  generateIndexPage(cfg) {
    const schoolName = cfg.schoolName || 'School Portal';
    const shortName = cfg.shortName || schoolName;
    const primary = cfg.themePrimary || '#0f172a';
    const accent = cfg.themeAccent || '#d4af37';
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>${schoolName} — School Connect</title>
<link rel="stylesheet" href="assets/css/style.css">
</head>
<body>
<div style="min-height:100vh;display:flex;align-items:center;justify-content:center;background:var(--gradient)">
  <div style="background:white;padding:48px;border-radius:24px;max-width:480px;text-align:center;box-shadow:0 25px 50px rgba(0,0,0,.25)">
    <h1 style="font-size:2rem;font-weight:900;margin-bottom:8px">${schoolName}</h1>
    <p style="color:var(--gray-600);margin-bottom:24px">${cfg.schoolMotto || 'School Management Portal'}</p>
    <div style="display:flex;gap:12px;justify-content:center;flex-wrap:wrap">
      <a href="login.html" class="btn btn-primary btn-lg">🔐 Sign In</a>
      <a href="apply.html" class="btn btn-outline btn-lg">📝 Apply</a>
    </div>
    <p style="margin-top:24px;font-size:0.8rem;color:var(--gray-400)">Powered by <a href="https://hmgconcepts.pages.dev/" style="color:var(--primary)">HMG Concepts</a></p>
  </div>
</div>
</body>
</html>`;
  },

  /** Generate login page (used when T is not available) */
  generateLoginPage(cfg) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Sign in — ${cfg.schoolName}</title>
<link rel="stylesheet" href="assets/css/style.css">
</head>
<body>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="assets/js/config.js"></script>
<script src="assets/js/app.js"></script>
</body>
</html>`;
  },

  /** Generate dashboard page (used when T is not available) */
  generateDashboardPage(cfg) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Dashboard — ${cfg.schoolName}</title>
<link rel="stylesheet" href="assets/css/style.css">
</head>
<body>
<div class="app-layout sidebar">
  <aside class="app-sidebar">
    <div class="app-brand">
      <img src="assets/img/logo.${cfg.logoExt || 'svg'}" alt="${cfg.schoolName}">
      <strong>${cfg.schoolName}</strong>
    </div>
    <nav class="app-nav">
      <a href="dashboard.html" class="active">🏠 Dashboard</a>
      <a href="students.html">👨‍🎓 Students</a>
      <a href="staff.html">👨‍🏫 Staff</a>
      <a href="attendance.html">📋 Attendance</a>
      <a href="results.html">📊 Results</a>
      <a href="fees.html">💰 Fees</a>
    </nav>
  </aside>
  <main class="app-main">
    <header class="app-topbar">
      <h1 class="app-page-title">Dashboard</h1>
      <div style="margin-left:auto;display:flex;align-items:center;gap:12px">
        <div class="user-chip"><strong id="user-display-name">—</strong></div>
        <button class="btn btn-sm btn-outline" onclick="App.signOut()" data-signout style="display:none">Sign out</button>
      </div>
    </header>
    <div class="app-content">
      <div class="card" style="background:var(--gradient);color:white;margin-bottom:18px">
        <h2 style="color:white;margin:0">Welcome, <span id="dash-user-name">—</span></h2>
        <p style="opacity:.9;margin:4px 0 0">Role: <strong id="dash-user-role">—</strong></p>
        <div id="dash-quick-links" style="display:flex;gap:8px;flex-wrap:wrap;margin-top:14px"></div>
      </div>
      <div class="stats-grid">
        <div class="stat-card"><div class="stat-value" id="stat-students">—</div><div class="stat-label">Students</div></div>
        <div class="stat-card"><div class="stat-value" id="stat-staff">—</div><div class="stat-label">Staff</div></div>
        <div class="stat-card"><div class="stat-value" id="stat-fees">—</div><div class="stat-label">Fees Paid</div></div>
        <div class="stat-card"><div class="stat-value" id="stat-announcements">—</div><div class="stat-label">Notices</div></div>
      </div>
    </div>
  </main>
</div>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="assets/js/config.js"></script>
<script src="assets/js/notifications.js"></script>
<script src="assets/js/voting.js"></script>
<script src="assets/js/pwa-install.js"></script>
<script src="assets/js/super.js"></script>
<script src="assets/js/enterprise.js"></script>
<script src="assets/js/crud.js"></script>
<script src="assets/js/app.js"></script>
</body>
</html>`;
  },

/* ============================================================
   PRICING — itemised "Done-for-You" quote (platform is always FREE)
   Wired by Wizard.recalcQuote() in builder.html
   ============================================================ */
  PRICING: {
    currency: '₦',
    baseBuild: 35000,
    perModule: 4500,
    perDept: 1500,
    addons: [
      { id: 'deploy', name: 'Deploy & host for you', price: 15000 },
      { id: 'training', name: 'Staff training (3 hours)', price: 10000 },
      { id: 'data_import', name: 'Bulk data import', price: 8000 },
      { id: 'custom_domain', name: 'Custom domain setup', price: 5000 },
      { id: 'support', name: '3-month priority support', price: 5000 }
    ]
  },

  /** Generate an itemised quote from wizard config + selected add-ons. */
  estimate(config, addons) {
    const P = Generator.PRICING;
    const modules = Array.isArray(config.modules) ? config.modules : [];
    const depts = Array.isArray(config.departments) ? config.departments : [];
    const addOnTotal = (addons || []).reduce((s, id) => {
      const a = (P.addons || P.levels || []).find(l => l.id === id);
      return s + (a ? a.price : 0);
    }, 0);
    const lines = [
      { label: 'Base build & branding', amount: P.baseBuild },
      { label: modules.length + ' modules × ₦' + P.perModule, amount: modules.length * P.perModule },
      { label: depts.length + ' departments × ₦' + P.perDept, amount: depts.length * P.perDept }
    ];
    (addons || []).forEach(id => {
      const a = (P.addons || P.levels || []).find(l => l.id === id);
      if (a) lines.push({ label: a.name, amount: a.price });
    });
    return { lines, total: lines.reduce((s, l) => s + l.amount, 0), currency: P.currency };
  },

  /** Full interactive multi-page preview (FIX G-05 helper for fullPreview).
      Creates a self-contained HTML document with real page bodies from
      templates.js, injected CSS, and a mock Supabase client with demo data. */
  fullPreviewHtml(config) {
    const cfg = { ...config };
    if (!cfg.schoolName) cfg.schoolName = 'Preview School';
    const theme = (window.SC && window.SC.THEMES && window.SC.THEMES.find(t => t.id === cfg.themeId)) || window.SC.THEMES[0] || { primary: '#0f172a', accent: '#d4af37' };
    cfg.themePrimary = cfg.themePrimary || theme.primary || '#0f172a';
    cfg.themeAccent  = cfg.themeAccent  || theme.accent  || '#d4af37';

    // Mock Supabase demo data
    const demoData = {
      students: Array.from({ length: 8 }, (_, i) => ({
        id: 's' + i, admission_no: 'STD/' + (1001 + i),
        full_name: ['Grace Adeyemi','John Okoro','Mary Bello','Daniel Musa','Esther Obi','Samuel Eze','Ruth Ali','Peter Udo'][i],
        class_name: ['JSS 1A','JSS 2B','SSS 1A','SSS 2C','Primary 5','SSS 3A','JSS 1B','SSS 1C'][i],
        gender: i % 2 === 0 ? 'M' : 'F', status: 'active'
      })),
      staff: Array.from({ length: 5 }, (_, i) => ({
        id: 'st' + i, staff_no: 'STF/' + (2001 + i),
        full_name: ['Mrs. Bello','Mr. Eze','Mrs. Adebayo','Mr. Sule','Dr. Okonkwo'][i],
        role: i === 0 ? 'admin' : 'teacher', status: 'active'
      })),
      results: Array.from({ length: 12 }, (_, i) => ({
        id: 'r' + i, student_id: 's' + (i % 8),
        subject: ['Mathematics','English','Biology','Physics','Chemistry','Economics'][i % 6],
        term: 'First Term', ca_score: Math.floor(Math.random() * 30) + 5,
        exam_score: Math.floor(Math.random() * 50) + 20,
        grade: ['A','B','C','D'][i % 4]
      })),
      announcements: [
        { id: 'a1', title: 'Term begins Monday', body: 'All students must report by 7:30am', created_at: new Date().toISOString(), priority: 'high' },
        { id: 'a2', title: ' PTA meeting this Saturday', body: 'All parents please attend', created_at: new Date().toISOString(), priority: 'normal' }
      ],
      fee_payments: Array.from({ length: 6 }, (_, i) => ({
        id: 'f' + i, student_id: 's' + i,
        amount_paid: 75000, balance: i % 3 === 0 ? 0 : 15000,
        term: 'First Term', status: i % 3 === 0 ? 'paid' : 'partial'
      })),
      attendance: Array.from({ length: 20 }, (_, i) => ({
        id: 'at' + i, student_id: 's' + (i % 8),
        status: i % 5 === 0 ? 'absent' : 'present',
        date: new Date(Date.now() - i * 864e5).toISOString().slice(0, 10)
      })),
      polls: [{ id: 'p1', title: 'Head Boy Election 2026', status: 'open', audience: 'all', candidates: JSON.stringify([
        { id: 'c1', name: 'Adaeze Okeke', info: 'SSS 3A', photo: '' },
        { id: 'c2', name: 'Chidi Nwankwo', info: 'SSS 3A', photo: '' }
      ]) }],
      cbt_exams: [{ id: 'cbt1', title: 'Mathematics Quiz - Week 4', class_name: 'SSS 1A', subject: 'Mathematics', duration_min: 20, is_open: true, total_questions: 10 }]
    };

    const modules = Array.isArray(cfg.modules) ? cfg.modules : [];
    const navItems = (modules.length ? modules : ['dashboard','students','staff','attendance','results','fees','announcements','voting','cbt','library']).map(id => ({
      id,
      label: (window.T && window.T.labelFor) ? window.T.labelFor(id, id) : id.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase()),
      icon: (window.T && window.T.iconFor) ? window.T.iconFor(id) : '📄'
    }));

    const navHTML = navItems.map(m => `<div class="pv-nav-item" data-page="${m.id}">
      <span class="pv-nav-icon">${m.icon}</span>
      <span>${m.label}</span>
    </div>`).join('');

    const previewCSS = `
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body { font-family: var(--font, 'Inter'), system-ui, sans-serif; background: #f8fafc; color: #0f172a; }
      .pv-shell { display: flex; height: 100vh; }
      .pv-side { width: 240px; background: #0f172a; color: #fff; flex-shrink: 0; display: flex; flex-direction: column; }
      .pv-brand { padding: 16px; border-bottom: 1px solid #1e293b; display: flex; align-items: center; gap: 10px; }
      .pv-brand-name { font-weight: 800; font-size: 0.95rem; }
      .pv-nav { padding: 12px 8px; flex: 1; overflow-y: auto; }
      .pv-nav-item { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 8px; cursor: pointer; font-size: 0.88rem; margin-bottom: 2px; color: #94a3b8; transition: all .15s; }
      .pv-nav-item:hover { background: #1e293b; color: #fff; }
      .pv-nav-item.active { background: var(--primary, #4f46e5); color: #fff; }
      .pv-nav-icon { font-size: 1rem; width: 24px; text-align: center; }
      .pv-main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
      .pv-topbar { padding: 14px 24px; background: white; border-bottom: 1px solid #e2e8f0; display: flex; align-items: center; gap: 14px; }
      .pv-page-title { font-size: 1.2rem; font-weight: 800; }
      .pv-content { flex: 1; padding: 24px; overflow-y: auto; }
      .pv-card { background: white; border-radius: 12px; padding: 20px; margin-bottom: 16px; box-shadow: 0 2px 8px rgba(0,0,0,.06); border: 1px solid #e2e8f0; }
      .pv-stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 20px; }
      .pv-stat { background: white; border-radius: 12px; padding: 16px; text-align: center; border: 1px solid #e2e8f0; }
      .pv-stat-val { font-size: 1.8rem; font-weight: 900; color: var(--primary, #4f46e5); }
      .pv-stat-lbl { font-size: 0.7rem; text-transform: uppercase; letter-spacing: .05em; color: #64748b; margin-top: 4px; }
      .pv-table { width: 100%; border-collapse: collapse; }
      .pv-table th { text-align: left; padding: 10px 12px; background: #f1f5f9; font-size: 0.75rem; text-transform: uppercase; color: #475569; border-bottom: 2px solid #e2e8f0; }
      .pv-table td { padding: 10px 12px; border-bottom: 1px solid #e2e8f0; font-size: 0.88rem; }
      .pv-badge { display: inline-block; padding: 2px 8px; border-radius: 50px; font-size: 0.72rem; font-weight: 700; }
      .pv-badge-green { background: #dcfce7; color: #15803d; }
      .pv-badge-yellow { background: #fef9c3; color: #a16207; }
      .pv-badge-red { background: #fee2e2; color: #b91c1c; }
      .pv-badge-blue { background: #dbeafe; color: #1d4ed8; }
      .pv-btn { display: inline-flex; align-items: center; gap: 6px; padding: 8px 16px; border-radius: 8px; font-size: 0.85rem; font-weight: 600; border: 1px solid #e2e8f0; background: white; cursor: pointer; }
      .pv-btn-primary { background: var(--primary, #4f46e5); color: white; border: 0; }
      .pv-footer { padding: 16px 24px; border-top: 1px solid #e2e8f0; font-size: 0.78rem; color: #94a3b8; text-align: center; }
      .pv-section-title { font-size: 1rem; font-weight: 800; margin-bottom: 12px; color: #0f172a; }
      .pv-grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
      .pv-grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
      @media(max-width: 900px) { .pv-side { display: none; } .pv-stats { grid-template-columns: repeat(2, 1fr); } }
    `;

    // Page content generators for the preview
    function getPageHTML(pageId) {
      const d = demoData;
      const esc = s => String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
      switch (pageId) {
        case 'dashboard': return `
          <div class="pv-stats">
            <div class="pv-stat"><div class="pv-stat-val">${d.students.length}</div><div class="pv-stat-lbl">Students</div></div>
            <div class="pv-stat"><div class="pv-stat-val">${d.staff.length}</div><div class="pv-stat-lbl">Staff</div></div>
            <div class="pv-stat"><div class="pv-stat-val">${d.fee_payments.filter(f=>f.status==='paid').length}</div><div class="pv-stat-lbl">Paid</div></div>
            <div class="pv-stat"><div class="pv-stat-val">${d.announcements.length}</div><div class="pv-stat-lbl">Notices</div></div>
          </div>
          <div class="pv-grid-2">
            <div class="pv-card"><h3 class="pv-section-title">📢 Announcements</h3>
              ${d.announcements.map(a => `<div style="padding:8px 0;border-bottom:1px solid #e2e8f0"><strong>${esc(a.title)}</strong><div style="font-size:.8rem;color:#64748b">${esc(a.body)}</div></div>`).join('')}
            </div>
            <div class="pv-card"><h3 class="pv-section-title">🗳️ Active Polls</h3>
              ${d.polls.map(p => `<div style="padding:10px;background:#f1f5f9;border-radius:8px"><strong>${esc(p.title)}</strong><span class="pv-badge pv-badge-green" style="margin-left:8px">${esc(p.status)}</span></div>`).join('')}
            </div>
          </div>`;
        case 'students': return `
          <div class="pv-card"><h3 class="pv-section-title">👨‍🎓 Student Register (${d.students.length})</h3>
            <table class="pv-table"><thead><tr><th>Adm No</th><th>Name</th><th>Class</th><th>Gender</th><th>Status</th></tr></thead>
            <tbody>${d.students.map(s => `<tr><td>${esc(s.admission_no)}</td><td>${esc(s.full_name)}</td><td>${esc(s.class_name)}</td><td>${esc(s.gender)}</td><td><span class="pv-badge pv-badge-green">active</span></td></tr>`).join('')}</tbody>
            </table></div>`;
        case 'results': return `
          <div class="pv-card"><h3 class="pv-section-title">📊 Results — First Term</h3>
            <table class="pv-table"><thead><tr><th>Student</th><th>Subject</th><th>CA</th><th>Exam</th><th>Grade</th></tr></thead>
            <tbody>${d.results.map(r => `<tr><td>${esc(d.students.find(s=>s.id===r.student_id)?.full_name||'?')}</td><td>${esc(r.subject)}</td><td>${r.ca_score}</td><td>${r.exam_score}</td><td><span class="pv-badge ${r.grade==='A'?'pv-badge-green':r.grade==='D'?'pv-badge-red':'pv-badge-yellow'}">${esc(r.grade)}</span></td></tr>`).join('')}</tbody></table></div>`;
        case 'fees': return `
          <div class="pv-card"><h3 class="pv-section-title">💰 Fee Payments</h3>
            <table class="pv-table"><thead><tr><th>Student</th><th>Amount Paid</th><th>Balance</th><th>Status</th></tr></thead>
            <tbody>${d.fee_payments.map(f => `<tr><td>${esc(d.students.find(s=>s.id===f.student_id)?.full_name||'?')}</td><td>₦${f.amount_paid.toLocaleString()}</td><td>₦${f.balance.toLocaleString()}</td><td><span class="pv-badge ${f.status==='paid'?'pv-badge-green':'pv-badge-yellow'}">${esc(f.status)}</span></td></tr>`).join('')}</tbody></table></div>`;
        case 'attendance': return `
          <div class="pv-card"><h3 class="pv-section-title">📋 Attendance — Recent</h3>
            <table class="pv-table"><thead><tr><th>Date</th><th>Student</th><th>Status</th></tr></thead>
            <tbody>${d.attendance.slice(0,10).map(a => `<tr><td>${esc(a.date)}</td><td>${esc(d.students.find(s=>s.id===a.student_id)?.full_name||'?')}</td><td><span class="pv-badge ${a.status==='present'?'pv-badge-green':'pv-badge-red'}">${esc(a.status)}</span></td></tr>`).join('')}</tbody></table></div>`;
        case 'cbt': return `
          <div class="pv-card"><h3 class="pv-section-title">💻 CBT Exams</h3>
            ${d.cbt_exams.map(e => `<div style="padding:16px;background:#f1f5f9;border-radius:12px;margin-bottom:12px"><strong>${esc(e.title)}</strong><div style="font-size:.85rem;color:#64748b;margin-top:4px">${esc(e.subject)} · ${e.duration_min} min · ${e.total_questions} questions</div><button class="pv-btn pv-btn-primary" style="margin-top:10px" onclick="location.href='cbt-exam.html'">Take Exam</button></div>`).join('')}
            <p style="color:#94a3b8;font-size:.85rem">${d.cbt_exams.length} open exam(s). Admin can add more in the full portal.</p></div>`;
        case 'voting': return `
          <div class="pv-card"><h3 class="pv-section-title">🗳️ Polls & Elections</h3>
            ${d.polls.map(p => { const cands = JSON.parse(p.candidates||'[]'); return `<div style="padding:16px;background:#f1f5f9;border-radius:12px"><h4>${esc(p.title)} <span class="pv-badge pv-badge-green">open</span></h4><div class="pv-grid-3" style="margin-top:12px">${cands.map(c=>`<div class="pv-card" style="text-align:center;cursor:pointer"><div style="width:48px;height:48px;background:var(--primary,#4f46e5);border-radius:50%;display:flex;align-items:center;justify-content:center;color:white;font-weight:900;font-size:1.2rem;margin:0 auto 8px">${esc((c.name||'?')[0])}</div><strong>${esc(c.name)}</strong><div style="font-size:.78rem;color:#64748b">${esc(c.info)}</div></div>`).join('')}</div></div>`; }).join('')}</div>`;
        case 'announcements': return `
          <div class="pv-card"><h3 class="pv-section-title">📢 School Announcements</h3>
            ${d.announcements.map(a => `<div style="padding:16px;background:${a.priority==='high'?'#fef3c7':'#f1f5f9'};border-radius:12px;margin-bottom:12px;border-left:4px solid ${a.priority==='high'?'#f59e0b':'#4f46e5'}"><strong>${esc(a.title)}</strong><p style="margin:6px 0 0;font-size:.88rem;color:#475569">${esc(a.body)}</p></div>`).join('')}</div>`;
        case 'library': return `
          <div class="pv-card"><h3 class="pv-section-title">📖 Library Catalogue</h3>
            <table class="pv-table"><thead><tr><th>Title</th><th>Author</th><th>Code</th><th>Status</th></tr></thead>
            <tbody>${[{t:'Things Fall Apart',a:'Chinua Achebe',c:'LIT-001',s:'available'},{t:'Advanced Mathematics',a:'John Bird',c:'MTH-002',s:'available'},{t:'Biology for SS',a:'Nigerian Series',c:'BIO-003',s:'lent'}].map(b=>`<tr><td>${esc(b.t)}</td><td>${esc(b.a)}</td><td>${esc(b.c)}</td><td><span class="pv-badge ${b.s==='available'?'pv-badge-green':'pv-badge-yellow'}">${esc(b.s)}</span></td></tr>`).join('')}</tbody></table></div>`;
        case 'staff': return `
          <div class="pv-card"><h3 class="pv-section-title">👨‍🏫 Staff Directory (${d.staff.length})</h3>
            <table class="pv-table"><thead><tr><th>Staff No</th><th>Name</th><th>Role</th><th>Status</th></tr></thead>
            <tbody>${d.staff.map(s => `<tr><td>${esc(s.staff_no)}</td><td>${esc(s.full_name)}</td><td>${esc(s.role)}</td><td><span class="pv-badge pv-badge-green">active</span></td></tr>`).join('')}</tbody></table></div>`;
        default: return `
          <div class="pv-card" style="text-align:center;padding:40px">
            <div style="font-size:3rem;margin-bottom:12px">📄</div>
            <h3 style="margin-bottom:8px">${window.T && window.T.labelFor ? window.T.labelFor(pageId, pageId) : pageId.replace(/_/g,' ')}</h3>
            <p style="color:#64748b">Preview of the <strong>${pageId}</strong> module. Full features available in the downloaded portal.</p>
            <p style="margin-top:16px;font-size:.82rem;color:#94a3b8">Licensed Platform · HMG Technologies</p>
          </div>`;
      }
    }

    const firstPage = navItems[0]?.id || 'dashboard';

    // Pre-generate page content HTML strings for each page ID
    const esc2 = (s, into) => String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    const studentsHTML = d.students.map(s => `<tr><td>${esc2(s.admission_no)}</td><td>${esc2(s.full_name)}</td><td>${esc2(s.class_name)}</td><td>${esc2(s.gender)}</td><td><span class="pv-badge pv-badge-green">active</span></td></tr>`).join('');
    const staffHTML = d.staff.map(s => `<tr><td>${esc2(s.staff_no)}</td><td>${esc2(s.full_name)}</td><td>${esc2(s.role)}</td><td><span class="pv-badge pv-badge-green">active</span></td></tr>`).join('');
    const resultsHTML = d.results.map(r => `<tr><td>${esc2(d.students.find(s=>s.id===r.student_id)?.full_name||'?')}</td><td>${esc2(r.subject)}</td><td>${r.ca_score}</td><td>${r.exam_score}</td><td><span class="pv-badge ${r.grade==='A'?'pv-badge-green':r.grade==='D'?'pv-badge-red':'pv-badge-yellow'}">${esc2(r.grade)}</span></td></tr>`).join('');
    const feesHTML = d.fee_payments.map(f => `<tr><td>${esc2(d.students.find(s=>s.id===f.student_id)?.full_name||'?')}</td><td>₦${f.amount_paid.toLocaleString()}</td><td>₦${f.balance.toLocaleString()}</td><td><span class="pv-badge ${f.status==='paid'?'pv-badge-green':'pv-badge-yellow'}">${esc2(f.status)}</span></td></tr>`).join('');
    const attendanceHTML = d.attendance.slice(0,10).map(a => `<tr><td>${esc2(a.date)}</td><td>${esc2(d.students.find(s=>s.id===a.student_id)?.full_name||'?')}</td><td><span class="pv-badge ${a.status==='present'?'pv-badge-green':'pv-badge-red'}">${esc2(a.status)}</span></td></tr>`).join('');
    const announcementsHTML = d.announcements.map(a => `<div style="padding:16px;background:${a.priority==='high'?'#fef3c7':'#f1f5f9'};border-radius:12px;margin-bottom:12px;border-left:4px solid ${a.priority==='high'?'#f59e0b':'#4f46e5'}"><strong>${esc2(a.title)}</strong><p style="margin:6px 0 0;font-size:.88rem;color:#475569">${esc2(a.body)}</p></div>`).join('');
    const pollsHTML = d.polls.map(p => { const cands = JSON.parse(p.candidates||'[]'); return `<div style="padding:16px;background:#f1f5f9;border-radius:12px;margin-bottom:12px"><h4 style="margin:0 0 12px">${esc2(p.title)} <span class="pv-badge pv-badge-green" style="margin-left:8px">open</span></h4><div class="pv-grid-3">${cands.map(c=>`<div style="background:white;border-radius:10px;padding:16px;text-align:center;border:1px solid #e2e8f0"><div style="width:48px;height:48px;background:${cfg.themePrimary};border-radius:50%;display:flex;align-items:center;justify-content:center;color:white;font-weight:900;font-size:1.2rem;margin:0 auto 8px">${esc2((c.name||'?')[0])}</div><strong style="display:block;margin-bottom:4px">${esc2(c.name)}</strong><span style="font-size:.78rem;color:#64748b">${esc2(c.info)}</span></div>`).join('')}</div></div>`; }).join('');
    const cbtHTML = d.cbt_exams.map(e => `<div style="padding:16px;background:#f1f5f9;border-radius:12px;margin-bottom:12px"><strong>${esc2(e.title)}</strong><div style="font-size:.85rem;color:#64748b;margin-top:4px">${esc2(e.subject)} · ${e.duration_min} min · ${e.total_questions} questions</div><a href="cbt-exam.html" class="pv-btn pv-btn-primary" style="display:inline-flex;margin-top:10px;text-decoration:none">Take Exam →</a></div>`).join('');

    const pagesJSON = {
      dashboard: `<div class="pv-stats"><div class="pv-stat"><div class="pv-stat-val">${d.students.length}</div><div class="pv-stat-lbl">Students</div></div><div class="pv-stat"><div class="pv-stat-val">${d.staff.length}</div><div class="pv-stat-lbl">Staff</div></div><div class="pv-stat"><div class="pv-stat-val">${d.fee_payments.filter(f=>f.status==='paid').length}</div><div class="pv-stat-lbl">Fees Paid</div></div><div class="pv-stat"><div class="pv-stat-val">${d.announcements.length}</div><div class="pv-stat-lbl">Notices</div></div></div><div class="pv-grid-2"><div class="pv-card"><h3 class="pv-section-title">📢 Announcements</h3>${announcementsHTML}</div><div class="pv-card"><h3 class="pv-section-title">🗳️ Active Polls</h3>${pollsHTML}</div></div>`,
      students: `<div class="pv-card"><h3 class="pv-section-title">👨‍🎓 Student Register (${d.students.length})</h3><table class="pv-table"><thead><tr><th>Adm No</th><th>Name</th><th>Class</th><th>Gender</th><th>Status</th></tr></thead><tbody>${studentsHTML}</tbody></table></div>`,
      staff: `<div class="pv-card"><h3 class="pv-section-title">👨‍🏫 Staff Directory (${d.staff.length})</h3><table class="pv-table"><thead><tr><th>Staff No</th><th>Name</th><th>Role</th><th>Status</th></tr></thead><tbody>${staffHTML}</tbody></table></div>`,
      results: `<div class="pv-card"><h3 class="pv-section-title">📊 Results — First Term</h3><table class="pv-table"><thead><tr><th>Student</th><th>Subject</th><th>CA</th><th>Exam</th><th>Grade</th></tr></thead><tbody>${resultsHTML}</tbody></table></div>`,
      fees: `<div class="pv-card"><h3 class="pv-section-title">💰 Fee Payments</h3><table class="pv-table"><thead><tr><th>Student</th><th>Paid</th><th>Balance</th><th>Status</th></tr></thead><tbody>${feesHTML}</tbody></table></div>`,
      attendance: `<div class="pv-card"><h3 class="pv-section-title">📋 Recent Attendance</h3><table class="pv-table"><thead><tr><th>Date</th><th>Student</th><th>Status</th></tr></thead><tbody>${attendanceHTML}</tbody></table></div>`,
      announcements: `<div class="pv-card"><h3 class="pv-section-title">📢 Announcements</h3>${announcementsHTML}</div>`,
      voting: `<div class="pv-card"><h3 class="pv-section-title">🗳️ Polls &amp; Elections</h3>${pollsHTML}</div>`,
      cbt: `<div class="pv-card"><h3 class="pv-section-title">💻 CBT Exams</h3>${cbtHTML}<p style="color:#94a3b8;font-size:.85rem;margin-top:8px">${d.cbt_exams.length} open exam(s). Add more in the full portal.</p></div>`,
      library: `<div class="pv-card"><h3 class="pv-section-title">📖 Library Catalogue</h3><table class="pv-table"><thead><tr><th>Title</th><th>Author</th><th>Code</th><th>Status</th></tr></thead><tbody><tr><td>Things Fall Apart</td><td>Chinua Achebe</td><td>LIT-001</td><td><span class="pv-badge pv-badge-green">available</span></td></tr><tr><td>Advanced Mathematics</td><td>John Bird</td><td>MTH-002</td><td><span class="pv-badge pv-badge-green">available</span></td></tr><tr><td>Biology for SS</td><td>Nigerian Series</td><td>BIO-003</td><td><span class="pv-badge pv-badge-yellow">lent</span></td></tr></tbody></table></div>`
    };

    const pagesObj = JSON.stringify(pagesJSON);
    const navJSON = JSON.stringify(navItems.map(n => ({ id: n.id, label: n.label })));

    return `<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc2(cfg.schoolName)} — School Connect Preview</title>
<style>:root{--primary:${cfg.themePrimary};--accent:${cfg.themeAccent};--font:'${(cfg.font && cfg.font.css) || 'Inter'}',system-ui,sans-serif}</style>
<style>${previewCSS}</style>
</head><body>
<div class="pv-shell">
  <div class="pv-side">
    <div class="pv-brand">
      <div style="width:32px;height:32px;background:${cfg.themePrimary};border-radius:8px;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:900;font-size:1.1rem">${esc2((cfg.shortName||cfg.schoolName||'S')[0])}</div>
      <span class="pv-brand-name">${esc2(cfg.schoolName)}</span>
    </div>
    <div class="pv-nav" id="pv-nav">${navHTML}</div>
    <div style="padding:12px 8px;border-top:1px solid #1e293b;font-size:.72rem;color:#64748b;text-align:center">Demo data · <a href="feature-guide.html" style="color:#94a3b8">Feature Guide</a></div>
  </div>
  <div class="pv-main">
    <div class="pv-topbar">
      <div class="pv-page-title" id="pv-title">Dashboard</div>
      <div style="margin-left:auto"><span class="pv-badge pv-badge-blue">DEMO</span></div>
    </div>
    <div class="pv-content" id="pv-content"></div>
    <div class="pv-footer">${esc2(cfg.schoolName)} · Demo preview · Real portal at download · <a href="https://hmgconcepts.pages.dev/" target="_blank" style="color:#94a3b8">HMG Concepts</a></div>
  </div>
</div>
<script>
(function(){
  var PAGES = ${pagesObj};
  var NAV = ${navJSON};
  var firstPage = ${JSON.stringify(firstPage)};

  function go(id) {
    document.getElementById('pv-content').innerHTML = PAGES[id] || '<div class="pv-card" style="text-align:center;padding:40px"><div style="font-size:3rem;margin-bottom:12px">📄</div><h3>' + (NAV.find(function(n){return n.id===id;})||{label:id}).label + '</h3><p style="color:#64748b">This module is available in the full portal.</p></div>';
    document.getElementById('pv-title').textContent = (NAV.find(function(n){return n.id===id;})||{label:id}).label;
    document.querySelectorAll('.pv-nav-item').forEach(function(el){ el.classList.toggle('active', el.dataset.page === id); });
  }

  document.querySelectorAll('.pv-nav-item').forEach(function(el){
    el.addEventListener('click', function(){ go(el.dataset.page); });
  });

  go(firstPage);
})();
</script>
</body></html>`;
  }
};

window.Generator = Generator;

console.log('%c[School Connect Gen v8] Generator loaded — full page generation pipeline.', 'color:#4f46e5;font-weight:bold');