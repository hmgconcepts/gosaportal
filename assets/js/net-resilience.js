/* ====================================================================
   net-resilience.js — School Connect V12.84
   ----------------------------------------------------------------------------
   WHY THIS FILE EXISTS
   A school on home data (mobile network, CGNAT, one bar of signal) reported
   three things during prep exams that never happened on the school network:

       1. "some students could not log in"
       2. "their answers would not submit"
       3. "the portal signed them out in the middle of the paper"

   None of those are a teaching problem. They are one problem: a browser that
   treats a FAILED REQUEST as a FACT.

   * A sign-in that returns 429 (the auth service rate-limits per IP address,
     and a mobile carrier puts thousands of subscribers behind one address) is
     not a wrong password. It is "try again in a moment".
   * A token refresh that times out is not a dead session. It is a slow second.
   * A submission that hits a throttled database is not a lost paper.

   So this file does four things, once, for every page:

     A. retry(fn)          — exponential backoff with jitter on transient
                             errors only (network, 429, 5xx). Never retries a
                             real refusal.
     B. session(sb)        — reads the session from local storage (no network),
                             refreshes it early, and NEVER reports "signed out"
                             because a refresh failed. A stale session beats a
                             wrong one.
     C. poll(name, fn, ms) — ONE scheduler for every badge in the app, so a
                             page makes one small request every few minutes
                             instead of three every 30 seconds. Stops when the
                             tab is hidden, when the browser is offline, and
                             (for non-critical badges) while an exam is running.
     D. queue              — a durable submit queue in localStorage, so an
                             answer that could not be sent is sent later, from
                             the same device, without the learner's help.

   V12.83 adds two more things the school cannot see but always feels:

     E. day()              — the SCHOOL'S calendar day. A date is not an
                             instant: "today" for a school in Lagos is not
                             "today" in UTC, and an attendance sheet marked at
                             00:30 must not be filed under yesterday. One
                             helper, one timezone (the school's), used
                             everywhere a page needs a YYYY-MM-DD.
     F. refresh coordination — two tabs of the same portal both refreshing an
                             expiring token is how a family gets "suddenly
                             logged out": Supabase rotates the refresh token,
                             the slower tab presents the old one and the
                             session is revoked. One tab refreshes; the others
                             adopt its token. A sign-out now reaches every tab.

   Self-contained. No dependency, no CDN, no paid service.
   ==================================================================== */
window.SCNet = (function () {
  'use strict';

  var QUEUE_KEY = 'sc-net-queue-v1';
  var DEGRADE_KEY = 'sc-net-degraded';
  var state = {
    online: (typeof navigator === 'undefined') ? true : navigator.onLine !== false,
    exam: false,
    lastFailAt: 0,
    lastOkAt: 0,
    refreshing: null,
    refreshes: 0,
    tab: null,
    polls: {},
    timer: null,
    flushing: null,
    banner: null
  };

  /* ---------------------------------------------------------------- A. transport */

  function text(e) {
    if (!e) return '';
    return String(e.message || e.error_description || e.error || e.hint || e || '');
  }

  /* A transient failure is one the SAME request could survive a second later. */
  function transient(e) {
    if (!e) return false;
    if (state.online === false) return true;
    var s = text(e).toLowerCase();
    var code = String((e && (e.status || e.code || e.statusCode)) || '');
    if (/^(429|500|502|503|504|522|524)$/.test(code)) return true;
    if (e && (e.name === 'TypeError' || e.name === 'AbortError')) return true;
    return /failed to fetch|networkerror|network error|load failed|fetch failed|timeout|timed out|too many requests|rate limit|temporarily unavailable|econnreset|etimedout|service unavailable|bad gateway|gateway timeout|jwt expired|token .*expired|42p17|57014|statement timeout|canceling statement/i
      .test(s);
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, Math.max(0, ms)); }); }

  /* Full jitter, capped. Attempt 0 fires immediately: the common case is a
     request that works, and a resilience layer that adds latency to every
     healthy request is its own outage. */
  function delayFor(attempt, base) {
    var b = base || 800;
    if (attempt <= 0) return 0;
    var ceiling = Math.min(b * Math.pow(2, attempt - 1), 15000);
    return Math.round(ceiling * (0.5 + Math.random() * 0.75));
  }

  function retry(fn, opts) {
    opts = opts || {};
    var attempts = opts.attempts || 4;
    var base = opts.base || 800;
    var label = opts.label || '';
    var i = 0;
    function attemptOnce() {
      return Promise.resolve()
        .then(fn)
        .then(function (v) {
          state.lastOkAt = Date.now();
          if (state.lastFailAt) { state.lastFailAt = 0; paint(); }
          return v;
        })
        .catch(function (e) {
          i++;
          if (!transient(e) || i >= attempts) throw e;
          state.lastFailAt = Date.now();
          note(label + ' retry ' + i);
          return sleep(delayFor(i, base)).then(attemptOnce);
        });
    }
    return attemptOnce();
  }

  /* -------------------------------------------------------------- B. the session */

  /* getSession() reads localStorage: no network, cannot fail for network
     reasons. getUser() is a real HTTP request and is what made a slow second
     look like a logout. */
  function session(sb) {
    if (!sb || !sb.auth) return Promise.resolve({ session: null, user: null, stale: false });
    if (state.refreshing) return state.refreshing;
    state.refreshing = Promise.resolve()
      .then(function () { return sb.auth.getSession(); })
      .then(function (r) {
        var s = r && r.data && r.data.session;
        if (!s) return { session: null, user: null, stale: false };
        var left = (Number(s.expires_at) || 0) * 1000 - Date.now();
        if (left > 120000) return { session: s, user: s.user || null, stale: false };
        /* refresh early, but a failure here keeps the session we have */
        return coordinatedRefresh(sb, s)
          .catch(function () {
            note('session-kept');
            return { session: s, user: s.user || null, stale: true };
          });
      })
      .catch(function () { return { session: null, user: null, stale: false }; })
      .then(function (v) { state.refreshing = null; return v; });
    return state.refreshing;
  }

  /* Ask for the current user WITHOUT a network round trip unless we must. */
  function user(sb) {
    return session(sb).then(function (r) {
      if (r.user && r.user.id) return r.user;
      if (!sb || !sb.auth || !sb.auth.getUser) return null;
      return retry(function () { return sb.auth.getUser(); }, { attempts: 2, base: 700, label: 'user' })
        .then(function (u) { return (u && u.data && u.data.user) || null; })
        .catch(function () { return null; });
    });
  }

  /* --------------------------------------------------------------- C. sign in */

  /* A 429 from the auth service is "the street is busy", not "wrong password".
     It is retried with jitter, and the caller is told which it was. */
  function signIn(sb, email, password) {
    if (!sb || !sb.auth) return Promise.resolve({ ok: false, message: 'This portal is not connected yet.' });
    var told = 0;
    return retry(function () {
      return sb.auth.signInWithPassword({ email: email, password: password }).then(function (r) {
        if (r && r.error) throw r.error;
        return r;
      });
    }, { attempts: 5, base: 1500, label: 'signin' })
      .then(function (r) {
        return { ok: true, user: (r && r.data && r.data.user) || null };
      })
      .catch(function (e) {
        var s = text(e).toLowerCase();
        var busy = /too many requests|rate limit|429/.test(s) || String(e && e.status) === '429';
        if (busy) noted('busy');
        return {
          ok: false,
          busy: busy,
          message: busy
            ? 'The network is busy right now (too many sign-ins from this connection). Wait about a minute and press Sign in again — nothing has been lost.'
            : text(e) || 'Could not sign in.'
        };
      });
  }

  /* ---------------------------------------------------------------- D. polling */

  function startClock() {
    if (state.timer) return;
    state.timer = setInterval(tick, 1000);
  }

  function visible() {
    try { return typeof document === 'undefined' || document.visibilityState !== 'hidden'; } catch (_) { return true; }
  }

  /* One scheduler for every poller in the app.
       name  — unique key ('bell', 'messages', 'license', ...)
       fn    — async function to run
       ms    — minimum gap between runs
       opts  — { critical:true } survives exam mode */
  function poll(name, fn, ms, opts) {
    opts = opts || {};
    var every = Math.max(20000, Number(ms) || 120000);
    state.polls[name] = {
      fn: fn, every: every, critical: !!opts.critical,
      due: Date.now() + Math.round(every * (0.6 + Math.random() * 0.8)),
      running: false, runs: 0
    };
    startClock();
    return state.polls[name];
  }

  function tick() {
    var now = Date.now();
    for (var k in state.polls) {
      var p = state.polls[k];
      if (!p || p.running || now < p.due) continue;
      /* hidden tab or offline browser: nothing to see, nothing to ask */
      if (!visible() || state.online === false) { p.due = now + p.every; continue; }
      /* during a sitting only the sitting's own traffic is worth the budget */
      if (state.exam && !p.critical) { p.due = now + p.every * 4; continue; }
      p.running = true;
      p.runs++;
      var gap = (state.exam && p.critical) ? p.every : p.every;
      Promise.resolve()
        .then(p.fn)
        .catch(function (e) { if (!transient(e)) note('poll:' + k); })
        .then(function () {
          p.running = false;
          p.due = Date.now() + Math.round(gap * (0.9 + Math.random() * 0.25));
        });
    }
  }

  function pollNow(name) {
    var p = state.polls[name];
    if (p) { p.due = 0; startClock(); tick(); }
  }

  function stopPoll(name) { if (state.polls[name]) delete state.polls[name]; }

  /* Exam mode: the sitting tells the shell it is running, so the shell can
     stop asking the database about bells and badges. */
  function examMode(on) {
    state.exam = !!on;
    try { localStorage.setItem('sc-exam-mode', on ? String(Date.now()) : ''); } catch (_) {}
    if (on) note('exam-mode');
    paint();
    return state.exam;
  }

  /* --------------------------------------------------------- E. durable queue */

  function readQueue() {
    try { var v = JSON.parse(localStorage.getItem(QUEUE_KEY) || '[]'); return Array.isArray(v) ? v : []; } catch (_) { return []; }
  }
  function writeQueue(list) {
    try { localStorage.setItem(QUEUE_KEY, JSON.stringify(list.slice(0, 50))); } catch (_) {}
    paint();
    return list;
  }

  /* { kind, key, payload, attempts } — `key` makes the enqueue idempotent, so
     a learner who presses Submit four times queues one paper, not four. */
  function enqueue(item) {
    var list = readQueue();
    var key = String(item.key || item.kind || 'item');
    var existing = null;
    for (var i = 0; i < list.length; i++) if (list[i].key === key) existing = list[i];
    if (existing) {
      existing.payload = item.payload;
      existing.at = new Date().toISOString();
      writeQueue(list);
      return existing;
    }
    var row = {
      kind: String(item.kind || 'submit'), key: key,
      payload: item.payload, attempts: 0,
      at: new Date().toISOString(), label: item.label || ''
    };
    list.push(row);
    writeQueue(list);
    return row;
  }

  function pending() { return readQueue(); }
  function size() { return readQueue().length; }

  /* flush() runs the queued items in order with retry; an item is removed only
     when `run` resolves. Nothing is deleted on a failure of any kind. */
  function flush(sb, run) {
    if (state.flushing) return state.flushing;
    var list = readQueue();
    if (!list.length) return Promise.resolve({ sent: 0, left: 0 });
    var sent = 0;
    state.flushing = list.reduce(function (chain, item) {
      return chain.then(function () {
        return retry(function () { return run(item, sb); }, { attempts: 3, base: 1200, label: 'flush' })
          .then(function (res) {
            var q = readQueue().filter(function (x) { return x.key !== item.key; });
            writeQueue(q);
            sent++;
            if (typeof window !== 'undefined' && window.dispatchEvent) {
              try { window.dispatchEvent(new CustomEvent('sc-net-sent', { detail: { item: item, result: res } })); } catch (_) {}
            }
          })
          .catch(function (e) {
            var q = readQueue();
            for (var i = 0; i < q.length; i++) if (q[i].key === item.key) q[i].attempts = (q[i].attempts || 0) + 1;
            writeQueue(q);
            throw e;
          });
      });
    }, Promise.resolve())
      .catch(function () { /* keep the rest for the next attempt */ })
      .then(function () { state.flushing = null; return { sent: sent, left: size() }; });
    return state.flushing;
  }

  /* ------------------------------------------------------------------ banner */

  function noted(why) { note(why); }

  function note(why) {
    state.lastFailAt = state.lastFailAt || Date.now();
    try { localStorage.setItem(DEGRADE_KEY, why + '@' + new Date().toISOString()); } catch (_) {}
    paint();
  }

  function paint() {
    if (typeof document === 'undefined' || !document.body) return;
    var q = size();
    var bad = state.online === false || state.lastFailAt;
    if (!bad && !q) {
      if (state.banner && state.banner.parentNode) state.banner.parentNode.removeChild(state.banner);
      state.banner = null;
      return;
    }
    if (!state.banner) {
      var el = document.createElement('div');
      el.id = 'sc-net-banner';
      el.setAttribute('role', 'status');
      el.style.cssText = 'position:fixed;left:50%;transform:translateX(-50%);bottom:14px;z-index:2147483000;' +
        'max-width:92vw;padding:9px 14px;border-radius:999px;font:600 13px/1.35 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;' +
        'box-shadow:0 6px 22px rgba(0,0,0,.22);display:flex;gap:8px;align-items:center;';
      document.body.appendChild(el);
      state.banner = el;
    }
    var b = state.banner;
    if (state.online === false) {
      b.style.background = '#7f1d1d'; b.style.color = '#fff';
      b.textContent = q ? '◍ Offline — ' + q + ' answer' + (q === 1 ? '' : 's') + ' saved on this device, will send when the signal returns'
                        : '◍ Offline — your work is saved on this device';
    } else if (q) {
      b.style.background = '#78350f'; b.style.color = '#fff';
      b.textContent = '⏳ ' + q + ' answer' + (q === 1 ? '' : 's') + ' waiting to send — retrying automatically';
    } else {
      b.style.background = '#0f766e'; b.style.color = '#fff';
      b.textContent = '↻ Connection restored — catching up';
      setTimeout(function () {
        state.lastFailAt = 0;
        paint();
      }, 4000);
    }
  }

  /* ------------------------------------------------- G. ONE REFRESH, NOT TWO TABS */

  /* Two tabs each saw a token with two minutes left and each called
     refreshSession(). Supabase ROTATES the refresh token, and the second call
     presented the token the first had already spent — so one tab ended up
     holding a session the server had revoked, and the next request signed the
     household out. On a shared connection the auth service also rate-limits
     refreshes per IP (150 per 5 minutes by default), which a few open tabs
     reach on their own.

     So: a tab that is about to refresh claims a short lock in localStorage.
     Another tab that finds the lock waits for the winner's token to appear in
     the (shared) storage and adopts it. Only the tab that could not see a new
     token after the wait refreshes for itself. */
  var LOCK_KEY = 'sc-refresh-lock-v1';
  var TAB = Math.random().toString(36).slice(2, 10);
  state.tab = TAB;

  var chan = null;
  try { if (typeof BroadcastChannel !== 'undefined') chan = new BroadcastChannel('sc-auth'); } catch (_) { chan = null; }

  function readLock() {
    try { return JSON.parse(localStorage.getItem(LOCK_KEY) || 'null'); } catch (_) { return null; }
  }
  function writeLock() {
    try { localStorage.setItem(LOCK_KEY, JSON.stringify({ tab: TAB, at: Date.now() })); } catch (_) {}
  }
  function dropLock() {
    try {
      var l = readLock();
      if (!l || l.tab === TAB) localStorage.removeItem(LOCK_KEY);
    } catch (_) {}
  }

  function broadcast(what, extra) {
    var msg = { what: what, tab: TAB, at: Date.now() };
    if (extra) for (var k in extra) msg[k] = extra[k];
    try { if (chan) chan.postMessage(msg); } catch (_) {}
    /* localStorage is the fallback bus: it reaches other tabs as a storage event */
    try { localStorage.setItem('sc-auth-bus', JSON.stringify(msg)); } catch (_) {}
  }

  function stillFresh(sb) {
    return Promise.resolve()
      .then(function () { return sb.auth.getSession(); })
      .then(function (r) {
        var s = r && r.data && r.data.session;
        if (!s) return null;
        var left = (Number(s.expires_at) || 0) * 1000 - Date.now();
        return left > 120000 ? { session: s, user: s.user || null, stale: false } : null;
      })
      .catch(function () { return null; });
  }

  function waitFresh(sb, tries) {
    if (!tries) return Promise.resolve(null);
    return sleep(500)
      .then(function () { return stillFresh(sb); })
      .then(function (v) { return v || waitFresh(sb, tries - 1); });
  }

  function refreshNow(sb, s) {
    return retry(function () {
      return sb.auth.refreshSession().then(function (rr) {
        if (rr && rr.error) throw rr.error;
        var ns = rr && rr.data && rr.data.session;
        if (!ns) throw new Error('no session returned');
        return ns;
      });
    }, { attempts: 3, base: 1500, label: 'session' })
      .then(function (ns) {
        state.refreshes++;
        return { session: ns, user: ns.user || (s && s.user) || null, stale: false };
      });
  }

  function coordinatedRefresh(sb, s, first) {
    var lock = readLock();
    var busy = lock && lock.tab !== TAB && (Date.now() - Number(lock.at || 0)) < 15000;
    /* Two tabs that look for the lock in the same millisecond both find it
       empty. A short, random step then a second look costs 60–190 ms once in a
       session and removes the simultaneous-start race. */
    if (!busy && first !== false) {
      return sleep(60 + Math.round(Math.random() * 130)).then(function () {
        return coordinatedRefresh(sb, s, false);
      });
    }
    if (busy) {
      /* another tab is already fetching the new token — wait for it to land */
      return waitFresh(sb, 12).then(function (v) {
        if (v) { state.refreshes++; note('token-adopted'); return v; }
        return refreshNow(sb, s);
      });
    }
    writeLock();
    return refreshNow(sb, s).then(function (v) {
      dropLock(); broadcast('refreshed');
      return v;
    }, function (e) { dropLock(); throw e; });
  }

  /* A sign-out must reach every tab on the device, not just the one that was
     clicked — otherwise the next person at a shared machine finds a live
     session in an old tab. */
  function signedOutElsewhere() {
    if (state.leftForLogin) return;
    state.leftForLogin = true;
    note('signed-out-elsewhere');
    try { localStorage.removeItem('sc-cached-profile'); localStorage.removeItem('sc-last-role'); } catch (_) {}
    try { purgeDocuments(); } catch (_) {}
    if (typeof location !== 'undefined' && !/login\.html$/.test(location.pathname)) {
      location.replace('login.html');
    }
  }

  function onBus(ev) {
    var msg = null;
    try { msg = ev && ev.data ? ev.data : JSON.parse((ev && ev.newValue) || 'null'); } catch (_) { msg = null; }
    if (!msg || !msg.what) return;
    if (msg.tab === TAB) return;
    if (msg.what === 'refreshed') { state.lastFailAt = 0; paint(); return; }
    if (msg.what === 'signedout') { signedOutElsewhere(); return; }
    if (msg.what === 'purge-docs') { purgeDocuments(); return; }
  }

  /* Ask the service worker to drop every CACHED PAGE while keeping the shell.
     A navigation response is the signed-in person's screen; on a shared phone
     the next user must not be able to read it from the offline cache. */
  function purgeDocuments() {
    try {
      if (typeof navigator === 'undefined' || !navigator.serviceWorker) return Promise.resolve(false);
      var ctl = navigator.serviceWorker.controller;
      if (!ctl) return Promise.resolve(false);
      ctl.postMessage({ type: 'PURGE_DOCS' });
      return Promise.resolve(true);
    } catch (_) { return Promise.resolve(false); }
  }

  if (chan) { try { chan.onmessage = onBus; } catch (_) {} }
  if (typeof window !== 'undefined') {
    try { window.addEventListener('storage', function (e) { if (e && e.key === 'sc-auth-bus') onBus(e); }); } catch (_) {}
  }

  /* ------------------------------------------------- F. THE SCHOOL'S DAY */

  /* A date is not an instant. "Today" for a school is the calendar day at the
     SCHOOL, not at the database (UTC) and not at the device (which a learner
     may have set to anything).

     What this replaces: `new Date().toISOString().slice(0,10)` — which, in
     Lagos (UTC+1), files anything done between 00:00 and 00:59 under
     YESTERDAY, and in any zone west of Greenwich files the whole evening
     under TOMORROW. Attendance, receipts, the diary and the "is my paper
     today" filters all read that string. */
  var DAY_TZ = 'Africa/Lagos';

  function schoolTz() {
    var t = '';
    try {
      t = (window.SCHOOL && (SCHOOL.timezone || SCHOOL.tz)) ||
          (window.SC_SETTINGS && (SC_SETTINGS.timezone || SC_SETTINGS.tz)) ||
          (window.SCHOOL_SETTINGS && (SCHOOL_SETTINGS.timezone || SCHOOL_SETTINGS.tz)) || '';
    } catch (_) { t = ''; }
    if (!t) { try { t = localStorage.getItem('sc-timezone') || ''; } catch (_) { t = ''; } }
    return String(t || DAY_TZ);
  }

  function dayOf(value) {
    var d = (value === undefined || value === null || value === '') ? new Date() : (value instanceof Date ? value : new Date(value));
    if (!d || isNaN(d.getTime())) return '';
    var tz = schoolTz();
    try {
      var f = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' });
      var p = {};
      f.formatToParts(d).forEach(function (x) { p[x.type] = x.value; });
      if (p.year && p.month && p.day) return p.year + '-' + p.month + '-' + p.day;
    } catch (_) {}
    try {
      var s = d.toLocaleDateString('en-CA', { timeZone: tz });
      if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
    } catch (_) {}
    /* last resort: the device's own calendar, which is still closer than UTC */
    var mm = ('0' + (d.getMonth() + 1)).slice(-2), dd = ('0' + d.getDate()).slice(-2);
    return d.getFullYear() + '-' + mm + '-' + dd;
  }

  function today() { return dayOf(new Date()); }
  function daysFromNow(n) { return dayOf(new Date(Date.now() + (Number(n) || 0) * 86400000)); }

  try {
    if (typeof window !== 'undefined') {
      window.scDay = dayOf;
      window.scToday = today;
      window.scDaysFromNow = daysFromNow;
    }
  } catch (_) {}

  /* ------------------------------------------------------------- boot wiring */

  function boot() {
    if (typeof window === 'undefined') return;
    try {
      window.addEventListener('online', function () {
        state.online = true;
        note('online');
        pollNow('bell'); pollNow('messages');
        try { window.dispatchEvent(new CustomEvent('sc-net-online')); } catch (_) {}
      });
      window.addEventListener('offline', function () {
        state.online = false;
        note('offline');
        try { window.dispatchEvent(new CustomEvent('sc-net-offline')); } catch (_) {}
      });
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') { pollNow('bell'); paint(); }
      });
      startClock();
    } catch (_) {}
    state.online = (typeof navigator === 'undefined') ? true : navigator.onLine !== false;
  }
  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
    else boot();
  }

  return {
    state: state,
    transient: transient,
    retry: retry,
    session: session,
    user: user,
    signIn: signIn,
    poll: poll,
    pollNow: pollNow,
    stopPoll: stopPoll,
    examMode: examMode,
    enqueue: enqueue,
    pending: pending,
    size: size,
    flush: flush,
    note: note,
    repaint: paint,
    /* V12.83 — the school's calendar day, and the tab-safe session */
    day: today,
    dayOf: dayOf,
    daysFromNow: daysFromNow,
    schoolTz: schoolTz,
    purgeDocuments: purgeDocuments,
    broadcast: broadcast,
    signedOut: function () { broadcast('signedout'); purgeDocuments(); },
    /* exposed for the health page and for the verification suite: the
       scheduler must be provable, not merely plausible */
    _tick: tick,
    _visible: visible,
    /* the app shell calls this once, after supabase is created */
    attach: function (sb) {
      if (!sb || sb.__scnet) return sb;
      try {
        sb.auth.onAuthStateChange(function (event, sess) {
          if (event === 'SIGNED_OUT' && state.online === false) note('auth-offline-signout');
          if (event === 'TOKEN_REFRESHED') { state.lastFailAt = 0; paint(); }
          if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') { if (sess) state.lastFailAt = 0; }
        });
      } catch (_) {}
      try { sb.__scnet = true; } catch (_) {}
      return sb;
    }
  };
})();
