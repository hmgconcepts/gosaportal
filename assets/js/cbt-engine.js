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
    if (this._sb && (location.pathname.includes('cbt') || document.getElementById('exam-root') || document.querySelector('[data-cbt-action]'))) this.bindFloatingToolbar();
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
    const type = String(q.type || q.question_type || 'mcq').toLowerCase().replace(/\s+/g,'_');
    let options = Array.isArray(q.options) ? q.options.slice() : [];
    if (!options.length) ['a','b','c','d','e'].forEach(k => { if (q[k] != null && String(q[k]).trim() !== '') options.push(String(q[k])); });
    const answer = q.answer != null ? q.answer : (q.correct != null ? q.correct : q.correct_answer);
    return {
      id: q.id || ('q' + (idx + 1)),
      type,
      question: q.question || q.prompt || q.text || '',
      options,
      answer,
      correct: answer,
      explanation: q.explanation || '',
      mark: Number(q.mark || q.score || 1) || 1,
      section: q.section || q.subject_section || q.subject || '',
      subject: q.subject || q.section || q.subject_section || '',
      difficulty: q.difficulty || '',
      tolerance: q.tolerance || q.accept || ''
    };
  },

  prepareForStudent(exam) {
    if (!exam) return exam;
    let qs = exam._questions || exam.questions || exam.csv_data || [];
    if (typeof qs === 'string') { try { qs = JSON.parse(qs); } catch(e) { qs = []; } }
    qs = (qs || []).map((q,i) => this.normalizeQuestion(q,i));
    if (exam.randomise) qs = this.shuffle(qs);
    if (exam.select_count && Number(exam.select_count) > 0) qs = qs.slice(0, Number(exam.select_count));
    exam._questions = qs;
    exam.questions = qs;
    return exam;
  },

  shuffle(arr) { const a = arr.slice(); for (let i=a.length-1;i>0;i--) { const j=Math.floor(Math.random()*(i+1)); [a[i],a[j]]=[a[j],a[i]]; } return a; },

  gradeSubmission(exam, answers) {
    const qs = (exam && (exam._questions || exam.questions)) || [];
    let score = 0, total = 0, correct = 0, wrong = 0, skipped = 0;
    qs.forEach((q,i) => {
      const mark = Number(q.mark || 1) || 1; total += mark;
      const given = answers ? answers[i] : null;
      if (given == null || String(given).trim() === '') { skipped++; return; }
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
    const norm = v => String(v == null ? '' : v).trim().toLowerCase();
    const g = norm(given);
    const ans = q.answer != null ? q.answer : q.correct;
    if (Array.isArray(ans)) return ans.map(norm).includes(g);
    if (q.type === 'numeric') return Math.abs(Number(given) - Number(ans)) < 0.0001;
    return norm(ans) === g;
  },

  startAntiCheat(cfg, onFlag) {
    cfg = cfg || {}; let count = 0; const log = [];
    const flag = type => { count++; log.push({type, at:new Date().toISOString()}); if (onFlag) onFlag(type, count); };
    if (cfg.watermark !== false && !document.getElementById('cbt-watermark')) { const wm=document.createElement('div'); wm.id='cbt-watermark'; wm.textContent=((window.SC_PROFILE&&SC_PROFILE.full_name)||'Candidate')+' · '+new Date().toLocaleString(); wm.style.cssText='position:fixed;inset:0;pointer-events:none;z-index:9997;opacity:.08;font-size:32px;font-weight:900;color:#111;display:flex;align-items:center;justify-content:center;transform:rotate(-28deg);'; document.body.appendChild(wm); }
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

  async listExams() { if (!this._sb) return {data:null,error:{message:'Database not configured'}}; let q=this._sb.from('cbt_exams').select('*').order('created_at',{ascending:false}).limit(100); const role=String((window.SC_PROFILE&&SC_PROFILE.role)||(window.App&&App.currentRole)||'').toLowerCase(); if (window.App && !App.isAdminRole(role) && window.SC_PROFILE && SC_PROFILE.id) q=q.eq('teacher_id', SC_PROFILE.id); return await q; },
  async createExam(exam) { if (!this._sb) return {data:null,error:{message:'Database not configured'}}; exam.code = (exam.code || this._generateCode(6)).toUpperCase(); exam.created_at = new Date().toISOString(); if (window.SC_PROFILE && SC_PROFILE.id && !exam.teacher_id) exam.teacher_id = SC_PROFILE.id; return await this._sb.from('cbt_exams').insert(exam).select().single(); },
  _generateCode(len) { const chars='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; let r=''; for(let i=0;i<len;i++) r+=chars.charAt(Math.floor(Math.random()*chars.length)); return r; },

  advancedPromptTemplate(subject, klass, topic, count) {
    subject = subject || 'Mathematics'; klass = klass || 'SSS 1'; topic = topic || 'Selected topic'; count = count || 40;
    return `You are an expert examination setter. Generate ${count} high-quality CBT questions for ${subject}, ${klass}, topic: ${topic}.\n\nReturn ONLY a CSV with these headers exactly:\nquestion,type,a,b,c,d,answer,explanation,mark,difficulty,topic,tolerance,section\n\nRules:\n1. Use a balanced mix of question types where appropriate: mcq, true_false, fill_blank, numeric, short_answer, multi_select, matching, ordering, comprehension.\n2. For MCQ, put four options in a,b,c,d and answer as the exact option text or letter.\n3. For numeric, put the numeric answer in answer and tolerance in tolerance.\n4. Keep explanations concise and educational.\n5. Avoid ambiguous questions.\n6. Align difficulty to the class level.\n7. Do not include markdown, numbering outside the CSV, or extra commentary.`;
  },

  parseCSV(csv) {
    if (!csv || !csv.trim()) return [];
    const rows = this.parseCSVRows(csv);
    if (rows.length < 2) return [];
    const head = rows[0].map(h => String(h).trim().toLowerCase());
    const idx = name => head.indexOf(name);
    const questions = [];
    rows.slice(1).forEach((vals, i) => {
      if (!vals.some(v => String(v||'').trim())) return;
      const get = (...names) => { for (const n of names) { const k=idx(n); if(k>=0) return vals[k] || ''; } return ''; };
      const q = {
        question: get('question','prompt','text') || vals[0] || '',
        a: get('a','option_a') || vals[1] || '', b: get('b','option_b') || vals[2] || '', c: get('c','option_c') || vals[3] || '', d: get('d','option_d') || vals[4] || '',
        answer: get('answer','correct','correct_answer') || vals[5] || 'A',
        explanation: get('explanation','reason') || vals[6] || '',
        type: get('type','question_type') || vals[7] || 'mcq',
        mark: Number(get('mark','score') || 1) || 1,
        difficulty: get('difficulty') || '', tags: get('tags') || '', section: get('section','subject_section') || ''
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

  toggleCalculator() { const existing=document.getElementById('cbt-calculator'); if(existing){existing.remove();return;} const calc=document.createElement('div'); calc.id='cbt-calculator'; calc.style.cssText='position:fixed;bottom:90px;right:20px;background:white;border:2px solid #e2e8f0;border-radius:16px;padding:16px;box-shadow:0 20px 50px rgba(0,0,0,.15);z-index:10000;width:280px;font-family:sans-serif;'; this._renderCalculatorHTML(calc); document.body.appendChild(calc); },
  _renderCalculatorHTML(calc) { const basic=['7','8','9','÷','4','5','6','×','1','2','3','-','0','.','⌫','+']; const scientific=['sin','cos','tan','π','√','x²','ln','log','(',')']; calc.innerHTML='<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px"><strong>🧮 Calculator</strong><button onclick="CBT.toggleCalcMode()" class="btn btn-sm btn-outline">'+(this.calcState.mode==='basic'?'Basic':'Scientific')+'</button><button onclick="document.getElementById(\'cbt-calculator\').remove()" class="btn btn-sm btn-outline">×</button></div><input id="calc-display" value="'+this.calcState.display+'" style="width:100%;font-size:24px;padding:10px;text-align:right;margin-bottom:10px;border:1px solid #cbd5e1;border-radius:8px" readonly>'+(this.calcState.mode==='scientific'?'<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:5px;margin-bottom:8px">'+scientific.map(b=>'<button onclick="CBT.calcInput(\''+b+'\')">'+b+'</button>').join('')+'</div>':'')+'<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:5px">'+basic.map(b=>'<button onclick="CBT.calcInput(\''+b+'\')" style="padding:10px">'+b+'</button>').join('')+'</div><div style="display:flex;gap:8px;margin-top:10px"><button onclick="CBT.calcClear()" style="flex:1">C</button><button onclick="CBT.calcEquals()" style="flex:2">=</button></div>'; },
  toggleCalcMode(){ this.calcState.mode=this.calcState.mode==='basic'?'scientific':'basic'; const c=document.getElementById('cbt-calculator'); if(c)this._renderCalculatorHTML(c); },
  calcInput(v){ const d=document.getElementById('calc-display'); if(!d)return; if(v==='⌫'){d.value=d.value.slice(0,-1);} else if(v==='x²'){d.value=Math.pow(Number(d.value)||0,2);} else if(v==='π'){d.value+=Math.PI;} else d.value+=v; this.calcState.display=d.value; },
  calcClear(){ const d=document.getElementById('calc-display'); if(d){d.value='';this.calcState.display='';} },
  calcEquals(){ const d=document.getElementById('calc-display'); if(!d)return; try{ d.value=String(eval(d.value.replace(/÷/g,'/').replace(/×/g,'*'))); this.calcState.display=d.value; }catch(e){d.value='Error';this.calcState.display='';} },
  calcMemoryClear(){ this.calcState.memory=0; },
  toggleMathKeyboard(){ const existing=document.getElementById('cbt-math-keyboard'); if(existing){existing.remove();return;} const kb=document.createElement('div'); kb.id='cbt-math-keyboard'; kb.style.cssText='position:fixed;bottom:160px;right:20px;background:white;border:2px solid #e2e8f0;border-radius:16px;padding:16px;box-shadow:0 20px 50px rgba(0,0,0,.15);z-index:10000;max-width:340px'; const syms=['+','-','×','÷','=','(',')','²','³','√','π','%','≤','≥','≠','≈','α','β','θ']; kb.innerHTML='<div style="display:flex;justify-content:space-between"><strong>⌨️ Math Keyboard</strong><button onclick="document.getElementById(\'cbt-math-keyboard\').remove()">×</button></div><p style="font-size:12px;color:#64748b">Click inside an answer field, then click a symbol.</p><div style="display:flex;flex-wrap:wrap;gap:5px">'+syms.map(s=>'<button onclick="CBT.insertMathSymbol(\''+s+'\')" style="min-width:36px;height:36px">'+s+'</button>').join('')+'</div>'; document.body.appendChild(kb); },
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
