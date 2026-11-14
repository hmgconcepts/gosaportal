/* V12.73 item 3 — changing a CBT's Report column after results were pushed must
   MOVE the existing marks, not leave them behind and duplicate them.
   Reported: "for one CBT it generates two results — one with the wrong column
   and the second with the right column." */
import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import { schemaText } from './schema-loader.mjs';
const H = new URL('.', import.meta.url).pathname;
let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? pass++ : (fail++, console.log('  FAIL ' + m, x === undefined ? '' : JSON.stringify(x))); };

async function school() {
  const db = await PGlite.create();
  await db.exec(fs.readFileSync(H + 'pglite-boot.sql', 'utf8'));
  await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;`);
  await db.exec(schemaText(H + '../../database/complete-schema.sql'));
  const q = async (s) => (await db.query(s)).rows;
  const one = async (s) => (await q(s))[0];
  const ADM = '11111111-1111-1111-1111-111111111111';
  await db.exec(`insert into auth.users(id,email) values('${ADM}','a@x.t') on conflict do nothing;
    insert into profiles(id,full_name,role,status) values('${ADM}','Bursar','admin','approved')
      on conflict(id) do update set role='admin',status='approved';`);
  await db.exec(`insert into classes(name) values('JSS 1A') on conflict do nothing`);
  await db.exec(`insert into academic_periods(session,term,is_current) values('2026/2027','First Term',true) on conflict do nothing`);
  const col = async n => (await one(`insert into assessment_columns(class,subject,name,term,session,max_mark,weight,"position",source,cbt_assessment_type)
    values('JSS 1A','*','${n}','First Term','2026/2027',20,1,0,'manual','midterm') returning id`)).id;
  await col('CA1'); await col('Midterm Test');
  const ex = (await one(`insert into cbt_exams(class,assessment_type,code,max_score,duration_min,report_column,subject,term,session)
    values('JSS 1A','midterm','MTH1',20,60,'CA1','Mathematics','First Term','2026/2027') returning id`)).id;
  await db.exec(`insert into cbt_results(exam_id,student_name,student_id_ref,score,total,percent,grading_status,engine_version)
    values('${ex}','Ada Obi','ADM001',16,20,80,'graded','v5.1.3')`);
  const push = async () => (await one(`select sc_cbt_bulk_push_batch_v1(array['${ex}']::uuid[],null,false,20,false,'best',null,false) r`)).r;
  const rows = async () => q(`select ac.name, rs.score from report_scores rs join assessment_columns ac on ac.id=rs.column_id order by 1`);
  return { db, q, one, ADM, ex, push, rows };
}

/* ---------- the teacher's exact sequence, WITH a signed-in session ---------- */
{
  const S = await school();
  await S.db.query(`select set_config('request.jwt.claim.sub',$1,false)`, [S.ADM]);
  await S.push();
  ok((await S.rows()).map(r => r.name).join() === 'CA1', 'push 1 lands in the wrong column CA1');
  await S.db.exec(`update cbt_exams set report_column='Midterm Test' where id='${S.ex}'`);
  ok((await S.rows()).map(r => r.name).join() === 'Midterm Test', 'changing the column MOVES the mark immediately');
  await S.db.exec(`update cbt_results set score=18, percent=90 where exam_id='${S.ex}'`);
  await S.push();
  const rows = await S.rows();
  ok(rows.length === 1, 'no duplicate row after regrade and re-push', rows);
  ok(rows[0].name === 'Midterm Test', 'the single row is in the right column', rows);
  ok(Number(rows[0].score) === 18, 'the score is the regraded one', rows);
}

/* ---------- the same sequence with NO session (migration / service role) ---- */
{
  const S = await school();
  await S.db.query(`select set_config('request.jwt.claim.sub',$1,false)`, [S.ADM]);
  await S.push();
  await S.db.exec(`select set_config('request.jwt.claim.sub','',false)`);   // no auth.uid()
  await S.db.exec(`update cbt_exams set report_column='Midterm Test' where id='${S.ex}'`);
  const rows = await S.rows();
  ok(rows.length === 1 && rows[0].name === 'Midterm Test',
     'the remap still works when there is no session identity', rows);
}

/* ---------- re-pushing twice must never double up ---------- */
{
  const S = await school();
  await S.db.query(`select set_config('request.jwt.claim.sub',$1,false)`, [S.ADM]);
  await S.db.exec(`update cbt_exams set report_column='Midterm Test' where id='${S.ex}'`);
  await S.push(); await S.push(); await S.push();
  const rows = await S.rows();
  ok(rows.length === 1, 'three pushes still leave exactly one row', rows);
}

console.log(`cbt re-column: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
