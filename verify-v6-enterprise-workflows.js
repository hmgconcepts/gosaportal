#!/usr/bin/env node
const fs=require('fs');
const read=p=>fs.existsSync(p)?fs.readFileSync(p,'utf8'):'';
let pass=0,fail=0;function ok(n,c){console.log((c?'OK  - ':'FAIL- ')+n); c?pass++:fail++;}
const crud=read('assets/js/crud.js');
const report=read('assets/js/report-engine.js');
const entrance=read('assets/templates/pages/entrance.html')||read('entrance.html');
const sampleReceipt=read('samples/sample-e-receipt.html');
const sampleReport=read('samples/sample-report-card.html');
const sampleClass=read('samples/sample-class-broadsheet.html');
const sampleSubject=read('samples/sample-subject-broadsheet.html');
const schema=read('database/schema.sql')+read('database/update-v11-schema.sql');
const notify=read('assets/js/notifications.js');

ok('entrance page has examination officer signature fields', /en-officer-name/.test(entrance)&&/en-officer-signature/.test(entrance)&&/sc-exam-officer-signature/.test(entrance));
ok('entrance outputs use examination officer signature/name', /EN\.officer\(\)\.sig/.test(entrance)&&/EN\.officer\(\)\.name/.test(entrance));
ok('e-receipt print uses sample receipt CSS/classes', /class="receipt"/.test(crud)&&/class="rh"/.test(crud)&&/class="paid"/.test(crud)&&/OFFICIAL E-RECEIPT/.test(crud));
ok('e-receipt includes sample note wording', /SAMPLE e-receipt \(Fees/.test(crud));
ok('fee balance auto-computed in JS and persisted', /Math\.max\(0,.*f\.balance/.test(crud)&&/update\(\{\s*balance:bal\s*\}\)/.test(crud));
ok('fee balance DB trigger present', /compute_fee_payment_balance/.test(schema)&&/trg_compute_fee_payment_balance/.test(schema));
ok('report engine uses sample report class names', /sample-report/.test(report)&&/TERMINAL REPORT SHEET/.test(report)&&/AFFECTIVE DOMAIN/.test(report));
ok('class broadsheet uses sample landscape classes', /class-sheet/.test(report)&&/CLASS BROADSHEET/.test(report)&&/class="rot"/.test(report));
ok('subject broadsheet uses sample stats/signature layout', /subject-sheet/.test(report)&&/SUBJECT BROADSHEET/.test(report)&&/class="stat"/.test(report));
ok('sample files are bundled/present', sampleReceipt.includes('OFFICIAL E-RECEIPT')&&sampleReport.includes('TERMINAL REPORT SHEET')&&sampleClass.includes('CLASS BROADSHEET')&&sampleSubject.includes('SUBJECT BROADSHEET'));
ok('information drop notification map includes family/staff/student modules', /digital_library/.test(crud)&&/report_cards/.test(crud)&&/attendance/.test(crud)&&/Fee\/Payment Update/.test(crud));
ok('phone notification pathway remains PWA push capable', /subscribeToPush/.test(notify)&&/push_subscriptions/.test(notify));
console.log(`\nSchoolConnect V6 enterprise verification: ${pass} passed, ${fail} failed.`);process.exit(fail?1:0);
