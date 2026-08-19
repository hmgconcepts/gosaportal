/* ============================================================================
   cbt-types.js — School Connect advanced question-type renderers & graders
   ----------------------------------------------------------------------------
   V10.3 (Pass 51). Modelled on the Tutoring Connect / HMG Academy CBT Pro
   student portal, which renders each question type with a purpose-built
   control instead of forcing everything into radio buttons or a bare
   textarea. School Connect declared 17+ types but rendered most of them as a
   plain textarea, so a matching question looked identical to a short-answer
   question.

   This file supplies a real control per type, and a matching client-side
   grader, and is PURELY ADDITIVE: cbt-exam.html falls back to its original
   letter-card / textarea behaviour for anything not handled here, so no
   existing paper changes behaviour. The CANONICAL grade is still computed
   server-side (sc_cbt_grade_fraction, database/v10.3) — the grader here is
   only the resilience preview, kept byte-compatible in semantics.

   The families, and what the student actually sees:

     mcq / image_based / case_study / assertion_reason
                        — tappable option cards, with a passage or figure or
                          assertion/reason block above where relevant
     multi_select (mrq) — tappable cards with checkboxes and a "pick all" hint
     true_false         — two large cards
     short_answer       — single line with an accepted-answers hint
     numeric            — decimal input with unit and tolerance shown
     multi_numeric      — one labelled input per sub-part, partial credit
     cloze / fill_blank — the sentence itself, with inputs inline at each ___
     matching           — left column fixed, right column a dropdown per row,
                          the right-hand pool shuffled once and remembered
     ordering           — a drag-and-drop list, with ↑ ↓ buttons as the
                          keyboard- and touch-accessible equivalent
     categorization     — one row per item, a category dropdown per row
     matrix             — one row per statement, shared options across rows
     hot_text           — the passage broken into tappable chips
     essay              — textarea with a live word count against the minimum
     code               — monospace textarea with the expected language shown

   Scoring is rule-based and transparent. No AI API is used anywhere: partial
   credit is arithmetic, and essay/code marking stays with the teacher
   (manual review) exactly as before.
   ========================================================================== */
(function (w, d) {
  'use strict';

  var esc = function (s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  };

  /* Parse a field that may arrive as JSON text, an array, or a pipe list. */
  function parseList(v) {
    if (v == null || v === '') return [];
    if (Array.isArray(v)) return v;
    if (typeof v === 'object') return Object.values(v);
    var s = String(v).trim();
    if (s.charAt(0) === '[' || s.charAt(0) === '{') {
      try {
        var p = JSON.parse(s);
        return Array.isArray(p) ? p : [p];
      } catch (e) { /* fall through to delimiter parsing */ }
    }
    return s.split(/\s*[|;]\s*/).filter(Boolean);
  }

  function parseObj(v) {
    if (!v) return {};
    if (typeof v === 'object' && !Array.isArray(v)) return v;
    try { var p = JSON.parse(String(v)); return (p && typeof p === 'object' && !Array.isArray(p)) ? p : {}; }
    catch (e) { return {}; }
  }

  /* A deterministic shuffle seeded by the question id, so the right-hand pool
     of a matching question is the same every time the student returns to it.
     A fresh Math.random() shuffle on each repaint would move the options
     under the student's finger. */
  function seededShuffle(arr, seed) {
    var a = arr.slice(), s = 0, i, j, t;
    String(seed || '').split('').forEach(function (c) { s = (s * 31 + c.charCodeAt(0)) & 0x7fffffff; });
    var rnd = function () { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; };
    for (i = a.length - 1; i > 0; i--) { j = Math.floor(rnd() * (i + 1)); t = a[i]; a[i] = a[j]; a[j] = t; }
    return a;
  }

  function itemsOf(q) {
    var raw = q.items != null && q.items !== '' ? q.items : q.pairs;
    return parseList(raw);
  }
  function itemsObjOf(q) {
    var raw = q.items != null && q.items !== '' ? q.items : q.pairs;
    return parseObj(raw);
  }

  var TYPES = {

    /* ---------------- typed families ---------------- */
    short_answer: function (q, name) {
      var acc = parseList(q.accepted_answers || q.accept);
      return '<input class="scq-input" type="text" name="' + esc(name) + '" autocomplete="off" ' +
        'placeholder="Type your answer">' +
        (acc.length > 1 ? '<div class="scq-hint">Spelling variations are accepted.</div>' : '');
    },

    numeric: function (q, name) {
      var unit = q.unit || '';
      var tol = q.tolerance;
      return '<div class="scq-numwrap">' +
        '<input class="scq-input scq-num" type="text" inputmode="decimal" name="' + esc(name) + '" ' +
          'placeholder="Enter a number">' +
        (unit ? '<span class="scq-unit">' + esc(unit) + '</span>' : '') +
      '</div>' +
      (tol ? '<div class="scq-hint">Answers within ±' + esc(tol) + ' are accepted.</div>'
           : '<div class="scq-hint">Give the number only — no words.</div>');
    },

    multi_numeric: function (q, name) {
      var parts = itemsOf(q);
      if (!parts.length) return TYPES.numeric(q, name);
      return '<div class="scq-hint">Answer <b>each</b> part. Marks are given part by part.</div>' +
        '<div class="scq-parts">' + parts.map(function (p, i) {
          var label = (typeof p === 'object' ? (p.label || p.name) : p) || ('Part ' + (i + 1));
          var unit = (typeof p === 'object' && p.unit) ? p.unit : '';
          return '<div class="scq-part">' +
            '<label class="scq-part-label">' + esc(label) + '</label>' +
            '<input class="scq-input scq-num" type="text" inputmode="decimal" ' +
              'name="' + esc(name) + '__' + i + '" placeholder="Answer">' +
            (unit ? '<span class="scq-unit">' + esc(unit) + '</span>' : '') +
          '</div>';
        }).join('') + '</div>';
    },

    /* The sentence with real inputs sitting where each ___ appeared. */
    cloze: function (q, name) {
      var text = String(q.question || '');
      var blanks = (text.match(/_{2,}/g) || []).length;
      var answers = itemsOf(q);
      if (!answers.length) answers = parseList(q.accepted_answers || q.answer);
      if (!blanks) blanks = Math.max(answers.length, 1);
      var i = 0;
      var withInputs = esc(text).replace(/_{2,}/g, function () {
        var box = '<input class="scq-input scq-blank" type="text" autocomplete="off" ' +
          'name="' + esc(name) + '__' + i + '" placeholder="' + (i + 1) + '">';
        i++;
        return box;
      });
      if (i === 0) {
        withInputs += '<div class="scq-parts">' + Array.apply(null, Array(blanks)).map(function (_, k) {
          return '<div class="scq-part"><label class="scq-part-label">Blank ' + (k + 1) + '</label>' +
            '<input class="scq-input" type="text" name="' + esc(name) + '__' + k + '"></div>';
        }).join('') + '</div>';
      }
      return '<div class="scq-cloze">' + withInputs + '</div>' +
        '<div class="scq-hint">Fill every blank. Capitalisation does not matter.</div>';
    },

    essay: function (q, name) {
      var cfg = itemsObjOf(q);
      var min = cfg.min_words || q.min_words || 0;
      return '<textarea class="scq-textarea" name="' + esc(name) + '" rows="8" ' +
        'placeholder="Write your answer in full sentences."></textarea>' +
        '<div class="scq-hint"><span data-wordcount="' + esc(name) + '">0 words</span>' +
        (min ? ' · at least <b>' + min + '</b> expected' : '') +
        ' · your teacher marks this after submission.</div>';
    },

    code: function (q, name) {
      var cfg = itemsObjOf(q);
      var lang = cfg.language || q.unit || 'code';
      return '<div class="scq-hint">Write your answer in <b>' + esc(lang) + '</b>. ' +
        'Indentation is preserved.</div>' +
        '<textarea class="scq-textarea scq-code" name="' + esc(name) + '" rows="10" spellcheck="false" ' +
        'placeholder="// your ' + esc(lang) + ' here"></textarea>';
    },

    /* ---------------- structured families ---------------- */
    matching: function (q, name) {
      var pairs = itemsOf(q).map(function (p) {
        return (typeof p === 'object') ? p : { left: p, right: '' };
      }).filter(function (p) { return p.left; });
      if (!pairs.length) return '<p class="scq-warn">⚠️ No matching pairs defined for this question.</p>';
      var rights = pairs.map(function (p) { return p.right; }).filter(Boolean);
      parseList(q.distractors || q.accept).forEach(function (dx) { if (rights.indexOf(dx) === -1) rights.push(dx); });
      var pool = seededShuffle(rights, q.id || name);
      return '<div class="scq-hint">Choose the item on the right that belongs with each item on the left.</div>' +
        '<table class="scq-match">' + pairs.map(function (p, i) {
          return '<tr>' +
            '<td class="scq-match-left">' + esc(p.left) + '</td>' +
            '<td class="scq-match-arrow">→</td>' +
            '<td><select class="scq-select" name="' + esc(name) + '__' + i + '">' +
              '<option value="">— choose —</option>' +
              pool.map(function (r) { return '<option value="' + esc(r) + '">' + esc(r) + '</option>'; }).join('') +
            '</select></td></tr>';
        }).join('') + '</table>';
    },

    ordering: function (q, name) {
      var items = itemsOf(q);
      if (!items.length) items = parseList(q.options);
      items = items.map(function (it) { return (typeof it === 'object') ? (it.text || it.item || it.label || '') : it; }).filter(Boolean);
      if (!items.length) return '<p class="scq-warn">⚠️ No items defined for this ordering question.</p>';
      var shown = seededShuffle(items, q.id || name);
      return '<div class="scq-hint">Drag into the correct order, or use the ↑ ↓ buttons. ' +
        'You get a mark for every item in the right place.</div>' +
        '<ul class="scq-order" data-order="' + esc(name) + '">' + shown.map(function (it) {
          return '<li class="scq-order-item" draggable="true" data-val="' + esc(it) + '">' +
            '<span class="scq-order-handle" aria-hidden="true">⠿</span>' +
            '<span class="scq-order-num"></span>' +
            '<span class="scq-order-text">' + esc(it) + '</span>' +
            '<span class="scq-order-btns">' +
              '<button type="button" class="scq-mini" data-up aria-label="Move up">↑</button>' +
              '<button type="button" class="scq-mini" data-down aria-label="Move down">↓</button>' +
            '</span></li>';
        }).join('') + '</ul>' +
        '<input type="hidden" name="' + esc(name) + '">';
    },

    categorization: function (q, name) {
      var rows = itemsOf(q);
      if (!rows.length) return '<p class="scq-warn">⚠️ No items defined for this question.</p>';
      var cats = [];
      rows.forEach(function (r) {
        var c = (typeof r === 'object') ? r.category : null;
        if (c && cats.indexOf(c) === -1) cats.push(c);
      });
      parseList(q.accept).forEach(function (c) { if (cats.indexOf(c) === -1) cats.push(c); });
      cats.sort();
      return '<div class="scq-hint">Put each item into the category it belongs to.</div>' +
        '<table class="scq-match">' + rows.map(function (r, i) {
          var item = (typeof r === 'object') ? (r.item || r.label) : r;
          return '<tr><td class="scq-match-left">' + esc(item) + '</td>' +
            '<td class="scq-match-arrow">→</td>' +
            '<td><select class="scq-select" name="' + esc(name) + '__' + i + '">' +
              '<option value="">— choose a category —</option>' +
              cats.map(function (c) { return '<option value="' + esc(c) + '">' + esc(c) + '</option>'; }).join('') +
            '</select></td></tr>';
        }).join('') + '</table>';
    },

    matrix: function (q, name) {
      var rows = itemsOf(q);
      if (!rows.length) return '<p class="scq-warn">⚠️ No rows defined for this question.</p>';
      var opts = parseList(q.accept);
      if (!opts.length) opts = ['True', 'False'];
      return '<div class="scq-hint">Answer every row.</div>' +
        '<table class="scq-match scq-matrix"><thead><tr><th>Statement</th>' +
        opts.map(function (o) { return '<th>' + esc(o) + '</th>'; }).join('') + '</tr></thead><tbody>' +
        rows.map(function (r, i) {
          var st = (typeof r === 'object') ? (r.statement || r.item || r.label) : r;
          return '<tr><td class="scq-match-left">' + esc(st) + '</td>' +
            opts.map(function (o) {
              return '<td class="scq-matrix-cell"><label><input type="radio" ' +
                'name="' + esc(name) + '__' + i + '" value="' + esc(o) + '">' +
                '<span class="scq-sr">' + esc(o) + '</span></label></td>';
            }).join('') + '</tr>';
        }).join('') + '</tbody></table>';
    },

    hot_text: function (q, name) {
      var chunks = itemsOf(q);
      if (!chunks.length) return '<p class="scq-warn">⚠️ No selectable text defined for this question.</p>';
      return '<div class="scq-hint">Tap every part that is correct. Tap again to unselect.</div>' +
        '<div class="scq-hot" data-hot="' + esc(name) + '">' + chunks.map(function (c) {
          var t = (typeof c === 'object') ? (c.text || c.item) : c;
          return '<button type="button" class="scq-chip" data-val="' + esc(t) + '">' + esc(t) + '</button>';
        }).join('') + '</div><input type="hidden" name="' + esc(name) + '">';
    }
  };

  /* Aliases so a paper authored for Tutoring Connect / HMG Academy CBT Pro
     renders here without being rewritten. Resolution order matches the SQL
     engine (sc_cbt_question_type in database/v10.3). */
  var ALIAS = {
    mrq: 'multi_select', tf: 'true_false', short: 'short_answer',
    fill_blank: 'cloze', fill: 'cloze', gap_fill: 'cloze', gapfill: 'cloze',
    classification: 'categorization', sorting: 'categorization', grouping: 'categorization',
    likert: 'matrix', grid: 'matrix',
    drag_drop: 'ordering', dragdrop: 'ordering', timeline: 'ordering',
    sequence: 'ordering', sequencing: 'ordering', ranking: 'ordering',
    error_spotting: 'hot_text', hottext: 'hot_text',
    multinumeric: 'multi_numeric', multi_part_numeric: 'multi_numeric',
    oral_prompt: 'essay', peer_review: 'essay', long_answer: 'essay',
    code_output: 'code',
    citation: 'short_answer', math_equation: 'short_answer'
  };

  /* ON-SCREEN GUIDANCE. A student who has only ever met multiple choice will
     hesitate at a matching table or a drag-to-order list, and hesitation in a
     timed exam costs marks that have nothing to do with what they know. Each
     type carries a one-line "how to answer this" note, shown inline above the
     control, plus a full legend the candidate can open at any time from the
     exam toolbar. Phrased for a nervous student, not for a developer. */
  var HOWTO = {
    mcq: 'Tap the ONE option you think is right. Tap a different one to change your mind.',
    multi_select: 'More than one option is correct. Tap EVERY option that applies.',
    true_false: 'Decide whether the statement is true or false, then tap that card.',
    short_answer: 'Type your answer in the box. Spelling variations are usually accepted.',
    numeric: 'Type the NUMBER only — no words and no unit unless the box asks for one.',
    multi_numeric: 'This question has several parts. Answer each box separately: you earn a mark for every part you get right, even if another part is wrong.',
    cloze: 'Fill in each gap in the sentence. Every gap is worth a mark on its own.',
    matching: 'For each item on the LEFT, choose the matching item from the dropdown on the RIGHT. Some right-hand options may not be used at all.',
    ordering: 'Put the items into the correct order. Drag them, or use the ↑ and ↓ buttons. You earn a mark for every item that ends up in the right place.',
    categorization: 'Decide which category each item belongs to and pick it from the dropdown beside it.',
    matrix: 'Answer every row. All rows share the same set of choices across the top.',
    hot_text: 'Tap every part that is correct. Tap it again to unselect. Wrong picks cost you, so choose carefully.',
    essay: 'Write in full sentences. Your teacher reads and marks it after you submit.',
    code: 'Write your code in the box. Indentation is kept exactly as you type it.',
    assertion_reason: 'Read the Assertion and the Reason. Decide whether each is true, and whether the Reason actually EXPLAINS the Assertion. Then pick the option that describes both.',
    case_study: 'Read the passage at the top first, then answer the question underneath it.',
    comprehension: 'Read the passage at the top first, then answer the question underneath it.',
    image_based: 'Study the figure, then answer the question underneath it.',
    audio_based: 'Listen to the clip, then answer the question underneath it.',
    video_based: 'Watch the clip, then answer the question underneath it.'
  };

  /* Every remaining named type, so nothing a paper can contain is unexplained. */
  var ALIAS_NOTE = {
    mrq: 'Behaves like Multiple response — tap every option that applies.',
    tf: 'Behaves like True / False.',
    short: 'Behaves like Short answer.',
    fill_blank: 'Behaves like Fill the gaps.',
    scenario_mcq: 'A short scenario, then a normal multiple-choice question.',
    comprehension: 'A passage to read, then questions on it.',
    data_interpretation: 'A table, chart or set of data to read, then questions on it.',
    graph_read: 'Read values off a graph or chart, then answer.',
    math_equation: 'Type the expression or value. The math keyboard has the symbols you need.',
    oral_prompt: 'Speak your answer and submit a recording LINK (Drive or YouTube). Never a file upload.',
    peer_review: 'Write a short, constructive comment on the work shown.',
    true_false_justify: 'Choose True or False, then justify it in the box.',
    classification: 'Behaves like Sort into groups.',
    likert: 'Choose the point on the scale that best matches your view. There is no wrong answer.',
    drag_drop: 'Drag the items into place, or use the ↑ ↓ buttons.',
    timeline: 'Put the events into the order they happened.',
    error_spotting: 'Tap the parts that contain the mistake.',
    map_label: 'Study the map or diagram, then answer.',
    citation: 'Give the source or reference in the box.',
    audio_based: 'Listen to the clip, then answer.',
    video_based: 'Watch the clip, then answer.',
    code_output: 'Say what the code prints, or write the code asked for.',
    hotspot: 'Study the figure and answer the question about the marked area.'
  };

  /* The full legend, for the "❓ How do I answer these?" button. */
  function legendHTML() {
    var order = ['mcq','multi_select','true_false','short_answer','numeric','multi_numeric',
                 'cloze','matching','ordering','categorization','matrix','hot_text',
                 'assertion_reason','case_study','image_based','essay','code'];
    var LABEL = {
      mcq: 'Multiple choice', multi_select: 'Multiple response', true_false: 'True / False',
      short_answer: 'Short answer', numeric: 'Numeric', multi_numeric: 'Multi-part numeric',
      cloze: 'Fill the gaps', matching: 'Matching', ordering: 'Put in order',
      categorization: 'Sort into groups', matrix: 'Grid', hot_text: 'Tap the right parts',
      assertion_reason: 'Assertion & Reason', case_study: 'Passage question',
      image_based: 'Figure question', essay: 'Written answer', code: 'Code'
    };
    return '<div class="scq-legend">' +
      '<p class="scq-legend-intro">This paper may use several question styles. Here is how each one ' +
      'works. You can reopen this at any time — it does not use up your exam time.</p>' +
      order.map(function (t) {
        return '<div class="scq-legend-row"><b>' + (LABEL[t] || t) + '</b><span>' + HOWTO[t] + '</span></div>';
      }).join('') +
      '<h4 class="scq-legend-more">Other styles you may meet</h4>' +
      Object.keys(ALIAS_NOTE).map(function (t) {
        var pretty = t.replace(/_/g, ' ').replace(/\b\w/g, function (c) { return c.toUpperCase(); });
        return '<div class="scq-legend-row"><b>' + pretty + '</b><span>' + ALIAS_NOTE[t] + '</span></div>';
      }).join('') +
      '<p class="scq-legend-foot">Partial credit is normal: on matching, ordering, grids, gap-fills ' +
      'and multi-part questions you earn marks for the parts you get right, so always attempt them. ' +
      'An unanswered question always scores zero, so a sensible attempt is never worse than a blank.</p>' +
      '</div>';
  }

  /* Types the exam player hands to this engine instead of its classic
     letter-card / textarea path. Option-card families (mcq, true_false,
     multi_select, case_study, assertion_reason with options…) STAY on the
     original letter-based path so existing papers and drafts keep behaving
     identically. */
  var STRUCTURED = ['matching','ordering','categorization','matrix','hot_text',
                    'multi_numeric','cloze','numeric','short_answer','essay','code'];

  var CBTTypes = {
    TYPES: TYPES,
    ALIAS: ALIAS,
    HOWTO: HOWTO,
    STRUCTURED: STRUCTURED,
    legendHTML: legendHTML,
    parseList: parseList,
    parseObj: parseObj,

    canonical: function (type) {
      var t = String(type || 'mcq').toLowerCase().replace(/[\s\/\\-]+/g, '_');
      return ALIAS[t] || t;
    },

    /** Should the exam player use this engine for the question? */
    handles: function (q) {
      var t = this.canonical(q && q.type);
      if (STRUCTURED.indexOf(t) === -1) return false;
      /* cloze only counts as structured when it has a per-blank key or
         multiple blanks — a legacy single-answer fill_blank keeps the old
         one-box behaviour and old grading. */
      if (t === 'cloze') {
        var multi = (String(q.question || '').match(/_{2,}/g) || []).length > 1;
        return itemsOf(q).length > 0 || multi;
      }
      return true;
    },

    /** Render the control for one question. Returns '' if unsupported. */
    render: function (q, name) {
      var t = this.canonical(q.type);
      if (typeof TYPES[t] !== 'function') return '';
      try {
        var body = TYPES[t](q, name);
        var tip = HOWTO[t];
        return (tip ? '<div class="scq-howto"><span aria-hidden="true">💡</span> ' +
                 esc(tip) + '</div>' : '') + body;
      }
      catch (e) { return '<p class="scq-warn">⚠️ This question could not be displayed (' + esc(e.message) + ').</p>'; }
    },

    /** The Assertion/Reason briefing block, shown ABOVE the classic option
        cards for assertion_reason questions (which stay on the letter path). */
    arBlock: function (q) {
      var it = itemsObjOf(q);
      var a = it.assertion || '', r = it.reason || '';
      if (!a && !r) return '';
      return '<div class="scq-ar">' +
        (a ? '<div class="scq-ar-row"><span class="scq-ar-tag">Assertion</span><span>' + esc(a) + '</span></div>' : '') +
        (r ? '<div class="scq-ar-row"><span class="scq-ar-tag scq-ar-reason">Reason</span><span>' + esc(r) + '</span></div>' : '') +
      '</div>';
    },

    /** Wire behaviour that needs JavaScript: drag ordering, chips, word count. */
    activate: function (root, onChange) {
      root = root || d;
      var fire = function () { if (typeof onChange === 'function') onChange(); };

      // Ordering — drag plus keyboard/touch buttons, kept in a hidden input.
      root.querySelectorAll('[data-order]').forEach(function (list) {
        if (list._wired) return; list._wired = true;
        var nm = list.getAttribute('data-order');
        var hidden = root.querySelector('input[type="hidden"][name="' + nm + '"]');
        var sync = function () {
          var vals = [].map.call(list.querySelectorAll('.scq-order-item'), function (li, i) {
            var n = li.querySelector('.scq-order-num'); if (n) n.textContent = i + 1;
            return li.getAttribute('data-val');
          });
          if (hidden) hidden.value = JSON.stringify(vals);
          fire();
        };
        var dragging = null;
        list.addEventListener('dragstart', function (e) {
          dragging = e.target.closest('.scq-order-item');
          if (dragging) dragging.classList.add('is-dragging');
        });
        list.addEventListener('dragend', function () {
          if (dragging) dragging.classList.remove('is-dragging');
          dragging = null; sync();
        });
        list.addEventListener('dragover', function (e) {
          e.preventDefault();
          var over = e.target.closest('.scq-order-item');
          if (!over || !dragging || over === dragging) return;
          var rect = over.getBoundingClientRect();
          var after = (e.clientY - rect.top) > rect.height / 2;
          list.insertBefore(dragging, after ? over.nextSibling : over);
        });
        list.addEventListener('click', function (e) {
          var li = e.target.closest('.scq-order-item'); if (!li) return;
          if (e.target.hasAttribute('data-up') && li.previousElementSibling) {
            list.insertBefore(li, li.previousElementSibling); sync();
          } else if (e.target.hasAttribute('data-down') && li.nextElementSibling) {
            list.insertBefore(li.nextElementSibling, li); sync();
          }
        });
        sync();
      });

      // Hot text — tappable chips.
      root.querySelectorAll('[data-hot]').forEach(function (box) {
        if (box._wired) return; box._wired = true;
        var nm = box.getAttribute('data-hot');
        var hidden = root.querySelector('input[type="hidden"][name="' + nm + '"]');
        box.addEventListener('click', function (e) {
          var b = e.target.closest('.scq-chip'); if (!b) return;
          b.classList.toggle('is-on');
          var picked = [].map.call(box.querySelectorAll('.scq-chip.is-on'), function (x) { return x.getAttribute('data-val'); });
          if (hidden) hidden.value = JSON.stringify(picked);
          fire();
        });
      });

      // Essay word counter.
      root.querySelectorAll('textarea[name]').forEach(function (ta) {
        var out = root.querySelector('[data-wordcount="' + ta.name + '"]');
        if (!out || ta._wc) return; ta._wc = true;
        var upd = function () {
          var n = (ta.value.trim().match(/\S+/g) || []).length;
          out.textContent = n + (n === 1 ? ' word' : ' words');
        };
        ta.addEventListener('input', upd); upd();
      });

      // Every typed / selected control reports changes upward.
      root.querySelectorAll('.scq-input, .scq-textarea, .scq-select, .scq-matrix-cell input').forEach(function (el) {
        if (el._scw) return; el._scw = true;
        el.addEventListener('input', fire);
        el.addEventListener('change', fire);
      });
    },

    /** Collect one question's answer out of the DOM. */
    collect: function (q, name, root) {
      root = root || d;
      var t = this.canonical(q.type);
      var one = function (sel) { var e = root.querySelector(sel); return e ? e.value : ''; };

      if (t === 'hot_text' || t === 'ordering') {
        try { return JSON.parse(one('input[type=hidden][name="' + name + '"]') || '[]'); } catch (e) { return []; }
      }
      if (t === 'matching' || t === 'categorization' || t === 'matrix' ||
          t === 'multi_numeric' || t === 'cloze') {
        var out = [];
        root.querySelectorAll('[name^="' + name + '__"]').forEach(function (el) {
          if (el.type === 'radio' && !el.checked) return;
          var idx = Number(el.name.split('__').pop());
          out[idx] = el.value;
        });
        return out;
      }
      var el = root.querySelector('[name="' + name + '"]');
      return el ? el.value : '';
    },

    /** Restore a saved/draft answer back into the rendered control. */
    restore: function (q, name, root, value) {
      root = root || d;
      if (this.isBlank(value)) return;
      var t = this.canonical(q.type);
      var arr = Array.isArray(value) ? value : parseList(value);
      if (t === 'ordering') {
        var list = root.querySelector('[data-order="' + name + '"]');
        var hidden = root.querySelector('input[type=hidden][name="' + name + '"]');
        if (list && arr.length) {
          var byVal = {};
          [].forEach.call(list.querySelectorAll('.scq-order-item'), function (li) { byVal[li.getAttribute('data-val')] = li; });
          arr.forEach(function (v) { if (byVal[v]) list.appendChild(byVal[v]); });
          [].forEach.call(list.querySelectorAll('.scq-order-item'), function (li, i) {
            var n = li.querySelector('.scq-order-num'); if (n) n.textContent = i + 1;
          });
          if (hidden) hidden.value = JSON.stringify(arr);
        }
        return;
      }
      if (t === 'hot_text') {
        var box = root.querySelector('[data-hot="' + name + '"]');
        var hid = root.querySelector('input[type=hidden][name="' + name + '"]');
        if (box) [].forEach.call(box.querySelectorAll('.scq-chip'), function (b) {
          b.classList.toggle('is-on', arr.indexOf(b.getAttribute('data-val')) > -1);
        });
        if (hid) hid.value = JSON.stringify(arr);
        return;
      }
      if (t === 'matching' || t === 'categorization' || t === 'matrix' ||
          t === 'multi_numeric' || t === 'cloze') {
        arr.forEach(function (v, i) {
          if (v == null) return;
          var els = root.querySelectorAll('[name="' + name + '__' + i + '"]');
          [].forEach.call(els, function (el) {
            if (el.type === 'radio') el.checked = (el.value === String(v));
            else el.value = v;
          });
        });
        return;
      }
      var el = root.querySelector('[name="' + name + '"]');
      if (el) el.value = Array.isArray(value) ? value.join(', ') : value;
    },

    /** Is a response genuinely blank? Arrays need a per-element check;
        `[] !== ''` is true, which is what makes naive checks miscount. */
    isBlank: function (v) {
      if (v == null) return true;
      if (typeof v === 'string') return v.trim() === '';
      if (Array.isArray(v)) {
        return v.length === 0 || v.every(function (x) {
          return x == null || String(x).trim() === '';
        });
      }
      if (typeof v === 'object') return Object.keys(v).length === 0;
      return false;
    },

    /** Does this question have a usable answer key at all? Mirrors
        public.sc_cbt_has_key in database/v10.3. */
    hasKey: function (q) {
      var t = this.canonical(q.type);
      if (t === 'essay' || t === 'code') return true;            // marked by the teacher
      if (t === 'matching' || t === 'categorization' || t === 'matrix' ||
          t === 'multi_numeric' || t === 'ordering' || t === 'hot_text') {
        return itemsOf(q).length > 0;
      }
      if (t === 'cloze') {
        if (itemsOf(q).length > 0) return true;
      }
      var a = q.answer != null ? q.answer : q.correct;
      if (Array.isArray(a)) return a.filter(function (x) { return String(x).trim() !== ''; }).length > 0;
      return a != null && String(a).trim() !== '';
    },

    /** Mark one question. Returns { earned, max, fraction, correct, detail }.
        A BLANK RESPONSE ALWAYS SCORES ZERO, and a question with no key is
        returned as `unmarkable` — never silently marked correct. This is the
        client preview twin of public.sc_cbt_grade_fraction. */
    grade: function (q, given) {
      var self = this;
      var t = this.canonical(q.type);
      var max = Number(q.mark || 1) || 1;
      var norm = function (v) { return String(v == null ? '' : v).trim().toLowerCase().replace(/\s+/g, ' '); };
      var res = function (fraction, detail) {
        fraction = Math.max(0, Math.min(1, fraction));
        return { earned: Math.round(max * fraction * 100) / 100, max: max, fraction: fraction,
                 correct: fraction >= 1 - 1e-9, detail: detail || '' };
      };

      if (this.isBlank(given)) {
        return { earned: 0, max: max, fraction: 0, correct: false, blank: true, detail: 'no answer given' };
      }
      if (!this.hasKey(q)) {
        return { earned: 0, max: max, fraction: 0, correct: false, pending: true, unmarkable: true,
                 detail: 'this question has no answer key — repair it before it can be marked' };
      }

      var rows, mine, good;

      if (t === 'ordering') {
        var order = parseList(q.answer);
        if (!order.length) order = itemsOf(q).map(function (it) { return (typeof it === 'object') ? (it.text || it.item || it.label || '') : it; });
        mine = Array.isArray(given) ? given : parseList(given);
        if (!order.length) return res(0, 'no answer key');
        good = 0;
        order.forEach(function (v, i) { if (norm(mine[i]) === norm(v)) good++; });
        return res(good / order.length, good + ' of ' + order.length + ' in place');
      }

      if (t === 'matching' || t === 'categorization' || t === 'matrix' ||
          t === 'multi_numeric' || t === 'cloze') {
        rows = itemsOf(q);
        if (t === 'cloze' && !rows.length) rows = parseList(q.answer || q.accepted_answers);
        mine = Array.isArray(given) ? given : parseList(given);
        if (!rows.length) return res(0, 'no answer key');
        good = 0;
        rows.forEach(function (r, i) {
          var expect;
          if (t === 'matching')            expect = (typeof r === 'object') ? r.right : r;
          else if (t === 'categorization') expect = (typeof r === 'object') ? r.category : r;
          else if (t === 'matrix')         expect = (typeof r === 'object') ? (r.answer || r.correct) : r;
          else if (t === 'multi_numeric')  expect = (typeof r === 'object') ? r.answer : r;
          else                             expect = (typeof r === 'object') ? (r.answer || r.text) : r;
          var g = mine[i];
          if (t === 'multi_numeric') {
            var tol = ((typeof r === 'object' && r.tolerance != null) ? Number(r.tolerance) : Number(q.tolerance || 0)) || 0;
            if (g !== '' && g != null && Math.abs(Number(g) - Number(expect)) <= tol + 1e-9) good++;
          } else {
            var alts = String(expect == null ? '' : expect).split('|').map(norm).filter(Boolean);
            if (alts.length && alts.indexOf(norm(g)) > -1) good++;
          }
        });
        return res(good / rows.length, good + ' of ' + rows.length + ' correct');
      }

      if (t === 'hot_text') {
        rows = itemsOf(q);
        var right = rows.filter(function (c) { return c && (c.correct === true || String(c.correct).toLowerCase() === 'true'); })
                        .map(function (c) { return norm(c.text || c.item); });
        var picked = (Array.isArray(given) ? given : parseList(given)).map(norm);
        if (!right.length) return res(0, 'no answer key');
        var h = picked.filter(function (p) { return right.indexOf(p) > -1; }).length;
        var bad = picked.length - h;
        return res(Math.max(0, h - bad) / right.length, h + ' of ' + right.length + ' found');
      }

      if (t === 'multi_select') {
        /* Legacy School Connect default is ALL-OR-NOTHING (preserved). A paper
           opts INTO partial credit with MRQ_AON=false. */
        var partialAsked = q.mrq_aon != null && ['false', '0', 'no', 'partial'].indexOf(String(q.mrq_aon).toLowerCase()) > -1;
        if (!partialAsked) {
          var okAll = (w.CBT && CBT.isCorrect) ? CBT.isCorrect(q, given) : false;
          return res(okAll ? 1 : 0);
        }
        var want = (Array.isArray(q.answer) ? q.answer : parseList(q.answer)).map(norm);
        var got = (Array.isArray(given) ? given : parseList(given)).map(norm);
        if (!want.length) return res(0, 'no answer key');
        var hit = got.filter(function (g) { return want.indexOf(g) > -1; }).length;
        var wrong = got.filter(function (g) { return want.indexOf(g) === -1; }).length;
        return res(Math.max(0, hit - wrong) / want.length,
                   hit + ' of ' + want.length + ' correct' + (wrong ? ', ' + wrong + ' wrong' : ''));
      }

      if (t === 'essay' || t === 'code') {
        return { earned: 0, max: max, fraction: 0, correct: false, pending: true, detail: 'awaiting teacher review' };
      }

      /* Everything else — the classic binary matcher keeps ownership. */
      var okOne = (w.CBT && CBT.isCorrect) ? CBT.isCorrect(q, given) : (norm(given) === norm(Array.isArray(q.answer) ? q.answer[0] : q.answer));
      return res(okOne ? 1 : 0);
    },

    /* Shared styles, injected once by pages that use the engine. */
    injectStyles: function () {
      if (d.getElementById('scq-styles')) return;
      var st = d.createElement('style');
      st.id = 'scq-styles';
      st.textContent =
        '.scq-howto{background:#eff6ff;border:1px solid #bfdbfe;color:#1e3a8a;border-radius:10px;padding:8px 12px;font-size:.82rem;margin:0 0 10px;display:flex;gap:8px;align-items:flex-start}' +
        '.scq-hint{font-size:.78rem;color:#475569;margin:6px 0}' +
        '.scq-warn{background:#fef2f2;border:1px solid #fecaca;color:#991b1b;border-radius:10px;padding:8px 12px;font-size:.85rem}' +
        '.scq-input{width:100%;max-width:420px;padding:10px 12px;border:2px solid #cbd5e1;border-radius:10px;font-size:1rem}' +
        '.scq-input:focus{border-color:#0506ae;outline:none}' +
        '.scq-blank{display:inline-block;width:110px;max-width:40vw;margin:0 4px;padding:6px 8px}' +
        '.scq-cloze{font-size:1.02rem;line-height:2.1}' +
        '.scq-numwrap{display:flex;align-items:center;gap:8px}' +
        '.scq-num{max-width:220px}' +
        '.scq-unit{font-weight:800;color:#334155}' +
        '.scq-parts{display:flex;flex-direction:column;gap:8px;margin-top:6px}' +
        '.scq-part{display:flex;align-items:center;gap:10px;flex-wrap:wrap}' +
        '.scq-part-label{min-width:90px;font-weight:700;font-size:.88rem;color:#334155}' +
        '.scq-textarea{width:100%;padding:12px;border:2px solid #cbd5e1;border-radius:12px;font-size:1rem;line-height:1.55}' +
        '.scq-textarea:focus{border-color:#0506ae;outline:none}' +
        '.scq-code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.9rem;background:#0f172a;color:#e2e8f0;border-color:#334155}' +
        '.scq-match{width:100%;border-collapse:collapse;margin:6px 0}' +
        '.scq-match td,.scq-match th{padding:8px 10px;border-bottom:1px solid #e2e8f0;text-align:left;vertical-align:middle}' +
        '.scq-match-left{font-weight:700;color:#0f172a;max-width:46%}' +
        '.scq-match-arrow{color:#94a3b8;width:24px}' +
        '.scq-select{width:100%;max-width:340px;padding:8px 10px;border:2px solid #cbd5e1;border-radius:10px;font-size:.95rem;background:#fff}' +
        '.scq-matrix th{font-size:.8rem;text-transform:uppercase;letter-spacing:.04em;color:#475569}' +
        '.scq-matrix-cell{text-align:center}' +
        '.scq-matrix-cell input{width:20px;height:20px;accent-color:#0506ae}' +
        '.scq-sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}' +
        '.scq-order{list-style:none;padding:0;margin:8px 0;display:flex;flex-direction:column;gap:8px}' +
        '.scq-order-item{display:flex;align-items:center;gap:10px;background:#fff;border:2px solid #cbd5e1;border-radius:12px;padding:10px 12px;cursor:grab}' +
        '.scq-order-item.is-dragging{opacity:.55;border-color:#0506ae}' +
        '.scq-order-handle{color:#94a3b8;font-size:1.05rem}' +
        '.scq-order-num{min-width:26px;height:26px;border-radius:50%;background:#eef2ff;color:#0506ae;font-weight:800;display:inline-flex;align-items:center;justify-content:center;font-size:.82rem}' +
        '.scq-order-text{flex:1}' +
        '.scq-order-btns{display:flex;gap:6px}' +
        '.scq-mini{width:32px;height:32px;border-radius:8px;border:1px solid #cbd5e1;background:#f8fafc;font-size:1rem;cursor:pointer}' +
        '.scq-mini:hover{background:#eef2ff;border-color:#0506ae}' +
        '.scq-hot{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0}' +
        '.scq-chip{border:2px solid #cbd5e1;background:#fff;border-radius:999px;padding:8px 14px;font-size:.92rem;cursor:pointer}' +
        '.scq-chip.is-on{background:linear-gradient(135deg,#0506ae,#964eec);color:#fff;border-color:#0506ae;font-weight:700}' +
        '.scq-ar{background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px;padding:10px 12px;margin:0 0 10px;display:flex;flex-direction:column;gap:8px}' +
        '.scq-ar-row{display:flex;gap:10px;align-items:flex-start}' +
        '.scq-ar-tag{background:#0506ae;color:#fff;border-radius:8px;padding:2px 8px;font-size:.72rem;font-weight:800;text-transform:uppercase;letter-spacing:.05em;white-space:nowrap}' +
        '.scq-ar-reason{background:#964eec}' +
        '.scq-legend{max-height:70vh;overflow:auto}' +
        '.scq-legend-intro{color:#334155}' +
        '.scq-legend-row{display:grid;grid-template-columns:170px 1fr;gap:10px;padding:7px 0;border-bottom:1px solid #f1f5f9;font-size:.88rem}' +
        '.scq-legend-row b{color:#0506ae}' +
        '.scq-legend-more{margin:14px 0 4px;color:#334155}' +
        '.scq-legend-foot{background:#f0fdf4;border:1px solid #bbf7d0;color:#166534;border-radius:10px;padding:10px 12px;font-size:.84rem;margin-top:12px}' +
        '@media(max-width:640px){.scq-legend-row{grid-template-columns:1fr;gap:2px}}';
      d.head.appendChild(st);
    }
  };

  w.CBTTypes = CBTTypes;
})(window, document);
