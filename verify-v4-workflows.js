#!/usr/bin/env node
/* SchoolConnect V4 workflow verifier — no network, no AI API. */
const fs = require('fs');
const path = require('path');
let pass = 0, fail = 0;
function read(p){ return fs.existsSync(p) ? fs.readFileSync(p,'utf8') : ''; }
function ok(name, cond){ if(cond){ console.log('OK  - '+name); pass++; } else { console.error('FAIL- '+name); fail++; } }
const app = read('assets/js/app.js');
const crud = read('assets/js/crud.js');
const cbtEngine = read('assets/js/cbt-engine.js');
const cbtExam = read('assets/templates/pages/cbt-exam.html') || read('cbt-exam.html');
const cbtSchema = read('database/cbt-schema.sql');
const reportPage = read('assets/templates/pages/report-cards.html') || read('report-cards.html');
const reportSchema = read('database/reportcard-schema.sql');
const generator = read('assets/js/generator.js') || read('generator.js');
const messages = read('assets/templates/pages/messages.html') || read('messages.html');
const idcards = read('assets/templates/pages/idcards.html') || read('idcards.html');

ok('global dropdown dedupe installed', /installSelectDedupe\(\)/.test(app) && /MutationObserver/.test(app) && /dedupeSelectOptions/.test(app));
ok('CRUD dropdown dedupe by visible label', /dedupeOptions\(options\)/.test(crud) && /label=String\(o\.label/.test(crud));
ok('multi-subject CBT has subject tab helpers', /Exam\.sections=function/.test(cbtExam) && /Exam\.goSubject=function/.test(cbtExam) && /Exam\.sectionStats=function/.test(cbtExam));
ok('multi-subject CBT filters palette to current subject', /question map/.test(cbtExam) && /!==current\) return/.test(cbtExam));
ok('multi-subject CBT tab names are encoded safely', /encodeURIComponent\(sec\)/.test(cbtExam) && /decodeURIComponent/.test(cbtExam));
ok('CBT preserves original question index', /_orig_index/.test(cbtEngine) && /_orig_index/.test(cbtExam));
ok('CBT SQL has high-concurrency indexes', /cbt_exams_code_open_idx/.test(cbtSchema) && /cbt_results_exam_student_created_idx/.test(cbtSchema));
ok('CBT SQL grades submitted original indexes', /qi :=/.test(cbtSchema) && /e\.csv_data -> qi/.test(cbtSchema));
ok('birthdays import admin/staff/parent/student', /adminRes/.test(crud) && /staffRes/.test(crud) && /parentRes/.test(crud) && /students/.test(crud));
ok('digital library teacher delete preserved', /digital_library:\['staff','teacher'\]/.test(crud) && /sharedTables = \['library', 'digital_library'/.test(crud));
ok('report cards family-safe read-only page', /family-safe Report Cards/.test(reportPage) && /Access denied: you can only view your linked children/.test(reportPage));
ok('report score RLS family scoping present', /rs_select_family/.test(reportSchema) && /is_parent_of\(auth\.uid\(\), s\.id\)/.test(reportSchema));
ok('messaging select-all and recipient_id delivery present', /Select all/.test(messages) && /recipient_id/.test(messages) && /Deliver In-App/.test(messages));
ok('ID card preview/print fallback preserved', /fallbackHtml/.test(idcards) && /printHtml/.test(idcards) && /Sample Student/.test(idcards));
ok('traditional + modern/SaaS generator paths present', /generateAsync/.test(generator) && /addModernScaffold/.test(generator) && /tenant-schema\.sql/.test(generator));
ok('no AI API required', !/OPENAI_API_KEY|ANTHROPIC_API_KEY|api\.openai\.com|generativelanguage\.googleapis\.com/.test(generator+app+crud+cbtExam));

console.log(`\nSchoolConnect V4 workflow verification: ${pass} passed, ${fail} failed.`);
process.exit(fail ? 1 : 0);
