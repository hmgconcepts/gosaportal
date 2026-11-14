/* V12.73 item 10 — a learner/parent must be able to open their OWN prep result,
   exactly as they can open a midterm report. */
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

const STAFF = '11111111-1111-1111-1111-111111111111';
const PARENT = '22222222-2222-2222-2222-222222222222';
const OTHER = '33333333-3333-3333-3333-333333333333';
for (const [id, name, role] of [[STAFF,'Tutor','teacher'],[PARENT,'Mrs Obi','parent'],[OTHER,'Stranger','parent']])
  await db.exec(`insert into auth.users(id,email) values('${id}','${role}@x.t') on conflict do nothing;
    insert into profiles(id,full_name,role,status) values('${id}','${name}','${role}','approved')
      on conflict(id) do update set role='${role}',status='approved';`);
await db.exec(`insert into classes(name) values('JSS 1A') on conflict do nothing;
  insert into academic_periods(session,term,is_current) values('2026/2027','First Term',true) on conflict do nothing`);
const stu = (await one(`insert into students(full_name,admission_no,class) values('Ada Obi','ADM001','JSS 1A') returning id`)).id;
try { await db.exec(`insert into parent_child(parent_id,student_id) values('${PARENT}','${stu}') on conflict do nothing`); } catch(_) {}

await db.exec(`insert into prep_report_cards(student_id,student_id_ref,student_name,class,term,session,
  scores,score_details,total,max_total,average,published,has_scores,readiness_band)
  values('${stu}','ADM001','Ada Obi','JSS 1A','First Term','2026/2027',
   '{"Mathematics":16}'::jsonb,'[]'::jsonb,16,20,16,false,true,'Ready')`);

/* the teacher can read it before publishing */
await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[STAFF]);
const t1 = (await one(`select get_prep_report('ADM001','JSS 1A','First Term','2026/2027') r`)).r;
ok(t1.ok === true, 'the tutor reads the prep sheet before publishing', t1);
ok(t1.report && t1.report.student_name === 'Ada Obi', 'the returned key is report (what the page reads)', Object.keys(t1));

/* a parent cannot read it until it is published */
await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[PARENT]);
const p1 = (await one(`select get_prep_report('ADM001','JSS 1A','First Term','2026/2027') r`)).r;
ok(p1.ok === false && /published/i.test(p1.error||''), 'a parent is refused before publishing', p1);

await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[STAFF]);
await db.exec(`update prep_report_cards set published=true`);
await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[PARENT]);
const p2 = (await one(`select get_prep_report('ADM001','JSS 1A','First Term','2026/2027') r`)).r;
ok(p2.ok === true, 'the parent reads the published prep sheet', p2);
ok(/rehearsal/i.test(p2.warning||''), 'the sheet says plainly that this is a rehearsal');

/* another family must not reach it */
await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[OTHER]);
const o1 = (await one(`select get_prep_report('ADM001','JSS 1A','First Term','2026/2027') r`)).r;
ok(o1.ok === false, 'an unrelated parent is refused', o1);

/* and the page really calls the signature that now exists */
const page = fs.readFileSync(H + '../../prep-exam-reports.html', 'utf8');
ok(page.indexOf("rpc('get_prep_report'") > -1 && /p_student_id_ref/.test(page), 'the page calls the 4-argument form');
ok(/r\.data\.report/.test(page), 'the page reads data.report');

console.log(`prep family: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
