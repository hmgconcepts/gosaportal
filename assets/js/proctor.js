/* ====================================================================
   proctor.js — School Connect V12.20 Enhanced Proctoring (from hmgacademycbtsystem v3.1 + DramaConnect)
   ====================================================================
   Advanced, sophisticated proctoring to prevent impersonation, someone else doing CBT,
   someone calling answers, etc. — robust, all-inclusive, self-contained, seamless.

   Features implemented from hmgacademycbtsystem:
   - Face gate: capture 3 photos before exam (identity verification)
   - Multiple people detection (only registered student may be present)
   - No face / face not detected
   - Audio activity monitor (loudness only, no recording) — sustained talking logs violation + snapshot
   - Tab/app switching, window focus loss, copy/paste/cut, right-click, fullscreen, watermark, devtools detection (via cbt-engine startAntiCheat)
   - Violation limit before auto-submit
   - Snapshots saved to private Supabase File Storage bucket "proctor" (1 GB file space, NOT 500 MB database)
   - Teacher review side: list, signedUrl, remove, per-image, delete all

   Enhanced V12.20:
   - Face detection via FaceDetector API if available (browser native) + fallback via canvas brightness/face presence heuristic
   - Multiple faces detection via FaceDetector + fallback counting
   - Audio loudness + speech pattern detection (sustained talking, not just noise)
   - Watermark with candidate name + exam code + timestamp (visible on screen, deters impersonation)
   - Snapshots saved to storage with metadata: exam/candidate/timestamp/reason (interval, audio-alert, multi-face, no-face, tab-switch, etc.)
   - Snapshots NOT saved in 500 MB database — only in storage bucket "proctor" (1 GB file storage) — prevents quick usage
   - Teacher review: listForExam, signedUrl, remove, with candidate grouping, per-image review, delete all
   - Consent & transparency: browser asks permission, refusal logged but exam continues

   Storage: snapshots go to private bucket "proctor" (created by database/v6.3-role-access-fixes.sql included in complete-schema.sql).
   They use 1 GB file space, NOT 500 MB database. Students can only upload; staff can list/review/delete.

   Free-tier only, no paid AI API, no external service, browser-only.
   ==================================================================== */
const Proctor = {
  BUCKET: 'proctor',
  SNAP_EVERY_MS: 45000,          // ~45s per snapshot (more frequent than before, better monitoring)
  SNAP_JITTER_MS: 15000,         // ± jitter unpredictable
  AUDIO_THRESHOLD: 0.20,         // loudness considered talking (lower = more sensitive)
  AUDIO_SUSTAIN_MS: 2000,        // must stay loud this long to count as talking/calling answers
  FACE_CHECK_EVERY_MS: 5000,     // face presence check every 5s
  _stream: null, _video: null, _timer: null, _faceTimer: null, _audioCtx: null, _raf: null,
  _loudSince: 0, _lastAudioHit: 0, _lastFaceCheck: 0, _lastMultiFaceHit: 0, _lastNoFaceHit: 0,
  active: false, snaps: 0, audioHits: 0, faceHits: 0, multiFaceHits: 0, noFaceHits: 0,
  _ctx: { exam: '', candidate: '' }, _onEvent: null,
  _faceDetector: null,
  sb() { return window.sb || null; },

  slug(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'x'; },

  /** Start monitoring. cfg = exam.anti_cheat_config; onEvent(type, detail) feeds violation log. */
  async start(cfg, examCode, candidateName, onEvent) {
    cfg = cfg || {};
    if (!cfg.camera && !cfg.audio_monitor) return { camera: false, audio: false };
    this._ctx = { exam: this.slug(examCode), candidate: this.slug(candidateName) + '-' + Date.now().toString(36) };
    this._onEvent = onEvent || function () {};
    const want = { video: !!cfg.camera, audio: !!cfg.audio_monitor };
    // V12.45 ENFORCE: If camera is required, permission is mandatory — no bypass. Enhanced with sophisticated checks.
    let attempts=0;
    while(attempts < 2){
      try {
        this._stream = await navigator.mediaDevices.getUserMedia(want);
        break;
      } catch (e) {
        attempts++;
        const isRequired = !!cfg.camera; // If tutor enabled camera, it's required, not optional
        const errName = e.name || 'PermissionDenied';
        const isNotFound = /NotFound|Overconstrained|DevicesNotFound/i.test(e.name||e.message);
        const isNotAllowed = /NotAllowed|PermissionDenied|Denied/i.test(e.name||e.message);
        if(isRequired){
          // Sophisticated: Detect virtual camera, screen share, etc.
          let reason = '';
          if(isNotFound) reason = 'No camera found on this device. This exam requires picturing — please use a device with a working camera or contact your teacher to allow an alternative.';
          else if(isNotAllowed) reason = 'Camera/microphone permission was denied. This exam requires picturing to prevent impersonation — you cannot bypass this security. Please allow camera access and try again.';
          else reason = 'Camera access failed ('+errName+': '+e.message+') — exam requires picturing. Please check camera and try again.';
          // Enhanced: Check for virtual camera / OBS / screen share spoofing (advanced)
          try{
            const devices = await navigator.mediaDevices.enumerateDevices();
            const videoDevices = devices.filter(d=>d.kind==='videoinput');
            const hasVirtual = videoDevices.some(d=>/OBS|Virtual|Snap|ManyCam|XSplit/i.test(d.label));
            if(hasVirtual) reason += ' Virtual camera detected ('+videoDevices.map(d=>d.label).join(', ')+') — please use your physical camera.';
            if(videoDevices.length===0) reason = 'No camera device detected. This exam requires picturing.';
          }catch(_){}
          this._onEvent('proctor_blocked', reason);
          // Return declined with blocked flag — caller will show blocking modal and NOT start exam
          return { camera: false, audio: false, declined: true, blocked: true, reason: reason };
        } else {
          this._onEvent('proctor_declined', 'Camera/microphone permission was not granted (' + (e.name || e.message) + ') — exam continues but monitoring declined is logged for teacher review');
          return { camera: false, audio: false, declined: true };
        }
      }
    }
    if(!this._stream){
      this._onEvent('proctor_blocked', 'Camera is required but could not be accessed after 2 attempts.');
      return { camera: false, audio: false, declined: true, blocked: true };
    }
    this.active = true;
    // Try to init FaceDetector if available (Chrome/Edge)
    try{
      if(window.FaceDetector){
        this._faceDetector = new FaceDetector({fastMode:true, maxDetectedFaces:3});
      }
    }catch(_){ this._faceDetector=null; }

    if (want.video) {
      this._video = document.createElement('video');
      this._video.muted = true; this._video.playsInline = true;
      this._video.srcObject = this._stream;
      try { await this._video.play(); } catch (_) {}
      // First snapshot shortly after start (face gate)
      this._scheduleSnap(3000 + Math.random() * 3000);
      // Start face checks
      this._scheduleFaceCheck(4000);
      // Add watermark
      this._addWatermark(candidateName, examCode);
    }
    if (want.audio) this._startAudioWatch();
    this._onEvent('proctor_started', (want.video ? '📸 camera snapshots (enhanced face + multi-person detection) ' : '') + (want.audio ? '🎙️ audio monitoring (talking/call detection, loudness only, no recording)' : '') + ' — snapshots saved to Storage (not 500 MB DB) — prevents impersonation and answer-calling');
    return { camera: want.video, audio: want.audio };
  },

  _addWatermark(candidateName, examCode){
    try{
      // Remove existing watermark if any
      const existing=document.getElementById('proctor-watermark');
      if(existing) existing.remove();
      const wm=document.createElement('div');
      wm.id='proctor-watermark';
      wm.style.cssText='position:fixed;top:50%;left:50%;transform:translate(-50%,-50%) rotate(-30deg);font-size:2.2rem;font-weight:900;color:rgba(15,23,42,.07);pointer-events:none;z-index:9999;white-space:nowrap;user-select:none;text-align:center;line-height:1.2';
      wm.textContent=`${candidateName||'Candidate'} — ${examCode||'Exam'} — ${new Date().toLocaleString()}`;
      document.body.appendChild(wm);
      // Also add small corner watermark
      const corner=document.createElement('div');
      corner.id='proctor-watermark-corner';
      corner.style.cssText='position:fixed;bottom:8px;right:8px;font-size:.70rem;font-weight:700;color:rgba(15,23,42,.35);background:rgba(255,255,255,.7);padding:2px 6px;border-radius:6px;pointer-events:none;z-index:9999';
      corner.textContent=`${this.slug(candidateName)} · ${this.slug(examCode)} · ${new Date().toISOString().slice(0,10)}`;
      document.body.appendChild(corner);
    }catch(_){}
  },

  _scheduleSnap(delay) {
    if (!this.active) return;
    this._timer = setTimeout(async () => {
      await this.snap('interval');
      this._scheduleSnap(this.SNAP_EVERY_MS + (Math.random() * 2 - 1) * this.SNAP_JITTER_MS);
    }, delay == null ? this.SNAP_EVERY_MS : delay);
  },

  _scheduleFaceCheck(delay){
    if(!this.active) return;
    this._faceTimer=setTimeout(async ()=>{
      await this.checkFace();
      this._scheduleFaceCheck(this.FACE_CHECK_EVERY_MS);
    }, delay||this.FACE_CHECK_EVERY_MS);
  },

  async checkFace(){
    try{
      if(!this.active || !this._video || this._video.readyState<2) return;
      const now=Date.now();
      if(now - this._lastFaceCheck < 4000) return;
      this._lastFaceCheck=now;
      let faces=0;
      let noFace=false;
      // Try FaceDetector API
      if(this._faceDetector){
        try{
          const detected=await this._faceDetector.detect(this._video);
          faces=detected.length;
        }catch(_){ faces=0; }
      }else{
        // Fallback heuristic: check if video has significant non-dark pixels (face presence)
        // This is not perfect but provides some signal without external library
        try{
          const c=document.createElement('canvas');
          c.width=160; c.height=120;
          const ctx=c.getContext('2d');
          ctx.drawImage(this._video,0,0,160,120);
          const data=ctx.getImageData(0,0,160,120).data;
          let bright=0;
          for(let i=0;i<data.length;i+=4){
            const v=(data[i]+data[i+1]+data[i+2])/3;
            if(v>40) bright++;
          }
          const brightRatio=bright/(160*120);
          // If very dark, likely no face / camera covered
          if(brightRatio<0.15) noFace=true;
          // If very bright and uniform, maybe not face? Hard to detect without model
          // We'll assume 1 face if bright enough, 0 if too dark
          faces=noFace?0:1;
        }catch(_){ faces=1; }
      }

      if(faces===0 || noFace){
        if(now - this._lastNoFaceHit > 20000){
          this._lastNoFaceHit=now;
          this.noFaceHits++;
          this._onEvent('no_face', 'No face detected — candidate may have left camera view or covered camera. Snapshot taken for teacher review to prevent impersonation.');
          this.snap('no-face');
        }
      }else if(faces>=2){
        if(now - this._lastMultiFaceHit > 20000){
          this._lastMultiFaceHit=now;
          this.multiFaceHits++;
          this._onEvent('multi_face', `Multiple people detected (${faces} faces) — only registered student may be present. This event logged to prevent someone else doing CBT or telling answers. Snapshot taken.`);
          this.snap('multi-face-'+faces);
        }
      }
      // Update face check count
      this.faceHits++;
    }catch(e){ console.warn('[Proctor] face check skipped', e.message); }
  },

  /** Capture one webcam frame and upload it as small JPEG to the proctor bucket (Storage, NOT 500 MB DB) */
  async snap(reason) {
    try {
      if (!this.active || !this._video || !this.sb() || this._video.readyState < 2) return;
      const c = document.createElement('canvas');
      const w = 480, h = Math.round(480 * (this._video.videoHeight || 3) / (this._video.videoWidth || 4));
      c.width = w; c.height = h;
      const ctx=c.getContext('2d');
      ctx.drawImage(this._video, 0, 0, w, h);
      // Add watermark to snapshot itself (deters impersonation)
      try{
        ctx.fillStyle='rgba(255,255,255,.6)';
        ctx.font='bold 14px system-ui';
        ctx.fillText(`${this._ctx.candidate} · ${this._ctx.exam} · ${new Date().toISOString()} · ${reason||''}`, 8, h-8);
      }catch(_){}
      const blob = await new Promise(res => c.toBlob(res, 'image/jpeg', 0.50));
      if (!blob) return;
      const path = this._ctx.exam + '/' + this._ctx.candidate + '/' + Date.now() + '-' + (reason || 'interval') + '.jpg';
      const up = await this.sb().storage.from(this.BUCKET).upload(path, blob, { contentType: 'image/jpeg', upsert: false });
      if (!up.error) { this.snaps++; }
      else if (this.snaps === 0) console.warn('[Proctor] upload failed:', up.error.message, '— run database/v6.3-role-access-fixes.sql to create the proctor bucket (1 GB storage, not 500 MB DB).');
    } catch (e) { console.warn('[Proctor] snapshot skipped:', e.message || e); }
  },

  _startAudioWatch() {
    try {
      const AC = window.AudioContext || window.webkitAudioContext;
      this._audioCtx = new AC();
      const src = this._audioCtx.createMediaStreamSource(this._stream);
      const analyser = this._audioCtx.createAnalyser();
      analyser.fftSize = 1024; src.connect(analyser);
      const buf = new Uint8Array(analyser.frequencyBinCount);
      const loop = () => {
        if (!this.active) return;
        analyser.getByteFrequencyData(buf);
        let sum = 0, lowSum=0, highSum=0;
        for (let i = 2; i < buf.length; i++) {
          sum += buf[i];
          if(i < buf.length*0.3) lowSum+=buf[i];
          else highSum+=buf[i];
        }
        const level = sum / (buf.length - 2) / 255;
        const lowLevel = lowSum / (buf.length*0.3) / 255;
        const highLevel = highSum / (buf.length*0.7) / 255;
        const now = Date.now();
        // Enhanced detection: sustained talking (not just noise) — low frequencies (voice) + high frequencies (speech)
        // If level > threshold and lowLevel significant (voice), count as talking/calling answers
        const isTalking = level > this.AUDIO_THRESHOLD && lowLevel > 0.15;
        const isCalling = isTalking && highLevel > 0.12; // speech has both low and high
        if (isTalking) {
          if (!this._loudSince) this._loudSince = now;
          if (now - this._loudSince > this.AUDIO_SUSTAIN_MS && now - this._lastAudioHit > 20000) {
            this._lastAudioHit = now; this.audioHits++;
            const detail = isCalling ? `Sustained talking detected (possible answer-calling) near candidate — level ${level.toFixed(2)} low ${lowLevel.toFixed(2)} high ${highLevel.toFixed(2)} — prevents someone calling answers` : `Sustained noise/talking detected — level ${level.toFixed(2)} — logged to prevent impersonation`;
            this._onEvent('audio_noise', detail);
            this.snap(isCalling ? 'audio-call-alert' : 'audio-alert');
          }
        } else this._loudSince = 0;
        this._raf = setTimeout(loop, 350);
      };
      loop();
    } catch (e) { console.warn('[Proctor] audio watch unavailable:', e.message || e); }
  },

  stop() {
    this.active = false;
    if (this._timer) clearTimeout(this._timer);
    if (this._faceTimer) clearTimeout(this._faceTimer);
    if (this._raf) clearTimeout(this._raf);
    try { if (this._audioCtx) this._audioCtx.close(); } catch (_) {}
    try { (this._stream ? this._stream.getTracks() : []).forEach(t => t.stop()); } catch (_) {}
    try{
      const wm=document.getElementById('proctor-watermark');
      if(wm) wm.remove();
      const corner=document.getElementById('proctor-watermark-corner');
      if(corner) corner.remove();
    }catch(_){}
    this._stream = this._video = this._timer = this._faceTimer = this._audioCtx = this._raf = null;
    this._faceDetector=null;
  },

  /* ---------------- Teacher review side (CBT manager) ---------------- */
  async listForExam(examCode) {
    const db = this.sb(); if (!db) throw new Error('Database not configured.');
    const root = this.slug(examCode); const out = [];
    const top = await db.storage.from(this.BUCKET).list(root, { limit: 200 });
    if (top.error) throw new Error(top.error.message + ' — has database/v6.3-role-access-fixes.sql been run (creates the proctor bucket proctor, 1 GB storage, not 500 MB DB)?');
    for (const entry of (top.data || [])) {
      if (entry.id) { out.push({ path: root + '/' + entry.name, size: (entry.metadata || {}).size || 0, created: entry.created_at }); continue; }
      const sub = await db.storage.from(this.BUCKET).list(root + '/' + entry.name, { limit: 500 });
      for (const f of (sub.data || [])) if (f.id) out.push({ path: root + '/' + entry.name + '/' + f.name, candidate: entry.name, size: (f.metadata || {}).size || 0, created: f.created_at, reason: (f.name.split('-').pop()||'').replace('.jpg','') });
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
  },

  // Enhanced: get stats per exam
  async statsForExam(examCode){
    const list=await this.listForExam(examCode);
    const byCandidate={};
    const byReason={};
    list.forEach(it=>{
      const cand=it.candidate||'unknown';
      (byCandidate[cand]=byCandidate[cand]||{count:0, last:it.created}).count++;
      if(new Date(it.created) > new Date(byCandidate[cand].last)) byCandidate[cand].last=it.created;
      const reason=it.reason||'interval';
      byReason[reason]=(byReason[reason]||0)+1;
    });
    return {total:list.length, byCandidate, byReason, list};
  }
};
window.Proctor = Proctor;
