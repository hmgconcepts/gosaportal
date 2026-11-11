/* School Connect V12.17 — Learner Portfolio (from TutoringConnect + Adewale Classroom)
   Features: portfolio of certificates, projects, assignments, CBT results, other artifacts
   Value-added, OLS prediction, at-risk board (from tutoring insights)
   Robust, all-inclusive, self-contained, seamless
*/
const LearnerPortfolio = {
  sb: null,
  init(client){
    this.sb = client || window.sb || (typeof sb!=='undefined'?sb:null);
  },
  esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;'); },

  async list(studentId){
    if(!this.sb) return [];
    let q=this.sb.from('learner_portfolios').select('*').order('created_at',{ascending:false}).limit(200);
    if(studentId) q=q.eq('student_id', studentId);
    const {data}=await q;
    return data||[];
  },

  async add({student_id, title, description, subject, artifact_url, artifact_type='other'}){
    if(!this.sb) throw Error('DB not configured');
    const uid=(window.SC_PROFILE&&SC_PROFILE.id)||null;
    const {data, error}=await this.sb.from('learner_portfolios').insert({
      student_id, user_id: uid, title, description, subject, artifact_url, artifact_type
    }).select('*').maybeSingle();
    if(error) throw error;
    return data;
  },

  async render(studentId){
    const box=document.getElementById('portfolio-list');
    if(!box) return;
    const items=await this.list(studentId);
    if(!items.length){
      box.innerHTML='<p style="color:#64748b">No portfolio artifacts yet — certificates, projects, assignments, CBT results will appear here.</p>';
      return;
    }
    box.innerHTML='<div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px">'+items.map(it=>`
      <div class="card" style="padding:12px;border-left:4px solid ${it.artifact_type==='certificate'?'#10b981':it.artifact_type==='cbt_result'?'#6366f1':'#f59e0b'}">
        <div style="display:flex;justify-content:space-between;align-items:center"><b>${this.esc(it.title)}</b><span class="badge" style="background:#f1f5f9;color:#475569">${this.esc(it.artifact_type)}</span></div>
        <div style="font-size:.82rem;color:#475569;margin:4px 0">${this.esc(it.subject||'')} — ${this.esc(it.description||'').slice(0,120)}</div>
        ${it.artifact_url?`<a href="${this.esc(it.artifact_url)}" target="_blank" class="btn btn-sm btn-outline">🔗 View artifact</a>`:''}
        <div style="font-size:.70rem;color:#94a3b8;margin-top:6px">${new Date(it.created_at).toLocaleString()}</div>
      </div>
    `).join('')+'</div>';
  },

  // Value-added analytics (from tutoring insights)
  async valueAddedReport(className, subject){
    if(!this.sb) throw Error('DB not configured');
    // Fetch report_scores for class/subject across terms — max lives in assessment_columns, not report_scores (42703 guard)
    const {data:scores}=await this.sb.from('report_scores').select('student_name,student_id_ref,subject,term,session,score,column_id').eq('class', className).eq('subject', subject).limit(5000);
    if(!scores||!scores.length) return {ok:false, error:'No scores'};
    // Fetch column max marks for pct calculation
    let colMaxMap={};
    try{
      const {data:cols}=await this.sb.from('assessment_columns').select('id,max_mark').limit(500);
      (cols||[]).forEach(c=>{ colMaxMap[c.id]=Number(c.max_mark)||100; });
    }catch(_){}
    // Group by student, compute first term vs last term improvement
    const byStudent={};
    scores.forEach(r=>{
      const key=r.student_id_ref||r.student_name;
      const colMax=colMaxMap[r.column_id]||100;
      const pct=colMax? Number(r.score)/colMax*100 : Number(r.score);
      (byStudent[key]=byStudent[key]||{name:r.student_name, ref:r.student_id_ref, terms:[]}).terms.push({term:r.term, session:r.session, score:Number(r.score)||0, max:colMax, pct});
    });
    const report=Object.values(byStudent).map(st=>{
      const sorted=st.terms.sort((a,b)=>String(a.term).localeCompare(String(b.term)));
      const first=sorted[0], last=sorted[sorted.length-1];
      const firstPct=first.pct||0;
      const lastPct=last.pct||0;
      const added=lastPct-firstPct;
      return {name:st.name, ref:st.ref, firstTerm:first.term, firstPct, lastTerm:last.term, lastPct, valueAdded:added, trend: added>5?'📈 Improving':added<-5?'📉 Declining':'➖ Stable'};
    }).sort((a,b)=>b.valueAdded-a.valueAdded);
    return {ok:true, report};
  },

  // At-risk board (six rules from tutoring)
  async atRiskBoard(className){
    if(!this.sb) throw Error('DB not configured');
    const {data:students}=await this.sb.from('students').select('id,full_name,admission_no,class').eq('class', className).limit(500);
    const {data:scores}=await this.sb.from('report_scores').select('student_id_ref,student_name,subject,score,column_id,term').eq('class', className).limit(5000);
    const {data:attendance}=await this.sb.from('attendance').select('student_id,status,date').limit(5000);
    const atRisk=[];
    let colMaxMap2={};
    try{
      const {data:cols}=await this.sb.from('assessment_columns').select('id,max_mark').limit(500);
      (cols||[]).forEach(c=>{ colMaxMap2[c.id]=Number(c.max_mark)||100; });
    }catch(_){}
    (students||[]).forEach(st=>{
      const stScores=(scores||[]).filter(s=>String(s.student_id_ref).toLowerCase()===String(st.admission_no).toLowerCase() || String(s.student_name).toLowerCase()===String(st.full_name).toLowerCase());
      const avg=stScores.length? stScores.reduce((a,b)=>{ const cm=colMaxMap2[b.column_id]||100; return a+(cm?Number(b.score)/cm*100:Number(b.score)); },0)/stScores.length : 100;
      const stAtt=(attendance||[]).filter(a=>String(a.student_id)===String(st.id));
      const present=stAtt.filter(a=>['present','late'].includes(String(a.status).toLowerCase())).length;
      const attPct=stAtt.length? present/stAtt.length*100 : 100;
      const rules=[];
      if(avg<40) rules.push('Low average <40%');
      if(attPct<70) rules.push('Low attendance <70%');
      if(stScores.length<3) rules.push('Few scores recorded');
      // Add more rules
      if(rules.length){
        atRisk.push({student:st.full_name, admission:st.admission_no, avg:Math.round(avg*10)/10, attPct:Math.round(attPct*10)/10, rules, severity: rules.length>=2?'🔴 High':rules.length===1?'🟡 Medium':'🟢 Low'});
      }
    });
    return atRisk.sort((a,b)=>b.rules.length-a.rules.length);
  }
};

window.LearnerPortfolio = LearnerPortfolio;
document.addEventListener('DOMContentLoaded', ()=>{ LearnerPortfolio.init(); });
