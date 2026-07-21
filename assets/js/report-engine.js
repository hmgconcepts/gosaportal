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



  async roleScope(){
    const db = this.sb || (typeof sb !== 'undefined' ? sb : null);
    const role = String((window.SC_PROFILE && SC_PROFILE.role) || (window.App && App.currentRole) || '').toLowerCase();
    const scope = { role, family: ['parent','student'].includes(role), studentIds: [], names: [], classes: [], admissionNos: [] };
    if (!db || !scope.family || !(window.SC_PROFILE && SC_PROFILE.id)) return scope;
    try {
      if (role === 'student') {
        const { data: st } = await db.from('students').select('id,full_name,class,admission_no').eq('user_id', SC_PROFILE.id).maybeSingle();
        if (st) {
          scope.studentIds = [st.id].filter(Boolean);
          scope.names = [String(st.full_name || '').toLowerCase()].filter(Boolean);
          scope.classes = [String(st.class || '').toLowerCase()].filter(Boolean);
          scope.admissionNos = [String(st.admission_no || '').toLowerCase()].filter(Boolean);
        }
      } else if (role === 'parent') {
        const { data: links } = await db.from('parent_child').select('student_id').eq('parent_id', SC_PROFILE.id);
        const ids = (links || []).map(x => x.student_id).filter(Boolean);
        if (ids.length) {
          const { data: kids } = await db.from('students').select('id,full_name,class,admission_no').in('id', ids);
          scope.studentIds = ids;
          scope.names = (kids || []).map(k => String(k.full_name || '').toLowerCase()).filter(Boolean);
          scope.classes = (kids || []).flatMap(k => [String(k.class || '').toLowerCase()]).filter(Boolean);
          scope.admissionNos = (kids || []).map(k => String(k.admission_no || '').toLowerCase()).filter(Boolean);
        }
      }
    } catch (_) {}
    return scope;
  },
  allowRowForScope(row, scope){
    if (!scope || !scope.family) return true;
    const sid = String(row.student_id || '').toLowerCase();
    const name = String(row.student_name || row.full_name || '').toLowerCase();
    const adm = String(row.student_id_ref || row.admission_no || '').toLowerCase();
    return !!(
      (sid && scope.studentIds.map(String).map(x=>x.toLowerCase()).includes(sid)) ||
      (adm && scope.admissionNos.includes(adm)) ||
      (name && scope.names.includes(name))
    );
  },

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

    const scope = await this.roleScope();
    let q = db.from('results').select('*').limit(5000);
    if (klass) q = q.eq('class', klass);
    if (subject) q = q.eq('subject', subject);
    if (term) q = q.eq('term', term);
    if (session) q = q.eq('session', session);
    if (studentText) q = q.ilike('student_name', '%' + studentText + '%');
    const { data: rows, error } = await q;
    if (error) throw new Error(error.message);
    let extraRows = [];
    const familyFilter = (r) => this.allowRowForScope(r, scope);
    try { let cq = db.from('cbt_results').select('*,cbt_exams(subject,class,term,session,report_column,max_score)').limit(5000); const cbtResults = await cq; (cbtResults.data||[]).forEach(x => { const e=x.cbt_exams||{}; const row={student_name:x.student_name, student_id_ref:x.student_id_ref, class:x.student_class||e.class, subject:e.subject||'CBT', term:e.term, session:e.session, cbt_score:x.percent, total:x.percent, max_score:100}; if (familyFilter(row)) extraRows.push(row); }); } catch(e) {}
    try { const reading = await db.from('reading_scores').select('*').limit(5000); (reading.data||[]).forEach(x => { const row={student_name:x.student_name, class:x.class, subject:x.subject||'Digital Library', term:x.term, session:x.session, assignment:x.score, total:x.score, max_score:100}; if (familyFilter(row)) extraRows.push(row); }); } catch(e) {}
    try { const subs = await db.from('lms_submissions').select('*,assignments(subject,class,title)').limit(5000); (subs.data||[]).forEach(x => { const a=x.assignments||{}; const row={student_id:x.student_id, student_name:x.student_name||'', class:a.class, subject:a.subject||a.title||'Assignment', term:x.term, session:x.session, assignment:x.score, total:x.score, max_score:100}; if (familyFilter(row)) extraRows.push(row); }); } catch(e) {}

    let sq = db.from('students').select('*').limit(5000);
    if (klass) sq = sq.eq('class', klass);
    const { data: students } = await sq;

    const baseRows = (scope.family ? (rows || []).filter(r => familyFilter(r)) : (rows || []));
    const normalized = baseRows.concat(extraRows.filter(r => (!klass || r.class===klass) && (!subject || r.subject===subject) && (!term || r.term===term) && (!session || r.session===session))).map(r => this.normalizeResult(r, students || []));
    return { ctx:{class:klass,subject,term,session,student:studentText}, rows:normalized, students:students||[], school:this.school(), feeBalances: await this.loadFeeBalances(students||[], term, session) };
  },



  async loadFeeBalances(students, term, session){
    const db = this.sb || (typeof sb !== 'undefined' ? sb : null); const out={};
    if(!db) return out;
    try{
      const ids=(students||[]).map(s=>s.id).filter(Boolean); let q=db.from('fee_payments').select('student_id,student_name,fee_total,amount_paid,balance,term,session').limit(5000);
      if(term) q=q.eq('term',term); if(session) q=q.eq('session',session);
      const {data}=await q; (data||[]).forEach(f=>{ const key=f.student_id || String(f.student_name||'').toLowerCase(); const bal=f.balance!=null?Number(f.balance):Math.max(0,(Number(f.fee_total)||0)-(Number(f.amount_paid)||0)); out[key]=bal; });
    }catch(_){}
    return out;
  },

  async loadNextTermFees(className, studentId){
    const db = this.sb || (typeof sb !== 'undefined' ? sb : null);
    const fallback = {fees:0, currency:(window.SCHOOL&&SCHOOL.currency)||'₦', begins:'', note:'Payable before resumption', items:[]};
    if(!db) return fallback;

    let begins = '', global = {};
    try {
      const { data: sData } = await db.from('school_settings').select('next_term_fees,next_term_fees_currency,next_term_begins,next_term_fees_note').eq('id',1).maybeSingle();
      if (sData) { begins = sData.next_term_begins || ''; global = sData; }
    } catch (_) {}

    let st = null;
    if (studentId) {
      try { const r = await db.from('students').select('id,class,arm,department').eq('id', studentId).maybeSingle(); st = r.data || null; } catch(_) {}
    }
    const cls = (className || (st && st.class) || '').trim();
    const arm = (st && st.arm) || '';
    const dept = (st && st.department) || '';
    const money = row => {
      if (!row) return null;
      const total = Number(row.total || row.amount || row.next_term_fees || 0) ||
        (Number(row.tuition)||0) + (Number(row.exam_fee)||0) + (Number(row.development)||0) + (Number(row.transport)||0) + (Number(row.boarding)||0) + (Number(row.other_fee)||0) - (Number(row.discount)||0);
      if (!total) return null;
      let items = [];
      try { items = Array.isArray(row.fee_items) ? row.fee_items : (typeof row.fee_items === 'string' ? JSON.parse(row.fee_items) : []); } catch(_) { items = []; }
      return { fees: total, currency: row.currency || row.next_term_fees_currency || global.next_term_fees_currency || fallback.currency, begins: row.next_term_begins || begins || global.next_term_begins || '', note: row.note || row.next_term_fees_note || row.description || 'Class/department next-term bill', items };
    };

    // Preferred source: class_fee_structure, because it supports class, arm and department.
    try {
      let q = db.from('class_fee_structure').select('*').eq('term','Next Term').order('updated_at', {ascending:false}).limit(50);
      if (cls) q = q.eq('class', cls);
      const { data } = await q;
      const rows = data || [];
      const pick = rows.find(x => String(x.department||'').toLowerCase() === String(dept||'').toLowerCase() && String(x.arm||'') === String(arm||'')) ||
                   rows.find(x => String(x.department||'').toLowerCase() === String(dept||'').toLowerCase()) ||
                   rows.find(x => !x.department && (!x.arm || String(x.arm||'') === String(arm||''))) || rows[0];
      const out = money(pick); if (out) return out;
    } catch (_) {}

    // Backward-compatible fallbacks for older databases where fees were stored on departments/classes.
    if (dept) {
      try { const {data} = await db.from('departments').select('next_term_fees,next_term_fees_currency,next_term_fees_note').eq('name', dept).maybeSingle(); const out = money(data); if(out) return out; } catch(_) {}
    }
    if (cls) {
      try { const {data} = await db.from('classes').select('next_term_fees,next_term_fees_currency,next_term_fees_note').eq('name', cls).maybeSingle(); const out = money(data); if(out) return out; } catch(_) {}
    }
    if (global && Number(global.next_term_fees) > 0) return {fees:Number(global.next_term_fees)||0, currency:global.next_term_fees_currency||fallback.currency, begins:global.next_term_begins||'', note:global.next_term_fees_note||fallback.note, items:[]};
    return fallback;
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
    const name = ctx.student || rows[0].student_name;
    const studentRows = rows.filter(r => !ctx.student || r.student_name.toLowerCase().includes(String(ctx.student).toLowerCase()));
    const list = studentRows.length ? studentRows : rows;
    const first = list[0] || {}; const sc=data.school;
    const total = list.reduce((a,b)=>a+this.n(b.total),0); const obtainable=list.reduce((a,b)=>a+this.n(b.max||100),0)||list.length*100;
    const avg = obtainable ? (total/obtainable*100) : 0;
    const bal = data.feeBalances[first.student_id] ?? data.feeBalances[String(first.student_name||'').toLowerCase()] ?? 0;
    const logo='assets/img/logo.'+sc.logoExt;
    const subjectClassAvg = (sub) => {
      const subRows = rows.filter(r => r.class === first.class && r.subject === sub);
      if (!subRows.length) return '—';
      const sum = subRows.reduce((acc, r) => acc + Number(r.total || 0), 0);
      return (sum / subRows.length).toFixed(1);
    };
    const scoreRows = list.map(r => {
      const classAvg = subjectClassAvg(r.subject);
      return `<tr><td class="left">${this.esc(r.subject)}</td><td>${this.fmt(r.ca1)}</td><td>${this.fmt(r.ca2)}</td><td>${this.fmt(r.cbt)}</td><td>${this.fmt(r.project)}</td><td>${this.fmt(r.paper)}</td><td><b>${this.fmt(r.total)}</b></td><td style="color:#475569;font-weight:700">${classAvg}</td><td class="grade">${this.grade(r.total)}</td><td>${this.remark(r.total)}</td></tr>`;
    }).join('');

    // v5: Compute class position
    let classPosition = '—'; let classSize = '—';
    try{
      const stName = String(first.student_name||'').toLowerCase();
      const stClass = first.class;
      // Compute position from all rows for the same class+term+session
      const classRows = rows.filter(r => r.class === stClass);
      const totals = {}; classRows.forEach(r => { totals[r.student_name] = (totals[r.student_name]||0) + this.n(r.total); });
      const sorted = Object.entries(totals).sort((a,b)=>b[1]-a[1]);
      classSize = sorted.length;
      const idx = sorted.findIndex(x => x[0].toLowerCase() === stName);
      classPosition = idx >= 0 ? this.ordinal(idx+1) : '—';
    }catch(_){}

    // v5: Try to load affective/psychomotor from v9 tables or fall back to a sensible default
    let affective = {
      Punctuality: '5', Neatness: '5', Politeness: '5', Honesty: '5', Leadership: '4', Cooperation: '5', Attentiveness: '5', Initiative: '4'
    };
    let psychomotor = {
      Handwriting: '4', 'Verbal Fluency': '5', Sports: '4', Creativity: '5', Crafts: '4', 'Handling Tools': '4', Drawing: '4', Music: '5'
    };
    try{
      const {data: aff} = await this.sb.from('affective_traits').select('*').eq('student_id', first.student_id).eq('term', first.term||'').eq('session', first.session||'').maybeSingle();
      if(aff && aff.data) affective = Object.assign(affective, aff.data);
      else if(aff && aff.ratings) affective = Object.assign(affective, aff.ratings);
    }catch(_){}
    try{
      const {data: ps} = await this.sb.from('psychomotor_traits').select('*').eq('student_id', first.student_id).eq('term', first.term||'').eq('session', first.session||'').maybeSingle();
      if(ps && ps.data) psychomotor = Object.assign(psychomotor, ps.data);
      else if(ps && ps.ratings) psychomotor = Object.assign(psychomotor, ps.ratings);
    }catch(_){}

    const ratingLabel = (v) => {
      const val = parseInt(v);
      if (isNaN(val)) return v;
      return { 5:'Excellent', 4:'Very Good', 3:'Good', 2:'Fair', 1:'Poor' }[val] || v;
    };
    const ratingCell = (v) => {
      const val = parseInt(v);
      const label = ratingLabel(v);
      const grade = isNaN(val) ? 'B' : (val >= 5 ? 'A' : val >= 4 ? 'B' : val >= 3 ? 'C' : val >= 2 ? 'D' : 'F');
      return `<span class="re-rating re-rating-${grade.toLowerCase()}">${this.esc(val || v)}</span> <small style="font-size:0.7rem;color:#64748b">${this.esc(label)}</small>`;
    };
    const affectiveRows = Object.entries(affective).map(([k,v]) => `<tr><td class="left">${this.esc(k)}</td><td>${ratingCell(v)}</td></tr>`).join('');
    const psychomotorRows = Object.entries(psychomotor).map(([k,v]) => `<tr><td class="left">${this.esc(k)}</td><td>${ratingCell(v)}</td></tr>`).join('');

    // v5: Get attendance for the term
    let attendanceStr = '—';
    try{
      const {data: att} = await this.sb.from('attendance').select('*').eq('student_id', first.student_id).eq('term', first.term||'').eq('session', first.session||'');
      if(att && att.length){
        const present = att.filter(a => String(a.status).toLowerCase()==='present').length;
        attendanceStr = `${present} / ${att.length} days`;
      }
    }catch(_){}

    // V2.1 Issue #17: Load next term fees bill for report card
    let nextTermBill = {fees:0, currency:'₦', begins:'', note:''};
    try{ nextTermBill = await this.loadNextTermFees(first.class || first.class_name, first.student_id); }catch(_){}

    // v5: Get comments from report_comments table (v9)
    let classTeacherComment = '';
    let principalComment = '';
    let nextTermBegins = '';
    try{
      const {data: ct} = await this.sb.from('report_comments').select('*').eq('student_id', first.student_id).eq('term', first.term||'').eq('session', first.session||'').maybeSingle();
      if(ct){ 
        classTeacherComment = ct.class_teacher_comment||''; 
        principalComment = ct.principal_comment||''; 
        if(ct.next_term_begins) nextTermBegins = this.fmtDMY(ct.next_term_begins);
      }
    }catch(_){}
    classTeacherComment = classTeacherComment || this.remark(avg) + '. A good performance.';
    principalComment = principalComment || (avg >= 50 ? 'Promoted to the next class.' : 'Needs more effort in the coming term.');

    // v5: Build school stamp SVG with embedded principal signature
    let sigUrl = '';
    try { sigUrl = localStorage.getItem('sc-signature-url') || ''; } catch(_){}
    sigUrl = sigUrl || sc.signatureUrl || sc.signature_url || sc.principalSignature || sc.signature || '';
    if (sigUrl && sigUrl.includes('drive.google.com')) {
      const idMatch = sigUrl.match(/id=([a-zA-Z0-9_-]+)/) || sigUrl.match(/\/file\/d\/([a-zA-Z0-9_-]+)/);
      if (idMatch) sigUrl = 'https://drive.google.com/uc?export=view&id=' + idMatch[1];
    }
    const hasSig = !!sigUrl;
    const principalName = (localStorage.getItem('sc-principal-name') || sc.principalName || 'Principal').slice(0,25);
    const settings = window.SC_SETTINGS || {};
    const stampEnabled = settings.stamp_enabled !== false && sc.stamp_enabled !== false;
    const stampColor = settings.stamp_color || sc.stamp_color || '#1e3a8a';
    const stampText = settings.stamp_text || sc.stamp_text || 'OFFICIAL SCHOOL SEAL';

    const stampSvg = `<svg viewBox="0 0 120 120" xmlns="http://www.w3.org/2000/svg" class="re-stamp" style="position:relative">
      <defs>
        <path id="stampTopArc_${first.student_id||'r'}" d="M 16,60 A 44,44 0 0,1 104,60" fill="none"/>
        <path id="stampBotArc_${first.student_id||'r'}" d="M 18,62 A 42,42 0 0,0 102,62" fill="none"/>
      </defs>
      <circle cx="60" cy="60" r="56" fill="none" stroke="${stampColor}" stroke-width="2.5" stroke-dasharray="0"/>
      <circle cx="60" cy="60" r="50" fill="none" stroke="${stampColor}" stroke-width="1"/>
      <text font-family="Arial, sans-serif" font-size="8.5" letter-spacing="1.5" font-weight="900" fill="${stampColor}">
        <textPath href="#stampTopArc_${first.student_id||'r'}" startOffset="50%" text-anchor="middle">${this.esc((sc.name||'SCHOOL').toUpperCase())}</textPath>
      </text>
      <text font-family="Arial, sans-serif" font-size="6" font-style="italic" font-weight="700" fill="${stampColor}">
        <textPath href="#stampBotArc_${first.student_id||'r'}" startOffset="50%" text-anchor="middle">★ ${this.esc(stampText).toUpperCase()} ★</textPath>
      </text>
      <circle cx="60" cy="60" r="34" fill="none" stroke="${stampColor}" stroke-dasharray="1 1" stroke-width="0.5"/>
      ${hasSig ? 
        `<image x="32" y="32" width="56" height="56" href="${sigUrl}" style="mix-blend-mode:multiply;filter:contrast(1.4) brightness(1.05)"/>` : 
        `<text x="60" y="65" text-anchor="middle" font-family="'Brush Script MT', cursive, sans-serif" font-style="italic" font-size="12" fill="${stampColor}">${this.esc(principalName)}</text>`
      }
      <text x="60" y="82" text-anchor="middle" font-family="Arial, sans-serif" font-size="5" font-weight="900" fill="${stampColor}">CERTIFIED</text>
      <text x="60" y="88" text-anchor="middle" font-family="Arial, sans-serif" font-size="4" font-weight="700" fill="${stampColor}">${new Date().toLocaleDateString()}</text>
    </svg>`;

    return `<div class="report-sheet sample-report"><div class="head"><img class="logo" src="${logo}" onerror="this.style.display='none'"><div class="school"><h1>${this.esc(sc.name)}</h1><p>📍 ${this.esc(sc.address)} · 📞 ${this.esc(sc.phone)} · ✉️ ${this.esc(sc.email)}</p><p style="font-style:italic;color:#7c2d12">Motto: ${this.esc(sc.motto)}</p></div><div class="photo">${first.photo_url ? `<img src="${this.esc(first.photo_url)}" onerror="this.parentNode.innerHTML='Photo'">` : 'Student<br>Photo'}</div></div><div class="title">TERMINAL REPORT SHEET — ${this.esc(ctx.term||first.term||'TERM')}, ${this.esc(ctx.session||first.session||'SESSION')}</div><table class="info"><tr><td><b>Name:</b> ${this.esc(first.student_name)}</td><td><b>Admission No:</b> ${this.esc(first.admission_no)}</td><td><b>Class:</b> ${this.esc(first.class)}</td></tr><tr><td><b>No. in Class:</b> ${classSize}</td><td><b>Attendance:</b> ${this.esc(attendanceStr)}</td><td><b>Position:</b> <b style="color:#16a34a">${classPosition}</b></td></tr></table><table class="scores" style="margin-top:8px"><thead><tr><th class="left">SUBJECT</th><th>CA1<br>(10)</th><th>CA2<br>(10)</th><th>CA3/CBT<br>(10)</th><th>PROJECT<br>(10)</th><th>EXAM<br>(60)</th><th>TOTAL<br>(100)</th><th>CLASS<br>AVG</th><th>GRADE</th><th>REMARK</th></tr></thead><tbody>${scoreRows}</tbody></table><table class="info" style="margin-top:8px"><tr><td><b>Total Score:</b> ${this.fmt(total)} / ${this.fmt(obtainable)}</td><td><b>Average:</b> ${this.fmt(avg,1)}%</td><td><b>Fees Balance:</b> ${bal===0?'₦0 (FULLY PAID)':'₦'+Number(bal).toLocaleString()}</td><td><b>Grade:</b> <span class="grade">${this.grade(avg)}</span></td></tr></table>
<table class="info" style="margin-top:6px;background:#fffbeb;border:1px solid #fcd34d"><tr><td><b>Previous School Fees Owed:</b> <span style="color:${bal>0?'#b91c1c':'#16a34a'};font-weight:900">${bal===0?'₦0 (FULLY PAID)':'₦'+Number(bal).toLocaleString()}</span></td><td><b>Next Term School Bill:</b> <span style="color:#b45309;font-weight:900">${nextTermBill.fees ? (nextTermBill.currency + Number(nextTermBill.fees).toLocaleString()) : '—'} </span> <small style="color:#92400e">(${this.esc(nextTermBill.note||'Payable before resumption')})</small></td><td><b>Next Term Begins:</b> ${this.esc(nextTermBill.begins ? this.fmtDMY(nextTermBill.begins) : (nextTermBegins||'—'))}</td></tr></table><div class="traits re-traits"><div><table><tr><th colspan="2">⭐ AFFECTIVE DOMAIN</th></tr>${affectiveRows}</table></div><div><table><tr><th colspan="2">🏃 PSYCHOMOTOR DOMAIN</th></tr>${psychomotorRows}</table></div></div><table class="comments" style="margin-top:10px"><tr><td>Class Teacher's Comment</td><td>${this.esc(classTeacherComment)}</td></tr><tr><td>Principal's Comment</td><td>${this.esc(principalComment)}</td></tr><tr><td>Next Term Begins</td><td>${this.esc(nextTermBegins || sc.next_term_begins || 'See school calendar')} &nbsp;·&nbsp; <b>Fees Balance:</b> ${bal===0?'₦0 (FULLY PAID)':'₦'+Number(bal).toLocaleString()}</td></tr></table><div class="sig re-sig"><div><div class="re-sig-script">${this.signatureBlock('teacher')}</div><div class="re-sig-line">Class Teacher's Signature</div></div><div style="position:relative">${stampEnabled ? '<div class="re-stamp-wrap">'+stampSvg+'</div><div class="re-sig-line" style="margin-top:6px">Principal\'s Signature &amp; Official Stamp</div>' : '<div class="re-sig-line">Principal\'s Signature</div>'}</div></div><p class="note">This is the report card the platform prints. Generated by School Connect · HMG Concepts.</p></div>`;
  },

  async renderSubject(ctx){
    const data=await this.loadContext(ctx); const rows=data.rows; if(!rows.length)return this.empty('No subject score records found.');
    const sc=data.school; const sorted=rows.slice().sort((a,b)=>this.n(b.total)-this.n(a.total));
    const avg=sorted.length?sorted.reduce((a,b)=>a+this.n(b.total),0)/sorted.length:0;
    const body=sorted.map((r,i)=>`<tr${i===0?' class="top"':''}><td>${i+1}</td><td class="left"><b>${this.esc(r.student_name)}</b></td><td>${this.esc(r.admission_no)}</td><td>${this.fmt(r.ca1)}</td><td>${this.fmt(r.ca2)}</td><td>${this.fmt(r.cbt)}</td><td>${this.fmt(r.project)}</td><td>${this.fmt(r.paper)}</td><td><b>${this.fmt(r.total)}</b></td><td>${this.fmt(avg,1)}</td><td>${this.ordinal(i+1)}</td><td class="grade">${this.grade(r.total)}</td><td>${this.remark(r.total)}</td></tr>`).join('');
    return `<div class="sheet subject-sheet"><h1>${this.esc(sc.name)} — SUBJECT BROADSHEET</h1><p class="meta">${this.esc(ctx.term||'TERM')} · ${this.esc(ctx.session||'SESSION')} · CLASS: ${this.esc(ctx.class||'')} · SUBJECT: ${this.esc(ctx.subject||rows[0].subject)} · Class Average: ${this.fmt(avg,1)}%</p><table><thead><tr><th>S/N</th><th class="left">FULL NAME</th><th>ADM NO.</th><th>CA1</th><th>CA2</th><th>CBT</th><th>PROJECT</th><th>EXAM</th><th>TOTAL</th><th>AVG</th><th>POS</th><th>GRADE</th><th>REMARK</th></tr></thead><tbody>${body}</tbody></table><div class="stat"><div><b>${sorted.length}</b>Candidates</div><div><b>${this.fmt(avg,1)}%</b>Average</div><div><b>${this.fmt((sorted[0]||{}).total||0)}</b>Highest</div><div><b>${this.fmt((sorted[sorted.length-1]||{}).total||0)}</b>Lowest</div></div><div class="sig"><div>Subject Teacher</div><div>Head of Department</div></div><p class="note">SAMPLE-style subject broadsheet. Generated by School Connect · HMG Concepts.</p></div>`;
  },

  async renderClass(ctx){
    const data=await this.loadContext(ctx); const rows=data.rows; if(!rows.length)return this.empty('No class score records found.');
    const sc=data.school; const subjects=this.subjects(rows); const students=this.studentsFromRows(rows);
    const aggregates=students.map(st=>{ const sr=rows.filter(r=>r.student_name===st); const total=sr.reduce((a,b)=>a+this.n(b.total),0); const max=subjects.length*100; const avg=max?total/subjects.length:0; return {st,sr,total,max,avg}; }).sort((a,b)=>b.avg-a.avg);
    const classAvg=aggregates.reduce((a,b)=>a+b.avg,0)/(aggregates.length||1);
    const body=aggregates.map((x,i)=>`<tr${i===0?' class="top"':''}><td>${i+1}</td><td class="left"><b>${this.esc(x.st)}</b></td><td>${this.esc((x.sr[0]||{}).admission_no||'')}</td>${subjects.map(s=>{const r=x.sr.find(y=>y.subject===s);return '<td>'+(r?this.fmt(r.total):'-')+'</td>';}).join('')}<td><b>${this.fmt(x.total)}</b></td><td>${this.fmt(x.avg,1)}</td><td>${this.ordinal(i+1)}</td><td>${this.grade(x.avg)}</td><td>${this.remark(x.avg)}</td></tr>`).join('');
    return `<div class="sheet class-sheet"><h1>${this.esc(sc.name)} — CLASS BROADSHEET</h1><p class="meta">${this.esc(ctx.term||'TERM')} · ${this.esc(ctx.session||'SESSION')} · CLASS: ${this.esc(ctx.class||'')} · ${students.length} students · Class Average: ${this.fmt(classAvg,1)}% · Max obtainable per subject: 100</p><table><thead><tr><th>S/N</th><th class="left">FULL NAME</th><th>ADM NO.</th>${subjects.map(s=>'<th class="rot"><span>'+this.esc(s)+'</span></th>').join('')}<th>TOTAL</th><th>AVG %</th><th>POS</th><th>GRADE</th><th>REMARK</th></tr></thead><tbody>${body}</tbody></table><p class="note">SAMPLE-style class broadsheet. One row per student, one column per subject, automatic totals/averages/positions/grades. Landscape A4. Generated by School Connect · HMG Concepts.</p></div>`;
  },

  empty(msg){ return `<div class="card"><h3>No output generated</h3><p>${this.esc(msg)}</p></div>`; },

  signatureBlock(kind){
    // ENTERPRISE V6 (issue 10): the principal's signature now resolves from
    // EVERY place it can be saved — the Settings page (localStorage), the
    // school_settings DB row (window.SC_SETTINGS) and config.js — and Google
    // Drive links are converted to direct-image URLs. A white/scanned
    // background is removed visually using mix-blend-mode:multiply +
    // contrast/brightness filters so the ink shows cleanly on documents.
    // v5: support 'teacher' (uses class_teacher_signature_url) or 'principal' (default)
    const sc = window.SCHOOL || {};
    const st = window.SC_SETTINGS || {};
    const isTeacher = kind === 'teacher';
    let url = '';
    try { url = localStorage.getItem(isTeacher ? 'sc-class-teacher-signature-url' : 'sc-signature-url') || ''; } catch(_){}
    url = url || st[isTeacher?'class_teacher_signature_url':'signature_url'] || sc[isTeacher?'classTeacherSignature':'signatureUrl'] || sc[isTeacher?'class_teacher_signature_url':'signature_url'] || sc[isTeacher?'classTeacherSignatureUrl':'principalSignature'] || sc[isTeacher?'classTeacherSignatureUrl':'signature'] || '';
    let name = '';
    try { name = localStorage.getItem(isTeacher ? 'sc-class-teacher-name' : 'sc-principal-name') || ''; } catch(_){}
    name = name || st[isTeacher?'class_teacher_name':'principal_name'] || sc[isTeacher?'classTeacherName':'principalName'] || sc[isTeacher?'class_teacher_name':'principal_name'] || (isTeacher ? 'Class Teacher' : 'Principal / Authorised Signatory');
    if (!url) return '<div class="doc-signature"><div style="width:220px;border-top:1px solid #111;margin:34px auto 4px"></div><b>'+this.esc(name)+'</b></div>';
    const direct = (window.Super && Super.idcard && Super.idcard.driveDirect) ? Super.idcard.driveDirect(url) : url;
    return '<div class="doc-signature"><img src="'+this.esc(direct)+'" crossorigin="anonymous" style="max-width:180px;max-height:80px;object-fit:contain;mix-blend-mode:multiply;filter:contrast(1.35) brightness(1.06)" referrerpolicy="no-referrer" onerror="this.style.display=\'none\';this.parentElement.insertAdjacentHTML(\'afterbegin\',\'<div style=&quot;height:40px&quot;></div>\')"><div style="width:220px;border-top:1px solid #111;margin:4px auto"></div><b>'+this.esc(name)+'</b></div>';
  },


  // V2.1 Issue #15-16: Push CBT exam results into Results table with column selection
  // Teacher can choose which report sheet column (CA1, CA2, CA3, CBT Exam, Exam, Project, etc) to fill
  async pushCBTToResults(examId, column, term, session){
    const db = this.sb || (typeof sb !== 'undefined' ? sb : null);
    if(!db){ toast('Database not configured','warning'); return; }
    if(!examId){ toast('Select an exam','warning'); return; }
    if(!column){ toast('Select the report-card column created for this assessment.','warning'); return; }
    const {data: exam, error: eErr} = await db.from('cbt_exams').select('*').eq('id', examId).maybeSingle();
    if(eErr || !exam){ toast('Exam not found: '+(eErr?.message||''),'danger'); return; }
    const {data: results, error} = await db.from('cbt_results').select('*').eq('exam_id', examId).limit(5000);
    if(error){ toast('Could not load CBT results: '+error.message,'danger'); return; }
    if(!results || !results.length){ toast('No CBT results to push yet.','info'); return; }
    let ok=0, fail=0;
    for(const r of results){
      // Normalize student lookup
      let studentId = null;
      try{
        const {data: st} = await db.from('students').select('id').or(`admission_no.eq.${r.student_id_ref},full_name.ilike.%${r.student_name}%`).maybeSingle();
        if(st) studentId = st.id;
      }catch(_){}
      const payload = {
        student_id: studentId,
        student_name: r.student_name,
        subject: exam.subject || 'CBT',
        class: r.student_class || exam.class || '',
        term: term || exam.term || '',
        session: session || exam.session || '',
        assessment_source: 'cbt',
        assessment_ref: r.id
      };
      payload[column] = r.percent != null ? Math.round((Number(r.percent)/100) * (Number(exam.max_score)||20)) : (r.score||0);
      // Use upsert by assessment_ref to avoid duplicates
      const {error: insErr} = await db.from('results').upsert(payload, {onConflict:'assessment_source,assessment_ref'});
      if(insErr){
        // fallback insert
        const {error: insErr2} = await db.from('results').insert(payload);
        if(insErr2) fail++; else ok++;
      } else ok++;
    }
    toast(`✅ Pushed ${ok} CBT result(s) into Results table column ${column}. ${fail?fail+' failed.':''} Use Report Cards to see them.`, 'success', 8000);
    if(window.App && App.logActivity) App.logActivity('push-cbt-to-results', 'results', `${ok} rows from exam ${examId} → ${column}`);
  },

  async reportPickerOptions(){
    const db=this.sb || (typeof sb!=='undefined'?sb:null); const empty={terms:[],sessions:[],columns:[]}; if(!db)return empty;
    try { const [{data:lookups},{data:columns}]=await Promise.all([db.from('lookups').select('kind,value').in('kind',['term','session']),db.from('assessment_columns').select('name,max_mark,position,subject').eq('subject','*').order('position')]);
      const unique=(a)=>[...new Set(a.filter(Boolean))]; return {terms:unique((lookups||[]).filter(x=>x.kind==='term').map(x=>x.value)),sessions:unique((lookups||[]).filter(x=>x.kind==='session').map(x=>x.value)),columns:(columns||[])};
    } catch(_){return empty;}
  },
  _options(values, selected='', label='— select —'){return '<option value="">'+this.esc(label)+'</option>'+values.map(v=>{const value=typeof v==='string'?v:(v.name||''); const text=typeof v==='string'?v:(v.name+(v.max_mark!=null?' (max '+v.max_mark+')':'')); return '<option value="'+this.esc(String(value).toLowerCase().replace(/[^a-z0-9]+/g,'_'))+'" '+(String(value).toLowerCase().replace(/[^a-z0-9]+/g,'_')===selected?'selected':'')+'>'+this.esc(text)+'</option>';}).join('');},
  async openCBTExportModal(){
    const db = this.sb || (typeof sb !== 'undefined' ? sb : null);
    if(!db){ toast('Database not configured','warning'); return; }
    const {data: exams} = await db.from('cbt_exams').select('id,title,subject,class,term,session,report_column,max_score').order('created_at',{ascending:false}).limit(100);
    if(!exams || !exams.length){ toast('No CBT exams found','warning'); return; }
    const examOpts = exams.map(e=>`<option value="${e.id}">${this.esc(e.title)} — ${this.esc(e.subject||'')} (${this.esc(e.class||'')}) [${this.esc(e.report_column||'CBT Exam')}]</option>`).join('');
    const picker = await this.reportPickerOptions();
    const colOpts = this._options(picker.columns, '', '— select report-card column —');
    const termOpts = this._options(picker.terms, '', '— select term —');
    const sessionOpts = this._options(picker.sessions, '', '— select session —');
    openModal('📊 Push CBT Results → Report Card',
      `<p style="color:var(--gray-600)">Select the CBT exam and which report sheet column its scores should fill. CBT is used for <strong>mid-term tests (CA1/CA2)</strong> and <strong>terminal exams (Exam)</strong> — mapping is now easy.</p>
       <div class="form-group"><label>CBT Exam</label><select id="cbt-exp-exam" class="form-select">${examOpts}</select></div>
       <div class="grid grid-3">
         <div class="form-group"><label>Target Column</label><select id="cbt-exp-col" class="form-select">${colOpts}</select><small style="color:var(--gray-500)">Where scores go in report card</small></div>
         <div class="form-group"><label>Term</label><select id="cbt-exp-term" class="form-select">${termOpts}</select></div>
         <div class="form-group"><label>Session</label><select id="cbt-exp-sess" class="form-select">${sessionOpts}</select></div>
       </div>
       <p style="font-size:.85rem;color:var(--gray-500)">Scores are scaled to the exam's max_score (e.g. 20) and upserted into Results table. Then open <strong>Report Cards</strong> to generate broadsheet and report card — broadsheet, subject broadsheet and report card are prepared automatically.</p>`,
      `<button class="btn btn-outline" onclick="closeModal()">Cancel</button><button class="btn btn-primary" onclick="ReportEngine.doCBTExport()">🚀 Push to Report Card</button>`
    );
  },

  async doCBTExport(){
    const examId=document.getElementById('cbt-exp-exam')?.value;
    const col=document.getElementById('cbt-exp-col')?.value||'cbt';
    const term=document.getElementById('cbt-exp-term')?.value||'';
    const sess=document.getElementById('cbt-exp-sess')?.value||'';
    closeModal();
    await this.pushCBTToResults(examId, col, term, sess);
  },

  print(title, html, landscape=false){
    const w=window.open('','_blank'); if(!w){ if(typeof toast==='function')toast('Popup blocked. Please allow popups.','warning'); return; }
    const sig = this.signatureBlock();
    const st=window.SC_SETTINGS||{}, color=st.stamp_color||'#1e3a8a', label=this.esc((st.stamp_text||'OFFICIAL SCHOOL SEAL').toUpperCase());
    const stamp=st.stamp_enabled===false?'':'<div style="margin:20px auto;text-align:center"><div style="display:inline-flex;width:112px;height:112px;border:3px double '+color+';border-radius:50%;align-items:center;justify-content:center;color:'+color+';font:900 10px Arial;text-align:center;padding:16px;transform:rotate(-6deg)">'+label+'</div><div style="font-size:10px;font-weight:700">Official School Stamp</div></div>';
    w.document.open(); w.document.write(`<!DOCTYPE html><html><head><title>${this.esc(title)}</title><base href="${document.baseURI.replace(/[^/]*$/,'')}">${this.printCSS(landscape)}</head><body>${html}${stamp}${sig}<script>window.onload=function(){setTimeout(function(){window.print()},400)};<\/script></body></html>`); w.document.close(); w.focus();
  },
  printCSS(landscape=false){ return `<style>
    @page{size:A4 ${landscape?'landscape':'portrait'};margin:${landscape?'8mm':'10mm'}}*{box-sizing:border-box}body{font-family:Arial,sans-serif;color:#111;background:#fff;margin:0;padding:16px}.sheet,.report-sheet{background:#fff;padding:${landscape?'20px':'24px'};max-width:${landscape?'1100px':'760px'};margin:0 auto}.head{display:flex;align-items:center;gap:12px;border-bottom:3px solid #111;padding-bottom:8px}.logo{width:58px;height:58px;border-radius:12px;object-fit:contain}.school{flex:1;text-align:center}.school h1,h1{font-family:Georgia,serif;color:#008c7a;text-align:center;margin:0;font-size:${landscape?'22px':'21px'}}.school p{margin:2px 0;font-size:11px;color:#334155}.photo{width:82px;height:92px;border:1px dashed #94a3b8;display:flex;align-items:center;justify-content:center;text-align:center;font-size:10px;color:#64748b;overflow:hidden}.photo img{width:100%;height:100%;object-fit:cover}.title{text-align:center;background:#008c7a;color:#fff;font-weight:800;margin:8px 0;padding:5px;letter-spacing:.5px}.meta{text-align:center;font-size:11px;margin:6px 0 10px;color:#334155}table{width:100%;border-collapse:collapse}.info td,.scores th,.scores td,.traits th,.traits td,.comments td,th,td{border:1px solid #222;padding:${landscape?'3px 4px':'4px 6px'};font-size:${landscape?'9.5px':'10.5px'};text-align:center}th,.scores th,.traits th{background:#008c7a;color:#fff}.scores tr:nth-child(even),.traits tr:nth-child(even),tr:nth-child(even){background:#e6f7f4}.left{text-align:left!important;white-space:nowrap}.rot{height:96px;vertical-align:bottom}.rot span{writing-mode:vertical-rl;transform:rotate(180deg);white-space:nowrap;font-weight:700}.top{background:#fef9c3!important}.grade{font-weight:800;color:#16a34a}.traits{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:8px}.comments td:first-child{width:170px;font-weight:700}.sig,.re-sig{display:flex;justify-content:space-between;margin-top:28px;font-size:11px;text-align:center;align-items:flex-end;gap:20px}.sig div,.re-sig>div{width:210px}.re-sig-script{font-family:'Segoe Script','Lucida Handwriting',cursive;color:#0c4a6e;font-size:1.4rem;height:38px;display:flex;align-items:center;justify-content:center;padding-bottom:4px}.re-sig-line{border-top:1.5px solid #111;padding-top:6px;font-weight:700}.re-stamp-wrap{width:130px;height:130px;display:inline-block;position:relative;margin:0 auto}.re-stamp{width:100%;height:100%;opacity:.92;transform:rotate(-6deg);filter:drop-shadow(2px 4px 6px rgba(0,0,0,0.1))}.re-stamp image{mix-blend-mode:multiply;filter:contrast(1.3) brightness(1.1)}.re-rating{display:inline-block;padding:1px 8px;border-radius:8px;font-weight:800;background:#e0e7ff;color:#3730a3;min-width:24px;text-align:center}.re-rating-a{background:#dcfce7;color:#166a34}.re-rating-b{background:#dbeafe;color:#1e40af}.re-rating-c{background:#fef3c7;color:#92400e}.re-rating-d,.re-rating-e,.re-rating-f{background:#fee2e2;color:#991b1b}.stat{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:12px}.stat div{border:1px solid #c7d2fe;border-radius:10px;padding:8px;text-align:center;background:#eef2ff}.stat b{display:block;font-size:16px;color:#4f46e5}.note{margin-top:12px;font-size:9.5px;color:#94a3b8;text-align:center}.doc-signature{text-align:center;margin-top:18px;page-break-inside:avoid}@media print{body{background:#fff;padding:0}.sheet,.report-sheet{box-shadow:none}button{display:none!important}}</style>`; }

};
if (typeof sb !== 'undefined') ReportEngine.init(sb);
window.ReportEngine = ReportEngine;
