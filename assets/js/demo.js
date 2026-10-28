/* ====================================================================
   demo.js — School Connect Demo Mode (prospective-client showcase)
   ====================================================================
   Active ONLY when window.SCHOOL.demo.enabled is true (set by the
   generator's "Demo build" option). Two jobs:

   1) LOGIN PAGE — renders an "Explore as Guest" panel with one-tap
      sign-in for five ready-made roles (Admin, Teacher, Parent,
      Student, Bursar). Credentials are created once by running
      database/demo-users.sql (see DEMO-SETUP.md) and shown on the
      panel so prospects can also type them manually.

   2) EVERY PAGE — a slim ribbon reminding visitors this is a demo
      deployment with simulated data (dismissible per session).

   The platform itself (RLS, pages, modules) is untouched: demo users
   are ordinary accounts whose profiles carry the matching role, so
   every page behaves exactly as it would for a real school.
   ==================================================================== */
(function () {
  'use strict';
  var D = (window.SCHOOL && window.SCHOOL.demo) || {};
  if (!D.enabled) return;

  /* Demo accounts — created in the Supabase Dashboard ("Add user", Auto Confirm
     ON) and approved by database/demo-users.sql v6 (DEMO-SETUP.md). On the
     newest hosted GoTrue, Dashboard-created accounts always log in while
     SQL-created auth rows cannot — so v6 never creates users in SQL. */
  var ACCOUNTS = [
    { role: 'Admin',   icon: '🛡️', email: 'admin@scdemo.school',   pass: 'Demo#Admin1',  see: 'Everything: setup, approvals, analytics, fees, license…' },
    { role: 'Teacher', icon: '👩‍🏫', email: 'teacher@scdemo.school', pass: 'Demo#Teach1',  see: 'Attendance, results, CBT exams, lesson plans, classroom…' },
    { role: 'Parent',  icon: '👨‍👩‍👧', email: 'parent@scdemo.school',  pass: 'Demo#Parent1', see: 'Only her two children: results, fees, attendance, diary…' },
    { role: 'Student', icon: '🎓', email: 'student@scdemo.school', pass: 'Demo#Study1',  see: 'Own records, CBT exam portal, timetable, assignments…' },
    { role: 'Bursar',  icon: '💼', email: 'bursar@scdemo.school',  pass: 'Demo#Bursar1', see: 'Fee structures, payments, receipts, finance reports…' }
  ];

  function toast(msg, opts) {
    var o = opts || {};
    var t = document.createElement('div');
    t.style.cssText = 'position:fixed;bottom:18px;left:50%;transform:translateX(-50%);max-width:min(92vw,560px);text-align:center;background:' +
      (o.err ? '#7f1d1d' : '#0f172a') + ';color:#fff;padding:10px 18px;border-radius:' + (o.err ? '12px' : '999px') +
      ';font:600 13px/1.45 system-ui;z-index:2147483000;box-shadow:0 8px 30px rgba(0,0,0,.35)';
    t.textContent = msg; document.body.appendChild(t); setTimeout(function(){ t.remove(); }, o.err ? 9000 : 2600);
  }

  /* Turn any Supabase/Auth error into a human-readable string (error objects
     often stringify to "{}" — so dig through every known shape). */
  function errMsg(err) {
    if (!err) return 'unknown error';
    if (typeof err === 'string') return err;
    var m = err.message || err.error_description || err.msg || err.code;
    if (m) return String(m);
    try { var s = JSON.stringify(err, Object.getOwnPropertyNames(err)); if (s && s !== '{}') return s; } catch (e) {}
    try { return String(err.status ? ('HTTP ' + err.status) : Object.prototype.toString.call(err)); } catch (e2) { return 'unknown error'; }
  }

  /* Cause-specific, actionable fix guidance for the dashboard operator. */
  function hintFor(msg) {
    var m = (msg || '').toLowerCase();
    if (/database error|unexpected_failure|querying schema|finding user/.test(m))
      return 'The auth service is choking on an old SQL-created auth row. Fix: Supabase Dashboard → Authentication → Users → delete the broken demo user, re-create it with \"Add user\" (same email + password from DEMO-SETUP.md, Auto Confirm ON), then run database/demo-users.sql v6 to approve its profile. See DEMO-SETUP.md.';
    if (/invalid login|invalid credentials|email or password/.test(m))
      return 'This guest account is missing or its password differs. Fix: Dashboard → Authentication → Users → create it (or Edit user → set the password to the one shown on the login panel / DEMO-SETUP.md), Auto Confirm ON — then run database/demo-users.sql v6 in the SAME project as the URL in assets/js/config.js to approve the profile.';
    if (/email not confirmed|confirm your email/.test(m))
      return 'Emails must be pre-confirmed for guest accounts. Fix: re-run database/demo-users.sql v6 (it confirms them), or Dashboard → Users → Edit user → Confirm email, or Auth → Providers → Email → turn OFF "Confirm email".';
    if (/failed to fetch|network|load failed|fetcherror|err_failed/.test(m))
      return 'The site cannot reach Supabase. Check SUPABASE_URL + SUPABASE_ANON_KEY in assets/js/config.js belong to this demo project.';
    if (/paused|inactive|unavailable|503/.test(m))
      return 'The free Supabase project is paused (7-day inactivity rule). Open the Supabase dashboard and click "Restore project", then retry.';
    return 'Open the browser console (F12) for the full error. Most causes are fixed by (re)running database/demo-users.sql in the correct project — see DEMO-SETUP.md.';
  }

  async function signInAs(acc) {
    if (!window.sb) { toast('Demo database not configured yet — fill SUPABASE_URL + anon key in assets/js/config.js (DEMO-SETUP.md step 2).', { err: true }); return; }
    toast('Signing in as demo ' + acc.role + '…');
    try {
      var r = await sb.auth.signInWithPassword({ email: acc.email, password: acc.pass });
      if (r.error) {
        var m = errMsg(r.error);
        console.warn('[demo] sign-in error for', acc.email, r.error);
        toast('Demo login failed: ' + m + '. ' + hintFor(m), { err: true });
        return;
      }
      location.href = 'dashboard.html';
    } catch (e) {
      var m2 = errMsg(e);
      console.warn('[demo] sign-in threw for', acc.email, e);
      toast('Demo login failed: ' + m2 + '. ' + hintFor(m2), { err: true });
    }
  }

  function isLoginPage() {
    var p = (location.pathname.split('/').pop() || 'index.html').toLowerCase();
    return p === 'login.html' || p === 'signin.html';
  }

  function renderPanel() {
    if (document.getElementById('sc-demo-panel')) return;
    var card = document.createElement('div');
    card.id = 'sc-demo-panel';
    card.style.cssText = 'max-width:640px;margin:18px auto 0;padding:18px;border-radius:16px;border:2px dashed #6366f1;background:#eef2ff;font-family:system-ui,-apple-system,sans-serif';
    var rows = ACCOUNTS.map(function (a, i) {
      return '<div style="display:flex;align-items:center;gap:10px;background:#fff;border:1px solid #e0e7ff;border-radius:12px;padding:10px 12px;margin:8px 0">' +
        '<div style="font-size:1.5rem">' + a.icon + '</div>' +
        '<div style="flex:1;min-width:0"><b style="font-size:.92rem">' + a.role + '</b><div style="font-size:.74rem;color:#64748b">' + a.see + '</div>' +
        '<div style="font-size:.72rem;color:#94a3b8;margin-top:2px">📧 ' + a.email + ' &nbsp;·&nbsp; 🔑 ' + a.pass + '</div></div>' +
        '<button data-demo-i="' + i + '" style="background:#4f46e5;color:#fff;border:0;border-radius:8px;padding:8px 14px;font:700 12px system-ui;cursor:pointer">Explore →</button></div>';
    }).join('');
    card.innerHTML =
      '<div style="text-align:center;margin-bottom:8px"><span style="background:#4f46e5;color:#fff;font:700 11px system-ui;padding:3px 12px;border-radius:999px;letter-spacing:.4px">LIVE DEMO — NO SIGN-UP NEEDED</span></div>' +
      '<h3 style="margin:0 0 2px;text-align:center;font-size:1.05rem">🎮 Explore School Connect as a Guest</h3>' +
      '<p style="margin:0 0 6px;text-align:center;font-size:.8rem;color:#64748b">One tap signs you in with a ready-made role. Everything you see — students, staff, fees, attendance, CBT exams, results, report cards — is realistic sample data from a fully simulated school.</p>' + rows +
      '<p style="margin:8px 0 0;text-align:center;font-size:.72rem;color:#94a3b8">Demo data resets periodically · please don\'t enter real personal data · <a href="https://hmgconcepts.pages.dev/" target="_blank" rel="noopener" style="color:#4f46e5">Get this for your school → HMG Concepts</a></p>';
    // mount: after the login card if we can find one, else top of body
    var host = document.querySelector('.login-card, .auth-card, form[action*="login"], .card');
    if (host && host.parentNode) host.parentNode.insertBefore(card, host.nextSibling);
    else document.body.insertBefore(card, document.body.firstChild);
    card.addEventListener('click', function (e) {
      var b = e.target.closest('[data-demo-i]');
      if (b) signInAs(ACCOUNTS[+b.dataset.demoI]);
    });
  }

  function renderRibbon() {
    if (isLoginPage() || document.getElementById('sc-demo-ribbon')) return;
    if (sessionStorage.getItem('sc_demo_ribbon_off') === '1') return;
    var r = document.createElement('div');
    r.id = 'sc-demo-ribbon';
    r.style.cssText = 'position:sticky;top:0;z-index:2147482000;background:linear-gradient(90deg,#312e81,#4f46e5);color:#fff;font:600 12px/1.4 system-ui;padding:6px 12px;display:flex;gap:10px;align-items:center;justify-content:center;flex-wrap:wrap';
    r.innerHTML = '<span>🎮 <b>Demo deployment</b> — fully simulated school data (nothing here is real). ' + (D.note || '') + '</span>' +
      '<a href="https://hmgconcepts.pages.dev/" target="_blank" rel="noopener" style="background:#fff;color:#4338ca;padding:2px 10px;border-radius:999px;text-decoration:none;font-weight:800">Get School Connect</a>' +
      '<span id="sc-demo-ribbon-x" style="cursor:pointer;opacity:.85;padding:0 4px">✕</span>';
    document.body.insertBefore(r, document.body.firstChild);
    r.querySelector('#sc-demo-ribbon-x').addEventListener('click', function () { try { sessionStorage.setItem('sc_demo_ribbon_off', '1'); } catch (e) {} r.remove(); });
  }

  function boot() {
    try {
      if (isLoginPage()) renderPanel(); else renderRibbon();
    } catch (e) { console.warn('[demo]', e); }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function(){ setTimeout(boot, 400); });
  else setTimeout(boot, 400);
})();
