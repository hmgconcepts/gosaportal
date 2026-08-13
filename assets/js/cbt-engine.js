/* ====================================================================
   CBT Engine — School Connect v2
   Robust question normalisation, CSV parsing, anti-cheat, grading helpers,
   calculator and math keyboard. No AI API.
   ==================================================================== */
const CBT = {
  QUESTION_TYPES_17: ['mcq','multi_select','true_false','fill_blank','short_answer','essay','numeric','matching','ordering','drag_drop','hotspot','comprehension','case_study','image_based','audio_based','video_based','math_equation'],
  _sb: null,
  calcState: { mode: 'basic', memory: 0, display: '' },

  init(supabaseClient) {
    this._sb = supabaseClient || (typeof sb !== 'undefined' ? sb : null);
    // FIX V2.1 Issue #11: Calculator and math keyboard ONLY on CBT exam taking page (cbt-exam.html), not on manager pages
    const page = (location.pathname.split('/').pop() || '').toLowerCase();
    const isExamPage = page === 'cbt-exam.html' || page.startsWith('cbt-exam') || !!document.getElementById('exam-root') || !!document.getElementById('cbt-exam-root') || !!document.querySelector('[data-cbt-exam]');
    if (this._sb && isExamPage) {
      try { this.bindFloatingToolbar(); } catch(e) {}
    }
    if (document.getElementById('cbt-list') && window.CBTUI) { try { CBTUI.refresh(); } catch(e) { console.warn('CBTUI.refresh failed:', e); } }
  },

  bindFloatingToolbar() {
    if (document.getElementById('cbt-floating-toolbar')) return;
    const toolbar = document.createElement('div');
    toolbar.id = 'cbt-floating-toolbar';
    toolbar.style.cssText = 'position:fixed;bottom:20px;right:20px;z-index:9999;display:flex;gap:8px;flex-direction:column;align-items:flex-end;';
    toolbar.innerHTML = '<button onclick="CBT.toggleCalculator()" style="background:linear-gradient(135deg,#0506ae,#964eec);color:white;border:none;border-radius:50px;padding:12px 20px;font-size:14px;font-weight:700;cursor:pointer;box-shadow:0 4px 15px rgba(79,70,229,0.4)">🧮 Calculator</button><button onclick="CBT.toggleMathKeyboard()" style="background:linear-gradient(135deg,#059669,#10b981);color:white;border:none;border-radius:50px;padding:12px 20px;font-size:14px;font-weight:700;cursor:pointer;box-shadow:0 4px 15px rgba(5,150,105,0.4)">⌨️ Math Keyboard</button>';
    document.body.appendChild(toolbar);
  },

  normalizeQuestion(q, idx) {
    q = q || {};
    const canonKey = k => String(k||'').toLowerCase().replace(/[^a-z0-9]/g,'');
    const keyMap = Object.keys(q).reduce((m,k)=>{m[canonKey(k)]=k;return m;},{});
    const pick = (...names) => { for(const name of names){const k=keyMap[canonKey(name)];if(k!=null&&q[k]!=null)return q[k];} return undefined; };
    // ENTERPRISE V6 (issue 12): normalise every spelling — true/false, true-false,
    // tf, boolean, truefalse — to the canonical 'true_false' so options render.
    let type = String(pick('type','question_type','questionType') || 'mcq').toLowerCase().replace(/[\s\/\\-]+/g,'_');
    if (['tf','boolean','truefalse','true_or_false','yes_no','yesno'].includes(type)) type = 'true_false';
    if (['multiplechoice','multiple_choice','single_choice','singlechoice','objective'].includes(type)) type = 'mcq';
    if (['mrq','multiple_response','multiple_responses','multiple_select','multiselect','checkbox','checkboxes'].includes(type)) type = 'multi_select';
    if (['number','integer','decimal','calculation'].includes(type)) type = 'numeric';
    if (['short','text','free_text'].includes(type)) type = 'short_answer';
    const rawOptions=pick('options','choices','alternatives','answers');
    let options = Array.isArray(rawOptions) ? rawOptions.slice() : [];
    if (!options.length && rawOptions && typeof rawOptions === 'object') options=Object.values(rawOptions);
    if (!options.length && typeof rawOptions === 'string' && rawOptions.trim()) {
      try { const parsed=JSON.parse(rawOptions); if(Array.isArray(parsed)) options=parsed.slice(); }
      catch(_) { options=rawOptions.split(/\s*[|;]\s*/).filter(Boolean); }
    }
    options=options.map(o=>o&&typeof o==='object'?(o.text??o.label??o.value??JSON.stringify(o)):String(o));
    // Read one naming family at a time. Canonical key lookup accepts A,
    // Option A, option_a, choiceA and legacy spreadsheet spellings.
    if (!options.length) {
      for (const keys of [['a','option_a','opt_a','choice_a','option1'],['b','option_b','opt_b','choice_b','option2'],['c','option_c','opt_c','choice_c','option3'],['d','option_d','opt_d','choice_d','option4'],['e','option_e','opt_e','choice_e','option5']]) {
        const value=pick(...keys); if(value!=null && String(value).trim()!=='') options.push(String(value));
      }
    }
    // FIX V3: If options still empty but answer is a number, try choices/alternatives
    if (!options.length && (q.choices || q.alternatives)) {
      const src = q.choices || q.alternatives;
      if (Array.isArray(src)) options = src.map(String);
    }
    // FIX V3: If type looks like MCQ but no options, force type to mcq and try harder
    if (!options.length && ['mcq','multiple_choice','multi','choice'].includes(String(q.type||q.question_type||'').toLowerCase())) {
      // Last resort: check numbered keys 1,2,3,4
      [1,2,3,4,5].forEach(k => { if (q[k] != null && String(q[k]).trim() !== '') options.push(String(q[k])); });
    }
    if (type === 'true_false') options = ['True','False'];  // always exactly True/False (issue 12)
    let answer = pick('answer','correct','correct_answer','correctAnswer','correct answer','answer_key','answerKey','correct_option','correctOption','key');
    if(answer && typeof answer==='object' && !Array.isArray(answer)) answer=answer.value??answer.answer??answer.key??answer.text??answer.label;
    if(type==='multi_select' && typeof answer==='string') answer=answer.split(/\s*[,;|]\s*/).filter(Boolean);
    return {
      id: pick('id') || ('q' + (idx + 1)),
      _orig_index: pick('_orig_index','orig_index') != null ? Number(pick('_orig_index','orig_index')) : idx,
      type,
      question: pick('question','prompt','text','question_text','questionText') || '',
      options,
      answer,
      correct: answer,
      explanation: pick('explanation','reason','solution') || '',
      mark: Number(pick('mark','marks','score','points') || 1) || 1,
      section: pick('section','subject_section','subject','exam_subject') || '',
      subject: pick('subject','section','subject_section','exam_subject') || '',
      difficulty: pick('difficulty','level') || '',
      tolerance: pick('tolerance','accept','margin') || '',
      accepted_answers: pick('accept','accepted_answers','alternatives') || '',
      passage: pick('passage','context','case_text','comprehension') || '',
      media_url: pick('media_url','media','image_url','image','audio_url','video_url') || '',
      metadata: pick('metadata') || null
    };
  },

  prepareForStudent(exam) {
    if (!exam) return exam;
    let qs = exam._questions || exam.questions || exam.csv_data || [];
    if (typeof qs === 'string') { try { qs = JSON.parse(qs); } catch(e) { qs = []; } }
    qs = (qs || []).map((q,i) => this.normalizeQuestion(q,i));
    // ENTERPRISE V13/V5: if an older/browser CSV path lost per-question
    // section values, recover subject tabs from the multi-subject builder's
    // anti_cheat_config.subject_breakdown metadata. This is a second safety net
    // so tabs still appear for students.
    const cfg = exam && exam.anti_cheat_config ? exam.anti_cheat_config : {};
    const breakdown = Array.isArray(cfg.subject_breakdown) ? cfg.subject_breakdown : [];
    if (breakdown.length > 1) {
      const isMulti = exam && String(exam.subject||'').toLowerCase().startsWith('multi-subject');
      if (new Set(qs.map(q => q.section || q.subject || 'General')).size <= 1 || isMulti) {
      breakdown.forEach(b => {
        const start = Number(b.start) || 0;
        const end = b.end != null ? Number(b.end) : (start + (Number(b.count) || 0) - 1);
        for (let i = start; i <= end && i < qs.length; i++) {
          if (qs[i]) { qs[i].section = b.name || ('Subject ' + (breakdown.indexOf(b)+1)); qs[i].subject = qs[i].section; }
        }
      });
      }
    }
    // Final safety net: if sections are still missing but question-level subject metadata exists under alternate keys, copy it in now.
    qs = qs.map((q,i) => {
      if (!(q.section || q.subject)) {
        const raw = (exam && ((exam._questions && exam._questions[i]) || (exam.questions && exam.questions[i]) || (Array.isArray(exam.csv_data) && exam.csv_data[i]))) || {};
        const sec = raw.section || raw.subject || raw.subject_section || raw.exam_subject || '';
        if (sec) { q.section = sec; q.subject = sec; }
      }
      return q;
    });
    // ENTERPRISE V6 (issue 13): UTME-style multi-subject exams must keep each
    // subject's questions GROUPED — never mixed together randomly. Randomise
    // and select_count now operate WITHIN each subject section.
    const sections = [...new Set(qs.map(q => q.section || q.subject || 'General'))];
    if (sections.length > 1) {
      const perSection = Math.max(0, Number(exam.select_count) || 0); // per-subject cap in multi mode
      let grouped = [];
      sections.forEach(sec => {
        let block = qs.filter(q => (q.section || q.subject || 'General') === sec);
        if (exam.randomise) block = this.shuffle(block);
        if (perSection > 0) block = block.slice(0, perSection);
        grouped = grouped.concat(block);
      });
      qs = grouped;
    } else {
      if (exam.randomise) qs = this.shuffle(qs);
      if (exam.select_count && Number(exam.select_count) > 0) qs = qs.slice(0, Number(exam.select_count));
    }
    exam._questions = qs;
    exam.questions = qs;
    return exam;
  },

  shuffle(arr) { const a = arr.slice(); for (let i=a.length-1;i>0;i--) { const j=Math.floor(Math.random()*(i+1)); [a[i],a[j]]=[a[j],a[i]]; } return a; },

  gradeSubmission(exam, answers) {
    const qs = (exam && (exam._questions || exam.questions)) || [];
    let score = 0, total = 0, correct = 0, wrong = 0, skipped = 0;
    qs.forEach((q,i) => {
      const mark = Number(q.mark || q.score || q.points || 1) || 1; total += mark;
      const given = answers ? answers[i] : null;
      // FIX V3: More lenient skip detection — only skip if truly empty
      if (given == null || given === undefined) { skipped++; return; }
      if (typeof given === 'string' && given.trim() === '') { skipped++; return; }
      if (Array.isArray(given) && given.length === 0) { skipped++; return; }
      const ok = this.isCorrect(q, given);
      if (ok) { score += mark; correct++; }
      else { score -= Number(exam.negative_mark || 0) || 0; wrong++; }
    });
    if (score < 0) score = 0;
    const percent = total ? Math.round((score / total) * 10000) / 100 : 0;
    const grade = percent >= 75 ? 'A' : percent >= 60 ? 'B' : percent >= 50 ? 'C' : percent >= 40 ? 'D' : 'F';
    return { score: Math.round(score*100)/100, total, percent, grade, correct, wrong, skipped };
  },

  isCorrect(q, given) {
    const norm = v => String(v == null ? '' : v).trim().toLowerCase().replace(/\s+/g,' ');
    const ans = q.answer != null ? q.answer : q.correct;
    const opts = (q.options || []).map(norm);
    const canonicalOption = v => {
      const x=norm(v);
      if (/^[a-z]$/.test(x)) { const i=x.charCodeAt(0)-97; if(opts[i]!=null)return opts[i]; }
      return x;
    };
    const tokens = v => {
      if (Array.isArray(v)) return v.map(canonicalOption).filter(Boolean);
      if (v && typeof v === 'object') return Object.values(v).map(canonicalOption).filter(Boolean);
      let s=String(v==null?'':v).trim();
      if (/^\s*\[/.test(s)) { try { const p=JSON.parse(s); if(Array.isArray(p))return p.map(canonicalOption).filter(Boolean); } catch(_){} }
      return s.split(/\s*[,;|]\s*/).map(canonicalOption).filter(Boolean);
    };
    if (String(q.type||'').toLowerCase()==='multi_select') {
      const a=[...new Set(tokens(ans))].sort(), gset=[...new Set(tokens(given))].sort();
      return a.length>0 && a.length===gset.length && a.every((x,i)=>x===gset[i]);
    }
    let g = norm(given);
    // For non-multi questions an answer array means accepted alternatives.
    if (Array.isArray(ans)) return ans.map(norm).includes(g);
    if (q.type === 'numeric') {
      const tol = Math.abs(Number(q.tolerance)) || 0.0001;
      return Math.abs(Number(given) - Number(ans)) <= tol;
    }
    const a = norm(ans);
    if (a === g) return true;
    // FIX V3: Handle numeric answer indices (0=A, 1=B, 2=C, 3=D)
    const ansNum = Number(ans);
    if (!isNaN(ansNum) && ansNum >= 0 && ansNum <= 9) {
      const letterFromNum = String.fromCharCode(97 + ansNum); // 0→'a', 1→'b', etc.
      if (g === letterFromNum) return true;
      const opts = (q.options || []).map(norm);
      if (opts[ansNum] && opts[ansNum] === g) return true;
    }
    // FIX V3: Handle student giving a number (0-3) as answer
    const gNum = Number(given);
    if (!isNaN(gNum) && gNum >= 0 && gNum <= 9) {
      const letterFromGNum = String.fromCharCode(97 + gNum);
      if (letterFromGNum === a) return true;
    }
    // ENTERPRISE V6 (issue 12 grading): students answer option questions with a
    // LETTER (A/B/C/D) while teachers may store the answer as the option TEXT
    // (e.g. "True") — or vice-versa. Accept both directions.
    if (opts.length) {
      const letterToText = (x) => (x.length === 1 && x >= 'a' && x <= 'z') ? opts[x.charCodeAt(0) - 97] : undefined;
      const textToLetter = (x) => { const i = opts.indexOf(x); return i >= 0 ? String.fromCharCode(97 + i) : undefined; };
      if (letterToText(g) !== undefined && letterToText(g) === a) return true;
      if (letterToText(a) !== undefined && letterToText(a) === g) return true;
      if (textToLetter(g) !== undefined && textToLetter(g) === a) return true;
      // FIX: Also check if answer is the option INDEX (0,1,2,3)
      const ansNum = Number(ans);
      if (!isNaN(ansNum) && ansNum >= 0 && ansNum < opts.length) {
        if (g === String.fromCharCode(97 + ansNum)) return true; // given='a', answer=0
        if (g === opts[ansNum]) return true; // given=option text, answer=index
      }
      // FIX: Check if given is the option INDEX
      const gNum = Number(given);
      if (!isNaN(gNum) && gNum >= 0 && gNum < opts.length) {
        if (String.fromCharCode(97 + gNum) === a) return true;
        if (opts[gNum] === a) return true;
      }
    }
    // FIX: Last resort — check if given matches any option by position
    if (opts.length && g.length === 1 && g >= 'a' && g <= 'e') {
      const idx = g.charCodeAt(0) - 97;
      if (idx < opts.length && opts[idx] === a) return true;
    }
    return false;
  },

  startAntiCheat(cfg, onFlag) {
    cfg = cfg || {}; let count = 0; const log = [];
    const flag = type => { count++; log.push({type, at:new Date().toISOString()}); if (onFlag) onFlag(type, count); };
    if (cfg.watermark !== false && !document.getElementById('cbt-watermark')) { const wm=document.createElement('div'); wm.id='cbt-watermark'; wm.textContent=((window.SC_PROFILE&&SC_PROFILE.full_name)||'Candidate')+' · '+(window.fmtDMYT?fmtDMYT(new Date()):new Date().toLocaleString()); wm.style.cssText='position:fixed;inset:0;pointer-events:none;z-index:9997;opacity:.08;font-size:32px;font-weight:900;color:#111;display:flex;align-items:center;justify-content:center;transform:rotate(-28deg);'; document.body.appendChild(wm); }
    const handlers = [];
    if (cfg.window_blur !== false) { const h=()=>flag('window_blur'); window.addEventListener('blur',h); handlers.push(['blur',h]); }
    if (cfg.copy_paste !== false) {
      ['copy','paste','cut'].forEach(ev => { const h=e=>{ e.preventDefault(); flag(ev); }; document.addEventListener(ev,h); handlers.push([ev,h,document]); });
    }
    if (cfg.right_click !== false) { const h=e=>{ e.preventDefault(); flag('right_click'); }; document.addEventListener('contextmenu',h); handlers.push(['contextmenu',h,document]); }
    if (cfg.fullscreen !== false && document.documentElement.requestFullscreen) { try { document.documentElement.requestFullscreen().catch(()=>{}); } catch(e) {} const h=()=>{ if(!document.fullscreenElement) flag('fullscreen_exit'); }; document.addEventListener('fullscreenchange',h); handlers.push(['fullscreenchange',h,document]); }
    if (cfg.devtools !== false) { const h=e=>{ if(e.key==='F12'||(e.ctrlKey&&e.shiftKey&&['I','J','C'].includes(String(e.key).toUpperCase()))){ e.preventDefault(); flag('devtools_key'); } }; document.addEventListener('keydown',h); handlers.push(['keydown',h,document]); }
    return { log, stop(){ handlers.forEach(([ev,h,target]) => (target||window).removeEventListener(ev,h)); const wm=document.getElementById('cbt-watermark'); if(wm) wm.remove(); } };
  },

  // ENTERPRISE V14 (issue 44): the manager list deliberately EXCLUDES the two
  // heavy jsonb question columns (csv_data/questions). A school with 100 exams
  // × a 200 KB question bank used to download ~20 MB on every page open; the
  // slim list is a few KB. Full rows are still fetched per-exam whenever the
  // teacher edits, previews, exports or appends questions.
  async listExams() { if (!this._sb) return {data:null,error:{message:'Database not configured'}}; const all=[];for(let from=0;from<5000;from+=500){const r=await this._sb.from('cbt_exams').select('id,code,title,subject,class,term,session,assessment_type,report_column,max_score,duration,duration_min,attempt_limit,select_count,randomise,negative_mark,exam_mode,is_open,is_archived,is_entrance,pass_mark,release_results,anti_cheat_config,certificate_enabled,start_at,close_at,teacher_id,created_at,updated_at').order('created_at',{ascending:false}).range(from,from+499);if(r.error)return r;all.push(...(r.data||[]));if(!r.data||r.data.length<500)break;}return{data:all,error:null}; },
  async createExam(exam) { if (!this._sb) return {data:null,error:{message:'Database not configured'}}; exam = exam || {}; exam.code = (exam.code || this._generateCode(6)).toUpperCase(); exam.created_at = new Date().toISOString(); if (!exam.teacher_id && window.SC_PROFILE && SC_PROFILE.id) exam.teacher_id = SC_PROFILE.id; exam.anti_cheat_config = Object.assign({tab_switch:true,window_blur:true,copy_paste:true,right_click:true,fullscreen:true,watermark:true,devtools:true,max_violations:5}, exam.anti_cheat_config || {}); const bank=(Array.isArray(exam.csv_data)&&exam.csv_data.length)?exam.csv_data:((Array.isArray(exam.questions)&&exam.questions.length)?exam.questions:[]); if(bank.length){exam.csv_data=bank;exam.questions=bank;} return await this._sb.from('cbt_exams').insert(exam).select().single(); },
  _generateCode(len) { const chars='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; let r=''; for(let i=0;i<len;i++) r+=chars.charAt(Math.floor(Math.random()*chars.length)); return r; },

  advancedPromptTemplate(subject, klass, topic, count) {
    subject = subject || 'Mathematics'; klass = klass || 'SSS 1'; topic = topic || 'Selected topic'; count = count || 40;
    return `You are an expert examination setter. Generate ${count} high-quality CBT questions for ${subject}, ${klass}, topic: ${topic}.\n\nReturn ONLY a CSV with these headers exactly:\nquestion,type,a,b,c,d,answer,explanation,mark,difficulty,topic,tolerance,section\n\nRules:\n1. Use a balanced mix of question types where appropriate: mcq, true_false, fill_blank, numeric, short_answer, multi_select, matching, ordering, comprehension.\n2. For MCQ, put four options in a,b,c,d and answer as the exact option text or letter.\n3. For numeric, put the numeric answer in answer and tolerance in tolerance.\n4. Keep explanations concise and educational.\n5. Avoid ambiguous questions.\n6. Align difficulty to the class level.\n7. Do not include markdown, numbering outside the CSV, or extra commentary.`;
  },

  validateQuestionBank(questions) {
    const manualTypes=new Set(['essay','long_answer','file_upload']);
    const errors=[],warnings=[];
    (questions||[]).forEach((raw,i)=>{
      const q=this.normalizeQuestion(raw,i), label='Question '+(i+1);
      if(!String(q.question||'').trim()) errors.push(label+': question text is missing.');
      const missing=q.answer==null || (typeof q.answer==='string'&&!q.answer.trim()) || (Array.isArray(q.answer)&&!q.answer.length);
      if(missing && !manualTypes.has(q.type)) errors.push(label+': correct answer key is missing. Check the CorrectAnswer/Correct Answer column.');
      if(['mcq','true_false','multi_select'].includes(q.type) && q.options.length<2) errors.push(label+': at least two options are required for '+q.type+'.');
      if(manualTypes.has(q.type)&&missing) warnings.push(label+': requires manual review and is excluded from automatic percentage.');
    });
    return {ok:errors.length===0,errors,warnings,question_count:(questions||[]).length,engine_version:'v5.1'};
  },

  parseCSV(csv) {
    if (!csv || !csv.trim()) return [];
    const rows = this.parseCSVRows(csv).filter(r => r.some(v => String(v == null ? '' : v).trim()));
    if (!rows.length) return [];
    const canon = h => String(h==null?'':h).replace(/^\uFEFF/,'').trim().toLowerCase().replace(/[^a-z0-9]/g,'');
    /* V9.6 (#2) ROOT CAUSE of "Add at least one question CSV" on PASTED text:
       the parser demanded ≥2 rows and blindly consumed row 1 as a header.
       Raw CSV pasted WITHOUT a header row (the common case when copying
       straight from Excel/Notepad) lost its first question — and a single
       pasted question produced ZERO. Now we DETECT whether row 1 is really
       a header (contains recognisable column names); when it is not, every
       row is data and the standard positional layout applies
       (question,a,b,c,d,answer,explanation,type,mark). */
    const probe = rows[0].map(canon);
    const headerWords = ['question','prompt','text','answer','correct','correctanswer','optiona','a','b','c','d','type','mark','marks'];
    const looksHeader = probe.filter(x => headerWords.includes(x)).length >= 2;
    const head = looksHeader ? probe : [];
    const idx = name => head.indexOf(canon(name));
    const dataRows = looksHeader ? rows.slice(1) : rows;
    if (!dataRows.length) return [];
    const questions = [];
    dataRows.forEach((vals, i) => {
      if (!vals.some(v => String(v||'').trim())) return;
      const get = (...names) => { for (const n of names) { const k=idx(n); if(k>=0) return vals[k] || ''; } return ''; };
      const q = {
        question: get('question','prompt','text') || vals[0] || '',
        a: get('a','option_a','option a') || vals[1] || '', b: get('b','option_b','option b') || vals[2] || '', c: get('c','option_c','option c') || vals[3] || '', d: get('d','option_d','option d') || vals[4] || '',
        answer: get('answer','correct','correct_answer','correct answer','correctanswer','answer_key','answerkey','correct_option','correctoption','key') || vals[5] || '',
        explanation: get('explanation','reason','solution') || vals[6] || '',
        type: get('type','question_type','questiontype') || vals[7] || 'mcq',
        mark: Number(get('mark','marks','score','points') || 1) || 1,
        difficulty: get('difficulty','level') || '',
        topic: get('topic','lesson') || '',
        tolerance: get('tolerance','accept') || '',
        section: get('section','subject','subject_section','exam_subject') || '',
        subject: get('subject','section','subject_section','exam_subject') || '',
        passage: get('passage','context','case_text','comprehension') || '',
        media_url: get('media_url','media','image_url','image','audio_url','video_url') || ''
      };
      questions.push(this.normalizeQuestion(q, i));
    });
    return questions;
  },
  parseCSVRows(text) {
    const rows=[]; let row=[], cur='', q=false;
    for (let i=0;i<text.length;i++) { const ch=text[i], nx=text[i+1];
      if (ch==='"' && q && nx==='"') { cur+='"'; i++; }
      else if (ch==='"') q=!q;
      else if (ch===',' && !q) { row.push(cur); cur=''; }
      else if ((ch==='\n'||ch==='\r') && !q) { if(ch==='\r'&&nx==='\n') i++; row.push(cur); rows.push(row); row=[]; cur=''; }
      else cur+=ch;
    }
    if (cur || row.length) { row.push(cur); rows.push(row); }
    return rows;
  },

  toggleCalculator() {
    // FIX #11: Only allow calculator on CBT exam pages
    const page = (location.pathname.split('/').pop() || '').replace('.html','');
    if (!['cbt-exam','cbt_exam','cbt-multi','cbt_multi','cbt'].includes(page)) {
      if (typeof toast === 'function') toast('Calculator is only available during CBT exams.', 'info', 4000);
      return;
    }
    const existing=document.getElementById('cbt-calculator'); if(existing){existing.remove();return;} const calc=document.createElement('div'); calc.id='cbt-calculator'; calc.style.cssText='position:fixed;bottom:90px;right:20px;background:white;border:2px solid #e2e8f0;border-radius:16px;padding:16px;box-shadow:0 20px 50px rgba(0,0,0,.15);z-index:10000;width:280px;font-family:sans-serif;'; this._renderCalculatorHTML(calc); document.body.appendChild(calc); },
  _renderCalculatorHTML(calc) { const basic=['7','8','9','÷','4','5','6','×','1','2','3','-','0','.','⌫','+']; const scientific=['sin','cos','tan','π','√','x²','ln','log','(',')']; calc.innerHTML='<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px"><strong>🧮 Calculator</strong><button onclick="CBT.toggleCalcMode()" class="btn btn-sm btn-outline">'+(this.calcState.mode==='basic'?'Basic':'Scientific')+'</button><button onclick="document.getElementById(\'cbt-calculator\').remove()" class="btn btn-sm btn-outline">×</button></div><input id="calc-display" value="'+this.calcState.display+'" style="width:100%;font-size:24px;padding:10px;text-align:right;margin-bottom:10px;border:1px solid #cbd5e1;border-radius:8px" readonly>'+(this.calcState.mode==='scientific'?'<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:5px;margin-bottom:8px">'+scientific.map(b=>'<button onclick="CBT.calcInput(\''+b+'\')">'+b+'</button>').join('')+'</div>':'')+'<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:5px">'+basic.map(b=>'<button onclick="CBT.calcInput(\''+b+'\')" style="padding:10px">'+b+'</button>').join('')+'</div><div style="display:flex;gap:8px;margin-top:10px"><button onclick="CBT.calcClear()" style="flex:1">C</button><button onclick="CBT.calcEquals()" style="flex:2">=</button></div>'; },
  toggleCalcMode(){ this.calcState.mode=this.calcState.mode==='basic'?'scientific':'basic'; const c=document.getElementById('cbt-calculator'); if(c)this._renderCalculatorHTML(c); },
  calcInput(v){ const d=document.getElementById('calc-display'); if(!d)return; if(v==='⌫'){d.value=d.value.slice(0,-1);} else if(v==='x²'){d.value=Math.pow(Number(d.value)||0,2);} else if(v==='π'){d.value+=Math.PI;} else d.value+=v; this.calcState.display=d.value; },
  calcClear(){ const d=document.getElementById('calc-display'); if(d){d.value='';this.calcState.display='';} },
  calcEquals(){ const d=document.getElementById('calc-display'); if(!d)return; try{ d.value=String(eval(d.value.replace(/÷/g,'/').replace(/×/g,'*'))); this.calcState.display=d.value; }catch(e){d.value='Error';this.calcState.display='';} },
  calcMemoryClear(){ this.calcState.memory=0; },
  toggleMathKeyboard(){
    // FIX #11: Only allow math keyboard on CBT exam pages
    const page = (location.pathname.split('/').pop() || '').replace('.html','');
    if (!['cbt-exam','cbt_exam','cbt-multi','cbt_multi','cbt'].includes(page)) {
      if (typeof toast === 'function') toast('Math keyboard is only available during CBT exams.', 'info', 4000);
      return;
    }
    const existing=document.getElementById('cbt-math-keyboard'); if(existing){existing.remove();return;} const kb=document.createElement('div'); kb.id='cbt-math-keyboard'; kb.style.cssText='position:fixed;bottom:160px;right:20px;background:white;border:2px solid #e2e8f0;border-radius:16px;padding:16px;box-shadow:0 20px 50px rgba(0,0,0,.15);z-index:10000;max-width:340px'; const syms=['+','-','×','÷','=','(',')','²','³','√','π','%','≤','≥','≠','≈','α','β','θ']; kb.innerHTML='<div style="display:flex;justify-content:space-between"><strong>⌨️ Math Keyboard</strong><button onclick="document.getElementById(\'cbt-math-keyboard\').remove()">×</button></div><p style="font-size:12px;color:#64748b">Click inside an answer field, then click a symbol.</p><div style="display:flex;flex-wrap:wrap;gap:5px">'+syms.map(s=>'<button onclick="CBT.insertMathSymbol(\''+s+'\')" style="min-width:36px;height:36px">'+s+'</button>').join('')+'</div>'; document.body.appendChild(kb); },
  insertMathSymbol(sym){ const a=document.activeElement; if(a&&(a.tagName==='INPUT'||a.tagName==='TEXTAREA')){ const st=a.selectionStart||a.value.length; a.value=a.value.slice(0,st)+sym+a.value.slice(a.selectionEnd||st); a.setSelectionRange(st+sym.length,st+sym.length); a.focus(); a.dispatchEvent(new Event('input',{bubbles:true})); } else if(typeof toast==='function') toast('Click inside an answer field first','info'); }
};


window.CBTUI = window.CBTUI || {
  async refresh(){ const box=document.getElementById('cbt-list'); if(!box) return; const res=await CBT.listExams(); if(res.error){box.innerHTML='<div class="card">Could not load exams: '+esc(res.error.message)+'</div>';return;} const data=res.data||[]; box.innerHTML=data.length?data.map(e=>'<div class="card"><h3>'+esc(e.title||'Untitled')+'</h3><p>'+esc(e.subject||'')+' · '+esc(e.class||'')+' · Code: <b>'+esc(e.code||'')+'</b></p><div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn btn-sm btn-outline" onclick="CBTUI.open(\''+e.code+'\')">Open exam link</button><button class="btn btn-sm btn-outline" onclick="CRUD.renderList(\'cbt\')">Manage in table</button></div></div>').join(''):'<div class="card">No CBT exams yet. Click + Add new or use the CBT manager form to create one.</div>'; },
  open(code){ location.href='cbt-exam.html?code='+encodeURIComponent(code||''); },
  newExam(){ if(window.CRUD) CRUD.openForm('cbt'); },
  downloadTemplate(){ const csv='question,type,a,b,c,d,answer,explanation,mark,difficulty,topic,tolerance,section\nWhat is 2+2?,mcq,3,4,5,6,4,2+2 equals 4,1,easy,Arithmetic,\n'; const a=document.createElement('a'); a.href=URL.createObjectURL(new Blob([csv],{type:'text/csv'})); a.download='school-connect-cbt-template.csv'; a.click(); }
};

document.addEventListener('DOMContentLoaded' , function(){ CBT.init((typeof sb !== 'undefined' ? sb : (window.sb || null))); setTimeout(function(){ if(window.CBTUI&&CBTUI.refresh) CBTUI.refresh(); },300); });
window.CBT = CBT;
