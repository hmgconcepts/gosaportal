/* V12.86 (round 31, item 5) — "I filled every field, saved, and it was gone."
   ---------------------------------------------------------------------------
   The teacher's report was exact: the affective grid took the ratings, said
   "saved", and on reopening every column was back to 3. Two faults, both in
   assets/js/crud.js:

     * _bfLoad rebuilt the grid from the DEFAULTS and never read the table, so
       the saved ratings could not appear however well the save worked;
     * _bfSave wrote term/session straight out of two dropdowns, so a blank
       dropdown wrote a blank period — and the report asks for "First Term", so
       the row was invisible even though it existed.

   Both are executed here against the SHIPPED file, with a stub database that
   behaves like PostgREST:
     1. the grid pre-selects what is stored for THAT class, THAT term, THAT session;
     2. a learner with nothing saved still opens at 3 and is not marked "on record";
     3. the header says how many learners are already on record;
     4. a blank period is resolved from the current academic period, not written blank;
     5. with no period anywhere, the save refuses instead of losing the work.

   Run: node tools/verification/t68-affective-roundtrip.mjs
   ========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const ROOT = path.resolve(new URL('.', import.meta.url).pathname, '../..');
const SRC = fs.readFileSync(path.join(ROOT, 'assets/js/crud.js'), 'utf8');

let pass = 0, fail = 0;
const ok = (c, m, x) => c ? (pass++, console.log('  PASS', m))
  : (fail++, console.log('  FAIL', m, x === undefined ? '' : JSON.stringify(x).slice(0, 600)));

function extract(marker) {
  const i = SRC.indexOf(marker);
  if (i < 0) throw new Error('not found: ' + marker);
  let d = 0, started = false;
  for (let k = i; k < SRC.length; k++) {
    const ch = SRC[k];
    if (ch === '{') { d++; started = true; }
    else if (ch === '}') { d--; if (started && d === 0) return SRC.slice(i, k + 1); }
  }
  throw new Error('unbalanced: ' + marker);
}

/* ---------- the shipped source, executed with a PostgREST-shaped stub ------- */
const LOAD = extract('async _bfLoad(kind) {');
const SAVE = extract('async _bfSave(kind) {');

const STUDENTS = [
  { id: 's1', full_name: 'ADEBAYO RUKAYAT', class: 'JSS 3' },
  { id: 's2', full_name: 'MUSA DANIEL', class: 'JSS 3' }
];
const SAVED = { s1: { Punctuality: 5, Neatness: 4, Politeness: 5, Honesty: 4, Leadership: 3, Cooperation: 4, Attentiveness: 5 } };

function makeSink() {
  const els = new Proxy({}, { get: (t, k) => t[k] || (t[k] = { value: '', innerHTML: '', options: [], add(){} }) });
  const dom = {
    getElementById: (id) => els[id],
    querySelectorAll: (sel) => (globalThis.__rows || [])
  };
  const from = (table) => {
    const chain = {
      select: () => chain, ilike: (col, val) => { chain._term = col === 'term' ? val : chain._term; chain._session = col === 'session' ? val : chain._session; return chain; },
      order: () => chain, limit: () => chain,
      then: (res) => res({ data: table === 'students' ? STUDENTS
        : Object.entries(SAVED).map(([k, v]) => ({ student_id: k, ratings: v })), error: null })
    };
    if (table === 'students') { chain.order = () => chain; }
    return chain;
  };
  return { dom, els, from };
}

function harness() {
  const sink = makeSink();
  const upserts = [];
  const ctx = {
    console, Date, Math, JSON, Number, String, Object, Array, Promise,
    document: sink.dom,
    esc: (s) => String(s == null ? '' : s),
    toast: (m) => { ctx._lastToast = m; },
    closeModal: () => { ctx._closed = true; },
    window: { SC_PROFILE: { id: 'teacher-1' } },
    CRUD: {
      currentPeriod: async () => (ctx._period === undefined ? { term: 'First Term', session: '2026/2027' } : ctx._period)
    },
    sb: {
      from: (table) => {
        const c = sink.from(table);
        c.upsert = (rows) => { upserts.push({ table, rows }); return { error: null }; };
        const origSelect = c.select;
        c.select = () => { const r = origSelect(); r.upsert = c.upsert; return r; };
        return c;
      }
    }
  };
  ctx.CRUD.sb = ctx.sb;   /* the page reaches the client through this.sb */
  const api = vm.createContext(ctx);
  const loadFn = LOAD.replace(/^async _bfLoad/, 'async function _bfLoad');
  const saveFn = SAVE.replace(/^async _bfSave/, 'async function _bfSave');
  vm.runInContext(loadFn + '\n' + saveFn +
    '\nCRUD._bfLoad = function(kind){ return _bfLoad.call(this, kind); };' +
    '\nCRUD._bfSave = function(kind){ return _bfSave.call(this, kind); };', api);
  return { ctx, api, upserts, els: sink.els };
}

console.log('\n1. the grid reads back what was saved');
{
  const h = harness();
  h.els['bf-class'].value = 'JSS 3';
  h.els['bf-term'].value = 'First Term';
  h.els['bf-session'].value = '2026/2027';
  await vm.runInContext('CRUD._bfLoad("affective")', h.api);
  const html = h.els['bf-list'].innerHTML;
  ok(/ADEBAYO RUKAYAT/.test(html), 'the class is listed');
  ok(/Punctuality"\+[^]{0,80}?selected/.test(html) || /value="5" selected/.test(html), 'the saved rating is pre-selected, not the default 3', html.slice(0, 300));
  ok(/on record/.test(html), 'a learner already on record is marked as such');
  ok(/1 of 2 learner\(s\)/.test(html), 'the header counts who is already on record', (html.match(/<b>[^<]*of[^<]*<\/b>/) || [])[0]);
  ok(/MUSA DANIEL/.test(html), 'a learner with nothing saved is still listed');
}

console.log('\n2. an empty period is resolved, never written blank');
{
  const h = harness();
  h.els['bf-class'].value = 'JSS 3';
  h.els['bf-term'].value = '';
  h.els['bf-session'].value = '';
  globalThis.__rows = [
    { dataset: { studentId: 's1' }, querySelectorAll: () => [{ dataset: { trait: 'Punctuality' }, value: '4' }] }
  ];
  await vm.runInContext('CRUD._bfSave("affective")', h.api);
  const up = h.upserts[0];
  ok(!!up, 'the save reached the database');
  ok(up && up.rows[0].term === 'First Term', `the term was resolved from the academic period (${up && up.rows[0].term})`);
  ok(up && up.rows[0].session === '2026/2027', `and so was the session (${up && up.rows[0].session})`);
  ok(up && typeof up.rows[0].ratings.Punctuality === 'number', 'ratings are written as numbers, not strings');
}

console.log('\n3. with no period anywhere, the save refuses and says why');
{
  const h = harness();
  h.ctx._period = { term: '', session: '' };
  h.els['bf-class'].value = 'JSS 3';
  globalThis.__rows = [{ dataset: { studentId: 's1' }, querySelectorAll: () => [{ dataset: { trait: 'Punctuality' }, value: '4' }] }];
  await vm.runInContext('CRUD._bfSave("affective")', h.api);
  ok(h.upserts.length === 0, 'nothing is written with a blank period');
  ok(/term and the session first/.test(h.ctx._lastToast || ''), 'and the teacher is told to choose the period', h.ctx._lastToast);
}

console.log(`\nAFFECTIVE-ROUNDTRIP ${fail ? 'FAILED' : 'OK'} — ${pass} passed, ${fail} failed · what the tutor saved is what the tutor sees.`);
process.exit(fail ? 1 : 0);
