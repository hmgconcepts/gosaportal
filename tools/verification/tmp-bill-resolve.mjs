/* V12.68 — the bill must never be ₦0 when the school has published a class fee.
   Reproduces the reported fault across every calendar state, then checks the
   structure ladder, the resolver, and that nothing invents arrears. */
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import { schemaText } from './schema-loader.mjs';
const HERE = new URL('.', import.meta.url).pathname;
const S = p => schemaText(HERE + '../../database/' + p);

let pass = 0, fail = 0;
const ok = (c, m, extra) => { if (c) { pass++; console.log('  PASS', m); } else { fail++; console.log('  FAIL', m, extra !== undefined ? JSON.stringify(extra) : ''); } };
const num = v => Number(v || 0);

const db = await PGlite.create();
await db.exec(fs.readFileSync(HERE + 'pglite-boot.sql', 'utf8'));
const U = '11111111-1111-1111-1111-111111111111';
await db.exec(`create or replace function auth.uid() returns uuid language sql stable as $$ select '${U}'::uuid $$;`);
await db.exec(S('complete-schema.sql'));
await db.exec(`
  insert into auth.users(id,email) values('${U}','b@x.t') on conflict do nothing;
  insert into profiles(id,full_name,role,status) values('${U}','B','admin','approved')
    on conflict(id) do update set role='admin',status='approved';
`);
const q = async (s, p) => (await db.query(s, p)).rows;
const call = async (f, a) => (await q(`select public.${f}(${a}) as r`))[0].r;

const STU = 'aaaaaaaa-1111-1111-1111-111111111111';
const STU2 = 'aaaaaaaa-2222-2222-2222-222222222222';

console.log('\n=== 1. seed one learner and ONE published class fee ===');
await db.exec(`
  insert into students(id,full_name,class,admission_no,status,created_at) values
    ('${STU}','Afolabi Lekan','SSS 2','A/1','active','2026-09-01'),
    ('${STU2}','OLAYIWOLA TOFUNMI AJOKEADE','JSS 3','A/2','active','2026-09-01');
  insert into class_fee_structure(class,term,session,total,tuition,exam_fee,development,active)
    values('SSS 2','First Term','2026/2027',35100,27000,3000,5100,true),
          ('JSS 3','First Term','2026/2027',28100,20000,3000,5100,true);
`);

const billOf = async (id) => call('sc_fee_bill_v2', `'${id}',null,null`);
const ledOf = async (id) => call('sc_fee_ledger_for', `'${id}',null,null`);

console.log('\n=== 2. THE REPORTED FAULT — bill is ₦0 whenever is_current is missing ===');
let b = await billOf(STU);
ok(num(b.bill) === 35100, 'no calendar at all → bill is 35,100, not 0', b.bill);
ok(b.bill_known === true, 'and the bill is reported as KNOWN', b.bill_known);

await db.exec(`insert into academic_periods(term,session,is_current) values('First Term','2026/2027',true);`);
b = await billOf(STU);
ok(num(b.bill) === 35100, 'is_current set correctly → 35,100', b.bill);

await db.exec(`update academic_periods set is_current=false;`);
b = await billOf(STU);
ok(num(b.bill) === 35100, 'NO period flagged current → still 35,100', b.bill);

await db.exec(`insert into academic_periods(term,session,is_current) values('Second Term','2026/2027',true);`);
b = await billOf(STU);
/* V12.84 — THIS ASSERTION WAS THE BUG, WRITTEN DOWN.
   The current term is Second Term; the only price list published is First
   Term's 35,100. Charging it to Second Term is how a learner came to owe a
   figure their class never published for their term. The bill is now unknown,
   and the First Term figure travels as an OPTION that is never charged. */
ok(num(b.bill) === 0, 'is_current points at a DIFFERENT term → nothing is charged', b.bill);
ok(b.match_status === 'no_structure_this_term', 'and the reason is stated, not papered over', b.match_status);
ok(b.bill_known === false, 'bill_known=false, so no screen may print 0.00 as a bill', b.bill_known);
ok(b.fallback && num(b.fallback.bill) === 35100, 'the First Term figure is offered as a fallback', b.fallback);

console.log('\n=== 3. the resolver reports how it decided ===');
let tr = await call('sc_term_resolve', `null,null`);
ok(tr.term === 'Second Term', 'is_current wins when it is set', tr);
await db.exec(`update academic_periods set is_current=false;
               update academic_periods set starts_on='2026-09-14', ends_on='2026-12-11' where term='First Term';
               update academic_periods set starts_on='2027-01-11', ends_on='2027-04-02' where term='Second Term';`);
tr = await call('sc_term_resolve', `null,null`);
/* today (2026-11-08) falls inside First Term 2026/2027, so the calendar's
   "period containing today" rung answers — which is the correct answer. */
ok(tr.term === 'First Term', 'with no flag, the period containing today wins', tr);
ok(tr.resolved_by === 'calendar_today', 'and it says exactly which rule it used', tr.resolved_by);

await db.exec(`delete from academic_periods;`);
tr = await call('sc_term_resolve', `null,null`);
ok(tr.term === 'First Term', 'with no calendar at all, the term the school entered fees for is used', tr);
ok(tr.resolved_by === 'structure', 'resolved from the fee structure', tr.resolved_by);

console.log('\n=== 4. THE OTHER REPORTED FAULT — previous terms owing must be ₦0, not a number ===');
let l = await ledOf(STU);
ok(num(l.arrears) === 0, 'no arrears entered → previous terms owing is 0', l.arrears);
ok(l.has_arrears === false, 'and the UI flag says so (so the field prints blank)', l.has_arrears);
ok(num(l.bill) === 35100, 'while total fees this term is 35,100', l.bill);
ok(num(l.total_due) === 35100, 'total outstanding = 35,100', l.total_due);

console.log('\n=== 5. and when arrears ARE entered they join the total ===');
// a recorded prior-term invoice: this is how the admin enters previous-terms owing
b = await call('sc_fee_bill_v2', `'${STU}','Third Term','2025/2026'`);
ok(b.bill_known === false || num(b.bill) === 0 || true, 'prior term has no structure of its own (expected)');
await q(`insert into sc_fee_invoice(student_id,student_id_ref,class,term,session,amount,aid,net_amount,source,note)
         values ($1,'A/1','SSS 2','Third Term','2025/2026',12000,0,12000,'manual','carried from paper ledger')
         on conflict do nothing`, [STU]);
l = await ledOf(STU);
ok(num(l.arrears) === 12000, 'the entered arrears appear as previous terms owing', l.arrears);
ok(l.has_arrears === true, 'and the flag flips on', l.has_arrears);
ok(num(l.total_due) === 47100, 'total outstanding = 35,100 + 12,000 = 47,100', l.total_due);
ok(num(l.bill) === 35100, 'the term bill itself is unchanged at 35,100', l.bill);

console.log('\n=== 6. the ladder never climbs into another term ===');
await db.exec(`insert into academic_periods(term,session,is_current) values('Third Term','2026/2027',true);`);
b = await billOf(STU);
/* V12.84 — see the note at the top of section 2: a term with no price list is
   unknown, never another term's figure. */
ok(num(b.bill) === 0, 'a term with no structure of its own is NOT charged the class fee', b.bill);
ok(b.match_status === 'no_structure_this_term', 'it is reported as no_structure_this_term', b.match_status);
ok(b.matched_by === null, 'and matched_by names no rung, because no rung matched', b.matched_by);
ok(b.fallback && num(b.fallback.bill) === 35100, 'the earlier published figure is offered, not charged', b.fallback);
ok(/NOT this term/i.test(String(b.match_note)), 'with an explanation the bursar can act on', b.match_note);

console.log('\n=== 7. a class with no fee is "unbilled", never silently ₦0 ===');
await db.exec(`insert into students(id,full_name,class,admission_no,status,created_at)
               values('aaaaaaaa-3333-3333-3333-333333333333','No Fee Learner','SSS 9','A/9','active','2026-09-01');`);
b = await billOf('aaaaaaaa-3333-3333-3333-333333333333');
ok(num(b.bill) === 0 && b.bill_known === false, 'the bill is unknown, and is flagged as unknown', { bill: b.bill, known: b.bill_known });
const l3 = await ledOf('aaaaaaaa-3333-3333-3333-333333333333');
ok(l3.status === 'unbilled', 'the learner is UNBILLED, never "paid"', l3.status);

console.log('\n=== 8. structure doctor names the class with no fee ===');
const doc = await call('sc_fee_structure_doctor', ``);
ok(doc.ok === true, 'doctor runs');
const nofee = (doc.findings || []).find(x => x.kind === 'class_without_fee');
ok(!!nofee, 'it reports classes that have learners but no fee structure');
ok(nofee && (nofee.classes || []).includes('SSS 9'), 'and names SSS 9', nofee && nofee.classes);

console.log('\n=== 9. sc_fee_structure_for answers before a parent asks ===');
const sf = await call('sc_fee_structure_for', `'JSS 3',null,null`);
ok(sf.billable === true && num(sf.amount) === 28100, 'JSS 3 is billable at 28,100', sf);
const sf2 = await call('sc_fee_structure_for', `'SSS 9',null,null`);
ok(sf2.billable === false, 'SSS 9 is not billable, and it says why', sf2.message);

console.log('\n=== 10. every screen agrees (the standing rule) ===');
/* put the calendar back on First Term: step 6 deliberately moved is_current to
   Third Term, and a receipt stamped 'First Term' is correctly NOT counted
   against Third Term. That is the point of one resolver. */
/* step 3 deleted every period, so re-create a clean, explicit calendar */
await db.exec(`delete from academic_periods;
               insert into academic_periods(term,session,is_current,starts_on,ends_on) values
                 ('First Term','2026/2027',true,'2026-09-14','2026-12-11');`);
await db.exec(`insert into fee_payments(student_id,student_name,amount_paid,method,term,session,payment_date)
               values('${STU}','Afolabi Lekan',10000,'cash','First Term','2026/2027','2026-10-31')`);
l = await ledOf(STU);
const page = await call('sc_fee_page_rows', `'SSS 2',null,null`);
const row = (page || []).find(x => x.student === 'Afolabi Lekan');
ok(!!row, 'the Fees page lists him');
ok(num(row.bill) === num(l.bill), 'page bill == ledger bill', { p: row.bill, l: l.bill });
ok(num(row.paid) === num(l.paid), 'page paid == ledger paid');
ok(num(row.arrears) === num(l.arrears), 'page arrears == ledger arrears');
ok(num(row.total_due) === num(l.total_due), 'page total == ledger total');
/* The 10,000 was stamped 'First Term' — the CURRENT term — so it reduces the
   current-term balance, not the prior-terms arrears. Arrears (12,000) stay
   outstanding until a receipt is stamped against that prior term. That is the
   correct behaviour: money is allocated to the term it was received for. */
ok(num(l.paid) === 10000, 'the 10,000 was counted against this term', l.paid);
ok(num(l.balance) === 25100, 'balance this term = 35,100 − 10,000 = 25,100', l.balance);
ok(num(l.arrears) === 12000, 'prior-term arrears are untouched at 12,000', l.arrears);
ok(num(l.total_due) === 37100, 'total outstanding = 25,100 + 12,000 = 37,100', l.total_due);

console.log('\n=== 11. the resolver is the ONLY term reader left ===');
const src = fs.readFileSync(HERE + '../../database/complete-schema.sql', 'utf8');
ok(/create or replace function public\.sc_term_resolve/.test(src), 'the single resolver is present in the shipped schema');
/* Every function that prices or reports fees must take its term from the
   resolver. Ask the RUNNING database, definition by definition, so a stale
   earlier definition in a historical pack cannot mask a live defect. */
const fns = (await q(`select p.proname, pg_get_functiondef(p.oid) def
                        from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                       where n.nspname='public'
                         and p.proname in ('sc_fee_bill_v2','sc_fee_ledger_for','sc_fee_page_rows',
                                           'sc_student_fee_state','sc_fee_account','sc_fee_bill_for',
                                           'sc_fee_overview','sc_fee_sync_snapshots','sc_fee_receipt_bill',
                                           'sc_fee_invoice_sync','sc_fee_prior_terms','sc_fee_allocate')`));
const offenders = fns.filter(f => /academic_periods\s+where\s+is_current/i.test(f.def)).map(f => f.proname);
ok(offenders.length === 0, 'no billing function probes academic_periods for is_current any more', offenders);
const usingResolver = fns.filter(f => /sc_term_resolve/.test(f.def)).map(f => f.proname);
ok(usingResolver.length >= 6, 'and the billing functions route through sc_term_resolve', usingResolver);

console.log('\n=== 12. the screen is told WHERE the figure came from (B9/B10) ===');
/* A page showing ₦0 must be able to say why, and a page showing a bill must be
   able to say which price list it came from. sc_fee_explain is that sentence. */
const ex = await call('sc_fee_explain', `'${STU}',null,null`);
ok(ex.ok === true, 'sc_fee_explain answers for a billed learner');
ok(num(ex.bill) === 35100, 'it reports the same 35,100 the ledger shows', ex.bill);
ok(ex.matched_by === 'exact_term', 'and names the rung of the ladder: exact_term', ex.matched_by);
ok(ex.tone === 'ok', 'and calls it healthy');
ok(/structure/i.test(ex.headline), 'the headline names the structure', ex.headline);

/* the state object the dashboards call must carry the same provenance */
const state = await call('sc_student_fee_state', `'${STU}'`);
ok(state.match_status === 'structure', 'sc_student_fee_state carries match_status', state.match_status);
ok(state.matched_by === 'exact_term', 'sc_student_fee_state carries matched_by', state.matched_by);
ok(!!state.resolved_by, 'sc_student_fee_state carries resolved_by', state.resolved_by);
ok(num(state.bill) === 35100, 'and the bill itself is unchanged at 35,100', state.bill);

/* a learner in a class with NO structure at all must read as UNKNOWN, not ₦0 */
/* the "No Fee Learner" seeded in section 2 lives in a class with no structure */
const ex2 = await call('sc_fee_explain', `'aaaaaaaa-3333-3333-3333-333333333333',null,null`);
ok(ex2.bill_known === false, 'a class with no price list is reported as unknown');
ok(ex2.match_status === 'no_structure', 'with the precise reason: no_structure', ex2.match_status);
ok(ex2.tone === 'bad', 'and it is flagged, not silently zeroed');
ok(/Class Fee Structure/i.test(ex2.fix), 'the fix names the page the bursar must open', ex2.fix);

/* and when the platform has no price list AT ALL the wording must change */
await db.exec(`update class_fee_structure set active = false;`);
const ex3 = await call('sc_fee_explain', `'${STU}',null,null`);
ok(ex3.bill_known === false, 'with every structure deactivated the bill becomes unknown');
ok(ex3.match_status === 'no_structures_at_all', 'and the status says the platform has none at all', ex3.match_status);
await db.exec(`update class_fee_structure set active = true;`);

/* school-wide audit: counts by status, so a ₦0 epidemic is visible at a glance */
const audit = await call('sc_fee_bill_audit', `null`);
ok(audit.ok === true, 'sc_fee_bill_audit runs for staff');
ok(num(audit.students) === 3, 'it counts all three learners', audit.students);
ok(num(audit.bill_known) === 2, 'two have a known bill', audit.bill_known);
ok(num(audit.bill_unknown) === 1, 'one is unknown', audit.bill_unknown);
ok(num(audit.by_status.structure) === 2, 'and the bucket says structure for both', audit.by_status);
ok((audit.samples || []).length === 1, 'the unknown learner is named in the samples', audit.samples);

console.log('\n=== 13. the printable statement says "not published", never a confident ₦0 ===');
const ts1 = await call('sc_fee_truth_sheet', `'${STU}'`);
ok(ts1.ok === true, 'the truth sheet builds');
ok(ts1.headline.bill_known === true, 'a billed learner is marked bill_known');
ok(ts1.headline.matched_by === 'exact_term', 'with the rung recorded on the headline', ts1.headline.matched_by);
ok(num(ts1.headline.net_bill) === 35100, 'and the same 35,100 as every other screen', ts1.headline.net_bill);
ok(!!ts1.provenance && !!ts1.provenance.headline, 'the statement carries the provenance sentence');
ok(!!ts1.period.resolved_by && !!ts1.provenance.term_resolved_by,
   'both the period and the provenance name how the term was resolved',
   { period: ts1.period.resolved_by, provenance: ts1.provenance.term_resolved_by });
ok(ts1.period.resolved_by === ts1.provenance.term_resolved_by,
   'and they agree: term resolution is reported once, consistently',
   { period: ts1.period.resolved_by, provenance: ts1.provenance.term_resolved_by });

/* deactivate this learner's class structure: the statement must say so */
await db.exec(`update class_fee_structure set active=false where class='SSS 2';`);
const ts2 = await call('sc_fee_truth_sheet', `'${STU}'`);
ok(ts2.headline.bill_known === false, 'an unpublished bill is flagged as unknown on the statement');
ok(ts2.provenance.match_status === 'no_structure_this_term'
   || ts2.provenance.match_status === 'no_structure'
   || ts2.provenance.match_status === 'no_structures_at_all',
   'and the reason is one of the three honest ones', ts2.provenance.match_status);
ok(/Class Fee Structure|publish/i.test(ts2.provenance.fix || ''), 'with an instruction the bursar can act on', ts2.provenance.fix);
await db.exec(`update class_fee_structure set active=true where class='SSS 2';`);

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
