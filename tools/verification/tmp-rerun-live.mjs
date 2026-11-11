/* V12.68 — "safe to run again" must be PROVED, not claimed.
   This loads the complete schema onto a database that already has data in it,
   twice, and asserts:
     * no error on either run
     * every row of data is still there, unchanged
     * no duplicate objects appear on the second run
   If this passes, running the file after a release cannot damage a school. */
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import { schemaText } from './schema-loader.mjs';
const H = new URL('.', import.meta.url).pathname;
const db = await PGlite.create();
await db.exec(fs.readFileSync(H + 'pglite-boot.sql', 'utf8'));
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;`);
const SQL = schemaText(H + '../../database/complete-schema.sql');
let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? (pass++, console.log('  PASS', m)) : (fail++, console.log('  FAIL', m, x ?? '')); };

console.log('\n=== first install ===');
await db.exec(SQL);
ok(true, 'the schema applies to an empty database');

/* a school's live data */
const S1 = 'aaaaaaaa-1111-1111-1111-111111111111';
await db.exec(`
  insert into students(id,full_name,class,admission_no,status) values
    ('${S1}','Afolabi Lekan','SS 2','A/1','active');
  insert into class_fee_structure(class,term,session,total,tuition,active)
    values('SS 2','First Term','2026/2027',35100,27000,true);
  insert into academic_periods(session,term,starts_on,ends_on,is_current)
    values('2026/2027','First Term','2026-09-14','2026-12-11',true);
  insert into fee_payments(student_id,student_name,amount_paid,method,term,session,payment_date)
    values('${S1}','Afolabi Lekan',10000,'cash','First Term','2026/2027','2026-10-31');
  insert into sc_fee_invoice(student_id,class,term,session,amount,net_amount,source)
    values('${S1}','SS 2','First Term','2026/2027',35100,35100,'structure');
`);
const snap = async () => ({
  students: (await db.query(`select id, full_name, class, admission_no, status from students order by id`)).rows,
  structures: (await db.query(`select class, term, session, total, tuition from class_fee_structure order by class`)).rows,
  periods: (await db.query(`select session, term, starts_on, ends_on, is_current from academic_periods order by term`)).rows,
  payments: (await db.query(`select id, student_id, amount_paid, method, term, session, payment_date from fee_payments order by id`)).rows,
  invoices: (await db.query(`select id, student_id, amount, net_amount, source from sc_fee_invoice order by id`)).rows,
  counts: (await db.query(`
    select (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
             where n.nspname='public' and c.relkind='r') as tables,
           (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='public') as functions,
           (select count(*) from pg_policies where schemaname='public') as policies,
           (select count(*) from pg_indexes where schemaname='public') as indexes,
           (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
             join pg_namespace n on n.oid=c.relnamespace
             where not t.tgisinternal and n.nspname='public') as triggers`)).rows[0],
});
const before = await snap();
const billBefore = (await db.query(`select public.sc_fee_bill_v2('${S1}',null,null) as b`)).rows[0].b;

console.log('\n=== second run, on a database with data in it ===');
let err2 = null;
try { await db.exec(SQL); } catch (e) { err2 = e.message.split('\n').slice(0, 3).join(' '); }
ok(!err2, 'the schema re-applies with no error on a populated database', err2);
const after = await snap();

ok(JSON.stringify(before.students) === JSON.stringify(after.students), 'no student row was changed or lost', { before: before.students.length, after: after.students.length });
ok(JSON.stringify(before.structures) === JSON.stringify(after.structures), 'the class fee structure is untouched');
ok(JSON.stringify(before.periods) === JSON.stringify(after.periods), 'the academic calendar is untouched');
ok(JSON.stringify(before.payments) === JSON.stringify(after.payments), 'every payment is byte-identical (amount, term, session, date)');
ok(JSON.stringify(before.invoices) === JSON.stringify(after.invoices), 'every invoice is byte-identical');
ok(Number(before.payments[0].amount_paid) === 10000, 'the 10,000 receipt still exists', before.payments[0]);

console.log('\n=== no duplicate objects ===');
for (const k of ['tables','functions','policies','indexes','triggers']) {
  ok(Number(before.counts[k]) === Number(after.counts[k]),
     `${k}: ${before.counts[k]} before, ${after.counts[k]} after`, { before: before.counts[k], after: after.counts[k] });
}

console.log('\n=== the money is identical after the re-run ===');
const billAfter = (await db.query(`select public.sc_fee_bill_v2('${S1}',null,null) as b`)).rows[0].b;
ok(JSON.stringify(billBefore) === JSON.stringify(billAfter), 'the same bill, figure for figure', { before: billBefore && billBefore.bill, after: billAfter && billAfter.bill });
ok(Number(billAfter.bill) === 35100, 'bill is still 35,100', billAfter.bill);

console.log('\n=== third run (belt and braces) ===');
let err3 = null;
try { await db.exec(SQL); } catch (e) { err3 = e.message.split('\n')[0]; }
ok(!err3, 'and a third time', err3);
const rows3 = (await db.query(`select count(*) c from fee_payments`)).rows[0].c;
ok(Number(rows3) === 1, 'still exactly one receipt after three runs', rows3);

console.log(`\n  ${pass} passed, ${fail} failed\n`);
await db.close();
process.exit(fail ? 1 : 0);
