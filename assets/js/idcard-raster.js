/* ==========================================================================
   School Connect — V12.79 idcard-raster.js
   THE CARD THAT IS DOWNLOADED IS THE CARD THAT IS ON SCREEN.

   The complaint this file exists to end: pick "Aurora", see Aurora in the
   preview, press Download PDF — and get a file drawn by a *different* renderer
   (a generic navy/QR layout), because the PDF engine was given plain data and
   painted its own idea of a card. Two renderers, two ideas, one disappointed
   school.

   There is now one renderer. This module photographs the REAL card — the same
   markup Super.idcard gives the preview, in the same styles, at the same
   physical size — into a canvas at print resolution. The PDF engine then places
   that picture inside the card's exact millimetre box, so:

       preview  ===  printed card  ===  downloaded PDF  ===  HTML proof

   How the photograph is taken (and why this way):
     · the markup is mounted off-screen at its natural CSS size, so the browser
       computes exactly the layout the preview shows;
     · every <img> inside is replaced by a data URL first, because a canvas that
       has seen a cross-origin picture cannot be read back (and a blank card
       would be the result);
     · the whole face is serialised into an SVG <foreignObject>, rendered by the
       browser's own engine, and drawn onto a canvas at the requested dpi — so
       gradients, shadows, rounded corners, emoji and the QR all survive;
     · if a picture cannot be inlined (a locked Drive link, a dead URL) that one
       picture becomes a neutral placeholder and the run CONTINUES — a missing
       photo must never cost the school 147 cards.

   API (window.IDCardRaster):
     ready()                                   → boolean
     async face(person, side, opts)            → HTMLCanvasElement | null
     async capture(element, opts)              → HTMLCanvasElement | null
     mmToPx(mm, dpi)                           → integer pixels
   ========================================================================== */
(function (global) {
  'use strict';

  var DEFAULTS = { dpi: 300, quality: 0.82, maxSide: 1400, mountTimeoutMs: 1500 };

  function mmToPx(mm, dpi) { return Math.max(1, Math.round((Number(mm) || 0) / 25.4 * (dpi || DEFAULTS.dpi))); }

  function absUrl(u) {
    try { return new URL(String(u), document.baseURI).href; } catch (e) { return String(u || ''); }
  }

  /* ------------------------------------------------------------------ images */
  function blobToDataUrl(blob) {
    return new Promise(function (res) {
      var fr = new FileReader();
      fr.onload = function () { res(String(fr.result || '')); };
      fr.onerror = function () { res(''); };
      fr.readAsDataURL(blob);
    });
  }

  var _imgCache = Object.create(null);

  async function inlineOne(src) {
    if (!src) return '';
    if (src.indexOf('data:') === 0) return src;
    var url = absUrl(src);
    if (_imgCache[url] !== undefined) return _imgCache[url];
    /* Cross-origin needs CORS for a canvas read-back; same-origin always works. */
    var opts = { mode: 'cors', credentials: 'omit', cache: 'force-cache' };
    try {
      var r = await fetch(url, opts);
      if (!r.ok) throw new Error('HTTP ' + r.status);
      var b = await r.blob();
      if (!/^image\//.test(b.type || '')) throw new Error('not an image');
      var d = await blobToDataUrl(b);
      if (!d) throw new Error('unreadable');
      _imgCache[url] = d;
      return d;
    } catch (e) {
      _imgCache[url] = '';
      try { console.warn('[ID card] picture could not be embedded, a placeholder is used:', url, e && e.message); } catch (_) {}
      return '';
    }
  }

  function placeholder(w, h) {
    var c = document.createElement('canvas');
    c.width = Math.max(8, Math.round(w || 120)); c.height = Math.max(8, Math.round(h || 120));
    var x = c.getContext('2d');
    x.fillStyle = '#e2e8f0'; x.fillRect(0, 0, c.width, c.height);
    x.strokeStyle = '#94a3b8'; x.lineWidth = 2; x.strokeRect(1, 1, c.width - 2, c.height - 2);
    x.fillStyle = '#64748b'; x.font = Math.round(c.height / 5) + 'px system-ui,sans-serif';
    x.textAlign = 'center'; x.textBaseline = 'middle';
    x.fillText('photo', c.width / 2, c.height / 2);
    return c.toDataURL('image/png');
  }

  /* V12.80 — THE MISSING PHOTOGRAPHS.
     The report was exact: "the cards have no pictures of the staff or the
     students". The cause: a photo that lives on ANOTHER ORIGIN has to be read
     byte-for-byte before it can go into a canvas (a canvas that has merely
     SEEN a cross-origin picture cannot be read back), and the old loader gave
     up after one fetch of one URL — then painted a grey box with the word
     "photo" on it. Google Drive, which the page advertises, answers that fetch
     with no CORS header at all, so on a real school every Drive photo became a
     grey box.
     Now, per picture:
       · the card's own URL, then the card's documented SECOND source (every
         template writes data-alt — for a Drive link that is
         lh3.googleusercontent.com, which does allow the read),
       · each of those as fetch, then as a crossOrigin <img>, then as a plain
         <img> drawn into a canvas (same-origin needs neither);
       · and if every route fails, the card's OWN fallback is used — the
         initial-letter tile the preview shows — instead of a grey rectangle
         pretending to be a photo.
     The count is published as lastReport() so the page can tell the school
     which records are missing artwork. */
  async function inlineOneTrusted(url) {
    if (!url) return '';
    var src = absUrl(url);
    if (/^data:/i.test(src)) return src;
    if (_imgCache[src] !== undefined) return _imgCache[src];
    var got = await inlineOne(src);                 /* fetch + blob (CORS) */
    if (!got) {
      /* the same bytes through an <img>, which succeeds wherever the server
         allows the read even when fetch is blocked by an opaque redirect */
      got = await inlineViaImg(src);
    }
    _imgCache[src] = got || '';
    return got || '';
  }

  function inlineViaImg(src) {
    return new Promise(function (res) {
      var im = new Image();
      im.crossOrigin = 'anonymous';
      im.onload = function () {
        try {
          var c = document.createElement('canvas');
          c.width = im.naturalWidth || im.width; c.height = im.naturalHeight || im.height;
          if (!c.width || !c.height) return res('');
          c.getContext('2d').drawImage(im, 0, 0);
          res(c.toDataURL('image/png'));
        } catch (e) { res(''); }
      };
      im.onerror = function () { res(''); };
      im.src = src;
      setTimeout(function () { res(''); }, DEFAULTS.mountTimeoutMs * 2);
    });
  }

  var _lastReport = { inlined: 0, missing: 0, items: [] };
  function lastReport() { return _lastReport; }

  /* the markup's own fallback, exactly: a picture that cannot be embedded
     reveals the initial-letter tile the template put beside it */
  function dropImage(img, why) {
    var sib = img.nextElementSibling;
    img.removeAttribute('data-alt');
    img.style.display = 'none';
    if (sib && sib.style) { sib.style.display = 'flex'; return true; }
    return false;
  }

  async function inlineImages(root) {
    var imgs = [].slice.call(root.querySelectorAll('img'));
    var inlined = 0, missing = 0, items = [];
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var src = img.getAttribute('src') || '';
      var alt = img.getAttribute('data-alt') || '';
      var data = await inlineOneTrusted(src);
      if (!data && alt) data = await inlineOneTrusted(alt);
      if (data) {
        img.setAttribute('src', data);
        img.removeAttribute('srcset');
        img.removeAttribute('loading');
        img.removeAttribute('data-alt');
        inlined++;
      } else {
        var kept = dropImage(img, 'unreadable');
        if (!kept) {
          var w = img.getAttribute('width') || img.clientWidth || 120;
          var h = img.getAttribute('height') || img.clientHeight || 120;
          img.setAttribute('src', placeholder(Number(w), Number(h)));
          img.style.display = '';
        }
        missing++;
        items.push({ src: src, alt: alt, kept: kept });
        try { console.warn('[ID card] a picture could not be embedded:', src); } catch (_) {}
      }
    }
    _lastReport = { inlined: inlined, missing: missing, items: items };
    return imgs.length;
  }

  function waitImages(root) {
    var imgs = [].slice.call(root.querySelectorAll('img'));
    return Promise.all(imgs.map(function (i) {
      if (i.complete && i.naturalWidth) return Promise.resolve();
      return new Promise(function (res) {
        var done = function () { res(); };
        i.addEventListener('load', done, { once: true });
        i.addEventListener('error', done, { once: true });
        setTimeout(done, DEFAULTS.mountTimeoutMs);
      });
    }));
  }

  /* ------------------------------------------------------------------ styles */
  /* The card is drawn by the browser, so the browser needs the page's rules.
     Same-origin sheets are readable; a sheet that throws (a cross-origin one)
     is skipped rather than breaking the run. */
  function pageStyles() {
    var out = [];
    for (var i = 0; i < document.styleSheets.length; i++) {
      var sheet = document.styleSheets[i];
      try {
        var rules = sheet.cssRules;
        if (!rules) continue;
        for (var j = 0; j < rules.length; j++) out.push(rules[j].cssText);
      } catch (e) { /* cross-origin sheet — not needed for the card */ }
    }
    return out.join('\n');
  }

  /* A design that uses its own typeface must keep it in the photograph.
     An SVG rendered from a data: URL has no base URL, so every relative font
     or picture reference inside the copied CSS dies and the card comes back in
     a fallback font — the text then wraps differently from the preview, which
     is exactly the kind of "the download is not what I saw" that started this
     round. Every url(...) in the stylesheet is therefore fetched once and
     embedded as a data URL before the card is drawn. */
  var _cssUrlCache = Object.create(null);

  async function inlineCssUrls(css) {
    if (!css) return css;
    var re = /url\(\s*(['"]?)([^'")]+)\1\s*\)/gi, m, jobs = [], seen = Object.create(null);
    while ((m = re.exec(css))) {
      var raw = String(m[2] || '').trim();
      if (!raw || /^data:/i.test(raw) || /^blob:/i.test(raw) || raw.charAt(0) === '#') continue;
      var url = absUrl(raw);
      if (seen[url]) continue;
      seen[url] = 1; jobs.push(url);
    }
    if (!jobs.length) return css;
    await Promise.all(jobs.map(async function (url) {
      if (_cssUrlCache[url] !== undefined) return;
      try {
        var r = await fetch(url, { mode: 'cors', credentials: 'omit', cache: 'force-cache' });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        var b = await r.blob();
        _cssUrlCache[url] = await blobToDataUrl(b);
      } catch (e) {
        _cssUrlCache[url] = '';
        try { console.warn('[ID card] a style resource could not be embedded:', url, e && e.message); } catch (_) {}
      }
    }));
    return css.replace(re, function (whole, q, raw) {
      var url = absUrl(String(raw || '').trim());
      var data = _cssUrlCache[url];
      return data ? 'url("' + data + '")' : whole;
    });
  }

  /* --------------------------------------------------------------- capture */
  /* WHY THIS IS NOT A PLAIN element.cloneNode() PHOTOGRAPH.
     The preview does not scale the design with fonts or percentages; it draws
     the design at its own natural pixel size and shrinks it with a CSS
     `transform: scale()` (see Super.idcard.fitFace). A CSS transform survives on
     screen, but Chromium does NOT apply it while rasterising an SVG
     <foreignObject> — the design comes back at full size and the card is a
     zoomed-in crop of its top-left corner. That was the "downloaded card looks
     nothing like the preview" report, in a second disguise.

     So the design is photographed at its NATURAL size (no transform anywhere),
     and the scaling is done afterwards by the canvas itself, using the very
     same offset and factor the preview used. The result is the preview, pixel
     for pixel, at print resolution. */
  function parseScale(styleText) {
    var m = String(styleText || '').match(/transform\s*:\s*scale\(\s*([\d.]+)\s*\)/i);
    return m ? parseFloat(m[1]) : 0;
  }
  function pxOf(styleText, prop) {
    var m = String(styleText || '').match(new RegExp('(?:^|;)\\s*' + prop + '\\s*:\\s*(-?[\\d.]+)px', 'i'));
    return m ? parseFloat(m[1]) : null;
  }

  async function capture(el, opts) {
    opts = opts || {};
    if (!el) { console.warn('[ID card] nothing to photograph'); return null; }

    /* where is the design itself, and how did the preview shrink it? */
    var scaleEl = el.classList && el.classList.contains('sc-idcard-scale')
      ? el : el.querySelector('.sc-idcard-scale');
    var root = scaleEl || el;
    var rootStyle = root.getAttribute('style') || '';
    var natW = pxOf(rootStyle, 'width')  || root.offsetWidth  || el.offsetWidth;
    var natH = pxOf(rootStyle, 'height') || root.offsetHeight || el.offsetHeight;
    var left = pxOf(rootStyle, 'left') || 0;
    var top  = pxOf(rootStyle, 'top')  || 0;
    var k = parseScale(rootStyle);
    if (!k && scaleEl) {
      var rr = root.getBoundingClientRect(), er = el.getBoundingClientRect();
      k = natW ? rr.width / natW : 1;
      if (!k || !isFinite(k)) k = er.width / natW || 1;
    }
    if (!k || !isFinite(k) || k <= 0) { k = 1; left = 0; top = 0; }

    /* the face's own box: this is what the card measures on screen */
    var boxW = Math.max(1, Math.round(el.offsetWidth  || natW * k));
    var boxH = Math.max(1, Math.round(el.offsetHeight || natH * k));
    var faceBg = '#ffffff';
    try { faceBg = getComputedStyle(el).backgroundColor || '#ffffff'; } catch (e) {}

    /* the pixels we want: the card's real size in millimetres at the given dpi,
       capped so a 147-card run cannot exhaust the tab's memory */
    var dpi = opts.dpi || DEFAULTS.dpi;
    var targetW = opts.widthMm  ? mmToPx(opts.widthMm,  dpi) : Math.round(boxW * (opts.scale || 1));
    var targetH = opts.heightMm ? mmToPx(opts.heightMm, dpi) : Math.round(boxH * (opts.scale || 1));
    var cap = Math.min(1, (opts.maxSide || DEFAULTS.maxSide) / Math.max(targetW, targetH));
    targetW = Math.max(1, Math.round(targetW * cap));
    targetH = Math.max(1, Math.round(targetH * cap));
    var perCss = targetW / boxW;                       /* device px per CSS px */

    /* photographic quality ceiling: a 300 dpi card from a 4x source is enough */
    var srcScale = Math.min(4, Math.max(1, perCss * k));

    var clone = root.cloneNode(true);
    clone.removeAttribute('id');
    [].slice.call(clone.querySelectorAll('[id]')).forEach(function (n) { n.removeAttribute('id'); });
    [].slice.call(clone.querySelectorAll('script,link')).forEach(function (n) { if (n.parentNode) n.parentNode.removeChild(n); });
    /* no transform anywhere: the canvas applies the scale, not CSS */
    clone.style.transform = 'none';
    clone.style.transformOrigin = 'top left';
    clone.style.position = 'static';
    clone.style.left = '0'; clone.style.top = '0';
    clone.style.width = natW + 'px';
    clone.style.height = natH + 'px';
    clone.style.margin = '0';

    var css = await inlineCssUrls(pageStyles());
    var xml = new XMLSerializer().serializeToString(clone);
    var srcW = Math.max(1, Math.round(natW * srcScale));
    var srcH = Math.max(1, Math.round(natH * srcScale));
    var svg =
      '<svg xmlns="http://www.w3.org/2000/svg" width="' + srcW + '" height="' + srcH + '"' +
      ' viewBox="0 0 ' + natW + ' ' + natH + '">' +
      '<foreignObject x="0" y="0" width="' + natW + '" height="' + natH + '">' +
      '<div xmlns="http://www.w3.org/1999/xhtml" style="width:' + natW + 'px;height:' + natH + 'px;overflow:hidden">' +
      (css ? '<style>' + css.replace(/<\/style/gi, '<\\/style') + '</style>' : '') +
      xml + '</div></foreignObject></svg>';

    var url = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
    var img = new Image();
    img.decoding = 'sync';
    await new Promise(function (res, rej) {
      img.onload = function () { res(); };
      img.onerror = function () { rej(new Error('the browser could not draw the card')); };
      img.src = url;
      setTimeout(function () { res(); }, 8000);          /* never hang a 147-card run */
    });
    if (!img.naturalWidth) { console.warn('[ID card] the drawing came back empty', { sw: natW, sh: natH, srcW: srcW, srcH: srcH }); return null; }

    var canvas = document.createElement('canvas');
    canvas.width = targetW; canvas.height = targetH;
    var ctx = canvas.getContext('2d', { alpha: false });
    ctx.fillStyle = faceBg || '#ffffff';
    ctx.fillRect(0, 0, targetW, targetH);
    try {
      /* the preview's own framing: design scaled by k, at (left, top) in the face */
      ctx.drawImage(img, left * perCss, top * perCss,
                    natW * k * perCss, natH * k * perCss);
    } catch (e) {
      console.warn('[ID card] the card could not be read back', e && e.message);
      return null;
    }
    return canvas;
  }

  /* THE PAIR, RENDERED ONCE — and then photographed.
     The preview does not render a front and a back independently: it calls
     Super.idcard.pairHtml(), which measures the design ONCE and gives both
     faces the same canvas and the same scale, so a card and its back are one
     physical object. Re-rendering the faces separately for the PDF produced a
     different canvas for each, and a design that paints its own height (the
     serif "heritage" design, among others) then came out laid out differently
     from the preview. Printing that pair is printing a different card.

     So the PDF now renders the SAME pair, at print resolution, and photographs
     it. One renderer, one measurement, one card. */
  /* V12.80 — LAY THE CARD OUT AT THE SIZE THE PREVIEW LAID IT OUT AT.
     The pair used to be mounted at 300 dpi (85.6 mm = 1011 px) and then
     photographed. A template sets its type, its photo box and its QR in
     PIXELS, so re-rendering it on a canvas three times wider is a DIFFERENT
     LAYOUT, not a bigger one: the same 14 px line of text fills a third of the
     card, rows stop where they stopped, and the rest of the card comes out
     empty — while the preview on screen had been laid out at 96 dpi (324 px)
     and looked full. "The downloaded card is not the card I saw" for the third
     time in three releases, this time in the artwork rather than the design.
     The card is therefore mounted at exactly the CSS pixel size the preview
     uses, and the resolution comes from the SVG rasteriser (capture() scales
     the drawing up to the requested dpi), so the LAYOUT is the preview's and
     only the pixel density changes. */
  var CSS_DPI = 96;             /* the size the preview lays the card out at */

  async function pair(person, opts) {
    opts = opts || {};
    var S = global.Super && global.Super.idcard;
    if (!S || !S.pairHtml) return null;
    var mmW = Number(opts.widthMm) || 85.6;
    var mmH = Number(opts.heightMm) || 53.98;
    var dpi = Number(opts.dpi) || DEFAULTS.dpi;

    var natW = mmToPx(mmW, CSS_DPI);
    var natH = mmToPx(mmH, CSS_DPI);
    var faceOpts = Object.assign({}, opts.faceOpts || {}, {
      widthMm: mmW, heightMm: mmH, widthPx: natW, heightPx: natH
    });

    var html = '';
    try { html = S.pairHtml(person, faceOpts); } catch (e) { html = ''; }
    if (!html) return null;

    var host = document.createElement('div');
    host.setAttribute('aria-hidden', 'true');
    host.style.cssText = 'position:fixed;left:-100000px;top:0;width:' + natW + 'px;height:' +
      (natH * 2 + 40) + 'px;overflow:hidden;background:#fff;z-index:-1';
    host.innerHTML = html;
    document.body.appendChild(host);
    try {
      await waitImages(host);
      await inlineImages(host);
      await waitImages(host);
      var faces = [].slice.call(host.querySelectorAll('.sc-idcard-face'));
      if (!faces.length) faces = [].slice.call(host.querySelectorAll('.sc-idcard'));
      if (!faces.length) return null;
      var shots = { front: null, back: null };
      for (var i = 0; i < faces.length && i < 2; i++) {
        var side = (faces[i].getAttribute('data-face') || (i === 0 ? 'front' : 'back')).toLowerCase();
        if (side !== 'front' && side !== 'back') side = i === 0 ? 'front' : 'back';
        if (shots[side]) continue;
        shots[side] = await capture(faces[i], {
          widthMm: mmW, heightMm: mmH, dpi: dpi, maxSide: opts.maxSide || DEFAULTS.maxSide
        });
      }
      return shots;
    } finally {
      host.remove();
    }
  }

  /* Render ONE face of ONE person exactly as the preview does, then photograph
     it. Kept for the single-face callers (a preview thumbnail, the "print this
     one" path); it goes through pair() so it can never drift from it. */
  async function face(person, side, opts) {
    var both = await pair(person, opts);
    if (!both) return null;
    return side === 'back' ? both.back : both.front;
  }

  global.IDCardRaster = {
    ready: function () { return !!(global.Super && global.Super.idcard && global.Super.idcard.frontFace); },
    mmToPx: mmToPx,
    face: face,
    pair: pair,
    capture: capture,
    inlineImages: inlineImages,
    lastReport: lastReport,
    DEFAULTS: DEFAULTS
  };
})(window);
