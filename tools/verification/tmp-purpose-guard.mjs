/* V12.72 item 2 — a purpose created as "never on the report card" must be
   refused by the results ledger, not merely stored with a flag nobody reads. */
import { PGlite } from '@electric-sql/pglite';
import { schemaText } from './schema-loader.mjs';
const HERE = new URL('.', import.meta.url).pathname;
const db = new PGlite();
await db.exec(schemaText(HERE + '../../database/complete-schema.sql'));
const q = async (s) => (await db.query(s)).rows;
let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  FAIL ' + m)); };

ok((await q("select report_eligible from sc_assessment_purpose where slug='prep'"))[0].report_eligible === false,
   'builtin prep is report_eligible=false');

// a school adds "Mock Exam" and sets it to stay off the report card
await db.exec(`insert into sc_assessment_purpose(slug,label,emoji,report_eligible,feeds_report,is_builtin,sort_order,description)
  values('mock_exam','Mock Exam','🎯',false,'none',false,80,'Custom. Off the report card.')
  on conflict (slug) do update set report_eligible=false`);
await db.exec(`insert into sc_assessment_purpose(slug,label,emoji,report_eligible,feeds_report,is_builtin,sort_order,description)
  values('debate','Debate','🗣️',true,'none',false,81,'Custom. On the report card.')
  on conflict (slug) do update set report_eligible=true`);

ok((await q("select sc_purpose_report_eligible('prep') as e"))[0].e === false, 'eligible(prep)=false');
ok((await q("select sc_purpose_report_eligible('mock_exam') as e"))[0].e === false, 'eligible(custom, off)=false');
ok((await q("select sc_purpose_report_eligible('debate') as e"))[0].e === true, 'eligible(custom, on)=true');
ok((await q("select sc_purpose_report_eligible('exam') as e"))[0].e === true, 'eligible(exam)=true');
ok((await q("select sc_purpose_report_eligible('never-heard-of-it') as e"))[0].e === true,
   'an unknown purpose stays eligible so no score is ever lost');

const cls = (await q("select name from classes limit 1"))[0];
const C = cls?.name || 'JSS1';
await db.exec(`insert into academic_periods(session,term,is_current) values('2026/2027','First Term',true) on conflict do nothing`);
// cbt_exams carries no title/subject/term columns — a CBT names its subject
// through its questions. Insert only columns that exist.
const mk = async (type, code) => (await q(`insert into cbt_exams(class,assessment_type,code,max_score,duration_min)
  values('${C}','${type}','${code}',100,60) returning id`))[0].id;

// the push walks cbt_results, so a result must exist for it to reach the guard
const pushWith = async (type, code) => {
  const id = await mk(type, code);
  await db.exec(`insert into cbt_results(exam_id,student_name,student_id_ref,score,percent)
    values('${id}','Ada Obi','ADM001',72,72)`);
  return q(`select sc_push_cbt_to_results('${id}'::uuid,'exam','First Term','2026/2027') as n`);
};
let blocked = false;
try { await pushWith('mock_exam','MOCK1'); }
catch (e) { blocked = /report card|results ledger/.test(e.message); }
ok(blocked, 'an ineligible custom purpose cannot reach the results ledger');

let prepBlocked = false;
try { await pushWith('prep','PREP1'); }
catch (e) { prepBlocked = /prep \(rehearsal\)/.test(e.message); }
ok(prepBlocked, 'prep is still refused by the same path');

let allowed = true;
try { await pushWith('debate','DEB1'); }
catch (e) { allowed = false; console.log('    unexpected block:', e.message.slice(0,120)); }
ok(allowed, 'an eligible custom purpose still pushes normally');

console.log(`purpose guard: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
