/* V12.68 — the fee engine must not THROW on real-world mess.
   The dashboard hides r.error behind "run v9.4", so any runtime exception here
   reads to the school as "the database update is missing". Every case below is
   a shape that exists in live school data. */
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import { schemaText } from './schema-loader.mjs';
const H = new URL('.', import.meta.url).pathname;
const db = await PGlite.create();
await db.exec(fs.readFileSync(H + 'pglite-boot.sql', 'utf8'));
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;`);
await db.exec(schemaText(H + '../../database/complete-schema.sql'));
const ADM = '11111111-1111-1111-1111-111111111111';
await db.exec(`
  insert into auth.users(id,email) values('${ADM}','a@x.t') on conflict do nothing;
  insert into profiles(id,full_name,role,status) values('${ADM}','A','admin','approved') on conflict(id) do nothing;
  select set_config('request.jwt.claim.sub','${ADM}',false);`);

const cases = [
  ['NULL class',              `insert into students(id,full_name,class,status) values('b0000000-0000-0000-0000-000000000001','Null Class',null,'active')`],
  ['empty class',             `insert into students(id,full_name,class,status) values('b0000000-0000-0000-0000-000000000002','Empty Class','','active')`],
  ['class with no structure', `insert into students(id,full_name,class,status) values('b0000000-0000-0000-0000-000000000003','Orphan Class','SS 9','active')`],
  ['structure, NULL totals',  `insert into class_fee_structure(class,term,session,active) values('SS 9','First Term','2026/2027',true)`],
  ['NULL session structure',  `insert into class_fee_structure(class,term,session,total,active) values('SS 8',null,null,1000,true)`],
  ['structure total only',    `insert into class_fee_structure(class,term,session,total,active) values('SS 8','First Term','2026/2027',null,true)`],
  ['student w/ NULL arm',     `insert into students(id,full_name,class,arm,status) values('b0000000-0000-0000-0000-000000000004','Null Arm','SS 8',null,'active')`],
  ['school_settings no row',  `delete from school_settings`],
  ['school_settings null cur',`insert into school_settings(currency) values(null)`],
  ['payment w/ NULL amount',  `insert into fee_payments(student_id,student_name,amount_paid,term,session) values('b0000000-0000-0000-0000-000000000004','Null Arm',null,'First Term','2026/2027')`],
  ['payment w/ NULL term',    `insert into fee_payments(student_id,student_name,amount_paid) values('b0000000-0000-0000-0000-000000000004','Null Arm',500)`],
  ['period w/ NULL dates',    `insert into academic_periods(session,term,is_current) values('2026/2027','First Term',true) on conflict (session,term) do update set starts_on=null, ends_on=null, is_current=true`],
  ['duplicate structures',    `insert into class_fee_structure(class,term,session,total,active) values('SS 8','First Term','2026/2027',999,true)`],
  ['invoice, NULL amounts',   `insert into sc_fee_invoice(student_id,term,session,amount,aid,net_amount,source) values('b0000000-0000-0000-0000-000000000004','First Term','2026/2027',null,null,null,'manual')`],
];

let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? (pass++, console.log('  PASS', m)) : (fail++, console.log('  FAIL', m, x ?? '')); };

for (const [label, sql] of cases) {
  let setupErr = null;
  try { await db.exec(sql); } catch (e) { setupErr = e.message.split('\n')[0]; }
  if (setupErr) { console.log('  --   ' + label + ': (skipped, seed: ' + setupErr + ')'); continue; }
  const ids = (await db.query(`select id from students order by id`)).rows.map(r => r.id);
  for (const id of ids) {
    for (const fn of ['sc_student_fee_state', 'sc_fee_explain']) {
      try {
        const arg = fn === 'sc_fee_bill_audit' ? 'null' : `'${id}'`;
        const r = (await db.query(`select public.${fn}(${arg}) as r`)).rows[0].r;
        const o = typeof r === 'string' ? JSON.parse(r) : r;
        ok(o && o.ok !== false, `${label}: ${fn} answers (ok=${o && o.ok})`, o && o.error);
      } catch (e) {
        ok(false, `${label}: ${fn} THREW`, e.message.split('\n')[0]);
      }
    }
  }
}
console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
