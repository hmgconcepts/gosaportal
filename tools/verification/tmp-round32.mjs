/* Round 32 — proof for V12.86: new/returning billing, honest receipt repair,
   one-click fee doctor, and the affective round-trip. */
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import { schemaText } from './schema-loader.mjs';
const HERE = new URL('.', import.meta.url).pathname;
let pass = 0, fail = 0;
const ok = (c, m, extra) => { console.log(`  ${c ? 'PASS' : 'FAIL'}  ${m}${c || extra === undefined ? '' : '  → ' + JSON.stringify(extra)}`); c ? pass++ : fail++; };
const n = v => Number(v || 0);
const eq = (a, b) => Math.abs(n(a) - n(b)) < 0.005;

const db = await PGlite.create();
await db.exec(fs.readFileSync(HERE + 'pglite-boot.sql', 'utf8'));
const UID = '11111111-1111-1111-1111-111111111111';
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$ select '${UID}'::uuid $$;`);
await db.exec(schemaText(HERE + '../../database/complete-schema.sql'));
await db.exec(`
  insert into auth.users(id,email) values ('${UID}','bursar@school.test') on conflict do nothing;
  insert into profiles(id,full_name,role,status) values ('${UID}','Bursar','admin','approved')
    on conflict (id) do update set role='admin', status='approved';
  insert into academic_periods(term,session,is_current) values ('First Term','2026/2027',true) on conflict do nothing;
`);
const q = async (sql, p) => (await db.query(sql, p)).rows;
const call = async (fn, args) => (await q(`select public.${fn}(${args}) r`))[0].r;

const RET = 'aaaaaaaa-0000-0000-0000-000000000001';
const NEW = 'aaaaaaaa-0000-0000-0000-000000000002';
const DUP = 'aaaaaaaa-0000-0000-0000-000000000003';

console.log('\n=== 1. a learner is new or returning, and the school can say why ===');
await db.exec(`
  insert into students(id,full_name,admission_no,class,status,created_at) values
    ('${RET}','RETURNING LEARNER','GoSA/RET','JSS 3','active', now() - interval '400 days'),
    ('${NEW}','NEW LEARNER','GoSA/NEW','JSS 3','active', now()),
    ('${DUP}','DOUBLE RECEIPT LEARNER','GoSA/DUP','JSS 3','active', now() - interval '400 days')
  on conflict (id) do nothing;
  update students set arm='A' where class='JSS 3';
  insert into fee_payments(student_id,student_name,amount_paid,payment_date,method,term,session,fee_total)
    values ('${RET}','RETURNING LEARNER',20000,'2025-11-04','cash','First Term','2025/2026',28100)
    on conflict do nothing;
`);
ok(await q(`select coalesce(first_session,'') f from students where id='${RET}'`).then(r => r[0].f === ''),
   'a learner with no stored first session still resolves correctly (the receipts decide)');
const tRet = await call('sc_student_type', `'${RET}'`);
const tNew = await call('sc_student_type', `'${NEW}'`);
ok(tRet === 'returning', `a learner billed in an earlier session is returning (${tRet})`);
ok(tNew === 'new', `a learner with no earlier session is new (${tNew})`);
await db.exec(`update students set student_type='returning' where id='${NEW}'`);
ok(await call('sc_student_type', `'${NEW}'`) === 'returning', 'an explicit choice on the learner record wins over the guess');
await db.exec(`update students set student_type='' where id='${NEW}'`);

console.log('\n=== 2. two price lists for one class and term (item 2) ===');
await db.exec(`
  insert into class_fee_structure(class,arm,department,term,session,tuition,total,student_type)
    values ('JSS 3','A','','First Term','2026/2027',28100,28100,'returning'),
           ('JSS 3','A','','First Term','2026/2027',28100,28100,'new');
`);
const rows = await q(`select student_type from class_fee_structure where class='JSS 3' and term='First Term' and session='2026/2027' order by 1`);
ok(rows.length === 2, `a returning price and a new price coexist (${rows.length} rows)`);
await db.exec(`
  insert into class_fee_extra(class,arm,term,session,name,amount,applies_to)
    values ('JSS 3','','First Term','2026/2027','Admission fee',5000,'new'),
           ('JSS 3','','First Term','2026/2027','Uniform & books',3000,'new'),
           ('JSS 3','','First Term','2026/2027','Excursion',2000,'all');
`);

console.log('\n=== 3. what each learner is actually billed (item 9) ===');
const billNew = await call('sc_fee_bill_v2_structure', `'${NEW}','First Term','2026/2027'`);
const billRet = await call('sc_fee_bill_v2_structure', `'${RET}','First Term','2026/2027'`);
ok(eq(billNew.bill, 38100), `a new learner is billed the class bill + new-learner fees (${n(billNew.bill)})`, billNew.breakdown);
ok(eq(billNew.extras_total, 10000), `the extras are itemised separately (${n(billNew.extras_total)})`, billNew.extras_total);
ok(eq(billRet.bill, 30100), `a returning learner is billed the class bill + only what everyone pays (${n(billRet.bill)})`, billRet.bill);
ok(eq(billRet.extras_total, 2000), `and none of the new-learner fees (${n(billRet.extras_total)})`, billRet.extras_total);
ok(billNew.student_type === 'new' && billRet.student_type === 'returning', 'the bill states which group it used');
const lines = (billNew.breakdown || []).filter(x => String(x.item || x.label || '').startsWith('🆕'));
ok(lines.length >= 2, `each new-learner fee is its own line on the bill (${lines.length})`, lines);

console.log('\n=== 4. repairing stored receipt totals without inventing anything (item 6) ===');
await db.exec(`
  insert into fee_payments(student_id,student_name,amount_paid,payment_date,method,term,session,fee_total)
    values ('${RET}','RETURNING LEARNER',1000,'2026-11-01','cash','First Term','2026/2027',30100);
`);
const dry = await call('sc_fee_truth_migrate', 'true');
ok(dry.ok === true && dry.dry_run === true, 'the check runs and changes nothing');
ok(n(dry.kept_correct) >= 1, `a receipt that already matches the bill is kept (${n(dry.kept_correct)})`);
/* the autoheal trigger would rewrite the snapshot; switch it off to reproduce a
   stored figure that disagrees with the bill, which is what item 6 is about */
await db.exec(`alter table fee_payments disable trigger trg_fee_rows_autoheal_upd;
                alter table fee_payments disable trigger trg_compute_fee_payment_balance;`);
await db.exec(`update fee_payments set fee_total = 36100 where student_id='${RET}' and session='2026/2027'`);
const dry2 = await call('sc_fee_truth_migrate', 'true');
const sample = (dry2.samples || []).find(x => x.student === 'RETURNING LEARNER' && x.session === '2026/2027');
ok(sample && sample.verdict === 'keep', `an unexplained difference is NOT rewritten (${sample && sample.verdict})`, sample);
ok(sample && sample.why === 'unexplained', `and the reason is named (${sample && sample.why})`);
const applied = await call('sc_fee_truth_migrate', 'false');
await db.exec(`alter table fee_payments enable trigger trg_fee_rows_autoheal_upd;
                alter table fee_payments enable trigger trg_compute_fee_payment_balance;`);
const still = await q(`select fee_total from fee_payments where student_id='${RET}' and session='2026/2027'`);
ok(eq(still[0].fee_total, 36100), `the stored figure survived the repair (${n(still[0].fee_total)})`);
ok(applied.ok === true, 'the repair reports what it did');

console.log('\n=== 5. the fee doctor: every finding fixable in one click (items 7 & 8) ===');
// an overpayment that is really a new learner billed without their extras
await db.exec(`
  insert into sc_fee_invoice(student_id,student_id_ref,class,term,session,amount,aid,net_amount,source)
    values ('${NEW}','GoSA/NEW','JSS 3','First Term','2026/2027',28100,0,28100,'structure');
  insert into fee_payments(student_id,student_name,amount_paid,payment_date,method,term,session,fee_total)
    values ('${NEW}','NEW LEARNER',36100,'2026-11-02','transfer','First Term','2026/2027',28100);
  insert into fee_payments(student_id,student_name,amount_paid,payment_date,method,term,session,reference,fee_total)
    values ('${DUP}','DOUBLE RECEIPT LEARNER',5000,'2026-11-03','cash','First Term','2026/2027','R9',28100),
           ('${DUP}','DOUBLE RECEIPT LEARNER',5000,'2026-11-03','cash','First Term','2026/2027','R9',28100);
`);
const scan1 = await call('sc_fee_doctor_v4', 'false, null');
const get = (d, k) => (d.checks || []).find(c => c.key === k) || {};
ok(scan1.ok === true, 'the doctor scans');
ok(n(get(scan1, 'overpayments').found) === 1, `it finds the overpayment (${n(get(scan1, 'overpayments').found)})`, scan1.checks);
ok(n(get(scan1, 'duplicate_receipts').found) === 1, `it finds the duplicate receipt (${n(get(scan1, 'duplicate_receipts').found)})`);
ok(get(scan1, 'overpayments').fixable === true, 'and says the overpayment can be fixed in one click');
const fixOP = await call('sc_fee_doctor_v4', `true, 'overpayments'`);
const credit = await q(`select credit_balance from students where id='${NEW}'`);
ok(eq(credit[0].credit_balance, 8000), `the excess is held as credit, no receipt touched (${n(credit[0].credit_balance)})`);
ok(n(get(fixOP, 'overpayments').found) === 0, `and it stops being reported in the same breath (${n(get(fixOP, 'overpayments').found)})`);
const fixDup = await call('sc_fee_doctor_v4', `true, 'duplicate_receipts'`);
ok(n(get(fixDup, 'duplicate_receipts').found) === 0, 'the duplicate is gone');
const dupLeft = await q(`select count(*)::int c from fee_payments where student_id='${DUP}'`);
ok(dupLeft[0].c === 1, `one receipt remains, the copy is removed (${dupLeft[0].c})`);

// CBT score in two report columns
await db.exec(`
  insert into assessment_columns(id,class,subject,term,session,name,source,max_mark)
    values ('bbbbbbbb-0000-0000-0000-000000000001','JSS 3','Mathematics','First Term','2026/2027','CBT',  'manual',100),
           ('bbbbbbbb-0000-0000-0000-000000000002','JSS 3','Mathematics','First Term','2026/2027','Test 1','manual',100)
    on conflict do nothing;
  insert into report_scores(column_id,student_id,student_id_ref,student_name,class,subject,term,session,score,source)
    values ('bbbbbbbb-0000-0000-0000-000000000001','${RET}','GoSA/RET','RETURNING LEARNER','JSS 3','Mathematics','First Term','2026/2027',75,'cbt:cccccccc-0000-0000-0000-000000000001'),
           ('bbbbbbbb-0000-0000-0000-000000000002','${RET}','GoSA/RET','RETURNING LEARNER','JSS 3','Mathematics','First Term','2026/2027',75,'cbt:cccccccc-0000-0000-0000-000000000001');
`);
const scan2 = await call('sc_fee_doctor_v4', 'false, null');
ok(n(get(scan2, 'cbt_two_columns').found) === 1, `it finds the score counted twice (${n(get(scan2, 'cbt_two_columns').found)})`);
const fixCbt = await call('sc_fee_doctor_v4', `true, 'cbt_two_columns'`);
const left = await q(`select count(*)::int c from report_scores where student_id_ref='GoSA/RET'`);
ok(left[0].c === 1, `one score remains after the click (${left[0].c})`);
ok(n(get(fixCbt, 'cbt_two_columns').found) === 0, 'and nothing is re-raised');

console.log('\n=== 6. a second press finds nothing (item 8) ===');
const scan3 = await call('sc_fee_doctor_v4', 'false, null');
const open = (scan3.checks || []).filter(c => c.fixable && n(c.found) > 0);
ok(open.length === 0, `every fixable check is at zero (${open.map(c => c.key + '=' + n(c.found)).join(', ') || 'none open'})`, open);
const log = await q(`select count(*)::int c from sc_repair_log`);
ok(log[0].c >= 3, `every repair was written to the log (${log[0].c} entries)`);

console.log('\n=== 7. the affective domain remembers (item 5) ===');
await db.exec(`
  insert into affective_traits(student_id,term,session,ratings,teacher_id)
    values ('${RET}','First Term','2026/2027','{"Punctuality":5,"Neatness":4}'::jsonb,'${UID}')
  on conflict (student_id,term,session) do update set ratings=excluded.ratings;
`);
const saved = await q(`select ratings from affective_traits where student_id='${RET}' and lower(term)='first term' and session='2026/2027'`);
ok(saved.length === 1 && n(saved[0].ratings.Punctuality) === 5, 'a rating written for a term reads back for that term', saved[0] && saved[0].ratings);
const other = await q(`select ratings from affective_traits where student_id='${RET}' and session='2025/2026'`);
ok(other.length === 0, 'and is not invented for a term nobody saved');

console.log(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
