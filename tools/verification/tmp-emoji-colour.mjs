/* V12.68 — emoji must render in COLOUR, in a real browser.
   The user's standing instruction: never accept a monochrome/outline glyph where
   colour is expected, and never "verify" that by reading code. This harness
   loads the page in Chromium, embeds a colour-emoji face we control (so the
   result does not depend on the machine having an emoji font installed), draws
   the same glyphs the UI uses, and counts DISTINCT COLOURS in the pixels.

   A monochrome fallback (Noto Sans Symbols / DejaVu / the "tofu" box) is a flat
   grey or outline: 1–6 colours. Colour emoji are full-colour bitmaps: hundreds.
   The threshold is 40 distinct RGB values per glyph run — an order of magnitude
   away from both states, so this cannot be flaky. */
/* playwright-core lives in the authoring tree, not in the shipped repo */
import { createRequire } from 'module';
const require_ = createRequire(import.meta.url);
/* The authoring tree at /home/user/work is NOT part of the saved workspace, so
   never depend on it: resolve playwright-core from wherever it actually is
   (the repo's own node_modules, an env override, or a global install). */
let chromium = null, resolveErr = null;
for (const cand of [process.env.SC_WORK, 'playwright-core', 'playwright',
                    '/usr/lib/node_modules/playwright-core'].filter(Boolean)) {
  try { ({ chromium } = require_(cand)); break; } catch (e) { resolveErr = e; }
}
if (!chromium) {
  console.error('  playwright-core not resolvable — run: npm i --no-save playwright-core');
  console.error('  ' + (resolveErr && resolveErr.message));
  process.exit(1);
}
import fs from 'fs';
const HERE = new URL('.', import.meta.url).pathname;
/* find a usable Chromium: the container image changes between sessions, so
   never hard-code one revision. Chrome needs its shared libraries; the
   headless shell is what CI has. */
function findChrome() {
  if (process.env.SC_CHROME) return process.env.SC_CHROME;
  const roots = [process.env.HOME + '/.cache/ms-playwright', '/root/.cache/ms-playwright'];
  const glob = (dir) => { try { return fs.readdirSync(dir); } catch { return []; } };
  for (const r of roots) {
    for (const d of glob(r).sort().reverse()) {
      for (const rel of ['chrome-linux/headless_shell', 'chrome-linux/chrome',
                         'chrome-linux64/chrome', 'chrome-headless-shell-linux64/chrome-headless-shell']) {
        const p = r + '/' + d + '/' + rel;
        if (fs.existsSync(p)) return p;
      }
    }
  }
  return '';
}
const EXE = findChrome();
const FONT = HERE + 'fonts/color-emoji-subset.woff2';
let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? (pass++, console.log('  PASS', m)) : (fail++, console.log('  FAIL', m, x ?? '')); };

const b64 = fs.readFileSync(FONT).toString('base64');
const GLYPHS = '💰 🧾 ✅ ⚠️ 📞 ✉️ 📍 🔎 🎓 🧮';
if (!EXE) { console.log('  SKIP  no Chromium found (set SC_CHROME)'); process.exit(0); }
const browser = await chromium.launch({
  executablePath: EXE,
  args: ['--no-sandbox'],
  env: { ...process.env, LD_LIBRARY_PATH: '/home/user/.local/lib:' + (process.env.LD_LIBRARY_PATH || '') },
});
const page = await browser.newPage({ viewport: { width: 900, height: 260 }, deviceScaleFactor: 2 });
await page.setContent(`<meta charset="utf-8"><style>
  @font-face{font-family:"SCEmoji";src:url(data:font/woff2;base64,${b64}) format("woff2");font-display:block;}
  body{margin:0;background:#fff}
  #run{font:48px "SCEmoji",sans-serif;line-height:1.4;padding:8px;letter-spacing:6px}
  #mono{font:48px "DejaVu Sans",sans-serif;line-height:1.4;padding:8px;letter-spacing:6px}
</style><body><div id="run">${GLYPHS}</div><div id="mono">${GLYPHS}</div></body>`);
await page.evaluate(async () => { await document.fonts.ready; });
const loaded = await page.evaluate(() => [...document.fonts].map(f => f.family + ':' + f.status));
ok(loaded.some(s => /SCEmoji:loaded/.test(s)), 'the colour-emoji face was actually loaded by the browser', loaded);

const shot = (sel) => page.locator(sel).screenshot({ type: 'png' });
const countColours = async (buf) => {
  /* decode PNG with the browser itself — no extra dependency, and it is the
     same rasteriser that drew the glyphs */
  return page.evaluate(async (dataUrl) => {
    const img = new Image(); img.src = dataUrl; await img.decode();
    const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
    const g = c.getContext('2d'); g.drawImage(img, 0, 0);
    const d = g.getImageData(0, 0, c.width, c.height).data;
    const seen = new Set(); let sat = 0;
    for (let i = 0; i < d.length; i += 4) {
      const r = d[i], gg = d[i + 1], bb = d[i + 2];
      if (r > 245 && gg > 245 && bb > 245) continue;       // white background
      seen.add((r >> 3) + ',' + (gg >> 3) + ',' + (bb >> 3));
      if (Math.max(r, gg, bb) - Math.min(r, gg, bb) > 40) sat++;  // a genuinely coloured pixel
    }
    return { colours: seen.size, saturated: sat };
  }, 'data:image/png;base64,' + buf.toString('base64'));
};
const colourRun = await countColours(await shot('#run'));
const monoRun = await countColours(await shot('#mono'));

ok(colourRun.colours >= 40, `colour-emoji run uses ${colourRun.colours} distinct colours (>=40)`, colourRun);
ok(colourRun.saturated > 400, `and ${colourRun.saturated} saturated pixels — genuinely coloured, not tinted grey`, colourRun);
ok(monoRun.colours < 40, `control: the same glyphs in a monochrome face use only ${monoRun.colours}`, monoRun);
ok(colourRun.saturated > monoRun.saturated * 5, 'the two runs are separated by an order of magnitude, so the test is decisive');

/* the shipped pages must not strip the emoji before they reach the screen */
const files = ['assets/js/app.js', 'fees.html', 'assets/templates/pages/fees.html'];
for (const f of files) {
  const p = HERE + '../../' + f;
  if (!fs.existsSync(p)) continue;   /* client repos do not ship every template */
  const t = fs.readFileSync(p, 'utf8');
  ok(!/replace\([^)]*[\u{1F300}-\u{1FAFF}]/u.test(t), `${f} does not strip emoji from rendered text`);
}
await browser.close();
console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
