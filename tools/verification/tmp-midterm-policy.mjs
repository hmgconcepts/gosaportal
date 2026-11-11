/* V12.70 — ITEM 11: DOES THE SCHOOL'S POSITIONS SWITCH ACTUALLY CHANGE WHAT PRINTS?
   ---------------------------------------------------------------------------
   The bug this proves dead: V12.66 shipped a complete positions policy — the
   table (sc_report_settings), the reader (sc_report_policy), the writer
   (sc_report_policy_save), and a settings card on midterm-reports.html with a
   "Show the position in class" checkbox. The school could tick it off and save,
   and the database stored it faithfully. tmp-policy.mjs proves that, and still
   passes.

   But NOTHING ON THE PAGE READ IT. grep for show_position across
   midterm-reports.html returned zero hits. So the sheet printed
     Position   3
   in the student-meta block and again in the summary, the preview table kept a
   Position column, and the CSV kept a Position column — every time, whatever
   the school had chosen. A school that had deliberately turned ranking off at
   midterm was still handing parents a rank.

   This harness opens the REAL midterm-reports.html in Chromium, points `sb` at
   a stub, renders the actual sheet / preview / CSV through the page's own
   functions, and asserts that flipping the flag changes the output — and that
   the default (no setting saved) still shows positions, because changing the
   default would silently alter reports for every school that never opened the
   card.
   ========================================================================== */
import fs from 'fs';
import { createRequire } from 'module';
const require_ = createRequire(import.meta.url);
let chromium = null, resolveErr = null;
for (const cand of [process.env.SC_WORK, 'playwright-core', 'playwright'].filter(Boolean)) {
  try { ({ chromium } = require_(cand)); break; } catch (e) { resolveErr = e; }
}
const HERE = new URL('.', import.meta.url).pathname;
const ROOT = HERE + '../../';

function findChrome() {
  if (process.env.SC_CHROME) return process.env.SC_CHROME;
  const roots = [process.env.HOME + '/.cache/ms-playwright', '/root/.cache/ms-playwright'];
  const glob = d => { try { return fs.readdirSync(d); } catch { return []; } };
  for (const r of roots) for (const d of glob(r).sort().reverse())
    for (const rel of ['chrome-linux/headless_shell', 'chrome-linux64/chrome', 'chrome-headless-shell-linux64/chrome-headless-shell']) {
      const p = `${r}/${d}/${rel}`; if (fs.existsSync(p)) return p;
    }
  return '';
}

let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? (pass++, console.log('  PASS', m)) : (fail++, console.log('  FAIL', m, x === undefined ? '' : JSON.stringify(x))); };

const EXE = findChrome();
if (!EXE || !chromium) {
  console.log('  SKIP  no Chromium/playwright available' + (resolveErr ? ' — ' + resolveErr.message : ''));
  process.exit(0);
}

const ROW = {
  student_name: 'Ada Obi', student_id_ref: 'ADM001', class: 'JSS 1',
  term: 'First Term', session: '2025/2026', total: 76, max_total: 100,
  average: 76, percentage: 76, expected_total: 100, position: 3,
  rank_cohort_size: 12, rank_basis: 'Ranked on 4 subjects sat', grade: 'A',
  subjects_sat: 4, subjects_expected: 4, has_scores: true, published: true,
  scores: { Maths: 20, English: 19 }, score_details: [
    { subject: 'Maths', assessment: 'Midterm test', score: 20, max: 25 },
    { subject: 'English', assessment: 'Midterm test', score: 19, max: 25 },
  ],
};

const browser = await chromium.launch({
  executablePath: EXE, args: ['--no-sandbox'],
  env: { ...process.env, LD_LIBRARY_PATH: '/home/user/.local/lib:' + (process.env.LD_LIBRARY_PATH || '') },
});
const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
await page.route('**/*', route => {
  const req = route.request();
  if (req.isNavigationRequest() && req.frame() === page.mainFrame()
      && page.url() && !req.url().includes('midterm-reports')) return route.abort();
  return route.continue();
});
const errors = [];
/* file:// cannot register a service worker; that is the harness's origin, not a
   defect in the page, so it is filtered out of the "clean load" assertion. */
const IGNORE = /ServiceWorkerRegistration|service worker/i;
page.on('pageerror', e => { const m = String(e && e.message || e); if (!IGNORE.test(m)) errors.push(m); });

/* ---------- stub Supabase: scenarios for the policy + one class of rows ---------- */
await page.addInitScript(({ ROW }) => {
  const S = window.__SC = {
    policy: { ok: true, show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: false },
    rpc: [],
  };
  function chain(v) {
    const api = {};
    Object.assign(api, {
      then: (res, rej) => Promise.resolve(v).then(res, rej),
      catch: rej => Promise.resolve(v).catch(rej),
      finally: fn => Promise.resolve(v).finally(fn),
      eq: () => api, neq: () => api, order: () => api, limit: () => api, range: () => api,
      in: () => api, is: () => api, not: () => api, or: () => api, filter: () => api,
      select: () => api, update: () => api, insert: () => api, upsert: () => api,
      maybeSingle: () => Promise.resolve(Array.isArray(v && v.data) ? { data: v.data[0] || null, error: null } : v),
      single: () => Promise.resolve(v),
    });
    return api;
  }
  window.sb = {
    from(t) {
      if (t === 'midterm_report_cards') return chain({ data: [ROW], error: null });
      if (t === 'lookups') return chain({ data: [], error: null });
      if (t === 'academic_periods') return chain({ data: [], error: null });
      return chain({ data: [], error: null });
    },
    rpc(name, args) {
      S.rpc.push({ name, args: JSON.parse(JSON.stringify(args || {})) });
      if (name === 'sc_report_policy') return Promise.resolve({ data: S.policy, error: null });
      if (name === 'sc_report_policy_save') {
        /* the real function writes the row and the next read reflects it; the
           stub must do the same, mapping the p_* arguments onto the read shape */
        S.policy = {
          ok: true, configured: true,
          show_position: args.p_show_position !== false,
          show_grade: args.p_show_grade !== false,
          show_subject_position: args.p_show_subject_position !== false,
          show_remarks: args.p_show_remarks !== false,
          position_label: args.p_position_label || 'Position in class',
        };
        return Promise.resolve({ data: { ok: true }, error: null });
      }
      return Promise.resolve({ data: { ok: true }, error: null });
    },
    auth: {
      getUser: () => Promise.resolve({ data: { user: { id: 'u1' } } }),
      getSession: () => Promise.resolve({ data: { session: null } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() { } } } }),
    },
    channel: () => ({ on() { return this; }, subscribe() { return this; }, unsubscribe() { } }),
    removeChannel: () => { },
  };
  window.SC_PROFILE = { id: 'u1', role: 'admin', status: 'approved', full_name: 'Admin' };
  window.toast = window.toast || function () { };
  window.SCHOOL = { name: 'Test College', shortName: 'Test', motto: 'Learn' };
}, { ROW });

const url = 'file://' + ROOT + 'midterm-reports.html';
await page.goto(url, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => window.MR && typeof window.MR.sheetBody === 'function', { timeout: 20000 }).catch(() => { });

ok(await page.evaluate(() => !!(window.MR && window.MR.sheetBody)), 'the real midterm-reports.html loaded its MR engine');
ok(errors.length === 0, 'the page threw no errors while loading', errors.slice(0, 3));

/* ---------- 1. DEFAULT: no setting saved → positions still show (old behaviour) ---------- */
await page.evaluate(() => {
  window.__SC.policy = { ok: true, show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: false };
});
const defHtml = await page.evaluate(async (ROW) => {
  await window.MR.loadPolicy('First Term', '2025/2026');
  return window.MR.sheetBody(ROW);
}, ROW);
ok(/Position/i.test(defHtml), 'DEFAULT (nothing saved): the sheet still prints a position — schools that never opened the card see no change');
ok(defHtml.includes('>3<'), 'and it prints the actual position value', defHtml.slice(0, 100));

/* ---------- 2. THE SWITCH: show_position = false ---------- */
await page.evaluate(() => {
  window.__SC.policy = { ok: true, show_position: false, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: true };
});
const offHtml = await page.evaluate(async (ROW) => {
  await window.MR.loadPolicy('First Term', '2025/2026');
  return window.MR.sheetBody(ROW);
}, ROW);
ok(!/Position/i.test(offHtml), 'SWITCH OFF: the printed sheet no longer shows the word Position anywhere', offHtml.match(/.{0,40}Position.{0,40}/i));
ok(!offHtml.includes('>3<'), 'and the learner\'s rank (3) is not printed either');
ok(/Ada Obi/.test(offHtml) && /76\.00/.test(offHtml), 'the rest of the report is untouched — name and marks still print');
ok(/MIDTERM ASSESSMENT REPORT/.test(offHtml), 'the sheet is still the midterm report, not a blank page');

/* ---------- 3. the LABEL is the school's word, not ours ---------- */
const labelled = await page.evaluate(async (ROW) => {
  window.__SC.policy = { ok: true, show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Overall rank', configured: true };
  await window.MR.loadPolicy('First Term', '2025/2026');
  return window.MR.sheetBody(ROW);
}, ROW);
ok(/Overall rank/.test(labelled), 'a school that calls it "Overall rank" gets that word on the sheet');
ok(!/Position in class/.test(labelled), 'and our default wording is gone');

/* ---------- 4. the PREVIEW TABLE obeys the same flag ---------- */
const setVals = () => page.evaluate(() => {
  const put = (id, v) => {
    const el = document.getElementById(id);
    if (!el) return false;
    if (![...el.options].some(o => o.value === v || o.textContent === v)) {
      const o = document.createElement('option'); o.value = v; o.textContent = v; el.appendChild(o);
    }
    el.value = v;
    return true;
  };
  return [put('mr-class', 'JSS 1'), put('mr-term', 'First Term'), put('mr-session', '2025/2026')];
});
ok((await setVals()).every(Boolean), 'the page exposes its class / term / session pickers');
const prevOn = await page.evaluate(async () => {
  window.__SC.policy = { ok: true, show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: true };
  await window.MR.preview();
  return document.getElementById('mr-list')?.innerHTML || '';
});
ok(/Position/.test(prevOn), 'PREVIEW (shown): the generated-reports table keeps its Position column');
const prevOff = await page.evaluate(async () => {
  window.__SC.policy = { ok: true, show_position: false, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: true };
  await window.MR.preview();
  return document.getElementById('mr-list')?.innerHTML || '';
});
ok(!/Position/.test(prevOff), 'PREVIEW (hidden): the column is gone — header and cells both', prevOff.slice(0, 200));
ok(/Ada Obi/.test(prevOff), 'and the rows are still listed');

/* ---------- 5. the CSV obeys it too, header and body in step ---------- */
const csvOut = await page.evaluate(async () => {
  const cap = { text: '' };
  const RealBlob = window.Blob;
  window.Blob = function (parts, opts) { cap.text = String((parts || []).join('')); return new RealBlob(parts, opts); };
  const realCreate = URL.createObjectURL;
  URL.createObjectURL = () => 'blob:x';
  const realClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () { };
  const out = {};
  try {
    window.__SC.policy = { ok: true, show_position: false, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: true };
    await window.MR.exportCSV();
    out.off = cap.text; cap.text = '';
    window.__SC.policy = { ok: true, show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: true };
    await window.MR.exportCSV();
    out.on = cap.text;
  } finally {
    window.Blob = RealBlob; URL.createObjectURL = realCreate; HTMLAnchorElement.prototype.click = realClick;
  }
  return out;
});
const csvHead = s => (String(s).split('\n')[0] || '');
ok(csvOut.off && csvHead(csvOut.off) && !/Position/i.test(csvHead(csvOut.off)), 'CSV (hidden): no Position column in the header', csvHead(csvOut.off));
ok(/Position/i.test(csvHead(csvOut.on)), 'CSV (shown): the Position column is back', csvHead(csvOut.on));
/* count fields with the CSV rules, not by splitting on every comma: the
   Scores_JSON cell contains commas inside its quotes (that was my harness's
   bug, not the page's) */
function fields(line){
  const out=[]; let cur='', q=false;
  for(let i=0;i<String(line).length;i++){
    const ch=String(line)[i];
    if(ch==='"'){ if(q && String(line)[i+1]==='"'){ cur+='"'; i++; } else q=!q; }
    else if(ch===',' && !q){ out.push(cur); cur=''; }
    else cur+=ch;
  }
  out.push(cur); return out;
}
const cols = s => fields(csvHead(s)).length;
const cells = s => fields(String(s).split('\n')[1] || '').length;
ok(cols(csvOut.off) === cells(csvOut.off), 'CSV (hidden): header and data row have the same number of fields — no shifted columns in Excel', { h: cols(csvOut.off), d: cells(csvOut.off) });
ok(cols(csvOut.on) === cells(csvOut.on), 'CSV (shown): header and data row still line up', { h: cols(csvOut.on), d: cells(csvOut.on) });

/* ---------- 6. saving from the card, then the sheet follows immediately ---------- */
const afterSave = await page.evaluate(async (ROW) => {
  window.__SC.policy = { ok: true, show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: false };
  await window.MR.loadPolicy('First Term', '2025/2026');
  const before = window.MR.sheetBody(ROW);
  /* the admin ticks "show position" OFF in the card and presses Save */
  if (!document.getElementById('mpol-body')) document.body.insertAdjacentHTML('beforeend', '<div id="mpol-body"></div>');
  if (!document.getElementById('mpol-term')) document.body.insertAdjacentHTML('beforeend', '<select id="mpol-term"><option>First Term</option></select><select id="mpol-session"><option>2025/2026</option></select>');
  await ReportPolicy.load('midterm');
  const cb = document.getElementById('mpol-show_position');
  if (cb) cb.checked = false;
  await ReportPolicy.save('midterm');
  await window.MR.loadPolicy('First Term', '2025/2026');
  const after = window.MR.sheetBody(ROW);
  return { before, after, rpc: window.__SC.rpc.map(x => x.name) };
}, ROW);
ok(/Position/i.test(afterSave.before), 'before the change the sheet showed a position');
ok(!/Position/i.test(afterSave.after), 'after pressing Save with the box unticked, the very next sheet drops it', afterSave.after.slice(0, 160));
ok(afterSave.rpc.includes('sc_report_policy_save'), 'the save really went to the database function, not just to the screen', afterSave.rpc);

/* ---------- 7. the default is SHOW, and a failure never breaks a report ---------- */
const fresh = await browser.newPage({ viewport: { width: 1200, height: 900 } });
await fresh.addInitScript(() => {
  function chain(v) {
    const api = {};
    Object.assign(api, {
      then: (res, rej) => Promise.resolve(v).then(res, rej),
      catch: rej => Promise.resolve(v).catch(rej), finally: fn => Promise.resolve(v).finally(fn),
      eq: () => api, neq: () => api, order: () => api, limit: () => api, range: () => api,
      in: () => api, is: () => api, not: () => api, or: () => api, filter: () => api,
      select: () => api, update: () => api, insert: () => api, upsert: () => api,
      maybeSingle: () => Promise.resolve(Array.isArray(v && v.data) ? { data: v.data[0] || null, error: null } : v),
      single: () => Promise.resolve(v),
    });
    return api;
  }
  window.sb = {
    from: () => chain({ data: [], error: null }),
    /* the policy module is unreachable — the worst case a real school can hit */
    rpc: () => Promise.reject(new Error('network down')),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'u1' } } }),
            getSession: () => Promise.resolve({ data: { session: null } }),
            onAuthStateChange: () => ({ data: { subscription: { unsubscribe() { } } } }) },
    channel: () => ({ on() { return this; }, subscribe() { return this; }, unsubscribe() { } }),
    removeChannel: () => { },
  };
  window.SC_PROFILE = { id: 'u1', role: 'admin', status: 'approved' };
  window.toast = function () { };
  window.SCHOOL = { name: 'Test College' };
});
await fresh.goto(url, { waitUntil: 'domcontentloaded' });
await fresh.waitForFunction(() => window.MR && typeof window.MR.sheetBody === 'function', { timeout: 20000 }).catch(() => { });
const fallback = await fresh.evaluate(async (ROW) => {
  const before = JSON.parse(JSON.stringify(window.MR._pol || {}));
  let threw = null, html = '';
  try { await window.MR.loadPolicy('First Term', '2025/2026'); html = window.MR.sheetBody(ROW); }
  catch (e) { threw = String(e.message || e); }
  return { before, threw, html, pol: window.MR._pol };
}, ROW);
ok(fallback.before.show_position === true, 'on a fresh page the default is SHOW — a school that never opened the card sees no change', fallback.before);
ok(fallback.threw === null, 'a policy module that is entirely unreachable does not throw at the page', fallback.threw);
ok(/MIDTERM ASSESSMENT REPORT/.test(fallback.html) && /Ada Obi/.test(fallback.html),
   'and the sheet still renders a complete report');
ok(fallback.pol.show_position === true && /Position/.test(fallback.html),
   'the learner\'s real rank is still printed rather than silently dropped', fallback.pol);
await fresh.close();

/* ==========================================================================
   PART TWO — the TERMINAL report card.
   The terminal sheet has always read the policy (ReportEngine._preparePolicy
   → loadPolicy → pol.show_grade / show_remarks / show_subject_position at the
   subject row). Nobody had ever proved it end to end in a browser, so this
   does: it drives the REAL report-cards.html, renders a real report through
   ReportEngine.renderStudent, and asserts each of the four switches in turn.
   ========================================================================== */
const term = await browser.newPage({ viewport: { width: 1300, height: 950 } });
await term.addInitScript(({ ROWS }) => {
  const S = window.__SC = {
    policy: { ok: true, show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class', configured: false },
  };
  const by = t => (ROWS[t] || []);
  function chain(v) {
    const api = {};
    Object.assign(api, {
      then: (res, rej) => Promise.resolve(v).then(res, rej),
      catch: rej => Promise.resolve(v).catch(rej), finally: fn => Promise.resolve(v).finally(fn),
      eq: (c, val) => {
        /* loadContext asks students for `user_id = <profile id>` — a column the
           roster rows do not carry. Comparing undefined to the id would empty
           the roster and silently trip the engine's live-roster gate, which is
           exactly how my earlier stub produced "No result records". Answer that
           particular question with nothing instead. */
        if (c === 'user_id' || c === 'parent_id') return chain({ data: [], error: null });
        return chain({ data: (v.data || []).filter(r => String(r[c]) === String(val)), error: null });
      },
      neq: () => api, order: () => api, limit: () => chain({ data: (v.data || []).slice(0, 5000), error: null }),
      range: () => api, in: () => api, is: () => api, not: () => api, or: () => api, filter: () => api,
      select: () => api, update: () => api, insert: () => api, upsert: () => api,
      maybeSingle: () => Promise.resolve({ data: (v.data || [])[0] || null, error: null }),
      single: () => Promise.resolve({ data: (v.data || [])[0] || null, error: null }),
    });
    return api;
  }
  window.sb = {
    from(t) { return chain({ data: by(t), error: null }); },
    rpc(name, args) {
      if (name === 'sc_report_policy') return Promise.resolve({ data: S.policy, error: null });
      if (name === 'sc_report_hold_list') return Promise.resolve({ data: [], error: null });
      return Promise.resolve({ data: { ok: true }, error: null });
    },
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'u1' } } }),
            getSession: () => Promise.resolve({ data: { session: null } }),
            onAuthStateChange: () => ({ data: { subscription: { unsubscribe() { } } } }) },
    channel: () => ({ on() { return this; }, subscribe() { return this; }, unsubscribe() { } }),
    removeChannel: () => { },
  };
  window.SC_PROFILE = { id: 'u1', role: 'admin', status: 'approved' };
  window.toast = function () { };
  window.SCHOOL = { name: 'Test College', address: 'Lagos', phone: '1', email: 'a@b.c', motto: 'Learn' };
}, { ROWS: {
  results: [
    { id: 'r1', student_id: 's1', student_name: 'Ada Obi', admission_no: 'ADM001', class: 'JSS 1', term: 'First Term', session: '2025/2026', subject: 'Maths', total: 20, max: 25, ca1: 8, ca2: 6, exam: 6 },
    { id: 'r2', student_id: 's1', student_name: 'Ada Obi', admission_no: 'ADM001', class: 'JSS 1', term: 'First Term', session: '2025/2026', subject: 'English', total: 19, max: 25, ca1: 7, ca2: 6, exam: 6 },
    { id: 'r3', student_id: 's2', student_name: 'Bola Ade', admission_no: 'ADM002', class: 'JSS 1', term: 'First Term', session: '2025/2026', subject: 'Maths', total: 15, max: 25, ca1: 5, ca2: 5, exam: 5 },
    { id: 'r4', student_id: 's2', student_name: 'Bola Ade', admission_no: 'ADM002', class: 'JSS 1', term: 'First Term', session: '2025/2026', subject: 'English', total: 17, max: 25, ca1: 6, ca2: 6, exam: 5 },
  ],
  students: [
    { id: 's1', full_name: 'Ada Obi', admission_no: 'ADM001', class: 'JSS 1' },
    { id: 's2', full_name: 'Bola Ade', admission_no: 'ADM002', class: 'JSS 1' },
  ],
  /* no assessment_columns: this context must fall back to legacy `results`,
     which is the path a school that never configured Report Cards uses */
  assessment_columns: [],
} });
await term.goto('file://' + ROOT + 'report-cards.html', { waitUntil: 'domcontentloaded' });
await term.waitForFunction(() => window.ReportEngine && typeof window.ReportEngine.renderStudent === 'function', { timeout: 20000 }).catch(() => { });
ok(await term.evaluate(() => !!window.ReportEngine), 'the real report-cards.html loaded ReportEngine');

const render = async (pol) => term.evaluate(async (pol) => {
  window.__SC.policy = Object.assign({ ok: true, configured: true }, pol);
  /* The page runs its own auth flow and had resolved this stub as a STUDENT,
     which turns on the engine's family scope filter and hides every row. That
     is correct behaviour, not a defect — an admin view is what we are testing,
     so state the role at call time. */
  window.SC_PROFILE = { id: 'u1', role: 'admin', status: 'approved' };
  if (window.App) window.App.currentRole = 'admin';
  window.ReportEngine.sb = window.sb;
  window.ReportEngine._policy = null;
  return await window.ReportEngine.renderStudent({ class: 'JSS 1', term: 'First Term', session: '2025/2026', student: 'Ada Obi', report_kind: 'terminal' });
}, pol);

const on = await render({ show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class' });
ok(/TERMINAL REPORT SHEET/.test(on), 'the terminal report renders', on.slice(0, 80));
ok(/ADA OBI|Ada Obi/i.test(on), 'and names the learner');
ok(/>GRADE</.test(on) && />POSITION</.test(on) && />REMARK</.test(on), 'DEFAULT: grade, per-subject position and remark columns are all present');
/* the sheet shortens the label ("Position in class" -> "POSITION") to fit the
   info row, so assert on the label word rather than the full phrase */
ok(/<b>Position[:<]/i.test(on) || /Position:/i.test(on), 'DEFAULT: the class position row is on the sheet', on.match(/<b>[^<]{0,24}Position[^<]{0,16}<\/b>[^<]*/i));

const posOff = await render({ show_position: false, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Position in class' });
ok(/Not published/.test(posOff), 'POSITION OFF: the sheet prints "Not published" in the position cell rather than a rank');
ok(/positions withheld for this report/.test(posOff), 'and says plainly that positions are withheld, so a parent is not left guessing', posOff.match(/.{0,60}withheld.{0,40}/));
ok(/MIDTERM|TERMINAL REPORT SHEET/.test(posOff), 'the report itself still renders in full');

const gradeOff = await render({ show_position: true, show_grade: false, show_subject_position: true, show_remarks: true, position_label: 'Position in class' });
ok(!/>GRADE</.test(gradeOff), 'GRADE OFF: the GRADE column header is gone');
ok(/>POSITION</.test(gradeOff) && />REMARK</.test(gradeOff), 'and the columns the school kept are still there');

const remOff = await render({ show_position: true, show_grade: true, show_subject_position: true, show_remarks: false, position_label: 'Position in class' });
ok(!/>REMARK</.test(remOff), 'REMARK OFF: the REMARK column header is gone');
ok(/>GRADE</.test(remOff), 'and the GRADE column survives independently');

const subOff = await render({ show_position: true, show_grade: true, show_subject_position: false, show_remarks: true, position_label: 'Position in class' });
ok(!/>POSITION</.test(subOff), 'SUBJECT POSITION OFF: the per-subject POSITION column is gone');
ok(/<b>Position[:<]/i.test(subOff) || /Position:/i.test(subOff),
   'while the learner\'s overall class position is unaffected — the two switches are separate',
   subOff.match(/<b>[^<]{0,24}Position[^<]{0,16}<\/b>[^<]*/i));

const relabel = await render({ show_position: true, show_grade: true, show_subject_position: true, show_remarks: true, position_label: 'Overall rank' });
ok(/Overall rank/i.test(relabel), 'the school\'s own label ("Overall rank") is what prints');
await term.close();

/* ==========================================================================
   PART THREE — item 9: the page must never die silently.
   Before V12.70 the seven action buttons on midterm-reports.html had no
   database guard. On a site whose config.js was never filled in, pressing
   Generate threw "sb is not defined" and left the screen frozen: no message,
   no spinner, nothing a teacher could act on.
   ========================================================================== */
const blind = await browser.newPage({ viewport: { width: 1200, height: 900 } });
await blind.addInitScript(() => {
  window.toast = function () { window.__TOASTS = (window.__TOASTS || []).concat([String(arguments[0])]); };
  window.SCHOOL = { name: 'Test College' };
  /* deliberately leave window.sb UNSET — an unconfigured deployment */
});
await blind.goto('file://' + ROOT + 'midterm-reports.html', { waitUntil: 'domcontentloaded' });
await blind.waitForFunction(() => window.MR && typeof window.MR.generate === 'function', { timeout: 20000 }).catch(() => { });

const blindOut = await blind.evaluate(async () => {
  const out = { threw: [], messages: [] };
  const put = (id, v) => {
    const el = document.getElementById(id); if (!el) return false;
    if (![...el.options].some(o => o.value === v)) { const o = document.createElement('option'); o.value = v; o.textContent = v; el.appendChild(o); }
    el.value = v; return true;
  };
  put('mr-class', 'JSS 1'); put('mr-term', 'First Term'); put('mr-session', '2025/2026');
  for (const fn of ['generate', 'preview', 'publish', 'publishAllClasses', 'exportCSV', 'repairRanking']) {
    try { await window.MR[fn](); } catch (e) { out.threw.push(fn + ': ' + String(e.message || e)); }
  }
  out.messages.push(document.getElementById('mr-status')?.innerText || '');
  out.toasts = (window.__TOASTS || []).join(' | ');
  return out;
});
ok(blindOut.threw.length === 0, 'with NO database configured, none of the six actions throws — the page stays alive', blindOut.threw);
ok(/Database not connected/i.test(blindOut.messages.join(' ') + ' ' + blindOut.toasts),
   'and the school is told plainly that the database is not connected', blindOut.messages.join(' ').slice(0, 120));
ok(/config\.js/i.test(blindOut.messages.join(' ') + ' ' + blindOut.toasts),
   'the message names the file to fix, so the fix is obvious');
await blind.close();

await browser.close();
console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
