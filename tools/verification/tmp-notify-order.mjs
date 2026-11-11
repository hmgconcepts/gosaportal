/* V12.68 — THE API CATALOGUE MUST BE TOLD ABOUT *EVERYTHING*.
 *
 * PostgREST answers `rpc('...')` from a cached catalogue. `select pg_notify(
 * 'pgrst','reload schema')` is the instruction to re-read it, and its effect is
 * positional: it announces what exists at that moment. The packs are appended to
 * the cumulative schema in release order, so if the builder keeps an EARLY
 * notification, every object declared later stays invisible to the API.
 *
 * Measured on this repository's own history: keeping the first notification left
 * 239 functions and 34 tables — including the entire fee engine — declared after
 * the reload point. That is precisely what makes a correct database answer
 * "Could not find the function public.sc_student_fee_state(...) in the schema
 * cache", which the dashboard used to report as "run database/v9.4-...sql".
 *
 * This file proves the invariant holds for the SHIPPED build.
 */
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
const BUILT = HERE + '../../database/complete-schema.sql';
let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? (pass++, console.log('  PASS', m)) : (fail++, console.log('  FAIL', m, x ?? '')); };

const t = fs.readFileSync(BUILT, 'utf8');
const hits = [...t.matchAll(/select\s+pg_notify\s*\(\s*'pgrst'\s*,\s*'reload schema'\s*\)\s*;/gi)];

console.log('\n  School Connect — API catalogue signal\n  ' + '-'.repeat(52));
ok(hits.length >= 1, `the reload notification exists (${hits.length})`);
ok(hits.length === 1, 'exactly one — no duplicate announcements left behind', hits.length);

const at = hits[hits.length - 1].index;
const tail = t.slice(at + hits[hits.length - 1][0].length);
const fns = [...tail.matchAll(/create or replace function public\.([a-z0-9_]+)/gi)].map(m => m[1]);
const tables = [...tail.matchAll(/create table if not exists public\.([a-z0-9_]+)/gi)].map(m => m[1]);
ok(fns.length === 0, `no function is declared after it (found ${fns.length})`, [...new Set(fns)].slice(0, 6));
ok(tables.length === 0, `no table is declared after it (found ${tables.length})`, [...new Set(tables)].slice(0, 6));

/* and it is the final statement of the file, not merely the final notification */
const after = tail.split('\n').filter(l => l.trim() && !l.trim().startsWith('--'));
ok(after.length === 0, 'it is the last executable statement in the file', after.slice(0, 3));

/* the fee engine specifically */
for (const fn of ['sc_term_resolve', 'sc_fee_bill_v2', 'sc_fee_ledger_for',
                  'sc_student_fee_state', 'sc_fee_explain', 'sc_fee_bill_audit']) {
  const i = t.search(new RegExp('create or replace function public\\.' + fn + '\\b'));
  ok(i >= 0 && i < at, `${fn} is declared before the reload point`);
}

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
