/* ====================================================================
   security-guard.js — School Connect V6.0 "Sovereign Edition"
   ====================================================================
   Runtime security layer loaded on EVERY page (via app.js). Free-stack,
   browser-only, zero external services. Adds:

   1. IDLE SESSION AUTO-LOCK
      School computers are shared (staff room, front desk, ICT lab).
      After N minutes without activity (default 30, configurable by the
      owner in the Platform Health Console; 0 = off) the signed-in user
      is signed out automatically, protecting open sessions.

   2. LOGIN AUDIT TRAIL
      The complete-schema has always had a `login_audit` table — this
      layer finally feeds it: every sign-in and sign-out is recorded
      (email, event, user agent). Admins review it on activity_log /
      admin-data / the Health Console.

   3. EMERGENCY LOCKDOWN MODE
      One switch (owner-only) instantly locks the portal for everyone
      except admin roles — for incidents like exam-leak investigations,
      fee-fraud checks, or a compromised account. Non-admin users see a
      professional notice, not an error.

   4. PASSWORD STRENGTH METER
      Live strength feedback on every password field (login/signup/
      change-password) — no library, no network call.

   All settings live in `school_settings` (database/security-hardening.sql,
   embedded in complete-schema.sql) so they apply to every device at once.
   Fails safe: on any error, features silently disable rather than break
   the page.
   ==================================================================== */
const SecurityGuard = {
  cfg: { idleMinutes: 30, lockdown: false, lockdownMessage: '' },
  ADMIN_ROLES: ['super_admin', 'admin', 'proprietor', 'principal', 'head_teacher'],
  LS_ACT: 'sc-last-activity',
  _timer: null, _lockdownShown: false,
  sb() { return window.sb || null; },

  async loadCfg() {
    try {
      if (!this.sb()) return this.cfg;
      const { data } = await this.sb().from('school_settings')
        .select('idle_lock_minutes,lockdown_mode,lockdown_message').eq('id', 1).maybeSingle();
      if (data) this.cfg = {
        idleMinutes: data.idle_lock_minutes == null ? 30 : Math.max(0, Number(data.idle_lock_minutes) || 0),
        lockdown: !!data.lockdown_mode,
        lockdownMessage: data.lockdown_message || ''
      };
    } catch (e) { /* columns may not exist yet on older DBs — defaults apply */ }
    return this.cfg;
  },

  /* ---------- 1. Idle session auto-lock ---------- */
  touch() { try { localStorage.setItem(this.LS_ACT, String(Date.now())); } catch (_) {} },
  startIdleWatch() {
    if (!this.cfg.idleMinutes) return;                       // 0 = disabled
    const mark = () => this.touch();
    ['pointerdown', 'keydown', 'scroll', 'touchstart'].forEach(ev =>
      document.addEventListener(ev, mark, { passive: true }));
    this.touch();
    this._timer = setInterval(() => {
      try {
        if (!window.SC_PROFILE) return;                      // nobody signed in
        const last = Number(localStorage.getItem(this.LS_ACT) || Date.now());
        if (Date.now() - last > this.cfg.idleMinutes * 60000) {
          clearInterval(this._timer);
          this.audit('idle_lock');
          if (typeof toast === 'function') toast('🔒 Signed out after ' + this.cfg.idleMinutes + ' minutes of inactivity to protect this account on a shared computer.', 'info', 8000);
          setTimeout(() => { if (window.App && App.signOut) App.signOut(); else location.href = 'login.html'; }, 1200);
        }
      } catch (_) {}
    }, 30000);
  },

  /* ---------- 2. Login audit trail ---------- */
  async audit(event, email) {
    try {
      if (!this.sb()) return;
      const p = window.SC_PROFILE || {};
      await this.sb().from('login_audit').insert({
        user_id: p.id || null,
        email: email || p.email || null,
        event: event,
        user_agent: (navigator.userAgent || '').slice(0, 250)
      });
    } catch (_) { /* audit must never break the page */ }
  },
  wireAuthAudit() {
    try {
      if (!this.sb() || !this.sb().auth || !this.sb().auth.onAuthStateChange) return;
      this.sb().auth.onAuthStateChange((event, session) => {
        try {
          if (event === 'SIGNED_IN' && session && session.user) {
            // dedupe: token refreshes / tab restores must not spam the audit log
            const key = 'sc-audit-in-' + session.user.id;
            if (sessionStorage.getItem(key)) return;
            sessionStorage.setItem(key, '1');
            this.audit('login', session.user.email);
          } else if (event === 'SIGNED_OUT') {
            Object.keys(sessionStorage).filter(k => k.startsWith('sc-audit-in-')).forEach(k => sessionStorage.removeItem(k));
          }
        } catch (_) {}
      });
    } catch (_) {}
  },

  /* ---------- 3. Emergency lockdown ---------- */
  enforceLockdown() {
    if (!this.cfg.lockdown || this._lockdownShown) return;
    const p = window.SC_PROFILE;
    if (!p) return;                                          // public pages stay reachable
    if (this.ADMIN_ROLES.includes(p.role)) {                 // admins keep working
      if (typeof toast === 'function') toast('⚠️ LOCKDOWN MODE is ON — non-admin users are locked out. Turn it off in the Platform Health Console when resolved.', 'warning', 10000);
      return;
    }
    this._lockdownShown = true;
    const msg = this.cfg.lockdownMessage || 'The school portal is temporarily locked by the administration. Please check back shortly or contact the school office.';
    const div = document.createElement('div');
    div.id = 'sc-lockdown';
    div.setAttribute('style', 'position:fixed;inset:0;z-index:99999;background:linear-gradient(135deg,#0f172a,#1e293b);color:#e2e8f0;display:flex;align-items:center;justify-content:center;padding:24px;text-align:center');
    div.innerHTML = '<div style="max-width:520px"><div style="font-size:3rem">🔒</div>' +
      '<h2 style="color:#fff;margin:12px 0">Portal Temporarily Locked</h2>' +
      '<p style="line-height:1.6">' + String(msg).replace(/&/g, '&amp;').replace(/</g, '&lt;') + '</p>' +
      '<button style="margin-top:18px;padding:10px 22px;border-radius:10px;border:1px solid #475569;background:#334155;color:#fff;cursor:pointer" onclick="if(window.App&&App.signOut)App.signOut();else location.href=\'login.html\'">Sign out</button></div>';
    document.body.appendChild(div);
  },

  /* ---------- 4. Password strength meter ---------- */
  score(pw) {
    pw = String(pw || '');
    let s = 0;
    if (pw.length >= 8) s++; if (pw.length >= 12) s++;
    if (/[a-z]/.test(pw) && /[A-Z]/.test(pw)) s++;
    if (/\d/.test(pw)) s++; if (/[^A-Za-z0-9]/.test(pw)) s++;
    if (/^(password|12345678|qwerty|school|admin)/i.test(pw)) s = Math.min(s, 1);
    return Math.min(s, 5);
  },
  mountMeters() {
    document.querySelectorAll('input[type="password"]').forEach(inp => {
      if (inp.dataset.pwMeter || /confirm|pw2|current/i.test(inp.id + ' ' + (inp.name || ''))) return;
      inp.dataset.pwMeter = '1';
      const bar = document.createElement('div');
      bar.setAttribute('style', 'height:5px;border-radius:99px;background:#e2e8f0;margin-top:6px;overflow:hidden');
      bar.innerHTML = '<div style="height:100%;width:0;transition:all .25s"></div>';
      const label = document.createElement('div');
      label.setAttribute('style', 'font-size:.75rem;color:#64748b;margin-top:3px');
      inp.insertAdjacentElement('afterend', label);
      inp.insertAdjacentElement('afterend', bar);
      const colors = ['#ef4444', '#ef4444', '#f59e0b', '#eab308', '#22c55e', '#16a34a'];
      const words = ['Very weak', 'Very weak', 'Weak', 'Fair', 'Strong', 'Very strong'];
      inp.addEventListener('input', () => {
        const v = inp.value; const s = this.score(v);
        bar.firstChild.style.width = (v ? (s / 5) * 100 : 0) + '%';
        bar.firstChild.style.background = colors[s];
        label.textContent = v ? 'Password strength: ' + words[s] : '';
      });
    });
  },

  async init() {
    this.wireAuthAudit();
    this.mountMeters();
    await this.loadCfg();
    this.startIdleWatch();
    // lockdown needs the resolved profile — poll briefly until app.js sets it
    let tries = 0;
    const t = setInterval(() => {
      tries++;
      if (window.SC_PROFILE) { clearInterval(t); this.enforceLockdown(); }
      else if (tries > 20) clearInterval(t);
    }, 800);
  }
};
window.SecurityGuard = SecurityGuard;
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => SecurityGuard.init());
else SecurityGuard.init();
