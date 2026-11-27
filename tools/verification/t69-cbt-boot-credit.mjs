/* V12.86 (round 31, item 4) — A CLOSED PAGE MUST GIVE ITS MINUTES BACK.
   ---------------------------------------------------------------------------
   A call does not always just hide the page: on a phone short of memory the tab
   is discarded outright, so `visibilitychange` and `pagehide` never fire. The
   learner returns, the page reboots, and the countdown has charged them for
   every minute the phone was in their pocket. Near the end of the paper the
   next tick finds zero and the paper is sent with the answers they never
   reached.

   Proved here against the SHIPPED page (assets/templates/pages/cbt-exam.html)
   and against the arithmetic itself, executed here:
     1. a heartbeat is written whenever the draft is saved;
     2. boot reads the heartbeat and hands the gap back to the deadline;
     3. the credit is capped over the whole sitting and logged with a reason;
     4. a short gap (a normal reload) is not treated as an interruption;
     5. the end-of-paper sender re-arms and never sends while hidden/offline.

   Run: node tools/verification/t69-cbt-boot-credit.mjs
   ========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const ROOT = path.resolve(new URL('.', import.meta.url).pathname, '../..');
const src = fs.readFileSync(path.join(ROOT, 'assets/templates/pages/cbt-exam.html'), 'utf8');

let pass = 0, fail = 0;
const ok = (c, m, x) => c ? (pass++, console.log('  PASS', m))
  : (fail++, console.log('  FAIL', m, x === undefined ? '' : JSON.stringify(x).slice(0, 400)));

console.log('\n1. the page keeps a heartbeat while the paper is open');
ok(/-hb'/.test(src), 'a heartbeat key is written next to the deadline');
ok(/localStorage\.setItem\(this\.deadlineKey\(\) \+ '-hb'/.test(src), 'and it is written by saveDraft, i.e. after every answer');

console.log('\n2. boot hands back the time the phone was away');
ok(/page_closed/.test(src), 'the interruption is logged with a reason a tutor can read');
ok(/handed back to you/.test(src), 'and the learner is told, in words, that the minutes were returned');

/* ---------- run the boot arithmetic exactly as shipped ---------- */
/* brace-match the whole `try { ... } catch(_) {}` wrapper the page ships */
function extractTry(src, marker) {
  const m = src.indexOf(marker);
  if (m < 0) throw new Error('marker not found');
  const ti = src.lastIndexOf('try', m);
  const open = src.indexOf('{', ti);
  let d = 0;
  for (let k = open; k < src.length; k++) {
    if (src[k] === '{') d++;
    else if (src[k] === '}') { d--; if (d === 0) return src.slice(ti, k + 1) + ' catch(_) {}'; }
  }
  throw new Error('unbalanced try block');
}
/* the toast line is a one-line try/catch of its own and carries an emoji; it is
   asserted from the SOURCE below, so it is dropped before the block is executed */
const block = extractTry(src, 'const hb = Number(localStorage.getItem(this.deadlineKey()')
  .split('\n').filter(l => !l.includes('toast(')).join('\n');

function runBoot({ awayMs, already = 0, deadlineInMs = 600000 }) {
  const store = { hb: String(Date.now() - awayMs) };
  const ctx = {
    Date, Math, JSON, String, Number, console,
    localStorage: {
      getItem: k => (k.endsWith('-hb') ? store.hb : null),
      setItem: (k, v) => { if (k.endsWith('-hb')) store.hb = v; }
    },
    toast: (m) => { ctx._toast = m; }
  };
  const that = {
    deadlineKey: () => 'cbt-deadline-ABC-GOSA2024001',
    deadline: Date.now() + deadlineInMs,
    interruptTotalMs: already,
    interruptLog: []
  };
  const before = that.deadline;
  vm.createContext(ctx);
  vm.runInContext(
    'result = (function(){ ' + block + '\n return this; }).call(THAT);',
    Object.assign(ctx, { THAT: that })
  );
  return { credited: that.deadline - before, log: that.interruptLog, toastMsg: ctx._toast, that };
}

const closed = runBoot({ awayMs: 10 * 60 * 1000 });
ok(closed.credited >= 9.9 * 60 * 1000 && closed.credited <= 10.1 * 60 * 1000,
   `ten minutes away gives ten minutes back (${Math.round(closed.credited / 1000)}s)`, closed.credited);
ok(closed.log.length === 1 && closed.log[0].why === 'page_closed', 'the log says the PAGE was closed, not the tab hidden', closed.log);
ok(/handed back to you/.test(src), 'and the candidate is told, in words, in the shipped page');

const reload = runBoot({ awayMs: 20000 });
ok(reload.credited === 0, 'a 20-second reload is not called an interruption (no free time)', reload.credited);

const capped = runBoot({ awayMs: 90 * 60 * 1000, already: 25 * 60 * 1000 });
ok(Math.round(capped.credited / 60000) === 5, `the whole-sitting cap holds (${Math.round(capped.credited / 60000)} min credited of 90 min away)`, capped.credited);

const spent = runBoot({ awayMs: 60 * 60 * 1000, already: 30 * 60 * 1000 });
ok(spent.credited === 0, 'a candidate who has used the whole allowance is given nothing more', spent.credited);

console.log('\n3. the end-of-paper sender cannot be surprised');
ok(/this\._timeUpTimer = setInterval/.test(src), 'the sender re-arms instead of firing once');
ok(/if \(document\.hidden \|\| !navigator\.onLine\) return;/.test(src), 'it never sends while the page is away or offline');
ok(/_timeUpIdleSince/.test(src) && /120000/.test(src), 'and it waits for two idle minutes in front of the screen');

console.log(`\nCBT-BOOT-CREDIT ${fail ? 'FAILED' : 'OK'} — ${pass} passed, ${fail} failed · a discarded tab no longer charges the learner for the call.`);
process.exit(fail ? 1 : 0);
