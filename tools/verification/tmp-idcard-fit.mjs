/* ROUND-15 ITEM 2 — "same orientation AND same size" is half the requirement.
   The other half is that the SCHOOL can read the card: content must fit inside
   the box, not be cropped by overflow:hidden.
   This measures scrollHeight vs clientHeight on both faces at five card sizes,
   through the production path (Super.idcard.html / .backHtml), and fails on any
   overflow or any front/back disagreement. */
import { chromium } from 'playwright-core';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml'};
const srv=http.createServer((q,r)=>{let p=decodeURIComponent(q.url.split('?')[0]);if(p==='/')p='/idcards.html';
 const f=path.join(ROOT,p); if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('x');}
 r.writeHead(200,{'content-type':MIME[path.extname(f)]||'application/octet-stream'}); fs.createReadStream(f).pipe(r);});
await new Promise(r=>srv.listen(8141,'0.0.0.0',r));
const b=await chromium.launch({args:['--no-sandbox']});
const pg=await b.newPage({viewport:{width:1200,height:900}});
/* The print pop-up is a BARE document (doctype + inline CSS + super.js), not
   idcards.html. Measuring inside the app page measures the app's own stylesheet
   and lies about what the printer receives. Mirror the pop-up instead. */
const superjs = fs.readFileSync(path.join(ROOT,'assets/js/super.js'),'utf8').replace(/<\/script>/g,'<\\/script>');
await pg.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;padding:0}
  .sc-idcard{max-width:none!important;margin:0!important;box-shadow:none!important}
</style></head><body><script>${superjs}
Super.school={name:'God of Seed Academy',motto:'Knowledge and Character',
  address:'12 Adeola Odeku Street, Victoria Island, Lagos',phone:'+2348012345678',
  email:'info@godofseed.edu.ng',primary:'#0506ae',accent:'#964eec',logoExt:'png',session:'2026/2027'};
</script></body></html>`);
await pg.waitForTimeout(400);
const res=await pg.evaluate(()=>{
  const person={full_name:'Adaeze Ngozi Okonkwo',admission_no:'GOS/2026/001',type:'student',
    gender:'F',blood_group:'O+',date_of_birth:'2013-04-12',phone:'08031234567'};
  const TPL=(window.ICUI&&ICUI.tplOpts&&ICUI.tplOpts().template)||'horizontal';
  const out=[];
  for(const [label,w,h] of [['ID-1 landscape',85.6,53.98],['ID-1 portrait',53.98,85.6],
                            ['60x90 portrait',60,90],['100x60 landscape',100,60],
                            ['CR80 square',70,70],['ID-2',105,74]]){
    const o={widthMm:w,heightMm:h,widthPx:Math.round(w*96/25.4),heightPx:Math.round(h*96/25.4),template:TPL};
    const face=(html)=>{
      const holder=document.createElement('div');
      /* NOT position:absolute — an absolutely-positioned parent gives the
         card a 0-height containing block, so 100% height collapses and every
         measurement lies. Off-screen but in normal flow is what we need. */
      holder.style.cssText='position:relative;left:-9999px;width:'+w+'mm;height:'+h+'mm;overflow:hidden';
      holder.innerHTML=html;
      document.body.appendChild(holder);
      const card=holder.querySelector('.sc-idcard');
      card.style.setProperty('max-width','none','important');
      const r=card.getBoundingClientRect();
      const m={w:Math.round(r.width),h:Math.round(r.height),
               over:Math.max(0,card.scrollHeight-card.clientHeight),
               overW:Math.max(0,card.scrollWidth-card.clientWidth),
               rules:card.querySelectorAll('ol li').length};
      holder.remove(); return m;
    };
    out.push({label,w,h,front:face(Super.idcard.html(person,o)),back:face(Super.idcard.backHtml(person,o))});
  }
  return out;
});
let fail=0;
console.log('CARD               FRONT          BACK           F/B SIZE  CONTENT         VERDICT');
for(const r of res){
  const {front:f,back:k}=r;
  const same=Math.abs(f.w-k.w)<2&&Math.abs(f.h-k.h)<2;
  const fits=f.over<=1&&k.over<=1&&f.overW<=1&&k.overW<=1;
  const ok=same&&fits&&f.rules===0&&k.rules===5;  /* front has no rules; back must keep all five */
  if(!ok)fail++;
  const det=[f.over?`front +${f.over}px`:'',k.over?`back +${k.over}px`:'',
             f.overW?`front W+${f.overW}`:'',k.overW?`back W+${k.overW}`:'',
             k.rules!==5?`back rules ${k.rules}≠5`:''].filter(Boolean).join(', ')||'all inside';
  console.log(`${r.label.padEnd(18)} ${String(f.w+'x'+f.h).padEnd(14)} ${String(k.w+'x'+k.h).padEnd(14)} ${(same?'same':'DIFF').padEnd(9)} ${det.padEnd(15)} ${ok?'PASS':'FAIL'}`);
}
console.log(`\n${res.length-fail} passed, ${fail} failed`);
await b.close(); srv.close(); process.exit(fail?1:0);
