/* ============================================================================
   cbt-richtext.js — V39 · self-contained rich-text + maths renderer
   ----------------------------------------------------------------------------
   THE BUG THIS SOLVES (reported)
   A CSV generated with the "Multi-Line maths / STEM" prompt reached the
   candidate looking like this:

       Solve the simultaneous equations:\n2x + 3y = 12\nx - y = 1
       Simplify \frac{3x+6}{9}

   Two separate problems, both fatal to readability:

     1. LITERAL ESCAPES.  A CSV cell cannot hold a real newline unless it is
        quoted and wrapped, so the generator writes the two characters
        backslash + n.  Nothing downstream ever turned those back into line
        breaks, and `white-space:pre-wrap` cannot help because the character
        in the string is a backslash, not U+000A.
     2. RAW LaTeX.  \frac{}{}, \sqrt{}, ^{}, _{}, \times, matrices and Greek
        letters were passed through TC.esc() and printed verbatim.

   WHY NOT KaTeX / MathJax
   This platform is a zero-dependency offline-first PWA. Pulling a 300 KB
   CDN library would break the offline shell, break the sandboxed preview,
   cost money on metered Nigerian data, and add a third-party point of
   failure to an exam runtime. So this file renders the LaTeX subset that
   school maths actually uses, in about 12 KB, with no network and no
   dependencies. It degrades to readable plain text for anything it does
   not recognise — it never shows a raw backslash command to a candidate.

   THE \n VS \neq AMBIGUITY
   Both start with a backslash, so a naive .replace(/\\n/g,'\n') turns the
   "not equal" sign into a line break followed by the letters "eq". The
   tokeniser below resolves this deterministically:
        1. exact match against the known-command table   (\neq, \ne, \nabla)
        2. else, a leading n / t / r is an escape         (\nGive -> newline)
        3. else, longest known command prefix
        4. else, emit literally
   That is why \neq renders as ≠ while \nGive renders as a line break.

   SECURITY
   The input is HTML-escaped BEFORE any transformation, and every
   transformation emits only markup this file generates. No user text is
   ever interpolated into an attribute or executed. Output is safe for
   innerHTML.

   API
     CBTRich.html(text)        -> HTML string, safe to innerHTML
     CBTRich.plain(text)       -> flattened text (for TTS, CSV preview, aria)
     CBTRich.decode(text)      -> literal escapes turned into real characters
     CBTRich.hasMath(text)     -> boolean
     CBTRich.injectCSS()       -> idempotent stylesheet install
   ========================================================================== */
(function (w, d) {
  'use strict';

  if (w.CBTRich) return;   // idempotent: safe if loaded twice

  /* ------------------------------------------------------------------ *
   * 1. Symbol table — the LaTeX commands school papers actually use.    *
   * ------------------------------------------------------------------ */
  var SYM = {
    /* relations */
    times:'×', div:'÷', cdot:'·', pm:'±', mp:'∓', ast:'∗', star:'⋆',
    le:'≤', leq:'≤', ge:'≥', geq:'≥', ne:'≠', neq:'≠', equiv:'≡',
    approx:'≈', sim:'∼', simeq:'≃', cong:'≅', propto:'∝', doteq:'≐',
    ll:'≪', gg:'≫', subset:'⊂', supset:'⊃', subseteq:'⊆', supseteq:'⊇',
    in:'∈', notin:'∉', ni:'∋', cup:'∪', cap:'∩', emptyset:'∅', varnothing:'∅',
    setminus:'∖', forall:'∀', exists:'∃', nexists:'∄', neg:'¬', lnot:'¬',
    land:'∧', lor:'∨', oplus:'⊕', otimes:'⊗',
    /* arrows */
    to:'→', rightarrow:'→', Rightarrow:'⇒', leftarrow:'←', Leftarrow:'⇐',
    leftrightarrow:'↔', Leftrightarrow:'⇔', mapsto:'↦', implies:'⟹', iff:'⟺',
    uparrow:'↑', downarrow:'↓', longrightarrow:'⟶', longleftarrow:'⟵',
    /* operators / big */
    sum:'∑', prod:'∏', int:'∫', iint:'∬', iiint:'∭', oint:'∮',
    partial:'∂', nabla:'∇', infty:'∞', surd:'√', angle:'∠', measuredangle:'∡',
    triangle:'△', square:'□', perp:'⊥', parallel:'∥', nparallel:'∦',
    therefore:'∴', because:'∵', degree:'°', deg:'°', prime:'′', dagger:'†',
    ldots:'…', cdots:'⋯', vdots:'⋮', ddots:'⋱', dots:'…',
    /* Greek — lower */
    alpha:'α', beta:'β', gamma:'γ', delta:'δ', epsilon:'ε', varepsilon:'ε',
    zeta:'ζ', eta:'η', theta:'θ', vartheta:'ϑ', iota:'ι', kappa:'κ',
    lambda:'λ', mu:'μ', nu:'ν', xi:'ξ', pi:'π', rho:'ρ', sigma:'σ',
    tau:'τ', upsilon:'υ', phi:'φ', varphi:'φ', chi:'χ', psi:'ψ', omega:'ω',
    /* Greek — upper */
    Gamma:'Γ', Delta:'Δ', Theta:'Θ', Lambda:'Λ', Xi:'Ξ', Pi:'Π',
    Sigma:'Σ', Upsilon:'Υ', Phi:'Φ', Psi:'Ψ', Omega:'Ω',
    /* currency / misc */
    naira:'₦', pounds:'£', euro:'€', percent:'%', ' ':' ', quad:'  ', qquad:'    '
  };

  /* Functions that should render upright, not italic. */
  var FUNCS = ['sin','cos','tan','sec','csc','cot','sinh','cosh','tanh',
    'arcsin','arccos','arctan','log','ln','lg','exp','lim','limsup','liminf',
    'max','min','det','dim','ker','gcd','lcm','mod','bmod','Pr','arg','sup','inf'];

  /* Commands taking one braced argument, rendered by a wrapper. */
  var WRAP1 = {
    text:'t', textrm:'t', mathrm:'t', textnormal:'t', mbox:'t',
    mathbf:'b', textbf:'b', bf:'b',
    mathit:'i', textit:'i', emph:'i',
    mathsf:'s', mathtt:'m', texttt:'m',
    overline:'ovl', bar:'ovl', underline:'unl',
    vec:'vec', hat:'hat', tilde:'tld', dot:'dot', ddot:'ddot',
    boxed:'box'
  };

  var MATRIX_ENV = {
    pmatrix:['(' , ')'], bmatrix:['[' , ']'], Bmatrix:['{' , '}'],
    vmatrix:['|' , '|'], Vmatrix:['‖','‖'], matrix:['' , ''],
    smallmatrix:['','']
  };

  var KNOWN = {};
  Object.keys(SYM).forEach(function (k) { KNOWN[k] = 1; });
  FUNCS.forEach(function (k) { KNOWN[k] = 1; });
  Object.keys(WRAP1).forEach(function (k) { KNOWN[k] = 1; });
  ['frac','dfrac','tfrac','cfrac','sqrt','begin','end','left','right',
   'binom','choose','over','operatorname','displaystyle','textstyle',
   'limits','nolimits','!',','].forEach(function (k) { KNOWN[k] = 1; });

  /* ------------------------------------------------------------------ *
   * 2. Helpers                                                          *
   * ------------------------------------------------------------------ */
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  /* Read a {...} group starting at s[i] === '{'. Returns [content, nextIndex]. */
  function group(s, i) {
    if (s.charAt(i) !== '{') {
      // a single token argument, e.g. \frac12 or ^2
      if (s.charAt(i) === '\\') {
        var m = /^\\[a-zA-Z]+/.exec(s.slice(i));
        if (m) return [m[0], i + m[0].length];
      }
      var t0 = s.charAt(i) || '', j0 = i + 1;
      if ((t0 === '+' || t0 === '-') && j0 < s.length) {
        var m3 = /^\\[a-zA-Z]+/.exec(s.slice(j0));
        if (m3) return [t0 + m3[0], j0 + m3[0].length];
        if (s.charAt(j0) !== '{') { t0 += s.charAt(j0); j0 += 1; }
        else { var g3r = group(s, j0); return [t0 + g3r[0], g3r[1]]; }
      }
      return [t0, j0];
    }
    var depth = 0, out = '', j = i;
    for (; j < s.length; j++) {
      var c = s.charAt(j);
      if (c === '{') { depth++; if (depth === 1) continue; }
      else if (c === '}') { depth--; if (depth === 0) { j++; break; } }
      out += c;
    }
    return [out, j];
  }

  /* Optional [..] argument, for \sqrt[3]{x}. */
  function optArg(s, i) {
    if (s.charAt(i) !== '[') return ['', i];
    var j = s.indexOf(']', i);
    if (j < 0) return ['', i];
    return [s.slice(i + 1, j), j + 1];
  }

  /* ------------------------------------------------------------------ *
   * 3. Maths renderer — turns a LaTeX fragment into HTML.               *
   * ------------------------------------------------------------------ */
  function math(src) {
    var out = '', i = 0, n = src.length;

    while (i < n) {
      var c = src.charAt(i);

      /* ---- backslash command ---- */
      if (c === '\\') {
        /* \\ = hard line break inside maths */
        if (src.charAt(i + 1) === '\\') { out += '<br>'; i += 2; continue; }

        var m = /^\\([a-zA-Z]+)/.exec(src.slice(i));
        if (!m) {
          /* \{ \} \$ \% \_ \& and friends */
          var lit = src.charAt(i + 1);
          if (lit) { out += esc(lit); i += 2; }
          else { i += 1; }
          continue;
        }
        var cmd = m[1], adv = m[0].length;

        /* (1) exact known command */
        if (!KNOWN[cmd]) {
          /* (2) a leading n / t / r is a literal escape, not a command.
                 This is the \n vs \neq resolution described at the top. */
          if (/^[ntr]/.test(cmd)) {
            var ch = cmd.charAt(0);
            out += (ch === 'n' ? '<br>' : ch === 't' ? '&#9;' : '');
            i += 2;
            continue;
          }
          /* (3) longest known prefix */
          var pref = '';
          for (var L = cmd.length - 1; L >= 2; L--) {
            if (KNOWN[cmd.slice(0, L)]) { pref = cmd.slice(0, L); break; }
          }
          if (pref) { cmd = pref; adv = 1 + pref.length; }
          else { /* (4) unknown — show the word, drop the backslash */
            out += esc(cmd); i += adv; continue; }
        }

        i += adv;

        /* --- fractions --- */
        if (cmd === 'frac' || cmd === 'dfrac' || cmd === 'tfrac' || cmd === 'cfrac') {
          var a = group(src, i); i = a[1];
          var b = group(src, i); i = b[1];
          out += '<span class="tcm-frac"><span class="tcm-num">' + math(a[0]) +
                 '</span><span class="tcm-den">' + math(b[0]) + '</span></span>';
          continue;
        }
        if (cmd === 'binom' || cmd === 'choose') {
          var b1 = group(src, i); i = b1[1];
          var b2 = group(src, i); i = b2[1];
          out += '<span class="tcm-paren">(</span><span class="tcm-frac tcm-nobar">' +
                 '<span class="tcm-num">' + math(b1[0]) + '</span>' +
                 '<span class="tcm-den">' + math(b2[0]) + '</span></span>' +
                 '<span class="tcm-paren">)</span>';
          continue;
        }
        /* --- roots --- */
        if (cmd === 'sqrt') {
          var o = optArg(src, i); i = o[1];
          var r = group(src, i); i = r[1];
          out += (o[0] ? '<sup class="tcm-root">' + math(o[0]) + '</sup>' : '') +
                 '<span class="tcm-sqrt">&radic;<span class="tcm-rad">' + math(r[0]) + '</span></span>';
          continue;
        }
        /* --- environments --- */
        if (cmd === 'begin') {
          var e = group(src, i); i = e[1];
          var env = e[0].replace(/\*$/, '');
          var endTok = '\\end{' + e[0] + '}';
          var endAt = src.indexOf(endTok, i);
          if (endAt < 0) { endAt = src.length; }
          var body = src.slice(i, endAt);
          i = (endAt === src.length) ? src.length : endAt + endTok.length;
          out += environment(env, body);
          continue;
        }
        if (cmd === 'end') { var eg = group(src, i); i = eg[1]; continue; }
        /* --- sizing wrappers we can safely drop --- */
        if (cmd === 'left' || cmd === 'right') {
          var dc = src.charAt(i); i += 1;
          if (dc === '.') continue;
          if (dc === '\\') { var mm = /^\\[a-zA-Z]+/.exec(src.slice(i - 1)); if (mm) { i += mm[0].length - 1; } continue; }
          out += '<span class="tcm-paren">' + esc(dc) + '</span>';
          continue;
        }
        if (cmd === 'displaystyle' || cmd === 'textstyle' || cmd === 'limits' || cmd === 'nolimits') continue;
        if (cmd === '!' ) continue;
        if (cmd === 'operatorname') { var op = group(src, i); i = op[1]; out += '<span class="tcm-fn">' + esc(op[0]) + '</span>'; continue; }

        /* --- one-argument wrappers --- */
        if (WRAP1[cmd]) {
          var g = group(src, i); i = g[1];
          var kind = WRAP1[cmd], inner = (kind === 't') ? esc(g[0]) : math(g[0]);
          if (kind === 't') out += '<span class="tcm-text">' + inner + '</span>';
          else if (kind === 'b') out += '<b>' + inner + '</b>';
          else if (kind === 'i') out += '<i>' + inner + '</i>';
          else if (kind === 's') out += '<span style="font-family:system-ui">' + inner + '</span>';
          else if (kind === 'm') out += '<code>' + inner + '</code>';
          else if (kind === 'ovl') out += '<span class="tcm-ovl">' + inner + '</span>';
          else if (kind === 'unl') out += '<span class="tcm-unl">' + inner + '</span>';
          else if (kind === 'box') out += '<span class="tcm-box">' + inner + '</span>';
          else out += '<span class="tcm-acc" data-a="' +
                      (kind === 'vec' ? '→' : kind === 'hat' ? '^' : kind === 'tld' ? '~' : kind === 'dot' ? '˙' : '¨') +
                      '">' + inner + '</span>';
          continue;
        }
        /* --- upright functions --- */
        if (FUNCS.indexOf(cmd) > -1) { out += '<span class="tcm-fn">' + cmd + '</span>'; continue; }
        /* --- plain symbol --- */
        if (SYM[cmd] != null) { out += esc(SYM[cmd]); continue; }
        out += esc(cmd);
        continue;
      }

      /* ---- superscript / subscript ---- */
      if (c === '^' || c === '_') {
        var gg = group(src, i + 1); i = gg[1];
        out += (c === '^' ? '<sup>' : '<sub>') + math(gg[0]) + (c === '^' ? '</sup>' : '</sub>');
        continue;
      }
      /* ---- brace groups ---- */
      if (c === '{') { var gr = group(src, i); i = gr[1]; out += math(gr[0]); continue; }
      if (c === '}') { i += 1; continue; }
      /* ---- real newline inside maths ---- */
      if (c === '\n') { out += '<br>'; i += 1; continue; }

      out += esc(c);
      i += 1;
    }
    return out;
  }

  /* Matrices, cases, aligned — rendered as real tables so columns line up. */
  function environment(env, body) {
    if (env === 'cases') {
      var rows = body.split(/\\\\/);
      return '<span class="tcm-cases"><span class="tcm-brace">{</span><span class="tcm-casesrows">' +
        rows.map(function (r) {
          var cells = r.split('&');
          return '<span class="tcm-caserow">' + cells.map(function (cc) {
            return '<span class="tcm-casecell">' + math(cc.trim()) + '</span>';
          }).join('') + '</span>';
        }).join('') + '</span></span>';
    }
    if (MATRIX_ENV[env]) {
      var br = MATRIX_ENV[env];
      var rws = body.split(/\\\\/).map(function (r) { return r.trim(); })
                    .filter(function (r) { return r !== ''; });
      /* Render each row as a column list. To make every element sit directly
         under the same column (item 3 — [2 3] over [5 7], or [12 3] over
         [500 7]) the wrapper is a CSS grid with one column per element and the
         cells auto-placed row-major. Equal column widths keep the vertical
         line dead straight even when the digits differ in size. */
      var ncols = 1;
      rws.forEach(function (r) { ncols = Math.max(ncols, r.split('&').length); });
      var tbl = '<span class="tcm-mtable" style="--ncols:' + ncols + '">' + rws.map(function (r) {
        return '<span class="tcm-mrow">' + r.split('&').map(function (cc) {
          return '<span class="tcm-mcell">' + math(cc.trim()) + '</span>';
        }).join('') + '</span>';
      }).join('') + '</span>';
      return '<span class="tcm-matrix">' +
        (br[0] ? '<span class="tcm-mbrk">' + esc(br[0]) + '</span>' : '') + tbl +
        (br[1] ? '<span class="tcm-mbrk">' + esc(br[1]) + '</span>' : '') + '</span>';
    }
    if (env === 'aligned' || env === 'align' || env === 'align*' || env === 'gather' || env === 'array') {
      var ar = body.split(/\\\\/).filter(function (r) { return r.trim() !== ''; });
      var ncols2 = 1;
      ar.forEach(function (r) { ncols2 = Math.max(ncols2, r.split('&').length); });
      return '<span class="tcm-mtable tcm-align" style="--ncols:' + ncols2 + '">' + ar.map(function (r) {
        return '<span class="tcm-mrow">' + r.split('&').map(function (cc) {
          return '<span class="tcm-mcell">' + math(cc.trim()) + '</span>';
        }).join('') + '</span>';
      }).join('') + '</span>';
    }
    /* unknown environment — render the body so nothing is lost */
    return math(body);
  }

  /* ------------------------------------------------------------------ *
   * 4. Literal-escape decoding for the NON-maths parts of a cell.       *
   * ------------------------------------------------------------------ */
  function decodeEscapes(s) {
    var out = '', i = 0;
    while (i < s.length) {
      var c = s.charAt(i);
      if (c !== '\\') { out += c; i++; continue; }
      var nx = s.charAt(i + 1);
      if (nx === '\\') { out += '\n'; i += 2; continue; }
      if (nx === 'n')  { out += '\n'; i += 2; continue; }
      if (nx === 't')  { out += '\t'; i += 2; continue; }
      if (nx === 'r')  { i += 2; continue; }
      out += c; i++;
    }
    return out;
  }

  /* Does this fragment need the maths engine at all? */
  function looksMathy(s) {
    return /\\[a-zA-Z]|[\^_](?=[a-zA-Z0-9{(\\-])|\$|\\\(|\\\[|\\begin\{/.test(s);
  }

  /* Unicode superscripts / subscripts (1², 3², m⁴, (x+y)⁵, a₁, H₂O, x₀)
     are re-written to caret/underscore form so the maths engine draws them
     as real <sup>/<sub> that are identical on every platform — a font's own
     superscript glyphs are inconsistent and can even be missing. Doing the
     conversion here means both toHtml() and toPlain() (TTS/aria) agree:
     "1²" renders as 1<sup>2</sup> and is read "1 squared". */
  function toCaret(s) {
    var SUP = { '⁰':'0','¹':'1','²':'2','³':'3','⁴':'4','⁵':'5','⁶':'6','⁷':'7','⁸':'8','⁹':'9','⁺':'+','⁻':'-','⁼':'=','⁽':'(','⁾':')','ⁿ':'n' };
    var SUB = { '₀':'0','₁':'1','₂':'2','₃':'3','₄':'4','₅':'5','₆':'6','₇':'7','₈':'8','₉':'9','₊':'+','₋':'-','₌':'=','₍':'(','₎':')' };
    return String(s == null ? '' : s)
      .replace(/[⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿ]/g, function (m) { return '^{' + SUP[m] + '}'; })
      .replace(/[₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎]/g, function (m) { return '_{' + SUB[m] + '}'; });
  }

  /* ------------------------------------------------------------------ *
   * 5. Public renderer                                                  *
   * ------------------------------------------------------------------ */
  /* A cell is a mix of prose and maths. Explicit delimiters ($…$, $$…$$,
     \(…\), \[…\]) are honoured; anything else containing backslash commands
     is rendered by the maths engine too, because the STEM prompt emits bare
     \frac outside delimiters and candidates must still see a fraction. */
  function toHtml(raw) {
    var s = toCaret(String(raw == null ? '' : raw));
    if (!s) return '';

    /* Split on explicit maths delimiters, keeping the delimiters' content. */
    var parts = [], re = /(\$\$[\s\S]*?\$\$|\$[^$\n]*?\$|\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\])/g;
    var last = 0, mm;
    while ((mm = re.exec(s)) !== null) {
      if (mm.index > last) parts.push({ t: 'txt', v: s.slice(last, mm.index) });
      var body = mm[0];
      if (body.slice(0, 2) === '$$') body = body.slice(2, -2);
      else if (body.charAt(0) === '$') body = body.slice(1, -1);
      else body = body.slice(2, -2);
      parts.push({ t: 'math', v: body, display: mm[0].slice(0, 2) === '$$' || mm[0].slice(0, 2) === '\\[' });
      last = mm.index + mm[0].length;
    }
    if (last < s.length) parts.push({ t: 'txt', v: s.slice(last) });

    return parts.map(function (p) {
      if (p.t === 'math') {
        return '<span class="tcm' + (p.display ? ' tcm-display' : '') + '">' + math(p.v) + '</span>';
      }
      /* Plain-ish text. If it carries backslash commands, hand the whole
         fragment to the maths engine (it handles \n and prose safely).
         Otherwise just decode escapes and convert newlines. */
      if (looksMathy(p.v)) return '<span class="tcm tcm-inline">' + math(p.v).replace(/\]\s*\[/g, ']<br>[') + '</span>';
      return esc(decodeEscapes(p.v)).replace(/\n/g, '<br>').replace(/\t/g, '&#9;&#9;').replace(/\]\s*\[/g, ']<br>[');
    }).join('');
  }

  /* ------------------------------------------------------------------ *
   * 5b. Speech renderer.                                                *
   * ------------------------------------------------------------------ *
   * Read-aloud cannot speak the HTML above: a screen reader hitting the
   * fraction markup says "3x plus 6 9", which is a different question.
   * So maths is re-rendered a second time into English words, using the
   * same tokeniser rules. "\frac{3x+6}{9}" becomes "the fraction 3 x plus
   * 6, over 9,". Operators become words, superscripts become "to the power
   * of", and matrices are read row by row.                               */

  var SAY = {
    '+':' plus ', '-':' minus ', '=':' equals ', '<':' is less than ',
    '>':' is greater than ', '/':' divided by ', '*':' times ',
    '×':' times ', '÷':' divided by ', '±':' plus or minus ',
    '≤':' is less than or equal to ', '≥':' is greater than or equal to ',
    '≠':' is not equal to ', '≈':' is approximately ', '≡':' is identical to ',
    '∞':' infinity ', '°':' degrees ', '√':' the square root of ',
    '∑':' the sum of ', '∏':' the product of ', '∫':' the integral of ',
    '∴':' therefore ', '∵':' because ', '∈':' is a member of ',
    '∪':' union ', '∩':' intersection ', '→':' gives ', '⇒':' implies ',
    '₦':' naira ', '%':' percent ', '|':' the modulus of '
  };

  /* "3" -> "cube", "4" -> "fourth", so \\sqrt[3]{27} reads naturally. */
  var ORD = { '2':'square', '3':'cube', '4':'fourth', '5':'fifth', '6':'sixth',
              '7':'seventh', '8':'eighth', '9':'ninth', '10':'tenth', 'n':'nth' };
  function ordinal(x) {
    var k = String(x).trim();
    return ORD[k] || (k + 'th');
  }

  /* Greek letters must be NAMED, not passed to the voice as a glyph: most
     free system voices skip characters they have no phoneme for, silently
     dropping the variable out of the question. */
  var GREEK = {};
  ['alpha','beta','gamma','delta','epsilon','zeta','eta','theta','iota','kappa',
   'lambda','mu','nu','xi','pi','rho','sigma','tau','upsilon','phi','chi','psi',
   'omega'].forEach(function (g) {
    GREEK[g] = g;
    var U = g.charAt(0).toUpperCase() + g.slice(1);
    GREEK[U] = 'capital ' + g;
    GREEK['var' + g] = g;
  });

  /* Expand terse function tokens the voice would otherwise spell out. */
  var SAYFN = { ln:'the natural log of', log:'log', exp:'e to the power',
                lim:'the limit of', det:'the determinant of', gcd:'the H C F of',
                lcm:'the L C M of', sin:'sine', cos:'cosine', tan:'tan',
                sec:'secant', csc:'cosecant', cot:'cotangent',
                arcsin:'inverse sine', arccos:'inverse cosine', arctan:'inverse tan' };

  function speakMath(src) {
    var out = '', i = 0, n = src.length;
    while (i < n) {
      var c = src.charAt(i);

      if (c === '\\') {
        if (src.charAt(i + 1) === '\\') { out += '. '; i += 2; continue; }
        var m = /^\\([a-zA-Z]+)/.exec(src.slice(i));
        if (!m) { var l = src.charAt(i + 1); out += (l || ''); i += (l ? 2 : 1); continue; }
        var cmd = m[1], adv = m[0].length;

        if (!KNOWN[cmd]) {
          if (/^[ntr]/.test(cmd)) { out += (cmd.charAt(0) === 'r' ? '' : '. '); i += 2; continue; }
          var pf = '';
          for (var L = cmd.length - 1; L >= 2; L--) { if (KNOWN[cmd.slice(0, L)]) { pf = cmd.slice(0, L); break; } }
          if (pf) { cmd = pf; adv = 1 + pf.length; }
          else { out += ' ' + cmd + ' '; i += adv; continue; }
        }
        i += adv;

        if (cmd === 'frac' || cmd === 'dfrac' || cmd === 'tfrac' || cmd === 'cfrac') {
          var a = group(src, i); i = a[1];
          var b = group(src, i); i = b[1];
          out += ' the fraction ' + speakMath(a[0]) + ', over ' + speakMath(b[0]) + ', ';
          continue;
        }
        if (cmd === 'binom' || cmd === 'choose') {
          var q1 = group(src, i); i = q1[1];
          var q2 = group(src, i); i = q2[1];
          out += ' ' + speakMath(q1[0]) + ' choose ' + speakMath(q2[0]) + ' ';
          continue;
        }
        if (cmd === 'sqrt') {
          var o = optArg(src, i); i = o[1];
          var r = group(src, i); i = r[1];
          out += (o[0] ? ' the ' + ordinal(o[0]) + ' root of ' : ' the square root of ') +
                 speakMath(r[0]) + ', ';
          continue;
        }
        if (cmd === 'begin') {
          var e = group(src, i); i = e[1];
          var envn = e[0].replace(/\*$/, '');
          var tok = '\\end{' + e[0] + '}', at = src.indexOf(tok, i);
          if (at < 0) at = src.length;
          var body = src.slice(i, at);
          i = (at === src.length) ? at : at + tok.length;
          var rows = body.split(/\\\\/).filter(function (x) { return x.trim(); });
          var word = MATRIX_ENV[envn] ? 'matrix' : (envn === 'cases' ? 'cases' : 'group');
          out += ' the ' + word + ', ' + rows.map(function (r, ix) {
            return 'row ' + (ix + 1) + ': ' + r.split('&').map(function (cc) {
              return speakMath(cc.trim());
            }).join(', ');
          }).join('; ') + '. end ' + word + '. ';
          continue;
        }
        if (cmd === 'end') { var eg2 = group(src, i); i = eg2[1]; continue; }
        if (cmd === 'left' || cmd === 'right') {
          var dc = src.charAt(i); i += 1;
          if (dc === '\\') { var m2 = /^\\[a-zA-Z]+/.exec(src.slice(i - 1)); if (m2) i += m2[0].length - 1; }
          continue;
        }
        if (cmd === 'displaystyle' || cmd === 'textstyle' || cmd === 'limits' ||
            cmd === 'nolimits' || cmd === '!') continue;
        if (WRAP1[cmd] || cmd === 'operatorname') {
          var g2 = group(src, i); i = g2[1];
          var pre = (cmd === 'vec') ? 'vector ' : (cmd === 'overline' || cmd === 'bar') ? 'bar ' :
                    (cmd === 'hat') ? 'hat ' : '';
          out += ' ' + pre + speakMath(g2[0]) + ' ';
          continue;
        }
        if (FUNCS.indexOf(cmd) > -1) { out += ' ' + (SAYFN[cmd] || cmd) + ' '; continue; }
        if (GREEK[cmd]) { out += ' ' + GREEK[cmd] + ' '; continue; }
        if (SYM[cmd] != null) { out += (SAY[SYM[cmd]] || ' ' + SYM[cmd] + ' '); continue; }
        out += ' ' + cmd + ' ';
        continue;
      }

      if (c === '^') {
        var s1 = group(src, i + 1); i = s1[1];
        var sv = s1[0];
        out += (sv === '2' ? ' squared ' : sv === '3' ? ' cubed ' :
                ' to the power of ' + speakMath(sv) + ', ');
        continue;
      }
      if (c === '_') { var s2 = group(src, i + 1); i = s2[1]; out += ' sub ' + speakMath(s2[0]) + ' '; continue; }
      if (c === '{') { var g3 = group(src, i); i = g3[1]; out += speakMath(g3[0]); continue; }
      if (c === '}') { i += 1; continue; }
      if (c === '\n') { out += '. '; i += 1; continue; }
      if (c === '&') { out += ', '; i += 1; continue; }

      out += (SAY[c] != null ? SAY[c] : c);
      i += 1;
    }
    return out;
  }

  /* Flatten to speech/plain text — used by the read-aloud engine and aria. */
  function toPlain(raw) {
    var s = toCaret(String(raw == null ? '' : raw));
    if (!s) return '';
    var re = /(\$\$[\s\S]*?\$\$|\$[^$\n]*?\$|\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\])/g;
    var out = '', last = 0, mm;
    function chunk(v) {
      return looksMathy(v) ? speakMath(v) : decodeEscapes(v).replace(/\n/g, '. ');
    }
    while ((mm = re.exec(s)) !== null) {
      if (mm.index > last) out += chunk(s.slice(last, mm.index));
      var body = mm[0];
      if (body.slice(0, 2) === '$$') body = body.slice(2, -2);
      else if (body.charAt(0) === '$') body = body.slice(1, -1);
      else body = body.slice(2, -2);
      out += ' ' + speakMath(body) + ' ';
      last = mm.index + mm[0].length;
    }
    if (last < s.length) out += chunk(s.slice(last));

    return out
      .replace(/&nbsp;/g, ' ').replace(/&amp;/g, ' and ')
      .replace(/&lt;/g, ' less than ').replace(/&gt;/g, ' greater than ')
      .replace(/&quot;/g, '"').replace(/&#9;/g, ' ')
      .replace(/[ \t]+/g, ' ')
      .replace(/ ([,.;:])/g, '$1')
      .replace(/([,.;:]){2,}/g, '$1')
      .replace(/\.\s*\./g, '.')
      .trim();
  }

  /* ------------------------------------------------------------------ *
   * 6. Stylesheet — injected once, no external file.                    *
   * ------------------------------------------------------------------ */
  var CSS = [
    /* Baseline: normal prose spacing. Only a block that actually contains a
       stacked construction gets the extra leading it needs, so a paper of
       plain text is not double-spaced for no reason. */
    '.tcm{display:inline;line-height:1.75}',
    '.tcm:has(.tcm-frac),.tcm:has(.tcm-matrix),.tcm:has(.tcm-cases),.tcm:has(.tcm-sqrt){line-height:2.15}',
    '.tcm-display{display:block;margin:10px 0;text-align:center;font-size:1.06em}',
    /* vertical-align:middle centres the whole fraction box on the parent's
       x-height midpoint, which is where a reader expects it. A fixed em
       offset (the first attempt) drifted out of place as soon as the stem
       mixed font sizes or the numerator was itself a fraction. */
    '.tcm-frac{display:inline-flex;flex-direction:column;vertical-align:middle;',
      'text-align:center;margin:0 .2em;line-height:1.18;font-size:.98em}',
    '.tcm-frac>.tcm-num{display:block;padding:0 .32em;border-bottom:1.6px solid currentColor}',
    '.tcm-frac.tcm-nobar>.tcm-num{border-bottom:none}',
    '.tcm-frac>.tcm-den{display:block;padding:0 .32em}',
    '.tcm-sqrt{display:inline-flex;align-items:flex-start;white-space:nowrap}',
    '.tcm-sqrt>.tcm-rad{border-top:1.6px solid currentColor;padding:.12em .28em 0 .18em;margin-left:-.06em}',
    '.tcm-root{font-size:.68em;position:relative;left:.5em;top:-.15em}',
    '.tcm-fn{font-style:normal;padding-right:.18em}',
    '.tcm-text{font-style:normal}',
    '.tcm-ovl{border-top:1.5px solid currentColor;padding-top:.06em}',
    '.tcm-unl{border-bottom:1.5px solid currentColor;padding-bottom:.06em}',
    '.tcm-box{border:1.4px solid currentColor;border-radius:4px;padding:.06em .3em}',
    '.tcm-acc{position:relative;display:inline-block}',
    '.tcm-acc::before{content:attr(data-a);position:absolute;top:-.72em;left:50%;',
      'transform:translateX(-50%);font-size:.8em;line-height:1}',
    '.tcm-paren{padding:0 .04em}',
    '.tcm-matrix{display:inline-flex;align-items:stretch;vertical-align:middle;margin:0 .2em}',
    '.tcm-mbrk{display:flex;align-items:center;font-size:1.9em;line-height:1;font-weight:300}',
    '.tcm-mtable{display:grid;grid-template-columns:repeat(var(--ncols,1),minmax(1.1em,auto));',
      'gap:.18em .6em;padding:.1em .35em;justify-items:center;justify-content:center}',
    '.tcm-mrow{display:contents}',
    '.tcm-mcell{min-width:1.1em;text-align:center}',
    '.tcm-align .tcm-mtable{justify-content:flex-start}',
    '.tcm-cases{display:inline-flex;align-items:center;vertical-align:middle}',
    '.tcm-brace{font-size:2.1em;line-height:1;font-weight:300}',
    '.tcm-casesrows{display:inline-flex;flex-direction:column;gap:.18em;padding-left:.2em}',
    '.tcm-caserow{display:flex;gap:.7em}',
    /* keep long stems readable on a phone */
    '.cbt-q .tcm,.cbt-rich{overflow-x:auto;max-width:100%}',
    '@media (max-width:520px){.tcm-display{font-size:1em}}'
  ].join('');

  function injectCSS() {
    if (d.getElementById('tcm-style')) return;
    var st = d.createElement('style');
    st.id = 'tcm-style';
    st.textContent = CSS;
    (d.head || d.documentElement).appendChild(st);
  }

  /* ------------------------------------------------------------------ *
   * 7. Export                                                           *
   * ------------------------------------------------------------------ */
  w.CBTRich = {
    html: function (t) { injectCSS(); return toHtml(t); },
    plain: toPlain,
    decode: decodeEscapes,
    hasMath: function (t) { return looksMathy(toCaret(t)); },
    injectCSS: injectCSS,
    _math: math
  };

  if (d.readyState === 'loading') d.addEventListener('DOMContentLoaded', injectCSS);
  else injectCSS();

})(window, document);
