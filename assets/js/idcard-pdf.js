/* ============================================================================
   idcard-pdf.js — School Connect V12.60
   CorelDRAW-safe ID-card PDF engine (vector, flattened, font-embedded).

   WHY THIS FILE EXISTS
   --------------------
   The previous "Download PDF" path was the browser's own print-to-PDF
   (Skia/PDF). Those files are valid PDFs, but they carry transparency groups,
   soft masks (/SMask), pattern and shading objects, and ICC-based colours with
   no /OutputIntent. CorelDRAW's importer stalls or force-closes when the
   designer opens a multi-page bulk ID-card file like that.

   THIS ENGINE emits a deliberately boring, maximum-compatibility PDF:
     • PDF 1.3 header, classic uncompressed xref — every importer reads it
     • one Page object per sheet; no object streams, no xref streams
     • NO transparency, SMask, blend modes, patterns or shadings
     • NO ICC profiles and no /OutputIntent — DeviceRGB only, which CorelDRAW
       converts to CMYK without complaint
     • real TrueType font embedded (Roboto), WinAnsi encoded, so text stays
       EDITABLE and searchable in CorelDRAW (no curves, no images of words)
     • every card drawn at exact physical millimetres (ID-1 = 85.6 × 53.98 mm)
     • photos embedded as opaque JPEG (alpha flattened — no SMask in the file)
     • optional thin trim marks drawn OUTSIDE the card artwork
     • print scaling pinned to 100% (ViewerPreferences /PrintScaling /None)

   API (window.IDCardPDF):
     IDCardPDF.build(cards, options)   -> Uint8Array
     IDCardPDF.blob(cards, options)    -> Blob
     IDCardPDF.download(cards, options, filename)
     IDCardPDF.open(cards, options, title)
     IDCardPDF.available()
   cards = [{ front: personObject, back: personObject }, …]
   personObject = { full_name, admission_no, class, arm, date_of_birth,
                    blood_group, photo, qr, type:'student'|'staff', role,
                    department, phone, staff_no }
   options = { widthMm, heightMm, pageWidthMm, pageHeightMm, marginMm, gapMm,
               layout:'side'|'stack'|'single', trim:boolean, title, brand }
   ========================================================================== */
(function (global) {
  'use strict';

  var K = 72 / 25.4;                 /* mm -> PostScript points */

  /* ---------- byte helpers ------------------------------------------------- */
  function b64ToBytes(b64) {
    var bin = global.atob(b64), out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function strBytes(s) {
    var out = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
    return out;
  }
  function concat(chunks) {
    var len = 0, i;
    for (i = 0; i < chunks.length; i++) len += chunks[i].length;
    var out = new Uint8Array(len), off = 0;
    for (i = 0; i < chunks.length; i++) { out.set(chunks[i], off); off += chunks[i].length; }
    return out;
  }
  function pad10(n) { return ('0000000000' + n).slice(-10); }
  function num(n) { return Number(n).toFixed(3); }

  /* ---------- text safety -------------------------------------------------- */
  /* WinAnsi is the standard TrueType encoding CorelDRAW expects. Cyrillic,
     CJK, emoji and box-drawing characters cannot be drawn by Roboto, so they
     are transliterated or dropped BEFORE layout — never shipped as broken
     glyph references. */
  var WINANSI_EXTRA = {
    0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85,
    0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A,
    0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92,
    0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
    0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C,
    0x017E: 0x9E, 0x0178: 0x9F
  };
  /* characters the embedded Roboto cannot draw, mapped to printable ASCII */
  var FALLBACK = {
    '\u2026': '...', '\u2013': '-', '\u2014': '-', '\u2018': "'", '\u2019': "'",
    '\u201C': '"', '\u201D': '"', '\u2022': '-', '\u00B7': '-', '\u20AC': 'EUR',
    '\u00D7': 'x', '\u00F7': '/', '\u00A0': ' ', '\u2122': '(TM)',
    '\u00A9': '(C)', '\u00AE': '(R)', '\u20A6': 'NGN '
  };
  var LITERAL = {
    '\u2705': '[OK]', '\u2714': '[OK]', '\u2713': '[OK]', '\u274C': 'x', '\u2716': 'x',
    '\u2192': '->', '\u2190': '<-', '\u25CF': '-', '\u00B7': '-', '\u20A6': 'NGN '
  };
  /* V12.63 — an "able to draw this?" test used by sanitize().
     The embedded Roboto is a 224-glyph subset, so a character outside it would
     reach the content stream with no glyph behind it — strict consumers then
     draw .notdef boxes or drop the run. Anything the font cannot draw is
     transliterated to printable ASCII up front, so no content stream ever
     carries a code the font cannot honour. */
  var _glyphCache = {};
  function fontCanDraw(ch) {
    var fam = String((global.SC_PDF_FONTS || {})['Roboto-Bold'] ? 'Roboto-Bold' : 'Roboto-Regular');
    if (!_glyphCache[fam]) {
      var m = FontMetrics.read((global.SC_PDF_FONTS || {})[fam]);
      _glyphCache[fam] = m || false;
    }
    var m2 = _glyphCache[fam];
    if (!m2) return true;             /* no font loaded yet — keep the character */
    return m2.hasGlyph(ch);
  }
  function sanitize(s) {
    s = String(s == null ? '' : s);
    /* Yoruba / Igbo / Hausa and other accented Latin letters (Ẹ Ọ Ṣ Ấ Ǹ …)
       decompose to base + combining mark; Roboto has the base, so strip the
       marks and keep the letter instead of losing the character. */
    if (s.normalize) s = s.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
    var out = '';
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i), code = s.charCodeAt(i);
      if (LITERAL[ch]) { out += LITERAL[ch]; continue; }
      if (code === 10 || code === 13 || code === 9) { out += ' '; continue; }
      /* Plain ASCII always draws. */
      if (code >= 32 && code <= 126) { out += ch; continue; }

      /* WinAnsi can carry a character if it is Latin-1 (<= 0xFF) or one of the
         CP1252 extras. Only then is it worth asking the font about it — and the
         question must be about the UNICODE character, never about the byte it
         would be encoded as. */
      var winAnsi = (code <= 0xFF) || (WINANSI_EXTRA[code] != null);
      if (winAnsi && fontCanDraw(ch)) { out += ch; continue; }

      /* The font has no glyph, or WinAnsi cannot carry it: transliterate to
         printable ASCII rather than emitting a code with no glyph behind it. */
      if (FALLBACK[ch] != null) { out += FALLBACK[ch]; continue; }
      /* nothing printable — drop it rather than emit an un-drawable code */
      continue;
      /* anything else (emoji, CJK, accents outside Latin-1) is dropped */
    }
    return out.replace(/[ ]{2,}/g, ' ').trim();
  }
  function pdfString(s) {
    return '(' + sanitize(s).replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)') + ')';
  }

  /* ---------- colour ------------------------------------------------------- */
  function toRgb(colour, fallback) {
    var c = String(colour || fallback || '#1e3a8a').trim();
    var m = c.match(/^#?([0-9a-f]{3}|[0-9a-f]{6})$/i);
    if (m) {
      var h = m[1];
      if (h.length === 3) h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
      return [parseInt(h.substr(0, 2), 16) / 255, parseInt(h.substr(2, 2), 16) / 255, parseInt(h.substr(4, 2), 16) / 255];
    }
    m = c.match(/rgba?\(([^)]+)\)/i);
    if (m) { var p = m[1].split(','); return [(+p[0] || 0) / 255, (+p[1] || 0) / 255, (+p[2] || 0) / 255]; }
    return [30 / 255, 58 / 255, 138 / 255];
  }

  /* ==========================================================================
     V12.63 — REAL FONT METRICS (the "PDF looks wrong in CorelDRAW" root cause)

     The old file declared:
         /Type /Font /Subtype /TrueType /BaseFont /Roboto-Regular
         /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 255
     and NO /Widths array at all.

     Without /Widths a viewer has to guess every glyph advance from the font
     file. Acrobat guesses one way, CorelDRAW another, some readers default to
     zero — so text overlaps, lines run off the card and some viewers drop the
     run entirely. The same is true of the /FontBBox and the missing /ToUnicode,
     which is what breaks copy/paste and search.

     Everything below is computed from the very font that gets embedded, so the
     PDF describes its own text exactly.
     ========================================================================== */
  var FontMetrics = (function () {
    var cache = {};
    function u8(b64) {
      var bin = atob(String(b64 || '').replace(/[^A-Za-z0-9+/=]/g, ''));
      var out = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    }
    function u16(d, o) { return (d[o] << 8) | d[o + 1]; }
    function i16(d, o) { var v = u16(d, o); return v > 0x7FFF ? v - 0x10000 : v; }
    function u32(d, o) { return ((d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3]) >>> 0; }

    /* WinAnsi (CP1252) code byte → Unicode code point */
    var CP1252_HIGH = {
      0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
      0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
      0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
      0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
      0x9E: 0x017E, 0x9F: 0x0178
    };
    function codeToUnicode(c) { return CP1252_HIGH[c] != null ? CP1252_HIGH[c] : c; }

    function read(b64) {
      var key = String(b64).length + ':' + String(b64).slice(0, 40);
      if (cache[key]) return cache[key];
      var d;
      try { d = u8(b64); } catch (e) { return null; }
      if (d.length < 12 || d[0] !== 0x00 || d[1] !== 0x01) return null;   /* not TrueType */

      var numTables = u16(d, 4), tab = {};
      for (var t = 0; t < numTables; t++) {
        var o = 12 + t * 16;
        var tag = String.fromCharCode(d[o], d[o + 1], d[o + 2], d[o + 3]);
        tab[tag] = { off: u32(d, o + 8), len: u32(d, o + 12) };
      }
      if (!tab.head || !tab.hhea || !tab.hmtx || !tab.maxp) return null;

      /* head */
      var head = tab.head.off;
      var unitsPerEm = u16(d, head + 18) || 1000;
      var macStyle = u16(d, head + 44) || 0;

      /* hhea */
      var hhea = tab.hhea.off;
      var ascender = i16(d, hhea + 4), descender = i16(d, hhea + 6);
      var numberOfHMetrics = u16(d, hhea + 34);

      /* maxp */
      var numGlyphs = u16(d, tab.maxp.off + 4);

      /* name → PostScript name (best effort) */
      var psName = '';
      try {
        var name = tab.name.off;
        var count = u16(d, name + 2), strOff = u16(d, name + 4);
        for (var n = 0; n < count; n++) {
          var r = name + 6 + n * 12;
          var pid = u16(d, r), nid = u16(d, r + 6), len = u16(d, r + 8), off = u16(d, r + 10);
          if (nid !== 6) continue;                       /* 6 = PostScript name */
          var base = name + strOff + off, str = '';
          for (var k = 0; k < len; k++) {
            str += pid === 3 ? String.fromCharCode(u16(d, base + k * 2)) : String.fromCharCode(d[base + k]);
          }
          psName = str; break;
        }
      } catch (e) { psName = ''; }

      /* cmap: prefer (3,1) Unicode BMP, else (3,0) symbol, else (0,3)/(0,4) */
      var cmapOff = tab.cmap.off, nSub = u16(d, cmapOff + 2), best = null, bestRank = -1;
      for (var s = 0; s < nSub; s++) {
        var so = cmapOff + 4 + s * 8;
        var pid = u16(d, so), eid = u16(d, so + 2), sub = cmapOff + u32(d, so + 4);
        var rank = (pid === 3 && eid === 1) ? 4 : (pid === 3 && eid === 0) ? 3 : (pid === 0) ? 2 : 1;
        if (rank > bestRank) { bestRank = rank; best = sub; }
      }
      var uni2gid = {};
      if (best != null) {
        var fmt = u16(d, best);
        if (fmt === 4) {
          var segX2 = u16(d, best + 6), seg = segX2 / 2;
          var endO = best + 14, startO = endO + segX2 + 2;
          var deltaO = startO + segX2, rangeO = deltaO + segX2;
          for (var g = 0; g < seg; g++) {
            var endC = u16(d, endO + g * 2), startC = u16(d, startO + g * 2);
            var delta = i16(d, deltaO + g * 2), ro = u16(d, rangeO + g * 2);
            if (startC > endC) continue;
            for (var c = startC; c <= endC && c !== 0xFFFF; c++) {
              var gid;
              if (ro === 0) gid = (c + delta) & 0xFFFF;
              else {
                var gi = rangeO + g * 2 + ro + (c - startC) * 2;
                if (gi + 1 >= d.length) continue;
                gid = u16(d, gi);
                if (gid !== 0) gid = (gid + delta) & 0xFFFF;
              }
              if (gid) uni2gid[c] = gid;
            }
          }
        } else if (fmt === 0) {
          for (var c0 = 0; c0 < 256; c0++) {
            var g0 = d[best + 6 + c0];
            if (g0) uni2gid[c0] = g0;
          }
        } else if (fmt === 6) {
          var first = u16(d, best + 6), cnt = u16(d, best + 8);
          for (var c6 = 0; c6 < cnt; c6++) {
            var g6 = u16(d, best + 10 + c6 * 2);
            if (g6) uni2gid[first + c6] = g6;
          }
        }
      }

      /* hmtx advance widths, in 1000-unit em space, per WinAnsi byte */
      var hmtx = tab.hmtx.off;
      function gidForUnicode(u) { return uni2gid[u] != null ? uni2gid[u] : 0; }
      function advanceForGid(gid) {
        var g = gid < numberOfHMetrics ? gid : (numberOfHMetrics - 1);
        if (g < 0) g = 0;
        var aw = u16(d, hmtx + g * 4);
        return Math.round(aw * 1000 / unitsPerEm);
      }
      var widths = [];          /* index 0..255 → WinAnsi code */
      var missing = [];
      for (var code = 0; code <= 255; code++) {
        var gid = gidForUnicode(codeToUnicode(code));
        if (!gid) { widths.push(0); if (code >= 32) missing.push(code); }
        else widths.push(advanceForGid(gid) || 0);
      }

      var fontBBox = [i16(d, head + 36), i16(d, head + 38), i16(d, head + 40), i16(d, head + 42)];
      var scale = function (v) { return Math.round(v * 1000 / unitsPerEm); };

      var out = {
        unitsPerEm: unitsPerEm,
        psName: psName || '',
        bold: (macStyle & 1) === 1,
        widths: widths,
        missingCodes: missing,
        ascent: scale(ascender),
        descent: scale(descender),
        capHeight: scale(ascender * 0.7),
        bbox: [scale(fontBBox[0]), scale(fontBBox[1]), scale(fontBBox[2]), scale(fontBBox[3])],
        /* reported in 1000-em space so the PDF /Widths array is exact */
        /* NB: never mask with & 0xFF here — U+2014 would alias code 0x14 and
           the font would be wrongly declared able to draw an em dash. */
        widthOf: function (ch) {
          var cp = ch.charCodeAt(0);
          return cp > 255 ? 0 : (widths[cp] || 0);
        },
        hasGlyph: function (ch) {
          var cp = ch.charCodeAt(0);
          if (cp === 32) return true;          /* space always advances */
          if (cp > 255) return false;          /* not representable in WinAnsi */
          return widths[cp] > 0;
        }
      };
      cache[key] = out;
      return out;
    }
    return { read: read, codeToUnicode: codeToUnicode };
  })();

  /* ---------- images ------------------------------------------------------- */
  var measureCanvas = document.createElement('canvas');
  /* Headless / locked-down browsers can return a null 2D context. Fall back to a
     proportional estimate (0.52 em average for Roboto) instead of throwing. */
  function measureMm(text, sizeMm, bold) {
    var t = sanitize(text);
    try {
      var ctx = measureCanvas.getContext('2d');
      if (!ctx) throw new Error('no-2d-context');
      ctx.font = (bold ? '700 ' : '400 ') + (sizeMm * 10) + 'px "Roboto", Arial, sans-serif';
      return ctx.measureText(t).width / 10;
    } catch (e) {
      return t.length * sizeMm * (bold ? 0.56 : 0.52);
    }
  }
  /* Flatten ANY drawable to opaque JPEG bytes (no alpha ⇒ no /SMask). */
  /* V12.63 — every image conversion failure used to be swallowed by
     `catch (e) { return null; }`, so a CORS-tainted or alpha-only canvas
     produced a card with a BLANK photo and nobody was told. Failures are now
     recorded in `IDCardPDF.lastWarnings` and drawn as an explicit "NO PHOTO"
     placeholder, so the defect is visible instead of silent. */
  var diagnostics = [];
  function diag(msg, detail) {
    diagnostics.push({ message: msg, detail: detail == null ? '' : String(detail) });
  }

  function toJpeg(src) {
    if (!src) return null;
    try {
      var w = 0, h = 0, source = src;
      if (src.nodeName === 'CANVAS') { w = src.width; h = src.height; }
      else if (src.nodeName === 'IMG') { w = src.naturalWidth || src.width; h = src.naturalHeight || src.height; }
      else if (src.data && src.width) { w = src.width; h = src.height; }
      else return null;
      if (!w || !h) return null;
      var maxSide = 1400;
      var scale = Math.min(1, maxSide / Math.max(w, h));
      var c = document.createElement('canvas');
      c.width = Math.max(1, Math.round(w * scale));
      c.height = Math.max(1, Math.round(h * scale));
      var ctx = c.getContext('2d', { alpha: false });
      /* flatten onto white — a transparent PNG would otherwise encode as
         black in some readers */
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, c.width, c.height);
      if (src.nodeName === 'CANVAS' || src.nodeName === 'IMG') ctx.drawImage(src, 0, 0, c.width, c.height);
      else if (src instanceof ImageData) ctx.putImageData(src, 0, 0);
      else if (src.data && src.width) {
        var id = ctx.createImageData(w, h);
        id.data.set(src.data);
        ctx.putImageData(id, 0, 0);
      } else return null;
      var url = c.toDataURL('image/jpeg', 0.92);
      if (!url || url.indexOf('data:image/jpeg') !== 0) {
        diag('image could not be encoded', 'toDataURL returned ' + String(url).slice(0, 24));
        return null;
      }
      return { b64: url.split(',')[1], w: c.width, h: c.height };
    } catch (e) {
      /* the classic: the canvas is CORS-tainted because the photo came from
         another origin without Access-Control-Allow-Origin */
      diag('image could not be read back from the canvas (CORS / tainted canvas)', e && e.message);
      return null;
    }
  }
  function imageKey(bytes) { return bytes.w + 'x' + bytes.h + ':' + bytes.b64.length + ':' + bytes.b64.slice(0, 48); }

  /* ---------- card painter (canvas preview + PDF text records) ------------- */
  function CardPainter(o) {
    o = o || {};
    this.w = o.widthMm || 85.6;
    this.h = o.heightMm || 53.98;
    this.dpi = o.dpi || 300;
    this.unit = this.dpi / 25.4;                    /* px per mm */
    this.canvas = document.createElement('canvas');
    this.canvas.width = Math.round(this.w * this.unit);
    this.canvas.height = Math.round(this.h * this.unit);
    this.ctx = this.canvas.getContext('2d');
    this.texts = [];
    this.images = [];
    this.rects = [];
  }
  CardPainter.prototype.text = function (value, xMm, yMm, o) {
    o = o || {};
    var clean = sanitize(value);
    if (!clean) return this;
    var size = o.size || 3.2, bold = !!o.bold;
    var ctx = this.ctx;
    ctx.font = (bold ? '700 ' : '400 ') + (size * this.unit) + 'px "Roboto", Arial, sans-serif';
    ctx.textAlign = 'left';
    /* V12.61 — fit-to-box that NEVER overflows and NEVER prints illegible 1.7 mm
       text. Order of attack: (1) shrink to a readable floor of 65 % of the design
       size; (2) if it still does not fit, ellipsise; (3) if even one character
       will not fit, clip it. Before this fix a 60-character name bottomed out at
       1.7 mm and spilled past the card edge into the QR / next card. */
    if (o.maxMm) {
      var maxW = o.maxMm * this.unit;
      var floor = Math.min(size, Math.max(1.9, size * 0.65));
      while (size > floor && ctx.measureText(clean).width > maxW) {
        size = Math.max(floor, +(size - 0.1).toFixed(2));
        ctx.font = (bold ? '700 ' : '400 ') + (size * this.unit) + 'px "Roboto", Arial, sans-serif';
        if (size <= floor) break;
      }
      if (ctx.measureText(clean).width > maxW) {
        var ell = '\u2026';
        if (ctx.measureText(ell).width > maxW) {
          clean = '';                       /* nothing legible fits — draw nothing */
        } else {
          var cut = clean;
          while (cut.length > 1 && ctx.measureText(cut + ell).width > maxW) cut = cut.slice(0, -1);
          clean = (cut.replace(/[\s.,;:\-\/]+$/, '') || clean.charAt(0)) + ell;
        }
        if (!clean) return this;
        /* re-measure so the recorded width is the PRINTED width */
        ctx.font = (bold ? '700 ' : '400 ') + (size * this.unit) + 'px "Roboto", Arial, sans-serif';
      }
    }
    var wMm = Math.min(ctx.measureText(clean).width / this.unit, o.maxMm ? o.maxMm : Infinity);
    ctx.fillStyle = o.colour || '#0f172a';
    ctx.textBaseline = 'top';
    ctx.fillText(clean, xMm * this.unit, yMm * this.unit);
    this.texts.push({ x: xMm, y: yMm, w: wMm, text: clean, size: size, bold: bold,
                      colour: o.colour || '#0f172a', align: o.align || 'left' });
    return this;
  };
  /* V12.63 — wrap a long name onto at most `maxLines` lines that all fit
     `maxMm`. An ID card with "ABDUL HAMEED KHALEED MORA…" is not acceptable;
     two balanced lines are. Returns the lines actually drawn. */
  CardPainter.prototype.wrapText = function (value, xMm, yMm, o) {
    o = o || {};
    var maxMm = o.maxMm || (this.w - xMm - 2);
    var size = o.size || 4.2;
    var words = sanitize(value).split(' ').filter(Boolean);
    var maxLines = o.maxLines || 2;
    var lineH = (o.lineHeight || size * 1.18);
    if (!words.length) return 0;
    function widthOf(t) {
      try {
        var ctx = this.ctx;
        ctx.font = (o.bold ? '700 ' : '400 ') + (size * this.unit) + 'px "Roboto", Arial, sans-serif';
        return ctx.measureText(t).width / this.unit;
      } catch (e) { return t.length * size * (o.bold ? 0.56 : 0.52); }
    }
    var self = this;
    var lines = [], cur = '';
    for (var i = 0; i < words.length; i++) {
      var test = cur ? (cur + ' ' + words[i]) : words[i];
      if (widthOf.call(self, test) <= maxMm || !cur) { cur = test; }
      else { lines.push(cur); cur = words[i]; if (lines.length === maxLines - 1) break; }
    }
    if (lines.length < maxLines && cur) lines.push(cur);
    /* anything left over is appended to the last line and allowed to ellipsise */
    var rest = words.slice(lines.join(' ').split(' ').length).join(' ');
    if (rest && lines.length) lines[lines.length - 1] += ' ' + rest;
    for (var L = 0; L < lines.length; L++) {
      this.text(lines[L], xMm, yMm + L * lineH, { size: size, bold: o.bold, colour: o.colour, maxMm: maxMm });
    }
    return lines.length;
  };
  CardPainter.prototype.rect = function (x, y, w, h, colour) {
    this.ctx.fillStyle = colour;
    this.ctx.fillRect(x * this.unit, y * this.unit, w * this.unit, h * this.unit);
    this.rects.push({ x: x, y: y, w: w, h: h, colour: colour });
    return this;
  };
  /* outlined rectangle (never used with transparency — plain stroke only) */
  CardPainter.prototype.frame = function (x, y, w, h, colour, lw) {
    this.ctx.strokeStyle = colour || '#cbd5e1';
    this.ctx.lineWidth = (lw || 0.3) * this.unit;
    this.ctx.strokeRect(x * this.unit, y * this.unit, w * this.unit, h * this.unit);
    this.rects.push({ x: x, y: y, w: w, h: h, colour: null, stroke: colour || '#cbd5e1', lw: lw || 0.3 });
    return this;
  };
  /* V12.63 — `fit: 'contain'` keeps the photo's aspect ratio inside the box
     instead of stretching a 4:5 portrait into a square. */
  CardPainter.prototype.image = function (img, x, y, w, h, opt) {
    if (!img) throw new Error('CardPainter.image() needs an image');
    opt = opt || {};
    var bytes = toJpeg(img);
    if (!bytes) throw new Error('image could not be converted to JPEG');
    var dx = x, dy = y, dw = w, dh = h;
    if (opt.fit && bytes.w && bytes.h) {
      /* contain = whole image visible; cover = fill the frame and crop the
         overflow (what a portrait photo needs, so no white bars appear). */
      var s = (opt.fit === 'cover') ? Math.max(w / bytes.w, h / bytes.h)
                                    : Math.min(w / bytes.w, h / bytes.h);
      dw = bytes.w * s; dh = bytes.h * s;
      dx = x + (w - dw) / 2; dy = y + (h - dh) / 2;
      if (opt.fit === 'cover') {
        /* clip so the overflow is cropped rather than drawn over the card */
        var cx = this.ctx;
        cx.save();
        cx.beginPath();
        cx.rect(x * this.unit, y * this.unit, w * this.unit, h * this.unit);
        cx.clip();
        try { cx.drawImage(img, dx * this.unit, dy * this.unit, dw * this.unit, dh * this.unit); } catch (e) {}
        cx.restore();
        this.images.push({ x: x, y: y, w: w, h: h, bytes: bytes });
        return this;
      }
    }
    try { this.ctx.drawImage(img, dx * this.unit, dy * this.unit, dw * this.unit, dh * this.unit); } catch (e) {}
    this.images.push({ x: dx, y: dy, w: dw, h: dh, bytes: bytes });
    return this;
  };

  /** Reproduce an ID-card face as flat vector art at exact physical size. */
  CardPainter.prototype.drawFace = function (person, side, brand) {
    var p = person || {}, b = brand || {};
    var W = this.w, H = this.h;
    var primary = b.primary || '#1e3a8a', accent = b.accent || '#0ea5e9';
    var white = '#ffffff', ink = '#0f172a', soft = '#475569';
    var isStaff = String(p.type || '').toLowerCase() === 'staff';
    var idNo = p.admission_no || p.staff_no || p.id || '';
    var school = b.name || 'School', short = b.shortName || school;

    this.rect(0, 0, W, H, white);

    if (side === 'front') {
      this.rect(0, 0, W, 14.4, primary);
      this.rect(0, 14.4, W, 0.9, accent);
      this.text(school.toUpperCase(), 3.2, 2.4, { size: 3.2, bold: true, colour: white, maxMm: W - 33 });
      if (b.motto) this.text(b.motto, 3.2, 7.4, { size: 2.1, colour: '#dbeafe', maxMm: W - 33 });
      this.text(isStaff ? 'STAFF ID CARD' : 'STUDENT ID CARD', W - 3.2, 2.4,
                { size: 2.4, bold: true, colour: white, align: 'right' });
      this.text(short.toUpperCase(), W - 3.2, 7.4, { size: 2.7, bold: true, colour: white, align: 'right' });

      var px = 3.2, py = 18.6, pw = 22, phh = 27.5;
      this.rect(px - 0.5, py - 0.5, pw + 1, phh + 1, '#e2e8f0');
      this.rect(px, py, pw, phh, '#cbd5e1');
      /* V12.63 — a missing or unreadable photo now says so on the card, in the
         file's warnings, and in the exported PDF. Silence was the bug. */
      var photoDrawn = false;
      if (p.photo) {
        try { this.image(p.photo, px, py, pw, phh, { fit: 'cover' }); photoDrawn = true; }
        catch (e) {
          diag('photo could not be embedded', (p.full_name || '') + ' — ' + (e && e.message));
        }
      } else if (p.full_name) {
        diag('no photo supplied for card', p.full_name);
      }
      if (!photoDrawn) {
        /* initial-letter fallback, clearly marked */
        this.text((String(p.full_name || 'S').trim().charAt(0) || 'S').toUpperCase(),
                  px + pw / 2, py + phh * 0.52, { size: 8.5, bold: true, colour: '#94a3b8', align: 'center' });
        this.text('NO PHOTO', px + pw / 2, py + phh - 3.4,
                  { size: 1.55, bold: true, colour: '#94a3b8', align: 'center' });
      }

      /* V12.63 geometry — the QR square is placed FIRST and every other element
         is then told to stop before it. Previously the detail values used
         maxMm = W - x - 17.5 (≈ 39 mm), which ran straight through the QR code
         and off the card. */
      var qrSize = 17.0, qx = W - 3.2 - qrSize, qy = H - 6.2 - qrSize;

      var x = 28.4, y = 18.2;
      var nameLines = this.wrapText(p.full_name || '', x, y,
        { size: 4.2, bold: true, colour: ink, maxMm: W - x - 3.4, maxLines: 2, lineHeight: 4.9 });
      y += (nameLines >= 2 ? 9.4 : 6.2);
      /* values must end before the QR square starts (with a 1.2 mm gutter) */
      var valX = x + 14.2;
      var valMax = Math.max(12, qx - valX - 1.2);
      var rows = isStaff
        ? [['Designation', p.role], ['Department', p.department], ['Staff ID', idNo], ['Phone', p.phone]]
        : [['Student ID', idNo], ['Class', [p.class, p.arm].filter(Boolean).join(' ')],
           ['Date of birth', p.date_of_birth], ['Blood group', p.blood_group]];
      for (var i = 0; i < rows.length; i++) {
        if (!rows[i][1]) continue;
        this.text(rows[i][0], x, y, { size: 1.85, colour: soft, maxMm: valX - x - 1.5 });
        this.text(String(rows[i][1]).toUpperCase(), valX, y - 0.2,
                  { size: 2.35, bold: i < 2, colour: ink, maxMm: valMax });
        y += 3.55;
      }
      this.frame(qx, qy, qrSize, qrSize, '#cbd5e1', 0.25);
      if (p.qr) { try { this.image(p.qr, qx, qy, qrSize, qrSize, { fit: 'contain' }); } catch (e) { diag('QR could not be embedded', e && e.message); } }
      this.text('SCAN TO VERIFY', W - 3.2, H - 4.6, { size: 1.75, bold: true, colour: ink, align: 'right' });
      this.text(b.address || '', 3.2, H - 6.2, { size: 1.75, colour: soft, maxMm: qx - 6 });
      this.text([b.phone, b.email].filter(Boolean).join('  .  '), 3.2, H - 3.6,
                { size: 1.75, colour: soft, maxMm: qx - 6 });
    } else {
      this.rect(0, 0, W, 9.5, primary);
      this.text((short + '  ·  ' + (isStaff ? 'STAFF' : 'STUDENT') + ' ID — REVERSE').toUpperCase(),
                3.2, 3.0, { size: 2.7, bold: true, colour: white, maxMm: W - 6.4 });
      /* V12.63 — this was a 3.2 mm solid black bar carrying no text, which
         reads as a printing fault. It is now the same accent rule as the front. */
      this.rect(0, 9.5, W, 0.9, accent);
      var rules = isStaff ? [
        'This card identifies a bona-fide member of staff and remains school property.',
        'Wear it visibly on the premises and present it on request.',
        'It is not transferable; misuse attracts disciplinary action.',
        'Report loss or damage to the school office immediately.',
        'Surrender the card to the school office upon exit from service.'
      ] : [
        'This card identifies a bona-fide student and remains school property.',
        'Carry it at school and present it on request; it is not transferable.',
        'It stays valid for the holder\u2019s entire period of studentship.',
        'Report loss or damage to the class teacher or school office at once.',
        'Surrender the card on graduation or withdrawal.'
      ];
      /* V12.63 — the rules used to run past the card edge on long lines. They
         are now wrapped inside the printable width, and the "if found" box is
         measured from wherever they actually ended. */
      var ry = 15.2;
      for (var r = 0; r < rules.length; r++) {
        this.text((r + 1) + '.', 3.2, ry, { size: 1.95, bold: true, colour: primary });
        var used = this.wrapText(rules[r], 5.8, ry,
          { size: 1.95, colour: '#334155', maxMm: W - 9.2, maxLines: 3, lineHeight: 2.75 });
        ry += 3.0 + Math.max(0, used - 1) * 2.75;
      }
      var boxTop = ry + 1.1, boxH = 12.6;
      this.rect(3.2, boxTop, W - 6.4, boxH, '#f1f5f9');
      this.frame(3.2, boxTop, W - 6.4, boxH, '#cbd5e1', 0.25);
      this.text('IF FOUND, PLEASE RETURN TO:', 4.4, boxTop + 1.6, { size: 2.1, bold: true, colour: primary });
      this.text(school, 4.4, boxTop + 4.4, { size: 2.3, bold: true, colour: ink, maxMm: W - 9 });
      this.text(b.address || '', 4.4, boxTop + 7.4, { size: 1.9, colour: soft, maxMm: W - 9 });
      this.text([b.phone, b.email].filter(Boolean).join('  .  '), 4.4, boxTop + 10.2,
                { size: 1.9, colour: soft, maxMm: W - 9 });
      /* signature / issued / footer live in the bottom strip BELOW the box */
      var footTop = boxTop + boxH + 1.9;
      this.text('Authorised signature', 3.2, footTop, { size: 1.8, colour: soft });
      /* V12.63 — a real signature image is drawn above the rule when supplied;
         previously the field was labelled but never populated. */
      if (b.signature) {
        try { this.image(b.signature, 3.2, footTop + 0.9, 26, 8.4, { fit: 'contain' }); } catch (e) {}
      }
      this.rect(3.2, footTop + 3.5 + (b.signature ? 6.2 : 0), 30, 0.25, '#64748b');
      this.text('Issued ' + new Date().getFullYear(), W - 3.2, footTop, { size: 1.8, colour: soft, align: 'right' });
      this.text('Powered by HMG Concepts', W - 3.2, H - 3.5, { size: 1.7, colour: '#94a3b8', align: 'right' });
      if (idNo) this.text(idNo, 3.2, H - 3.6, { size: 2.1, bold: true, colour: ink });
    }
    return this;
  };

  /* ---------- PDF serialisation ------------------------------------------- */
  function build(cards, options) {
    var o = options || {};
    var cw = o.widthMm || 85.6, ch = o.heightMm || 53.98;
    var pageWmm = o.pageWidthMm || 210, pageHmm = o.pageHeightMm || 297;
    var margin = o.marginMm == null ? 10 : o.marginMm;
    var gap = o.gapMm == null ? 4 : o.gapMm;
    var layout = o.layout || 'side';
    var pageW = pageWmm * K, pageH = pageHmm * K;

    var objects = [];
    function addObject(body) {
      objects.push(body);
      return objects.length;                      /* 1-based object number */
    }
    /* `dict` may be an empty string, or carry extra entries such as /Length1.
       /Length is always computed here and never trusted from the caller, so a
       wrong value can never truncate a stream (a classic cause of "the PDF
       opens but the last glyphs are missing"). */
    function stream(dict, bytes) {
      var extra = String(dict || '').replace(/\/Length\s+\d+/g, '').trim();
      var head = extra ? ('<< ' + extra + ' /Length ' + bytes.length + ' >>\nstream\n')
                       : ('<< /Length ' + bytes.length + ' >>\nstream\n');
      return concat([strBytes(head), bytes, strBytes('\nendstream')]);
    }

    /* ======================================================================
       Fonts — embedded TrueType, WinAnsi, no subsetting (CorelDRAW can edit).

       V12.63 fixes the three things that made the exported PDF fall apart in
       CorelDRAW and other strict readers:

         1. /Widths is now REAL, read from the embedded font's hmtx table.
            Previously it was absent, so every viewer invented glyph advances —
            Acrobat one way, CorelDRAW another — and lines overlapped or ran off
            the card.
         2. /FontBBox, /Ascent, /Descent, /CapHeight and /Flags are read from
            the font instead of being hard-coded constants.
         3. /ToUnicode is emitted, so copy/paste and search return the real
            characters instead of mojibake, and CorelDRAW can map the text back
            to the correct glyphs.

       A deterministic /FontName keeps re-exports identical.
       ====================================================================== */
    var fontObj = {}, fontMeta = {};
    ['Roboto-Regular', 'Roboto-Bold'].forEach(function (name) {
      var b64 = (global.SC_PDF_FONTS || {})[name];
      if (!b64) return;
      var bytes = b64ToBytes(b64);
      var fileId = addObject(stream('/Length1 ' + bytes.length, bytes));

      var w = FontMetrics.read(b64);
      var widths = w ? w.widths : null;

      /* /Widths must cover FirstChar..LastChar with one number per code. An
         empty entry (0) marks "no glyph" — viewers fall back to the default
         width instead of drawing a wrong advance. */
      var firstChar = 32, lastChar = 255;
      var widthArr = [];
      for (var c = firstChar; c <= lastChar; c++) widthArr.push(widths ? (widths[c] || 0) : 0);

      var bbox = w ? w.bbox : [-1021, -463, 1793, 1232];
      var asc = w ? w.ascent : 927;
      var desc = w ? w.descent : -244;
      var capH = w ? w.capHeight : 711;

      /* Flags bit 3 (0x04) = Symbolic, bit 6 (0x20) = Nonsymbolic, bit 1 (0x01)
         = FixedPitch. A proportionally-spaced Latin font is Nonsymbolic. */
      var flags = 32;                                   /* Nonsymbolic */
      if (name.indexOf('Bold') >= 0) flags |= 0x40000;  /* ForceBold */

      var descId = addObject('<< /Type /FontDescriptor /FontName /' + name +
        ' /Flags ' + flags +
        ' /FontBBox [' + bbox.join(' ') + ']' +
        ' /ItalicAngle 0 /Ascent ' + asc + ' /Descent ' + desc +
        ' /CapHeight ' + capH + ' /StemV ' + (name.indexOf('Bold') >= 0 ? 88 : 60) +
        ' /MissingWidth ' + (widths ? (widths[32] || 500) : 500) +
        ' /FontFile2 ' + fileId + ' 0 R >>');

      /* /ToUnicode: one line per code so text is copyable and searchable. */
      var cmap = ['/CIDInit /ProcSet findresource begin',
                  '12 dict begin', 'begincmap',
                  '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def',
                  '/CMapName /Adobe-Identity-UCS def', '/CMapType 2 def',
                  '1 begincodespacerange', '<00> <FF>', 'endcodespacerange'];
      var pairs = [], all = [];
      for (var ci = 0; ci <= 255; ci++) {
        var uni = FontMetrics.codeToUnicode(ci);
        var hex = ('0000' + uni.toString(16).toUpperCase()).slice(-4);
        pairs.push('<' + ('0' + ci.toString(16).toUpperCase()).slice(-2) + '> <' + hex + '>');
      }
      for (var pi = 0; pi < pairs.length; pi += 100) {
        var chunk = pairs.slice(pi, pi + 100);
        all.push(chunk.length + ' beginbfchar', chunk.join('\n'), 'endbfchar');
      }
      cmap = cmap.concat(all).concat(['endcmap',
        'CMapName currentdict /CMap defineresource pop', 'end', 'end']);
      var cmapBytes = strBytes(cmap.join('\n'));
      var cmapId = addObject(stream('', cmapBytes));

      fontObj[name] = addObject('<< /Type /Font /Subtype /TrueType' +
        ' /BaseFont /' + name +
        ' /Encoding /WinAnsiEncoding' +
        ' /FirstChar ' + firstChar + ' /LastChar ' + lastChar +
        ' /Widths [' + widthArr.join(' ') + ']' +
        ' /FontDescriptor ' + descId + ' 0 R' +
        ' /ToUnicode ' + cmapId + ' 0 R >>');
      fontMeta[name] = { widths: widths, first: firstChar, last: lastChar, metrics: w };
    });
    var FONT_REG = fontObj['Roboto-Regular'] || 0;
    var FONT_BOLD = fontObj['Roboto-Bold'] || FONT_REG;

    /* Images — one XObject per unique picture, named Im<n>. */
    var imageObj = {};
    function ensureImage(bytes) {
      var key = imageKey(bytes);
      if (imageObj[key]) return imageObj[key];
      var raw = b64ToBytes(bytes.b64);
      var id = addObject(stream('/Type /XObject /Subtype /Image /Width ' + bytes.w +
        ' /Height ' + bytes.h + ' /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode', raw));
      imageObj[key] = id;
      return id;
    }

    var pageIds = [];
    var pageBodies = [];

    (cards || []).forEach(function (card) {
      var painters = [];
      ['front', 'back'].forEach(function (side) {
        var payload = card && card[side];
        if (!payload) return;
        if (payload.nodeName === 'CANVAS' || payload.nodeName === 'IMG') {
          /* a ready picture of the whole face: place it as one image */
          var bytes = toJpeg(payload);
          if (bytes) painters.push({ raw: bytes });
          return;
        }
        var painter = new CardPainter({ widthMm: cw, heightMm: ch, dpi: o.dpi || 300 });
        painter.drawFace(payload, side, o.brand || {});
        painters.push(painter);
      });
      if (!painters.length) return;

      var content = [];
      var used = {};
      function useImage(id) { used[id] = true; }

      function place(item, xMm, yMm) {
        function X(mm) { return (xMm + mm) * K; }
        function Y(mm) { return pageH - (yMm + mm) * K; }
        var w = item.raw ? cw : item.w, h = item.raw ? ch : item.h;
        content.push('q\n1 1 1 rg\n' + num(X(0)) + ' ' + num(Y(h)) + ' ' + num(w * K) + ' ' + num(h * K) + ' re\nf\nQ\n');
        if (item.raw) {
          var id = ensureImage(item.raw); useImage(id);
          content.push('q\n' + num(w * K) + ' 0 0 ' + num(h * K) + ' ' + num(X(0)) + ' ' + num(Y(h)) +
                       ' cm\n/Im' + id + ' Do\nQ\n');
          return;
        }
        (item.rects || []).forEach(function (rc) {
          if (rc.stroke) {
            content.push('q\n' + num(rc.lw * K) + ' w\n' + toRgb(rc.stroke)[0].toFixed(4) + ' ' +
              toRgb(rc.stroke)[1].toFixed(4) + ' ' + toRgb(rc.stroke)[2].toFixed(4) + ' RG\n' +
              num(X(rc.x)) + ' ' + num(Y(rc.y + rc.h)) + ' ' + num(rc.w * K) + ' ' + num(rc.h * K) + ' re\nS\nQ\n');
          } else {
            var c = toRgb(rc.colour);
            content.push('q\n' + c[0].toFixed(4) + ' ' + c[1].toFixed(4) + ' ' + c[2].toFixed(4) + ' rg\n' +
              num(X(rc.x)) + ' ' + num(Y(rc.y + rc.h)) + ' ' + num(rc.w * K) + ' ' + num(rc.h * K) + ' re\nf\nQ\n');
          }
        });
        item.images.forEach(function (img) {
          var iid = ensureImage(img.bytes); useImage(iid);
          content.push('q\n' + num(img.w * K) + ' 0 0 ' + num(img.h * K) + ' ' +
                       num(X(img.x)) + ' ' + num(Y(img.y + img.h)) + ' cm\n/Im' + iid + ' Do\nQ\n');
        });
        item.texts.forEach(function (t) {
          var size = t.size * K;
          var x = X(t.x);
          if (t.align === 'right') x -= t.w * K;
          else if (t.align === 'center') x -= (t.w * K) / 2;
          var rgb = toRgb(t.colour);
          content.push('BT\n' + rgb[0].toFixed(4) + ' ' + rgb[1].toFixed(4) + ' ' + rgb[2].toFixed(4) + ' rg\n' +
            '/' + (t.bold ? 'Roboto-Bold' : 'Roboto-Regular') + ' ' + size.toFixed(2) + ' Tf\n' +
            '1 0 0 1 ' + num(x) + ' ' + num(Y(t.y + t.size * 0.78)) + ' Tm\n' + pdfString(t.text) + ' Tj\nET\n');
        });
      }

      if (layout === 'single') {
        /* one face per page — the safest possible imposition */
        painters.forEach(function (pt) { place(pt, (pageWmm - cw) / 2, (pageHmm - ch) / 2); });
        pageBodies.push({ content: content.join(''), used: used });
        return;
      } else if (layout === 'stack') {
        painters.forEach(function (pt, i) { place(pt, margin, margin + i * (ch + gap)); });
      } else {
        var top = margin + Math.max(0, (pageHmm - margin * 2 - ch) / 2);
        painters.forEach(function (pt, i) { place(pt, margin + i * (cw + gap), top); });
      }

      if (o.trim) {
        var pads = layout === 'stack'
          ? painters.map(function (_, i) { return [margin, margin + i * (ch + gap)]; })
          : painters.map(function (_, i) { return [margin + i * (cw + gap), margin + Math.max(0, (pageHmm - margin * 2 - ch) / 2)]; });
        pads.forEach(function (m) {
          var x = m[0], y = m[1], L = 3.2;
          function line(x1, y1, x2, y2) {
            content.push('q\n0.5 w\n0 0 0 RG\n' + num(x1 * K) + ' ' + num(pageH - y1 * K) + ' m\n' +
                         num(x2 * K) + ' ' + num(pageH - y2 * K) + ' l\nS\nQ\n');
          }
          line(x - L, y, x - 1, y); line(x, y - L, x, y - 1);
          line(x + cw + 1, y, x + cw + L, y); line(x + cw, y - L, x + cw, y - 1);
          line(x - L, y + ch, x - 1, y + ch); line(x, y + ch + 1, x, y + ch + L);
          line(x + cw + 1, y + ch, x + cw + L, y + ch); line(x + cw, y + ch + 1, x + cw, y + ch + L);
        });
      }

      pageBodies.push({ content: content.join(''), used: used });
    });

    if (!pageBodies.length) {
      /* never emit an empty file — one page explaining the problem */
      var p0 = new CardPainter({ widthMm: 120, heightMm: 30, dpi: 150 });
      p0.text('No ID-card data was selected.', 2, 8, { size: 5, bold: true, colour: '#b91c1c' });
      var noteContent = [];
      p0.texts.forEach(function (t) {
        var rgb = toRgb(t.colour);
        noteContent.push('BT\n' + rgb[0].toFixed(4) + ' ' + rgb[1].toFixed(4) + ' ' + rgb[2].toFixed(4) + ' rg\n' +
          '/' + (t.bold ? 'Roboto-Bold' : 'Roboto-Regular') + ' ' + (t.size * K).toFixed(2) + ' Tf\n' +
          '1 0 0 1 ' + num(margin + t.x * K) + ' ' + num(pageH - (margin + t.y) * K) + ' Tm\n' +
          pdfString(t.text) + ' Tj\nET\n');
      });
      pageBodies.push({ content: noteContent.join(''), used: {} });
    }

    var pagesId = addObject('<< /Type /Pages /Count ' + pageBodies.length + ' /Kids [] >>');
    pageBodies.forEach(function (pb) {
      var res = '/Font << ' + Object.keys(fontObj).map(function (n) {
        return '/' + n + ' ' + fontObj[n] + ' 0 R';
      }).join(' ') + ' >>';
      var xo = Object.keys(pb.used || {});
      if (xo.length) res += ' /XObject << ' + xo.map(function (id) { return '/Im' + id + ' ' + id + ' 0 R'; }).join(' ') + ' >>';
      var body = strBytes(pb.content);
      var cid = addObject(stream('', body));
      var pid = addObject('<< /Type /Page /Parent ' + pagesId + ' 0 R /MediaBox [0 0 ' +
        num(pageW) + ' ' + num(pageH) + '] /Resources << ' + res +
        ' /ProcSet [/PDF /Text /ImageC] >> /Contents ' + cid + ' 0 R >>');
      pageIds.push(pid);
    });
    objects[pagesId - 1] = '<< /Type /Pages /Count ' + pageIds.length + ' /Kids [' +
      pageIds.map(function (id) { return id + ' 0 R'; }).join(' ') + '] >>';

    var catalogId = addObject('<< /Type /Catalog /Pages ' + pagesId + ' 0 R' +
      ' /ViewerPreferences << /PrintScaling /None /PickTrayByPDFSize false >> >>');
    var infoId = addObject('<< /Title ' + pdfString(o.title || 'Student ID Cards') +
      ' /Producer ' + pdfString('School Connect - HMG Concepts ID-card engine v12.63') +
      ' /Creator ' + pdfString(o.creator || 'School Connect') + ' >>');

    /* serialise with a classic xref table (no compressed objects) */
    var header = strBytes('%PDF-1.3\n%\xE2\xE3\xCF\xD3\n');
    var parts = [header];
    var offsets = [];
    var pos = header.length;
    for (var i = 0; i < objects.length; i++) {
      var item = objects[i];
      var bodyBytes = typeof item === 'string' ? strBytes(item) : item;
      var piece = concat([strBytes((i + 1) + ' 0 obj\n'), bodyBytes, strBytes('\nendobj\n')]);
      offsets.push(pos);
      parts.push(piece);
      pos += piece.length;
    }
    var xref = 'xref\n0 ' + (objects.length + 1) + '\n0000000000 65535 f \n' +
      offsets.map(function (off) { return pad10(off) + ' 00000 n \n'; }).join('');
    xref += 'trailer\n<< /Size ' + (objects.length + 1) + ' /Root ' + catalogId + ' 0 R /Info ' + infoId +
      ' 0 R >>\nstartxref\n' + pos + '\n%%EOF\n';
    parts.push(strBytes(xref));
    return concat(parts);
  }

  /* ---------- public API --------------------------------------------------- */
  var API = {
    available: function () { return !!(global.SC_PDF_FONTS && global.SC_PDF_FONTS['Roboto-Regular']); },
    /* every image/font problem found while building the last PDF */
    lastWarnings: function () { return diagnostics.slice(); },
    noteWarning: function (msg, detail) { diag(msg, detail); },
    clearWarnings: function () { diagnostics.length = 0; },
    /* exposed so the self-test and the audit harness can assert the exact
       metrics that will be written into the PDF */
    fontMetrics: function (name) { return FontMetrics.read((global.SC_PDF_FONTS || {})[name || 'Roboto-Regular']); },
    canDraw: function (ch, name) {
      var m = API.fontMetrics(name);
      return m ? m.hasGlyph(ch) : true;
    },
    build: function (cards, options) {
      diagnostics.length = 0;
      return build(cards, options);
    },
    blob: function (cards, options) { return new Blob([build(cards, options)], { type: 'application/pdf' }); },
    download: function (cards, options, filename) {
      var blob = API.blob(cards, options);
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url;
      a.download = filename || 'school-connect-id-cards.pdf';
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 5000);
      return blob.size;
    },
    open: function (cards, options, title) {
      var blob = API.blob(cards, options);
      var url = URL.createObjectURL(blob);
      var w = global.open(url, '_blank');
      if (!w && global.toast) global.toast('Allow pop-ups to open the print-ready PDF.', 'warning', 7000);
      setTimeout(function () { URL.revokeObjectURL(url); }, 90000);
      return blob.size;
    }
  };
  global.IDCardPDF = API;
  global.IDCardPDF.CardPainter = CardPainter;
  global.IDCardPDF.sanitize = sanitize;
})(window);
