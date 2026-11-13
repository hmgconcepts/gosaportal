/* ROUND-15 ITEM 4 — report-card / mid-term arithmetic under hostile input.
   A record a school prints, signs and keeps for decades must not depend on
   tidy data. This drives the REAL primitives of assets/js/report-engine.js
   with the inputs that actually occur, and fails on any NaN, Infinity, crash,
   or impossible figure. */
import { chromium } from 'playwright-core';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml'};
const srv=http.createServer((q,r)=>{let p=decodeURIComponent(q.url.split('?')[0]);if(p==='/')p='/report-cards.html';
 const f=path.join(ROOT,p); if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('x');}
 r.writeHead(200,{'content-type':MIME[path.extname(f)]||'application/octet-stream'}); fs.createReadStream(f).pipe(r);});
await new Promise(r=>srv.listen(8151,'0.0.0.0',r));
const b=await chromium.launch({args:['--no-sandbox']});
const pg=await b.newPage();
const pageErrors=[];
pg.on('pageerror', e=>{ if(!/sb is not defined/.test(e.message)) pageErrors.push(e.message); });
await pg.goto('http://127.0.0.1:8151/report-cards.html',{waitUntil:'domcontentloaded'});
await pg.waitForTimeout(900);

const out = await pg.evaluate(() => {
  const R=[];
  const E = window.ReportEngine;
  if(!E) return [{name:'engine present', pass:false, detail:'window.ReportEngine not found'}];
  const num = x => typeof x==='number' && isFinite(x);
  const t=(name, expect, fn)=>{ let got; try{got=fn();}catch(e){R.push({name,pass:false,detail:'THREW: '+e.message});return;}
    R.push({name, pass:!!expect(got), detail:JSON.stringify(got)}); };

  /* — coercion: the engine's n() must never leak NaN into a total — */
  /* label with String(v) — JSON.stringify turns NaN and Infinity into null and
     made two perfectly good results look like failures */
  for(const v of [undefined,null,'','abc',NaN,Infinity,-Infinity,{},[],'12.5abc',true]){
    t(`n(${String(v)}) is a finite number`, g=>num(g), ()=>E.n(v));
  }
  /* — fmt(): no 'NaN', no 'Infinity', never blank for a real number — */
  for(const v of [undefined,null,'','abc',NaN,Infinity,0,-0,1.005,99.999,100]){
    t(`fmt(${String(v)}) renders a clean string`, g=>typeof g==='string'&&!/NaN|Infinity/.test(g), ()=>E.fmt(v));
  }
  /* — grade(): always one of the six, for every input — */
  for(const v of [-100,0,39.9,40,49.9,50,59.9,60,69.9,70,79.9,80,100,1000,NaN,'',null,undefined,'88']){
    t(`grade(${JSON.stringify(v)}) is a valid letter`, g=>['A','B','C','D','E','F'].includes(g), ()=>E.grade(v));
  }
  /* — grade() must be MONOTONE: a higher score can never get a worse letter — */
  t('grade is monotone across the whole scale', ok=>ok===true, ()=>{
    /* a higher score must never earn a WORSE letter */
    const order={A:6,B:5,C:4,D:3,E:2,F:1};
    let prev=order['F'];
    for(let s=0;s<=100;s+=0.5){ const g=order[E.grade(s)]; if(g<prev) return false; prev=g; }
    return true;
  });
  /* — remark() always defined, never undefined — */
  for(const v of [0,45,85,NaN,null]){
    t(`remark(${JSON.stringify(v)}) is a non-empty string`, g=>typeof g==='string'&&g.length>0, ()=>E.remark(v));
  }
  /* — ordinal(): 1st/2nd/3rd/4th/11th/12th/13th/21st/101st/111th — */
  const ordCases={1:'1st',2:'2nd',3:'3rd',4:'4th',11:'11th',12:'12th',13:'13th',21:'21st',22:'22nd',23:'23rd',101:'101st',111:'111th'};
  for(const [k,v] of Object.entries(ordCases)){
    t(`ordinal(${k}) === ${v}`, g=>g===v, ()=>E.ordinal(Number(k)));
  }
  /* — gradeFor(): a learner who sat NOTHING must not be graded as a failure — */
  t('gradeFor with zero assessments sat is not "F"',
    g=>g===null||g===undefined||g===''||String(g).toUpperCase()!=='F',
    ()=>E.gradeFor(0, 0));
  /* A learner who SAT something and scored zero has genuinely failed it, so 'F'
     is correct there. What must never happen is a grade when NOTHING was sat —
     that is the zero-evidence case below. */
  t('gradeFor(0, 1) grades a sat-but-failed paper as F', g=>g==='F', ()=>E.gradeFor(0,1));
  t('gradeFor(0, 0) withholds when nothing was sat', g=>g==='', ()=>E.gradeFor(0,0));
  /* — bmi(): impossible vitals must be null, never Infinity/NaN — */
  for(const m of [{height_cm:0,weight_kg:50},{height_cm:170,weight_kg:0},{height_cm:'',weight_kg:''},
                  {height_cm:null,weight_kg:null},{height_cm:-170,weight_kg:60},{height_cm:170,weight_kg:-60}]){
    t(`bmi(${JSON.stringify(m)}) is null or finite`, g=>g===null||num(g), ()=>E.bmi(m));
  }
  t('bmi(170cm, 65kg) is a sane 22.5', g=>Math.abs(g-22.5)<0.1, ()=>E.bmi({height_cm:170,weight_kg:65}));

  /* ============================================================
     COHORT RANKING — the figures that decide a child's position.
     ============================================================ */
  const R2 = (nm,s,total,max,id)=>({student_name:nm,subject:s,total,max,student_id:id});

  t('an empty cohort ranks nobody instead of throwing',
    r=>r.cohortSize===0 && Object.keys(r.byName).length===0,
    ()=>E.rankCohort([],[]));

  t('TWO CHILDREN WITH THE SAME NAME ARE NEVER MERGED',
    r=>Object.keys(r.byId||{}).length===2 || r.list.length===2 ? (r.list.length===2) : false,
    ()=>E.rankCohort([R2('Ada Obi','Math',90,100,'s1'), R2('Ada Obi','Math',40,100,'s2')],['Math']));

  t('same-name learners keep their OWN totals',
    r=>{ const l=r.list.slice().sort((a,b)=>b.total-a.total);
         return l.length===2 && l[0].total===90 && l[1].total===40; },
    ()=>E.rankCohort([R2('Ada Obi','Math',90,100,'s1'), R2('Ada Obi','Math',40,100,'s2')],['Math']));

  t('same-name learners get DIFFERENT positions',
    r=>{ const p=r.list.map(x=>x.position); return p.length===2 && p[0]!==p[1]; },
    ()=>E.rankCohort([R2('Ada Obi','Math',90,100,'s1'), R2('Ada Obi','Math',40,100,'s2')],['Math']));

  t('a genuine tie shares a position',
    r=>r.byName['A'].position===1 && r.byName['B'].position===1 && r.byName['C'].position===3,
    ()=>E.rankCohort([R2('A','Math',80,100),R2('B','Math',80,100),R2('C','Math',60,100)],['Math']));

  t('NOBODY IS RANKED WHEN THE DENOMINATOR IS ZERO',
    r=>r.byName['A'].position===null && r.byName['A'].rankable===false,
    ()=>E.rankCohort([R2('A','Math',10,0)],['Math']));

  t('a zero denominator reports null percentage, never 0% or NaN',
    r=>r.byName['A'].percentage===null,
    ()=>E.rankCohort([R2('A','Math',10,0)],['Math']));

  t('a learner with no marks is not ranked and not "complete"',
    r=>r.byName['A'].position===null && r.byName['A'].complete===false,
    ()=>E.rankCohort([R2('A','Math',0,100)],['Math']));

  t('a blank student name cannot create a phantom learner',
    r=>Object.keys(r.byName).length===1 && Object.keys(r.byName)[0]==='Real',
    ()=>E.rankCohort([R2('   ','Math',50,100),R2('Real','Math',60,100)],['Math']));

  t('a one-learner class still gets position 1st',
    r=>r.byName['Solo'].position===1 && r.byName['Solo'].cohortSize===1,
    ()=>E.rankCohort([R2('Solo','Math',100,100)],['Math']));

  t('the denominator is the CLASS load, not the learner\'s own submission',
    r=>r.byName['A'].expected===400,
    ()=>E.rankCohort([R2('A','Math',50,100),R2('A','Eng',50,100),R2('A','Sci',50,100),R2('A','Art',50,100),
                      R2('B','Math',90,100),R2('B','Eng',90,100),R2('B','Sci',90,100),R2('B','Art',90,100)],
                     ['Math','Eng','Sci','Art']));
  return R;
});

let fail=0;
for(const r of out){ if(!r.pass){fail++; console.log(`  FAIL  ${r.name}  ${r.detail||''}`);} }
console.log(`  ${out.length-fail} checks passed, ${fail} failed`);
if(pageErrors.length){ console.log('  PAGE ERRORS:', pageErrors.slice(0,5).join(' | ')); }
console.log(`\n${out.length-fail} passed, ${fail + (pageErrors.length?1:0)} failed`);
await b.close(); srv.close(); process.exit((fail||pageErrors.length)?1:0);
