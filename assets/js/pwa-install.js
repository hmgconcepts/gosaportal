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
  showUpdateBanner(version) {
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
  applyUpdate() {
    clearInterval(this._updateCountdown);
    if (this._waitingSW) {
      console.log('[PWA] Activating waiting SW');
      this._waitingSW.postMessage({type: 'SKIP_WAITING'});
    } else if (this._reg && this._reg.waiting) {
      this._reg.waiting.postMessage({type: 'SKIP_WAITING'});
    } else {
      console.log('[PWA] No waiting SW, reloading');
      this.forceReload();
    }
    // Fallback reload if controllerchange doesn't fire in 2s (e.g., SW already skipWaiting)
    setTimeout(() => {
      if (!this._hasReloaded) {
        console.log('[PWA] Fallback reload after SKIP_WAITING');
        this.forceReload();
      }
    }, 1500);
  },
  forceReload() {
    if (this._hasReloaded) return;
    this._hasReloaded = true;
    // Bust any PWA-install dismissal for new version
    try { sessionStorage.setItem('sc_pwa_reloaded_for_update', Date.now().toString()); } catch (_) {}
    window.location.reload();
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
    // If there's already a waiting SW (update found while page was closed)
    if (reg.waiting) {
      console.log('[PWA] found waiting SW');
      this._waitingSW = reg.waiting;
      this.showUpdateBanner(reg.waiting.scriptURL);
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
          const ver = (reg.waiting && reg.waiting.scriptURL) || nw.scriptURL || 'v';
          this.showUpdateBanner(ver);
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
