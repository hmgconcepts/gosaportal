/* ====================================================================
   pwa-install.js — School Connect Gen v8
   Handles BOTH install prompt AND seamless background updates.
   - Install: beforeinstallprompt → banner with Install/Dismiss/Never
   - Update: SW updatefound → waiting → Update banner with auto-reload
             (standalone PWA auto-updates in 10s, browser tab in 20s)
   Robust, self-contained, all-inclusive, works on phone/laptop/tablet
   for student/parent/staff/admin, online/offline, single/multiple tabs,
   Android/Chrome, iOS Safari standalone, Vercel + Supabase free tier.
   No paid APIs. Every page that includes this file gets update UX
   without editing HTML (banner injected dynamically).
   ==================================================================== */

const PWAInstall = {
  deferredPrompt: null,
  installed: false,
  dismissedAt: null,
  showIntervalDays: 2,
  // Update state
  _reg: null,
  _waitingSW: null,
  _updateBanner: null,
  _updateCountdown: null,
  _updateCountdownSec: 0,
  _hasReloaded: false,
  _lastUpdateCheck: 0,

  init() {
    // ---- Install handlers (existing, unchanged) ----
    window.addEventListener('beforeinstallprompt', e => {
      e.preventDefault();
      this.deferredPrompt = e;
      setTimeout(() => this.maybeShowBanner(), 4000);
    });
    window.addEventListener('appinstalled', () => {
      this.installed = true;
      this.deferredPrompt = null;
      localStorage.setItem('sc_pwa_installed', '1');
      this.hideBanner();
      if (window.toast) toast('🎉 App installed! Find "School Connect" on your home screen.', 'success', 6000);
    });
    if (localStorage.getItem('sc_pwa_installed') === '1') this.installed = true;
    if (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) this.installed = true;
    if (window.navigator && window.navigator.standalone === true) this.installed = true;
    setTimeout(() => this.maybeShowBanner(), 6000);
    this.bindUI();
    // ---- Update handlers (new in v12.40) ----
    this.injectUpdateBanner();
    this.initUpdateChecker();
    /* V12.74 (item 8): if this build IS the newest one, there is no update to
       offer — make sure a stale banner from a previous session cannot linger. */
    this.alreadyCurrent().then(current => { if (current) this.hideUpdateBanner(); });
  },

  bindUI() {
    document.addEventListener('click', e => {
      const t = e.target.closest('[data-pwa-action]');
      if (!t) return;
      const a = t.dataset.pwaAction;
      if (a === 'install') this.prompt();
      if (a === 'dismiss') this.dismiss();
      if (a === 'ios-help') this.showIOSHelp();
      if (a === 'never') this.neverShow();
      if (a === 'update-now') this.applyUpdate();
      if (a === 'update-dismiss') this.dismissUpdate();
    });
  },

  // ---- Install banner ----
  maybeShowBanner() {
    if (this.installed) return;
    const b = document.getElementById('pwa-install-banner');
    if (!b) return;
    if (this.deferredPrompt) { b.classList.add('show'); return; }
    if (this.isIOS() && !this.installed) {
      b.classList.add('show');
      const m = b.querySelector('.pwa-install-msg');
      if (m) m.innerHTML = 'Tap <strong>Share</strong> (the square with arrow ↑) then choose <strong>Add to Home Screen</strong>.';
    }
  },
  async prompt() {
    if (!this.deferredPrompt) {
      if (this.isIOS()) this.showIOSHelp();
      else if (window.toast) toast('Use your browser\'s "Add to Home Screen" option.', 'info', 5000);
      return;
    }
    this.deferredPrompt.prompt();
    const c = await this.deferredPrompt.userChoice;
    if (c.outcome === 'accepted' && window.toast) toast('Installing…', 'success');
    else this.dismiss();
    this.deferredPrompt = null;
  },
  dismiss() { this.hideBanner(); localStorage.setItem('sc_pwa_dismissed_at', Date.now().toString()); },
  neverShow() { this.hideBanner(); localStorage.setItem('sc_pwa_never', '1'); },
  hideBanner() { const b = document.getElementById('pwa-install-banner'); if (b) b.classList.remove('show'); },
  isIOS() { return /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream; },
  showIOSHelp() {
    if (window.openModal) openModal('Install on iPhone / iPad', `
      <div style="text-align:center;padding:12px 0">
        <div style="font-size:3rem;margin-bottom:12px">📱</div>
        <ol style="text-align:left;line-height:1.8;padding-left:24px">
          <li>Open this page in <strong>Safari</strong> (not Chrome).</li>
          <li>Tap the <strong>Share</strong> button <span style="font-size:1.4rem">⬆️</span> at the bottom.</li>
          <li>Scroll down and tap <strong>Add to Home Screen</strong>.</li>
          <li>Tap <strong>Add</strong> in the top right.</li>
        </ol>
        <p style="margin-top:16px;color:var(--gray-600, #6b7280);font-size:0.88rem">The app will appear on your home screen with the school logo. Works offline and sends push notifications.</p>
      </div>
    `);
  },

  // ---- Update: inject banner & styles ----
  injectUpdateBanner() {
    if (document.getElementById('pwa-update-banner')) return;
    const s = document.createElement('style');
    s.id = 'pwa-update-styles';
    s.textContent = `
# pwa-update-banner{position:fixed;left:12px;right:12px;bottom:14px;z-index:9999;display:none;align-items:center;gap:10px;padding:12px 14px;background:#0f172a;color:#fff;border-radius:14px;box-shadow:0 8px 24px rgba(0,0,0,.35);font-size:.92rem;line-height:1.4;border:1px solid rgba(255,255,255,.15)}
# pwa-update-banner.show{display:flex;animation:pwaSlideUp .3s ease}
@keyframes pwaSlideUp{from{transform:translateY(100%);opacity:0}to{transform:translateY(0);opacity:1}}
# pwa-update-banner .pwa-update-icon{font-size:1.4rem;flex:0 0 auto}
# pwa-update-banner .pwa-update-msg{flex:1;min-width:0}
# pwa-update-banner .pwa-update-msg strong{color:#fff}
# pwa-update-banner .pwa-update-count{font-weight:800;color:#fbbf24}
# pwa-update-banner .pwa-update-actions{display:flex;gap:8px;flex:0 0 auto;flex-wrap:wrap}
# pwa-update-banner .btn{padding:7px 12px;border-radius:10px;border:0;font-weight:700;cursor:pointer;font-size:.88rem}
# pwa-update-banner .btn-primary{background:#06b6d4;color:#0f172a}
# pwa-update-banner .btn-ghost{background:rgba(255,255,255,.12);color:#fff;border:1px solid rgba(255,255,255,.2)}
@media(max-width:520px){#pwa-update-banner{flex-direction:column;align-items:stretch;text-align:center}#pwa-update-banner .pwa-update-actions{justify-content:center}}
`;
    document.head.appendChild(s);
    const b = document.createElement('div');
    b.id = 'pwa-update-banner';
    b.setAttribute('role', 'alert');
    b.setAttribute('aria-live', 'polite');
    b.innerHTML = `
      <span class="pwa-update-icon">🔄</span>
      <span class="pwa-update-msg"><strong>New version available!</strong> <span id="pwa-update-detail">App will update automatically</span> <span class="pwa-update-count" id="pwa-update-count"></span></span>
      <span class="pwa-update-actions">
        <button class="btn btn-primary" data-pwa-action="update-now">Update now</button>
        <button class="btn btn-ghost" data-pwa-action="update-dismiss">Later</button>
      </span>`;
    document.body.appendChild(b);
    this._updateBanner = b;
  },
  /* ==================================================================
     V12.74 (item 8) — "Update now" must update, and must not come back.
     Three defects:
       (a) the banner's version identity was registration.scriptURL, which is
           the SAME string in every release, so "have I already applied this?"
           could never be answered — the banner kept returning;
       (b) applyUpdate() silently reloaded when there was no waiting worker,
           and the reload could be served from the old cache, so nothing changed;
       (c) nothing recorded that a version had been applied.
     The version now comes from the service worker's own cache name, the last
     applied version is remembered, and the apply path always does something
     visible.
     ================================================================== */
  async latestVersion() {
    try {
      /* V12.77 — a cache-busting query AND no-store. The worker answers sw.js
         from the network now, but a browser or a corporate proxy can still hold
         a copy; asking for a URL that has never existed cannot be answered from
         a cache, so "what is the newest build?" is always answered truthfully. */
      const r = await fetch('sw.js?_v=' + Date.now(), { cache: 'no-store' });
      if (!r.ok) return null;
      const t = await r.text();
      const mm = t.match(/CACHE\s*=\s*['"]([^'"]+)['"]/);
      return mm ? mm[1] : null;
    } catch (_) { return null; }
  },
  appliedVersion() { try { return localStorage.getItem('sc_pwa_applied_ver') || ''; } catch (_) { return ''; } },
  /* Ask a specific worker (waiting/installing/active) what version it is. */
  versionOf(sw) {
    return new Promise(resolve => {
      if (!sw || !sw.postMessage) return resolve(null);
      try {
        const ch = new MessageChannel();
        const t = setTimeout(() => resolve(null), 900);
        ch.port1.onmessage = e => { clearTimeout(t); resolve((e.data && e.data.version) || null); };
        sw.postMessage({ type: 'GET_VERSION' }, [ch.port2]);
      } catch (_) { resolve(null); }
    });
  },
  /* True when the running build IS the newest one — then there is nothing to offer. */
  async alreadyCurrent() {
    const latest = await this.latestVersion();
    if (!latest) return false;
    if (this.appliedVersion() === latest) return true;
    const active = this._reg && this._reg.active;
    if (active) {
      const v = await this.versionOf(active);
      if (v && v === latest) return true;
    }
    return false;
  },
  showUpdateBanner(version) {
    /* Never offer an update the platform is already running. */
    if (version && this.appliedVersion() && version === this.appliedVersion()) {
      this.hideUpdateBanner();
      return;
    }
    /* a version we are in the middle of installing is not "available" either */
    let pending = ''; try { pending = localStorage.getItem('sc_pwa_pending_ver') || ''; } catch (_) {}
    if (version && pending && version === pending) { this.hideUpdateBanner(); return; }
    /* V12.77 — the second way the banner lied: a worker that had just
       ACTIVATED posted SW_UPDATED about itself, so the page was told "a new
       version is available" about the version it was already running. The
       caller cannot know; this function can. Remember the answer briefly so a
       burst of announcements costs one probe, not four. */
    if (version) {
      const now = Date.now();
      if (!this._activeVer || now - (this._activeVerAt || 0) > 30000) {
        this._activeVerAt = now;
        this.versionOf(this._reg && this._reg.active).then(v => { this._activeVer = v; if (v && v === version) this.hideUpdateBanner(); });
      } else if (this._activeVer && this._activeVer === version) {
        this.hideUpdateBanner();
        return;
      }
    }
    if (!this._updateBanner) this.injectUpdateBanner();
    const b = this._updateBanner;
    if (!b) return;
    // Avoid spamming same version if user just dismissed
    const dismissedVer = localStorage.getItem('sc_pwa_update_dismissed_ver');
    if (dismissedVer === version) return;
    const dismissedAt = Number(localStorage.getItem('sc_pwa_update_dismissed_at') || 0);
    if (dismissedAt && Date.now() - dismissedAt < 2 * 60 * 60 * 1000) return; // 2h snooze
    const isStandalone = (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) || window.navigator.standalone === true;
    const secs = isStandalone ? 10 : 20;
    this._updateCountdownSec = secs;
    const detail = document.getElementById('pwa-update-detail');
    if (detail) detail.textContent = isStandalone ? 'Updating in' : 'Tap Update or wait';
    const cnt = document.getElementById('pwa-update-count');
    if (cnt) cnt.textContent = secs + 's';
    b.classList.add('show');
    clearInterval(this._updateCountdown);
    this._updateCountdown = setInterval(() => {
      this._updateCountdownSec -= 1;
      if (cnt) cnt.textContent = this._updateCountdownSec + 's';
      if (this._updateCountdownSec <= 0) {
        clearInterval(this._updateCountdown);
        this.applyUpdate();
      }
    }, 1000);
    // Also toast for visibility
    if (window.toast) toast('🔄 New version available! Updating in ' + secs + 's — tap to update now.', 'info', 7000);
    // Log for debugging
    console.log('[PWA] Update available', version, 'standalone:', isStandalone, 'auto in', secs + 's');
  },
  hideUpdateBanner() {
    if (this._updateBanner) this._updateBanner.classList.remove('show');
    clearInterval(this._updateCountdown);
  },
  dismissUpdate() {
    this.hideUpdateBanner();
    localStorage.setItem('sc_pwa_update_dismissed_at', Date.now().toString());
    const ver = this._waitingSW ? (this._waitingSW.scriptURL || '') : 'dismissed';
    localStorage.setItem('sc_pwa_update_dismissed_ver', ver);
    if (window.toast) toast('Update postponed. App will remind you later.', 'info', 4000);
  },
  async applyUpdate() {
    clearInterval(this._updateCountdown);
    /* Always answer the click, even if everything is already in place. */
    if (window.toast) toast('🔄 Updating to the newest version…', 'info', 4000);
    this.hideUpdateBanner();

    /* Record the version being applied BEFORE reloading, so the banner can never
       return for a build that is already running. */
    const latest = await this.latestVersion();
    try {
      if (latest) localStorage.setItem('sc_pwa_pending_ver', latest);
      localStorage.removeItem('sc_pwa_update_dismissed_ver');
      localStorage.removeItem('sc_pwa_update_dismissed_at');
    } catch (_) {}

    const waiting = this._waitingSW || (this._reg && this._reg.waiting);
    if (waiting) {
      console.log('[PWA] activating waiting SW');
      try { waiting.postMessage({ type: 'SKIP_WAITING' }); } catch (_) {}
      this._reloadSoon();
      return;
    }

    /* A worker may still be installing — activate it the moment it is ready. */
    const installing = this._reg && this._reg.installing;
    if (installing) {
      console.log('[PWA] waiting for installing SW to finish');
      const go = () => {
        try { installing.postMessage({ type: 'SKIP_WAITING' }); } catch (_) {}
        this._reloadSoon();
      };
      installing.addEventListener('statechange', () => {
        if (installing.state === 'installed' || installing.state === 'activated') go();
      });
      setTimeout(() => { if (!this._hasReloaded) this.forceReload(); }, 5000);
      return;
    }

    /* Nothing pending: pull any new worker, then load the shell fresh.
       V12.77 — and if that still leaves nothing to activate, the click must
       STILL do something, because "I pressed Update and nothing happened" is
       the report that started this. The last resort is a true reset: drop the
       cached shell, unregister the worker, and let the next load install the
       deployed build from the network. It costs one page load and it cannot
       leave a device pinned to an old build. */
    try { if (this._reg) await this._reg.update(); } catch (_) {}
    await new Promise(r => setTimeout(r, 600));
    const stillPending = this._reg && (this._reg.waiting || this._reg.installing);
    if (!stillPending) {
      console.log('[PWA] nothing to activate — performing a full reset');
      /* each step on its own: a browser that refuses one of them must not stop
         the others, or the click is dead again for a different reason */
      try { if (navigator.serviceWorker.controller && navigator.serviceWorker.controller.postMessage) navigator.serviceWorker.controller.postMessage({ type: 'CLEAR_CACHES' }); } catch (_) {}
      try { const keys = await caches.keys(); await Promise.all(keys.map(k => caches.delete(k))); } catch (_) {}
      try { if (this._reg) await this._reg.unregister(); } catch (_) {}
      try { if (window.toast) toast('Cache cleared — reloading the newest version…', 'info', 3000); } catch (_) {}
    }
    this.forceReload();
  },
  _reloadSoon() {
    setTimeout(() => { if (!this._hasReloaded) this.forceReload(); }, 1500);
  },
  forceReload() {
    if (this._hasReloaded) return;
    this._hasReloaded = true;
    // Bust any PWA-install dismissal for new version
    try { sessionStorage.setItem('sc_pwa_reloaded_for_update', Date.now().toString()); } catch (_) {}
    try {
      const u = new URL(window.location.href);
      u.searchParams.set('_u', String(Date.now()));
      window.location.replace(u.toString());
    } catch (_) {
      window.location.reload();
    }
  },

  /* V12.77 — proof, after the fact. A reload can be served by an old worker, so
     the version we aimed at is written down before the reload and confirmed
     after it: only when the RUNNING worker reports that exact version is the
     update recorded as applied and the banner retired for good. */
  async confirmApplied() {
    let pending = '';
    try { pending = localStorage.getItem('sc_pwa_pending_ver') || ''; } catch (_) {}
    if (!pending) return null;
    const active = await this.versionOf(this._reg && this._reg.active);
    if (active && active === pending) {
      try { localStorage.setItem('sc_pwa_applied_ver', pending); localStorage.removeItem('sc_pwa_pending_ver'); localStorage.removeItem('sc_pwa_update_dismissed_ver'); localStorage.removeItem('sc_pwa_update_dismissed_at'); } catch (_) {}
      this.hideUpdateBanner();
      if (window.toast) toast('✅ Updated to the newest version.', 'success', 5000);
      return active;
    }
    /* the reload did not land on the new build — keep the banner honest */
    return null;
  },

  // ---- Update checker ----
  initUpdateChecker() {
    // Hook into existing SW registrations (pages register sw.js themselves)
    // We patch navigator.serviceWorker.register to intercept future registrations
    // and also probe existing registration.
    const origRegister = navigator.serviceWorker.register.bind(navigator.serviceWorker);
    const self = this;
    navigator.serviceWorker.register = function(url, opts) {
      return origRegister(url, opts).then(reg => { self.attachRegListener(reg); return reg; });
    };
    // Probe any already-registered SW (page may have registered before this file loaded)
    if (navigator.serviceWorker.controller) {
      navigator.serviceWorker.getRegistration().then(reg => { if (reg) self.attachRegListener(reg); });
    } else {
      // Not yet controlled, but registration may still exist
      navigator.serviceWorker.getRegistration().then(reg => { if (reg) self.attachRegListener(reg); });
    }
    // Also listen for messages from SW (SW_UPDATED)
    navigator.serviceWorker.addEventListener('message', e => {
      if (e.data && e.data.type === 'SW_UPDATED') {
        console.log('[PWA] SW_UPDATED', e.data.version);
        self._waitingSW = null; // SW already active via skipWaiting+claim
        self.showUpdateBanner(e.data.version);
      }
    });
    // When new SW takes control, reload once
    let refreshing = false;
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (refreshing) return;
      refreshing = true;
      console.log('[PWA] controllerchange — new SW controlling, reloading');
      self._hasReloaded = true;
      window.location.reload();
    });
    // Periodic checks
    setInterval(() => self.checkForUpdate(), 60 * 60 * 1000); // 1h
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) self.checkForUpdate();
    });
    window.addEventListener('online', () => self.checkForUpdate());
    window.addEventListener('focus', () => self.checkForUpdate());
    window.addEventListener('pageshow', () => self.checkForUpdate());
    // Initial check after 5s (allow page to settle)
    setTimeout(() => self.checkForUpdate(), 5000);
  },
  attachRegListener(reg) {
    if (!reg || this._reg === reg) return;
    this._reg = reg;
    console.log('[PWA] attached to SW registration', reg.scope);
    this.confirmApplied().catch(() => {});
    // If there's already a waiting SW (update found while page was closed)
    if (reg.waiting) {
      console.log('[PWA] found waiting SW');
      this._waitingSW = reg.waiting;
      this.versionOf(reg.waiting).then(v => this.latestVersion().then(latest => {
        const ver = v || latest;
        if (ver && this.appliedVersion() === ver) { this.hideUpdateBanner(); return; }
        this.showUpdateBanner(ver);
      }));
    }
    reg.addEventListener('updatefound', () => {
      const nw = reg.installing;
      console.log('[PWA] updatefound', nw && nw.state);
      if (!nw) return;
      nw.addEventListener('statechange', () => {
        console.log('[PWA] installing state', nw.state);
        if (nw.state === 'installed' && navigator.serviceWorker.controller) {
          // New update ready
          this._waitingSW = reg.waiting || nw;
          this.versionOf(this._waitingSW).then(v => this.latestVersion().then(latest => {
            this.showUpdateBanner(v || latest || 'v');
          }));
        }
      });
    });
  },
  async checkForUpdate() {
    if (!this._reg) {
      try {
        const reg = await navigator.serviceWorker.getRegistration();
        if (reg) this.attachRegListener(reg);
      } catch (_) {}
    }
    if (!this._reg) return;
    // Throttle to at most every 5 min
    if (Date.now() - this._lastUpdateCheck < 5 * 60 * 1000) return;
    this._lastUpdateCheck = Date.now();
    try {
      console.log('[PWA] checking for SW update');
      await this._reg.update();
    } catch (e) {
      console.warn('[PWA] update check failed', e.message);
    }
  },

  // Exposed for manual testing / Settings page
  async manualCheck() {
    if (window.toast) toast('🔍 Checking for updates…', 'info', 2000);
    await this.checkForUpdate();
    setTimeout(() => {
      if (this._updateBanner && this._updateBanner.classList.contains('show')) {
        if (window.toast) toast('✅ Update found! Banner shown below.', 'success', 4000);
      } else {
        if (window.toast) toast('✅ App is up to date.', 'success', 3000);
      }
    }, 1500);
  }
};

window.PWAInstall = PWAInstall;
// Also expose as PWAUpdate for clarity (same object)
window.PWAUpdate = PWAInstall;

console.log('%c[School Connect v12.40] PWA install + seamless update ready.', 'color:#06b6d4;font-weight:bold');
