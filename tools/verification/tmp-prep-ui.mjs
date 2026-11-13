/* ROUND-16 ITEM 1/2 — the Prep Exam page, proven in a real browser.
   The critical claim is negative: nothing on this page may reach a report card,
   and the page must SAY so everywhere a person could be misled. */
import { chromium } from 'playwright-core';
import http from 'node:http';
import { readFileSync } from 'node:fs';
const HERE = new URL('.', import.meta.url).pathname;
let pass=0, fail=0;
const ok=(c,n,d)=>{ if(c) pass++; else { fail++; console.log('  FAIL',n,d===undefined?'':JSON.stringify(d).slice(0,260)); } };

const ROWS=[
 {student_id:'s1',student_name:'Ada Rehearsal',student_id_ref:'SC/101',class:'JSS 1',term:'First Term',session:'2025/2026',
  total:90,max_total:100,average:90,percentage:90,position:1,has_scores:true,published:true,grade:'A',
  readiness_band:'ready',readiness_note:'On this evidence the learner is ready for the school examination.',
  score_details:[{subject:'Mathematics',assessment:'Prep',score:18,max_mark:20}]},
 {student_id:'s2',student_name:'Bola Rehearsal',student_id_ref:'SC/102',class:'JSS 1',term:'First Term',session:'2025/2026',
  total:55,max_total:100,average:55,percentage:55,position:2,has_scores:true,published:true,grade:'D',
  readiness_band:'needs_work',readiness_note:'Not yet ready. A focused revision plan is needed before the examination.',
  score_details:[{subject:'Mathematics',assessment:'Prep',score:11,max_mark:20}]},
 {student_id:'s3',student_name:'Chidi Absent',student_id_ref:'SC/103',class:'JSS 1',term:'First Term',session:'2025/2026',
  total:0,max_total:0,average:0,percentage:0,position:null,has_scores:false,published:false,grade:'',
  readiness_band:'not_sat',readiness_note:'This learner did not sit the rehearsal.',score_details:[]}
];

const html = readFileSync(HERE+'../../prep-exam-reports.html','utf8')
 .replace(/<script[^>]*src=["'][^"']*config\.js["'][^>]*><\/script>/i,'')
 .replace(/<script[^>]*src=["'][^"']*supabase/i,'')
 .replace('</head>', `<script>
   window.SCHOOL={name:'Test College',currency:'₦',logoExt:'svg'};
   window.toast=function(){};
   var ROWS=${JSON.stringify(ROWS)};
   window.sb={
     from:function(tbl){ return {select:function(){ return {
        eq:function(){ return { eq:function(){ return { eq:function(){ return { order:function(){ return { range:async function(){ return {data:ROWS,error:null}; } }; } }; } }; } };
     } }; } }; },
     rpc:async function(fn,args){
       if(fn==='sc_report_policy') return {data:{ok:true,show_position:true,position_label:'Position',show_grade:true,show_subject_position:true,show_remarks:true},error:null};
       if(fn==='sc_prep_generate') return {data:{ok:true,learners:3,prep_marks:2,note:'ok'},error:null};
       if(fn==='sc_purposes') return {data:[{slug:'prep',label:'Prep Exam (rehearsal)',emoji:'🧪',report_eligible:false,feeds_report:'prep'}],error:null};
       return {data:{ok:true,rows:[]},error:null};
     },
     from2:null
   };
   window.sb.from=function(tbl){ return {select:function(){ return {
      eq:function(){ return { eq:function(){ return { eq:function(){ return { order:function(){ return { range:async function(){ return {data:ROWS,error:null}; } }; } }; } }; } };
   } }; } }; };
 </script></head>`);

const srv=http.createServer((rq,rs)=>{
  const u=rq.url.split('?')[0].replace(/^\/+/,'');
  if(u===''||u.endsWith('.html')){ rs.writeHead(200,{'content-type':'text/html'}); return rs.end(html); }
  if(u.endsWith('.js')){ try{ rs.writeHead(200,{'content-type':'application/javascript'}); return rs.end(readFileSync(HERE+'../../'+u,'utf8')); }catch(e){ rs.writeHead(200,{'content-type':'application/javascript'}); return rs.end(''); } }
  if(u.endsWith('.css')){ rs.writeHead(200,{'content-type':'text/css'}); return rs.end(''); }
  rs.writeHead(204); rs.end();
});
await new Promise(r=>srv.listen(8172,'127.0.0.1',r));
const br=await chromium.launch({args:['--no-sandbox']});
const pg=await br.newPage();
const errs=[]; pg.on('pageerror',e=>errs.push(e.message));
await pg.goto('http://127.0.0.1:8172/prep-exam-reports.html',{waitUntil:'domcontentloaded'});

/* the page must announce what it is */
const body=await pg.textContent('body');
ok(/Prep Exam Reports/.test(body),'the page is titled Prep Exam Reports');
ok(/a rehearsal, not the report card/i.test(body),'a permanent banner says it is a rehearsal');
ok(/can be pushed to, or printed on, a report card/i.test(body),'the banner states the block in words a teacher understands');

/* it must be impossible to mistake for the real thing */
ok(await pg.$('#pr-readiness-card')!==null,'the readiness summary panel exists');
ok(await pg.$('#pr-list')!==null,'there is a sheet list container');

/* drive the preview */
await pg.evaluate(()=>{ const c=document.getElementById('pr-class'); if(c){const o=document.createElement('option');o.value='JSS 1';o.text='JSS 1';c.appendChild(o);c.value='JSS 1';}
  const t=document.getElementById('pr-term'); if(t){const o=document.createElement('option');o.value='First Term';o.text='First Term';t.appendChild(o);t.value='First Term';}
  const s=document.getElementById('pr-session'); if(s){const o=document.createElement('option');o.value='2025/2026';o.text='2025/2026';s.appendChild(o);s.value='2025/2026';} });
await pg.evaluate(()=>PR.preview());
await pg.waitForFunction(()=>document.getElementById('pr-list').textContent.length>40,null,{timeout:8000});

const listTxt=await pg.textContent('#pr-list');
ok(/Ada Rehearsal/.test(listTxt),'the learner list renders',listTxt.slice(0,150));
ok(/prep sheet\(s\) generated|prep sheet/.test(listTxt),'the summary speaks of prep sheets, not report cards',listTxt.slice(0,200));

/* readiness groups */
const rdy=await pg.textContent('#pr-readiness');
ok(/Ready/.test(rdy),'a ready learner is grouped',rdy.slice(0,200));
ok(/Needs work/.test(rdy),'a learner needing work is grouped',rdy.slice(0,200));
ok(/did not sit the rehearsal/.test(rdy),'an absent learner is called out as unjudgeable, not as failing',rdy.slice(0,400));
ok(/Ada Rehearsal/.test(rdy),'the ready group names the learner');
ok(/not an at-risk learner/.test(rdy),'absence is explicitly distinguished from risk',rdy.slice(-300));

/* the printed sheet carries the warning */
const sheet=await pg.evaluate(()=>PR.sheetBody(PR._lastRows[0]));
ok(/PREP EXAM REHEARSAL/.test(sheet),'the printed sheet is stamped PREP EXAM REHEARSAL');
ok(/NOT the report card/i.test(sheet),'the sheet says in words that it is not the report card');
ok(/Readiness:/.test(sheet),'the sheet prints the readiness verdict',sheet.match(/Readiness:[^<]*/));
ok(/Ada Rehearsal/.test(sheet),'the sheet prints the learner name');

/* an absent learner's sheet must not read as zero */
const sheet3=await pg.evaluate(()=>PR.sheetBody(PR._lastRows[2]));
ok(/No prep marks are recorded/.test(sheet3),'an unscored learner gets an honest notice',sheet3.slice(0,300));
ok(/does not treat missing marks as zero/.test(sheet3),'the sheet states that absence is not zero',sheet3.slice(0,300));
ok(/not_sat|NOT SAT/i.test(sheet3),'an absent learner is marked not sat, not failed',sheet3.match(/Readiness:[^<]*/));

const realErrs=errs.filter(e=>!/PWAInstall|Notifications|supabase|Failed to load resource/i.test(e));
ok(realErrs.length===0,'the page threw no JavaScript errors',errs);
console.log(`\n  ${pass} passed, ${fail} failed\n`);
await br.close(); srv.close(); process.exit(fail?1:0);
