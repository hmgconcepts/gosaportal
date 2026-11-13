/* ROUND-15 ITEM 2 — "front and back must share orientation AND size."
   A fix is only real if a browser agrees, so this renders BOTH faces through
   the production path (Super.idcard.html / .backHtml) inside the production
   print geometry (.idcard-face mm box > .idcard-scale transform) and measures
   the physical result in millimetres.
   Fails if the two faces differ in size, in ratio, or in orientation. */
import { chromium } from 'playwright-core';
import http from 'http'; import fs from 'fs'; import path from 'path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const MIME = {'.html':'text/html','.js':'text/javascript','.css':'text/css',
  '.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml'};
const srv = http.createServer((q,r)=>{
  let p = decodeURIComponent(q.url.split('?')[0]); if(p==='/') p='/idcards.html';
  const f = path.join(ROOT,p);
  if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){ r.writeHead(404); return r.end('x'); }
  r.writeHead(200,{'content-type':MIME[path.extname(f)]||'application/octet-stream'});
  fs.createReadStream(f).pipe(r);
});
await new Promise(r=>srv.listen(8137,'0.0.0.0',r));

const b = await chromium.launch({args:['--no-sandbox']});
const pg = await b.newPage();
await pg.goto('http://127.0.0.1:8137/idcards.html',{waitUntil:'domcontentloaded'});
await pg.waitForTimeout(900);

const res = await pg.evaluate(() => {
  const person = {full_name:'Ada Obi',admission_no:'GOS/001',class:'JSS1',type:'student'};
  /* the exact fit() the print pop-up runs before window.print() */
  const fit = (frame, box, card) => {
    card.style.setProperty('max-width','none','important');
    card.style.setProperty('margin','0','important');
    const r = card.getBoundingClientRect();
    const w = r.width || card.offsetWidth, h = r.height || card.offsetHeight;
    if(!w || !h) return null;
    const scale = Math.min(frame.clientWidth/w, frame.clientHeight/h);
    box.style.width = w+'px'; box.style.height = h+'px';
    box.style.transform = 'scale('+scale+')';
    const pxPerMm = frame.clientWidth / (parseFloat(frame.dataset.mmW)||1);
    return {scale, naturalW:w, naturalH:h,
            printedWmm:+(w*scale/pxPerMm).toFixed(2), printedHmm:+(h*scale/pxPerMm).toFixed(2)};
  };
  const out = [];
  for(const [label,w,h] of [['landscape ID-1',85.6,53.98],['portrait ID-1',53.98,85.6],
                            ['portrait custom',60,90],['landscape custom',100,60],['square',70,70]]){
    const o = {widthMm:w,heightMm:h,widthPx:Math.round(w*96/25.4),heightPx:Math.round(h*96/25.4),
               template:(window.SUPER_TEMPLATE||'horizontal')};
    const face = (html) => {
      const frame = document.createElement('div');
      frame.className='idcard-face';
      frame.dataset.mmW = w; frame.dataset.mmH = h;
      frame.style.cssText = `position:relative;width:${w}mm;height:${h}mm;background:#fff;box-sizing:border-box`;
      const box = document.createElement('div');
      box.className='idcard-scale';
      box.style.cssText='position:absolute;transform-origin:top left';
      box.innerHTML = html;
      frame.appendChild(box);
      const holder = document.createElement('div');
      holder.style.cssText='position:absolute;left:-9999px;top:0;';
      holder.appendChild(frame); document.body.appendChild(holder);
      const info = fit(frame, box, box.querySelector('.sc-idcard'));
      const rect = box.querySelector('.sc-idcard').getBoundingClientRect();
      holder.remove();
      return {...info, mountedW:rect.width, mountedH:rect.height};
    };
    out.push({label, wantW:w, wantH:h,
      front: face(Super.idcard.html(person,o)),
      back:  face(Super.idcard.backHtml(person,o))});
  }
  return out;
});

let fail = 0;
console.log('CARD               FRONT printed   BACK printed    RATIO F/B      VERDICT');
for(const r of res){
  const f = r.front, k = r.back;
  if(!f || !k){ console.log(`${r.label.padEnd(18)} RENDER FAILED`); fail++; continue; }
  const same = Math.abs(f.printedWmm-k.printedWmm) < 0.2 && Math.abs(f.printedHmm-k.printedHmm) < 0.2;
  const rf = +(f.printedWmm/f.printedHmm).toFixed(3), rk = +(k.printedWmm/k.printedHmm).toFixed(3);
  const want = +(r.wantW/r.wantH).toFixed(3);
  const ratioOk = Math.abs(rf-rk) < 0.01 && Math.abs(rf-want) < 0.02;
  const orientOk = (rf>1) === (rk>1);
  const ok = same && ratioOk && orientOk;
  if(!ok) fail++;
  console.log(`${r.label.padEnd(18)} ${String(f.printedWmm+'x'+f.printedHmm+'mm').padEnd(15)} ${String(k.printedWmm+'x'+k.printedHmm+'mm').padEnd(15)} ${(rf+'/'+rk).padEnd(15)} ${ok?'PASS':'FAIL'} (want ${r.wantW}x${r.wantH})`);
}
console.log(`\n${res.length-fail} passed, ${fail} failed`);
await b.close(); srv.close(); process.exit(fail?1:0);
