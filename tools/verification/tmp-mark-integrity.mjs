/* V12.70 — ITEM 6: CAN AN IMPOSSIBLE MARK GET INTO A REPORT?
   ---------------------------------------------------------------------------
   Report cards, results and the midterm report all rank learners from
   report_scores. The find that started this harness: the database accepted
   a mark of 9999 against an assessment whose maximum is 10 and said nothing.
   Negative marks were accepted too, and an assessment could be created with
   a maximum of 0 or -10. Rank is computed from those rows, so one mistyped
   digit silently re-orders the whole class — and no screen, audit or report
   anywhere objected.

   Two guards, deliberately different in strength:
     * CHECK constraints refuse what can never be legitimate — a negative
       mark, a maximum that is not greater than zero.
     * sc_report_mark_audit() names a mark above its maximum but never
       deletes it, because importing a school's old marks is supported and
       silently destroying them would be worse than the defect.
   ========================================================================== */
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { schemaText } from './schema-loader.mjs';

const db = new PGlite();
let pass = 0, fail = 0;
const ok = (c, m, x) => { if (c) { pass++; console.log('  PASS', m); } else { fail++; console.log('  FAIL', m, x === undefined ? '' : JSON.stringify(x)); } };
const q = async (s, p) => (await db.query(s, p)).rows;
const j = v => JSON.parse(JSON.stringify(v));
const HERE = new URL('.', import.meta.url).pathname;

await db.exec(readFileSync(HERE + 'pglite-boot.sql', 'utf8'));
try { await db.exec(schemaText(HERE + '../../database/complete-schema.sql')); }
catch (e) { console.log('SCHEMA FAILED', e.message); process.exit(1); }

const COL = '11111111-aaaa-aaaa-aaaa-111111111111';
const COL2 = '33333333-cccc-cccc-cccc-333333333333';
const STU = '22222222-bbbb-bbbb-bbbb-222222222222';

console.log('\n=== A. a legitimate assessment and mark still work ===');
await db.exec(`
  insert into assessment_columns(id,class,subject,term,session,name,max_mark,position)
    values ('${COL}','JSS 1','Maths','First Term','2026/2027','CA1',10,1),
           ('${COL2}','JSS 1','Maths','First Term','2026/2027','CA2',10,2);
  insert into students(id,full_name,admission_no,class,status)
    values ('${STU}','Ada Obi','ADM001','JSS 1','active');
`);
const ins = async (col, score) => {
  try {
    await db.exec(`insert into report_scores(column_id,student_id,student_id_ref,student_name,class,subject,term,session,score)
      values ('${col}','${STU}','ADM001','Ada Obi','JSS 1','Maths','First Term','2026/2027',${score})`);
    return { accepted: true };
  } catch (e) { return { accepted: false, msg: String(e.message) }; }
};
let r = await ins(COL, 10);
ok(r.accepted, 'a mark equal to the maximum is accepted');
r = await ins(COL2, 0);
ok(r.accepted, 'a mark of zero is accepted (a learner may score nothing)');

console.log('\n=== B. a negative mark is refused ===');
r = await ins(COL2, -5);
ok(!r.accepted, 'a negative mark cannot be stored any more', r.msg && r.msg.slice(0, 90));
ok(/report_scores_score_not_negative/.test(r.msg || ''), 'and the refusal names the constraint that stopped it');

console.log('\n=== C. an impossible maximum is refused ===');
let bad = null;
try { await db.exec(`insert into assessment_columns(class,subject,term,session,name,max_mark,position)
        values ('JSS 1','Maths','First Term','2026/2027','ZeroMax',0,9)`); bad = 'zero accepted'; }
catch (e) { bad = String(e.message); }
ok(bad !== 'zero accepted', 'an assessment with a maximum of 0 is refused', String(bad).slice(0, 80));
let bad2 = null;
try { await db.exec(`insert into assessment_columns(class,subject,term,session,name,max_mark,position)
        values ('JSS 1','Maths','First Term','2026/2027','NegMax',-10,10)`); bad2 = 'negative accepted'; }
catch (e) { bad2 = String(e.message); }
ok(bad2 !== 'negative accepted', 'an assessment with a negative maximum is refused');

console.log('\n=== D. a mark ABOVE the maximum is caught by the audit, not deleted ===');
await db.exec(`alter table public.report_scores drop constraint if exists report_scores_score_not_negative`);
/* simulate the legacy offender: a row written before the guard existed */
/* the row for COL2 already exists (the zero-mark one), so overwrite it the way
   a mistyped edit would, with triggers off to bypass the new constraint */
await db.exec(`
  alter table public.report_scores disable trigger all;
  update report_scores set score = 9999 where column_id = '${COL2}';
  alter table public.report_scores enable trigger all;
`);
const a1 = j((await q(`select public.sc_report_mark_audit('JSS 1','First Term','2026/2027') a`))[0].a);
ok(a1.ok === false, 'the audit reports the report as NOT clean', a1.ok);
ok(a1.counts.above_maximum === 1, `exactly one mark is above its maximum (${a1.counts.above_maximum})`);
ok(a1.above_maximum[0].student_name === 'Ada Obi', 'the audit names the learner');
ok(Number(a1.above_maximum[0].score) === 9999, 'and the mark itself');
ok(Number(a1.above_maximum[0].max_mark) === 10, 'and the maximum it should be measured against');
ok(/above the maximum/.test(a1.verdict), 'and says in plain words what is wrong', a1.verdict.slice(0, 80));
const still = await q(`select count(*)::int c from report_scores where score = 9999`);
ok(still[0].c === 1, 'the audit did NOT delete the learner\'s mark — the school corrects it, not us');

console.log('\n=== E. the audit is scoped, not global ===');
const other = j((await q(`select public.sc_report_mark_audit('JSS 2','First Term','2026/2027') a`))[0].a);
ok(other.ok === true, 'a class with no offenders reports clean even while JSS 1 has one');

console.log('\n=== F. once the mark is corrected the audit goes clean ===');
await db.exec(`update report_scores set score = 8 where score = 9999`);
const a2 = j((await q(`select public.sc_report_mark_audit('JSS 1','First Term','2026/2027') a`))[0].a);
ok(a2.ok === true && a2.counts.defects === 0, 'clean after the correction', a2.counts);
ok(a2.counts.negative_marks === 0 && a2.counts.impossible_maxima === 0, 'no negative marks and no impossible maxima remain');

console.log('\n=== G. the guard survives a re-run of the complete schema ===');
try { await db.exec(schemaText(HERE + '../../database/complete-schema.sql')); ok(true, 'the complete schema applies a second time'); }
catch (e) { ok(false, 'the complete schema applies a second time', e.message); }
const a3 = j((await q(`select public.sc_report_mark_audit(null,null,null) a`))[0].a);
ok(a3.ok === true, 'and the audit still works afterwards', a3.ok);

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
