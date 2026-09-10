/* ============================================================================
   cbt-speech.js — School Connect V10.8 · read-aloud for CBT candidates (ported from Adewale Classroom V39, extended with Nigerian-language support)
   ----------------------------------------------------------------------------
   REQUIREMENT
   "The platform must be able to read questions and options to students during
    a CBT, if they desire. Only free-based tools."

   WHY Web Speech API
   speechSynthesis ships inside every modern browser (Chrome, Edge, Safari,
   Firefox, Android WebView, iOS WKWebView). It uses the voices already on the
   device, needs no key, no account, no network on most platforms, and costs
   nothing per character. That is the only option consistent with this
   platform's zero-cost design law. There is no paid TTS fallback and no CDN.

   WHAT IT READS
   Never the raw cell — always CBTRich.plain(), so "\frac{3x+6}{9}" is spoken
   as "the fraction 3x plus 6, over 9". A candidate who cannot see the screen
   well still receives the same question a sighted candidate reads.

   EXAM INTEGRITY
   - Speech is candidate-initiated and per-question; nothing autoplays.
   - Reading is cancelled on question change, on submit, and on tab blur, so
     audio can never leak from a question the candidate has left.
   - The utterance is built from question + options only. Explanations and
     correct answers are never queued during a live exam; they are only
     available on the review page after grading.

   ACCESSIBILITY
   The toggle is a real <button> with aria-pressed, keyboard shortcut is
   Alt+R (read) / Alt+S (stop), and the current sentence is mirrored into an
   aria-live region for screen readers that prefer their own voice.

   API
     CBTSpeech.available()             -> boolean
     CBTSpeech.mount(container, opts)  -> inject the control bar
     CBTSpeech.readQuestion(q)         -> speak a normalized question object
     CBTSpeech.speak(text)             -> speak arbitrary text
     CBTSpeech.stop()                  -> cancel everything
     CBTSpeech.setEnabled(bool)        -> master switch (exam setting)
     CBTSpeech.prefs                   -> {rate, pitch, voiceURI, enabled}
   ========================================================================== */
(function (w, d) {
  'use strict';

  if (w.CBTSpeech) return;

  var SS  = w.speechSynthesis;
  var SSU = w.SpeechSynthesisUtterance;
  var KEY = 'sc_cbt_speech_prefs';

  var prefs = { rate: 0.95, pitch: 1, volume: 1, voiceURI: '', enabled: true };
  try {
    var saved = JSON.parse(w.localStorage.getItem(KEY) || '{}');
    Object.keys(saved).forEach(function (k) { if (k in prefs) prefs[k] = saved[k]; });
  } catch (e) { /* private mode — defaults are fine */ }

  function save() {
    try { w.localStorage.setItem(KEY, JSON.stringify(prefs)); } catch (e) {}
  }

  function available() { return !!(SS && SSU); }

  /* ------------------------------------------------------------------ *
   * Voice list. Chrome populates voices asynchronously, so we cache and *
   * refresh on the voiceschanged event rather than reading once.        *
   * ------------------------------------------------------------------ */
  var voices = [];
  function loadVoices() {
    if (!available()) return;
    try { voices = SS.getVoices() || []; } catch (e) { voices = []; }
  }
  if (available()) {
    loadVoices();
    if (typeof SS.addEventListener === 'function') SS.addEventListener('voiceschanged', function () {
      loadVoices(); refreshVoiceSelect();
    });
    else SS.onvoiceschanged = function () { loadVoices(); refreshVoiceSelect(); };
  }

  /* ------------------------------------------------------------------ *
   * V10.8 NIGERIAN-LANGUAGE SUPPORT (School Connect requirement).       *
   * Yoruba, Igbo and Hausa papers must be READ in those languages.      *
   *                                                                     *
   * 1. DETECTION. detectLang() scores the text against orthographic     *
   *    fingerprints that are essentially unique per language:           *
   *      Yoruba — under-dots ẹ ọ ṣ, tone-marked vowels à á è é ì í ò ó  *
   *               ù ú + n̄/ń, and high-frequency function words          *
   *               (àti, tí, ní, wọn, ṣe, jẹ́, kí, ni, sí, fún…).        *
   *      Igbo   — ị ọ ụ ṅ with dots/underdots, digraph frequency        *
   *               (gb kp nw ny ch), function words (na, ya, ndị, nke,   *
   *               ihe, onye, dị, bụ, ka, ma…).                          *
   *      Hausa  — hooked letters ɓ ɗ ƙ ʼy, function words (da, ba, ne,  *
   *               ta, ya, su, wanda, amma, don, cikin…).                *
   *    Latin text with none of these fingerprints stays English.        *
   * 2. VOICE MATCHING. pickVoice(langHint) first honours the user's     *
   *    saved per-language voice choice, then any device voice whose     *
   *    BCP-47 tag matches (yo/yo-NG, ig/ig-NG, ha/ha-NG — Android and   *
   *    Chrome OS ship these where the language pack is installed),      *
   *    then falls back to an African-English voice (en-NG/en-GH/en-KE), *
   *    then any English — so tone-marked text is still read rather      *
   *    than skipped, and the candidate is told which voice served.      *
   * 3. PER-CHUNK TAGGING. Each utterance carries the detected lang tag  *
   *    so engines that route by utterance.lang pick the right voice     *
   *    even when utterance.voice is unset.                              *
   * ------------------------------------------------------------------ */
  var NG_WORDS = {
    yo: ['àti','ti','tí','ni','ní','wọn','won','ṣe','se','jẹ́','jẹ','kí','sí','fún','fun','náà','naa','pẹ̀lú','pelu','bí','gbogbo','ọmọ','omo','ilé','ile','kan','yìí','yii','rẹ̀','inú','inu','lati','láti','wo','ki','je','si'],
    ig: ['na','ya','ndị','ndi','nke','ihe','onye','dị','di','bụ','bu','ka','ma','gị','gi','anyị','anyi','ha','n\u0300','ga','no','n\u2019ime','nime','otu','ụlọ','ulo','mmadụ','mmadu','oge','ego','aha','kedu','gịnị','gini'],
    ha: ['da','ba','ne','ce','ta','ya','su','shi','ita','wanda','wadda','amma','don','domin','cikin','daga','zuwa','kuma','wannan','wancan','yana','tana','suna','mutum','mutane','gida','ruwa','abinci','me','mene','yaya','nawa'],
    /* V10.9: world languages — French first (requested), then the majors. */
    fr: ['le','la','les','un','une','des','est','sont','dans','pour','avec','que','qui','quelle','quel','quels','pas','vous','nous','ils','elles','être','avoir','fait','faire','plus','mais','comme','tout','cette','ces','son','ses','aussi','entre','réponse','question','choisissez','suivant','suivante','parmi'],
    es: ['el','la','los','las','un','una','es','son','en','para','con','que','qué','cuál','no','usted','nosotros','ellos','ser','estar','hace','más','pero','como','todo','esta','este','estos','también','entre','respuesta','pregunta','elige','siguiente'],
    pt: ['o','a','os','as','um','uma','é','são','em','para','com','que','qual','não','você','nós','eles','ser','estar','faz','mais','mas','como','tudo','esta','este','também','entre','resposta','pergunta','escolha','seguinte'],
    de: ['der','die','das','ein','eine','ist','sind','in','für','mit','dass','welche','welcher','nicht','sie','wir','sein','haben','macht','mehr','aber','wie','alle','diese','dieser','auch','zwischen','antwort','frage','wählen','folgende'],
    it: ['il','lo','la','gli','le','un','una','è','sono','in','per','con','che','quale','non','voi','noi','essere','avere','fa','più','ma','come','tutto','questa','questo','anche','tra','risposta','domanda','scegli','seguente'],
    sw: ['na','ya','wa','ni','kwa','katika','hii','hiyo','ambayo','gani','si','sisi','wao','kuwa','ina','zaidi','lakini','kama','yote','pia','kati','jibu','swali','chagua','ifuatayo']
  };
  var NG_CHARS = {
    yo: /[ẹọṣ]|[àáèéìíòóùú][\u0300-\u036f]?|ǹ|ń/g,
    ig: /[ịọụṅ]/g,
    ha: /[ɓɗƙ]|ʼy|'y/g,
    fr: /[àâçéèêëîïôùûüÿœ]|«|»/g,
    es: /[áéíóúñü]|¿|¡/g,
    pt: /[ãõáâàéêíóôúç]/g,
    de: /[äöüß]/g,
    it: /[àèéìòù]/g,
    sw: null
  };
  /* Non-Latin scripts identify their language family DETERMINISTICALLY —
     one regex hit is certainty, no scoring needed. */
  var SCRIPTS = [
    [/[\u0600-\u06FF\u0750-\u077F]/, 'ar'],   // Arabic
    [/[\u3040-\u30FF]/, 'ja'],                  // Kana FIRST: Japanese mixes Kanji(Han)+Kana, Chinese never uses Kana
    [/[\u4E00-\u9FFF\u3400-\u4DBF]/, 'zh'],   // Han (Chinese)
    [/[\uAC00-\uD7AF]/, 'ko'],                  // Hangul (Korean)
    [/[\u0400-\u04FF]/, 'ru'],                  // Cyrillic
    [/[\u0900-\u097F]/, 'hi'],                  // Devanagari (Hindi)
    [/[\u0590-\u05FF]/, 'he'],                  // Hebrew
    [/[\u0E00-\u0E7F]/, 'th'],                  // Thai
    [/[\u0370-\u03FF]/, 'el'],                  // Greek
    [/[\u0980-\u09FF]/, 'bn'],                  // Bengali
    [/[\u0B80-\u0BFF]/, 'ta']                   // Tamil
  ];
    function detectLang(text) {
    var t = String(text || '');
    if (!t.trim()) return 'en';
    /* 1. Non-Latin scripts: deterministic. */
    for (var si = 0; si < SCRIPTS.length; si++) {
      if (SCRIPTS[si][0].test(t)) return SCRIPTS[si][1];
    }
    /* 2. Latin languages: orthography (×3) + stop-word (×2) scoring. */
    var lower = t.toLowerCase();
    var scores = {};
    Object.keys(NG_WORDS).forEach(function (L) { scores[L] = 0; });
    Object.keys(NG_CHARS).forEach(function (L) {
      if (!NG_CHARS[L]) return;
      var m = lower.match(NG_CHARS[L]);
      if (m) scores[L] += m.length * 3;
    });
    var words = lower.replace(/[^\p{L}\p{M}''\u2019\s-]/gu, ' ').split(/\s+/).filter(Boolean);
    var total = words.length || 1;
    Object.keys(NG_WORDS).forEach(function (L) {
      var hits = 0;
      words.forEach(function (wd) { if (NG_WORDS[L].indexOf(wd) > -1) hits++; });
      scores[L] += hits * 2;
    });
    var best = 'en', bestScore = Math.max(2, total * 0.08);
    Object.keys(scores).forEach(function (L) { if (scores[L] > bestScore) { best = L; bestScore = scores[L]; } });
    return best;
  }
  var LANG_LABEL = { en:'English', yo:'Yorùbá', ig:'Igbo', ha:'Hausa', fr:'Français', es:'Español', pt:'Português', de:'Deutsch', it:'Italiano', sw:'Kiswahili', ar:'العربية (Arabic)', zh:'中文 (Chinese)', ja:'日本語 (Japanese)', ko:'한국어 (Korean)', ru:'Русский (Russian)', hi:'हिन्दी (Hindi)', he:'עברית (Hebrew)', th:'ไทย (Thai)', el:'Ελληνικά (Greek)', bn:'বাংলা (Bengali)', ta:'தமிழ் (Tamil)' };
  var LANG_TAG   = { en:'en-US', yo:'yo-NG', ig:'ig-NG', ha:'ha-NG', fr:'fr-FR', es:'es-ES', pt:'pt-BR', de:'de-DE', it:'it-IT', sw:'sw-KE', ar:'ar-SA', zh:'zh-CN', ja:'ja-JP', ko:'ko-KR', ru:'ru-RU', hi:'hi-IN', he:'he-IL', th:'th-TH', el:'el-GR', bn:'bn-BD', ta:'ta-IN' };

  /* Per-language saved voice choices ride inside prefs.voiceByLang. */
  if (!prefs.voiceByLang || typeof prefs.voiceByLang !== 'object') prefs.voiceByLang = {};
  var currentLang = 'en';

  /* Prefer a voice for the DETECTED language; else African English; else any
     English; prefer local (offline) so a candidate on a weak connection is
     not waiting on a network round trip mid-exam. */
  function pickVoice(langHint) {
    if (!voices.length) loadVoices();
    if (!voices.length) return null;
    var L = langHint || currentLang || 'en';
    var savedURI = prefs.voiceByLang[L] || (L === 'en' ? prefs.voiceURI : '');
    if (savedURI) {
      for (var i = 0; i < voices.length; i++) if (voices[i].voiceURI === savedURI) return voices[i];
    }
    var prefer = function (re) {
      var m = voices.filter(function (v) { return re.test(v.lang || '') || re.test(v.name || ''); });
      if (!m.length) return null;
      var local = m.filter(function (v) { return v.localService; });
      return local[0] || m[0];
    };
    /* 1. Exact language match by BCP-47 prefix (fr → fr-FR, fr-CA…). */
    if (L !== 'en') {
      var vx = prefer(new RegExp('^' + L + '(-|_|$)', 'i'));
      if (vx) return vx;
      /* 2. Named-voice fallback for languages engines label by name. */
      var NAMES = { yo:/yoruba/i, ig:/igbo/i, ha:/hausa/i, sw:/swahili/i, zh:/chinese|mandarin/i, ar:/arabic/i, hi:/hindi/i, el:/greek/i, he:/hebrew/i, bn:/bengali/i, ta:/tamil/i };
      if (NAMES[L]) { var vn = prefer(NAMES[L]); if (vn) return vn; }
      /* 3. African languages degrade to African English (tone-mark friendly);
            everything else degrades to any English rather than silence. */
      if (L === 'yo' || L === 'ig' || L === 'ha' || L === 'sw') {
        var vng = prefer(/^en[-_](NG|GH|KE|ZA)/i);
        if (vng) return vng;
      }
    }
    var en = voices.filter(function (v) { return /^en(-|_|$)/i.test(v.lang || ''); });
    var pool = en.length ? en : voices;
    var local = pool.filter(function (v) { return v.localService; });
    return (local[0] || pool[0]);
  }

  /* ------------------------------------------------------------------ *
   * Queue. Long questions are split at sentence boundaries: several     *
   * engines truncate or stall on utterances over ~200 characters, and a *
   * chunked queue also makes stop() instant.                            *
   * ------------------------------------------------------------------ */
  var queue = [], speaking = false, liveEl = null;

  function chunk(text, max) {
    max = max || 180;
    /* Sentence split WITHOUT lookbehind: Safari below 16.4 throws a syntax
       error on (?<=...) at parse time, which would kill this whole file. */
    function splitAfter(str, chars) {
      var res = [], cur = '';
      for (var i = 0; i < str.length; i++) {
        var ch = str.charAt(i);
        cur += ch;
        if (chars.indexOf(ch) > -1 && /\s/.test(str.charAt(i + 1) || ' ')) {
          res.push(cur); cur = '';
        }
      }
      if (cur) res.push(cur);
      return res.map(function (x) { return x.trim(); }).filter(Boolean);
    }
    var parts = splitAfter(String(text), '.;:?!'), out = [], buf = '';
    if (parts.length === 1 && text.length > max) parts = splitAfter(String(text), ',');
    parts.forEach(function (p) {
      if (!p) return;
      if ((buf + ' ' + p).trim().length > max && buf) { out.push(buf.trim()); buf = p; }
      else buf = (buf ? buf + ' ' : '') + p;
    });
    if (buf.trim()) out.push(buf.trim());
    /* hard-split anything still oversized */
    var final = [];
    out.forEach(function (p) {
      while (p.length > max * 2) { final.push(p.slice(0, max * 2)); p = p.slice(max * 2); }
      final.push(p);
    });
    return final.filter(Boolean);
  }

  function next() {
    if (!queue.length) { speaking = false; setBtnState(false); return; }
    var text = queue.shift();
    var u = new SSU(text);
    var v = pickVoice(currentLang);
    /* V10.8: tag the utterance with the detected language so engines that
       route by utterance.lang pick a matching voice even when voice is null. */
    if (v) { u.voice = v; u.lang = v.lang || LANG_TAG[currentLang] || 'en-US'; } else { u.lang = LANG_TAG[currentLang] || 'en-US'; }
    u.rate = Math.min(2, Math.max(0.5, Number(prefs.rate) || 0.95));
    u.pitch = Math.min(2, Math.max(0, Number(prefs.pitch) || 1));
    u.volume = Math.min(1, Math.max(0, Number(prefs.volume) == null ? 1 : Number(prefs.volume)));
    if (liveEl) liveEl.textContent = text;
    u.onend = function () { next(); };
    u.onerror = function () { next(); };   /* never let one bad chunk hang the queue */
    try { SS.speak(u); } catch (e) { next(); }
  }

  function speak(text, langHint) {
    if (!available() || !prefs.enabled) return false;
    var t = String(text || '').trim();
    if (!t) return false;
    stop();
    /* V10.8: detect Yoruba / Igbo / Hausa (or honour an explicit hint) so the
       matching device voice reads the paper in its own language. */
    currentLang = langHint || prefs.forceLang || detectLang(t);
    if (currentLang !== 'en' && liveEl) {
      var vv = pickVoice(currentLang);
      var native = vv && new RegExp('^' + currentLang + '(-|_|$)', 'i').test(vv.lang || '');
      if (!native && typeof toast === 'function' && !speak._warned) {
        speak._warned = true;
        toast('🔊 ' + (LANG_LABEL[currentLang] || currentLang) + ' detected. No ' + (LANG_LABEL[currentLang] || '') + ' voice is installed on this device — reading with the closest available voice. Tip: install the ' + (LANG_LABEL[currentLang] || '') + ' language pack in your phone\'s text-to-speech settings for a native voice.', 'info', 9000);
      }
    }
    queue = chunk(t);
    speaking = true;
    setBtnState(true);
    /* Chrome bug: speechSynthesis can be left in a paused state by a prior
       cancel(). resume() is a no-op when it is not paused. */
    try { SS.resume(); } catch (e) {}
    next();
    return true;
  }

  function stop() {
    queue = [];
    speaking = false;
    setBtnState(false);
    if (!available()) return;
    try { SS.cancel(); } catch (e) {}
    if (liveEl) liveEl.textContent = '';
  }

  function toggle(text) {
    if (speaking) { stop(); return false; }
    return speak(text);
  }

  /* ------------------------------------------------------------------ *
   * Building the spoken script for a normalized question object.        *
   * ------------------------------------------------------------------ */
  var LETTERS = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];

  function plain(x) {
    return (w.CBTRich && w.CBTRich.plain) ? w.CBTRich.plain(x)
         : String(x == null ? '' : x).replace(/\\n/g, '. ');
  }

  function scriptFor(q, opts) {
    opts = opts || {};
    var out = [];
    if (q.passage && opts.includePassage !== false) {
      out.push('Read the following passage.');
      out.push(plain(q.passage));
      out.push('Now the question.');
    }
    if (q.question) out.push(plain(q.question));

    var o = q.options || q.choices || [];
    if (o.length) {
      out.push('The options are.');
      o.forEach(function (op, i) {
        var txt = (op && typeof op === 'object') ? (op.text != null ? op.text : op.label) : op;
        out.push('Option ' + (LETTERS[i] || (i + 1)) + '. ' + plain(txt) + '.');
      });
    }
    if (q.type === 'numeric' || q.type === 'multi_numeric') {
      if (q.unit) out.push('Give your answer in ' + plain(q.unit) + '.');
      if (q.tolerance) out.push('A tolerance of ' + q.tolerance + ' is allowed.');
    }
    if (q.media_url && !o.length) out.push('This question has an accompanying image or diagram on screen.');
    return out.join(' ');
  }

  function readQuestion(q, opts) { return speak(scriptFor(q, opts)); }

  /* ------------------------------------------------------------------ *
   * UI                                                                  *
   * ------------------------------------------------------------------ */
  var btn = null, panel = null, sel = null;

  function setBtnState(on) {
    if (!btn) return;
    btn.setAttribute('aria-pressed', on ? 'true' : 'false');
    btn.classList.toggle('is-speaking', !!on);
    btn.querySelector('.tcs-label').textContent = on ? 'Stop reading' : 'Read aloud';
    btn.querySelector('.tcs-ico').textContent = on ? '⏹' : '🔊';
  }

  function refreshVoiceSelect() {
    if (!sel) return;
    var cur = prefs.voiceURI;
    sel.innerHTML = '<option value="">Device default</option>' +
      voices.map(function (v) {
        return '<option value="' + String(v.voiceURI).replace(/"/g, '&quot;') + '">' +
               String(v.name).replace(/</g, '&lt;') + ' (' + (v.lang || '') + ')' +
               (v.localService ? ' · offline' : '') + '</option>';
      }).join('');
    sel.value = cur || '';
  }

  var CSS = [
    '.tcs-bar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:8px 0}',
    '.tcs-btn{display:inline-flex;align-items:center;gap:7px;padding:8px 14px;border-radius:999px;',
      'border:1.5px solid var(--line,#cbd5e1);background:var(--card,#fff);color:inherit;',
      'font:inherit;font-size:.92rem;cursor:pointer;transition:.15s}',
    '.tcs-btn:hover{border-color:var(--brand,#2563eb)}',
    '.tcs-btn.is-speaking{background:var(--brand,#2563eb);color:#fff;border-color:transparent}',
    '.tcs-btn .tcs-ico{font-size:1.05em;line-height:1}',
    '.tcs-cog{border:none;background:none;cursor:pointer;font-size:1.05rem;opacity:.65;padding:4px}',
    '.tcs-cog:hover{opacity:1}',
    '.tcs-panel{display:none;gap:10px;align-items:center;flex-wrap:wrap;width:100%;',
      'padding:10px 12px;border:1px dashed var(--line,#cbd5e1);border-radius:10px;font-size:.85rem}',
    '.tcs-panel.open{display:flex}',
    '.tcs-panel label{display:flex;align-items:center;gap:6px}',
    '.tcs-panel select,.tcs-panel input[type=range]{font:inherit;font-size:.85rem;max-width:210px}',
    '.tcs-live{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}',
    '.tcs-none{font-size:.85rem;opacity:.7}'
  ].join('');

  function injectCSS() {
    if (d.getElementById('tcs-style')) return;
    var st = d.createElement('style');
    st.id = 'tcs-style';
    st.textContent = CSS;
    (d.head || d.documentElement).appendChild(st);
  }

  /* mount(container, {getQuestion: fn}) — getQuestion returns the question
     object currently on screen, so the bar always reads the right card. */
  function mount(container, opts) {
    opts = opts || {};
    if (!container) return null;
    injectCSS();
    if (container.querySelector('.tcs-bar')) return container.querySelector('.tcs-bar');

    var bar = d.createElement('div');
    bar.className = 'tcs-bar';

    if (!available()) {
      bar.innerHTML = '<span class="tcs-none">🔇 Read-aloud is not supported by this browser. ' +
                      'Try Chrome, Edge or Safari.</span>';
      container.appendChild(bar);
      return bar;
    }

    bar.innerHTML =
      '<button type="button" class="tcs-btn" aria-pressed="false" ' +
        'title="Read this question aloud (Alt+R)">' +
        '<span class="tcs-ico" aria-hidden="true">🔊</span>' +
        '<span class="tcs-label">Read aloud</span></button>' +
      '<button type="button" class="tcs-cog" title="Voice settings" aria-label="Voice settings">⚙</button>' +
      '<div class="tcs-panel">' +
        '<label>Language <select class="tcs-lang">' +
          '<option value="">Auto-detect (21 languages)</option>' +
          Object.keys(LANG_LABEL).map(function (L) {
            return '<option value="' + L + '">' + LANG_LABEL[L] + '</option>';
          }).join('') +
        '</select></label>' +
        '<label>Voice <select class="tcs-voice"></select></label>' +
        '<label>Speed <input class="tcs-rate" type="range" min="0.6" max="1.6" step="0.05"></label>' +
        '<span class="tcs-rateval"></span>' +
        '<button type="button" class="tcs-btn tcs-test">Test voice</button>' +
      '</div>' +
      '<span class="tcs-live" aria-live="polite" role="status"></span>';

    container.appendChild(bar);

    btn    = bar.querySelector('.tcs-btn');
    panel  = bar.querySelector('.tcs-panel');
    sel    = bar.querySelector('.tcs-voice');
    liveEl = bar.querySelector('.tcs-live');
    var rate = bar.querySelector('.tcs-rate');
    var rval = bar.querySelector('.tcs-rateval');

    rate.value = prefs.rate;
    rval.textContent = Number(prefs.rate).toFixed(2) + '×';
    refreshVoiceSelect();

    btn.addEventListener('click', function () {
      if (speaking) { stop(); return; }
      var q = opts.getQuestion ? opts.getQuestion() : null;
      if (q) readQuestion(q, opts);
      else if (opts.getText) speak(opts.getText());
    });
    bar.querySelector('.tcs-cog').addEventListener('click', function () {
      panel.classList.toggle('open');
    });
    /* V10.8: language override + per-language voice memory. */
    var langSel = bar.querySelector('.tcs-lang');
    if (langSel) {
      langSel.value = prefs.forceLang || '';
      langSel.addEventListener('change', function () {
        prefs.forceLang = langSel.value || '';
        currentLang = prefs.forceLang || 'en';
        save(); refreshVoiceSelect();
      });
    }
    sel.addEventListener('change', function () {
      var L = (langSel && langSel.value) || currentLang || 'en';
      if (L === 'en') prefs.voiceURI = sel.value;
      prefs.voiceByLang[L] = sel.value;
      save();
    });
    rate.addEventListener('input', function () {
      prefs.rate = Number(rate.value);
      rval.textContent = prefs.rate.toFixed(2) + '×';
      save();
    });
    bar.querySelector('.tcs-test').addEventListener('click', function () {
      var L = (langSel && langSel.value) || '';
      var samples = {
        yo: 'Báwo ni? Èyí ni bí a ó ṣe ka àwọn ìbéèrè fún ọ. Àṣàyàn A.',
        ig: 'Kedu? Nke a bụ ka a ga-esi gụọra gị ajụjụ ndị ahụ. Nhọrọ A.',
        ha: 'Sannu! Ga yadda za a karanta muku tambayoyin. Zaɓi na A.',
        fr: 'Bonjour ! Voici comment les questions vous seront lues. Option A. La fraction trois x plus six, sur neuf.',
        es: '¡Hola! Así es como se le leerán las preguntas. Opción A.',
        pt: 'Olá! É assim que as perguntas serão lidas para você. Opção A.',
        de: 'Hallo! So werden Ihnen die Fragen vorgelesen. Option A.',
        it: 'Ciao! Ecco come ti verranno lette le domande. Opzione A.',
        sw: 'Habari! Hivi ndivyo maswali yatakavyosomwa kwako. Chaguo A.',
        ar: 'مرحبا! هكذا ستُقرأ الأسئلة لك. الخيار أ.',
        zh: '你好！这就是为你朗读问题的方式。选项A。',
        ja: 'こんにちは。このように問題を読み上げます。選択肢A。',
        ko: '안녕하세요. 이렇게 문제를 읽어 드립니다. 보기 A.',
        ru: 'Здравствуйте! Вот как вам будут читать вопросы. Вариант А.',
        hi: 'नमस्ते! प्रश्न आपको इस प्रकार पढ़कर सुनाए जाएँगे। विकल्प A।',
        he: 'שלום! כך יוקראו לך השאלות. אפשרות א.',
        th: 'สวัสดี! นี่คือวิธีที่จะอ่านคำถามให้คุณฟัง ตัวเลือก A',
        el: 'Γεια σας! Έτσι θα σας διαβάζονται οι ερωτήσεις. Επιλογή Α.',
        bn: 'নমস্কার! এভাবে প্রশ্নগুলো আপনাকে পড়ে শোনানো হবে। বিকল্প A।',
        ta: 'வணக்கம்! கேள்விகள் இப்படித்தான் உங்களுக்கு வாசிக்கப்படும். விருப்பம் A.'
      };
      speak(samples[L] || 'This is how the questions will be read to you. Option A. The fraction 3 x plus 6, over 9.', L || undefined);
    });

    return bar;
  }

  /* Keyboard shortcuts — Alt+R read, Alt+S stop. Never plain keys: the
     candidate is typing answers. */
  d.addEventListener('keydown', function (e) {
    if (!e.altKey || e.ctrlKey || e.metaKey) return;
    var k = String(e.key || '').toLowerCase();
    if (k === 'r' && btn) { e.preventDefault(); btn.click(); }
    if (k === 's') { e.preventDefault(); stop(); }
  });

  /* Integrity: never let audio outlive the question or the exam. */
  d.addEventListener('visibilitychange', function () { if (d.hidden) stop(); });
  w.addEventListener('pagehide', stop);
  w.addEventListener('beforeunload', stop);

  w.CBTSpeech = {
    available: available,
    detectLang: detectLang,
    mount: mount,
    speak: speak,
    stop: stop,
    toggle: toggle,
    readQuestion: readQuestion,
    scriptFor: scriptFor,
    isSpeaking: function () { return speaking; },
    setEnabled: function (b) { prefs.enabled = !!b; if (!b) stop(); save(); },
    voices: function () { return voices.slice(); },
    prefs: prefs
  };

})(window, document);
