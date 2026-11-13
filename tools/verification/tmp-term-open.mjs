/* ROUND-15 ITEM 6 — "one click" must actually prepare a term.
   Proves sc_term_open against a real Postgres (PGlite):
     A. preview writes NOTHING
     B. apply creates the same columns, with the same maxima and weights
     C. NO MARKS MOVE — the old term keeps every score, the new term has none
     D. running it twice creates nothing the second time (idempotent)
     E. a class the school teaches but never assessed is reported, not hidden
     F. a source term with no structure is refused with a reason
*/
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { schemaText } from './schema-loader.mjs';

const HERE = new URL('.', import.meta.url).pathname;
const db = new PGlite();
await db.exec(readFileSync(HERE + 'pglite-boot.sql', 'utf8'));
/* auth.uid() is Supabase's; PGlite has no session, so stand it up from a GUC —
   the same technique tmp-term-carry.mjs uses. */
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;`);
try { await db.exec(schemaText(HERE + '../../database/complete-schema.sql')); }
catch(e){ console.log('SCHEMA FAILED', e.message); process.exit(1); }

const ADMIN='11111111-1111-1111-1111-111111111111';
const asAdmin = async () => { await db.exec(`select set_config('request.jwt.claim.sub','${ADMIN}',false)`); };
/* an admin identity: auth.users row (profiles FKs to it), profile, role */
await db.exec(`
  insert into auth.users(id,email) values ('${ADMIN}','boss@x.test') on conflict (id) do nothing;
  insert into public.profiles(id, full_name, role, status) values ('${ADMIN}','Boss','admin','approved')
    on conflict (id) do update set role='admin', status='approved';
`);
await asAdmin();

let pass=0, fail=0;
const ok=(c,n,d)=>{ if(c){pass++;} else {fail++; console.log('  FAIL', n, d===undefined?'':JSON.stringify(d).slice(0,300));} };

/* seed a previous term with structure AND marks */
await db.exec(`
  insert into assessment_columns(class,subject,term,session,name,max_mark,weight,position,source)
  values ('JSS 1','*','First Term','2025/2026','CA1',10,10,1,'manual'),
         ('JSS 1','*','First Term','2025/2026','CA2',10,10,2,'manual'),
         ('JSS 1','*','First Term','2025/2026','Exam',70,70,3,'manual'),
         ('JSS 2','*','First Term','2025/2026','CA1',20,20,1,'manual'),
         ('JSS 2','*','First Term','2025/2026','Exam',80,80,2,'manual');
`);
const cols=await db.query(`select class,name,max_mark,weight,position from assessment_columns
   where term='First Term' order by class,position`);
ok(cols.rows.length===5,'seeded 5 assessment columns for First Term',cols.rows.length);

/* a learner with a real mark in the old term */
const stu=await db.query(`insert into students(full_name,class,admission_no,status)
  values('Ada Obi','JSS 1','SC/001','active') returning id`);
const sid=stu.rows[0].id;
const c1=await db.query(`select id from assessment_columns where class='JSS 1' and name='CA1' and term='First Term'`);
await db.query(`insert into report_scores(student_id,class,subject,term,session,column_id,score)
  values($1,'JSS 1','Maths','First Term','2025/2026',$2,8)`,[sid,c1.rows[0].id]);

/* ---- A. preview writes nothing ---- */
const prev=await db.query(`select public.sc_term_open('Second Term','2025/2026','First Term','2025/2026',true) as r`);
const pr=prev.rows[0].r;
ok(pr.ok===true,'A: preview returns ok',pr);
ok(pr.dry_run===true,'A: preview is flagged as a dry run');
ok(Number(pr.columns_created)===5,'A: preview reports the 5 columns it WOULD create',pr.columns_created);
const after=await db.query(`select count(*)::int n from assessment_columns where term='Second Term'`);
ok(after.rows[0].n===0,'A: preview wrote NOTHING to the database',after.rows[0].n);

/* ---- B. apply creates the same columns ---- */
const app=await db.query(`select public.sc_term_open('Second Term','2025/2026','First Term','2025/2026',false) as r`);
const ar=app.rows[0].r;
ok(ar.ok===true,'B: apply returns ok',ar);
const made=await db.query(`select class,name,max_mark,weight,position from assessment_columns
   where term='Second Term' order by class,position`);
ok(made.rows.length===5,'B: 5 columns exist in the new term',made.rows.length);
const sameShape=made.rows.every((r,i)=>{
  const o=cols.rows[i];
  return r.class===o.class && r.name===o.name &&
         Number(r.max_mark)===Number(o.max_mark) && Number(r.weight)===Number(o.weight) &&
         Number(r.position)===Number(o.position);
});
ok(sameShape,'B: every new column has the SAME name, maximum, weight and order',made.rows);

/* ---- C. no marks move ---- */
const oldScores=await db.query(`select count(*)::int n, coalesce(sum(score),0) s from report_scores where term='First Term'`);
const newScores=await db.query(`select count(*)::int n from report_scores where term='Second Term'`);
ok(oldScores.rows[0].n===1 && Number(oldScores.rows[0].s)===8,
   'C: the old term still holds its mark, unchanged',oldScores.rows[0]);
ok(newScores.rows[0].n===0,'C: the new term holds NO marks — history was not duplicated',newScores.rows[0].n);
ok(Number(ar.marks_copied)===0,'C: the function itself reports marks_copied = 0',ar.marks_copied);

/* ---- D. idempotent ---- */
const again=await db.query(`select public.sc_term_open('Second Term','2025/2026','First Term','2025/2026',false) as r`);
const againCols=await db.query(`select count(*)::int n from assessment_columns where term='Second Term'`);
ok(againCols.rows[0].n===5,'D: a second run creates NOTHING new',againCols.rows[0].n);
ok((again.rows[0].r.classes_already_ready||[]).length===2,
   'D: and reports both classes as already ready',again.rows[0].r.classes_already_ready);

/* ---- E. a class with no structure is surfaced ---- */
await db.query(`insert into students(full_name,class,admission_no,status)
  values('Bola Ade','JSS 3','SC/002','active')`);
const e=await db.query(`select public.sc_term_open('Second Term','2025/2026','First Term','2025/2026',true) as r`);
const er=e.rows[0].r;
ok(JSON.stringify(er.classes_without_structure).includes('JSS 3'),
   'E: a taught class with no columns is named, not silently skipped',er.classes_without_structure);
ok(/JSS 3/.test(er.next_step||''),'E: and the next step names it');

/* ---- F. a source term with no structure is refused ---- */
const f=await db.query(`select public.sc_term_open('Third Term','2025/2026','Third Term','2024/2025',false) as r`);
ok(f.rows[0].r.ok===false,'F: a source term with no columns is refused',f.rows[0].r);
ok(/no assessment columns/i.test(f.rows[0].r.error||''),'F: with a reason the school can act on');

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail?1:0);
