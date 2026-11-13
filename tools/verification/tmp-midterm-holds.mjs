/* ROUND-15 ITEMS 7 & 8 — the midterm report must obey the SAME governance as
   the terminal report card. Proves, in a real browser, that:
     A. the school's positions switch reaches the midterm sheet
     B. a learner whose position is HELD prints a dash, on the midterm too
     C. a held learner still gets full marks — withholding a position must
        never suppress a score
     D. the sheet says WHY the position is a dash, rather than leaving a blank
     E. a hold recorded for another term does not leak into this one
*/
import { chromium } from 'playwright-core';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml'};
const srv=http.createServer((q,r)=>{let p=decodeURIComponent(q.url.split('?')[0]);if(p==='/')p='/midterm-reports.html';
 const f=path.join(ROOT,p); if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('x');}
 r.writeHead(200,{'content-type':MIME[path.extname(f)]||'application/octet-stream'}); fs.createReadStream(f).pipe(r);});
await new Promise(r=>srv.listen(8160,'0.0.0.0',r));
const b=await chromium.launch({args:['--no-sandbox']});
const pg=await b.newPage();
await pg.goto('http://127.0.0.1:8160/midterm-reports.html',{waitUntil:'domcontentloaded'});
await pg.waitForTimeout(900);

const out=await pg.evaluate(()=>{
  const R=[]; const ok=(c,n,d)=>{R.push({n,c:!!c,d});};
  const MR=window.MR;
  ok(!!MR,'the midterm controller exists');
  if(!MR) return R;

  ok(typeof MR.loadHolds==='function','the page can load per-learner holds');
  ok(typeof MR.isHeld==='function','and can test a row against them');

  /* simulate the holds the school has saved */
  MR._holds={'gos/001':true,'id:abc-123':true};
  ok(MR.isHeld({admission_no:'GOS/001'})===true,'a held admission number is recognised');
  ok(MR.isHeld({student_id:'abc-123'})===true,'a held student id is recognised');
  ok(MR.isHeld({admission_no:'GOS/999'})===false,'a learner who is not held is not held');
  ok(MR.isHeld(null)===false,'a null row does not throw');

  /* B/C/D — render a real sheet and read what it printed */
  MR._pol={show_position:true,show_grade:true,show_subject_position:true,
           show_remarks:true,position_label:'Position in class'};
  const row={student_name:'Ada Obi',admission_no:'GOS/001',has_scores:true,
             position:'3rd',rank_cohort_size:30,percentage:81.5,total:81.5,expected_total:100,
             subjects_sat:4,subjects_expected:4,grade:'A',
             score_details:[{subject:'Mathematics',assessment:'Midterm Test',score:90,max_mark:100}]};
  let html='';
  try{ html=MR.sheetBody ? MR.sheetBody(row) : (MR.sheet?MR.sheet(row):''); }catch(e){ html='THREW '+e.message; }
  if(typeof html!=='string') html='';

  ok(/—/.test(html), 'B: a held learner prints a dash where the position belongs', html.slice(0,120));
  ok(!/>3rd</.test(html)&&!/>3\s*rd</.test(html), 'B: the held learner real position is NOT printed');
  ok(/90/.test(html), 'C: the mark is still there in full', html.slice(0,200));
  ok(/81\.5/.test(html)||/81\.50/.test(html), 'C: the percentage is still there in full');
  ok(/Position withheld/i.test(html), 'D: the sheet explains WHY it is a dash');

  /* a learner who is NOT held must still print their position */
  const row2=Object.assign({},row,{admission_no:'GOS/002',student_name:'Bola Ade',position:'7th'});
  let html2=''; try{ html2=MR.sheetBody?MR.sheetBody(row2):''; }catch(_){ }
  ok(/>7th</.test(html2)||/>7\s*th</.test(html2), 'the un-held learner still prints 7th', html2.slice(0,120));
  ok(!/Position withheld/i.test(html2), 'and carries no withholding notice');

  /* A — with the switch off, NOBODY shows a position, held or not */
  MR._pol.show_position=false;
  let html3=''; try{ html3=MR.sheetBody?MR.sheetBody(row2):''; }catch(_){ }
  ok(!/>7th</.test(html3), 'A: positions switch off removes the position entirely');

  return R;
});

/* E — the term filter on holds, checked on the loader's own logic */
const e=await pg.evaluate(async()=>{
  const MR=window.MR;
  if(!MR||typeof MR.loadHolds!=='function') return {skip:true};
  /* stand up a fake sb that returns holds from two different terms */
  window.sb={
    from(){ return { select(){ return Promise.resolve({data:[
      {student_id_ref:'GOS/100',term:'Second Term',session:'2025/2026'},
      {student_id_ref:'GOS/200',term:'First Term', session:'2025/2026'}
    ]}); } }; }
  };
  MR._holds=null; MR._holdsKey=null;
  const set=await MR.loadHolds('Second Term','2025/2026');
  return {has100:!!set['gos/100'], has200:!!set['gos/200']};
});
let pass=out.filter(x=>x.c).length, fail=out.filter(x=>!x.c).length;
for(const r of out) if(!r.c) console.log('  FAIL', r.n, r.d===undefined?'':String(r.d).slice(0,120));
if(!e.skip){
  if(e.has100===true) pass++; else { fail++; console.log('  FAIL E: a hold for THIS term is loaded', e); }
  if(e.has200===false) pass++; else { fail++; console.log('  FAIL E: a hold from ANOTHER term leaked in', e); }
}
console.log(`\n  ${pass} passed, ${fail} failed\n`);
await b.close(); srv.close(); process.exit(fail?1:0);
