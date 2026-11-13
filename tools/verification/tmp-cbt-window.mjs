/* ROUND-16 ITEM 4 — the CBT link must open and close exactly when the teacher
   said, and a learner must be told plainly why they cannot sit it yet. */
import { chromium } from 'playwright-core';
import http from 'node:http';
import { readFileSync } from 'node:fs';
const HERE=new URL('.',import.meta.url).pathname;
let pass=0,fail=0;
const ok=(c,n,d)=>{if(c)pass++;else{fail++;console.log('  FAIL',n,d===undefined?'':JSON.stringify(d).slice(0,300));}};

function page(state){
  return readFileSync(HERE+'../../cbt-exam.html','utf8')
   .replace(/<script[^>]*src=["'][^"']*config\.js["'][^>]*><\/script>/i,'')
   .replace(/<script[^>]*src=["'][^"']*supabase/i,'')
   .replace('</head>',`<script>
     window.STATE=${JSON.stringify(state)};
     window.SCHOOL={name:'Test College'};
     window.toast=function(){};
     window.sb={rpc:async function(){ return {data:window.STATE,error:null}; }};
   </script></head>`);
}
const future=new Date(Date.now()+90*60000).toISOString();
const past=new Date(Date.now()-60*60000).toISOString();

const cases=[
 {name:'not yet open', state:{ok:false,wait:true,error:'not_started',message:'This exam has not started yet.',start_at:future,title:'Prep Maths',code:'PREP1'}},
 {name:'already closed', state:{ok:false,closed:true,error:'closed',message:'This exam closing time has passed.',close_at:past,title:'Prep Maths',code:'PREP1'}}
];

const srv=http.createServer((rq,rs)=>{
  const u=rq.url.split('?')[0].replace(/^\/+/,'');
  const m=/st=(\d)/.exec(rq.url);
  if(u===''||u.endsWith('.html')){ rs.writeHead(200,{'content-type':'text/html'}); return rs.end(page(cases[Number(m?m[1]:0)].state)); }
  if(u.endsWith('.js')){ try{ rs.writeHead(200,{'content-type':'application/javascript'}); return rs.end(readFileSync(HERE+'../../'+u,'utf8')); }catch(e){ rs.writeHead(200,{'content-type':'application/javascript'}); return rs.end(''); } }
  if(u.endsWith('.css')){ rs.writeHead(200,{'content-type':'text/css'}); return rs.end(''); }
  rs.writeHead(204); rs.end();
});
await new Promise(r=>srv.listen(8174,'127.0.0.1',r));
const br=await chromium.launch({args:['--no-sandbox']});

/* --- before the window opens --- */
let pg=await br.newPage();
const errs=[]; pg.on('pageerror',e=>errs.push(e.message));
await pg.goto('http://127.0.0.1:8174/cbt-exam.html?code=PREP1&st=0',{waitUntil:'domcontentloaded'});
await pg.waitForTimeout(700);
/* the page asks for the code first; a prefill or the Start button drives it */
await pg.evaluate(()=>{ try{ Exam.load(false); }catch(_){} });
await pg.waitForTimeout(1200);
let body=await pg.textContent('body');
ok(/Not open yet/.test(body),'an exam before its start says "Not open yet"',body.slice(0,200));
ok(/Opens at/.test(body),'the exact opening moment is printed');
ok(await pg.$('#cbt-countdown')!==null,'a live countdown element exists');
const cd1=await pg.textContent('#cbt-countdown');
ok(/\d+[dhms]/.test(cd1),'the countdown shows a real time remaining',cd1);
ok(/unlock by itself/.test(body),'the learner is told the page unlocks itself');
await pg.waitForTimeout(1600);
const cd2=await pg.textContent('#cbt-countdown');
ok(cd1!==cd2,'the countdown actually ticks down',[cd1,cd2]);
ok(/Check again now/.test(body),'there is a manual recheck button');
ok(errs.filter(e=>!/PWAInstall|Notifications|supabase|Failed to load/i.test(e)).length===0,'no JS errors on the waiting screen',errs);

/* --- after the window closes --- */
await pg.goto('http://127.0.0.1:8174/cbt-exam.html?code=PREP1&st=1',{waitUntil:'domcontentloaded'});
await pg.waitForTimeout(700);
await pg.evaluate(()=>{ try{ Exam.load(false); }catch(_){} });
await pg.waitForTimeout(1200);
body=await pg.textContent('body');
ok(/Closed/.test(body),'an exam past its close says it is closed',body.slice(0,200));
ok(/closing time has passed/i.test(body),'the learner is told why');
ok(await pg.$('#cbt-countdown')===null,'no countdown is shown for a closed exam');

console.log(`\n  ${pass} passed, ${fail} failed\n`);
await br.close(); srv.close(); process.exit(fail?1:0);
