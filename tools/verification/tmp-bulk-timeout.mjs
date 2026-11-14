/* V12.73 item 2 — "canceling statement due to statement timeout" on a
   midterm-only bulk push. Prove the batch stays fast at realistic scale. */
import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import { schemaText } from './schema-loader.mjs';
const H = new URL('.', import.meta.url).pathname;
let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? pass++ : (fail++, console.log('  FAIL ' + m, x === undefined ? '' : JSON.stringify(x))); };

const db = await PGlite.create();
await db.exec(fs.readFileSync(H + 'pglite-boot.sql', 'utf8'));
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;`);
await db.exec(schemaText(H + '../../database/complete-schema.sql'));
const q = async s => (await db.query(s)).rows;
const one = async s => (await q(s))[0];
const ADM = '11111111-1111-1111-1111-111111111111';
await db.exec(`insert into auth.users(id,email) values('${ADM}','a@x.t') on conflict do nothing;
  insert into profiles(id,full_name,role,status) values('${ADM}','Bursar','admin','approved')
    on conflict(id) do update set role='admin',status='approved';`);
await db.query(`select set_config('request.jwt.claim.sub',$1,false)`, [ADM]);
await db.exec(`insert into academic_periods(session,term,is_current) values('2026/2027','First Term',true) on conflict do nothing`);

/* a real school: 8 classes x 35 learners, 6 midterm CBTs each */
const CLASSES = ['JSS 1A','JSS 1B','JSS 2A','JSS 2B','JSS 3A','JSS 3B','SS 1A','SS 1B'];
const PER = 35, EXAMS = 6;
const cvs = CLASSES.map(c => `('${c}')`).join(',');
await db.exec(`insert into classes(name) values ${cvs} on conflict do nothing`);
let sid = 0;
const stu = [];
for (const c of CLASSES) for (let i = 0; i < PER; i++) {
  sid++;
  stu.push(`('aaaaaaaa-0000-0000-0000-${String(sid).padStart(12,'0')}','Learner ${sid}','ADM${String(sid).padStart(4,'0')}','${c}')`);
}
await db.exec(`insert into students(id,full_name,admission_no,class) values ${stu.join(',')} on conflict do nothing`);

const cols = [];
// each CBT gets its OWN column, which is what the conflict guard requires
const colNames = ['CA1','Midterm Test'];
for (let e = 1; e <= EXAMS; e++) colNames.push('CBT Test ' + e);
for (const c of CLASSES) for (const n of colNames)
  cols.push(`('${c}','*','${n}','First Term','2026/2027',20,1,0,'manual','midterm')`);
await db.exec(`insert into assessment_columns(class,subject,name,term,session,max_mark,weight,"position",source,cbt_assessment_type) values ${cols.join(',')} on conflict do nothing`);

const examIds = [];
for (const c of CLASSES) for (let e = 1; e <= EXAMS; e++) {
  const id = (await one(`insert into cbt_exams(class,assessment_type,code,max_score,duration_min,report_column,subject,term,session)
    values('${c}','midterm','${c.replace(/ /g,'')}-M${e}',20,60,'CBT Test ${e}','Mathematics','First Term','2026/2027') returning id`)).id;
  examIds.push(id);
  const res = [];
  const base = sid;
  for (const s of stu.map(x => x.match(/'([^']+)','ADM/)).slice(0, 1)) {}
}
// results: every learner of that class takes every exam
const resRows = [];
let ri = 0;
for (let ci = 0; ci < CLASSES.length; ci++) {
  for (let e = 0; e < EXAMS; e++) {
    const exam = examIds[ci * EXAMS + e];
    for (let i = 0; i < PER; i++) {
      const s = stu[ci * PER + i];
      const name = s.match(/'Learner (\d+)'/)[1];
      const adm = s.match(/'ADM(\d+)'/)[1];
      ri++;
      resRows.push(`('${exam}','Learner ${name}','ADM${adm}',${10 + (ri % 10)},20,${50 + (ri % 50)},'graded','v5.1.3')`);
    }
  }
}
for (let i = 0; i < resRows.length; i += 400)
  await db.exec(`insert into cbt_results(exam_id,student_name,student_id_ref,score,total,percent,grading_status,engine_version) values ${resRows.slice(i, i + 400).join(',')}`);
console.log(`  seeded ${CLASSES.length} classes, ${stu.length} learners, ${examIds.length} CBTs, ${resRows.length} results`);

/* the reported action: bulk push, midterm purpose */
const t0 = Date.now();
const out = (await one(`select sc_cbt_bulk_push_batch_v1(array[${examIds.map(i=>`'${i}'`).join(',')}]::uuid[],null,false,20,false,'best',null,true) r`)).r;
const ms = Date.now() - t0;
console.log(`  midterm-only bulk push of ${examIds.length} CBTs took ${ms} ms ->`, JSON.stringify(out).slice(0, 160));

ok(out.ok === true, 'the midterm-only bulk push commits (no statement timeout)', out);
ok(!/statement timeout|canceling statement/i.test(JSON.stringify(out)), 'no statement-timeout error');
ok(ms < 20000, `the push finishes well inside a normal statement timeout (${ms} ms)`);
ok(Number(out.saved) > 0, 'scores were actually written', out);

const rows = await q(`select count(*) n from report_scores`);
ok(Number(rows[0].n) === CLASSES.length * PER * EXAMS, 'one row per learner per destination column', rows);

/* and it is still idempotent */
const t1 = Date.now();
const again = (await one(`select sc_cbt_bulk_push_batch_v1(array[${examIds.map(i=>`'${i}'`).join(',')}]::uuid[],null,false,20,false,'best',null,true) r`)).r;
const rows2 = await q(`select count(*) n from report_scores`);
ok(Number(rows2[0].n) === CLASSES.length * PER * EXAMS, 'a second push adds nothing', rows2);
console.log(`  second push took ${Date.now() - t1} ms`);

console.log(`bulk timeout: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
