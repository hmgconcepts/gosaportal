/* ====================================================================
   license.js — School Connect Site License & Subscription engine
   ====================================================================
   WHY THIS FILE EXISTS
   --------------------
   School Connect is sold two ways (see the generator wizard):
     1. ONE-TIME (lifetime): the client pays once and owns the site
        forever. This file then does nothing visible.
     2. SUBSCRIPTION: the client pays per cycle (monthly / termly /
        annual / custom). This file then evaluates the license on every
        page load and, after expiry + grace days, locks the portal with
        a full renewal screen until HMG extends the subscription.

   DATA SOURCES (evaluated in priority order)
     A. HMG License Registry (optional) — SCHOOL.licenseRegistryUrl:
        a small JSON hosted on HMG-controlled hosting, which the client
        cannot edit. If it is reachable it wins. Format:
          { "sites": { "<shortName>": { "model": "subscription",
              "status": "active|suspended", "expires_on": "YYYY-MM-DD",
              "grace_days": 7, "plan": "...", "renew_url": "..." } } }
     B. Supabase table public.site_license (row id = 1). Read is public
        (RLS policy site_license_read) so this works even pre-login;
        writes require an admin (policy site_license_write).
     C. Build config fallback: window.SCHOOL.license in assets/js/config.js
        (written by the generator; always present).

   ANTI-BYPASS LAYERS
     • The guard runs on EVERY page (script tag right after config.js),
       before the app boots, re-checks every 15 min and on tab refocus.
     • The lock and banner render inside a closed Shadow DOM and are
       re-attached by a MutationObserver if someone removes the node.
     • Rows written through the official license page carry a SHA-256
       signature (model|expires_on|grace_days|status|salt); a casually
       hand-edited database row fails verification and is flagged.
     • The HMG registry (when configured) lives on hosting the client
       does not control, so local edits cannot suspend/extend terms.
     Honest note (see docs): code on client-controlled hosting can never
     be made 100% tamper-proof; these layers make bypass non-trivial,
     and the registry keeps the authoritative status in HMG's hands.

   PUBLIC API (used by license.html and diagnostics):
     License.evaluate(lic)        → {state, exp, daysLeft, ...}
     License.status()             → Promise<{source, lic, result}>
     License.signature(lic)       → Promise<hex>
     License.applyUi(result,lic)  → renders banner/lock as appropriate
   ==================================================================== */
(function () {
  'use strict';

  var LS_CACHE = 'sc_license_cache_v2';
  var POLL_MS = 15 * 60 * 1000;

  function cfg() {
    var s = window.SCHOOL || {};
    return {
      short: (s.shortName || 'SCH'),
      name: s.name || 'School',
      license: s.license || { model: 'lifetime' },
      registry: s.licenseRegistryUrl || '',
      salt: s.licenseSalt || '',
      hmg: s.hmgLink || 'https://hmgconcepts.pages.dev/',
      demo: s.demo && s.demo.enabled
    };
  }

  function normalize(raw) {
    raw = raw || {};
    return {
      model: (raw.model === 'subscription') ? 'subscription' : 'lifetime',
      plan: raw.plan || (raw.model === 'subscription' ? 'Subscription' : 'One-time purchase (lifetime ownership)'),
      cycle: raw.cycle || '',
      started_on: raw.started_on || '',
      expires_on: raw.expires_on || null,
      grace_days: (raw.grace_days == null ? 7 : +raw.grace_days || 0),
      status: raw.status === 'suspended' ? 'suspended' : 'active',
      renew_url: raw.renew_url || '',
      lock_message: raw.lock_message || '',
      signature: raw.signature || ''
    };
  }

  /** Core date/status evaluation — pure function, reused everywhere. */
  function evaluate(raw) {
    var lic = normalize(raw);
    if (lic.model !== 'subscription') return { state: 'lifetime', lic: lic };
    if (lic.status !== 'active') return { state: 'suspended', lic: lic };
    if (!lic.expires_on) return { state: 'active', lic: lic };
    var now = new Date();
    var exp = new Date(lic.expires_on + 'T23:59:59');
    if (isNaN(+exp)) return { state: 'active', lic: lic };
    var graceEnd = new Date(exp.getTime() + lic.grace_days * 86400000);
    if (now > graceEnd) return { state: 'expired', lic: lic, exp: exp, daysOver: Math.max(1, Math.round((now - graceEnd) / 86400000)) };
    if (now > exp) return { state: 'grace', lic: lic, exp: exp, daysLeft: Math.max(1, Math.ceil((graceEnd - now) / 86400000)) };
    var days = Math.ceil((exp - now) / 86400000);
    if (days <= 30) return { state: 'warning', lic: lic, exp: exp, daysLeft: days };
    return { state: 'active', lic: lic, exp: exp, daysLeft: days };
  }

  async function sha256hex(text) {
    try {
      if (!crypto || !crypto.subtle) return '';
      var buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
      return Array.prototype.map.call(new Uint8Array(buf), function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
    } catch (e) { return ''; }
  }

  /** Signature for tamper evidence: sha256(model|expires|grace|status|salt). */
  async function signature(raw) {
    var lic = normalize(raw);
    return sha256hex([lic.model, lic.expires_on || '', lic.grace_days, lic.status, cfg().salt].join('|'));
  }

  function readCache() { try { return JSON.parse(localStorage.getItem(LS_CACHE) || 'null'); } catch (e) { return null; } }
  function writeCache(o) { try { localStorage.setItem(LS_CACHE, JSON.stringify(o)); } catch (e) {} }

  async function fromRegistry() {
    var c = cfg(); if (!c.registry) return null;
    try {
      var ctl = new AbortController(); var t = setTimeout(function () { ctl.abort(); }, 3500);
      var res = await fetch(c.registry + (c.registry.indexOf('?') > -1 ? '&' : '?') + 'v=' + Date.now(), { signal: ctl.signal, cache: 'no-store' });
      clearTimeout(t);
      if (!res.ok) return null;
      var j = await res.json();
      var hit = (j && j.sites && (j.sites[c.short] || j.sites[(c.short || '').toUpperCase()] || j.sites[(c.short || '').toLowerCase()])) || (j && j.site === c.short ? j : null);
      return hit ? { lic: normalize(hit), source: 'registry' } : null;
    } catch (e) { return null; }
  }

  async function fromDb() {
    try {
      if (!window.sb) return null;
      var r = await window.sb.from('site_license').select('*').eq('id', 1).maybeSingle();
      if (r && r.data) return { lic: normalize(r.data), source: 'database', tampered: false, raw: r.data };
    } catch (e) {}
    return null;
  }

  /** Resolve effective license: registry → database → config, with caching. */
  async function status() {
    if (cfg().demo) { var d = { lic: normalize({ model: 'lifetime', plan: 'Demo deployment' }), source: 'demo' }; d.result = evaluate(d.lic); return d; }
    var reg = await fromRegistry();
    if (reg) { reg.result = evaluate(reg.lic); writeCache({ at: Date.now(), lic: reg.lic, source: reg.source }); return reg; }
    var db = await fromDb();
    if (db) {
      var sig = await signature(db.lic);
      db.tampered = !!(db.lic.signature && cfg().salt && sig && db.lic.signature !== sig);
      db.result = evaluate(db.lic);
      writeCache({ at: Date.now(), lic: db.lic, source: db.source });
      return db;
    }
    var c = cfg().license;
    if (c) { var out = { lic: normalize(c), source: 'config' }; out.result = evaluate(out.lic); return out; }
    var cached = readCache();
    if (cached && cached.lic) return { lic: normalize(cached.lic), source: 'cache', result: evaluate(cached.lic) };
    return { lic: normalize({ model: 'lifetime' }), source: 'default', result: evaluate({ model: 'lifetime' }) };
  }

  /* ---------------- UI: shadow-DOM banner & lock ---------------- */
  var host = null;
  function ensureHost() {
    if (host && document.documentElement.contains(host)) return host;
    host = document.createElement('div');
    host.id = 'sc-license-guard';
    host.setAttribute('data-sc-license', '1');
    var sh = host.attachShadow({ mode: 'closed' });
    sh.innerHTML = '';
    (document.documentElement || document.body).appendChild(host);
    return sh;
  }

  function bannerHtml(res) {
    var lic = res.lic, r = res.result, primary = (window.SCHOOL && window.SCHOOL.primary) || '#4f46e5';
    var renew = lic.renew_url || ('https://wa.me/2348100866322?text=' + encodeURIComponent('Hello HMG, we want to renew the School Connect subscription for ' + cfg().name + '.'));
    var msg;
    if (r.state === 'grace') msg = '⚠️ Your School Connect subscription expired on ' + lic.expires_on + '. Grace period: <b>' + r.daysLeft + ' day(s) left</b>. Please renew now to avoid interruption.';
    else if (r.state === 'warning') msg = '🔔 Your School Connect subscription (' + (lic.plan || 'Subscription') + ') expires in <b>' + r.daysLeft + ' day(s)</b> on ' + lic.expires_on + '. Renew early to avoid interruption.';
    else if (r.tampered) msg = '🛡️ License verification notice: the stored license record does not match its signature. Please contact HMG support.';
    else return '';
    return '<div id="bar" style="position:fixed;left:0;right:0;top:0;z-index:2147483000;background:' + (r.state === 'grace' ? '#b91c1c' : '#92400e') + ';color:#fff;font:600 13px/1.5 system-ui,sans-serif;padding:8px 14px;display:flex;gap:10px;align-items:center;justify-content:center;flex-wrap:wrap;text-align:center;box-shadow:0 2px 10px rgba(0,0,0,.25)">' +
      '<span>' + msg + '</span>' +
      '<a href="' + renew + '" target="_blank" rel="noopener" style="background:#fff;color:' + primary + ';padding:4px 12px;border-radius:999px;text-decoration:none;font-weight:700">Renew / Contact HMG</a>' +
      '<span id="x" style="cursor:pointer;opacity:.8;padding:0 6px" title="Dismiss for this session">✕</span></div>';
  }

  function lockHtml(res) {
    var lic = res.lic, r = res.result, primary = (window.SCHOOL && window.SCHOOL.primary) || '#4f46e5';
    var renew = lic.renew_url || ('https://wa.me/2348100866322?text=' + encodeURIComponent('Hello HMG, please renew the School Connect subscription for ' + cfg().name + '.'));
    var reason = r.state === 'suspended'
      ? 'This portal is currently <b>suspended</b>.'
      : 'Your School Connect subscription <b>expired on ' + (lic.expires_on || 'n/a') + '</b>' + (r.daysOver ? ' (' + r.daysOver + ' day(s) past the grace period).' : '.');
    var custom = lic.lock_message ? '<p style="margin:10px 0 0;color:#374151;font-size:14px">' + lic.lock_message + '</p>' : '';
    return '<div id="lock" style="position:fixed;inset:0;z-index:2147483647;background:linear-gradient(135deg,#0f172a,#1e293b);display:flex;align-items:center;justify-content:center;padding:20px;overflow:auto">' +
      '<div style="background:#fff;max-width:560px;width:100%;border-radius:18px;padding:34px 30px;text-align:center;font-family:system-ui,-apple-system,sans-serif;box-shadow:0 24px 70px rgba(0,0,0,.45)">' +
      '<div style="font-size:44px">🔒</div>' +
      '<h1 style="margin:8px 0 4px;font-size:1.35rem;color:#111827">Subscription Renewal Required</h1>' +
      '<p style="margin:0;color:#4b5563;font-size:14.5px;line-height:1.6"><b>' + cfg().name + '</b> — ' + reason + '</p>' + custom +
      '<p style="margin:10px 0 0;color:#4b5563;font-size:14px;line-height:1.6">Renew to restore full access instantly. All your data is safe and nothing has been deleted — the portal resumes as soon as the subscription is extended.</p>' +
      '<div style="margin:18px 0 0;display:flex;gap:10px;justify-content:center;flex-wrap:wrap">' +
      '<a href="' + renew + '" target="_blank" rel="noopener" style="background:' + primary + ';color:#fff;padding:11px 22px;border-radius:10px;text-decoration:none;font-weight:700;font-size:14px">💬 Renew on WhatsApp</a>' +
      '<a href="' + cfg().hmg + '" target="_blank" rel="noopener" style="border:1.5px solid ' + primary + ';color:' + primary + ';padding:11px 22px;border-radius:10px;text-decoration:none;font-weight:700;font-size:14px">Contact HMG Concepts</a></div>' +
      '<p style="margin:16px 0 0;color:#9ca3af;font-size:11.5px">Powered by School Connect · HMG Concepts Ecosystem · Your data remains 100% yours</p>' +
      '</div></div>';
  }

  function applyUi(res) {
    var r = res.result;
    if (!r || r.state === 'lifetime' || r.state === 'active') return;
    var sh;
    function mount() {
      try {
        sh = ensureHost();
        var inner = '';
        if (r.state === 'expired' || r.state === 'suspended') inner = lockHtml(res);
        else if (r.state === 'grace' || r.state === 'warning' || (res.tampered && r.state !== 'lifetime')) inner = bannerHtml(res);
        if (sh.innerHTML !== inner) {
          sh.innerHTML = inner;
          var x = sh.getElementById('x');
          if (x) x.addEventListener('click', function () {
            try { sessionStorage.setItem('sc_license_banner_dismissed', '1'); } catch (e) {}
            sh.innerHTML = '';
          });
        }
      } catch (e) {}
    }
    if (sessionStorage.getItem('sc_license_banner_dismissed') === '1' && r.state !== 'expired' && r.state !== 'suspended') return;
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount); else mount();
    // re-attach if removed (tamper resistance)
    if (!window.__scLicenseObserver) {
      window.__scLicenseObserver = new MutationObserver(function () {
        if (sessionStorage.getItem('sc_license_banner_dismissed') === '1' && r.state !== 'expired' && r.state !== 'suspended') return;
        if (!document.getElementById('sc-license-guard')) { host = null; mount(); }
      });
      try { window.__scLicenseObserver.observe(document.documentElement, { childList: true, subtree: false }); } catch (e) {}
    }
  }

  async function tick() {
    try {
      var res = await status();
      applyUi(res);
      window.SC_LICENSE_STATUS = res;
      return res;
    } catch (e) { return null; }
  }

  window.License = {
    evaluate: evaluate,
    signature: signature,
    status: status,
    applyUi: applyUi,
    normalize: normalize,
    refresh: tick
  };

  // boot
  function boot() { tick(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else setTimeout(boot, 0);
  setInterval(tick, POLL_MS);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) tick(); });
})();
