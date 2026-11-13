/* ============================================================================
   idcard-pdf.selftest.js — geometry guard for the ID-card PDF engine.
   Run it from the browser console (or the ID-card page in debug mode):
       IDCardPDF.selfTest()
   It fails loudly if any drawn element falls outside the card, if two text
   runs collide, or if a glyph would be unprintable. This is the regression
   net that keeps "the PDF is broken" from ever reaching a customer again.
   ========================================================================== */
(function (global) {
  'use strict';
  function norm(t) {
    if (t.align === 'right') return { x: t.x - t.w, y: t.y, w: t.w, h: t.size, text: t.text, size: t.size };
    if (t.align === 'center') return { x: t.x - t.w / 2, y: t.y, w: t.w, h: t.size, text: t.text, size: t.size };
    return t;
  }
  function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  }
  function run(brand) {
    var b = brand || { name: "God's Own Standard Academy", shortName: 'GOSA',
      motto: 'Knowledge, Character, Service',
      address: '63B Ishaga Road, Ijeshatedo, Surulere, Lagos',
      phone: '08088667076', email: 'info@gosa.edu.ng' };
    var people = [
      { full_name: 'Adaeze Chukwuma-Okonkwo', admission_no: 'GOSA/2024/0001', class: 'JSS1', arm: 'A',
        date_of_birth: '2012-05-01', blood_group: 'O+', type: 'student' },
      { full_name: 'Abdulrahman Ọláyínká', admission_no: 'GOSA/2024/0002', class: 'SSS3', arm: 'Science',
        date_of_birth: '2008-11-23', blood_group: 'AB-', type: 'student' },
      { full_name: 'Mrs. Ngozi Ebere', staff_no: 'GOSA/STF/07', role: 'Vice Principal (Academics)',
        department: 'Academic Board', phone: '08088667076', type: 'staff' }
    ];
    var failures = [];
    people.forEach(function (person) {
      ['front', 'back'].forEach(function (side) {
        var painter = new global.IDCardPDF.CardPainter({ widthMm: 85.6, heightMm: 53.98, dpi: 200 });
        painter.drawFace(person, side, b);
        var W = painter.w, H = painter.h;
        painter.rects.forEach(function (r) {
          if (r.x < -0.01 || r.y < -0.01 || r.x + r.w > W + 0.01 || r.y + r.h > H + 0.01) {
            failures.push(side + '/' + person.full_name + ': rect out of card ' + JSON.stringify(r));
          }
        });
        painter.texts.forEach(function (t) {
          if (t.align === 'right') t = Object.assign({}, t, { x: t.x - t.w });
          else if (t.align === 'center') t = Object.assign({}, t, { x: t.x - t.w / 2 });
          if (t.x < -0.05 || t.y < 0 || t.x + t.w > W + 0.05 || t.y + t.size > H + 0.05) {
            failures.push(side + '/' + person.full_name + ': text out of card "' + t.text + '" @ ' +
              t.x.toFixed(1) + ',' + t.y.toFixed(1) + ' w=' + t.w.toFixed(1));
          }
          if (/\?{2,}/.test(t.text)) failures.push(side + ': unsanitised glyphs in "' + t.text + '"');
        });
        for (var i = 0; i < painter.texts.length; i++) {
          for (var j = i + 1; j < painter.texts.length; j++) {
            var a = norm(painter.texts[i]), c = norm(painter.texts[j]);
            var ra = { x: a.x, y: a.y, w: a.w, h: a.size * 0.95 };
            var rc = { x: c.x, y: c.y, w: c.w, h: c.size * 0.95 };
            if (overlaps(ra, rc) && a.text !== c.text) {
              failures.push(side + '/' + person.full_name + ': text overlap "' + a.text + '" / "' + c.text + '"');
            }
          }
        }
      });
    });
    if (global.console) {
      if (failures.length) {
        console.error('[IDCardPDF.selfTest] ' + failures.length + ' problem(s):');
        failures.forEach(function (f) { console.error('  - ' + f); });
      } else {
        console.info('[IDCardPDF.selfTest] PASS — no overflow, no collisions, all glyphs printable.');
      }
    }
    return { pass: failures.length === 0, failures: failures };
  }
  if (global.IDCardPDF) global.IDCardPDF.selfTest = run;
})(window);
