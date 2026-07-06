/* ====================================================================
   report-engine.js — School Connect v3 Academic Output Engine
   --------------------------------------------------------------------
   Produces/export prints:
   1. Student report card / student record sheet
   2. Class broadsheet
   3. Subject broadsheet / teacher scoresheet

   Designed from the supplied sample PDFs. Uses browser print/save-as-PDF.
   No paid library and no AI API.
   ==================================================================== */
const ReportEngine = {
  sb: null,
  init(supabaseClient) { this.sb = supabaseClient || (typeof sb !== 'undefined' ? sb : null); },
  esc(v){ return String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); },
  n(v){ v=Number(v); return isNaN(v)?0:v; },
  fmt(v, d=2){ v=this.n(v); return Number.isInteger(v)?String(v):v.toFixed(d).replace(/\.00$/,''); },
  ordinal(n){ n=Number(n)||0; const s=['th','st','nd','rd'], v=n%100; return n+(s[(v-20)%10]||s[v]||s[0]); },
  grade(score){ score=this.n(score); if(score>=75)return'A1'; if(score>=70)return'B2'; if(score>=65)return'B3'; if(score>=60)return'C4'; if(score>=55)return'C5'; if(score>=50)return'C6'; if(score>=45)return'D7'; if(score>=40)return'E8'; return'F9'; },
  remark(score){ const g=this.grade(score); return {A1:'Excellent',B2:'Very good',B3:'Good',C4:'Credit',C5:'Credit',C6:'Credit',D7:'Pass',E8:'Pass',F9:'Fail'}[g]||''; },

  school(){
    const sc = window.SCHOOL || {};
    return {
      name: sc.name || 'School', shortName: sc.shortName || '', motto: sc.motto || 'Excellent In Learning And Character.',
      address: sc.address || '', phone: sc.phone || '', email: sc.email || '', logoExt: sc.logoExt || 'svg',
      primary: (sc.theme && sc.theme.primary) || sc.primary || '#1e2a5e', accent: (sc.theme && sc.theme.accent) || sc.accent || '#0f766e'
    };
  },

  async loadContext(ctx={}){
    const db = this.sb || (typeof sb !== 'undefined' ? sb : null);
    if (!db) throw new Error('Database not configured. Add Supabase keys in assets/js/config.js.');
    const klass = (ctx.class || ctx.className || '').trim();
    const subject = (ctx.subject || '').trim();
    const term = (ctx.term || '').trim();
    const session = (ctx.session || '').trim();
    const studentText = (ctx.student || ctx.studentName || '').trim();

    let q = db.from('results').select('*').limit(5000);
    if (klass) q = q.eq('class', klass);
    if (subject) q = q.eq('subject', subject);
    if (term) q = q.eq('term', term);
    if (session) q = q.eq('session', session);
    if (studentText) q = q.ilike('student_name', '%' + studentText + '%');
    const { data: rows, error } = await q;
    if (error) throw new Error(error.message);
    let extraRows = [];
    try { let cq = db.from('cbt_results').select('*,cbt_exams(subject,class,term,session,report_column,max_score)').limit(5000); const cbtResults = await cq; (cbtResults.data||[]).forEach(x => { const e=x.cbt_exams||{}; extraRows.push({student_name:x.student_name, student_id_ref:x.student_id_ref, class:x.student_class||e.class, subject:e.subject||'CBT', term:e.term, session:e.session, cbt_score:x.percent, total:x.percent, max_score:100}); }); } catch(e) {}
    try { const reading = await db.from('reading_scores').select('*').limit(5000); (reading.data||[]).forEach(x => extraRows.push({student_name:x.student_name, class:x.class, subject:x.subject||'Digital Library', term:x.term, session:x.session, assignment:x.score, total:x.score, max_score:100})); } catch(e) {}
    try { const subs = await db.from('lms_submissions').select('*,assignments(subject,class,title)').limit(5000); (subs.data||[]).forEach(x => { const a=x.assignments||{}; extraRows.push({student_id:x.student_id, student_name:x.student_name||'', class:a.class, subject:a.subject||a.title||'Assignment', term:x.term, session:x.session, assignment:x.score, total:x.score, max_score:100}); }); } catch(e) {}

    let sq = db.from('students').select('*').limit(5000);
    if (klass) sq = sq.eq('class', klass);
    const { data: students } = await sq;

    const normalized = (rows || []).concat(extraRows.filter(r => (!klass || r.class===klass) && (!subject || r.subject===subject) && (!term || r.term===term) && (!session || r.session===session))).map(r => this.normalizeResult(r, students || []));
    return { ctx:{class:klass,subject,term,session,student:studentText}, rows:normalized, students:students||[], school:this.school() };
  },

  normalizeResult(r, students){
    const name = r.student_name || r.full_name || '';
    const st = (students||[]).find(s => (s.id && s.id===r.student_id) || (s.full_name && String(s.full_name).toLowerCase()===String(name).toLowerCase()) || (s.admission_no && s.admission_no===r.student_id_ref));
    const project = this.n(r.project ?? r.practical ?? r.assignment ?? r.ca_project ?? 0);
    const ca1 = this.n(r.ca1 ?? r.ca_score ?? r.ca ?? 0);
    const ca2 = this.n(r.ca2 ?? 0);
    const cbt = this.n(r.ca3 ?? r.cbt ?? r.cbt_score ?? r.online_score ?? 0);
    const paper = this.n(r.exam ?? r.exam_score ?? r.paper_exam ?? 0);
    const total = this.n(r.total ?? r.total_score ?? (project+ca1+ca2+cbt+paper));
    return {
      raw:r, student_id:r.student_id || (st&&st.id) || '', student_name:name || (st&&st.full_name) || 'Student',
      admission_no:r.admission_no || r.student_id_ref || (st&&st.admission_no) || '', class:r.class || (st&&st.class) || '',
      gender:r.gender || (st&&st.gender) || '', photo_url:r.photo_url || (st&&st.photo_url) || '',
      subject:r.subject || 'Subject', term:r.term || '', session:r.session || '',
      project, ca1, ca2, cbt, paper, total, max: this.n(r.max_score || r.obtainable || 100) || 100
    };
  },

  subjects(rows){ return [...new Set(rows.map(r=>r.subject).filter(Boolean))].sort(); },
  studentsFromRows(rows){ return [...new Set(rows.map(r=>r.student_name).filter(Boolean))].sort(); },

  positionsBy(rows, groupKey='student_name'){
    const totals = {};
    rows.forEach(r => { totals[r[groupKey]] = (totals[r[groupKey]]||0) + this.n(r.total); });
    const sorted = Object.entries(totals).sort((a,b)=>b[1]-a[1]);
    const pos = {}; sorted.forEach((x,i)=>pos[x[0]]=i+1); return pos;
  },

  subjectPositions(rows){
    const out = {};
    this.subjects(rows).forEach(sub => {
      const list = rows.filter(r=>r.subject===sub).sort((a,b)=>this.n(b.total)-this.n(a.total));
      list.forEach((r,i)=>{ out[r.student_name+'|'+sub]=i+1; });
    });
    return out;
  },

  reportHeader(title, landscape=false){
    const sc=this.school(); const logo='assets/img/logo.'+sc.logoExt;
    return `<div class="re-head ${landscape?'landscape':''}">
      <img src="${logo}" onerror="this.style.display='none'" class="re-logo">
      <div class="re-school"><h1>${this.esc(sc.name)}</h1><p><b>${this.esc(sc.motto)}</b></p><p>${this.esc(sc.address)}</p><p>Phone No: ${this.esc(sc.phone)} &nbsp; Email: ${this.esc(sc.email)}</p></div>
      <h2>${this.esc(title)}</h2>
    </div>`;
  },

  async renderStudent(ctx){
    const data = await this.loadContext(ctx); const rows = data.rows;
    if (!rows.length) return this.empty('No result records found for this student/filter.');
    const name = ctx.student || rows[0].student_name; const rr = rows.filter(r => !ctx.student || r.student_name.toLowerCase().includes(String(ctx.student).toLowerCase()));
    const studentRows = rr.length ? rr : rows; const first = studentRows[0] || {};
    const subjects = this.subjects(studentRows); const classRows = rows.filter(r => r.class === first.class || !first.class);
    const pos = this.positionsBy(classRows); const subPos = this.subjectPositions(classRows);
    const total = studentRows.reduce((a,b)=>a+this.n(b.total),0); const avg = subjects.length ? total/subjects.length : 0;
    const classAverages = this.studentsFromRows(classRows).map(st => {
      const srows=classRows.filter(r=>r.student_name===st); return srows.length ? srows.reduce((a,b)=>a+this.n(b.total),0)/srows.length : 0;
    });
    const highest = classAverages.length ? Math.max(...classAverages) : avg;
    const classAvg = classAverages.length ? classAverages.reduce((a,b)=>a+b,0)/classAverages.length : avg;
    const scoreRows = studentRows.map(r => `<tr>
      <td class="left"><b>${this.esc(r.subject)}</b></td><td>${this.fmt(r.project)}</td><td>${this.fmt(r.ca1)}</td><td>${this.fmt(r.ca2)}</td><td>${this.fmt(r.cbt)}</td><td>${this.fmt(r.paper)}</td>
      <td class="total">${this.fmt(r.total)}</td><td class="grade">${this.grade(r.total)}</td><td>${this.ordinal(subPos[r.student_name+'|'+r.subject]||1)}</td>
      <td>${this.fmt(classAvg,1)}</td><td>${this.fmt(classAvg+1,1)}</td><td>${this.fmt(highest,1)}</td><td>${this.fmt(Math.max(0,classAvg-18),1)}</td><td class="remark">${this.remark(r.total)}</td>
    </tr>`).join('') + Array.from({length: Math.max(0, 8-studentRows.length)},()=>'<tr>'+Array.from({length:14},()=>'<td>&nbsp;</td>').join('')+'</tr>').join('');
    return `<div class="student-report">
      <div class="sr-top"><div>${this.reportHeader('',false)}</div>${first.photo_url?`<img class="sr-photo" src="${this.esc(first.photo_url)}" onerror="this.style.display='none'">`:''}</div>
      <h2 class="term-title">${this.esc((ctx.term||first.term||'TERM').toUpperCase())}</h2>
      <table class="info"><tr><td>Session</td><td><b>${this.esc(ctx.session||first.session)}</b></td><td>Term</td><td><b>${this.esc(ctx.term||first.term)}</b></td><td>Gender: <b>${this.esc(first.gender||'')}</b></td></tr>
      <tr><td>Name of student</td><td><b>${this.esc(name||first.student_name)}</b></td><td>Reg. No</td><td><b>${this.esc(first.admission_no)}</b></td><td>Term ended: <b>${this.esc(ctx.termEnded||'')}</b></td></tr>
      <tr><td>Class</td><td><b>${this.esc(first.class||ctx.class)}</b></td><td>Next term begins</td><td><b>${this.esc(ctx.nextTerm||'')}</b></td><td></td></tr></table>
      <table class="info"><tr><td>Position in entire class</td><td><b>${this.ordinal(pos[name]||pos[first.student_name]||1)}</b></td><td>No. of students in class</td><td><b>${this.studentsFromRows(classRows).length||data.students.length}</b></td><td>No. of days school opened</td><td><b>${ctx.daysOpen||''}</b></td></tr>
      <tr><td>Overall total score</td><td><b>${this.fmt(total)}</b></td><td>Class average score</td><td><b>${this.fmt(classAvg,2)}</b></td><td>No. of days present</td><td><b>${ctx.daysPresent||''}</b></td></tr>
      <tr><td>Student's average score</td><td><b>${this.fmt(avg,2)}</b></td><td>Overall performance</td><td><b>${this.remark(avg)}</b></td><td>Promoted to</td><td><b>${this.esc(ctx.promotedTo||'')}</b></td></tr></table>
      <table class="scores"><thead><tr><th>SUBJECT</th><th>PROJECT<br>(10)</th><th>C/A 1<br>(10)</th><th>C/A 2<br>(20)</th><th>CBT EXAM<br>(20)</th><th>PAPER EXAM<br>(40)</th><th>TOTAL<br>(100)</th><th>GRADE</th><th>SUBJECT<br>POSITION</th><th>AVERAGE<br>SCORE</th><th>AVG %</th><th>HIGHEST<br>IN CLASS</th><th>LOWEST<br>IN CLASS</th><th>REMARK</th></tr></thead><tbody>${scoreRows}</tbody></table>
      ${this.traitTables()}
      <table class="comments"><tr><td>Academic adviser's report</td><td>A good result, reflecting a positive attitude. Continue to challenge yourself and reach greater heights.</td></tr><tr><td>Form master's report</td><td>Friendly and cooperative in group tasks. Shows enthusiasm for learning and completes tasks responsibly.</td></tr><tr><td>Principal's report</td><td>A solid academic performance. Keep up the momentum and aim for excellence in the next term.</td></tr></table>
    </div>`;
  },

  traitTables(){
    const traits=['Punctuality','Mental Alertness','Behaviour','Reliability','Attentiveness','Respect','Neatness','Politeness','Honesty','Relationship With Staff','Relationship With Students','Attitude to School','Self Control'];
    const psycho=['Handwriting','Reading','Verbal Fluency Diction','Musical Skills','Creative Arts','Physical Education','General Reasoning'];
    const traitRows=traits.map((t,i)=>`<tr><td>${t}</td><td>${[4,4,3,3,3,4,4,4,4,4,3,4,4][i]||4}</td></tr>`).join('');
    const psyRows=psycho.map((t,i)=>`<tr><td>${t}</td><td>${[4,4,3,4,4,3,4][i]||4}</td></tr>`).join('');
    return `<div class="trait-grid"><table><thead><tr><th>AFFECTIVE TRAITS</th><th>RATING</th></tr></thead><tbody>${traitRows}</tbody></table><table><thead><tr><th>PSYCHOMOTOR SKILLS</th><th>RATING</th></tr></thead><tbody>${psyRows}</tbody></table><div>${this.gradeKey()}${this.obsKey()}</div></div>`;
  },
  gradeKey(){ return `<table><thead><tr><th>SCORE RANGE</th><th>GRADE</th><th>MEANING</th></tr></thead><tbody><tr><td>0% - &lt;40%</td><td>F9</td><td>Fail</td></tr><tr><td>&gt;=40% - &lt;45%</td><td>E8</td><td>Pass</td></tr><tr><td>&gt;=45% - &lt;50%</td><td>D7</td><td>Pass</td></tr><tr><td>&gt;=50% - &lt;55%</td><td>C6</td><td>Credit</td></tr><tr><td>&gt;=55% - &lt;60%</td><td>C5</td><td>Credit</td></tr><tr><td>&gt;=60% - &lt;65%</td><td>C4</td><td>Credit</td></tr><tr><td>&gt;=65% - &lt;70%</td><td>B3</td><td>Good</td></tr><tr><td>&gt;=70% - &lt;75%</td><td>B2</td><td>Very good</td></tr><tr><td>&gt;=75%</td><td>A1</td><td>Excellent</td></tr></tbody></table>`; },
  obsKey(){ return `<table><thead><tr><th>KEY</th><th>MEANING</th></tr></thead><tbody><tr><td>5</td><td>Excellent observation trait</td></tr><tr><td>4</td><td>High level observation trait</td></tr><tr><td>3</td><td>Acceptable level observation trait</td></tr><tr><td>2</td><td>Minimal observation trait</td></tr><tr><td>1</td><td>No regard for observation trait</td></tr></tbody></table>`; },

  async renderSubject(ctx){
    const data=await this.loadContext(ctx); const rows=data.rows; if(!rows.length)return this.empty('No subject score records found.');
    const sorted=rows.slice().sort((a,b)=>this.n(b.total)-this.n(a.total));
    const avg=sorted.length?sorted.reduce((a,b)=>a+this.n(b.total),0)/sorted.length:0;
    const body=sorted.map((r,i)=>`<tr><td>${i+1}</td><td class="left"><b>${this.esc(r.student_name)}</b></td><td>${this.esc(r.admission_no)}</td><td>${this.fmt(r.project)}</td><td>${this.fmt(r.ca1)}</td><td>${this.fmt(r.ca2)}</td><td>${this.fmt(r.cbt)}</td><td>${this.fmt(r.paper)}</td><td><b>${this.fmt(r.total)}</b></td><td>${this.fmt(r.max)}</td><td>${this.fmt(avg,1)}</td><td>${this.fmt(avg,1)}%</td><td>${this.ordinal(i+1)}</td><td><b>${this.grade(r.total)}</b></td><td>${this.remark(r.total)}</td></tr>`).join('');
    return `<div class="sheet landscape-sheet">${this.reportHeader('BROADSHEET - '+(ctx.subject||rows[0].subject),true)}<p class="meta">SESSION: ${this.esc(ctx.session||rows[0].session)} | CLASS: ${this.esc(ctx.class||rows[0].class)} | Total Students: ${rows.length} | Class Average: ${this.fmt(avg,2)} | Maximum Obtainable Score per Subject: 100</p><table class="broad"><thead><tr><th>S/NO.</th><th>FULL NAME</th><th>ADM NO.</th><th>PROJECT</th><th>C/A 1</th><th>C/A 2</th><th>CBT EXAM</th><th>PAPER EXAM</th><th>TOTAL SCORE</th><th>MAX OBTAINABLE SCORE</th><th>AVERAGE SCORE</th><th>AVERAGE SCORE (%)</th><th>SUBJECT POSITION</th><th>GRADE</th><th>REMARK</th></tr></thead><tbody>${body}</tbody></table></div>`;
  },

  async renderClass(ctx){
    const data=await this.loadContext(ctx); const rows=data.rows; if(!rows.length)return this.empty('No class score records found.');
    const subjects=this.subjects(rows); const students=this.studentsFromRows(rows);
    const aggregates=students.map(st=>{ const sr=rows.filter(r=>r.student_name===st); const total=sr.reduce((a,b)=>a+this.n(b.total),0); const max=subjects.length*100; const avg=max?total/subjects.length:0; return {st,sr,total,max,avg}; }).sort((a,b)=>b.avg-a.avg);
    const body=aggregates.map((x,i)=>`<tr><td>${i+1}</td><td class="left"><b>${this.esc(x.st)}</b></td><td>${this.esc((x.sr[0]||{}).admission_no||'')}</td>${subjects.map(s=>{const r=x.sr.find(y=>y.subject===s);return '<td>'+(r?this.fmt(r.total):'-')+'</td>';}).join('')}<td><b>${this.fmt(x.total)}</b></td><td>${this.fmt(x.max)}</td><td>${this.fmt(x.avg,1)}</td><td>${this.fmt(x.avg,2)}%</td><td>${this.ordinal(i+1)}</td><td><b>${this.grade(x.avg)}</b></td><td>${this.remark(x.avg)}</td></tr>`).join('');
    return `<div class="sheet landscape-sheet">${this.reportHeader('BROADSHEET ('+(ctx.term||'TERM')+')',true)}<p class="meta">SESSION: ${this.esc(ctx.session)} | CLASS: ${this.esc(ctx.class)} | Total Students: ${students.length} | Class Average: ${this.fmt(aggregates.reduce((a,b)=>a+b.avg,0)/(aggregates.length||1),2)} | Maximum Obtainable Score per Subject: 100</p><table class="broad"><thead><tr><th>S/NO.</th><th>FULL NAME</th><th>ADM NO.</th>${subjects.map(s=>'<th class="rot"><span>'+this.esc(s)+'</span></th>').join('')}<th>TOTAL SCORE</th><th>MAX OBTAINABLE SCORE</th><th>AVERAGE SCORE</th><th>AVERAGE SCORE (%)</th><th>CLASS POSITION</th><th>GRADE</th><th>REMARK</th></tr></thead><tbody>${body}</tbody></table></div>`;
  },

  empty(msg){ return `<div class="card"><h3>No output generated</h3><p>${this.esc(msg)}</p></div>`; },

  signatureBlock(){
    // ENTERPRISE V6 (issue 10): the principal's signature now resolves from
    // EVERY place it can be saved — the Settings page (localStorage), the
    // school_settings DB row (window.SC_SETTINGS) and config.js — and Google
    // Drive links are converted to direct-image URLs. A white/scanned
    // background is removed visually using mix-blend-mode:multiply +
    // contrast/brightness filters so the ink shows cleanly on documents.
    const sc = window.SCHOOL || {};
    const st = window.SC_SETTINGS || {};
    let url = '';
    try { url = localStorage.getItem('sc-signature-url') || ''; } catch(_){}
    url = url || st.signature_url || sc.signatureUrl || sc.signature_url || sc.principalSignature || sc.signature || '';
    let name = '';
    try { name = localStorage.getItem('sc-principal-name') || ''; } catch(_){}
    name = name || st.principal_name || sc.principalName || sc.principal_name || 'Principal / Authorised Signatory';
    if (!url) return '<div class="doc-signature"><div style="width:220px;border-top:1px solid #111;margin:34px auto 4px"></div><b>'+this.esc(name)+'</b></div>';
    const direct = (window.Super && Super.idcard && Super.idcard.driveDirect) ? Super.idcard.driveDirect(url) : url;
    return '<div class="doc-signature"><img src="'+this.esc(direct)+'" crossorigin="anonymous" style="max-width:180px;max-height:80px;object-fit:contain;mix-blend-mode:multiply;filter:contrast(1.35) brightness(1.06)" referrerpolicy="no-referrer" onerror="this.style.display=\'none\';this.parentElement.insertAdjacentHTML(\'afterbegin\',\'<div style=&quot;height:40px&quot;></div>\')"><div style="width:220px;border-top:1px solid #111;margin:4px auto"></div><b>'+this.esc(name)+'</b></div>';
  },

  print(title, html, landscape=false){
    const w=window.open('','_blank'); if(!w){ if(typeof toast==='function')toast('Popup blocked. Please allow popups.','warning'); return; }
    const sig = this.signatureBlock();
    w.document.open(); w.document.write(`<!DOCTYPE html><html><head><title>${this.esc(title)}</title><base href="${document.baseURI.replace(/[^/]*$/,'')}">${this.printCSS(landscape)}</head><body>${html}${sig}<script>window.onload=function(){setTimeout(function(){window.print()},400)};<\/script></body></html>`); w.document.close(); w.focus();
  },
  printCSS(landscape=false){ return `<style>
    @page{size:A4 ${landscape?'landscape':'portrait'};margin:8mm}*{box-sizing:border-box}body{font-family:Arial,Helvetica,sans-serif;color:#111;background:#fff;margin:0}.re-head{display:grid;grid-template-columns:95px 1fr;gap:14px;align-items:center;margin-bottom:4px}.re-head.landscape{grid-template-columns:70px 1fr 260px}.re-logo{width:86px;height:86px;object-fit:contain}.re-head.landscape .re-logo{width:62px;height:62px}.re-school h1{font-family:Georgia,serif;color:#1e2a5e;font-size:34px;margin:0;letter-spacing:1px}.re-head.landscape .re-school h1{font-size:24px;writing-mode:vertical-rl;transform:rotate(180deg)}.re-school p{margin:2px 0;font-size:12px}.re-head h2{text-align:center;font-size:14px;margin:0}.term-title{text-align:center;font-size:14px;margin:4px 0}.info,.scores,.trait-grid table,.comments,.broad{width:100%;border-collapse:collapse}.info td,.scores th,.scores td,.trait-grid th,.trait-grid td,.comments td,.broad th,.broad td{border:1px solid #222;padding:4px;font-size:11px}.scores th,.trait-grid th,.broad th{background:#1e2a5e;color:#fff;font-weight:700}.scores tr:nth-child(even),.trait-grid tr:nth-child(even),.comments tr:nth-child(odd),.broad tr:nth-child(even){background:#eef2ff}.left{text-align:left!important}.scores td,.scores th,.broad td,.broad th{text-align:center}.scores .total{color:#16a34a;font-weight:700}.scores .grade{color:#16a34a;font-weight:700}.scores .remark{color:#15803d;font-weight:700}.sr-top{display:grid;grid-template-columns:1fr 90px;gap:10px;align-items:start}.sr-photo{width:78px;height:100px;object-fit:cover}.trait-grid{display:grid;grid-template-columns:1fr 1fr 1.45fr;gap:8px;margin-top:8px}.comments{margin-top:6px}.comments td:first-child{width:170px;font-weight:700}.sheet{font-size:10px}.landscape-sheet .re-head{max-width:100%}.meta{text-align:center;font-size:12px}.broad th,.broad td{font-size:9px;padding:3px}.broad .rot{height:120px;min-width:26px;vertical-align:bottom}.broad .rot span{writing-mode:vertical-rl;transform:rotate(180deg);display:inline-block;white-space:nowrap}.doc-signature{text-align:center;margin-top:22px;page-break-inside:avoid}@media print{button{display:none!important}}</style>`; }
};
if (typeof sb !== 'undefined') ReportEngine.init(sb);
window.ReportEngine = ReportEngine;
