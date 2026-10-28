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
  scoreCell(row,field){ return row&&row._assessmentPresent&&!row._assessmentPresent[field]?'—':this.fmt(row?row[field]:null); },
  ordinal(n){ n=Number(n)||0; const s=['th','st','nd','rd'], v=n%100; return n+(s[(v-20)%10]||s[v]||s[0]); },
  fmtDMY(v){ if(!v)return ''; const d=new Date(String(v).length===10?String(v)+'T00:00:00':v); return isNaN(d)?String(v):String(d.getDate()).padStart(2,'0')+'/'+String(d.getMonth()+1).padStart(2,'0')+'/'+d.getFullYear(); },
  // Matches the published sample documents exactly.
  grade(score){ score=this.n(score); if(score>=80)return'A'; if(score>=70)return'B'; if(score>=60)return'C'; if(score>=50)return'D'; if(score>=40)return'E'; return'F'; },
  remark(score){ const g=this.grade(score); return {A:'Excellent',B:'Very Good',C:'Good',D:'Credit',E:'Pass',F:'Fail'}[g]||''; },



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

  /* Convert the canonical assessment_columns + report_scores model into the
     sample document's five score bands. This removes the old split-brain bug:
     staff entered a subject scoresheet successfully, but printable documents
     queried only `results` and showed blank/old figures. */
  async loadAssessmentRows(ctx, students, scope){
    const db=this.sb || (typeof sb!=='undefined'?sb:null); if(!db)return {rows:[],configured:false,columns:[]};
    try{
      let cq=db.from('assessment_columns').select('id,class,subject,term,session,name,max_mark,position,source').order('position').limit(1000);
      if(ctx.class)cq=cq.eq('class',ctx.class); if(ctx.term)cq=cq.eq('term',ctx.term); if(ctx.session)cq=cq.eq('session',ctx.session);
      const cr=await cq; if(cr.error || !(cr.data||[]).length)return {rows:[],configured:false,columns:[]};
      const allCols=cr.data||[],cols=ctx.subject?allCols.filter(c=>c.subject==='*'||String(c.subject||'')===String(ctx.subject)):allCols;if(!cols.length)return {rows:[],configured:false,columns:[]};const ids=cols.map(c=>c.id);
      let sq=db.from('report_scores').select('*').in('column_id',ids).limit(10000);
      if(ctx.class)sq=sq.eq('class',ctx.class); if(ctx.subject)sq=sq.eq('subject',ctx.subject); if(ctx.term)sq=sq.eq('term',ctx.term); if(ctx.session)sq=sq.eq('session',ctx.session);
      const sr=await sq; if(sr.error)return {rows:[],configured:true,columns:cols,error:sr.error};
      const allowed=(sr.data||[]).filter(r=>(!ctx.student||this._studentMatch(r,ctx.student))&&this.allowRowForScope(r,scope));
      const groups=new Map();
      allowed.forEach(r=>{
        const key=[r.student_id||'',r.student_id_ref||'',String(r.student_name||'').toLowerCase(),r.subject||''].join('|');
        if(!groups.has(key))groups.set(key,{student_id:r.student_id||'',student_id_ref:r.student_id_ref||'',student_name:r.student_name||'',class:r.class||ctx.class||'',subject:r.subject||'Subject',term:r.term||ctx.term||'',session:r.session||ctx.session||'',scores:new Map()});
        groups.get(key).scores.set(String(r.column_id),this.n(r.score));
      });
      const token=s=>String(s||'').toLowerCase().replace(/[^a-z0-9]+/g,'_');
      const assembled=[...groups.values()].map(g=>{
        // Prefer the modern global template; otherwise use this subject's legacy columns.
        const globals=cols.filter(c=>c.subject==='*' && (!c.class||c.class===g.class));
        const specific=cols.filter(c=>String(c.subject||'')===String(g.subject||''));
        const applicable=(globals.length?globals:specific).filter(c=>g.scores.has(String(c.id)) || globals.length);
        const out={student_id:g.student_id,student_id_ref:g.student_id_ref,student_name:g.student_name,class:g.class,subject:g.subject,term:g.term,session:g.session,project:null,ca1:null,ca2:null,cbt:null,paper:null,total:0,max:0,_assessmentMax:{project:0,ca1:0,ca2:0,cbt:0,paper:0},_assessmentValues:{},_assessmentPresent:{project:false,ca1:false,ca2:false,cbt:false,paper:false},_assessmentCells:[]};
        const used=new Set();
        applicable.forEach((c,index)=>{
          const hasScore=g.scores.has(String(c.id)), value=hasScore?this.n(g.scores.get(String(c.id))):null, max=this.n(c.max_mark)||0, t=token(c.name); let field='';
          if(/project|practical|assignment/.test(t))field='project';
          else if(/(^|_)ca_?1($|_)|first_ca|first_test|test_?1/.test(t))field='ca1';
          else if(/(^|_)ca_?2($|_)|second_ca|second_test|test_?2/.test(t))field='ca2';
          else if(/(^|_)ca_?3($|_)|third_ca|third_test|cbt|mid_?term/.test(t))field='cbt';
          else if(/exam|terminal|paper/.test(t))field='paper';
          else field=['ca1','ca2','cbt','project','paper'].find(x=>!used.has(x))||'project';
          used.add(field); out._assessmentMax[field]+=max; out._assessmentValues[c.name]=value;out._assessmentCells.push({id:c.id,name:c.name,max_mark:max,position:Number(c.position||index),value,present:hasScore,source:c.source||''});
          if(hasScore){out[field]=(out[field]==null?0:out[field])+value;out._assessmentPresent[field]=true;out.total+=value;out.max+=max;}
        });
        const st=(students||[]).find(s=>(s.id&&String(s.id)===String(g.student_id))||(s.admission_no&&s.admission_no===g.student_id_ref)||(s.full_name&&String(s.full_name).toLowerCase()===String(g.student_name).toLowerCase()));
        if(st){out.student_id=out.student_id||st.id;out.student_name=out.student_name||st.full_name;out.admission_no=st.admission_no||g.student_id_ref;out.gender=st.gender||'';out.photo_url=st.photo_url||'';}
        else out.admission_no=g.student_id_ref;
        return out;
      }).filter(r=>r.max>0);
      return {rows:assembled,configured:true,columns:cols};
    }catch(e){console.warn('Assessment-score adapter failed:',e);return {rows:[],configured:false,columns:[],error:e};}
  },

  /* V7.1 #7: admission-number-first student matching. Accepts "ADM — Name",
     a bare admission number, or a name; prefers the unique admission number. */
  _studentMatch(row, needle){
    needle=String(needle||'').trim(); if(!needle) return true;
    const adm=(needle.includes('—')?needle.split('—')[0]:needle).trim().toLowerCase();
    const name=(needle.includes('—')?needle.split('—').slice(1).join('—'):needle).trim().toLowerCase();
    const ref=String(row.student_id_ref||row.admission_no||'').toLowerCase();
    if(adm && ref && ref===adm) return true;
    return !!name && String(row.student_name||row.full_name||'').toLowerCase().includes(name);
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
    // Student name is resolved after joining the students list because many
    // legitimate legacy results contain student_id but a blank student_name.
    const { data: rows, error } = await q;
    if (error) throw new Error(error.message);
    // V5.2 data authority: raw CBT/reading/LMS attempts are NOT injected into
    // official reports. They appear only after an explicit push into report_scores.
    // This removes phantom scores and prevents a raw percentage from being counted
    // a second time alongside the pushed/scaled score.
    const familyFilter = (r) => this.allowRowForScope(r, scope);

    let sq = db.from('students').select('*').limit(8000);
    /* V7.6 #1 ROOT-CAUSE FIX (history access): load the WHOLE register, not
       just the current class roster. The roster gate below exists to hide
       DELETED students — but matching against a class-filtered list also
       killed every score row of students who had since been PROMOTED,
       moved class or GRADUATED, making previous-term records impossible to
       regenerate in the new term. Gate now checks the full register (any
       class, any status), so promotion/graduation never hides history;
       only genuinely deleted students stay excluded. */
    const { data: allStudents } = await sq;
    const students = klass
      ? (allStudents || []).filter(s => String(s.class || '').trim().toLowerCase() === klass.toLowerCase())
      : (allStudents || []);

    /* V7.2 #2: LIVE ROSTER GATE — any score row whose student no longer exists
       in the register is dropped at render time, so deleted students can never
       appear on report cards/broadsheets even on databases that predate the
       cleanup triggers. Matching is admission-number-first, then exact name.
       V7.6: matches the FULL register (see above) so history survives promotions. */
    const _liveRosterGate=(list)=>{
      const byId=new Set((allStudents||[]).map(x=>String(x.id)));
      const byAdm=new Set((allStudents||[]).map(x=>String(x.admission_no||'').toLowerCase()).filter(Boolean));
      const byName=new Set((allStudents||[]).map(x=>String(x.full_name||'').toLowerCase()).filter(Boolean));
      return (list||[]).filter(r=>{
        if(r.student_id&&byId.has(String(r.student_id)))return true;
        const ref=String(r.student_id_ref||'').toLowerCase();
        if(ref&&byAdm.has(ref))return true;
        const nm=String(r.student_name||'').toLowerCase();
        return !!nm&&byName.has(nm);
      });
    };
    const baseRows = (scope.family ? (rows || []).filter(r => familyFilter(r)) : (rows || []));
    let legacyNormalized=_liveRosterGate(baseRows).map(r=>this.normalizeResult(r,allStudents||[])).filter(r=>!studentText||String(r.student_name||'').toLowerCase().includes(studentText.toLowerCase()));
    const assessmentPack=await this.loadAssessmentRows({class:klass,subject,term,session,student:studentText},allStudents||[],scope);
    const assessmentNormalized=_liveRosterGate(assessmentPack.rows||[]).map(r=>this.normalizeResult(r,allStudents||[]));
    // Once assessment columns exist for this report context, report_scores is the
    // only official source. Legacy results is a fallback solely for old contexts
    // that have never been configured in Report Cards.
    const normalized=assessmentPack.configured?assessmentNormalized:legacyNormalized;
    return {ctx:{class:klass,subject,term,session,student:studentText},rows:normalized,students:students||[],school:this.school(),sourceMode:assessmentPack.configured?'report_scores':'legacy_results',assessmentColumns:assessmentPack.columns||[],feeBalances:await this.loadFeeBalances(students||[],term,session)};
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
    const ap=r._assessmentPresent||null;
    const project = ap ? (ap.project?this.n(r.project):null) : this.n(r.project ?? r.practical ?? r.assignment ?? r.ca_project ?? 0);
    const ca1 = ap ? (ap.ca1?this.n(r.ca1):null) : this.n(r.ca1 ?? r.ca_score ?? r.ca ?? 0);
    const ca2 = ap ? (ap.ca2?this.n(r.ca2):null) : this.n(r.ca2 ?? 0);
    const cbt = ap ? (ap.cbt?this.n(r.cbt):null) : this.n(r.ca3 ?? r.cbt ?? r.cbt_score ?? r.online_score ?? 0);
    const paper = ap ? (ap.paper?this.n(r.paper):null) : this.n(r.exam ?? r.exam_score ?? r.paper_exam ?? 0);
    const total = this.n(r.total ?? r.total_score ?? ([project,ca1,ca2,cbt,paper].reduce((a,v)=>a+this.n(v),0)));
    return {
      raw:r, student_id:r.student_id || (st&&st.id) || '', student_name:name || (st&&st.full_name) || 'Student',
      admission_no:r.admission_no || r.student_id_ref || (st&&st.admission_no) || '', class:r.class || (st&&st.class) || '',
      gender:r.gender || (st&&st.gender) || '', photo_url:r.photo_url || (st&&st.photo_url) || '',
      subject:r.subject || 'Subject', term:r.term || '', session:r.session || '',
      project, ca1, ca2, cbt, paper, total, max: this.n(r.max ?? r.max_score ?? r.obtainable ?? 100) || 100,
      _assessmentMax:r._assessmentMax||null,_assessmentValues:r._assessmentValues||null,_assessmentPresent:r._assessmentPresent||null,_assessmentCells:r._assessmentCells||null
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

  sealSvg(id='doc',office='EXAMINATIONS OFFICE'){
    const sc=this.school(),st=window.SC_SETTINGS||{},color=st.stamp_color||'#7f1d1d',safe=String(id).replace(/[^a-z0-9_-]/gi,'');
    if(st.stamp_enabled===false)return '<div style="height:90px"></div>';
    return `<div class="stamp-wrap re-stamp-wrap"><svg viewBox="0 0 120 120" xmlns="http://www.w3.org/2000/svg"><defs><path id="${safe}TopArc" d="M 16,60 A 44,44 0 0,1 104,60" fill="none"/><path id="${safe}BotArc" d="M 18,62 A 42,42 0 0,0 102,62" fill="none"/></defs><circle cx="60" cy="60" r="55" fill="none" stroke="${color}" stroke-width="3"/><circle cx="60" cy="60" r="48" fill="none" stroke="${color}" stroke-width="1.5"/><text font-family="Georgia,serif" font-size="8" letter-spacing="1.5" font-weight="800" fill="${color}"><textPath href="#${safe}TopArc" startOffset="50%" text-anchor="middle">★ ${this.esc(String(sc.name||'SCHOOL').toUpperCase())} ★</textPath></text><text font-family="Georgia,serif" font-size="5.5" font-style="italic" fill="${color}"><textPath href="#${safe}BotArc" startOffset="50%" text-anchor="middle">${this.esc(office)}</textPath></text><text x="60" y="54" font-family="Georgia,serif" font-size="13" font-weight="900" fill="${color}" text-anchor="middle">${this.esc((sc.shortName||'SC').toUpperCase())}</text><text x="60" y="66" font-family="Georgia,serif" font-size="5" fill="${color}" text-anchor="middle">— OFFICIAL SEAL —</text><line x1="35" y1="76" x2="85" y2="76" stroke="${color}" stroke-width="0.6"/><text x="60" y="86" font-family="Georgia,serif" font-size="5.2" font-weight="700" fill="${color}" text-anchor="middle">★ AUTHENTICATED ★</text></svg></div>`;
  },

  async loadPromotionStatus(studentId,studentName,term,session){
    const db=this.sb||(typeof sb!=='undefined'?sb:null);const pending={code:'not_decided',label:'PROMOTION NOT YET DECIDED',detail:'No approved promotion decision has been recorded.',color:'#92400e',background:'#fef3c7'};if(!db||(!studentId&&!studentName))return pending;
    /* V9.4 (#2): promotion is an END-OF-SESSION event. Nigerian schools decide
       promotion only after the THIRD term — first/second-term report cards must
       not carry any promotion strip at all (not even "pending"). Returning null
       tells the renderer to omit the section entirely. */
    if(term && !/third|3rd|\b3\b/i.test(String(term))) return null;
    try{
      /* V7.3 FIX (root cause of "PENDING — Recorded action: promote"):
         1. "✅ Apply promotions" stamps rows status='applied' — the OFFICIAL final
            state — but this reader only accepted approved/active/completed, so an
            APPLIED promotion still printed as PENDING. 'applied' is now accepted.
         2. The term+session filter was absolute; decisions saved without a term
            (or for the session only) were invisible. Now: try term+session →
            fall back to session-only → fall back to the student's latest decision. */
      const run=async(field,value,useTerm,useSession)=>{let q=db.from('promotions').select('*').eq(field,value);if(useTerm&&term)q=q.eq('term',term);if(useSession&&session)q=q.eq('session',session);return await q.order('created_at',{ascending:false}).limit(1);};
      const attempt=async(useTerm,useSession)=>{let r=studentId?await run('student_id',studentId,useTerm,useSession):{data:[]};if(!(r.data||[]).length&&studentName)r=await run('student_name',studentName,useTerm,useSession);return (r.data||[])[0];};
      let p=await attempt(true,true); if(!p)p=await attempt(false,true); if(!p)p=await attempt(false,false);
      if(!p)return pending;const action=String(p.action||'').toLowerCase(),status=String(p.status||'approved').toLowerCase(),to=p.to_class||'';
      if(!['approved','active','completed','applied'].includes(status))return {code:'pending',label:'PROMOTION DECISION PENDING',detail:'Recorded action: '+(action||'pending')+(to?' → '+to:'')+' — admin: click “✅ Apply promotions” on the Promotion page to finalise.',color:'#92400e',background:'#fef3c7'};
      if(action==='promote')return {code:'promoted',label:'PROMOTED'+(to?' TO '+String(to).toUpperCase():''),detail:'Approved promotion decision.',color:'#166534',background:'#dcfce7'};
      if(action==='graduate')return {code:'graduated',label:'GRADUATED',detail:to?('Graduated to '+to):'Approved graduation decision.',color:'#1e40af',background:'#dbeafe'};
      if(action==='repeat')return {code:'not_promoted',label:'NOT PROMOTED — REPEAT'+(to?' '+String(to).toUpperCase():''),detail:'Approved repeat decision.',color:'#991b1b',background:'#fee2e2'};
      return {code:'not_promoted',label:'NOT PROMOTED',detail:'Recorded decision: '+(action||'not promoted')+(to?' → '+to:''),color:'#991b1b',background:'#fee2e2'};
    }catch(e){console.warn('Promotion status load failed:',e);return pending;}
  },

  async loadStudentMetrics(studentId,studentName,className,term,session){const db=this.sb||(typeof sb!=='undefined'?sb:null);if(!db)return null;try{let q=db.from('student_term_metrics').select('*').eq('class',className||'').eq('term',term||'').eq('session',session||'');if(studentId)q=q.eq('student_id',studentId);else q=q.eq('student_name',studentName||'');const r=await q.order('measured_on',{ascending:false}).limit(1);return(r.data||[])[0]||null;}catch(_){return null;}},
  bmi(metric){const h=Number(metric&&metric.height_cm),w=Number(metric&&metric.weight_kg);return h>0&&w>0?Math.round(w/Math.pow(h/100,2)*10)/10:null;},

  async loadClassTeacherIdentity(className){
    const db=this.sb||(typeof sb!=='undefined'?sb:null);const fallback={name:'Class Teacher',signature_url:'',linked:false};if(!db||!className)return fallback;
    try{const r=await db.rpc('get_class_teacher_identity',{p_class:className});if(!r.error&&r.data)return Object.assign(fallback,r.data);}catch(_){}
    // Backward-compatible browser fallback for schemas awaiting the V5.3 RPC.
    try{const c=await db.from('classes').select('class_teacher').eq('name',className).maybeSingle(),name=c.data&&c.data.class_teacher;if(!name)return fallback;const st=await db.from('staff').select('full_name,user_id,signature_url').ilike('full_name',name).maybeSingle();let sig=st.data&&st.data.signature_url||'';if(st.data&&st.data.user_id){const pr=await db.from('profiles').select('full_name,signature_url').eq('id',st.data.user_id).maybeSingle();return{name:(pr.data&&pr.data.full_name)||st.data.full_name||name,signature_url:(pr.data&&pr.data.signature_url)||sig,linked:true};}return{name:(st.data&&st.data.full_name)||name,signature_url:sig,linked:false};}catch(_){return fallback;}
  },
  teacherSignatureInk(identity){const x=identity||{},url=x.signature_url?((window.Super&&Super.idcard&&Super.idcard.driveDirect)?Super.idcard.driveDirect(x.signature_url):x.signature_url):'';return url?'<img src="'+this.esc(url)+'" referrerpolicy="no-referrer" style="max-width:170px;max-height:54px;object-fit:contain;mix-blend-mode:multiply;filter:contrast(1.35) brightness(1.06)" onerror="this.style.display=\'none\'">':'<span style="color:#64748b;font-size:.75rem">Signature not uploaded</span>';},

  assessmentLayout(rows){const found=[];(rows||[]).forEach(r=>(r._assessmentCells||[]).forEach(c=>{const key=this.labelToken?this.labelToken(c.name):String(c.name||'').toLowerCase().replace(/[^a-z0-9]/g,'');if(!found.some(x=>x.key===key))found.push({...c,key});}));return found.sort((a,b)=>Number(a.position||0)-Number(b.position||0));},
  dynamicScoreCell(row,col){const key=col.key||(this.labelToken?this.labelToken(col.name):String(col.name||'').toLowerCase().replace(/[^a-z0-9]/g,'')),cell=(row._assessmentCells||[]).find(c=>(this.labelToken?this.labelToken(c.name):String(c.name||'').toLowerCase().replace(/[^a-z0-9]/g,''))===key);return cell&&cell.present?this.fmt(cell.value):'—';},

  async renderStudent(ctx){
    const data = await this.loadContext(ctx); const rows = data.rows;
    if (!rows.length) return this.empty('No result records found for this student/filter.');
    const name = ctx.student || rows[0].student_name;
    const studentRows = rows.filter(r => !ctx.student || this._studentMatch(r, ctx.student));
    const list = studentRows.length ? studentRows : rows;
    const first = list[0] || {}; const sc=data.school;
    const promotion=await this.loadPromotionStatus(first.student_id,first.student_name,ctx.term||first.term,ctx.session||first.session);
    const classTeacher=await this.loadClassTeacherIdentity(first.class||ctx.class);
    const metrics=await this.loadStudentMetrics(first.student_id,first.student_name,first.class||ctx.class,ctx.term||first.term,ctx.session||first.session),metricBMI=this.bmi(metrics);
    const total = list.reduce((a,b)=>a+this.n(b.total),0); const obtainable=list.reduce((a,b)=>a+this.n(b.max||100),0)||list.length*100;
    const avg = obtainable ? (total/obtainable*100) : 0;
    const bal = data.feeBalances[first.student_id] ?? data.feeBalances[String(first.student_name||'').toLowerCase()] ?? 0;
    const logo='assets/img/logo.'+sc.logoExt;
    const subjectClassAvg = (sub) => {
      const subRows = rows.filter(r => r.class === first.class && r.subject === sub);
      if (!subRows.length) return '—';
      const sum = subRows.reduce((acc, r) => acc + (this.n(r.max)?this.n(r.total)/this.n(r.max)*100:0), 0);
      return (sum / subRows.length).toFixed(1);
    };
    // Compute per-subject positions within the class
    const subjectPositions = {};
    const allSubjects = [...new Set(list.map(r => r.subject))];
    allSubjects.forEach(sub => {
      const subRows = rows.filter(r => r.subject === sub && r.class === first.class).sort((a,b) => (this.n(b.max)?this.n(b.total)/this.n(b.max):0) - (this.n(a.max)?this.n(a.total)/this.n(a.max):0));
      subRows.forEach((r, idx) => { subjectPositions[r.student_name + '|' + sub] = idx + 1; });
    });
    const layout=this.assessmentLayout(list);
    const legacyLayout=layout.length?layout:[{name:'CA1',max_mark:10,key:'ca1',legacy:'ca1'},{name:'CA2',max_mark:10,key:'ca2',legacy:'ca2'},{name:'CA3 / CBT',max_mark:10,key:'cbt',legacy:'cbt'},{name:'Project',max_mark:10,key:'project',legacy:'project'},{name:'Exam',max_mark:60,key:'paper',legacy:'paper'}];
    const scoreRows = list.map(r => {
      const subPos = subjectPositions[r.student_name + '|' + r.subject];
      const subPosStr = subPos ? this.ordinal(subPos) : '—';
      const subjectPct=this.n(r.max)?this.n(r.total)/this.n(r.max)*100:0;
      const cells=legacyLayout.map(c=>'<td>'+(layout.length?this.dynamicScoreCell(r,c):this.scoreCell(r,c.legacy))+'</td>').join('');
      return `<tr><td class="left">${this.esc(r.subject)}</td>${cells}<td><b>${this.fmt(r.total)} / ${this.fmt(r.max)}</b></td><td class="grade">${this.grade(subjectPct)}</td><td>${subPosStr}</td><td>${this.remark(subjectPct)}</td></tr>`;
    }).join('');
    const scoreHead=legacyLayout.map(c=>'<th>'+this.esc(c.name)+'<br>('+this.fmt(c.max_mark)+')</th>').join('');

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
    // Never invent ratings. Empty domains print “Not rated” until a teacher
    // explicitly saves traits for this learner/term/session.
    let affective = {};
    let psychomotor = {};
    try{
      const {data: aff} = await this.sb.from('affective_traits').select('*').eq('student_id', first.student_id).eq('term', first.term||'').eq('session', first.session||'').maybeSingle();
      if(aff) affective=Object.assign({},aff.ratings||{},aff.data||{});
    }catch(_){}
    try{
      const {data: ps} = await this.sb.from('psychomotor_traits').select('*').eq('student_id', first.student_id).eq('term', first.term||'').eq('session', first.session||'').maybeSingle();
      if(ps) psychomotor=Object.assign({},ps.ratings||{},ps.data||{});
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
    const affectiveRows = Object.keys(affective).length?Object.entries(affective).map(([k,v]) => `<tr><td class="left">${this.esc(k)}</td><td>${ratingCell(v)}</td></tr>`).join(''):'<tr><td colspan="2" style="color:#64748b">Not rated</td></tr>';
    const psychomotorRows = Object.keys(psychomotor).length?Object.entries(psychomotor).map(([k,v]) => `<tr><td class="left">${this.esc(k)}</td><td>${ratingCell(v)}</td></tr>`).join(''):'<tr><td colspan="2" style="color:#64748b">Not rated</td></tr>';

    // Attendance stores dates (not term/session columns). Resolve the academic
    // period first; the former query referenced non-existent columns and always
    // printed an em dash on otherwise complete report cards.
    let attendanceStr = '—';
    try{
      let aq=this.sb.from('attendance').select('date,status').eq('student_id',first.student_id).order('date');
      try{
        const pr=await this.sb.from('academic_periods').select('starts_on,ends_on').eq('term',first.term||ctx.term||'').eq('session',first.session||ctx.session||'').maybeSingle();
        if(pr.data&&pr.data.starts_on)aq=aq.gte('date',pr.data.starts_on); if(pr.data&&pr.data.ends_on)aq=aq.lte('date',pr.data.ends_on);
      }catch(_){}
      const {data:att}=await aq;
      if(att&&att.length){const present=att.filter(a=>['present','late'].includes(String(a.status).toLowerCase())).length;attendanceStr=`${present} / ${att.length} days`;}
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
    classTeacherComment = classTeacherComment || 'No class teacher comment entered.';
    principalComment = principalComment || 'No principal comment entered. Promotion decision is shown separately below.';

    // v5: Build school stamp SVG with embedded principal signature
    const settings=window.SC_SETTINGS||{};let sigUrl=settings.signature_url||localStorage.getItem('sc-signature-url')||sc.signatureUrl||sc.signature_url||'';if(window.SCSignature)sigUrl=SCSignature.direct(sigUrl);else if(window.Super&&Super.idcard)sigUrl=Super.idcard.driveDirect(sigUrl);const hasSig=!!sigUrl,removeSigBg=settings.principal_signature_bg_removed!==false;const principalName=(settings.principal_name||localStorage.getItem('sc-principal-name')||sc.principalName||'Principal').slice(0,40);
    const stampEnabled = settings.stamp_enabled !== false && sc.stamp_enabled !== false;
    const stampColor = settings.stamp_color || sc.stamp_color || '#1e3a8a';
    const stampText = settings.stamp_text || sc.stamp_text || 'OFFICIAL SCHOOL SEAL';

    const classLearnerAverages={};
    rows.filter(r=>r.class===first.class).forEach(r=>{const k=r.student_name;(classLearnerAverages[k]||(classLearnerAverages[k]={got:0,max:0}));classLearnerAverages[k].got+=this.n(r.total);classLearnerAverages[k].max+=this.n(r.max);});
    const classAvgValues=Object.values(classLearnerAverages).map(x=>x.max?x.got/x.max*100:0);
    const classAverage=classAvgValues.length?classAvgValues.reduce((a,b)=>a+b,0)/classAvgValues.length:0;

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
        `<image x="32" y="32" width="56" height="56" href="${sigUrl}" style="${removeSigBg?'mix-blend-mode:multiply;filter:contrast(1.4) brightness(1.05)':''}"/>` : 
        `<text x="60" y="65" text-anchor="middle" font-family="'Brush Script MT', cursive, sans-serif" font-style="italic" font-size="12" fill="${stampColor}">${this.esc(principalName)}</text>`
      }
      <text x="60" y="82" text-anchor="middle" font-family="Arial, sans-serif" font-size="5" font-weight="900" fill="${stampColor}">CERTIFIED</text>
      <text x="60" y="88" text-anchor="middle" font-family="Arial, sans-serif" font-size="4" font-weight="700" fill="${stampColor}">${new Date().toLocaleDateString()}</text>
    </svg>`;

    return `<div class="report-sheet sample-report"><div class="head"><img class="logo" src="${logo}" onerror="this.style.display='none'"><div class="school"><h1>${this.esc(sc.name)}</h1><p>📍 ${this.esc(sc.address)} · 📞 ${this.esc(sc.phone)} · ✉️ ${this.esc(sc.email)}</p><p style="font-style:italic;color:#7c2d12">Motto: ${this.esc(sc.motto)}</p></div><div class="photo">${first.photo_url ? `<img src="${this.esc(first.photo_url)}" onerror="this.parentNode.innerHTML='Photo'">` : 'Student<br>Photo'}</div></div><div class="title">TERMINAL REPORT SHEET — ${this.esc(ctx.term||first.term||'TERM')}, ${this.esc(ctx.session||first.session||'SESSION')}</div><table class="info"><tr><td><b>Name:</b> ${this.esc(first.student_name)}</td><td><b>Admission No:</b> ${this.esc(first.admission_no)}</td><td><b>Class:</b> ${this.esc(first.class)}</td></tr><tr><td><b>No. in Class:</b> ${classSize}</td><td><b>Attendance:</b> ${this.esc(attendanceStr)}</td><td><b>Position:</b> <b style="color:#16a34a">${classPosition}</b></td></tr></table><table class="scores" style="margin-top:8px"><thead><tr><th class="left">SUBJECT</th>${scoreHead}<th>TOTAL /<br>ACTIVE MAX</th><th>GRADE</th><th>POSITION</th><th>REMARK</th></tr></thead><tbody>${scoreRows}</tbody></table><table class="info" style="margin-top:8px"><tr><td><b>Total Score:</b> ${this.fmt(total)} / ${this.fmt(obtainable)}</td><td><b>Average:</b> ${this.fmt(avg,1)}%</td><td><b>Class Average:</b> ${this.fmt(classAverage,1)}%</td><td><b>Grade:</b> <span class="grade">${this.grade(avg)}</span></td></tr></table>${promotion?`<div class="promotion-status" style="margin-top:8px;padding:9px 12px;border:1.5px solid ${promotion.color};background:${promotion.background};color:${promotion.color};border-radius:8px;text-align:center"><b style="font-size:13px;letter-spacing:.7px">${this.esc(promotion.label)}</b><div style="font-size:9.5px;margin-top:2px">${this.esc(promotion.detail)}</div></div>`:''}
<table class="info" style="margin-top:6px;background:#fffbeb;border:1px solid #fcd34d"><tr><td><b>Previous School Fees Owed:</b> <span style="color:${bal>0?'#b91c1c':'#16a34a'};font-weight:900">${bal===0?'₦0 (FULLY PAID)':'₦'+Number(bal).toLocaleString()}</span></td><td><b>Next Term School Bill:</b> <span style="color:#b45309;font-weight:900">${nextTermBill.fees ? (nextTermBill.currency + Number(nextTermBill.fees).toLocaleString()) : '—'} </span> <small style="color:#92400e">(${this.esc(nextTermBill.note||'Payable before resumption')})</small></td><td><b>Next Term Begins:</b> ${this.esc(nextTermBill.begins ? this.fmtDMY(nextTermBill.begins) : (nextTermBegins||'—'))}</td></tr></table><table class="info" style="margin-top:6px"><tr><td><b>Height:</b> ${metrics&&metrics.height_cm!=null?this.fmt(metrics.height_cm)+' cm':'—'}</td><td><b>Weight:</b> ${metrics&&metrics.weight_kg!=null?this.fmt(metrics.weight_kg)+' kg':'—'}</td><td><b>BMI:</b> ${metricBMI!=null?this.fmt(metricBMI,1):'—'}</td><td><b>Blood pressure:</b> ${this.esc(metrics&&metrics.blood_pressure||'—')}</td></tr><tr><td><b>Vision:</b> ${this.esc(metrics&&metrics.vision||'—')}</td><td><b>Blood group:</b> ${this.esc(metrics&&metrics.blood_group||'—')}</td><td><b>Genotype:</b> ${this.esc(metrics&&metrics.genotype||'—')}</td><td><b>Measured:</b> ${this.esc(metrics&&metrics.measured_on?this.fmtDMY(metrics.measured_on):'—')}</td></tr></table><div class="traits re-traits"><div><table><tr><th colspan="2">⭐ AFFECTIVE DOMAIN</th></tr>${affectiveRows}</table></div><div><table><tr><th colspan="2">🏃 PSYCHOMOTOR DOMAIN</th></tr>${psychomotorRows}</table></div></div><table class="comments" style="margin-top:10px"><tr><td>Class Teacher's Comment</td><td>${this.esc(classTeacherComment)}</td></tr><tr><td>Principal's Comment</td><td>${this.esc(principalComment)}</td></tr><tr><td>Next Term Begins</td><td>${this.esc(nextTermBegins || sc.next_term_begins || 'See school calendar')} &nbsp;·&nbsp; <b>Fees Balance:</b> ${bal===0?'₦0 (FULLY PAID)':'₦'+Number(bal).toLocaleString()}</td></tr></table><div class="sig re-sig"><div><div class="re-sig-script">${this.teacherSignatureInk(classTeacher)}</div><div class="re-sig-line">${this.esc(classTeacher.name||'Class Teacher')}<br><small>Class Teacher's Signature</small></div></div><div style="position:relative">${stampEnabled?'<div class="re-stamp-wrap">'+stampSvg+'</div>':(hasSig?'<img src="'+this.esc(sigUrl)+'" style="max-width:160px;max-height:65px;object-fit:contain;'+(removeSigBg?'mix-blend-mode:multiply;filter:contrast(1.35)':'')+'">':'')}<div class="re-sig-line" style="margin-top:6px">${this.esc(principalName)}<br><small>Principal\'s Signature${stampEnabled?' &amp; Official Stamp':''}</small></div></div></div><p class="note">This is an official computer-generated report sheet. It carries the school stamp with embedded verification code and is valid without physical seal. Verify at the school portal.</p></div>`;
  },

  async renderSubject(ctx){
    const data=await this.loadContext(ctx); const rows=data.rows; if(!rows.length)return this.empty('No subject score records found.');
    const sc=data.school; const pct=r=>this.n(r.max)?this.n(r.total)/this.n(r.max)*100:0;
    const sorted=rows.slice().sort((a,b)=>pct(b)-pct(a));
    const avg=sorted.length?sorted.reduce((a,b)=>a+pct(b),0)/sorted.length:0;
    const highest=sorted.length?pct(sorted[0]):0,lowest=sorted.length?pct(sorted[sorted.length-1]):0,passRate=sorted.length?sorted.filter(r=>pct(r)>=50).length/sorted.length*100:0;
    let teacher=''; try{const tr=await this.sb.from('subjects').select('teacher').eq('name',ctx.subject||rows[0].subject).maybeSingle();teacher=(tr.data&&tr.data.teacher)||'';}catch(_){}
    const layout=this.assessmentLayout(sorted),legacy=layout.length?layout:[{name:'CA1',max_mark:10,key:'ca1',legacy:'ca1'},{name:'CA2',max_mark:10,key:'ca2',legacy:'ca2'},{name:'CA3 / CBT',max_mark:10,key:'cbt',legacy:'cbt'},{name:'Project',max_mark:10,key:'project',legacy:'project'},{name:'Exam',max_mark:60,key:'paper',legacy:'paper'}],head=legacy.map(c=>'<th>'+this.esc(c.name)+' ('+this.fmt(c.max_mark)+')</th>').join('');
    const body=sorted.map((r,i)=>`<tr${i===0?' class="top"':''}><td>${i+1}</td><td class="left">${this.esc(r.student_name)}</td><td>${this.esc(r.admission_no)}</td>${legacy.map(c=>'<td>'+(layout.length?this.dynamicScoreCell(r,c):this.scoreCell(r,c.legacy))+'</td>').join('')}<td><b>${this.fmt(r.total)} / ${this.fmt(r.max)}</b></td><td class="grade ${this.grade(pct(r))}">${this.grade(pct(r))}</td><td>${this.ordinal(i+1)}</td><td>${this.remark(pct(r))}</td></tr>`).join('');
    return `<div class="sheet subject-sheet"><h1>${this.esc(sc.name)} — SUBJECT BROADSHEET</h1><p class="meta">SUBJECT: ${this.esc(ctx.subject||rows[0].subject)} · CLASS: ${this.esc(ctx.class||rows[0].class||'')} · ${this.esc(ctx.term||rows[0].term||'TERM')}, ${this.esc(ctx.session||rows[0].session||'SESSION')} · Subject Teacher: ${this.esc(teacher||'—')} · ${sorted.length} students</p><table><thead><tr><th>S/N</th><th class="left">FULL NAME</th><th>ADM NO.</th>${head}<th>TOTAL / ACTIVE MAX</th><th>GRADE</th><th>POS</th><th>REMARK</th></tr></thead><tbody>${body}</tbody></table><div class="stat"><div><b>${this.fmt(avg,1)}%</b>Subject Average</div><div><b>${this.fmt(highest,1)}</b>Highest Score</div><div><b>${this.fmt(lowest,1)}</b>Lowest Score</div><div><b>${this.fmt(passRate,1)}%</b>Pass Rate (≥50)</div></div><div class="grading-scale"><b>Grading scale:</b> A (80–100) Excellent · B (70–79) Very Good · C (60–69) Good · D (50–59) Credit · E (40–49) Pass · F (0–39) Fail</div><div class="sig"><div><div class="sig-script">${this.signatureInk('teacher')}</div><div class="sig-line">Subject Teacher's Signature</div></div><div>${this.sealSvg('subjectSeal','EXAMINATIONS OFFICE')}<div class="sig-line">Head of Department's Signature &amp; Stamp</div></div></div><p class="note">Official per-subject scoresheet. Automatic totals, grades, positions and subject statistics. Licensed Platform · HMG Technologies.</p></div>`;
  },

  async renderClass(ctx){
    const data=await this.loadContext(ctx); const rows=data.rows; if(!rows.length)return this.empty('No class score records found.');
    const sc=data.school; const subjects=this.subjects(rows); const students=this.studentsFromRows(rows);const classTeacher=await this.loadClassTeacherIdentity(ctx.class||rows[0].class);
    const aggregates=students.map(st=>{const sr=rows.filter(r=>r.student_name===st),total=sr.reduce((a,b)=>a+this.n(b.total),0),max=sr.reduce((a,b)=>a+this.n(b.max),0)||subjects.length*100,avg=max?total/max*100:0;return{st,sr,total,max,avg};}).sort((a,b)=>b.avg-a.avg);
    const classAvg=aggregates.reduce((a,b)=>a+b.avg,0)/(aggregates.length||1);
    const body=aggregates.map((x,i)=>`<tr${i===0?' class="top"':''}><td>${i+1}</td><td class="left"><b>${this.esc(x.st)}</b></td><td>${this.esc((x.sr[0]||{}).admission_no||'')}</td>${subjects.map(s=>{const r=x.sr.find(y=>y.subject===s);return '<td>'+(r?this.fmt(this.n(r.max)?this.n(r.total)/this.n(r.max)*100:r.total):'-')+'</td>';}).join('')}<td><b>${this.fmt(x.total)}</b></td><td>${this.fmt(x.avg,1)}</td><td>${this.ordinal(i+1)}</td><td>${this.grade(x.avg)}</td><td>${this.remark(x.avg)}</td></tr>`).join('');
    return `<div class="sheet class-sheet"><h1>${this.esc(sc.name)} — CLASS BROADSHEET</h1><p class="meta">${this.esc(ctx.term||rows[0].term||'TERM')} · ${this.esc(ctx.session||rows[0].session||'SESSION')} · CLASS: ${this.esc(ctx.class||rows[0].class||'')} · ${students.length} students · Class Average: ${this.fmt(classAvg,1)}% · Max obtainable per subject: 100</p><table><thead><tr><th>S/N</th><th class="left">FULL NAME</th><th>ADM NO.</th>${subjects.map(s=>'<th class="rot"><span>'+this.esc(s)+'</span></th>').join('')}<th>TOTAL</th><th>AVG %</th><th>POS</th><th>GRADE</th><th>REMARK</th></tr></thead><tbody>${body}</tbody></table><div class="grading-scale"><b>Grading scale:</b> A (80–100) Excellent · B (70–79) Very Good · C (60–69) Good · D (50–59) Credit · E (40–49) Pass · F (0–39) Fail</div><div class="sig"><div><div class="sig-script">${this.teacherSignatureInk(classTeacher)}</div><div class="sig-line">${this.esc(classTeacher.name||'Class Teacher')}<br><small>Class Teacher's Signature</small></div></div><div>${this.sealSvg('classSeal','EXAMINATIONS OFFICE')}<div class="sig-line">Principal's Signature &amp; Stamp</div></div></div><p class="note">Official class broadsheet. One row per student, one column per subject, automatic totals, averages, positions and grades. Landscape A4. Licensed Platform · HMG Technologies.</p></div>`;
  },

  empty(msg){ return `<div class="card"><h3>No output generated</h3><p>${this.esc(msg)}</p></div>`; },

  signatureInk(kind){
    const sc=window.SCHOOL||{},st=window.SC_SETTINGS||{},isTeacher=kind==='teacher';let url='',name='';
    try{url=localStorage.getItem(isTeacher?'sc-class-teacher-signature-url':'sc-signature-url')||'';name=localStorage.getItem(isTeacher?'sc-class-teacher-name':'sc-principal-name')||'';}catch(_){}
    url=url||st[isTeacher?'class_teacher_signature_url':'signature_url']||sc[isTeacher?'classTeacherSignature':'signatureUrl']||'';
    name=name||st[isTeacher?'class_teacher_name':'principal_name']||sc[isTeacher?'classTeacherName':'principalName']||(isTeacher?'Class Teacher':'Principal');
    if(url){const direct=(window.Super&&Super.idcard&&Super.idcard.driveDirect)?Super.idcard.driveDirect(url):url;return '<img src="'+this.esc(direct)+'" referrerpolicy="no-referrer" style="max-width:170px;max-height:54px;object-fit:contain;mix-blend-mode:multiply;filter:contrast(1.35) brightness(1.06)" onerror="this.style.display=\'none\'">';}
    return '<span style="font-family:\'Segoe Script\',cursive;color:#1e2a5e;font-size:1.15rem">'+this.esc(name)+'</span>';
  },

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


  // V5.2 canonical CBT → report_scores bulk pipeline. Raw CBT attempts never
  // enter a report until an authorised user explicitly previews and pushes them.
  _bulkCBT:{exams:[],columns:[],counts:{},filtered:[]},
  labelToken(v){return String(v||'').trim().toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/^_|_$/g,'');},
  unique(values){return [...new Set((values||[]).map(v=>String(v||'').trim()).filter(Boolean))].sort();},
  selectOptions(values,label){return '<option value="">'+this.esc(label||'All')+'</option>'+this.unique(values).map(v=>'<option value="'+this.esc(v)+'">'+this.esc(v)+'</option>').join('');},

  async openBulkCBTExportModal(){
    const db=this.sb||(typeof sb!=='undefined'?sb:null);if(!db){toast('Database not configured','warning');return;}
    const [er,cr]=await Promise.all([
      db.from('cbt_exams').select('id,code,title,subject,class,term,session,report_column,max_score,is_open,exam_mode,anti_cheat_config,created_at').order('created_at',{ascending:false}).limit(500),
      db.from('assessment_columns').select('id,class,subject,term,session,name,max_mark,position,source').order('position').limit(2000)
    ]);
    if(er.error){toast('Could not load CBT exams: '+er.error.message,'danger');return;}
    const exams=er.data||[];if(!exams.length){toast('No CBT exams found.','warning');return;}
    let counts={};try{const rr=await db.from('cbt_results').select('exam_id').in('exam_id',exams.map(e=>e.id)).limit(20000);(rr.data||[]).forEach(r=>counts[r.exam_id]=(counts[r.exam_id]||0)+1);}catch(_){}
    this._bulkCBT={exams,columns:cr.data||[],counts,filtered:[]};
    const columnNames=this.unique((cr.data||[]).filter(c=>c.subject==='*').map(c=>c.name));
    const body=`<div class="notice" style="background:#eff6ff;border-color:#93c5fd;color:#1e3a8a"><b>Bulk workflow — three clear steps</b><ol style="margin:6px 0 0;padding-left:20px"><li>Filter by class, subject, term and session.</li><li>Review the matching exams/results and select what to push.</li><li>Use each exam's destination or override it, then push once.</li></ol><p style="margin:8px 0 0"><b>🎯 Multi-subject CBT exams route automatically:</b> each candidate's per-subject scores are split and written to the matching <b>subject line</b> of their report card (English → English, Mathematics → Mathematics, …) in the destination column — no re-typing, no manual splitting, and re-pushing updates the same rows instead of duplicating.</p></div>
      <div class="grid grid-2">
       <div class="form-group"><label>Class filter</label><select id="be-class" class="form-select" onchange="ReportEngine.refreshCBTBulkPreview()">${this.selectOptions(exams.map(e=>e.class),'All classes')}</select></div>
       <div class="form-group"><label>Subject filter</label><select id="be-subject" class="form-select" onchange="ReportEngine.refreshCBTBulkPreview()">${this.selectOptions(exams.flatMap(e=>{const a=e.anti_cheat_config&&e.anti_cheat_config.subjects;return Array.isArray(a)?a:[e.subject]}),'All subjects')}</select></div>
       <div class="form-group"><label>Term filter</label><select id="be-term" class="form-select" onchange="ReportEngine.refreshCBTBulkPreview()">${this.selectOptions(exams.map(e=>e.term),'All terms')}</select></div>
       <div class="form-group"><label>Session filter</label><select id="be-session" class="form-select" onchange="ReportEngine.refreshCBTBulkPreview()">${this.selectOptions(exams.map(e=>e.session),'All sessions')}</select></div>
      </div>
      <div class="card" style="background:#f8fafc;margin:10px 0"><h4 style="margin-top:0">Destination rule</h4>
       <select id="be-destination" class="form-select" onchange="ReportEngine.refreshCBTBulkPreview()"><option value="__exam__">Use each exam's configured Report column (recommended)</option>${columnNames.map(n=>'<option value="'+this.esc(n)+'">Override every selected exam → '+this.esc(n)+'</option>').join('')}</select>
       <div class="grid grid-2" style="margin-top:8px"><label><input type="checkbox" id="be-create" checked onchange="ReportEngine.refreshCBTBulkPreview()"> Create a missing global destination column automatically</label><label>Maximum mark for an auto-created column <input id="be-max" class="form-input" type="number" min="1" step="0.5" value="10" style="max-width:100px;display:inline-block"></label></div>
       <label style="display:block;margin-top:8px"><input type="checkbox" id="be-verified" checked onchange="ReportEngine.refreshCBTBulkPreview()"> Push only V5.1 server-verified/regraded results (recommended)</label>
      </div><div id="be-preview"><span class="pulse">Preparing preview…</span></div>`;
    openModal('🚀 Bulk Push CBT Scores → Official Report Cards',body,'<button class="btn btn-outline" onclick="closeModal()">Cancel</button><button class="btn btn-primary" onclick="ReportEngine.executeBulkCBTPush()">Push selected exams now</button>');
    await this.refreshCBTBulkPreview();
  },
  openCBTExportModal(){return this.openBulkCBTExportModal();},

  async refreshCBTBulkPreview(){
    const host=document.getElementById('be-preview');if(!host)return;const val=id=>(document.getElementById(id)||{}).value||'';
    const cls=val('be-class'),sub=val('be-subject'),term=val('be-term'),sess=val('be-session'),dest=val('be-destination')||'__exam__';
    const filtered=(this._bulkCBT.exams||[]).filter(e=>(!cls||e.class===cls)&&(!term||e.term===term)&&(!sess||e.session===sess)&&(!sub||(String(e.subject||'').toLowerCase().includes(sub.toLowerCase())||(Array.isArray(e.anti_cheat_config&&e.anti_cheat_config.subjects)&&(e.anti_cheat_config.subjects||[]).some(x=>String(x).toLowerCase()===sub.toLowerCase())))));
    this._bulkCBT.filtered=filtered;
    const rows=filtered.map(e=>{const target=dest==='__exam__'?(e.report_column||'CBT / Online Exam'):dest;const col=(this._bulkCBT.columns||[]).find(c=>c.subject==='*'&&c.class===e.class&&c.term===e.term&&c.session===e.session&&this.labelToken(c.name)===this.labelToken(target));const count=this._bulkCBT.counts[e.id]||0;return '<tr><td><input class="be-exam" type="checkbox" value="'+this.esc(e.id)+'" '+(count?'checked':'disabled')+'></td><td><b>'+this.esc(e.code||'')+'</b><br><small>'+this.esc(e.title||'')+'</small></td><td>'+this.esc(e.class||'—')+'</td><td>'+this.esc(e.subject||'—')+'</td><td>'+this.esc(e.term||'—')+'<br>'+this.esc(e.session||'—')+'</td><td><b>'+count+'</b></td><td>'+this.esc(target)+(col?'<br><span style="color:#166534">Ready · max '+Number(col.max_mark||0)+'</span>':'<br><span style="color:#b45309">Missing — '+(document.getElementById('be-create')?.checked?'will be created':'enable auto-create')+'</span>')+'</td></tr>';}).join('');
    host.innerHTML='<div style="display:flex;justify-content:space-between;align-items:center;margin:8px 0"><b>'+filtered.length+' exam(s) match · '+filtered.reduce((a,e)=>a+(this._bulkCBT.counts[e.id]||0),0)+' result row(s)</b><label><input type="checkbox" checked onchange="document.querySelectorAll(\'.be-exam:not(:disabled)\').forEach(x=>x.checked=this.checked)"> Select all</label></div><div class="table-wrap"><table><thead><tr><th>Push</th><th>Exam</th><th>Class</th><th>Subject(s)</th><th>Term / Session</th><th>Results</th><th>Destination</th></tr></thead><tbody>'+(rows||'<tr><td colspan="7">No exams match these filters.</td></tr>')+'</tbody></table></div><p style="font-size:.8rem;color:#64748b">Scores are scaled from each verified percentage to the destination column maximum. Re-running is safe: the same learner/subject/destination row is updated, not duplicated.</p>';
  },

  async ensureCBTDestination(exam,name,maxMark,autoCreate){
    const same=c=>(c.subject==='*'&&c.class===(exam.class||'')&&c.term===(exam.term||'')&&c.session===(exam.session||'')&&this.labelToken(c.name)===this.labelToken(name));let col=(this._bulkCBT.columns||[]).find(same);if(col)return col;
    if(!autoCreate)throw new Error('Missing report column "'+name+'" for '+(exam.class||'class')+' · '+(exam.term||'term')+' · '+(exam.session||'session'));
    const peers=(this._bulkCBT.columns||[]).filter(c=>c.class===(exam.class||'')&&c.term===(exam.term||'')&&c.session===(exam.session||''));const payload={class:exam.class||'',subject:'*',term:exam.term||'',session:exam.session||'',name,max_mark:Number(maxMark)||10,weight:1,position:peers.length,source:'cbt',cbt_assessment_type:exam.assessment_type||'exam',created_by:(window.SC_PROFILE&&SC_PROFILE.id)||null};
    const res=await this.sb.from('assessment_columns').insert(payload).select().maybeSingle();if(res.error){const again=await this.sb.from('assessment_columns').select('*').eq('class',payload.class).eq('subject','*').eq('term',payload.term).eq('session',payload.session);col=(again.data||[]).find(same);if(!col)throw new Error(res.error.message);}else col=res.data;this._bulkCBT.columns.push(col);return col;
  },

  async pushOneCBTExam(exam,targetName,opts){
    const rr=await this.sb.from('cbt_results').select('*').eq('exam_id',exam.id).limit(10000);if(rr.error)throw new Error(rr.error.message);const verifiedOnly=!!opts.verifiedOnly;let skippedLegacy=0,skippedManual=0;const rows=[];
    for(const r of (rr.data||[])){
      if(verifiedOnly&&!String(r.engine_version||'').startsWith('v5.1')){skippedLegacy++;continue;}if(String(r.grading_status||'graded')!=='graded'){skippedManual++;continue;}
      let parts=[];const breakdown=r.subject_scores&&typeof r.subject_scores==='object'?r.subject_scores:{};const names=Object.keys(breakdown);
      if(names.length){parts=names.map(subject=>{const x=breakdown[subject]||{},pct=Number(x.total)>0?Number(x.score||0)/Number(x.total)*100:0;return{subject,pct};});}
      else {if(String(exam.subject||'').toUpperCase().startsWith('MULTI-SUBJECT')){skippedManual++;continue;}const pct=r.percent!=null?Number(r.percent):(Number(r.total)>0?Number(r.score||0)/Number(r.total)*100:0);parts=[{subject:exam.subject||'CBT',pct}];}
      for(const part of parts){if(opts.subjectFilter&&String(part.subject).toLowerCase()!==String(opts.subjectFilter).toLowerCase())continue;rows.push({column_id:opts.column.id,student_id:r.student_id||null,student_id_ref:r.student_id_ref||'',student_name:r.student_name||'Student',class:exam.class||r.student_class||'',subject:part.subject,term:exam.term||'',session:exam.session||'',score:Math.round((part.pct/100)*Number(opts.column.max_mark||10)*100)/100,source:'cbt:'+r.id,updated_by:(window.SC_PROFILE&&SC_PROFILE.id)||null,updated_at:new Date().toISOString()});}
    }
    let saved=0;for(let i=0;i<rows.length;i+=400){const chunk=rows.slice(i,i+400),res=await this.sb.from('report_scores').upsert(chunk,{onConflict:'column_id,student_id_ref,student_name,class,subject,term,session'});if(res.error)throw new Error(res.error.message);saved+=chunk.length;}
    return{saved,skippedLegacy,skippedManual,totalResults:(rr.data||[]).length};
  },

  async executeBulkCBTPush(){
    const ids=[...document.querySelectorAll('.be-exam:checked')].map(x=>x.value);if(!ids.length){toast('Select at least one exam that has results.','warning');return;}const dest=(document.getElementById('be-destination')||{}).value||'__exam__',auto=!!document.getElementById('be-create')?.checked,maxMark=Number(document.getElementById('be-max')?.value)||10,verifiedOnly=!!document.getElementById('be-verified')?.checked,subjectFilter=(document.getElementById('be-subject')||{}).value||'';let saved=0,legacy=0,manual=0,failed=[];
    for(const id of ids){const exam=(this._bulkCBT.exams||[]).find(e=>e.id===id);if(!exam)continue;const target=dest==='__exam__'?(exam.report_column||'CBT / Online Exam'):dest;try{const column=await this.ensureCBTDestination(exam,target,maxMark,auto),out=await this.pushOneCBTExam(exam,target,{column,verifiedOnly,subjectFilter});saved+=out.saved;legacy+=out.skippedLegacy;manual+=out.skippedManual;}catch(e){failed.push((exam.code||exam.title)+': '+(e.message||e));}}
    if(window.App&&App.logActivity)App.logActivity('bulk-push-cbt','report_scores',saved+' report score rows from '+ids.length+' exams');closeModal();openModal('✅ Bulk CBT push complete','<div class="stats-grid"><div class="stat-card"><div class="stat-value">'+saved+'</div><div class="stat-label">Report score rows saved/updated</div></div><div class="stat-card"><div class="stat-value">'+ids.length+'</div><div class="stat-label">Exams processed</div></div><div class="stat-card"><div class="stat-value">'+legacy+'</div><div class="stat-label">Legacy rows skipped</div></div><div class="stat-card"><div class="stat-value">'+manual+'</div><div class="stat-label">Manual/multi rows skipped</div></div></div>'+(failed.length?'<div class="notice notice-error"><b>Needs attention:</b><br>'+failed.map(this.esc).join('<br>')+'</div>':'<div class="notice" style="background:#f0fdf4;border-color:#86efac;color:#166534">Official `report_scores` is now updated. Open Report Cards and generate the student/class output.</div>'),'<button class="btn btn-primary" onclick="closeModal();location.href=\'report-cards.html\'">Open Report Cards</button>');
  },

  async pushCBTToResults(examId,column,term,session){
    // Compatibility entry point: one exam now uses the same canonical pipeline.
    const er=await this.sb.from('cbt_exams').select('*').eq('id',examId).maybeSingle();if(er.error||!er.data){toast('Exam not found','danger');return;}this._bulkCBT.columns=(await this.sb.from('assessment_columns').select('*').limit(2000)).data||[];const exam=Object.assign({},er.data,{term:term||er.data.term,session:session||er.data.session});try{const target=column||exam.report_column||'CBT / Online Exam',col=await this.ensureCBTDestination(exam,target,Number(exam.max_score)||10,true),out=await this.pushOneCBTExam(exam,target,{column:col,verifiedOnly:true,subjectFilter:''});toast('✅ '+out.saved+' CBT score row(s) pushed into official report scores.','success',9000);}catch(e){toast('Push failed: '+e.message,'danger',10000);}
  },
  doCBTExport(){return this.executeBulkCBTPush();},

  /* V6.2 BULK CLASS PRINTING (admin/staff): renders EVERY student's full report
     card for a class/term/session in one print job — one card per A4 page.
     Uses the same renderStudent() pipeline as single cards, so bulk output is
     pixel-identical to individual cards (photos, traits, comments, promotion,
     signatures, stamp). onProgress(done,total,name) keeps the admin informed. */
  async listClassStudents(ctx){
    const data=await this.loadContext({class:ctx.class,term:ctx.term,session:ctx.session});
    /* V7.1 #7: identify each learner by ADMISSION NUMBER when present —
       "ADM — Name" tokens keep same-named students separate in bulk printing. */
    const seen=new Map();
    (data.rows||[]).forEach(r=>{
      if(!r.student_name) return;
      const key=(r.student_id_ref?String(r.student_id_ref):'')+'|'+String(r.student_name).toLowerCase();
      if(!seen.has(key)) seen.set(key, r.student_id_ref ? (r.student_id_ref+' — '+r.student_name) : r.student_name);
    });
    return [...seen.values()].sort((a,b)=>String(a).localeCompare(String(b)));
  },
  async renderClassBulk(ctx,onProgress){
    const names=ctx.students&&ctx.students.length?ctx.students:await this.listClassStudents(ctx);
    if(!names.length)throw new Error('No result records found for '+(ctx.class||'this class')+' in the selected term/session. Enter scores first (Results page or the score grid above).');
    const pages=[];let done=0;
    for(const n of names){
      try{
        const html=await this.renderStudent({student:n,class:ctx.class,term:ctx.term,session:ctx.session});
        pages.push('<div class="rc-bulk-page">'+html+'</div>');
      }catch(e){pages.push('<div class="rc-bulk-page"><p style="color:#b91c1c;padding:30px">Could not build the card for '+this.esc(n)+': '+this.esc(e.message||e)+'</p></div>');}
      done++;if(typeof onProgress==='function')try{onProgress(done,names.length,n);}catch(_){}
    }
    return{html:pages.join('\n'),count:names.length,names};
  },
  /* V6.3 FIX #7: real report-column picker. Loads the ADMIN-CREATED assessment
     columns (deduplicated by heading) plus registered terms/sessions, so any
     "push to report card" modal (e.g. punctuality points) offers exactly the
     columns the admin designed — never a hard-coded ca1/ca2/ca3/exam list. */
  async reportPickerOptions(){
    const db=this.sb||(typeof sb!=='undefined'?sb:null);
    if(!db)return{columns:[],terms:[],sessions:[]};
    const out={columns:[],terms:[],sessions:[]};
    try{
      const cr=await db.from('assessment_columns').select('id,name,max_mark,class,term,session').order('position');
      const seen=new Set();
      (cr.data||[]).forEach(c=>{const k=String(c.name||'').trim().toLowerCase();if(!k||seen.has(k))return;seen.add(k);out.columns.push({id:c.id,name:c.name,max_mark:c.max_mark});});
    }catch(_){/* table may be empty on fresh installs */}
    try{
      const lr=await db.from('lookups').select('kind,value').in('kind',['term','session']).order('position');
      (lr.data||[]).forEach(l=>{if(l.kind==='term'&&!out.terms.includes(l.value))out.terms.push(l.value);if(l.kind==='session'&&!out.sessions.includes(l.value))out.sessions.push(l.value);});
    }catch(_){}
    return out;
  },
  print(title, html, landscape=false){
    const w=window.open('','_blank'); if(!w){ if(typeof toast==='function')toast('Popup blocked. Please allow popups.','warning'); return; }
    const sig = this.signatureBlock();
    const st=window.SC_SETTINGS||{}, color=st.stamp_color||'#1e3a8a', label=this.esc((st.stamp_text||'OFFICIAL SCHOOL SEAL').toUpperCase());
    const embedded=/(re-sig|re-stamp-wrap|stamp-wrap)/.test(String(html||''));
    const stamp=embedded||st.stamp_enabled===false?'':'<div style="margin:20px auto;text-align:center"><div style="display:inline-flex;width:112px;height:112px;border:3px double '+color+';border-radius:50%;align-items:center;justify-content:center;color:'+color+';font:900 10px Arial;text-align:center;padding:16px;transform:rotate(-6deg)">'+label+'</div><div style="font-size:10px;font-weight:700">Official School Stamp</div></div>';
    const signature=embedded?'':sig;
    w.document.open(); w.document.write(`<!DOCTYPE html><html><head><title>${this.esc(title)}</title><base href="${document.baseURI.replace(/[^/]*$/,'')}">${this.printCSS(landscape)}</head><body>${html}${stamp}${signature}<script>window.onload=function(){var imgs=[].slice.call(document.images),left=imgs.length,done=function(){if(--left<=0)setTimeout(function(){window.print()},250)};if(!left)return setTimeout(function(){window.print()},250);imgs.forEach(function(i){if(i.complete)done();else{i.onload=done;i.onerror=done}});setTimeout(function(){window.print()},2500)};<\/script></body></html>`); w.document.close(); w.focus();
  },
  printCSS(landscape=false){ return `<style>
    @page{size:A4 ${landscape?'landscape':'portrait'};margin:${landscape?'8mm':'10mm'}}*{box-sizing:border-box}body{font-family:Arial,sans-serif;color:#111;background:#fff;margin:0;padding:16px}.sheet,.report-sheet{background:#fff;padding:${landscape?'20px':'24px'};max-width:${landscape?'1100px':'760px'};margin:0 auto}.head{display:flex;align-items:center;gap:12px;border-bottom:3px solid #111;padding-bottom:8px}.logo{width:58px;height:58px;border-radius:12px;object-fit:contain}.school{flex:1;text-align:center}.school h1,h1{font-family:Georgia,serif;color:#008c7a;text-align:center;margin:0;font-size:${landscape?'22px':'21px'}}.school p{margin:2px 0;font-size:11px;color:#334155}.photo{width:82px;height:92px;border:1px dashed #94a3b8;display:flex;align-items:center;justify-content:center;text-align:center;font-size:10px;color:#64748b;overflow:hidden}.photo img{width:100%;height:100%;object-fit:cover}.title{text-align:center;background:#008c7a;color:#fff;font-weight:800;margin:8px 0;padding:5px;letter-spacing:.5px}.meta{text-align:center;font-size:11px;margin:6px 0 10px;color:#334155}table{width:100%;border-collapse:collapse}.info td,.scores th,.scores td,.traits th,.traits td,.comments td,th,td{border:1px solid #222;padding:${landscape?'3px 4px':'4px 6px'};font-size:${landscape?'9.5px':'10.5px'};text-align:center}th,.scores th,.traits th{background:#008c7a;color:#fff}.scores tr:nth-child(even),.traits tr:nth-child(even),tr:nth-child(even){background:#e6f7f4}.left{text-align:left!important;white-space:nowrap}.rot{height:96px;vertical-align:bottom}.rot span{writing-mode:vertical-rl;transform:rotate(180deg);white-space:nowrap;font-weight:700}.top{background:#fef9c3!important}.grade{font-weight:800;color:#16a34a}.traits{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:8px}.comments td:first-child{width:170px;font-weight:700}.sig,.re-sig{display:flex;justify-content:space-between;margin-top:28px;font-size:11px;text-align:center;align-items:flex-end;gap:20px}.sig>div,.re-sig>div{width:210px}.sig-script,.re-sig-script{font-family:'Segoe Script','Lucida Handwriting',cursive;color:#0c4a6e;font-size:1.3rem;min-height:38px;display:flex;align-items:center;justify-content:center;padding-bottom:4px}.sig-line,.re-sig-line{border-top:1.5px solid #111;padding-top:6px;font-weight:700}.re-stamp-wrap{width:130px;height:130px;display:inline-block;position:relative;margin:0 auto}.re-stamp{width:100%;height:100%;opacity:.92;transform:rotate(-6deg);filter:drop-shadow(2px 4px 6px rgba(0,0,0,0.1))}.re-stamp image{mix-blend-mode:multiply;filter:contrast(1.3) brightness(1.1)}.re-rating{display:inline-block;padding:1px 8px;border-radius:8px;font-weight:800;background:#e0e7ff;color:#3730a3;min-width:24px;text-align:center}.re-rating-a{background:#dcfce7;color:#166a34}.re-rating-b{background:#dbeafe;color:#1e40af}.re-rating-c{background:#fef3c7;color:#92400e}.re-rating-d,.re-rating-e,.re-rating-f{background:#fee2e2;color:#991b1b}.stat{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:12px}.stat div{border:1px solid #c7d2fe;border-radius:10px;padding:8px;text-align:center;background:#eef2ff}.stat b{display:block;font-size:16px;color:#4f46e5}.grading-scale{margin-top:10px;font-size:9.5px;color:#475569;display:flex;gap:14px;flex-wrap:wrap;justify-content:center}.grading-scale b{color:#4f46e5}.note{margin-top:12px;font-size:9.5px;color:#94a3b8;text-align:center}.doc-signature{text-align:center;margin-top:18px;page-break-inside:avoid}.rc-bulk-page{page-break-after:always;break-after:page}.rc-bulk-page:last-child{page-break-after:auto;break-after:auto}@media print{body{background:#fff;padding:0}.sheet,.report-sheet{box-shadow:none}button{display:none!important}}</style>`; }

};
if (typeof sb !== 'undefined') ReportEngine.init(sb);
window.ReportEngine = ReportEngine;
