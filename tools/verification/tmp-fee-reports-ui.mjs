/* ROUND-15 ITEM 5 — the Financial Reports panel, proven in a real browser.
   The RPCs are stubbed with the exact response shapes the server returns, so
   this suite tests the PAGE: does it band the money, warn on a bad collection
   rate, refuse to nag about money not yet due, and print the register. */
import { chromium } from 'playwright-core';
import http from 'node:http';
import { readFileSync } from 'node:fs';
const HERE = new URL('.', import.meta.url).pathname;
const PAGE = HERE + '../../fees.html';
let pass=0, fail=0;
const ok=(c,n,d)=>{ if(c) pass++; else { fail++; console.log('  FAIL', n, d===undefined?'':JSON.stringify(d).slice(0,260)); } };

const AGED = { ok:true, engine:'v12.71',
  rows:[
    { student_id:'s1', student:'Ada Obi',      admission_no:'SC/001', class:'JSS 1', outstanding:50000, days_overdue:120, band:'over_90' },
    { student_id:'s2', student:'Bala Musa',    admission_no:'SC/002', class:'JSS 1', outstanding:30000, days_overdue:45,  band:'31_60' },
    { student_id:'s3', student:'Chidi Nwosu',  admission_no:'SC/003', class:'JSS 2', outstanding:12000, days_overdue:12,  band:'0_30' },
    { student_id:'s4', student:'Dara Ahmed',   admission_no:'SC/004', class:'JSS 2', outstanding:40000, days_overdue:0,   band:'not_due' }
  ],
  totals:{ not_due:40000, '0_30':12000, '31_60':30000, '61_90':0, over_90:50000, total:132000, learners:4 },
  meaning:'not_due is billed but not yet payable; the other bands are money the school can already chase — 31-60 is a reminder, 61-90 is a meeting, over 90 needs a written plan or a write-off decision.' };
const COLL = { ok:true, engine:'v12.71',
  rows:[ { class:'jss 1', invoices:2, billed:80000,  collected:0,     outstanding:80000, rate:0 },
         { class:'jss 2', invoices:2, billed:52000,  collected:50000, outstanding:2000,  rate:96.2 } ],
  totals:{ billed:132000, collected:50000, outstanding:82000, rate:37.9 },
  meaning:'collected/billed is the collection rate.' };
const ADJ = { ok:true, engine:'v12.71', rows:[
  { id:'a1', student:'Ada Obi', admission_no:'SC/001', class:'JSS 1', kind:'waiver', amount:5000,
    reason:'Bereavement — approved by the board', term:'First Term', session:'2025/2026',
    by:'Mrs Bursar', at:'13 Nov 2026 09:12' } ] };

const html = readFileSync(PAGE,'utf8')
  .replace(/<script[^>]*src=["'][^"']*config\.js["'][^>]*><\/script>/i,'')
  .replace(/<script[^>]*src=["'][^"']*supabase/i,'')
  .replace('</head>', `<script>
    window.__calls=[]; window.__mode='ok';
    window.SCHOOL={currency:'\u20a6',name:'Test College'};
    window.toast=(m,k)=>{window.__lastToast=m+'|'+k;};
    window.sb={rpc:async(fn,args)=>{ window.__calls.push(fn);
      if(window.__mode==='fail') return {data:null,error:{message:'function public.'+fn+' does not exist'}};
      const RECON={ok:true,from:'2026-11-01',to:'2026-11-13',engine:'v12.71',
      by_method:[{method:'cash',receipts:12,amount:180000},{method:'transfer',receipts:8,amount:420000}],
      totals:{receipts:20,total:600000,cash:180000,bank:420000,unallocated:0,no_reference:2,zero_or_negative:0,by_collector:[]},
      how_to_use:'Count the physical cash in the box and read the bank statement for the same dates.'};
    const M={sc_fee_aged_arrears:${JSON.stringify(AGED)},sc_fee_collection_summary:${JSON.stringify(COLL)},sc_fee_adjustments:${JSON.stringify(ADJ)},sc_fee_cash_reconciliation:RECON};
      return {data:M[fn]??{ok:true,rows:[]},error:null}; },
      from:()=>({select:()=>({in:async()=>({data:[],error:null})})})};
  </script></head>`);

const srv = http.createServer((rq,rq2)=>{
  /* anything that is not the page itself must NOT get HTML back, or the
     browser reports "Unexpected token '<'" for every missing asset */
  const u = rq.url.split('?')[0];
  if(u === '/' || u.endsWith('.html')){ rq2.writeHead(200,{'content-type':'text/html'}); return rq2.end(html); }
  if(u.endsWith('.js')){ rq2.writeHead(200,{'content-type':'application/javascript'}); return rq2.end(''); }
  if(u.endsWith('.css')){ rq2.writeHead(200,{'content-type':'text/css'}); return rq2.end(''); }
  rq2.writeHead(204); rq2.end();
});
await new Promise(r=>srv.listen(8166,'127.0.0.1',r));
const br = await chromium.launch({args:['--no-sandbox']});
const pg = await br.newPage();
const errs=[]; pg.on('pageerror',e=>errs.push(e.message));
await pg.goto('http://127.0.0.1:8166/fees.html', {waitUntil:'domcontentloaded'});

/* the card exists and is admin-gated */
ok(await pg.$('#fee-reports-card')!==null,'the Financial Reports card is on the page');
const gate = await pg.getAttribute('#fee-reports-card','data-admin-only');
ok(gate!==null,'the card is admin-only, like the other money panels',gate);
ok(await pg.$('#fr-load')!==null,'there is a Build button');
ok(await pg.$('#fr-csv')!==null,'there is a CSV button');
ok(await pg.$('#fr-csv').then(e=>e.isDisabled()),'CSV starts disabled — nothing to export yet');

/* build */
await pg.click('#fr-load');
await pg.waitForFunction(()=>document.getElementById('fr-out').textContent.includes('Over 90 days'),null,{timeout:8000});
const txt = await pg.textContent('#fr-out');
const calls = await pg.evaluate(()=>window.__calls);
ok(calls.includes('sc_fee_aged_arrears'),'the panel calls the aged-arrears engine');
ok(calls.includes('sc_fee_collection_summary'),'the panel calls the collection-summary engine');
ok(calls.includes('sc_fee_adjustments'),'the panel calls the adjustments register');

/* the five bands are named and carry their action */
ok(/Not yet due/.test(txt),'the not-yet-due money is separated from arrears');
ok(/0–30 days overdue/.test(txt)&&/send the reminder now/.test(txt),'the 0-30 band says what to do');
ok(/31–60 days/.test(txt)&&/phone the family/.test(txt),'the 31-60 band says what to do');
ok(/61–90 days/.test(txt)&&/book a meeting/.test(txt),'the 61-90 band says what to do');
ok(/Over 90 days/.test(txt)&&/written plan, or write it off/.test(txt),'the over-90 band says what to do');

/* the chaseable total EXCLUDES not-due money — the whole point */
ok(/₦92,000/.test(txt),'the chaseable total is 0-30 + 31-60 + 61-90 + 90+ = 92,000, NOT 132,000',txt.slice(0,400));

/* collection summary */
ok(/Collection by class/.test(txt),'there is a per-class collection table');
ok(/jss 1/.test(txt)&&/96.2%/.test(txt),'per-class collection rate is printed');
ok(/A collection rate below 70%/.test(txt),'a bad whole-school rate raises the warning');
ok(/Whole school/.test(txt),'the table totals the whole school');

/* the band pills */
const pills = await pg.$$eval('#fr-out span', els=>els.filter(e=>/days|not due/i.test(e.textContent)).map(e=>e.textContent.trim()));
ok(pills.includes('over 90 days'),'an over-90 learner is badged',pills);
ok(!pills.includes('not due'),'while overdue-only is ticked no not-yet-due learner is badged',pills);

/* "overdue only" hides the not-due learner */
ok(/Dara Ahmed/.test(txt)===false,'with overdue-only ticked the not-yet-due learner is hidden');
await pg.uncheck('#fr-only-overdue');
await pg.waitForFunction(()=>document.getElementById('fr-out').textContent.includes('Dara Ahmed'),null,{timeout:5000});
const txt2 = await pg.textContent('#fr-out');
ok(/Dara Ahmed/.test(txt2),'unticking shows the not-yet-due learner again');
const pills2 = await pg.$$eval('#fr-out span', els=>els.filter(e=>/days|not due/i.test(e.textContent)).map(e=>e.textContent.trim()));
ok(pills2.includes('not due'),'the not-yet-due learner is badged as such, not as an arrears',pills2);
await pg.check('#fr-only-overdue');
await pg.waitForFunction(()=>!document.getElementById('fr-out').textContent.includes('Dara Ahmed'),null,{timeout:5000});

/* adjustments register */
ok(/Adjustments register/.test(txt),'the adjustments register is shown');
ok(/Bereavement/.test(txt),'the register keeps the reason');
ok(/Mrs Bursar/.test(txt),'the register names the approver');

/* CSV enabled after build */
ok(!(await pg.$('#fr-csv').then(e=>e.isDisabled())),'CSV becomes available once the reports are built');
const dl = await Promise.all([pg.waitForEvent('download',{timeout:6000}).catch(()=>null), pg.click('#fr-csv')]);
ok(dl[0]!==null,'the CSV downloads');
ok(dl[0] && /aged-arrears-\d{4}-\d{2}-\d{2}\.csv/.test(dl[0].suggestedFilename()),'the CSV is named for today',dl[0]&&dl[0].suggestedFilename());

/* empty-ledger honesty */
await pg.evaluate(()=>{ const o=window.sb.rpc; window.sb.rpc=async(fn,a)=> fn==='sc_fee_aged_arrears'
  ? {data:{ok:true,rows:[],totals:{not_due:0,'0_30':0,'31_60':0,'61_90':0,over_90:0,total:0,learners:0},meaning:'x',engine:'v12.71'},error:null}
  : {data:{ok:true,rows:[],totals:{billed:0,collected:0,outstanding:0,rate:null},meaning:'x',engine:'v12.71'},error:null}; });
await pg.click('#fr-load');
await pg.waitForFunction(()=>document.getElementById('fr-out').textContent.includes('Nothing is overdue'),null,{timeout:6000});
ok(/Nothing is overdue/.test(await pg.textContent('#fr-out')),'an empty ledger says nothing is overdue rather than showing zeros as debt');

/* permission refusal is shown, not swallowed */
await pg.evaluate(()=>{ window.sb.rpc=async()=>({data:{ok:false,error:'Only the bursary and leadership can read arrears.'},error:null}); });
await pg.click('#fr-load');
await pg.waitForFunction(()=>document.getElementById('fr-out').textContent.includes('could not be built'),null,{timeout:6000});
const errTxt = await pg.textContent('#fr-out');
ok(/Only the bursary and leadership/.test(errTxt),'a refusal surfaces the server reason verbatim',errTxt.slice(0,200));

/* a missing function tells the operator what to run */
await pg.evaluate(()=>{ window.__mode='fail'; window.sb.rpc=async()=>({data:null,error:{message:'function public.sc_fee_aged_arrears does not exist'}}); });
await pg.click('#fr-load');
await pg.waitForFunction(()=>document.getElementById('fr-out').textContent.includes('complete-schema.sql'),null,{timeout:6000});
ok(/Run the latest/.test(await pg.textContent('#fr-out')),'a missing function tells the operator which script to run');

/* PWAInstall / Notifications live in assets/js/*.js which this harness strips;
   they are unrelated to the panel under test. Everything else must be clean. */
const realErrs = errs.filter(e=>!/PWAInstall is not defined|Notifications is not defined/.test(e));
ok(realErrs.length===0,'the page threw no JavaScript errors',errs);
/* ---- month-end reconciliation, on a freshly loaded page ---- */
await pg.evaluate(()=>{ const r=window.sb.rpc; });
await pg.goto('http://127.0.0.1:8166/fees.html', {waitUntil:'domcontentloaded'});
await pg.click('#fr-load');
await pg.waitForFunction(()=>document.getElementById('fr-out').textContent.includes('Total received'),null,{timeout:8000});
const rtxt = await pg.textContent('#fr-out');
ok(/Cash & bank reconciliation/.test(rtxt),'the reconciliation section is rendered', rtxt.slice(0,200));
ok(/Cash/.test(rtxt)&&/Bank/.test(rtxt),'cash and bank are separate lines');
ok(/₦600,000/.test(rtxt),'the total received is printed');
const calls2 = await pg.evaluate(()=>window.__calls);
ok(calls2.includes('sc_fee_cash_reconciliation'),'the panel calls the reconciliation engine');
ok(/carry no reference number/.test(rtxt),'a receipt with no reference is flagged in plain English');
ok(/Count the physical cash/.test(rtxt),'the instructions for using it are shown');
ok(await pg.$('#fr-recon')!==null,'there is a reconciliation button');

console.log(`\n  ${pass} passed, ${fail} failed\n`);
await br.close(); srv.close(); process.exit(fail?1:0);
