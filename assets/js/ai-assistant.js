/* ====================================================================
   ai-assistant.js — OPTIONAL "Bring-Your-Own-Key" AI helper (V9.1)
   ====================================================================
   PHILOSOPHY (unchanged): School Connect never DEPENDS on AI and HMG
   never pays for AI. This module is OFF by default and does nothing
   until the SCHOOL's admin enables it with the school's OWN key on
   settings.html → "🤖 AI Assistant (optional)".

   HOW IT WORKS
   • Configuration lives in public.sc_ai_settings (row 1): enabled,
     base_url, api_key, model. RLS: staff read, admin write — so keys
     are never exposed to students/parents, and the assistant is a
     STAFF-ONLY drafting tool.
   • Any OpenAI-compatible /chat/completions endpoint works, giving
     schools free/cheap options: Groq (free tier), OpenRouter (free
     models), Together, DeepSeek, OpenAI, a local Ollama server, etc.
   • The call goes DIRECTLY from the staff member's browser to the
     school's chosen provider — HMG is never in the loop and never
     billed.
   • If disabled/unconfigured/unreachable: every entry point stays
     hidden and the platform behaves exactly as before. No feature is
     built ON AI; AI only ASSISTS existing features.

   STAFF TOOLBELT (window.AI)
     AI.ready()                 → true when enabled + configured
     AI.ask(prompt, opts)       → Promise<string>  (throws on error)
     AI.draft(kind, context)    → templated school prompts:
        'lesson-plan' | 'report-comment' | 'announcement' | 'quiz' |
        'letter' | 'scheme' | 'explain'
     AI.injectHelpers()         → adds ✨ buttons next to known
        textareas on lesson plans / announcements pages (staff only).
   ==================================================================== */
(function () {
  'use strict';

  var CFG = null, LOADED = false;

  async function loadCfg(force) {
    if (LOADED && !force) return CFG;
    LOADED = true; CFG = null;
    try {
      if (!window.sb) return null;
      var r = await window.sb.from('sc_ai_settings').select('*').eq('id', 1).maybeSingle();
      if (r && r.data && r.data.enabled && r.data.base_url && r.data.api_key) CFG = r.data;
    } catch (e) { /* table missing or RLS-blocked (student/parent) → stays off */ }
    return CFG;
  }

  function ready() { return !!CFG; }

  /** Core call — OpenAI-compatible chat/completions. */
  async function ask(prompt, opts) {
    opts = opts || {};
    var c = CFG || await loadCfg();
    if (!c) throw new Error('AI assistant is not enabled. An admin can turn it on in Settings → AI Assistant.');
    var url = c.base_url.replace(/\/+$/, '');
    if (!/\/chat\/completions$/.test(url)) url += '/chat/completions';
    var body = {
      model: c.model || 'gpt-4o-mini',
      messages: [
        { role: 'system', content: opts.system || ('You are a helpful assistant for teachers and school administrators at ' + ((window.SCHOOL && SCHOOL.name) || 'a school') + '. Be concise, practical and appropriate for a school context. Never invent student data.') },
        { role: 'user', content: String(prompt || '') }
      ],
      temperature: opts.temperature == null ? 0.7 : +opts.temperature,
      max_tokens: opts.maxTokens || 900
    };
    var ctl = new AbortController(); var t = setTimeout(function () { ctl.abort(); }, opts.timeoutMs || 60000);
    var res;
    try {
      res = await fetch(url, {
        method: 'POST', signal: ctl.signal,
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + c.api_key },
        body: JSON.stringify(body)
      });
    } finally { clearTimeout(t); }
    if (!res.ok) {
      var txt = ''; try { txt = await res.text(); } catch (e) {}
      throw new Error('AI provider error (HTTP ' + res.status + '): ' + txt.slice(0, 300));
    }
    var j = await res.json();
    var out = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
    if (!out) throw new Error('AI provider returned no content.');
    return String(out).trim();
  }

  /** School-tuned prompt templates. */
  function draft(kind, ctx) {
    ctx = ctx || {};
    var p;
    switch (kind) {
      case 'lesson-plan':
        p = 'Draft a lesson plan for ' + (ctx.subject || 'the subject') + ', class ' + (ctx.class || '') + ', topic: "' + (ctx.topic || '') + '". Include: objectives, materials, a 40-minute activity flow (introduction, main activity, plenary), assessment questions, and homework. Keep it under 350 words.';
        break;
      case 'report-comment':
        p = 'Write a short, constructive report-card comment (max 40 words) for a student who ' + (ctx.performance || 'performed averagely') + ' in ' + (ctx.subject || 'their subjects') + '. Professional, encouraging tone. Do not use the student\'s name — write it so the teacher can personalise it.';
        break;
      case 'announcement':
        p = 'Draft a school announcement about: ' + (ctx.topic || '') + '. Audience: ' + (ctx.audience || 'parents and students') + '. Warm but professional, max 120 words, ready to paste.';
        break;
      case 'quiz':
        p = 'Create ' + (ctx.count || 5) + ' multiple-choice questions (A–D, mark the correct letter at the end of each) on: ' + (ctx.topic || '') + ' for ' + (ctx.class || 'secondary school') + ' level. Number them.';
        break;
      case 'letter':
        p = 'Draft a formal school letter: ' + (ctx.topic || '') + '. Include placeholders like [Parent Name], [Date] where personal data would go. Max 200 words.';
        break;
      case 'scheme':
        p = 'Draft a ' + (ctx.weeks || 12) + '-week scheme of work for ' + (ctx.subject || 'the subject') + ', class ' + (ctx.class || '') + (ctx.term ? ', ' + ctx.term : '') + '. One line per week: week number — topic — key objective.';
        break;
      case 'explain':
        p = 'Explain the following to a ' + (ctx.class || 'secondary school') + ' student in simple terms with one everyday example: ' + (ctx.topic || '');
        break;
      default:
        p = String(ctx.prompt || kind || '');
    }
    return ask(p, ctx.opts);
  }

  /** Reusable modal: prompt in, result out, copy button. Staff-only. */
  function openBox(title, seedPrompt, onUse) {
    if (!window.openModal) return;
    var id = 'ai-box-' + Date.now();
    openModal('✨ ' + (title || 'AI Assistant'),
      '<div class="form-group"><label>What do you need?</label><textarea class="form-input" id="' + id + '-p" rows="3">' + (seedPrompt || '') + '</textarea></div>' +
      '<div id="' + id + '-out" style="white-space:pre-wrap;background:var(--gray-100);border-radius:10px;padding:12px;font-size:.88rem;max-height:300px;overflow:auto;display:none"></div>' +
      '<p style="font-size:.75rem;color:var(--gray-500);margin:8px 0 0">Runs on the school\'s own AI key (Settings → AI Assistant). Review everything before use — AI drafts are suggestions, not decisions.</p>',
      '<button class="btn btn-outline" onclick="closeModal()">Close</button>' +
      '<button class="btn btn-primary" id="' + id + '-go">✨ Generate</button>' +
      '<button class="btn btn-outline" id="' + id + '-use" style="display:none">📋 ' + (onUse ? 'Insert into form' : 'Copy') + '</button>');
    var out = document.getElementById(id + '-out'), go = document.getElementById(id + '-go'), use = document.getElementById(id + '-use');
    go.onclick = async function () {
      var q = document.getElementById(id + '-p').value.trim();
      if (!q) return;
      go.disabled = true; go.textContent = '⏳ Thinking…'; out.style.display = ''; out.textContent = 'Contacting the AI provider…';
      try { var res = await ask(q); out.textContent = res; use.style.display = ''; }
      catch (e) { out.textContent = '❌ ' + (e && e.message || e); }
      go.disabled = false; go.textContent = '✨ Generate';
    };
    use.onclick = function () {
      var txt = out.textContent || '';
      if (onUse) { try { onUse(txt); } catch (e) {} if (window.closeModal) closeModal(); }
      else { try { navigator.clipboard.writeText(txt); use.textContent = '✅ Copied'; } catch (e) {} }
    };
  }

  /** Add ✨ helper buttons next to known long-text fields (staff only). */
  function injectHelpers() {
    if (!CFG) return;
    try {
      var role = String((window.SC_PROFILE || {}).role || '').toLowerCase();
      var staffish = ['super_admin', 'admin', 'principal', 'proprietor', 'head_teacher', 'bursar', 'staff', 'teacher'];
      if (role && staffish.indexOf(role) === -1) return;
    } catch (e) {}
    var page = (location.pathname.split('/').pop() || '').replace('.html', '');
    var seeds = {
      lesson_plans: ['Draft a lesson plan', 'lesson-plan'],
      announcements: ['Draft an announcement', 'announcement'],
      sow: ['Draft a scheme of work', 'scheme'],
      messages: ['Draft a message to parents', 'letter']
    };
    var hit = seeds[page]; if (!hit) return;
    if (document.getElementById('sc-ai-page-btn')) return;
    var bar = document.querySelector('.app-content .card [class*="btn"]');
    var hostCard = bar ? bar.closest('.card') : document.querySelector('.app-content .card');
    if (!hostCard) return;
    var b = document.createElement('button');
    b.className = 'btn btn-outline'; b.id = 'sc-ai-page-btn';
    b.innerHTML = '✨ AI draft';
    b.style.marginLeft = '6px';
    b.onclick = function () { openBox(hit[0], ''); };
    hostCard.appendChild(b);
  }

  window.AI = { ready: ready, ask: ask, draft: draft, openBox: openBox, injectHelpers: injectHelpers, reload: function () { return loadCfg(true); } };

  function boot() { loadCfg().then(function () { try { injectHelpers(); } catch (e) {} }); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else setTimeout(boot, 400);
})();
