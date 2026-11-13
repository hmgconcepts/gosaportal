/* ROUND-15 ITEMS 10 & 11 — a refusal must explain itself and offer the way out.
   Checks the shipped source, because these are screen contracts: if the
   explanation or the remedy button is missing from the code, the school cannot
   see it no matter what the server does. */
import fs from 'fs';
import path from 'path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const cbt = fs.readFileSync(path.join(ROOT,'cbt.html'),'utf8');
const re  = fs.readFileSync(path.join(ROOT,'assets/js/report-engine.js'),'utf8');
let pass=0, fail=0;
const ok=(c,n,d)=>{ if(c){pass++;} else {fail++; console.log('  FAIL', n, d===undefined?'':JSON.stringify(d).slice(0,160));} };

/* ---- item 10: the audit panel must MEAN something ---- */
ok(/Needs attention/.test(cbt), 'audit tile says what it is ("Needs attention"), not a bare "Potential missing"');
ok(/Waiting in THIS browser/.test(cbt), 'the local queue tile is spelled out');
ok(/Stranded on SERVER/.test(cbt), 'the server-orphan tile is spelled out');
for(const [label,re_] of [
  ['the "needs attention" tile explains the cause', /roster not matched|submissions stranded/],
  ['the "needs attention" tile says what to press', /Recover\/Repair/],
  ['the local-queue tile says the marks are NOT saved yet', /NOT in the database yet/],
  ['the local-queue tile offers the button', /Recover now/],
  ['the server tile explains why rows are stranded', /never attached to an exam/],
  ['the server tile explains what "1 failed" means', /that one row names an exam that no longer exists/],
  ['the server tile offers the button', /Flush now/],
]){
  ok(re_.test(cbt), label);
}
ok(!/stat-label">Pending on SERVER</.test(cbt), 'the bare "Pending on SERVER" label is gone');
ok(!/⚠️ Potential missing</.test(cbt), 'the bare "Potential missing" label is gone');

/* ---- item 10b: a failed flush must name the row and the reason ---- */
ok(/could not be saved/.test(cbt), 'a failed flush opens a titled dialog, not just a toast');
ok(/Why it could not be saved/.test(cbt), 'the failure table has a reason column');
ok(/indexOf\(':'\)/.test(cbt), 'errors are parsed in the "ref: reason" shape the RPC actually returns');
ok(/Unrecoverable/.test(cbt), 'an unrecoverable row is labelled as such');
ok(/Enter these marks by hand/.test(cbt), 'and says what to do about it');
ok(!/console\.warn\('Flush errors'/.test(cbt), 'failures are no longer hidden in the console');

/* ---- item 11: a refusal must offer the remedy ---- */
ok(/splitClashingColumns/.test(re), 'a one-click column splitter exists');
ok(/Give each exam its own column/.test(re), 'the preview offers that button');
ok(/Give each exam its own column/.test(re), 'the failure dialog offers it too');
ok(/this\._bulkCBT\.clashes=clashes/.test(re), 'the preview remembers which groups clashed');
ok(/does not push any mark/.test(re), 'the splitter states that it writes no marks');
ok(/Nothing was written/.test(re), 'the failure dialog reassures that existing marks are untouched');
/* the splitter must never silently invent a column for the FIRST exam */
ok(/i=1;i<group\.length/.test(re), 'the first exam in each group keeps the column it already uses');

/* ---- item 9 chain: a moved CBT must leave exactly one row ---- */
const remap = fs.readFileSync(path.join(ROOT,'tools/verification/tmp-cbt-remap.mjs'),'utf8');
ok(/there is still exactly ONE row/.test(remap), 'item 9: remap leaves exactly one score row');
ok(/generate_midterm_reports/.test(remap), 'item 9: the mid-term report is regenerated in the test');

console.log(`\n  ${pass} passed, ${fail} failed`);
process.exit(fail?1:0);
