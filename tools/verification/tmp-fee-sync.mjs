/* V12.73 item 12 — a payment the bursar deletes, or a fee the teacher edits,
   must reach the student's end. No stale balance anywhere. */
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
await db.exec(`insert into auth.users(id,email) values('${ADM}','b@x.t') on conflict do nothing;
  insert into profiles(id,full_name,role,status) values('${ADM}','Bursar','bursar','approved')
    on conflict(id) do update set role='bursar',status='approved';`);
await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[ADM]);
await db.exec(`insert into classes(name) values('JSS 1A') on conflict do nothing;
  insert into academic_periods(session,term,is_current) values('2026/2027','First Term',true) on conflict do nothing`);
const stu = (await one(`insert into students(full_name,admission_no,class) values('Ada Obi','ADM001','JSS 1A') returning id`)).id;

/* the bursar records a payment */
const fp = (await one(`insert into fee_payments(student_id,amount_paid,method,reference,term,session,payment_date)
  values('${stu}',25000,'cash','RCPT-1','First Term','2026/2027',current_date) returning id`)).id;
const after1 = await q(`select amount_paid from fee_payments where id='${fp}'`);
ok(Number(after1[0].amount_paid) === 25000, 'the payment is recorded', after1);

/* WRONG ENTRY — the bursar deletes it */
await db.exec(`delete from fee_payments where id='${fp}'`);
const gone = await q(`select count(*) n from fee_payments where id='${fp}'`);
ok(Number(gone[0].n) === 0, 'the mistaken payment is gone from the ledger');

/* what the STUDENT's own page reads: their payments straight from the ledger */
const studentSees = async () => q(`select amount_paid from fee_payments where student_id='${stu}' order by created_at`);
ok((await studentSees()).length === 0, 'the student sees NO payment after the delete (no stale figure)');

/* a correct payment is recorded and the student sees exactly it */
await db.exec(`insert into fee_payments(student_id,amount_paid,method,reference,term,session,payment_date)
  values('${stu}',25000,'cash','RCPT-2','First Term','2026/2027',current_date)`);
const seen2 = await studentSees();
ok(seen2.length === 1 && Number(seen2[0].amount_paid) === 25000, 'the student sees the recorded payment', seen2);

/* the bursar corrects the amount — the student must see the correction at once */
await db.exec(`update fee_payments set amount_paid=30000 where student_id='${stu}'`);
const seen3 = await studentSees();
ok(Number(seen3[0].amount_paid) === 30000, 'an EDITED payment reaches the student immediately', seen3);

/* and the total the student's receipt panel adds up agrees */
const total = (await one(`select coalesce(sum(amount_paid),0) t from fee_payments where student_id='${stu}'`)).t;
ok(Number(total) === 30000, 'the student\'s running total agrees with the ledger', total);

/* ======================================================================
   V12.74 item 7 (second half): a teacher EDITS a pre-existing school-fee
   record. sc_fee_bill_v2_structure treats a raised invoice as the bill and
   never re-reads class_fee_structure, so the learner kept quoting the old
   total for ever. The new trigger re-derives structure-sourced invoices and
   must leave a bursar's personal override alone.
   ====================================================================== */
await db.exec(`insert into class_fee_structure(class,term,session,tuition,total,active)
  values('JSS 1A','First Term','2026/2027',50000,50000,true)`);
await db.exec(`insert into sc_fee_invoice(student_id,class,term,session,amount,aid,net_amount,source)
  values('${stu}','JSS 1A','First Term','2026/2027',50000,0,50000,'structure')`);
const inv0 = await one(`select amount, net_amount from sc_fee_invoice where student_id='${stu}'`);
ok(Number(inv0.amount) === 50000, 'the invoice starts at the published fee', inv0);

/* the student's own card, before the correction */
const bill0 = await one(`select public.sc_student_fee_state('${stu}') s`);
ok(Number(bill0.s.bill) === 50000, 'the student is billed 50,000', bill0.s.bill);

/* the teacher corrects the price list */
await db.exec(`update class_fee_structure set tuition=60000, total=60000, updated_at=now()
  where class='JSS 1A' and term='First Term'`);
const inv1 = await one(`select amount, net_amount, note from sc_fee_invoice where student_id='${stu}'`);
ok(Number(inv1.amount) === 60000, 'EDITING THE FEE STRUCTURE UPDATES THE INVOICE', inv1);
ok(Number(inv1.net_amount) === 60000, 'the net amount follows too', inv1);

const bill1 = await one(`select public.sc_student_fee_state('${stu}') s`);
ok(Number(bill1.s.bill) === 60000, 'THE STUDENT NOW SEES THE CORRECTED TOTAL', bill1.s.bill);

/* a bursar's personal figure must survive the same edit */
const stu2 = (await one(`insert into students(full_name,admission_no,class) values('Bola Ade','ADM002','JSS 1A') returning id`)).id;
await db.exec(`insert into sc_fee_invoice(student_id,class,term,session,amount,aid,net_amount,source)
  values('${stu2}','JSS 1A','First Term','2026/2027',15000,0,15000,'override')`);
await db.exec(`update class_fee_structure set tuition=70000, total=70000, updated_at=now()
  where class='JSS 1A' and term='First Term'`);
const keep = await one(`select amount, source from sc_fee_invoice where student_id='${stu2}'`);
ok(Number(keep.amount) === 15000 && keep.source === 'override',
   'a bursar override is NOT overwritten by a price-list edit', keep);

/* and a deleted payment still reaches the learner's balance */
const before = await one(`select public.sc_student_fee_state('${stu}') s`);
ok(Number(before.s.paid) === 30000, 'the learner is credited with the edited payment', before.s.paid);
await db.exec(`delete from fee_payments where student_id='${stu}'`);
const after = await one(`select public.sc_student_fee_state('${stu}') s`);
ok(Number(after.s.paid) === 0, 'DELETING A MISTAKEN PAYMENT CLEARS IT ON THE STUDENT SIDE', after.s);
ok(Number(after.s.balance) === 70000, 'and the outstanding balance returns to the full bill', after.s.balance);

console.log(`fee sync: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
