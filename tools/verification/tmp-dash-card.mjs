/* V12.68 — the 💰 School Fees card on the dashboard, in a real browser, in the
   three states a school actually hits. The regression this guards: a failed
   call used to print "run database/v9.4-fees-and-exams.sql" — pointing at a
   file superseded four releases ago — and a card with no rows used to render
   nothing at all. */
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import { spawn } from 'child_process';
const require_ = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require_('playwright-core')); }
catch { ({ chromium } = require_(process.env.SC_WORK || '/home/user/work/node_modules/playwright-core')); }

const HERE = new URL('.', import.meta.url).pathname;
const ROOT = path.resolve(HERE, '../..');
let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? (pass++, console.log('  PASS', m)) : (fail++, console.log('  FAIL', m, x ?? '')); };

function findChrome() {
  if (process.env.SC_CHROME) return process.env.SC_CHROME;
  for (const r of [process.env.HOME + '/.cache/ms-playwright', '/root/.cache/ms-playwright']) {
    let dirs = [];
    try { dirs = fs.readdirSync(r).sort().reverse(); } catch { continue; }
    for (const d of dirs) for (const rel of ['chrome-linux/headless_shell', 'chrome-linux/chrome',
                                             'chrome-linux64/chrome',
                                             'chrome-headless-shell-linux64/chrome-headless-shell']) {
      const p = r + '/' + d + '/' + rel;
      if (fs.existsSync(p)) return p;
    }
  }
  return '';
}
const EXE = findChrome();
if (!EXE) { console.log('  SKIP  no Chromium found (set SC_CHROME)'); process.exit(0); }

/* serve the repo, because the page loads assets/js/app.js over HTTP */
const PORT = 8131;
const srv = spawn('python3', ['-m', 'http.server', String(PORT), '--bind', '127.0.0.1'], { cwd: ROOT, stdio: 'ignore' });
await new Promise(r => setTimeout(r, 1200));

const LIVE = {
  ok: true, student: 'Afolabi Lekan', class: 'SS 2', term: 'First Term', session: '2026/2027',
  currency: '₦', bill: 35100, aid: 0, paid: 10000, balance: 25100, arrears: 0, has_arrears: false,
  total_due: 25100, bill_known: true, match_status: 'structure', matched_by: 'exact_term',
  resolved_by: 'is_current', bill_breakdown: [{ item: 'Tuition', amount: 27000 }],
  arrears_rows: [], receipts: 1, paid_pct: 39.84,
};

const browser = await chromium.launch({
  executablePath: EXE, args: ['--no-sandbox'],
  env: { ...process.env, LD_LIBRARY_PATH: '/home/user/.local/lib:' + (process.env.LD_LIBRARY_PATH || '') },
});

const scenarios = [
  ['healthy — engine answers', () => ({ data: LIVE, error: null }), async (t) => {
    ok(/35,100/.test(t), 'the bill is printed: ₦35,100', t.slice(0, 80));
    ok(/25,100/.test(t), 'the outstanding balance is printed');
    ok(/exact term/i.test(t), 'and the card says where the figure came from');
    ok(!/v9\.4/.test(t), 'and never mentions the superseded v9.4 file');
  }],
  ['stale API cache — rpc 404', () => ({ data: null, error: { message: 'Could not find the function public.sc_student_fee_state(p_student) in the schema cache' } }), async (t) => {
    ok(/not visible to the API/i.test(t), 'names the real cause: a stale API cache');
    ok(/do not run any other SQL/i.test(t), 'and tells the school to change nothing');
    ok(/Retry/.test(t), 'offers a retry');
    ok(!/v9\.4/.test(t), 'does NOT send them to the superseded v9.4 file');
  }],
  ['call fails for another reason', () => ({ data: null, error: { message: 'JWT expired' } }), async (t) => {
    ok(/could not be loaded/i.test(t), 'reports a load failure without blaming the schema');
    ok(/JWT expired/.test(t), 'keeps the technical detail for support');
    ok(/Retry/.test(t), 'offers a retry');
  }],
  ['engine refuses this student', () => ({ data: { ok: false, error: 'Not authorised for this student.' }, error: null }), async (t) => {
    ok(/No fee figures were returned/i.test(t), 'renders an explanatory card instead of nothing');
    ok(/Class Fee Structure/.test(t), 'points at the page that fixes a class-name mismatch');
    ok(!/v9\.4/.test(t), 'and never mentions v9.4');
  }],
];

for (const [label, rpc, check] of scenarios) {
  const page = await (await browser.newContext({ viewport: { width: 1400, height: 1000 }, serviceWorkers: 'block' })).newPage();
  const errs = [];
  page.on('pageerror', e => errs.push(e.message));
  await page.route('**/assets/js/config.js', r => r.fulfill({ status: 200, contentType: 'application/javascript',
    body: 'window.SUPABASE_URL="";window.SUPABASE_ANON_KEY="";' }));
  await page.route('**/supabase-js@2', r => r.fulfill({ status: 200, contentType: 'application/javascript',
    body: 'window.supabase=window.supabase||{};' }));
  /* the page's own scripts call a bare global `sb`; an init script runs first */
  await page.addInitScript(({ rpcSrc, LIVE }) => {
    const stub = eval('(' + rpcSrc + ')');
    const student = { id: 'aaaaaaaa-1111-1111-1111-111111111111', full_name: 'Afolabi Lekan', class: 'SS 2' };
    const res = (d) => { const p = Promise.resolve({ data: d, error: null });
      p.eq = () => res(d); p.in = () => res(d); p.neq = () => res(d);
      p.order = () => res(d); p.limit = () => res(d); return p; };
    window.sb = { rpc: async (n, a) => stub(n, a),
      from: (t) => {
        const rows = /students|parent_child/.test(t) ? [student]
          : /fee_payments/.test(t) ? [{ amount_paid: 10000, method: 'cash', term: 'First Term',
              session: '2026/2027', payment_date: '2026-10-31', created_at: '2026-10-31T10:00:00Z' }]
          : [];
        return { select: () => res(rows), in: () => res(rows), order: () => res(rows) }; } };
    window.SC_PROFILE = { id: '33333333-3333-3333-3333-333333333333', role: 'student' };
  }, { rpcSrc: rpc.toString(), LIVE });
  page.on('console', m => { if (process.env.SC_DEBUG) console.log('   [console]', m.type(), m.text().slice(0, 300)); });
  await page.goto(`http://127.0.0.1:${PORT}/dashboard.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(700);
  const text = await page.evaluate(async () => {
    /* surface the real exception the page swallows */
    const origErr = console.error; let captured = null;
    console.error = (...a) => { captured = captured || a.map(String).join(' '); origErr(...a); };
    const origWarn = console.warn;
    console.warn = (...a) => { if (!captured) captured = a.map(String).join(' '); origWarn(...a); };
    try { await App.loadDashFees(); } catch (e) { captured = 'THREW: ' + e.message + '\n' + (e.stack||''); }
    console.error = origErr; console.warn = origWarn;
    if (captured) return 'CAPTURED: ' + captured.slice(0, 400);
    const boxes = [...document.querySelectorAll('[id="dash-fees"]')];
    return boxes.map(b => b.innerText.replace(/\s+/g, ' ').trim()).join(' | ');
  });
  if (process.env.SHOT) {
    /* Render what the card actually produced on a clean page carrying the app's
       own stylesheet. That is the card as a user sees it, with nothing of the
       dashboard shell (sidebar, overlays) in the way. */
    const cardHtml = await page.evaluate(() => {
      const el = document.querySelector('[id="dash-fees"]');
      const card = el && (el.closest('.card') || el);
      return card ? card.outerHTML : '';
    });
    const shot = await browser.newPage({ viewport: { width: 1080, height: 900 } });
    const css = fs.readFileSync(path.join(ROOT, 'assets/css/style.css'), 'utf8');
    const emoji = fs.readFileSync(HERE + 'fonts/color-emoji-subset.woff2').toString('base64');
    await shot.setContent(`<meta charset="utf-8"><style>${css}
      @font-face{font-family:"SCEmojiCap";src:url(data:font/woff2;base64,${emoji}) format("woff2");font-display:block;}
      body{background:#f8fafc;padding:18px;font-family:"SCEmojiCap",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
      .card{max-width:1040px}</style><body>${cardHtml}</body>`, { waitUntil: 'load' });
    await shot.evaluate(async () => { await document.fonts.ready; });
    await shot.waitForTimeout(300);
    await shot.locator('.card').first().screenshot({
      path: process.env.SHOT + '-' + label.split(' ')[0].replace(/[^a-z]/gi, '') + '.png' }).catch(() => {});
    await shot.close();
  }
  console.log(`\n=== ${label} ===`);
  ok(errs.length === 0, 'no JavaScript error on the page', errs.slice(0, 2));
  await check(text);
  await page.context().close();
}

await browser.close();
srv.kill();
console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
