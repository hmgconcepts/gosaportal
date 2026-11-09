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
  var LITERAL = {
    '\u2705': '[OK]', '\u2714': '[OK]', '\u2713': '[OK]', '\u274C': 'x', '\u2716': 'x',
    '\u2192': '->', '\u2190': '<-', '\u25CF': '-', '\u00B7': '-', '\u20A6': 'NGN '
  };
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
      if (WINANSI_EXTRA[code]) { out += String.fromCharCode(WINANSI_EXTRA[code]); continue; }
      if (code >= 32 && code <= 255) { out += ch; continue; }
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
      var ctx = c.getContext('2d');
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, c.width, c.height);
      if (src.nodeName === 'CANVAS' || src.nodeName === 'IMG') ctx.drawImage(src, 0, 0, c.width, c.height);
      else ctx.putImageData(src, 0, 0);
      return { b64: c.toDataURL('image/jpeg', 0.92).split(',')[1], w: c.width, h: c.height };
    } catch (e) { return null; }
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
  CardPainter.prototype.image = function (img, x, y, w, h) {
    var bytes = toJpeg(img);
    if (!bytes) return this;
    try { this.ctx.drawImage(img, x * this.unit, y * this.unit, w * this.unit, h * this.unit); } catch (e) {}
    this.images.push({ x: x, y: y, w: w, h: h, bytes: bytes });
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
      if (p.photo) this.image(p.photo, px, py, pw, phh);
      else this.text((String(p.full_name || 'S').trim().charAt(0) || 'S').toUpperCase(),
                     px + pw / 2, py + 8, { size: 12, bold: true, colour: '#64748b' });

      var x = 28.4, y = 18.2;
      this.text(p.full_name || '', x, y, { size: 4.2, bold: true, colour: ink, maxMm: W - x - 3.4 });
      y += 6.2;
      var rows = isStaff
        ? [['Designation', p.role], ['Department', p.department], ['Staff ID', idNo], ['Phone', p.phone]]
        : [['Student ID', idNo], ['Class', [p.class, p.arm].filter(Boolean).join(' ')],
           ['Date of birth', p.date_of_birth], ['Blood group', p.blood_group]];
      for (var i = 0; i < rows.length; i++) {
        if (!rows[i][1]) continue;
        this.text(rows[i][0], x, y, { size: 1.95, colour: soft });
        this.text(String(rows[i][1]).toUpperCase(), x + 15.0, y - 0.25,
                  { size: 2.5, bold: i < 2, colour: ink, maxMm: W - x - 17.5 });
        y += 3.85;
      }
      var qrSize = 19.5, qx = W - 3.2 - qrSize, qy = H - 6.2 - qrSize;
      this.frame(qx, qy, qrSize, qrSize, '#cbd5e1', 0.25);
      if (p.qr) this.image(p.qr, qx, qy, qrSize, qrSize);
      this.text('SCAN TO VERIFY', W - 3.2, H - 4.6, { size: 1.75, bold: true, colour: ink, align: 'right' });
      this.text(b.address || '', 3.2, H - 6.2, { size: 1.75, colour: soft, maxMm: qx - 6 });
      this.text([b.phone, b.email].filter(Boolean).join('  .  '), 3.2, H - 3.6,
                { size: 1.75, colour: soft, maxMm: qx - 6 });
    } else {
      this.rect(0, 0, W, 9.5, primary);
      this.text((short + '  ·  ' + (isStaff ? 'STAFF' : 'STUDENT') + ' ID — REVERSE').toUpperCase(),
                3.2, 3.0, { size: 2.7, bold: true, colour: white, maxMm: W - 6.4 });
      this.rect(0, 10.5, W, 3.2, '#1f2937');
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
      var ry = 15.2;
      for (var r = 0; r < rules.length; r++) {
        this.text((r + 1) + '.', 3.2, ry, { size: 2.05, bold: true, colour: primary });
        this.text(rules[r], 5.8, ry, { size: 2.05, colour: '#334155', maxMm: W - 9.2 });
        ry += 3.05;
      }
      var boxTop = ry + 0.95, boxH = 12.6;
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
      this.rect(3.2, footTop + 3.5, 30, 0.25, '#64748b');           /* signature rule */
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
    function stream(dict, bytes) {
      return concat([strBytes('<< ' + dict + ' /Length ' + bytes.length + ' >>\nstream\n'),
                     bytes, strBytes('\nendstream')]);
    }

    /* Fonts — embedded TrueType, WinAnsi, no subsetting (CorelDRAW can edit). */
    var fontObj = {};
    ['Roboto-Regular', 'Roboto-Bold'].forEach(function (name) {
      var b64 = (global.SC_PDF_FONTS || {})[name];
      if (!b64) return;
      var bytes = b64ToBytes(b64);
      var fileId = addObject(stream('', bytes));
      var descId = addObject('<< /Type /FontDescriptor /FontName /' + name +
        ' /Flags 32 /FontBBox [-1021 -463 1793 1232] /ItalicAngle 0 /Ascent 927 /Descent -244' +
        ' /CapHeight 711 /StemV 88 /FontFile2 ' + fileId + ' 0 R >>');
      fontObj[name] = addObject('<< /Type /Font /Subtype /TrueType /BaseFont /' + name +
        ' /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 255 /FontDescriptor ' + descId + ' 0 R >>');
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
      ' /Producer ' + pdfString('School Connect - HMG Concepts ID-card engine v12.60') +
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
    build: build,
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
