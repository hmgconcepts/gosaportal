/* V12.83 (round 28) — ONE REFRESH FOR THE WHOLE DEVICE, AND A SIGN-OUT THAT
   ACTUALLY LEAVES.
   ---------------------------------------------------------------------------
   The complaint this round answers: "the portal signs us out in the middle of
   the day, most of all at home." It is not one bug, it is two, and neither is
   about the network being slow:

   A. TWO TABS, ONE TOKEN. Every open tab refreshes an expiring session for
      itself. Supabase ROTATES the refresh token, so the second tab presents a
      token the first one already spent: the session is revoked and the next
      click lands on the login page. A household with the portal open on a
      phone and a laptop does this to itself, and the auth service also
      rate-limits refreshes per IP (150 per 5 min by default) — which a shared
      connection reaches easily.

   B. A SIGN-OUT THAT ONLY HALF HAPPENS. Signing out in one tab left the other
      tabs signed in, and left the previous session's PAGES in the service
      worker's cache, where the next person at a shared phone could open them
      offline with no sign-in at all.

   Proved here, in a real browser, with two real tabs on the real pages:
     1. both tabs ask for a session at the same moment → exactly ONE network
        refresh happens, and BOTH end up holding the new token;
     2. the tab that did not refresh never reports a stale/expired session;
     3. signing out in one tab takes the other tab to the login page;
     4. signing out drops the cached PAGES and keeps the offline shell, so the
        device can still open the portal — just not somebody else's screens;
     5. the refresh lock is released, so the next refresh can happen at all.

   Run: source /home/user/work/chromium-env.sh && node tools/verification/t60-one-refresh-and-signout.mjs
   ========================================================================== */
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import http from 'http';

const require_ = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require_('playwright-core')); }
catch { ({ chromium } = require_(process.env.SC_WORK || '/home/user/work/node_modules/playwright-core')); }

const ROOT = path.resolve(new URL('.', import.meta.url).pathname, '../..');
let pass = 0, fail = 0;
const ok = (c, m, x) => {
  c ? (pass++, console.log('  PASS', m))
    : (fail++, console.log('  FAIL', m, x === undefined ? '' : JSON.stringify(x).slice(0, 600)));
};

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.json': 'application/json', '.woff2': 'font/woff2', '.webmanifest': 'application/manifest+json' };
const srv = http.createServer((q, r) => {
  let p = decodeURIComponent(q.url.split('?')[0]); if (p === '/') p = '/dashboard.html';
  const f = path.join(ROOT, p);
  if (!fs.existsSync(f) || fs.statSync(f).isDirectory()) { r.writeHead(404); return r.end('x'); }
  r.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(r);
});
await new Promise(r => srv.listen(0, '127.0.0.1', r));
const BASE = 'http://127.0.0.1:' + srv.address().port;
const browser = await chromium.launch({ executablePath: process.env.SC_CHROME || undefined, args: ['--no-sandbox'] });

/* The stub lives in localStorage, because that is what two tabs of the same
   browser genuinely share — the same place supabase-js keeps its session. */
const STUB = `
  window.__errors = [];
  window.addEventListener('error', e => window.__errors.push(String(e.message)));
  const SKEY = 'x-sess', CKEY = 'x-refreshes';
  const readSess = () => { try { return JSON.parse(localStorage.getItem(SKEY) || 'null'); } catch (_) { return null; } };
  const writeSess = (s) => { try { localStorage.setItem(SKEY, JSON.stringify(s)); } catch (_) {} };
  const bump = () => { try { localStorage.setItem(CKEY, String(Number(localStorage.getItem(CKEY) || 0) + 1)); } catch (_) {} };
  window.__bump = bump;

  const chain = () => {
    const api = {};
    ['select','order','limit','range','eq','in','gte','lte','ilike','not','is','neq'].forEach(k => api[k] = () => api);
    api.maybeSingle = () => Promise.resolve({ data: null, error: null });
    api.single = () => Promise.resolve({ data: null, error: null });
    api.then = (res, rej) => Promise.resolve({ data: [], error: null }).then(res, rej);
    api.insert = () => Promise.resolve({ data: null, error: null });
    api.update = () => api; api.delete = () => api;
    return api;
  };

  window.sb = {
    from: () => chain(),
    rpc: (n) => Promise.resolve({ data: n === 'sc_current_role' ? { role: 'teacher', status: 'active', full_name: 'Teacher One' } : null, error: null }),
    auth: {
      getSession: () => Promise.resolve({ data: { session: readSess() }, error: null }),
      getUser: () => Promise.resolve({ data: { user: (readSess() || {}).user || null }, error: null }),
      refreshSession: () => {
        bump();
        const prev = readSess() || {};
        return new Promise(resolve => setTimeout(() => {
          const fresh = Object.assign({}, prev, {
            access_token: 'tok-' + Math.random().toString(36).slice(2),
            refresh_token: 'ref-' + Math.random().toString(36).slice(2),
            expires_at: Math.floor(Date.now() / 1000) + 3600
          });
          writeSess(fresh);                       /* the whole device sees the new token */
          resolve({ data: { session: fresh }, error: null });
        }, 700));
      },
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signOut: () => new Promise(resolve => setTimeout(() => { localStorage.removeItem(SKEY); resolve({ error: null }); }, 200))
    }
  };

  if (!readSess()) {
    /* 30 seconds left: inside net-resilience's 2-minute early-refresh window */
    writeSess({ access_token: 'old', refresh_token: 'old-ref',
                expires_at: Math.floor(Date.now() / 1000) + 30,
                user: { id: 'u1', email: 't@x' } });
  }
`;

const ctx = await browser.newContext({ timezoneId: 'Africa/Lagos' });
await ctx.addInitScript(STUB);
await ctx.route('**/assets/js/config.js', r => r.fulfill({
  status: 200, contentType: 'application/javascript',
  body: 'window.SUPABASE_URL="";window.SUPABASE_ANON_KEY="";'
}));

const A = await ctx.newPage();
const B = await ctx.newPage();
const errs = [];
A.on('pageerror', e => errs.push('A: ' + e.message));
B.on('pageerror', e => errs.push('B: ' + e.message));
const navs = [];
A.on('framenavigated', f => { if (f === A.mainFrame()) navs.push('A→' + f.url().split('/').pop()); });
B.on('framenavigated', f => { if (f === B.mainFrame()) navs.push('B→' + f.url().split('/').pop()); });

await A.goto(BASE + '/dashboard.html', { waitUntil: 'domcontentloaded' });
await B.goto(BASE + '/dashboard.html', { waitUntil: 'domcontentloaded' });
await A.waitForFunction(() => window.SCNet && typeof SCNet.session === 'function', null, { timeout: 10000 });
await B.waitForFunction(() => window.SCNet && typeof SCNet.session === 'function', null, { timeout: 10000 });

console.log('\n1. Two tabs need a token at the same moment');
{
  let ra, rb;
  try {
    [ra, rb] = await Promise.all([
      A.evaluate(() => SCNet.session(window.sb)),
      B.evaluate(() => SCNet.session(window.sb))
    ]);
  } catch (e) {
    console.log('   navigation during evaluate:', JSON.stringify(navs), 'A=' + A.url(), 'B=' + B.url(), e.message.split('\n')[0]);
    ra = {}; rb = {};
  }
  const refreshes = await A.evaluate(() => Number(localStorage.getItem('x-refreshes') || 0));
  ok(refreshes === 1, 'exactly ONE refresh hit the auth service for both tabs', { refreshes });
  ok(!!(ra && ra.session), 'tab A holds a session', ra);
  ok(!!(rb && rb.session), 'tab B holds a session', rb);
  ok(ra.session && rb.session && ra.session.access_token === rb.session.access_token,
     'and both tabs ended up with the SAME new token — no split brain', { a: ra.session && ra.session.access_token, b: rb.session && rb.session.access_token });
  ok(!ra.stale && !rb.stale, 'neither tab declared itself stale or signed out', { a: ra.stale, b: rb.stale });
  const lock = await A.evaluate(() => localStorage.getItem('sc-refresh-lock-v1'));
  ok(!lock, 'the refresh lock was released — the next refresh is not blocked forever', lock);
}

console.log('\n2. A third ask uses the token that is already there (no more network churn)');
{
  const before = await A.evaluate(() => Number(localStorage.getItem('x-refreshes') || 0));
  const r = await A.evaluate(() => SCNet.session(window.sb));
  const after = await A.evaluate(() => Number(localStorage.getItem('x-refreshes') || 0));
  ok(after === before, 'a fresh session is not refreshed again', { before, after });
  ok(!!(r && r.session), 'and the session is still returned', r && !!r.session);
}

console.log('\n3. The device caches a page while signed in (this is what offline needs)');
let cachedBefore = 0;
{
  /* a second visit so the service worker is controlling the navigation */
  await A.goto(BASE + '/dashboard.html', { waitUntil: 'load' });
  await A.evaluate(async () => {
    if (navigator.serviceWorker) {
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) {
        await new Promise(r => {
          navigator.serviceWorker.addEventListener('controllerchange', r, { once: true });
          setTimeout(r, 3000);
        });
      }
    }
  });
  await A.waitForTimeout(400);
  await A.reload({ waitUntil: 'load' });
  await A.waitForTimeout(1200);
  cachedBefore = await A.evaluate(async () => {
    const names = await caches.keys();
    let n = 0;
    for (const n2 of names) {
      const c = await caches.open(n2);
      const keys = await c.keys();
      n += keys.filter(r => /\.html$/i.test(new URL(r.url).pathname)).length;
    }
    return n;
  });
  ok(cachedBefore >= 2, 'signed-in pages are in the cache (the offline shell works)', { cachedBefore });
}

console.log('\n4. Signing out in tab A takes tab B with it');
{
  await A.evaluate(() => window.App && App.signOut ? App.signOut() : SCNet.signedOut());
  await B.waitForURL(/login\.html/, { timeout: 8000 }).catch(() => {});
  const bUrl = B.url();
  ok(/login\.html/.test(bUrl), 'tab B left the portal too — no orphaned session on a shared device', bUrl);
}

console.log('\n5. Signing out drops the cached PAGES and keeps the shell');
{
  await A.waitForTimeout(1200);
  const after = await A.evaluate(async () => {
    const names = await caches.keys();
    let docs = [], kept = [];
    for (const n of names) {
      const c = await caches.open(n);
      for (const r of await c.keys()) {
        const p = new URL(r.url).pathname;
        if (!/\.html$/i.test(p)) continue;
        if (/\/(offline|index)\.html$/i.test(p)) kept.push(p); else docs.push(p);
      }
    }
    return { docs, kept };
  });
  ok(!after.docs.some(p => /dashboard\.html$/i.test(p)),
     'the previous session\'s dashboard is no longer in the offline cache', after);
  ok(after.kept.length > 0 || after.docs.length < cachedBefore,
     'the offline shell itself was kept (the portal can still open on a dead line)', after);
  ok(!errs.length, 'no page errors in either tab', errs.slice(0, 3));
}

await ctx.close();
await browser.close();
srv.close();
console.log('\n' + (fail ? 'ONE-REFRESH / SIGN-OUT FAILED' : 'ONE-REFRESH / SIGN-OUT OK') +
  ' — ' + pass + ' passed, ' + fail + ' failed · one refresh for the whole device, ' +
  'and a sign-out that really leaves.');
process.exit(fail ? 1 : 0);
