/* ====================================================================
   drive-sync.js — School Connect V12.22 Google Drive Backup & Sync
   ====================================================================
   Purpose: give one-time-payment schools PERMANENT ownership of their
   data. Full portable archives are written straight into the school's
   OWN Google Drive — one click to back up, one click to restore, plus
   automatic scheduled sync.

   100% FREE STACK, NO SERVER:
     • Google Identity Services (GIS) token model — free
     • Google Drive REST API v3 — free
     • Scope: drive.file — only files it created.

   V12.22 UPGRADE (from Adewale Classroom V54):
   BEFORE: backupNow only showed 3 generic toasts: Authorising, Collecting,
   Uploading — no per-table progress, no byte-level upload progress (fetch
   cannot report upload progress), so teacher watched motionless line for
   minutes on big archives. Restore had no progress at all.

   AFTER (robust, self-contained, all-inclusive, seamless):
   - backupNow reports REAL progress before completion at every stage:
     1 Authorise 2% · 2-5 Collect per table i of n (5+75*i/n) · 81-96 Upload
     REAL byte-level via XHR (fetch cannot) · 97 Record · 100 done
     Callers pass onProgress(label, info) with no consumer a floating pill
     shows same truth so even silent background sync is visible.
   - Uses XHR not fetch for upload progress
   - restoreFrom reports progress too: download + per-table import
   - Overdue banner, retry scales with urgency, interactive fallback once/day

   Inspired by Adewale Classroom drive-sync.js V54 (round 18 item 3).
   ==================================================================== */
const DriveSync = {
  SCOPE: 'https://www.googleapis.com/auth/drive.file',
  LS_KEY: 'sc-drive-sync',
  MAX_KEEP: 15,
  token: null, tokenExp: 0, _tokenClient: null, _gisLoading: null,
  cfg: { clientId: '', enabled: false, days: 7, folderId: '', lastBackup: null },
  sb() { return window.sb || null; },

  state() { try { return JSON.parse(localStorage.getItem(this.LS_KEY) || '{}'); } catch (_) { return {}; } },
  setState(patch) { try { localStorage.setItem(this.LS_KEY, JSON.stringify(Object.assign(this.state(), patch))); } catch (_) {} },

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

  /* ---------- ONE-CLICK BACKUP with REAL progress (V12.22) ---------- */
  async backupNow(opts) {
    opts = opts || {};
    const t0 = Date.now();
    if (!this.sb()) throw new Error('Database not configured.');
    if (!window.DataPortability) throw new Error('Data portability engine not loaded yet — try again in a few seconds.');
    DataPortability.init(this.sb());
    this._progress(opts, 'Authorising with Google…', { stage: 'auth', pct: 2 });
    const folderId = await this.ensureFolder(opts.interactive !== false);
    this._progress(opts, 'Backup folder ready…', { stage: 'folder', pct: 5 });
    const env = await DataPortability.collectFull(null, (i, n, table) => {
      this._progress(opts, 'Collecting “' + table + '” — table ' + i + ' of ' + n + '…', {
        stage: 'collect', pct: 5 + Math.round(75 * i / n), tables: { done: i, total: n, current: table } });
    });
    const json = JSON.stringify(env);
    const name = 'school-connect-backup-' + new Date().toISOString().replace(/[:]/g, '-').slice(0, 19) + '-' + env.meta.row_count + 'rows.json';
    this._progress(opts, 'Uploading ' + (json.length / 1048576).toFixed(2) + ' MB to Google Drive…', { stage: 'upload', pct: 81 });
    const boundary = 'scb' + Date.now() + Math.random().toString(36).slice(2);
    const body = '--' + boundary + '\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n' +
      JSON.stringify({ name, parents: [folderId], mimeType: 'application/json',
        description: 'School Connect portable backup — ' + ((window.SCHOOL && window.SCHOOL.name) || '') + ' — restorable from admin-data.html' }) +
      '\r\n--' + boundary + '\r\nContent-Type: application/json\r\n\r\n' + json + '\r\n--' + boundary + '--';
    const token = await this.getToken(opts.interactive !== false);
    const up = await this.xhrUpload('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,size', {
      'Authorization': 'Bearer ' + token,
      'Content-Type': 'multipart/related; boundary=' + boundary
    }, body, (loaded, total) => {
      const mb = (x) => (x / 1048576).toFixed(2);
      this._progress(opts, 'Uploading ' + mb(loaded) + ' of ' + mb(total) + ' MB (' + Math.round(100 * loaded / Math.max(1, total)) + '%)…', {
        stage: 'upload', pct: 81 + Math.round(15 * loaded / Math.max(1, total)), upload: { loaded, total } });
    });
    try { await this.saveCfg({ lastBackup: new Date().toISOString() }); } catch (_) {}
    try {
      if (window.sb) {
        await window.sb.from('school_settings').update({ drive_last_backup: new Date().toISOString() }).eq('id', 1);
      }
    } catch (_) {}
    this.setState({ lastBackupLocal: Date.now() });
    this._progress(opts, 'Recording the backup in the school records…', { stage: 'stamp', pct: 97 });
    this.trimOld(folderId).catch(() => {});
    this._progress(opts, '', { stage: 'done', pct: 100 });
    return { file: up, rows: env.meta.row_count, bytes: json.length, ms: Date.now() - t0 };
  },

  xhrUpload(url, headers, body, onProgress) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', url, true);
      Object.keys(headers || {}).forEach((h) => xhr.setRequestHeader(h, headers[h]));
      xhr.upload.onprogress = (ev) => { if (onProgress && ev.lengthComputable) onProgress(ev.loaded, ev.total); };
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          try { resolve(JSON.parse(xhr.responseText)); }
          catch (_) { reject(new Error('Google Drive returned an unreadable success response.')); }
        } else {
          let m = 'Google Drive error HTTP ' + xhr.status;
          try { const j = JSON.parse(xhr.responseText); m = (j.error && j.error.message) || m; } catch (_) {}
          reject(new Error(m));
        }
      };
      xhr.onerror = () => reject(new Error('The upload to Google Drive failed (network error).'));
      xhr.onabort = () => reject(new Error('The upload to Google Drive was aborted.'));
      xhr.send(body);
    });
  },

  async trimOld(folderId) {
    const list = await this.listBackups(folderId);
    for (const f of list.slice(this.MAX_KEEP)) {
      try { await this.api('/drive/v3/files/' + f.id, { method: 'DELETE', _interactive: false }); } catch (_) { break; }
    }
  },

  async listBackups(folderId) {
    folderId = folderId || await this.ensureFolder(true);
    const q = encodeURIComponent("'" + folderId + "' in parents and trashed=false and mimeType='application/json'");
    const r = await (await this.api('/drive/v3/files?q=' + q + '&orderBy=createdTime desc&pageSize=100&fields=files(id,name,size,createdTime)')).json();
    return r.files || [];
  },

  async restoreFrom(fileId, mode, onProgress) {
    if (!window.DataPortability) throw new Error('Data portability engine not loaded yet.');
    DataPortability.init(this.sb());
    const rep = { onProgress };
    this._progress(rep, 'Downloading the backup from Google Drive…', { stage: 'download', pct: 5 });
    const r = await this.api('/drive/v3/files/' + fileId + '?alt=media');
    let env; try { env = JSON.parse(await r.text()); } catch (_) { throw new Error('That file is not a valid School Connect backup.'); }
    if (!env || !env.tables) throw new Error('That file is not a School Connect portable archive.');
    const report = await DataPortability.importArchive(env, mode || 'upsert', (i, n, table, saved) => {
      this._progress(rep, 'Importing “' + table + '” — table ' + i + ' of ' + n + '…', {
        stage: 'import', pct: 10 + Math.round(85 * i / Math.max(1, n)), tables: { done: i, total: n, current: table, saved } });
    });
    this._progress(rep, '', { stage: 'done', pct: 100 });
    return report;
  },

  async deleteBackup(fileId) { await this.api('/drive/v3/files/' + fileId, { method: 'DELETE' }); },

  isPrivileged() {
    const p = window.SC_PROFILE || {};
    return ['super_admin', 'admin', 'proprietor', 'principal'].includes(p.role);
  },
  due() {
    if (!this.cfg.enabled) return false;
    const last = this.cfg.lastBackup ? Date.parse(this.cfg.lastBackup) : 0;
    return (Date.now() - last) >= this.cfg.days * 86400000;
  },

  async autoSyncCheck(fromFocus) {
    try {
      if (!this.sb() || !window.DataPortability) return;
      if (window.SCHOOL && window.SCHOOL.demo && window.SCHOOL.demo.enabled) return;
      if (!this.isPrivileged()) return;
      await this.loadCfg();
      if (!this.cfg.clientId || !this.due()) { this.overdueBanner(false); return; }
      const st = this.state();
      const last = this.cfg.lastBackup ? Date.parse(this.cfg.lastBackup) : 0;
      const overdueFactor = last ? (Date.now() - last) / (this.cfg.days * 86400000) : 2;
      const retryMs = overdueFactor >= 1 ? 30 * 60000 : 6 * 3600000;
      if (st.lastAttempt && Date.now() - st.lastAttempt < retryMs) return;
      this.setState({ lastAttempt: Date.now() });
      try {
        const r = await this.backupNow({ interactive: false });
        this.setState({ granted: true, lastAutoOk: Date.now(), interactiveAskDay: '' });
        this.overdueBanner(false);
        if (typeof toast === 'function') toast('☁️ Automatic Google Drive backup completed — ' + r.rows + ' rows saved to your Drive.', 'success', 8000);
        const el = document.getElementById('gd-status'); if (el && window.GD) GD.refreshStatus();
        return;
      } catch (silentErr) {
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
      try {
        const last = this.cfg.lastBackup ? Date.parse(this.cfg.lastBackup) : 0;
        if (this.cfg.enabled && this.cfg.clientId && (!last || Date.now() - last >= 2 * this.cfg.days * 86400000)) this.overdueBanner(true);
      } catch (_) {}
    }
  },

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

  _progress(opts, msg, info) {
    info = info || {};
    if (opts && typeof opts.onProgress === 'function') {
      try { opts.onProgress(msg, info); } catch (_) {}
      return;
    }
    this._pill(msg, info);
  },

  _pill(label, info) {
    try {
      let el = document.getElementById('sc-drive-progress');
      if (!label) { if (el) el.remove(); return; }
      if (!el) {
        el = document.createElement('div');
        el.id = 'sc-drive-progress';
        el.style.cssText = 'position:fixed;bottom:14px;right:14px;z-index:2147481000;background:#0f172a;color:#fff;font:600 12.5px/1.5 system-ui;padding:10px 14px;border-radius:12px;box-shadow:0 8px 30px rgba(0,0,0,.35);max-width:320px';
        el.innerHTML = '<div id="sc-drive-progress-label" style="margin-bottom:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>' +
          '<div style="height:6px;border-radius:3px;background:rgba(255,255,255,.25);overflow:hidden">' +
          '<div id="sc-drive-progress-bar" style="height:100%;width:2%;background:#31c48d;border-radius:3px;transition:width .25s"></div></div>';
        document.body.appendChild(el);
      }
      const lab = document.getElementById('sc-drive-progress-label');
      const bar = document.getElementById('sc-drive-progress-bar');
      if (lab) lab.textContent = '☁️ ' + label;
      if (bar && typeof info.pct === 'number') bar.style.width = Math.max(2, Math.min(100, info.pct)) + '%';
    } catch (_) {}
  }
};
window.DriveSync = DriveSync;

(function () {
  let tries = 0;
  const tick = () => {
    tries++;
    if (window.SC_PROFILE && window.DataPortability) DriveSync.autoSyncCheck();
    else if (tries < 20) setTimeout(tick, 1500);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => setTimeout(tick, 3000));
  else setTimeout(tick, 3000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) setTimeout(() => DriveSync.autoSyncCheck(true), 2000); });
  setInterval(() => { if (!document.hidden) DriveSync.autoSyncCheck(); }, 30 * 60000);
})();
