/* V12.70 — ITEM 12: DOES A NEW TERM CARRY THE LEARNER'S RECORDS?
   ---------------------------------------------------------------------------
   The V12.69 rollover was proved to move MONEY correctly (tmp-account.mjs,
   59 checks). The brief asks for more than money: "new term must carry forward
   all relevant student records (financials, details, scores)". The previous
   report said, honestly, that scores and details were unverified.

   Reading sc_term_rollover(): it touches sc_fee_invoice, academic_periods and
   fee snapshots. It mentions `results`, `report_scores`, `attendance` and
   `midterm_report_cards` exactly ZERO times.

   That is not necessarily wrong — history does not need to be COPIED into the
   new term; it needs to remain READABLE from the new term. Copying old scores
   forward would fabricate marks for a term the learner has not sat yet, which
   would be a far worse defect. So this harness proves the right thing:

     A. after the roll, the previous term's scores are still exactly there,
     B. reading them from the NEW current term still finds them,
     C. nothing was copied into the new term (no phantom marks),
     D. the learner's own details are unchanged,
     E. the roll is idempotent — rolling again does not duplicate history.
   ========================================================================== */
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { schemaText } from './schema-loader.mjs';

const require = createRequire(import.meta.url);
const db = new PGlite();
let pass = 0, fail = 0;
const ok = (c, m, x) => { if (c) { pass++; console.log('  PASS', m); } else { fail++; console.log('  FAIL', m, x === undefined ? '' : JSON.stringify(x)); } };
const q = async (s, p) => (await db.query(s, p)).rows;
const j = v => JSON.parse(JSON.stringify(v));
const HERE = new URL('.', import.meta.url).pathname;

const ADMIN = '11111111-1111-1111-1111-111111111111';
const STU = '22222222-2222-2222-2222-222222222222';
const COL1 = '33333333-1111-1111-1111-111111111111';
const COL2 = '33333333-2222-2222-2222-222222222222';

await db.exec(readFileSync(HERE + 'pglite-boot.sql', 'utf8'));
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;`);
try { await db.exec(schemaText(HERE + '../../database/complete-schema.sql')); }
catch (e) { console.log('SCHEMA FAILED', e.message); process.exit(1); }

const rpc = async (fn, args) => j((await q(`select public.${fn}(${args}) r`))[0].r);

/* ---------- seed a school in First Term ---------- */
await db.exec(`
  insert into auth.users(id,email) values ('${ADMIN}','boss@x.test') on conflict (id) do nothing;
  insert into public.profiles(id, full_name, role, status) values ('${ADMIN}','Boss','admin','approved')
    on conflict (id) do update set role='admin', status='approved';
  insert into public.academic_periods(session, term, is_current) values ('2026/2027','First Term', true)
    on conflict (session, term) do update set is_current = true;

  insert into public.students(id, full_name, admission_no, class, status, gender, date_of_birth, guardian_email)
    values ('${STU}','Ada Obi','ADM001','JSS 3','active','female','2013-05-14','parent@x.test')
    on conflict (id) do update set full_name='Ada Obi', class='JSS 3', status='active';

  insert into public.assessment_columns(id, class, subject, term, session, name, max_mark, position)
    values ('${COL1}','JSS 3','Maths','First Term','2026/2027','CA1',10,1),
           ('${COL2}','JSS 3','Maths','First Term','2026/2027','Exam',20,2)
    on conflict (id) do nothing;

  insert into public.report_scores(column_id, student_id, student_id_ref, student_name, class, subject, term, session, score)
    values ('${COL1}','${STU}','ADM001','Ada Obi','JSS 3','Maths','First Term','2026/2027',8),
           ('${COL2}','${STU}','ADM001','Ada Obi','JSS 3','Maths','First Term','2026/2027',17)
    on conflict do nothing;

  insert into public.class_fee_structure(class, term, session, total, active)
    values ('JSS 3','Second Term','2026/2027',26400,true) on conflict do nothing;
`);
await db.exec(`select set_config('request.jwt.claim.sub','${ADMIN}',false)`);

const before = await q(`select column_id::text, score from report_scores where student_id='${STU}' order by column_id`);
const beforeStu = (await q(`select full_name, class, admission_no, gender, date_of_birth::text, guardian_email from students where id='${STU}'`))[0];

console.log('\n=== A. the previous term really has scores before the roll ===');
ok(before.length === 2, `two score rows exist (${before.length})`);

console.log('\n=== B. roll the school into the next term ===');
const live = await rpc('sc_term_rollover', `'Second Term','2026/2027',false`);
ok(live.ok === true, 'the roll applies', live.error);
const cur = await q(`select term, session from academic_periods where is_current = true`);
ok(cur.length === 1 && cur[0].term === 'Second Term', 'the school is now in Second Term', cur);

console.log('\n=== C. the scores did not move, vanish or get rewritten ===');
const after = await q(`select column_id::text, score from report_scores where student_id='${STU}' order by column_id`);
ok(after.length === before.length, `still exactly ${before.length} score rows`, after.length);
ok(JSON.stringify(after) === JSON.stringify(before), 'and every mark is byte-identical — nothing was re-scaled or lost', { before, after });

console.log('\n=== D. history is still READABLE while the school sits in the new term ===');
const readFromNewTerm = await q(`select rs.score, ac.name
                                   from report_scores rs join assessment_columns ac on ac.id = rs.column_id
                                  where rs.student_id='${STU}' and rs.term='First Term' and rs.session='2026/2027'
                                  order by ac.position`);
ok(readFromNewTerm.length === 2, 'both First Term marks are readable from the Second Term position', readFromNewTerm.length);
ok(Number(readFromNewTerm[0].score) === 8 && Number(readFromNewTerm[1].score) === 17,
   'and they are the right marks (8 and 17)', readFromNewTerm);

console.log('\n=== E. nothing was COPIED into the new term (no phantom marks) ===');
const phantom = await q(`select count(*)::int c from report_scores where term='Second Term' and session='2026/2027'`);
ok(phantom[0].c === 0, 'the new term holds zero scores — a learner cannot be given marks they have not sat', phantom[0].c);
const phantomCols = await q(`select count(*)::int c from assessment_columns where term='Second Term' and session='2026/2027'`);
ok(phantomCols[0].c === 0, 'and no assessment columns were invented for the new term either', phantomCols[0].c);

console.log('\n=== F. the learner\'s own details are untouched ===');
const afterStu = (await q(`select full_name, class, admission_no, gender, date_of_birth::text, guardian_email from students where id='${STU}'`))[0];
ok(JSON.stringify(afterStu) === JSON.stringify(beforeStu),
   'name, class, admission number, gender, date of birth and guardian email all unchanged', { beforeStu, afterStu });

console.log('\n=== G. rolling again is idempotent ===');
const again = await rpc('sc_term_rollover', `'Second Term','2026/2027',false`);
ok(again.ok === false, 're-rolling into the term you are already in is refused, not silently repeated', again);
const stillAfter = await q(`select column_id::text, score from report_scores where student_id='${STU}' order by column_id`);
ok(JSON.stringify(stillAfter) === JSON.stringify(before), 'and the marks are still exactly as they were');

console.log('\n=== H. a THIRD term still sees the FIRST term\'s marks ===');
await db.exec(`insert into public.class_fee_structure(class, term, session, total, active)
                 values ('JSS 3','Third Term','2026/2027',26400,true) on conflict do nothing;`);
const roll3 = await rpc('sc_term_rollover', `'Third Term','2026/2027',false`);
ok(roll3.ok === true, 'the school rolls on to Third Term', roll3.error);
const fromThird = await q(`select score from report_scores where student_id='${STU}' and term='First Term' order by score`);
ok(fromThird.length === 2, 'First Term marks are STILL readable two terms later — history does not decay', fromThird.length);
ok(Number(fromThird[0].score) === 8 && Number(fromThird[1].score) === 17, 'with the same values');

console.log(`\n  ${pass} passed, ${fail} failed\n`);
await db.close();
process.exit(fail ? 1 : 0);
