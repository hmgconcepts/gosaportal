import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import { schemaText } from './schema-loader.mjs';
const HERE = new URL('.', import.meta.url).pathname;
const S = p => schemaText(HERE + '../../database/' + p);

let pass = 0, fail = 0;
const ok = (c, m) => { console.log(`  ${c ? 'PASS' : 'FAIL'}  ${m}`); c ? pass++ : fail++; };
const money = n => Number(n || 0).toFixed(2);

const db = await PGlite.create();
await db.exec(fs.readFileSync(HERE + 'pglite-boot.sql', 'utf8'));

const UID = '11111111-1111-1111-1111-111111111111';
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$ select '${UID}'::uuid $$;`);
await db.exec(S('complete-schema.sql'));
await db.exec(S('v12.66-one-truth-and-remap.sql'));

await db.exec(`
  insert into auth.users(id,email) values ('${UID}','admin@school.test') on conflict do nothing;
  insert into profiles(id, full_name, role, status) values ('${UID}','Bursar','admin','approved')
    on conflict (id) do update set role='admin', status='approved';
`);
// the RLS helpers key off profiles.role — prove the identity really is staff
const who = (await db.query(`select public.is_staff('${UID}') s, public.is_admin('${UID}') a`)).rows[0];
console.log(`  (identity: is_staff=${who.s} is_admin=${who.a})`);
const q = async (sql, p) => (await db.query(sql, p)).rows;

console.log('\n=== 0. the pack is idempotent ===');
let e2 = null;
try { await db.exec(S('v12.66-one-truth-and-remap.sql')); } catch (e) { e2 = e; }
ok(!e2, 're-applies cleanly' + (e2 ? ': ' + String(e2.message).slice(0, 200) : ''));

// ============================================================ ISSUE 1: CBT remap
console.log('\n=== 1. CBT pushed to the WRONG column, then corrected ===');

await db.exec(`
  insert into academic_periods(term, session, is_current) values ('First Term','2026/2027', true)
    on conflict do nothing;
  insert into students(id, full_name, admission_no, class, status)
    values ('22222222-2222-2222-2222-222222222222','Ada Obi','ADM001','JSS 3','active')
    on conflict (id) do nothing;
  /* two candidate midterm columns */
  insert into assessment_columns(id,class,subject,term,session,name,max_mark,position)
    values ('c1c1c1c1-1111-1111-1111-111111111111','JSS 3','English','First Term','2026/2027','Midterm Test',20,1)
    on conflict (id) do nothing;
  insert into assessment_columns(id,class,subject,term,session,name,max_mark,position)
    values ('c2c2c2c2-2222-2222-2222-222222222222','JSS 3','English','First Term','2026/2027','Midterm Exam',20,2)
    on conflict (id) do nothing;
`);

// exam + result, then a push into the WRONG column (simulating the teacher's mistake)
const ex = await q(`
  insert into cbt_exams(title, subject, class, term, session, report_column, assessment_type, code)
  values ('English Midterm CBT','English','JSS 3','First Term','2026/2027','Midterm Test','midterm','ENGMT1')
  returning id`);
const examId = ex[0].id;
const res = await q(`
  insert into cbt_results(exam_id, student_id, student_id_ref, student_name, student_class,
                          score, total, percent, grading_status, engine_version)
  values ($1,'22222222-2222-2222-2222-222222222222','ADM001','Ada Obi','JSS 3',
          16, 20, 80, 'graded','v5.1.0') returning id`, [examId]);
const resultId = res[0].id;

// wrong push: exam says "Midterm Test" but the row went to "Midterm Exam"
await db.exec(`
  insert into report_scores(column_id,student_id,student_id_ref,student_name,class,subject,term,session,score,source)
  values ('c2c2c2c2-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222',
          'ADM001','Ada Obi','JSS 3','English','First Term','2026/2027',16,'cbt:${resultId}');
`);
let rows = await q(`select ac.name, rs.score from report_scores rs join assessment_columns ac on ac.id=rs.column_id`);
ok(rows.length === 1 && rows[0].name === 'Midterm Exam', 'wrong column holds the score initially');

// the audit must SEE it without being told
const aud = (await q(`select public.sc_report_source_audit(null,null,null) a`))[0].a;
ok(aud.counts.wrong_column === 1, `audit detects the wrong column (found ${aud.counts.wrong_column})`);
ok(/Midterm Exam/.test(JSON.stringify(aud.findings)) && /Midterm Test/.test(JSON.stringify(aud.findings)),
   'audit names both the actual and the expected column');

// teacher changes the destination and re-pushes -> the old row must GO
await db.exec(`
  update cbt_exams set report_column='Midterm Exam' where id='${examId}';
`);
const clean = (await q(`select public.sc_cbt_push_clean('${examId}','Midterm Exam') n`))[0].n;
rows = await q(`select ac.name from report_scores rs join assessment_columns ac on ac.id=rs.column_id`);
ok(rows.length === 1 && rows[0].name === 'Midterm Exam', 're-push to the SAME column leaves exactly one row');
ok(Number(clean) === 0, `push-clean removed nothing because it was already correct (removed ${clean})`);

// now simulate the real complaint: destination changed back to "Midterm Test"
// V12.70: the trigger now MOVES the score the instant report_column changes,
// so by the time push-clean runs there is nothing stale left to delete. The
// old assertion (push-clean removes 1) described the pre-V12.70 world, where
// the row sat in the wrong column until someone pushed again — the very hole
// that let a re-push create a SECOND row. Assert the stronger guarantee.
await db.exec(`update cbt_exams set report_column='Midterm Test' where id='${examId}';`);
rows = await q(`select ac.name, rs.score from report_scores rs join assessment_columns ac on ac.id=rs.column_id`);
ok(rows.length === 1 && rows[0].name === 'Midterm Test' && Number(rows[0].score) === 16,
   `changing the destination moves the score itself — one row, new column, score intact (${rows.length} row(s) in ${rows[0] && rows[0].name})`);
const clean2 = (await q(`select public.sc_cbt_push_clean('${examId}','Midterm Test') n`))[0].n;
rows = await q(`select count(*)::int c from report_scores`);
ok(Number(clean2) === 0 && rows[0].c === 1,
   `push-clean now finds nothing stale to remove (removed ${clean2}, rows left ${rows[0].c}) — the trigger got there first`);

// the remap function moves it back and reports the move.
// V12.70: the trigger keeps scores in the exam's own column from now on, so to
// exercise the remap at all we must recreate the LEGACY state it exists to
// repair — a score sitting in a column the exam no longer points at. Clearing
// first also avoids report_scores_uq, which is the constraint doing its job.
await db.exec(`delete from report_scores;
  insert into report_scores(column_id,student_id,student_id_ref,student_name,class,subject,term,session,score,source)
  values ('c1c1c1c1-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
          'ADM001','Ada Obi','JSS 3','English','First Term','2026/2027',16,'cbt:${resultId}');
  update cbt_exams set report_column='Midterm Exam' where id='${examId}';
`);
await db.exec(`update report_scores set column_id='c1c1c1c1-1111-1111-1111-111111111111'`);
const remapDry = (await q(`select public.sc_report_remap_cbt('${examId}','Midterm Exam',null,true) r`))[0].r;
ok(remapDry.moved === 1 && remapDry.dry_run === true, 'remap dry-run reports 1 score to move, changes nothing');
rows = await q(`select ac.name from report_scores rs join assessment_columns ac on ac.id=rs.column_id`);
ok(rows[0].name === 'Midterm Test', 'dry run really did not move it');

const remap = (await q(`select public.sc_report_remap_cbt('${examId}','Midterm Exam',null,false) r`))[0].r;
ok(remap.ok && remap.moved === 1, `remap moves it (moved ${remap.moved})`);
rows = await q(`select ac.name, rs.score from report_scores rs join assessment_columns ac on ac.id=rs.column_id`);
ok(rows.length === 1 && rows[0].name === 'Midterm Exam' && Number(rows[0].score) === 16,
   'exactly one row, in the RIGHT column, with the score intact');

const remap2 = (await q(`select public.sc_report_remap_cbt('${examId}','Midterm Exam',null,false) r`))[0].r;
ok(remap2.moved === 0 && remap2.already_correct === 1, 'remap is idempotent — second run moves nothing');

// the one-button repair sees a clean board
const rep = (await q(`select public.sc_report_repair_all(null,null,null,false) r`))[0].r;
ok(rep.ok === true && rep.counts.defects_remaining === 0,
   `one-click report repair leaves zero defects (${rep.counts.defects_remaining})`);

// double-counting: same result in two columns
await db.exec(`
  insert into report_scores(column_id,student_id,student_id_ref,student_name,class,subject,term,session,score,source)
  values ('c1c1c1c1-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
          'ADM001','Ada Obi','JSS 3','English','First Term','2026/2027',16,'cbt:${resultId}');
`);
const aud2 = (await q(`select public.sc_report_source_audit(null,null,null) a`))[0].a;
ok(aud2.counts.double_counted === 1, `audit detects the same result in two columns (${aud2.counts.double_counted})`);
const rep2 = (await q(`select public.sc_report_repair_all(null,null,null,false) r`))[0].r;
rows = await q(`select ac.name from report_scores rs join assessment_columns ac on ac.id=rs.column_id`);
ok(rows.length === 1, `repair collapses the double count to one row (${rows.length} left)`);
ok(rows[0].name === 'Midterm Exam', 'and keeps the row in the exam\'s declared column');

// orphan: score whose result is gone
await db.exec(`
  insert into report_scores(column_id,student_id,student_id_ref,student_name,class,subject,term,session,score,source)
  values ('c1c1c1c1-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
          'ADM001','Ada Obi','JSS 3','English','First Term','2026/2027',5,'cbt:99999999-9999-9999-9999-999999999999');
`);
const rep3 = (await q(`select public.sc_report_repair_all(null,null,null,false) r`))[0].r;
ok(rep3.counts.orphans_found === 1 && rep3.counts.orphans_removed === 1,
   `orphaned CBT score found and removed (${rep3.counts.orphans_found}/${rep3.counts.orphans_removed})`);

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail === 0 ? 0 : 1);
