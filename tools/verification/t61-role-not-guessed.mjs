/* V12.83 (round 28) — WHO AM I IS NOT GUESSED.
   ---------------------------------------------------------------------------
   The shell asked the database who the visitor was ONCE. One call, one profile
   select, and then — if both came back empty on a bad line — it wrote

        role = ... || 'student'

   So a TEACHER whose phone dropped one request was rendered as a learner: their
   classes, their prep diary and their staff cards simply were not there, and
   nothing on the screen said why. "It works in school but not at home" is,
   quite often, this: not a broken page, but a page told the wrong thing and
   believing it.

   Proved here, in a real browser, against the real pages:
     1. a transient failure is RETRIED, and the teacher is still a teacher;
     2. if the server truly cannot answer, the role this device already proved
        is used — never a downgrade to learner;
     3. if there is no answer and nothing remembered, the portal says so plainly
        and offers a retry, instead of impersonating a learner;
     4. an empty list is not cached as a fact: when the role lands late, the
        list that was asked for too early is fetched again.

   Run: source /home/user/work/chromium-env.sh && node tools/verification/t61-role-not-guessed.mjs
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
  '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };
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

const stub = (opts) => `
  window.__opts = ${JSON.stringify(opts)};
  window.__calls = { role: 0, profile: 0 };
  const transientError = () => ({ message: 'Failed to fetch', status: 503 });
  const SESS = { access_token: 'a', refresh_token: 'r', expires_at: Math.floor(Date.now()/1000) + 3600, user: { id: 'u1', email: 't@x', user_metadata: {} } };
  const rowsFor = (t) => (window.__opts.tables && window.__opts.tables[t]) || [];
  const chain = (rows) => {
    const api = {};
    ['select','order','limit','range','eq','in','gte','lte','ilike','not','is','neq'].forEach(k => api[k] = () => api);
    const answer = () => window.__opts.profileFails
      ? { data: null, error: transientError() }
      : { data: (rows || [])[0] || null, error: null };
    api.maybeSingle = () => Promise.resolve(answer());
    api.single = () => Promise.resolve(answer());
    api.then = (res, rej) => {
      const a = window.__opts.profileFails ? { data: [], error: transientError() } : { data: rows || [], error: null };
      return Promise.resolve(a).then(res, rej);
    };
    api.insert = () => Promise.resolve({ data: null, error: null });
    api.update = () => api; api.delete = () => api;
    return api;
  };
  window.sb = {
    from: (t) => { if (t === 'profiles') window.__calls.profile++; return chain(rowsFor(t)); },
    rpc: (n) => {
      if (n !== 'sc_current_role') return Promise.resolve({ data: null, error: null });
      window.__calls.role++;
      const o = window.__opts;
      if (o.roleMode === 'never') return Promise.resolve({ data: null, error: transientError() });
      if (o.roleMode === 'flaky' && window.__calls.role <= (o.failTimes || 2)) {
        return Promise.resolve({ data: null, error: transientError() });
      }
      return Promise.resolve({ data: o.role || { role: 'teacher', status: 'active', full_name: 'Mrs Bello' }, error: null });
    },
    auth: {
      getSession: () => Promise.resolve({ data: { session: SESS }, error: null }),
      getUser: () => Promise.resolve({ data: { user: SESS.user }, error: null }),
      refreshSession: () => Promise.resolve({ data: { session: SESS }, error: null }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signOut: () => Promise.resolve({ error: null })
    }
  };
`;

async function boot(opts) {
  const ctx = await browser.newContext({ timezoneId: 'Africa/Lagos' });
  const page = await ctx.newPage();
  const errs = [];
  page.on('pageerror', e => errs.push(e.message));
  await page.addInitScript(stub(opts));
  if (opts.storedRole) {
    await page.addInitScript((r) => { try { localStorage.setItem('sc-last-role', r); } catch (_) {} }, opts.storedRole);
  }
  await page.route('**/assets/js/config.js', r => r.fulfill({
    status: 200, contentType: 'application/javascript',
    body: 'window.SUPABASE_URL="";window.SUPABASE_ANON_KEY="";'
  }));
  await page.goto(BASE + '/' + (opts.page || 'dashboard.html'), { waitUntil: 'domcontentloaded' });
  return { ctx, page, errs };
}

console.log('\n1. A dropped request is retried — the teacher is still the teacher');
{
  const { ctx, page, errs } = await boot({ roleMode: 'flaky', failTimes: 2 });
  await page.waitForFunction(() => window.SC_PROFILE && SC_PROFILE.role && SC_PROFILE.role !== 'student', null, { timeout: 15000 })
    .catch(() => {});
  const r = await page.evaluate(() => ({
    role: (window.SC_PROFILE && SC_PROFILE.role) || null,
    calls: window.__calls.role,
    panel: !!document.getElementById('sc-reconnect'),
    body: document.body.innerText.slice(0, 80)
  }));
  ok(r.role === 'teacher', 'after two dropped answers the role is teacher, not student', r);
  ok(r.calls >= 3, 'the shell kept asking instead of accepting silence', r);
  ok(!r.panel, 'and it never had to show the waiting room', r);
  ok(!errs.length, 'no script errors', errs.slice(0, 3));
  await ctx.close();
}

console.log('\n2. The server cannot answer at all — the role this device proved is used');
{
  const { ctx, page, errs } = await boot({ roleMode: 'never', profileFails: true, storedRole: 'teacher' });
  await page.waitForFunction(() => window.SC_PROFILE && SC_PROFILE.role && SC_PROFILE.role !== 'student', null, { timeout: 30000 })
    .catch(() => {});
  const r = await page.evaluate(() => ({
    role: (window.SC_PROFILE && SC_PROFILE.role) || null,
    panel: !!document.getElementById('sc-reconnect')
  }));
  ok(r.role === 'teacher', 'a remembered teacher is NOT downgraded to learner', r);
  ok(!r.panel, 'and the portal is usable — nothing to apologise for', r);
  ok(!errs.length, 'no script errors', errs.slice(0, 3));
  await ctx.close();
}

console.log('\n3. Nothing can be known: say so, do not impersonate a learner');
{
  const { ctx, page, errs } = await boot({ roleMode: 'never', profileFails: true });
  await page.waitForFunction(() => !!document.getElementById('sc-reconnect'), null, { timeout: 30000 }).catch(() => {});
  const r = await page.evaluate(() => ({
    panel: !!document.getElementById('sc-reconnect'),
    text: (document.getElementById('sc-reconnect') || {}).innerText || '',
    role: (window.SC_PROFILE && SC_PROFILE.role) || null,
    hasRetry: !!document.getElementById('sc-reconnect-now')
  }));
  ok(r.panel, 'the portal shows an honest waiting room', r);
  ok(/Still connecting|connecting to the school/i.test(r.text), 'and it says what is happening, in words a parent understands', r.text.slice(0, 120));
  ok(r.hasRetry, 'with a way to try again immediately', r);
  ok(r.role !== 'student', 'the visitor is NOT silently rendered as a student', r);
  ok(!errs.length, 'no script errors', errs.slice(0, 3));
  await ctx.close();
}

console.log('\n4. An empty list is not a fact: a late role refetches the list');
{
  const opts = {
    roleMode: 'flaky', failTimes: 1, page: 'idcards.html',
    tables: {
      staff: [{ id: 't1', full_name: 'Mrs Bello', staff_no: 'ST1', role: 'Teacher', user_id: 'u2' }],
      students: []
    },
    role: { role: 'admin', status: 'active', full_name: 'Admin' }
  };
  const { ctx, page, errs } = await boot(opts);
  await page.waitForTimeout(4000);
  const r = await page.evaluate(async () => {
    ICUI.switchType('staff');
    await new Promise(r => setTimeout(r, 900));
    const sel = document.getElementById('ic-student');
    return {
      options: sel ? sel.options.length : 0,
      staff: (ICUI.all || []).map(x => x.full_name),
      role: (window.SC_PROFILE && SC_PROFILE.role) || null
    };
  });
  ok(r.role === 'admin', 'the role landed (late) as admin', r);
  ok(r.staff.length >= 1 && r.options >= 2,
     'and the staff list filled although the page was built before the role was known', r);
  ok(!errs.length, 'no script errors', errs.slice(0, 3));
  await ctx.close();
}

await browser.close();
srv.close();
console.log('\n' + (fail ? 'ROLE-NOT-GUESSED FAILED' : 'ROLE-NOT-GUESSED OK') +
  ' — ' + pass + ' passed, ' + fail + ' failed · nobody is rendered as somebody they are not.');
process.exit(fail ? 1 : 0);
