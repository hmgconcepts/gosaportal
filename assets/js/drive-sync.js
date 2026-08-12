/* ====================================================================
   drive-sync.js — School Connect V5.9 Google Drive Backup & Sync
   ====================================================================
   Purpose: give one-time-payment schools PERMANENT ownership of their
   data. Full portable archives (the same re-importable envelopes used
   by data-portability.js) are written straight into the school's OWN
   Google Drive — one click to back up, one click to restore, plus an
   automatic scheduled sync.

   100% FREE STACK, NO SERVER:
     • Google Identity Services (GIS) token model — free
     • Google Drive REST API v3 — free
     • Scope: drive.file — the app can ONLY see files it created.
       It can never read the school's other Drive documents.

   One-time setup per school (see docs/GOOGLE-DRIVE-SYNC-GUIDE.md):
   create a free Google Cloud OAuth "Web application" Client ID and
   paste it in the card on admin-data.html. The Client ID is public
   by design (it is not a secret).

   AUTO-SYNC (honest free-tier semantics): browsers cannot run when
   closed and the free stack has no server, so "automatic" means:
   whenever an owner/admin opens ANY page of the portal and the
   schedule says a backup is due, DriveSync silently requests a token
   (no popup if Google was previously authorised in this browser) and
   uploads a fresh backup in the background. With a 7-day schedule and
   normal school usage this yields continuous, hands-free backups.
   ==================================================================== */
const DriveSync = {
  SCOPE: 'https://www.googleapis.com/auth/drive.file',
  LS_KEY: 'sc-drive-sync',            // {granted:true, email, lastAttempt}
  MAX_KEEP: 15,                        // newest backups kept in Drive; older auto-trimmed
  token: null, tokenExp: 0, _tokenClient: null, _gisLoading: null,
  cfg: { clientId: '', enabled: false, days: 7, folderId: '', lastBackup: null },
  sb() { return window.sb || null; },

  /* ---------- local state ---------- */
  state() { try { return JSON.parse(localStorage.getItem(this.LS_KEY) || '{}'); } catch (_) { return {}; } },
  setState(patch) { try { localStorage.setItem(this.LS_KEY, JSON.stringify(Object.assign(this.state(), patch))); } catch (_) {} },

  /* ---------- settings stored in school_settings (shared by all admin devices) ---------- */
  async loadCfg() {
    if (!this.sb()) return this.cfg;
    try {
      const { data } = await this.sb().from('school_settings')
        .select('drive_client_id,drive_sync_enabled,drive_sync_days,drive_folder_id,drive_last_backup').eq('id', 1).maybeSingle();
      if (data) this.cfg = {
        clientId: data.drive_client_id || '',
        enabled: !!data.drive_sync_enabled,
        days: Math.max(1, Number(data.drive_sync_days) || 7),
        folderId: data.drive_folder_id || '',
        lastBackup: data.drive_last_backup || null
      };
    } catch (e) { console.warn('[DriveSync] settings load skipped:', e.message || e); }
    return this.cfg;
  },
  async saveCfg(patch) {
    Object.assign(this.cfg, patch || {});
    const row = { id: 1, drive_client_id: this.cfg.clientId, drive_sync_enabled: this.cfg.enabled,
      drive_sync_days: this.cfg.days, drive_folder_id: this.cfg.folderId };
    if (patch && 'lastBackup' in patch) row.drive_last_backup = this.cfg.lastBackup;
    const { error } = await this.sb().from('school_settings').upsert(row, { onConflict: 'id' });
    if (error) throw new Error('Could not save Drive settings: ' + error.message + ' (admin role required)');
  },

  /* ---------- Google Identity Services ---------- */
  loadGIS() {
    if (window.google && google.accounts && google.accounts.oauth2) return Promise.resolve();
    if (this._gisLoading) return this._gisLoading;
    this._gisLoading = new Promise((res, rej) => {
      const s = document.createElement('script');
      s.src = 'https://accounts.google.com/gsi/client'; s.async = true; s.defer = true;
      s.onload = res; s.onerror = () => rej(new Error('Could not load Google sign-in library (check internet connection).'));
      document.head.appendChild(s);
    });
    return this._gisLoading;
  },
  /** Get an access token. interactive=false attempts a silent grant (no popup). */
  async getToken(interactive) {
    if (this.token && Date.now() < this.tokenExp - 60000) return this.token;
    if (!this.cfg.clientId) throw new Error('Google Drive is not configured yet. Paste the school\u2019s OAuth Client ID in the Google Drive card (see docs/GOOGLE-DRIVE-SYNC-GUIDE.md).');
    await this.loadGIS();
    return new Promise((resolve, reject) => {
      let settled = false;
      const done = (fn, v) => { if (!settled) { settled = true; fn(v); } };
      try {
        this._tokenClient = google.accounts.oauth2.initTokenClient({
          client_id: this.cfg.clientId,
          scope: this.SCOPE,
          callback: (resp) => {
            if (resp && resp.access_token) {
              this.token = resp.access_token;
              this.tokenExp = Date.now() + (Number(resp.expires_in || 3600) * 1000);
              this.setState({ granted: true, lastGrant: Date.now() });
              done(resolve, this.token);
            } else done(reject, new Error((resp && (resp.error_description || resp.error)) || 'Google authorisation failed.'));
          },
          error_callback: (err) => done(reject, new Error(
            (err && err.type === 'popup_closed') ? 'Google sign-in window was closed before finishing.' :
            (err && err.type === 'popup_failed_to_open') ? 'The browser blocked the Google sign-in popup. Allow popups for this site and try again.' :
            (err && (err.message || err.type)) || 'Google authorisation failed.'))
        });
        this._tokenClient.requestAccessToken({ prompt: interactive ? 'consent' : '' });
        if (!interactive) setTimeout(() => done(reject, new Error('Silent Google authorisation timed out.')), 12000);
      } catch (e) { done(reject, e); }
    });
  },

  /* ---------- Drive REST helpers ---------- */
  async api(path, opts) {
    const t = await this.getToken(opts && opts._interactive !== false);
    const r = await fetch('https://www.googleapis.com' + path, Object.assign({}, opts, {
      headers: Object.assign({ Authorization: 'Bearer ' + t }, (opts && opts.headers) || {})
    }));
    if (r.status === 401) { this.token = null; throw new Error('Google session expired — click the button again to re-authorise.'); }
    if (!r.ok) { let m = 'Google Drive error HTTP ' + r.status; try { const j = await r.json(); m = (j.error && j.error.message) || m; } catch (_) {} throw new Error(m); }
    return r;
  },
  folderName() { return 'School Connect Backups — ' + ((window.SCHOOL && window.SCHOOL.name) || 'School'); },
  async ensureFolder(interactive) {
    if (this.cfg.folderId) {
      try { await this.api('/drive/v3/files/' + this.cfg.folderId + '?fields=id,trashed', { _interactive: interactive }); return this.cfg.folderId; }
      catch (_) { this.cfg.folderId = ''; }
    }
    const q = encodeURIComponent("name='" + this.folderName().replace(/'/g, "\\'") + "' and mimeType='application/vnd.google-apps.folder' and trashed=false");
    const found = await (await this.api('/drive/v3/files?q=' + q + '&fields=files(id)', { _interactive: interactive })).json();
    let id = found.files && found.files[0] && found.files[0].id;
    if (!id) {
      const created = await (await this.api('/drive/v3/files?fields=id', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, _interactive: interactive,
        body: JSON.stringify({ name: this.folderName(), mimeType: 'application/vnd.google-apps.folder' })
      })).json();
      id = created.id;
    }
    try { await this.saveCfg({ folderId: id }); } catch (_) { this.cfg.folderId = id; }
    return id;
  },

  /* ---------- ONE-CLICK BACKUP ---------- */
  async backupNow(opts) {
    opts = opts || {};
    if (!this.sb()) throw new Error('Database not configured.');
    if (!window.DataPortability) throw new Error('Data portability engine not loaded yet — try again in a few seconds.');
    DataPortability.init(this.sb());
    this._progress(opts, 'Authorising with Google…');
    const folderId = await this.ensureFolder(opts.interactive !== false);
    this._progress(opts, 'Collecting all tables (this can take a minute)…');
    const env = await DataPortability.collectFull();
    const json = JSON.stringify(env);
    const name = 'school-connect-backup-' + new Date().toISOString().replace(/[:]/g, '-').slice(0, 19) + '-' + env.meta.row_count + 'rows.json';
    this._progress(opts, 'Uploading ' + (json.length / 1048576).toFixed(2) + ' MB to Google Drive…');
    const boundary = 'scb' + Date.now() + Math.random().toString(36).slice(2);
    const body = '--' + boundary + '\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n' +
      JSON.stringify({ name, parents: [folderId], mimeType: 'application/json',
        description: 'School Connect portable backup — ' + ((window.SCHOOL && window.SCHOOL.name) || '') + ' — restorable from admin-data.html' }) +
      '\r\n--' + boundary + '\r\nContent-Type: application/json\r\n\r\n' + json + '\r\n--' + boundary + '--';
    const up = await (await this.api('/upload/drive/v3/files?uploadType=multipart&fields=id,name,size', {
      method: 'POST', headers: { 'Content-Type': 'multipart/related; boundary=' + boundary }, body, _interactive: opts.interactive !== false
    })).json();
    try { await this.saveCfg({ lastBackup: new Date().toISOString() }); } catch (_) {}
    this.setState({ lastBackupLocal: Date.now() });
    this.trimOld(folderId).catch(() => {});
    this._progress(opts, '');
    return { file: up, rows: env.meta.row_count, bytes: json.length };
  },
  async trimOld(folderId) {
    const list = await this.listBackups(folderId);
    for (const f of list.slice(this.MAX_KEEP)) {
      try { await this.api('/drive/v3/files/' + f.id, { method: 'DELETE', _interactive: false }); } catch (_) { break; }
    }
  },

  /* ---------- LIST / RESTORE / DELETE ---------- */
  async listBackups(folderId) {
    folderId = folderId || await this.ensureFolder(true);
    const q = encodeURIComponent("'" + folderId + "' in parents and trashed=false and mimeType='application/json'");
    const r = await (await this.api('/drive/v3/files?q=' + q + '&orderBy=createdTime desc&pageSize=100&fields=files(id,name,size,createdTime)')).json();
    return r.files || [];
  },
  async restoreFrom(fileId, mode) {
    if (!window.DataPortability) throw new Error('Data portability engine not loaded yet.');
    DataPortability.init(this.sb());
    const r = await this.api('/drive/v3/files/' + fileId + '?alt=media');
    let env; try { env = JSON.parse(await r.text()); } catch (_) { throw new Error('That file is not a valid School Connect backup.'); }
    if (!env || !env.tables) throw new Error('That file is not a School Connect portable archive.');
    return DataPortability.importArchive(env, mode || 'upsert');
  },
  async deleteBackup(fileId) { await this.api('/drive/v3/files/' + fileId, { method: 'DELETE' }); },

  /* ---------- AUTOMATIC SYNC ---------- */
  isPrivileged() {
    const p = window.SC_PROFILE || {};
    return ['super_admin', 'admin', 'proprietor', 'principal'].includes(p.role);
  },
  due() {
    if (!this.cfg.enabled) return false;
    const last = this.cfg.lastBackup ? Date.parse(this.cfg.lastBackup) : 0;
    return (Date.now() - last) >= this.cfg.days * 86400000;
  },
  /* V9.4 (#11) TRULY AUTOMATIC SYNC. Why manual backups were still needed:
       (a) one failed attempt froze retries for 6 HOURS — a single popup-blocked
           silent token on the day's first visit killed the whole day's backup;
       (b) a silent-grant failure quit for good instead of asking ONCE;
       (c) overdue-ness didn't change behaviour — day 1 late and day 20 late
           were treated the same. All three fixed:
       • retry interval now scales with urgency: 30 min when overdue (was 6 h);
       • if the silent grant fails but the backup is DUE and the tab is
         focused, ONE interactive consent prompt is allowed per day — the
         admin clicks "Allow" a single time and Drive backups flow again;
       • a persistent red banner appears when backups are ≥2 cycles overdue
         so the failure mode is loudly visible instead of a silent gap;
       • re-checks on tab refocus (not just first load). */
  async autoSyncCheck(fromFocus) {
    try {
      if (!this.sb() || !window.DataPortability) return;
      if (window.SCHOOL && window.SCHOOL.demo && window.SCHOOL.demo.enabled) return;   // never auto-sync the public demo
      if (!this.isPrivileged()) return;
      await this.loadCfg();
      if (!this.cfg.clientId || !this.due()) { this.overdueBanner(false); return; }
      const st = this.state();
      const last = this.cfg.lastBackup ? Date.parse(this.cfg.lastBackup) : 0;
      const overdueFactor = last ? (Date.now() - last) / (this.cfg.days * 86400000) : 2;
      const retryMs = overdueFactor >= 1 ? 30 * 60000 : 6 * 3600000;                   // urgent → every 30 min
      if (st.lastAttempt && Date.now() - st.lastAttempt < retryMs) return;
      this.setState({ lastAttempt: Date.now() });
      try {
        const r = await this.backupNow({ interactive: false });                        // silent token first
        this.setState({ granted: true, lastAutoOk: Date.now(), interactiveAskDay: '' });
        this.overdueBanner(false);
        if (typeof toast === 'function') toast('☁️ Automatic Google Drive backup completed — ' + r.rows + ' rows saved to your Drive.', 'success', 8000);
        const el = document.getElementById('gd-status'); if (el && window.GD) GD.refreshStatus();
        return;
      } catch (silentErr) {
        // Silent path failed. If DUE and the tab is visible, ask interactively —
        // at most once per day — so automation heals itself with one click.
        const today = new Date().toISOString().slice(0, 10);
        if (!document.hidden && st.interactiveAskDay !== today) {
          this.setState({ interactiveAskDay: today });
          if (typeof toast === 'function') toast('☁️ Scheduled Drive backup is due — approving Google access now (one click)…', 'info', 6000);
          const r2 = await this.backupNow({ interactive: true });
          this.setState({ granted: true, lastAutoOk: Date.now() });
          this.overdueBanner(false);
          if (typeof toast === 'function') toast('☁️ Google Drive backup completed — ' + r2.rows + ' rows saved. Future backups run silently.', 'success', 9000);
          return;
        }
        throw silentErr;
      }
    } catch (e) {
      console.warn('[DriveSync] auto-sync attempt failed:', e.message || e);
      // loud, persistent overdue banner at ≥2 missed cycles
      try {
        const last = this.cfg.lastBackup ? Date.parse(this.cfg.lastBackup) : 0;
        if (this.cfg.enabled && this.cfg.clientId && (!last || Date.now() - last >= 2 * this.cfg.days * 86400000)) this.overdueBanner(true);
      } catch (_) {}
    }
  },
  /* Persistent overdue strip (admins only) — impossible to miss. */
  overdueBanner(show) {
    try {
      let el = document.getElementById('sc-drive-overdue');
      if (!show) { if (el) el.remove(); return; }
      if (el || !this.isPrivileged()) return;
      el = document.createElement('div');
      el.id = 'sc-drive-overdue';
      el.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:2147482000;background:#b91c1c;color:#fff;font:600 13px/1.5 system-ui;padding:8px 14px;text-align:center';
      el.innerHTML = '☁️⚠️ Google Drive backups are OVERDUE (2+ cycles missed). <a href="admin-data.html" style="color:#fff;text-decoration:underline">Open Admin Data → Google Drive Backup</a> and click “Back up now” — or simply stay on any page and approve the Google prompt when it appears. <span style="cursor:pointer;padding:0 8px" onclick="this.parentNode.remove()">✕</span>';
      document.body.appendChild(el);
    } catch (_) {}
  },
  _progress(opts, msg) {
    if (opts && typeof opts.onProgress === 'function') { try { opts.onProgress(msg); } catch (_) {} }
    else if (msg && typeof toast === 'function' && opts && opts.interactive !== false) toast(msg, 'info', 2500);
  }
};
window.DriveSync = DriveSync;

/* Auto-sync trigger: wait for auth/profile bootstrap, then check the schedule.
   Runs on every page so a due backup happens no matter where the admin lands. */
(function () {
  let tries = 0;
  const tick = () => {
    tries++;
    if (window.SC_PROFILE && window.DataPortability) DriveSync.autoSyncCheck();
    else if (tries < 20) setTimeout(tick, 1500);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => setTimeout(tick, 3000));
  else setTimeout(tick, 3000);
  /* V9.4 (#11): re-check when the admin returns to the tab, and every 30 min
     while a portal tab stays open — a due backup no longer needs a reload. */
  document.addEventListener('visibilitychange', () => { if (!document.hidden) setTimeout(() => DriveSync.autoSyncCheck(true), 2000); });
  setInterval(() => { if (!document.hidden) DriveSync.autoSyncCheck(); }, 30 * 60000);
})();
