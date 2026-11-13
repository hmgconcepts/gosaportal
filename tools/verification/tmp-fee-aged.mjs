/* ROUND-15 ITEM 5 — the financial reports must be TRUE against a real ledger.
   Proves sc_fee_aged_arrears, sc_fee_collection_summary and sc_fee_adjust on
   PGlite, because a bursar acts on these figures and a wrong age band sends a
   demand to a family that does not owe it yet. */
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { schemaText } from './schema-loader.mjs';
const HERE = new URL('.', import.meta.url).pathname;
const db = new PGlite();
await db.exec(readFileSync(HERE + 'pglite-boot.sql','utf8'));
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;`);
try{ await db.exec(schemaText(HERE + '../../database/complete-schema.sql')); }
catch(e){ console.log('SCHEMA FAILED', e.message); process.exit(1); }

const ADMIN='11111111-1111-1111-1111-111111111111';
await db.exec(`
  insert into auth.users(id,email) values ('${ADMIN}','boss@x.test') on conflict (id) do nothing;
  insert into public.profiles(id,full_name,role,status) values ('${ADMIN}','Boss','admin','approved')
    on conflict (id) do update set full_name='Boss',role='admin',status='approved';
  select set_config('request.jwt.claim.sub','${ADMIN}',false);
`);
let pass=0, fail=0;
const ok=(c,n,d)=>{ if(c) pass++; else { fail++; console.log('  FAIL',n,d===undefined?'':JSON.stringify(d).slice(0,300)); } };
const q=async(s,p)=> (await db.query(s,p)).rows;
const rpc=async(fn,args)=> JSON.parse(JSON.stringify((await q(`select public.${fn}(${args}) r`))[0].r));

/* ---- learners + invoices at controlled ages ---- */
const a=(await q(`insert into students(full_name,class,admission_no,status)
  values('Old Debt','JSS 1','SC/001','active') returning id`))[0].id;
const b=(await q(`insert into students(full_name,class,admission_no,status)
  values('Fresh Debt','JSS 1','SC/002','active') returning id`))[0].id;
const c=(await q(`insert into students(full_name,class,admission_no,status)
  values('Paid Up','JSS 1','SC/003','active') returning id`))[0].id;
const d=(await q(`insert into students(full_name,class,admission_no,status)
  values('Not Yet Due','JSS 2','SC/004','active') returning id`))[0].id;
const TODAY=currentDateString();
function currentDateString(){ const n=new Date(); return n.toISOString().slice(0,10); }

/* due dates: 120 days ago, 45 days ago, 45 days ago (fully paid), 20 days in the future */
await q(`insert into sc_fee_invoice(student_id,student_id_ref,class,term,session,amount,aid,net_amount,due_on)
  values ($1,'SC/001','JSS 1','First Term','2025/2026',50000,0,50000, current_date - 120)`, [a]);
await q(`insert into sc_fee_invoice(student_id,student_id_ref,class,term,session,amount,aid,net_amount,due_on)
  values ($1,'SC/002','JSS 1','First Term','2025/2026',30000,0,30000, current_date - 45)`, [b]);
await q(`insert into sc_fee_invoice(student_id,student_id_ref,class,term,session,amount,aid,net_amount,due_on)
  values ($1,'SC/003','JSS 1','First Term','2025/2026',20000,0,20000, current_date - 45)`, [c]);
await q(`insert into sc_fee_invoice(student_id,student_id_ref,class,term,session,amount,aid,net_amount,due_on)
  values ($1,'SC/004','JSS 2','First Term','2025/2026',40000,0,40000, current_date + 20)`, [d]);
await q(`insert into fee_payments(student_id,amount_paid,method,term,session)
  values ($1,20000,'cash','First Term','2025/2026')`, [c]);

/* ---- aged arrears ---- */
const ag=await rpc('sc_fee_aged_arrears',`current_date,null,null,null`);
ok(ag.ok===true,'aged arrears returns ok',ag);
const t=ag.totals||{};
ok(Number(t.over_90)===50000,'120-day-old debt lands in over_90',t.over_90);
ok(Number(t['31_60'])===30000,'45-day-old debt lands in 31_60',t['31_60']);
ok(Number(t.not_due)===40000,'money not yet payable lands in not_due, NOT in arrears',t.not_due);
ok(Number(t['0_30'])===0,'nothing lands in 0_30 here',t['0_30']);
ok(Number(t['61_90'])===0,'nothing lands in 61_90 here',t['61_90']);
ok(Number(t.learners)===3,'only the three learners with a real balance are listed',t.learners);
ok(Number(t.total)===120000,'total outstanding is the sum of the bands',t.total);
/* the paid-up learner must NOT appear */
ok(!ag.rows.some(r=>r.admission_no==='SC/003'),'a fully paid learner is not listed as owing',ag.rows.map(r=>r.admission_no));
/* every row states its band and age */
ok(ag.rows.every(r=>r.band&&Number(r.days_overdue)>=0),'every row carries an age band and a day count');
ok(/31-60 is a reminder/.test(ag.meaning||''),'the result explains what the bands mean');

/* a class filter must work */
const ag2=await rpc('sc_fee_aged_arrears',`current_date,'JSS 2',null,null`);
ok(Number((ag2.totals||{}).learners)===1,'the class filter narrows to one JSS 2 learner',(ag2.totals||{}).learners);

/* ---- collection summary ---- */
const cs=await rpc('sc_fee_collection_summary',`null,null`);
ok(cs.ok===true,'collection summary returns ok',cs);
const g=cs.totals||{};
ok(Number(g.billed)===140000,'billed is every invoice net of aid',g.billed);
ok(Number(g.collected)===20000,'collected is what actually arrived',g.collected);
ok(Number(g.outstanding)===120000,'outstanding matches the aged-arrears total',g.outstanding);
ok(Math.abs(Number(g.rate)-14.3)<0.2,'the collection rate is collected/billed',g.rate);
const j1=(cs.rows||[]).find(r=>r.class==='jss 1');
ok(j1 && Number(j1.billed)===100000 && Number(j1.collected)===20000,'per-class figures add up',j1);

/* ---- adjustments ---- */
const adj=await rpc('sc_fee_adjust',`'${a}','waiver',5000,'Bereavement — approved by the board',null,null`);
ok(adj.ok===true,'an adjustment with a reason is accepted',adj);
const bad1=await rpc('sc_fee_adjust',`'${a}','waiver',5000,'',null,null`);
ok(bad1.ok===false&&/reason/i.test(bad1.error||''),'an adjustment WITHOUT a reason is refused',bad1);
const bad2=await rpc('sc_fee_adjust',`'${a}','gift',5000,'x',null,null`);
ok(bad2.ok===false&&/credit, waiver/i.test(bad2.error||''),'an unknown kind is refused with the valid list',bad2);
const bad3=await rpc('sc_fee_adjust',`'${a}','waiver',-100,'x',null,null`);
ok(bad3.ok===false,'a negative adjustment is refused',bad3);
const reg=await rpc('sc_fee_adjustments',`null,null`);
ok(reg.ok===true&&(reg.rows||[]).length===1,'the register lists the one adjustment',(reg.rows||[]).length);
ok((reg.rows||[])[0] && (reg.rows[0].reason||'').includes('Bereavement'),'the register keeps the reason',reg.rows[0]);
ok((reg.rows||[])[0] && reg.rows[0].by==='Boss','the register records WHO made it',(reg.rows||[])[0]&&reg.rows[0].by);

/* ---- permissions ---- */
await db.exec(`select set_config('request.jwt.claim.sub','',false)`);
const anon=await rpc('sc_fee_aged_arrears',`current_date,null,null,null`);
ok(anon.ok===false,'an unauthenticated caller is refused',anon);


/* ---- bank & cash reconciliation ---- */
await db.exec(`select set_config('request.jwt.claim.sub','${ADMIN}',false)`);
await q(`insert into fee_payments(student_id,amount_paid,method,reference,term,session,received_by_name,payment_date)
  values ($1, 15000,'cash','R-001','First Term','2025/2026','Mrs Bursar', current_date)`, [a]);
await q(`insert into fee_payments(student_id,amount_paid,method,reference,term,session,received_by_name,payment_date)
  values ($1, 25000,'transfer','','First Term','2025/2026','Mr Clerk', current_date)`, [b]);
const before = await rpc('sc_fee_cash_reconciliation',`current_date - 300, current_date`);
const bt = before.totals||{};
const cr = await rpc('sc_fee_cash_reconciliation',`current_date - 300, current_date`);
ok(cr.ok===true,'cash reconciliation returns ok',cr);
const ct=cr.totals||{};
/* the two new receipts are +15,000 cash and +25,000 bank over what was there */
ok(Number(ct.cash) - 0 >= 15000,'cash is totalled separately from bank',ct.cash);
ok(Number(ct.bank) >= 25000,'bank is totalled separately from cash',ct.bank);
ok(Number(ct.total) === Number(ct.cash) + Number(ct.bank),'total is exactly cash + bank',[ct.cash,ct.bank,ct.total]);
ok(Number(ct.no_reference) >= 1,'receipts with no reference ARE flagged',ct.no_reference);
ok(Array.isArray(ct.by_collector)&&ct.by_collector.some(c=>c.collector==='Mrs Bursar'),'each collector is broken out',ct.by_collector);
ok(/Count the physical cash/.test(cr.how_to_use||''),'the result tells the bursar how to use it');
const cr2 = await rpc('sc_fee_cash_reconciliation',`current_date, current_date - 30`);
ok(cr2.ok===false,'a backwards date range is refused',cr2);

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail?1:0);
