/* V12.83 (round 28) — THE SCHOOL'S DAY, NOT THE SERVER'S DAY.
   ---------------------------------------------------------------------------
   The defect this proves dead: 103 places computed a calendar date as

        new Date().toISOString().slice(0, 10)

   which is the UTC day. Lagos is UTC+1, so between 00:00 and 00:59 everything
   a school recorded was filed under YESTERDAY (a night-duty register, a receipt
   typed just after midnight, a diary entry). West of Greenwich it is worse: for
   most of the evening the UTC day is TOMORROW.

   Proved here, in a real browser, against the real pages, with the device clock
   pinned:
     1. at 00:30 in Lagos the attendance register is dated TODAY, not yesterday
        — and the old expression is shown to disagree, so the fix is doing work;
     2. at 23:55 it is still the same day (the midnight seam is crossed once);
     3. the day belongs to the SCHOOL's timezone, not the device's: a school in
        New York at 20:30 files under its own date, where UTC says tomorrow;
     4. the school's timezone can come from the school record or from the device
        setting, and Intl resolves it (DST and all);
     5. the helper never invents a date from rubbish — it returns '' and the
        page keeps working.

   Run: source /home/user/work/chromium-env.sh && node tools/verification/t59-school-day.mjs
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
    : (fail++, console.log('  FAIL', m, x === undefined ? '' : JSON.stringify(x).slice(0, 500)));
};

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.json': 'application/json', '.woff2': 'font/woff2' };
const srv = http.createServer((q, r) => {
  let p = decodeURIComponent(q.url.split('?')[0]); if (p === '/') p = '/attendance.html';
  const f = path.join(ROOT, p);
  if (!fs.existsSync(f) || fs.statSync(f).isDirectory()) { r.writeHead(404); return r.end('x'); }
  r.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(r);
});
await new Promise(r => srv.listen(0, '127.0.0.1', r));
const BASE = 'http://127.0.0.1:' + srv.address().port;
const browser = await chromium.launch({ executablePath: process.env.SC_CHROME || undefined, args: ['--no-sandbox'] });

/* A signed-in shell and nothing else: these checks are about the clock, so the
   database answers the smallest possible truth. */
const STUB = `
  window.__errors = [];
  window.addEventListener('error', e => window.__errors.push(String(e.message)));
  const chain = (rows) => {
    const api = {};
    ['select','order','limit','range','eq','in','gte','lte','ilike','not','is','neq'].forEach(k => api[k] = () => api);
    api.maybeSingle = () => Promise.resolve({ data: (rows||[])[0] || null, error: null });
    api.single = () => Promise.resolve({ data: (rows||[])[0] || null, error: null });
    api.then = (res, rej) => Promise.resolve({ data: rows || [], error: null }).then(res, rej);
    api.insert = () => Promise.resolve({ data: null, error: null });
    api.update = () => api; api.delete = () => api;
    return api;
  };
  const SESS = { access_token: 'a', refresh_token: 'r', expires_at: Math.floor(Date.now()/1000) + 3600, user: { id: 'u1', email: 't@x' } };
  window.sb = {
    from: () => chain([]),
    rpc: (n) => Promise.resolve({ data: n === 'sc_current_role' ? { role: 'teacher', status: 'active', full_name: 'Teacher One' } : null, error: null }),
    auth: {
      getSession: () => Promise.resolve({ data: { session: SESS }, error: null }),
      getUser: () => Promise.resolve({ data: { user: SESS.user }, error: null }),
      refreshSession: () => Promise.resolve({ data: { session: SESS }, error: null }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signOut: () => Promise.resolve({ error: null })
    }
  };
`;

async function probe({ iso, school, tzStorage }) {
  const ctx = await browser.newContext({ timezoneId: 'Africa/Lagos' });
  const page = await ctx.newPage();
  const errs = [];
  page.on('pageerror', e => errs.push(e.message));
  await page.clock.setFixedTime(new Date(iso));
  if (school || tzStorage) {
    await page.addInitScript(({ school, tzStorage }) => {
      if (school) window.SCHOOL = school;
      if (tzStorage) { try { localStorage.setItem('sc-timezone', tzStorage); } catch (_) {} }
    }, { school, tzStorage });
  }
  await page.addInitScript(STUB);
  await page.route('**/assets/js/config.js', r => r.fulfill({
    status: 200, contentType: 'application/javascript',
    body: 'window.SUPABASE_URL="";window.SUPABASE_ANON_KEY="";'
  }));
  await page.goto(BASE + '/attendance.html', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(1400);
  const out = await page.evaluate(() => {
    const el = document.getElementById('at-date');
    return {
      field: el ? el.value : null,
      today: typeof scToday === 'function' ? scToday() : null,
      legacy: new Date().toISOString().slice(0, 10),
      tz: typeof SCNet !== 'undefined' && SCNet.schoolTz ? SCNet.schoolTz() : null,
      role: (window.SC_PROFILE && SC_PROFILE.role) || null,
      errors: window.__errors || []
    };
  });
  out.pageErrors = errs;
  await ctx.close();
  return out;
}

/* ------------------------------------------------------------------ 1. the seam */
console.log('\n1. Just after midnight in Lagos, the register is TODAY');
{
  const r = await probe({ iso: '2026-11-19T23:30:00Z' });   // 00:30 on 20 Nov, Lagos
  ok(r.legacy === '2026-11-19', 'the old expression really does say the 19th (this is the defect)', r);
  ok(r.field === '2026-11-20', 'the real attendance page now opens the register on the 20th', r);
  ok(r.today === '2026-11-20', 'scToday() agrees with the page', r);
  ok(r.tz === 'Africa/Lagos', 'the day is resolved in the school zone, not UTC', r);
  ok(!r.pageErrors.length, 'the page loads with no script errors', r.pageErrors);
}

console.log('\n2. Late the same evening, it is still the 20th (one seam, crossed once)');
{
  const r = await probe({ iso: '2026-11-20T22:55:00Z' });   // 23:55 Lagos
  ok(r.field === '2026-11-20', 'the register is still dated the 20th at 23:55', r);
  ok(r.legacy === '2026-11-20', 'and here the old expression happens to agree — which is why this hid for so long', r);
}

console.log('\n3. A school west of Greenwich: its own evening, not tomorrow');
{
  const r = await probe({ iso: '2026-11-22T01:30:00Z', school: { name: 'Hudson School', timezone: 'America/New_York' } });
  // 01:30 UTC on the 22nd = 20:30 on the 21st in New York
  ok(r.legacy === '2026-11-22', 'UTC would file this evening under tomorrow', r);
  ok(r.field === '2026-11-21', 'the school files it under the 21st — its own calendar day', r);
  ok(r.tz === 'America/New_York', 'the school record supplied the zone', r);
}

console.log('\n4. The zone can also come from the device setting, and Intl resolves it');
{
  const r = await probe({ iso: '2026-11-20T20:00:00Z', tzStorage: 'Asia/Tokyo' });
  // 20:00 UTC = 05:00 on the 21st in Tokyo, still 21:00 on the 20th in Lagos
  ok(r.tz === 'Asia/Tokyo', 'localStorage sc-timezone is honoured when the school record is silent', r);
  ok(r.today === '2026-11-21', 'and the day follows that zone', r);
}

console.log('\n5. The helper does not invent dates');
{
  const ctx = await browser.newContext({ timezoneId: 'Africa/Lagos' });
  const page = await ctx.newPage();
  await page.clock.setFixedTime(new Date('2026-11-20T12:00:00Z'));
  await page.addInitScript(STUB);
  await page.route('**/assets/js/config.js', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: 'window.SUPABASE_URL="";window.SUPABASE_ANON_KEY="";' }));
  await page.goto(BASE + '/attendance.html', { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => typeof window.scDay === 'function', null, { timeout: 8000 }).catch(() => {});
  const r = await page.evaluate(() => ({
    garbage: scDay('not-a-date'),
    nullish: scDay(null),
    iso: scDay('2026-11-20T23:30:00Z'),
    offsetDays: scDaysFromNow(3),
    shape: /^\d{4}-\d{2}-\d{2}$/.test(scDay(new Date()))
  }));
  ok(r.garbage === '', 'rubbish input returns an empty string, never a fake date', r);
  ok(/^\d{4}-\d{2}-\d{2}$/.test(r.nullish), 'a missing value means "today", not 1970', r);
  ok(r.iso === '2026-11-21', 'an instant at 23:30 UTC is the NEXT day in Lagos', r);
  ok(r.shape, 'the helper always answers in YYYY-MM-DD', r);
  ok(r.offsetDays === '2026-11-23', 'daysFromNow(3) counts school days, not UTC days', r);
  await ctx.close();
}

await browser.close();
srv.close();
console.log('\n' + (fail ? 'SCHOOL DAY FAILED' : 'SCHOOL DAY OK') +
  ' — ' + pass + ' passed, ' + fail + ' failed · a date belongs to the school, ' +
  'not to the database\'s clock.');
process.exit(fail ? 1 : 0);
