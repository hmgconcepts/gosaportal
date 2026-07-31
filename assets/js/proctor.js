/* ====================================================================
   proctor.js — School Connect V6.3 CBT Exam Proctoring (free-stack)
   ====================================================================
   Optional, per-exam toggles set by the teacher on the CBT manager:
     • camera:true         → 📸 intermittent webcam snapshots during the
                             attempt (about once a minute, small JPEGs)
     • audio_monitor:true  → 🎙️ microphone loudness watch: when sustained
                             talking/noise is detected it logs a violation
                             AND takes an extra snapshot. No audio is ever
                             recorded or stored — only loudness levels are
                             sampled, so it is privacy-safe.

   Storage: snapshots go to the private Supabase FILE-STORAGE bucket
   "proctor" (created by database/v6.3-role-access-fixes.sql — included
   in complete-schema.sql). They use the 1 GB file space, NOT the 500 MB
   database. Students can only upload; ONLY staff/teachers can list,
   review and delete. The CBT manager has a review modal with per-image
   and one-click "delete all" cleanup.

   Consent & transparency: the browser itself asks the student to allow
   camera/microphone. If permission is refused the exam still runs and
   a violation entry records that monitoring was declined.
   ==================================================================== */
const Proctor = {
  BUCKET: 'proctor',
  SNAP_EVERY_MS: 60000,          // ~1 snapshot per minute
  SNAP_JITTER_MS: 20000,         // ± random jitter so timing is unpredictable
  AUDIO_THRESHOLD: 0.22,         // normalised loudness considered "talking"
  AUDIO_SUSTAIN_MS: 2500,        // must stay loud this long to count
  _stream: null, _video: null, _timer: null, _audioCtx: null, _raf: null,
  _loudSince: 0, _lastAudioHit: 0, active: false, snaps: 0, audioHits: 0,
  _ctx: { exam: '', candidate: '' }, _onEvent: null,
  sb() { return window.sb || null; },

  slug(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'x'; },

  /** Start monitoring. cfg = exam.anti_cheat_config; onEvent(type, detail) feeds the violation log. */
  async start(cfg, examCode, candidateName, onEvent) {
    cfg = cfg || {};
    if (!cfg.camera && !cfg.audio_monitor) return { camera: false, audio: false };
    this._ctx = { exam: this.slug(examCode), candidate: this.slug(candidateName) + '-' + Date.now().toString(36) };
    this._onEvent = onEvent || function () {};
    const want = { video: !!cfg.camera, audio: !!cfg.audio_monitor };
    try {
      this._stream = await navigator.mediaDevices.getUserMedia(want);
    } catch (e) {
      this._onEvent('proctor_declined', 'Camera/microphone permission was not granted (' + (e.name || e.message) + ')');
      return { camera: false, audio: false, declined: true };
    }
    this.active = true;
    if (want.video) {
      this._video = document.createElement('video');
      this._video.muted = true; this._video.playsInline = true;
      this._video.srcObject = this._stream;
      try { await this._video.play(); } catch (_) {}
      this._scheduleSnap(4000 + Math.random() * 4000);      // first snapshot shortly after start
    }
    if (want.audio) this._startAudioWatch();
    this._onEvent('proctor_started', (want.video ? '📸 camera snapshots ' : '') + (want.audio ? '🎙️ audio monitoring' : ''));
    return { camera: want.video, audio: want.audio };
  },

  _scheduleSnap(delay) {
    if (!this.active) return;
    this._timer = setTimeout(async () => {
      await this.snap('interval');
      this._scheduleSnap(this.SNAP_EVERY_MS + (Math.random() * 2 - 1) * this.SNAP_JITTER_MS);
    }, delay == null ? this.SNAP_EVERY_MS : delay);
  },

  /** Capture one webcam frame and upload it as a small JPEG to the proctor bucket. */
  async snap(reason) {
    try {
      if (!this.active || !this._video || !this.sb() || this._video.readyState < 2) return;
      const c = document.createElement('canvas');
      const w = 480, h = Math.round(480 * (this._video.videoHeight || 3) / (this._video.videoWidth || 4));
      c.width = w; c.height = h;
      c.getContext('2d').drawImage(this._video, 0, 0, w, h);
      const blob = await new Promise(res => c.toBlob(res, 'image/jpeg', 0.55));
      if (!blob) return;
      const path = this._ctx.exam + '/' + this._ctx.candidate + '/' + Date.now() + '-' + (reason || 'interval') + '.jpg';
      const up = await this.sb().storage.from(this.BUCKET).upload(path, blob, { contentType: 'image/jpeg', upsert: false });
      if (!up.error) { this.snaps++; }
      else if (this.snaps === 0) console.warn('[Proctor] upload failed:', up.error.message, '— run database/v6.3-role-access-fixes.sql to create the proctor bucket.');
    } catch (e) { console.warn('[Proctor] snapshot skipped:', e.message || e); }
  },

  _startAudioWatch() {
    try {
      const AC = window.AudioContext || window.webkitAudioContext;
      this._audioCtx = new AC();
      const src = this._audioCtx.createMediaStreamSource(this._stream);
      const analyser = this._audioCtx.createAnalyser();
      analyser.fftSize = 512; src.connect(analyser);
      const buf = new Uint8Array(analyser.frequencyBinCount);
      const loop = () => {
        if (!this.active) return;
        analyser.getByteFrequencyData(buf);
        let sum = 0; for (let i = 2; i < buf.length; i++) sum += buf[i];
        const level = sum / (buf.length - 2) / 255;
        const now = Date.now();
        if (level > this.AUDIO_THRESHOLD) {
          if (!this._loudSince) this._loudSince = now;
          if (now - this._loudSince > this.AUDIO_SUSTAIN_MS && now - this._lastAudioHit > 30000) {
            this._lastAudioHit = now; this.audioHits++;
            this._onEvent('audio_noise', 'Sustained talking/noise detected near the candidate (level ' + level.toFixed(2) + ')');
            this.snap('audio-alert');                        // photo evidence at the moment of noise
          }
        } else this._loudSince = 0;
        this._raf = setTimeout(loop, 400);                   // ~2.5 samples/sec — negligible CPU
      };
      loop();
    } catch (e) { console.warn('[Proctor] audio watch unavailable:', e.message || e); }
  },

  stop() {
    this.active = false;
    if (this._timer) clearTimeout(this._timer);
    if (this._raf) clearTimeout(this._raf);
    try { if (this._audioCtx) this._audioCtx.close(); } catch (_) {}
    try { (this._stream ? this._stream.getTracks() : []).forEach(t => t.stop()); } catch (_) {}
    this._stream = this._video = this._timer = this._audioCtx = this._raf = null;
  },

  /* ---------------- Teacher review side (CBT manager) ---------------- */
  async listForExam(examCode) {
    const db = this.sb(); if (!db) throw new Error('Database not configured.');
    const root = this.slug(examCode); const out = [];
    const top = await db.storage.from(this.BUCKET).list(root, { limit: 200 });
    if (top.error) throw new Error(top.error.message + ' — has database/v6.3-role-access-fixes.sql been run (creates the proctor bucket)?');
    for (const entry of (top.data || [])) {
      if (entry.id) { out.push({ path: root + '/' + entry.name, size: (entry.metadata || {}).size || 0, created: entry.created_at }); continue; }
      const sub = await db.storage.from(this.BUCKET).list(root + '/' + entry.name, { limit: 500 });
      for (const f of (sub.data || [])) if (f.id) out.push({ path: root + '/' + entry.name + '/' + f.name, candidate: entry.name, size: (f.metadata || {}).size || 0, created: f.created_at });
    }
    return out.sort((a, b) => String(a.path).localeCompare(String(b.path)));
  },
  async signedUrl(path) {
    const r = await this.sb().storage.from(this.BUCKET).createSignedUrl(path, 600);
    if (r.error) throw new Error(r.error.message);
    return r.data.signedUrl;
  },
  async remove(paths) {
    const list = Array.isArray(paths) ? paths : [paths];
    for (let i = 0; i < list.length; i += 100) {
      const r = await this.sb().storage.from(this.BUCKET).remove(list.slice(i, i + 100));
      if (r.error) throw new Error(r.error.message);
    }
  }
};
window.Proctor = Proctor;
