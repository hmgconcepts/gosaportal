/* School Connect V12.14 — Assignment + CBT Assignment Bridge (robust, all-inclusive, self-contained, seamless)
   Fixes:
   1. Edit/Delete buttons restored for admin/tutor (crud.js) — never drop pre-existing features
   2. Report Cards student auto-fill robust (report-cards.html) — auto-filled on landing, readonly, only own
   3. Multi-subject CBT assignments: Score class auto-fills per subject, push fills each subject Assignment column
      - listCBTAssignments now includes MULTI-SUBJECT containing subject via client-side filtering (anti_cheat_config.subjects + ILIKE)
      - uiScoreCBT detects multi and delegates to uiScoreMultiCBT
      - saveCBTScores handles isMulti with subject-inclusive unique index assignment_scores_cbt_subject_unique (cbt_exam_id,student_id,subject)
      - Works for pre-existing multi-subject CBT assignments
   4. Take Assignment button beside every CBT assignment for student dashboard (robust)
*/
const AssignmentCBT = {
  sb: null,
  init(client){
    this.sb = client || window.sb || (typeof sb!=='undefined'?sb:null);
    if(!this.sb) return;
  },
  esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;'); },

  purposeLabel(exam){
    const t = String((exam && exam.assessment_type) || exam || '').toLowerCase();
    const map = {
      'assignment': '🟢 CBT Assignment',
      'ca': '🔵 Mid-term CA',
      'test': '🔵 Mid-term Test',
      'exam': '🔴 Terminal Exam',
      'project': '🟣 Project',
      'quiz': '🟡 Quiz',
      'practical': '🟠 Practical',
    };
    return map[t] || '⚪ '+(t||'Other');
  },
  purposeBadge(exam){
    const t = String((exam && exam.assessment_type) || exam || '').toLowerCase();
    const colors = {
      'assignment': 'background:#dcfce7;color:#166534;border:1px solid #86efac',
      'ca': 'background:#dbeafe;color:#1e40af;border:1px solid #93c5fd',
      'test': 'background:#dbeafe;color:#1e40af;border:1px solid #93c5fd',
      'exam': 'background:#fee2e2;color:#991b1b;border:1px solid #fca5a5',
      'project': 'background:#f3e8ff;color:#6b21a8;border:1px solid #c4b5fd',
      'quiz': 'background:#fef3c7;color:#92400e;border:1px solid #fcd34d',
    };
    const style = colors[t] || 'background:#f1f5f9;color:#475569;border:1px solid #e2e8f0';
    return `<span class="badge" style="${style}">${this.esc(this.purposeLabel(t))}</span>`;
  },
  isAssignment(exam){ return String(exam.assessment_type||'').toLowerCase() === 'assignment'; },
  isMidTerm(exam){ const t=String(exam.assessment_type||'').toLowerCase(); return t==='ca' || t==='test' || (exam.report_column && /ca1|ca2/i.test(exam.report_column)); },
  isTerminal(exam){ const t=String(exam.assessment_type||'').toLowerCase(); return t==='exam' || (exam.report_column && /exam/i.test(exam.report_column) && !/ca/i.test(exam.report_column)); },
  isMultiSubject(exam){
    if(!exam) return false;
    const subj = String(exam.subject||'');
    if(subj.toUpperCase().startsWith('MULTI-SUBJECT')) return true;
    const cfg = exam.anti_cheat_config;
    if(cfg && Array.isArray(cfg.subjects) && cfg.subjects.length>1) return true;
    return false;
  },
  getMultiSubjects(exam){
    if(!exam) return [];
    const cfg = exam.anti_cheat_config;
    if(cfg && Array.isArray(cfg.subjects) && cfg.subjects.length){
      return cfg.subjects.map(s=>String(s).trim()).filter(Boolean);
    }
    const subj = String(exam.subject||'');
    if(subj.toUpperCase().startsWith('MULTI-SUBJECT')){
      return subj.replace(/^MULTI-SUBJECT:\s*/i,'').split(',').map(s=>s.trim()).filter(Boolean);
    }
    return [subj].filter(Boolean);
  },

  // V12.14: robust multi-subject containment — includes MULTI-SUBJECT containing requested subject
  _matchesSubjectFilter(exam, requestedSubject){
    if(!requestedSubject) return true;
    const req = String(requestedSubject).trim().toLowerCase();
    if(!req) return true;
    const subjRaw = String(exam.subject||'').trim();
    const subjLower = subjRaw.toLowerCase();
    // exact match
    if(subjLower===req) return true;
    // MULTI-SUBJECT: ... contains req
    if(subjLower.startsWith('multi-subject:')){
      const listPart = subjRaw.replace(/^MULTI-SUBJECT:\s*/i,'').toLowerCase();
      // split by comma
      const parts = listPart.split(',').map(s=>s.trim()).filter(Boolean);
      if(parts.includes(req)) return true;
      if(listPart.includes(req)) return true;
    }
    // anti_cheat_config.subjects contains req
    const ac = exam.anti_cheat_config;
    if(ac && Array.isArray(ac.subjects)){
      const acLow = ac.subjects.map(s=>String(s).toLowerCase().trim());
      if(acLow.includes(req)) return true;
    }
    // also allow substring containment for legacy data
    if(subjLower.includes(req)) return true;
    return false;
  },

  async listCBTAssignments({class:klass, subject, term, session}={}){
    if(!this.sb) throw Error('Database not configured');
    // Fetch without subject filter to allow MULTI-SUBJECT client-side containment
    let q = this.sb.from('cbt_exams').select('id,code,title,subject,class,term,session,assessment_type,report_column,max_score,is_archived,created_at,teacher_id,anti_cheat_config').eq('is_archived', false).order('created_at',{ascending:false}).limit(500);
    if(klass) q=q.eq('class',klass);
    if(term) q=q.eq('term',term);
    if(session) q=q.eq('session',session);
    const {data, error}=await q;
    if(error) throw error;
    let list = (data||[]).filter(e=> this.isAssignment(e));
    if(subject){
      list = list.filter(e=> this._matchesSubjectFilter(e, subject));
    }
    return list;
  },
  async listAllCBTForDiff({class:klass, subject, term, session}={}){
    if(!this.sb) throw Error('Database not configured');
    let q = this.sb.from('cbt_exams').select('id,code,title,subject,class,term,session,assessment_type,report_column,max_score,is_archived,anti_cheat_config').eq('is_archived', false).limit(500);
    if(klass) q=q.eq('class',klass);
    if(term) q=q.eq('term',term);
    if(session) q=q.eq('session',session);
    const {data, error}=await q;
    if(error) throw error;
    if(!subject) return data||[];
    // include MULTI-SUBJECT containing subject for diff legend
    return (data||[]).filter(e=> !subject || this._matchesSubjectFilter(e, subject) || String(e.subject||'').toLowerCase()===String(subject).toLowerCase());
  },

  async syncSingle(cbtExamId){
    if(!this.sb) throw Error('Database not configured');
    try{
      const {data, error}=await this.sb.rpc('sc_assignment_cbt_sync', {p_cbt_exam_id:cbtExamId});
      if(error) throw error;
      if(!data.ok) throw Error(data.error||'Sync failed');
      return data;
    }catch(e){
      if(/not found|schema cache|function/i.test(String(e.message||''))){
        return await this._clientSyncSingle(cbtExamId);
      }
      throw e;
    }
  },
  async _clientSyncSingle(cbtExamId){
    const {data:exam, error:exErr}=await this.sb.from('cbt_exams').select('*').eq('id',cbtExamId).maybeSingle();
    if(exErr) throw exErr;
    if(!exam) throw Error('CBT exam not found');
    if(!this.isAssignment(exam)) throw Error('Not an assignment type');
    let {data:assign}=await this.sb.from('assignments').select('id').eq('cbt_exam_id',cbtExamId).maybeSingle();
    let assignId=assign && assign.id;
    if(!assignId){
      const {data:ins, error:insErr}=await this.sb.from('assignments').insert({title:exam.title, class:exam.class, subject:exam.subject, cbt_exam_id:exam.id, is_cbt:true, source:'cbt_assignment', posted_by:exam.teacher_id, drive_link: exam.code ? './cbt-exam.html?code='+exam.code : null}).select('id').maybeSingle();
      if(insErr) throw insErr;
      assignId=ins.id;
    }
    const {data:results, error:rErr}=await this.sb.from('cbt_results').select('*').eq('exam_id',cbtExamId).limit(5000);
    if(rErr) throw rErr;
    const {data:students}=await this.sb.from('students').select('id,full_name,admission_no').eq('class', exam.class||'');
    const norm=s=> String(s||'').trim().toLowerCase();
    const byAdm=new Map((students||[]).map(s=>[norm(s.admission_no), s]).filter(k=>k[0]));
    const byName=new Map((students||[]).map(s=>[norm(s.full_name), s]).filter(k=>k[0]));
    const isMulti = this.isMultiSubject(exam);
    const multiSubjects = isMulti ? this.getMultiSubjects(exam) : [];
    let synced=0;
    for(const res of (results||[])){
      let st = byAdm.get(norm(res.student_id_ref)) || byName.get(norm(res.student_name));
      if(!st) continue;
      if(isMulti && res.subject_scores && typeof res.subject_scores==='object'){
        const subjScores = res.subject_scores;
        for(const sub of Object.keys(subjScores)){
          const sd = subjScores[sub]||{};
          const rawScore = Number(sd.score||0);
          const rawTotal = Number(sd.total||exam.max_score||10);
          const scaled = rawTotal ? Math.round((rawScore/rawTotal*Number(exam.max_score||10))*10)/10 : rawScore;
          const row={assignment_id:assignId, cbt_exam_id:cbtExamId, student_id:st.id, student_id_ref:st.admission_no||res.student_id_ref||'', student_name:st.full_name, class:exam.class||'', subject:sub, term:exam.term||'', session:exam.session||'', score:scaled, max_score:Number(exam.max_score)||10};
          // try subject-inclusive unique first
          let {error}=await this.sb.from('assignment_scores').upsert(row, {onConflict:'cbt_exam_id,student_id,subject'});
          if(error){
            const {error:e2}=await this.sb.from('assignment_scores').upsert(row, {onConflict:'cbt_exam_id,student_id'});
            if(!e2) synced++;
          }else synced++;
        }
      }else{
        const row={assignment_id:assignId, cbt_exam_id:cbtExamId, student_id:st.id, student_id_ref:st.admission_no||res.student_id_ref||'', student_name:st.full_name, class:exam.class||'', subject:exam.subject||'', term:exam.term||'', session:exam.session||'', score:Number(res.score)||0, max_score:Number(res.total||exam.max_score)||10};
        const {error}=await this.sb.from('assignment_scores').upsert(row, {onConflict:'cbt_exam_id,student_id,subject'});
        if(!error) synced++;
        else{
          const {error:e2}=await this.sb.from('assignment_scores').upsert(row, {onConflict:'cbt_exam_id,student_id'});
          if(!e2) synced++;
        }
      }
    }
    return {ok:true, synced, total_results:(results||[]).length, assignment_id:assignId, subjects: isMulti ? multiSubjects : [exam.subject]};
  },
  async syncAll({class:klass, subject, term, session}){
    if(!this.sb) throw Error('Database not configured');
    try{
      const {data, error}=await this.sb.rpc('sc_assignment_cbt_sync_all', {p_class:klass||null, p_subject:subject||null, p_term:term||null, p_session:session||null});
      if(error) throw error;
      return data;
    }catch(e){
      if(/not found|schema cache|function/i.test(String(e.message||''))){
        const list=await this.listCBTAssignments({class:klass, subject, term, session});
        let total=0;
        for(const ex of list){ const r=await this._clientSyncSingle(ex.id); total+=r.synced; }
        return {ok:true, exams_synced:list.length, total_scores_synced:total};
      }
      throw e;
    }
  },

  async listCombined({class:klass, subject, term}={}){
    if(!this.sb) throw Error('Database not configured');
    let q=this.sb.from('assignments').select('id,title,class,subject,due_date,cbt_exam_id,is_cbt,source,drive_link,created_at').order('created_at',{ascending:false}).limit(500);
    if(klass) q=q.eq('class',klass);
    // Don't filter by subject strictly for combined — include MULTI-SUBJECT containing subject
    const {data:phys, error:pErr}=await q;
    if(pErr) throw pErr;
    let filteredPhys = phys||[];
    if(subject){
      filteredPhys = filteredPhys.filter(a=>{
        if(!a.subject) return true;
        const subjLower = String(a.subject).toLowerCase();
        const reqLower = String(subject).toLowerCase();
        if(subjLower===reqLower) return true;
        if(subjLower.startsWith('multi-subject:') && subjLower.includes(reqLower)) return true;
        if(subjLower.includes(reqLower)) return true;
        return false;
      });
    }
    let cbtList=[];
    try{ cbtList=await this.listCBTAssignments({class:klass, subject, term}); }catch(_){}
    const haveCbtIds=new Set((filteredPhys||[]).map(a=>a.cbt_exam_id).filter(Boolean));
    const virtual=cbtList.filter(c=>!haveCbtIds.has(c.id)).map(c=>({id:'virtual-'+c.id, title:c.title, class:c.class, subject:c.subject, cbt_exam_id:c.id, is_cbt:true, source:'cbt_assignment', virtual:true, drive_link:'./cbt-exam.html?code='+c.code, _cbt:c, created_at:c.created_at, anti_cheat_config:c.anti_cheat_config}));
    return [...(filteredPhys||[]), ...virtual].sort((a,b)=> new Date(b.created_at||0)-new Date(a.created_at||0));
  },

  async renderCBTSection(){
    const box=document.getElementById('ap-cbt-list');
    if(!box) return;
    const klass=(document.getElementById('ap-class')||{}).value;
    const subject=(document.getElementById('ap-subject')||{}).value;
    if(!klass||!subject){ box.innerHTML='<p style="color:#64748b">Pick class + subject above to see CBT assignments for that subject (including multi-subject assignments containing this subject).</p>'; return; }
    box.innerHTML='<span class="pulse">Loading CBT assignments…</span>';
    try{
      const list=await this.listCBTAssignments({class:klass, subject});
      const allForDiff=await this.listAllCBTForDiff({class:klass, subject});
      const midTerms=allForDiff.filter(e=>!this.isAssignment(e) && this.isMidTerm(e));
      const terminals=allForDiff.filter(e=>!this.isAssignment(e) && this.isTerminal(e));
      const others=allForDiff.filter(e=>!this.isAssignment(e) && !this.isMidTerm(e) && !this.isTerminal(e));
      if(!list.length){
        box.innerHTML=`<div class="notice" style="background:#fffbeb;border-color:#fcd34d;color:#92400e"><b>No CBT Assignments for ${this.esc(klass)} · ${this.esc(subject)} yet.</b><br>Create them on <a href="cbt.html">CBT page</a> → Assessment type = <b>🟢 Assignment / Homework</b>. For multi-subject, use <a href="cbt-multi.html">CBT Multi-Subject Builder</a> → Type = Assignment. They will appear here automatically (single + multi-subject containing ${this.esc(subject)}) and can be scored cumulatively per subject.<br><br><b>Differentiation:</b><br>${midTerms.length? `🔵 Mid-term CAs: ${midTerms.length} — pushed to CA1/CA2 columns<br>` : ''}${terminals.length? `🔴 Terminal Exams: ${terminals.length} — pushed to Exam column<br>` : ''}${others.length? `Other CBT: ${others.length} — project/quiz/practical<br>` : ''}<small>Only 🟢 CBT Assignments are collated here for cumulative assignment scores.</small></div>`;
        return;
      }
      box.innerHTML=`<div style="margin-bottom:8px"><b>🖥️ ${list.length} CBT Assignment(s) for ${this.esc(klass)} · ${this.esc(subject)}</b> — includes single-subject + multi-subject assignments containing ${this.esc(subject)}. Each given more than once per term, cumulatively collated per subject. Click Score to auto-fill from CBT results (per subject for multi). Students see link to take it.</div>
        <div class="table-wrap"><table><thead><tr><th>Code / Title</th><th>Purpose</th><th>Subjects</th><th>Term / Session</th><th>Student Link</th><th>Actions</th></tr></thead><tbody>`+
        list.map(ex=>{
          const subs = this.isMultiSubject(ex) ? this.getMultiSubjects(ex).join(', ') : ex.subject;
          const badge = this.isMultiSubject(ex) ? '<span class="badge" style="background:#eef2ff;color:#4338ca;border:1px solid #a5b4fc">🧪 Multi: '+this.esc(subs.slice(0,60))+'</span>' : this.purposeBadge(ex);
          return `<tr><td><b>${this.esc(ex.code||'—')}</b><br>${this.esc(ex.title||'Untitled')}<br><small>${this.esc(ex.class||'')} · ${this.esc(ex.subject||'')}</small></td><td>${badge}<br><small>Max ${ex.max_score||10}</small></td><td style="font-size:.82rem;max-width:160px;white-space:normal">${this.esc(subs||'—')}</td><td>${this.esc(ex.term||'—')}<br><small>${this.esc(ex.session||'')}</small></td><td><a href="./cbt-exam.html?code=${this.esc(ex.code||'')}" target="_blank" class="btn btn-sm btn-outline">🔗 Take CBT</a><br><small style="color:#64748b">${this.esc('./cbt-exam.html?code='+ex.code)}</small></td><td style="white-space:nowrap"><button class="btn btn-sm btn-primary" onclick="AssignmentCBT.uiScoreCBT('${ex.id}')">✍️ Score class (auto-fill${this.isMultiSubject(ex)?' per subject':''})</button> <button class="btn btn-sm btn-outline" onclick="AssignmentCBT.uiSyncSingle('${ex.id}')">🔄 Sync scores now</button></td></tr>`;
        }).join('')+
        `</tbody></table></div>
        <div style="margin-top:8px;display:flex;gap:8px;flex-wrap:wrap"><button class="btn btn-primary btn-sm" onclick="AssignmentCBT.uiSyncAll()">🔄 Sync ALL CBT Assignment scores for this class/subject (single + multi)</button><button class="btn btn-outline btn-sm" onclick="AssignmentCBT.renderCBTSection()">↻ Refresh</button></div>
        <div id="ap-cbt-log" style="margin-top:8px;font-size:.85rem;color:#475569"></div>
        <div class="notice" style="margin-top:10px;background:#eff6ff;border-color:#93c5fd;color:#1e3a8a"><b>Clear differentiation & modus operandi:</b><br>🟢 Assignment = homework (multiple per term, cumulative → Assignment column, per subject for multi) · 🔵 Mid-term CA = CA1/CA2 (once) · 🔴 Terminal Exam = Exam column (once) · Other = project/quiz/practical.<br>For multi-subject CBT assignments, Score class auto-fills per subject (just like exams/mid-term), and push fills each subject Assignment column. Works for pre-existing multi-subject assignments too.</div>`;
    }catch(e){ box.innerHTML=`<p style="color:#b91c1c">${this.esc(e.message||e)}</p>`; }
  },
  log(msg, kind){
    const el=document.getElementById('ap-cbt-log') || document.getElementById('auh-log');
    if(el){
      const color=kind==='error'? '#b91c1c' : kind==='success'? '#166534' : '#475569';
      el.innerHTML=`<div style="padding:6px 8px;margin-bottom:4px;border-radius:6px;background:${kind==='error'?'#fef2f2':kind==='success'?'#f0fdf4':'#eff6ff'};border:1px solid ${kind==='error'?'#fca5a5':kind==='success'?'#86efac':'#93c5fd'};color:${color}">${this.esc(msg)}</div>`+el.innerHTML;
    }
    if(typeof toast==='function') toast(msg, kind||'info', 6000);
  },
  async uiSyncSingle(id){
    try{
      this.log('Syncing CBT assignment scores…','info');
      const res=await this.syncSingle(id);
      this.log(`✅ Synced ${res.synced||0}/${res.total_results||0} scores for CBT assignment (subjects: ${(res.subjects||[]).join(', ')||'—'}). They now accumulate per subject in totals and are visible for every student of that class.`, 'success');
      if(window.AP && AP.matrix) AP.matrix();
      if(window.AP && AP.totals) AP.totals();
    }catch(e){ this.log('Sync failed: '+(e.message||e), 'error'); }
  },
  async uiSyncAll(){
    const klass=(document.getElementById('ap-class')||{}).value, subject=(document.getElementById('ap-subject')||{}).value;
    if(!klass||!subject){ toast('Pick class + subject first','warning'); return; }
    try{
      this.log(`Syncing ALL CBT assignments for ${klass} · ${subject} (including multi-subject containing ${subject})…`,'info');
      const res=await this.syncAll({class:klass, subject});
      this.log(`✅ Synced ${res.total_scores_synced||0} scores across ${res.exams_synced||0} CBT assignment(s) (single + multi). Reflects per subject for every student of that class.`, 'success');
      if(window.AP && AP.matrix) AP.matrix();
    }catch(e){ this.log('Sync all failed: '+(e.message||e), 'error'); }
  },
  async uiScoreCBT(cbtId){
    if(!this.sb){ toast('Database not configured','warning'); return; }
    const {data:exam}=await this.sb.from('cbt_exams').select('*').eq('id', cbtId).maybeSingle();
    if(!exam){ toast('CBT assignment not found','warning'); return; }
    if(this.isMultiSubject(exam)){
      return await this.uiScoreMultiCBT(cbtId);
    }
    const {data:students}=await this.sb.from('students').select('id,full_name,admission_no,class').eq('class', exam.class||'').order('full_name');
    const {data:results}=await this.sb.from('cbt_results').select('*').eq('exam_id', cbtId).limit(5000);
    const norm=s=> String(s||'').trim().toLowerCase();
    const byAdm=new Map();
    const byName=new Map();
    const byNameNoSpace=new Map();
    (students||[]).forEach(s=>{
      const adm=norm(s.admission_no);
      if(adm) byAdm.set(adm, s);
      const name=norm(s.full_name);
      if(name) byName.set(name, s);
      const ns=name.replace(/\s+/g,'');
      if(ns) byNameNoSpace.set(ns, s);
    });
    const resultMap=new Map();
    (results||[]).forEach(r=>{
      let st=null;
      const refAdm=norm(r.student_id_ref);
      const refName=norm(r.student_name);
      const refNoSpace=refName.replace(/\s+/g,'');
      if(refAdm && byAdm.has(refAdm)) st=byAdm.get(refAdm);
      else if(refName && byName.has(refName)) st=byName.get(refName);
      else if(refNoSpace && byNameNoSpace.has(refNoSpace)) st=byNameNoSpace.get(refNoSpace);
      else {
        for(const [k,v] of byName.entries()){
          if(refName && (refName.includes(k) || k.includes(refName))){ st=v; break; }
        }
      }
      if(st) resultMap.set(String(st.id), r);
    });
    let {data:assign}=await this.sb.from('assignments').select('id,title').eq('cbt_exam_id', cbtId).maybeSingle();
    let assignId=assign && assign.id;
    if(!assignId){
      try{
        const {data:ins}=await this.sb.from('assignments').insert({title:exam.title, class:exam.class, subject:exam.subject, cbt_exam_id:exam.id, is_cbt:true, source:'cbt_assignment', posted_by:exam.teacher_id, drive_link: exam.code ? './cbt-exam.html?code='+exam.code : null}).select('id').maybeSingle();
        assignId=ins && ins.id;
      }catch(_){ assignId=null; }
    }
    const autoMax=Number(exam.max_score||10)||10;
    const rows=(students||[]).map(s=>{
      const res=resultMap.get(String(s.id));
      let score='';
      let cbtInfo='<span style="color:#94a3b8">No CBT result yet — student has not taken it</span>';
      if(res){
        const rawScore=Number(res.score)||0;
        const rawTotal=Number(res.total)||autoMax||10;
        const scaled = rawTotal ? Math.round((rawScore/rawTotal*autoMax)*10)/10 : rawScore;
        score = scaled;
        cbtInfo = `<span style="color:#166534;font-weight:700">CBT: ${res.score}/${res.total} (${res.percent||0}%) → Scaled: ${scaled}/${autoMax}</span><br><small>Cert: ${res.cert_code||'—'} · Raw max ${rawTotal} → Assignment max ${autoMax}</small>`;
      }
      const max=autoMax;
      return `<tr data-sid="${s.id}" data-ref="${this.esc(s.admission_no||'')}" data-name="${this.esc(s.full_name)}"><td><b>${this.esc(s.full_name)}</b><br><small>${this.esc(s.admission_no||'')} · ${this.esc(s.class||'')}</small></td><td>${cbtInfo}</td><td><input class="form-input ap-sc" type="number" min="0" max="${max}" style="width:90px" value="${score}" data-max="${max}" data-raw-score="${res?res.score:''}" data-raw-total="${res?res.total:''}" data-sid="${s.id}" data-ref="${this.esc(s.admission_no||'')}" data-name="${this.esc(s.full_name)}" placeholder="—"></td></tr>`;
    }).join('');
    openModal(`🖥️ Score CBT Assignment: ${this.esc(exam.title)} (${this.esc(exam.code)}) — Auto-filled`,
      `<div class="notice" style="background:#f0fdf4;border-color:#86efac;color:#166534"><b>✅ Auto-filled from CBT results</b> — ${results?results.length:0} result(s) found, ${resultMap.size} matched to class register. Scores, kind and max are auto-filled. Physical assignments require manual entry; CBT assignments auto-fill seamlessly. They accumulate cumulatively for ${this.esc(exam.class)} · ${this.esc(exam.subject)} → push to Assignment column. Link auto-filled for students: <a href="./cbt-exam.html?code=${this.esc(exam.code)}" target="_blank">./cbt-exam.html?code=${this.esc(exam.code)}</a></div>
       <div class="grid grid-3" style="margin:8px 0">
         <div class="form-group"><label>Assignment kind (auto-filled)</label><select class="form-select" id="ap-cbt-kind" disabled><option selected>CBT assignment (auto-marked)</option><option>Written homework</option><option>Class exercise</option><option>Project</option><option>Practical</option></select><small style="color:#166534">Auto-filled — CBT assignments are auto-marked, no manual kind needed</small></div>
         <div class="form-group"><label>Maximum mark for THIS assignment (auto-filled)</label><input class="form-input" id="ap-cbt-max" type="number" value="${autoMax}" min="1" style="width:120px" readonly><small style="color:#166534">Auto-filled from CBT exam max_score (${autoMax})</small></div>
         <div class="form-group"><label>Purpose (auto-filled, differentiated)</label><input class="form-input" value="${this.esc(this.purposeLabel(exam))} — multiple per term, cumulative → Assignment column" readonly style="width:100%"><small style="color:#475569">Clearly differentiated from 🔵 Mid-term and 🔴 Terminal</small></div>
       </div>
       <div class="table-wrap" style="max-height:50vh;overflow:auto"><table><thead><tr><th>Student</th><th>CBT Result (auto)</th><th>Score to record (auto-filled)</th></tr></thead><tbody>${rows||'<tr><td colspan=3>No students in class '+this.esc(exam.class||'')+'</td></tr>'}</tbody></table></div>
       <p style="font-size:.82rem;color:#64748b">Blank = not submitted (excluded from totals). Auto-filled scores come from CBT engine — teacher can adjust before saving, then they accumulate. Reflects for every student of that class.</p>`,
      `<button class="btn btn-outline" onclick="closeModal()">Cancel</button><button class="btn btn-primary" onclick="AssignmentCBT.saveCBTScores('${cbtId}','${assignId||''}')">💾 Save ${students?students.length:0} auto-filled scores (cumulative)</button>`);
  },
  async saveCBTScores(cbtId, assignId, isMultiFlag=false){
    const maxInput=document.getElementById('ap-cbt-max');
    const max=Number((maxInput||{}).value)||10;
    const {data:exam}=await this.sb.from('cbt_exams').select('class,subject,term,session,max_score,anti_cheat_config').eq('id', cbtId).maybeSingle();
    // V12.15: use current academic period for term/session to ensure scores appear in current term score sheet (robust)
    // If current period exists, use it; otherwise fallback to exam term/session
    let curTerm='', curSession='';
    try{
      if(window.CRUD && CRUD.currentPeriod){
        const cp=await CRUD.currentPeriod();
        curTerm=cp.term||'';
        curSession=cp.session||'';
      }
    }catch(_){}
    const effTerm = curTerm || (exam&&exam.term) || '';
    const effSession = curSession || (exam&&exam.session) || '';
    const rows=[];
    const errors=[];
    // Detect multi by flag or by presence of data-subject inputs
    const modalBody = document.getElementById('modal-body') || document.querySelector('.modal-body');
    const scope = modalBody || document;
    const multiInputs = scope.querySelectorAll('input.ap-sc[data-subject]');
    const isMulti = isMultiFlag || multiInputs.length>0 || (exam && this.isMultiSubject(exam));
    if(isMulti){
      // Per-subject handling — robust, self-contained, all-inclusive, seamless
      multiInputs.forEach(inp=>{
        if(modalBody && !inp.closest('#modal-body') && !inp.closest('.modal-body')) return;
        const v = inp.value.trim();
        if(v==='') return;
        const sid = inp.getAttribute('data-sid') || inp.getAttribute('data-student-id') || '';
        if(!sid) return;
        const subj = inp.getAttribute('data-subject') || (exam&&exam.subject) || '';
        const ref = inp.getAttribute('data-ref') || '';
        const name = inp.getAttribute('data-name') || '';
        const raw = Number(v)||0;
        const finalScore = Math.min(raw, max);
        rows.push({assignment_id:assignId||null, cbt_exam_id:cbtId, student_id:sid, student_id_ref:ref, student_name:name, class:(exam&&exam.class)||'', subject:subj, term:effTerm, session:effSession, score:finalScore, max_score:max, recorded_by:(window.SC_PROFILE&&SC_PROFILE.id)||null});
      });
      // Also support inputs where data-sid on tr but data-subject on input (fallback)
      if(!rows.length){
        scope.querySelectorAll('tr').forEach(tr=>{
          const sid = tr.getAttribute('data-sid') || '';
          if(!sid) return;
          const ref = tr.getAttribute('data-ref')||'';
          const name = tr.getAttribute('data-name')||'';
          tr.querySelectorAll('input.ap-sc[data-subject]').forEach(inp=>{
            const v = inp.value.trim();
            if(v==='') return;
            const subj = inp.getAttribute('data-subject')||'';
            rows.push({assignment_id:assignId||null, cbt_exam_id:cbtId, student_id:sid, student_id_ref:ref, student_name:name, class:(exam&&exam.class)||'', subject:subj, term:effTerm, session:effSession, score:Math.min(Number(v)||0,max), max_score:max, recorded_by:(window.SC_PROFILE&&SC_PROFILE.id)||null});
          });
        });
      }
    }else{
      // Single-subject handling
      const collect = (selector)=>{
        document.querySelectorAll(selector).forEach(tr=>{
          if(modalBody && !tr.closest('#modal-body') && !tr.closest('.modal-body')) return;
          const input=tr.querySelector('.ap-sc');
          if(!input) return;
          let v=input.value;
          if(v==='' && input.getAttribute('value')!==null) v=input.getAttribute('value');
          if(v==='') return;
          const rawScore=Number(v)||0;
          const finalScore=Math.min(rawScore, max);
          rows.push({assignment_id:assignId||null, cbt_exam_id:cbtId, student_id:tr.getAttribute('data-sid'), student_id_ref:tr.getAttribute('data-ref')||'', student_name:tr.getAttribute('data-name')||'', class:(exam&&exam.class)||'', subject:(exam&&exam.subject)||'', term:effTerm, session:effSession, score:finalScore, max_score:max, recorded_by:(window.SC_PROFILE&&SC_PROFILE.id)||null});
        });
      };
      collect('#modal-body tr[data-sid], .modal-body tr[data-sid]');
      if(!rows.length){
        // fallback any tr[data-sid] in document
        collect('tr[data-sid]');
      }
      // also fallback direct inputs with data-sid attribute (in case tr not used)
      if(!rows.length){
        scope.querySelectorAll('input.ap-sc[data-sid]').forEach(inp=>{
          const v=inp.value.trim();
          if(v==='') return;
          rows.push({assignment_id:assignId||null, cbt_exam_id:cbtId, student_id:inp.getAttribute('data-sid'), student_id_ref:inp.getAttribute('data-ref')||'', student_name:inp.getAttribute('data-name')||'', class:(exam&&exam.class)||'', subject:(exam&&exam.subject)||'', term:effTerm, session:effSession, score:Math.min(Number(v)||0,max), max_score:max, recorded_by:(window.SC_PROFILE&&SC_PROFILE.id)||null});
        });
      }
    }
    if(!rows.length){ toast('No scores to save — all inputs blank. Auto-filled scores should appear; if not, ensure students have taken the CBT assignment and that matching (admission_no/full_name) succeeded.','warning',8000); return; }
    let saved=0, failed=0;
    for(const row of rows){
      try{
        // Try subject-inclusive unique first (V12.13: allows per-subject rows for multi-subject)
        let {error}=await this.sb.from('assignment_scores').upsert(row, {onConflict:'cbt_exam_id,student_id,subject'});
        if(error){
          // Fallback to old unique (single-subject) + then try update
          const {error:e2}=await this.sb.from('assignment_scores').upsert(row, {onConflict:'cbt_exam_id,student_id'});
          if(e2){
            // Last fallback: insert or update
            const {error:e3}=await this.sb.from('assignment_scores').insert(row);
            if(e3){
              const upd = isMulti ? await this.sb.from('assignment_scores').update({score:row.score, max_score:row.max_score, student_name:row.student_name, student_id_ref:row.student_id_ref}).eq('cbt_exam_id',cbtId).eq('student_id',row.student_id).eq('subject',row.subject)
                : await this.sb.from('assignment_scores').update({score:row.score, max_score:row.max_score}).eq('cbt_exam_id',cbtId).eq('student_id',row.student_id);
              if(upd.error){ failed++; errors.push(upd.error.message); continue; }
            }
          }
        }
        saved++;
      }catch(e){ failed++; errors.push(e.message||String(e)); }
    }
    closeModal();
    if(saved===0){
      toast(`❌ Saved 0 scores — errors: ${errors.slice(0,3).join(' | ')} — Check RLS (is_staff) and that assignment_scores.cbt_exam_id + assignment_scores_cbt_subject_unique exists (run v12.13 SQL).`, 'danger', 10000);
      this.log(`❌ Saved 0 scores for CBT assignment ${cbtId} — errors: ${errors.join(' | ')}`, 'error');
    }else{
      const subjInfo = isMulti ? ` per subject (${[...new Set(rows.map(r=>r.subject))].join(', ')})` : '';
      toast(`💾 Saved ${saved} CBT assignment score(s)${subjInfo} (max ${max}) — scaled to align with Maximum mark, now accumulating cumulatively for Assignment column${isMulti?' per subject':''} and visible for every student of that class.`, 'success', 8000);
      this.log(`✅ Saved ${saved} scores for CBT assignment ${cbtId}${subjInfo} (max ${max}) — ${failed? failed+' failed: '+errors.slice(0,2).join(' | ') : 'all ok'}`, failed?'warning':'success');
    }
    if(window.AP){
      if(AP.matrix) setTimeout(()=>AP.matrix(), 400);
      if(AP.totals) setTimeout(()=>AP.totals(), 400);
    }
    if(window.AssignmentCBT) setTimeout(()=>AssignmentCBT.renderCBTSection(), 600);
  },
  // Multi-subject per subject auto-fill — robust, works for pre-existing multi-subject CBT assignments
  async uiScoreMultiCBT(cbtId){
    if(!this.sb){ toast('Database not configured','warning'); return; }
    const {data:exam}=await this.sb.from('cbt_exams').select('*').eq('id', cbtId).maybeSingle();
    if(!exam){ toast('CBT assignment not found','warning'); return; }
    const subjects = this.getMultiSubjects(exam);
    if(!subjects.length){
      // Fallback to single-subject UI if not actually multi
      return await this.uiScoreCBT(cbtId);
    }
    const {data:students}=await this.sb.from('students').select('id,full_name,admission_no,class').eq('class', exam.class||'').order('full_name');
    const {data:results}=await this.sb.from('cbt_results').select('*').eq('exam_id', cbtId).limit(5000);
    const norm=s=> String(s||'').trim().toLowerCase();
    const byAdm=new Map(), byName=new Map(), byNameNoSpace=new Map();
    (students||[]).forEach(s=>{
      const adm=norm(s.admission_no); if(adm) byAdm.set(adm, s);
      const name=norm(s.full_name); if(name) byName.set(name, s);
      const ns=name.replace(/\s+/g,''); if(ns) byNameNoSpace.set(ns, s);
    });
    const resultMap=new Map();
    (results||[]).forEach(r=>{
      let st=null;
      const refAdm=norm(r.student_id_ref);
      const refName=norm(r.student_name);
      const refNoSpace=refName.replace(/\s+/g,'');
      if(refAdm && byAdm.has(refAdm)) st=byAdm.get(refAdm);
      else if(refName && byName.has(refName)) st=byName.get(refName);
      else if(refNoSpace && byNameNoSpace.has(refNoSpace)) st=byNameNoSpace.get(refNoSpace);
      else {
        for(const [k,v] of byName.entries()){
          if(refName && (refName.includes(k) || k.includes(refName))){ st=v; break; }
        }
      }
      if(st) resultMap.set(String(st.id), r);
    });
    let {data:assign}=await this.sb.from('assignments').select('id').eq('cbt_exam_id', cbtId).maybeSingle();
    let assignId=assign && assign.id;
    if(!assignId){
      try{
        const {data:ins}=await this.sb.from('assignments').insert({title:exam.title, class:exam.class, subject:exam.subject, cbt_exam_id:exam.id, is_cbt:true, source:'cbt_assignment', posted_by:exam.teacher_id, drive_link: exam.code ? './cbt-exam.html?code='+exam.code : null}).select('id').maybeSingle();
        assignId=ins && ins.id;
      }catch(_){ assignId=null; }
    }
    const autoMax=Number(exam.max_score||10)||10;
    const tableHead='<tr><th>Student</th>'+subjects.map(sub=>'<th style="font-size:.75rem">'+this.esc(sub)+'<br><small>Score</small></th>').join('')+'<th>Total</th></tr>';
    const rowsHtml=(students||[]).map(s=>{
      const res=resultMap.get(String(s.id));
      let totalGot=0, totalMax=0;
      const cells=subjects.map(sub=>{
        let score='';
        let info='';
        if(res){
          const subjScores=res.subject_scores||{};
          const subData=subjScores[sub]||{};
          if(subData && subData.score!=null){
            const rawScore=Number(subData.score||0);
            const rawTotal=Number(subData.total||autoMax);
            const scaled=rawTotal ? Math.round((rawScore/rawTotal*autoMax)*10)/10 : rawScore;
            score=scaled;
            totalGot+=Number(scaled)||0;
            totalMax+=autoMax;
            info='<small style="color:#166534">'+subData.score+'/'+subData.total+' → '+scaled+'</small>';
          }else if(res && res.score!=null){
            // Fallback: if subject_scores missing (pre-existing multi), use overall percent scaled per subject
            const pct=Number(res.percent||0);
            if(pct){
              const scaledOverall=Math.round((pct/100*autoMax)*10)/10;
              score=scaledOverall;
              totalGot+=Number(scaledOverall)||0;
              totalMax+=autoMax;
              info='<small style="color:#64748b">Overall '+pct+'% → '+scaledOverall+' (pre-existing multi fallback)</small>';
            }
          }
        }
        return '<td><input class="form-input ap-sc" type="number" min="0" max="'+autoMax+'" style="width:70px" value="'+score+'" data-max="'+autoMax+'" data-subject="'+this.esc(sub)+'" data-sid="'+s.id+'" data-ref="'+this.esc(s.admission_no||'')+'" data-name="'+this.esc(s.full_name)+'"><br>'+info+'</td>';
      }).join('');
      return '<tr data-sid="'+s.id+'" data-ref="'+this.esc(s.admission_no||'')+'" data-name="'+this.esc(s.full_name)+'"><td><b>'+this.esc(s.full_name)+'</b><br><small>'+this.esc(s.admission_no||'')+'</small></td>'+cells+'<td><b>'+totalGot+' / '+totalMax+'</b></td></tr>';
    }).join('');
    openModal('🖥️ Score Multi-Subject CBT Assignment: '+this.esc(exam.title)+' ('+this.esc(exam.code)+') — Auto-filled per subject',
      '<div class="notice" style="background:#eef2ff;border-color:#93c5fd;color:#1e40af"><b>🧪 Multi-subject:</b> '+subjects.length+' subjects ('+subjects.map(s=>this.esc(s)).join(', ')+'). Scores auto-filled per subject, push fills each subject Assignment column. Works for pre-existing multi-subject assignments too (fallback uses overall % if subject_scores missing).</div>'+
      '<div class="notice" style="background:#f0fdf4;border-color:#86efac;color:#166534"><b>✅ Auto-filled per subject</b> — '+(results?results.length:0)+' results, '+resultMap.size+' matched. Kind and max auto-filled. Each subject score accumulates cumulatively for that subject Assignment column.</div>'+
      '<div class="grid g3" style="margin:8px 0"><div class="form-group"><label>Kind (auto)</label><select class="form-select" id="ap-cbt-kind" disabled><option selected>CBT assignment (auto-marked)</option></select></div><div class="form-group"><label>Max (auto)</label><input class="form-input" id="ap-cbt-max" type="number" value="'+autoMax+'" readonly></div><div class="form-group"><label>Purpose</label><input class="form-input" value="'+this.esc(this.purposeLabel(exam))+' — multi, cumulative per subject" readonly></div></div>'+
      '<div class="table-wrap" style="max-height:50vh;overflow:auto"><table><thead>'+tableHead+'</thead><tbody>'+(rowsHtml||'<tr><td>No students</td></tr>')+'</tbody></table></div>'+
      '<p style="font-size:.82rem;color:#64748b;margin-top:8px">For multi-subject, each subject column auto-fills from subject_scores breakdown (or overall % fallback for pre-existing). Blank = not submitted. They accumulate per subject → push to each subject Assignment column.</p>',
      '<button class="btn btn-outline" onclick="closeModal()">Cancel</button><button class="btn btn-primary" onclick="AssignmentCBT.saveCBTScores(\''+cbtId+'\',\''+(assignId||'')+'\', true)">💾 Save per subject (cumulative)</button>');
  },
  async injectStudentLinks(){
    try{
      const table=document.getElementById('assignments-table');
      if(!table) return;
      const role=String((window.SC_PROFILE&&SC_PROFILE.role)||'').toLowerCase();
      if(!['student','parent'].includes(role)) return;
      const {data:assigns}=await this.sb.from('assignments').select('id,title,class,subject,drive_link,cbt_exam_id,is_cbt').eq('is_cbt', true).limit(200);
      if(!assigns||!assigns.length) return;
      const rows=table.querySelectorAll('tbody tr[data-id]');
      for(const tr of rows){
        const id=tr.getAttribute('data-id');
        const a=(assigns||[]).find(x=>x.id===id);
        if(!a) continue;
        const lastTd=tr.querySelector('td:last-child');
        if(!lastTd) continue;
        if(lastTd.querySelector('.ap-take-cbt')) continue;
        const href = a.drive_link || (a.cbt_exam_id ? './cbt-exam.html?code='+a.cbt_exam_id : '');
        if(href){
          const btn=document.createElement('a');
          btn.className='btn btn-sm btn-primary ap-take-cbt';
          btn.href=href;
          btn.target='_blank';
          btn.textContent='🖥️ Take Assignment';
          btn.title='Take this CBT assignment — auto-marked, multiple per term cumulative per subject';
          btn.style.marginRight='4px';
          lastTd.insertBefore(btn, lastTd.firstChild);
        }
      }
    }catch(_){}
  }
};

AssignmentCBT.patchAP = function(){
  if(!window.AP) return;
  try{
    const clsSel=document.getElementById('ap-class');
    const subSel=document.getElementById('ap-subject');
    if(clsSel && !clsSel._cbtPatched){
      clsSel.addEventListener('change', ()=>{ setTimeout(()=>{ AssignmentCBT.renderCBTSection(); }, 300); });
      clsSel._cbtPatched=true;
    }
    if(subSel && !subSel._cbtPatched){
      subSel.addEventListener('change', ()=>{ setTimeout(()=>{ AssignmentCBT.renderCBTSection(); }, 300); });
      subSel._cbtPatched=true;
    }
  }catch(_){}

  const origPull=AP.pullCBT;
  AP.pullCBT=async function(){
    const cls=(document.getElementById('ap-class')||{}).value, sub=(document.getElementById('ap-subject')||{}).value;
    if(!cls||!sub){ toast('Pick a class AND subject first.','warning'); return; }
    try{ await AssignmentCBT.uiSyncAll(); }catch(e){ if(origPull) return await origPull.call(AP); throw e; }
  };

  const origScoreModal=AP.scoreModal;
  AP.scoreModal=async function(assignmentId){
    if(!window.sb){ toast('Database not configured','warning'); return; }
    if(String(assignmentId).startsWith('virtual-')){
      const realCbtId=String(assignmentId).replace('virtual-','');
      if(realCbtId) return await AssignmentCBT.uiScoreCBT(realCbtId);
    }
    try{
      const {data:ass}=await sb.from('assignments').select('id,title,class,subject,cbt_exam_id,is_cbt,source').eq('id', assignmentId).maybeSingle();
      if(ass && (ass.is_cbt || ass.cbt_exam_id)){
        const realCbtId=ass.cbt_exam_id;
        if(realCbtId) return await AssignmentCBT.uiScoreCBT(realCbtId);
      }
    }catch(_){}
    return await origScoreModal.call(AP, assignmentId);
  };

  const origMatrix=AP.matrix;
  AP.matrix=async function(){
    const cls=(document.getElementById('ap-class')||{}).value,sub=(document.getElementById('ap-subject')||{}).value;
    const box=document.getElementById('ap-totals');
    if(!cls||!sub){box.innerHTML='<p style="color:var(--gray-500)">Pick a class AND subject first.</p>';return;}
    let cp={};try{cp=await (window.CRUD&&CRUD.currentPeriod?CRUD.currentPeriod():{});}catch(_){ }
    // V12.15: robust term score sheet — includes MULTI-SUBJECT containing subject + term/session robust (null term allowed)
    // Fetches all for class, then client filters by subject containment + term/session (null allowed) so multi-subject scores always show
    let q=sb.from('assignment_scores').select('*').eq('class',cls).limit(8000);
    const r=await q;
    if(r.error){box.innerHTML='<p style="color:#b91c1c">'+AP.esc(r.error.message)+'</p>';return;}
    let scores=(r.data||[]).filter(s=>{
      const sSubj = String(s.subject||'').toLowerCase();
      const req = String(sub||'').toLowerCase();
      if(req){
        if(sSubj!==req && !sSubj.includes(req)) return false;
      }
      // Term/session filter — allow null term/session (pre-existing) or matching current period
      if(cp.term){
        const sTerm=String(s.term||'').toLowerCase();
        const cTerm=String(cp.term||'').toLowerCase();
        if(sTerm && cTerm && sTerm!==cTerm) return false;
      }
      if(cp.session){
        const sSess=String(s.session||'').toLowerCase();
        const cSess=String(cp.session||'').toLowerCase();
        if(sSess && cSess && sSess!==cSess) return false;
      }
      return true;
    });
    if(!scores.length){box.innerHTML='<p style="color:var(--gray-500)">No assignment scores yet for '+AP.esc(cls)+' · '+AP.esc(sub)+' this term. Use ✍️ Score class on assignments above or auto-fill CBT assignments (single + multi containing '+AP.esc(sub)+').</p>';return;}
    const aids=[...new Set(scores.map(x=>x.assignment_id).filter(Boolean))];
    const cbtIds=[...new Set(scores.map(x=>x.cbt_exam_id).filter(Boolean))];
    let titles={};
    if(aids.length){const ar=await sb.from('assignments').select('id,title,cbt_exam_id,is_cbt,subject').in('id',aids);(ar.data||[]).forEach(a=>{titles[a.id]= (a.is_cbt? '🖥️ ':'📄 ') + (a.title||'Assignment')+' ('+(a.subject||'')+')';});}
    if(cbtIds.length){
      const cr=await sb.from('cbt_exams').select('id,code,title,subject,anti_cheat_config').in('id',cbtIds);
      (cr.data||[]).forEach(c=>{ 
        const subjLabel = AssignmentCBT.isMultiSubject(c) ? AssignmentCBT.getMultiSubjects(c).join(', ') : (c.subject||'');
        titles[c.id]= '🖥️ '+ (c.title||c.code||'CBT Assignment')+' ('+subjLabel+')'; 
        (scores.filter(s=>s.cbt_exam_id===c.id && s.assignment_id)).forEach(s=>{ if(!titles[s.assignment_id]) titles[s.assignment_id]=titles[c.id]; }); 
      });
    }
    // V12.14: for multi-subject, each cbt_exam_id|subject is separate column key (cumulative per subject)
    const colKeysSet=new Set();
    scores.forEach(x=>{ 
      if(x.cbt_exam_id && x.subject){
        // For multi-subject, separate column per cbt_exam_id|subject
        colKeysSet.add(x.cbt_exam_id+'|'+x.subject);
      }else if(x.cbt_exam_id) colKeysSet.add(x.cbt_exam_id); 
      else if(x.assignment_id) colKeysSet.add(x.assignment_id); 
      else colKeysSet.add('orphan'); 
    });
    const colKeys=[...colKeysSet];
    const colLabel=k=>{ 
      if(k==='orphan') return '📄 Assignment (legacy)'; 
      if(k.includes('|')){
        const [cbtId, subj] = k.split('|');
        return (titles[cbtId]||'🖥️ CBT Assignment')+' — '+subj;
      }
      return titles[k] || (k.startsWith('virtual-')? '🖥️ CBT Assignment' : '📄 Assignment'); 
    };
    const studs=(await sb.from('students').select('id,full_name,admission_no').eq('class',cls).order('full_name')).data||[];
    const byStud={};
    scores.forEach(x=>{
      const sid=String(x.student_id);
      (byStud[sid]=byStud[sid]||{});
      const ck = x.cbt_exam_id ? (x.subject ? x.cbt_exam_id+'|'+x.subject : x.cbt_exam_id) : (x.assignment_id || 'orphan');
      (byStud[sid][ck]=byStud[sid][ck]||{got:0,max:0,count:0});
      byStud[sid][ck].got+=Number(x.score)||0;
      byStud[sid][ck].max+=Number(x.max_score)||0;
      byStud[sid][ck].count++;
    });
    let h='<div class="table-wrap" id="ap-matrix-print"><h4 style="margin:6px 0">📋 Term score sheet · '+AP.esc(cls)+' · '+AP.esc(sub)+(cp.term?' · '+AP.esc(cp.term):'')+(cp.session?' · '+AP.esc(cp.session):'')+'</h4>';
    h+='<p style="font-size:.82rem;color:#475569">📄 = Physical/manual · 🖥️ = CBT Assignment (auto-marked, multiple per term, per subject for multi). Each column is ONE assignment (or ONE subject of a multi-assignment); Total accumulates ALL → push to Assignment column per subject. Multi-subject assignments show per subject (e.g., Maths — Assignment1, English — Assignment1) and accumulate cumulatively.</p>';
    h+='<table><thead><tr><th>Student</th>'+colKeys.map(k=>'<th style="font-size:.72rem;min-width:90px">'+AP.esc(colLabel(k)).slice(0,40)+'</th>').join('')+'<th>Total</th><th>%</th></tr></thead><tbody>';
    studs.forEach(s0=>{
      const row=byStud[String(s0.id)]||{};
      let got=0,max=0;
      Object.values(row).forEach(c=>{ got+=c.got; max+=c.max; });
      h+='<tr><td><b>'+AP.esc(s0.full_name)+'</b><br><small>'+AP.esc(s0.admission_no||'')+'</small></td>'+colKeys.map(k=>{
        const c=row[k];
        if(c){ return '<td>'+c.got+'/'+c.max+'</td>'; }
        return '<td style="color:#cbd5e1">—</td>';
      }).join('')+'<td><b>'+got+' / '+max+'</b></td><td><b>'+(max?Math.round(got/max*1000)/10:0)+'%</b></td></tr>';
    });
    h+='</tbody></table></div><p style="font-size:.78rem;color:#64748b;margin:6px 0 0">Each CBT assignment is a separate column — for multi-subject, each subject of the multi-assignment is a separate column (e.g., Maths Assignment1, English Assignment1) — all accumulate per subject → Assignment column.</p><div style="margin-top:8px;display:flex;gap:8px"><button class="btn btn-outline btn-sm" onclick="AP.printMatrix()">🖨️ Print</button><button class="btn btn-outline btn-sm" onclick="AP.exportMatrixCSV()">⬇ CSV</button><button class="btn btn-primary btn-sm" onclick="AP.pushModal()">🚀 Push totals → Report card Assignment column</button></div>';
    this._matrix={studs:studs,byStud:byStud,colKeys:colKeys,colLabel:colLabel,cls:cls,sub:sub,cp:cp, scores:scores};
    box.innerHTML=h;
  };

  // V12.15: also patch totals to be robust for multi-subject per subject + term/session null allowed
  const origTotals=AP.totals;
  AP.totals=async function(){
    const cls=(document.getElementById('ap-class')||{}).value,sub=(document.getElementById('ap-subject')||{}).value;
    const box=document.getElementById('ap-totals');
    if(!cls||!sub){box.innerHTML='<p style="color:var(--gray-500)">Pick a class AND subject first.</p>';return;}
    let cp={};try{cp=await (window.CRUD&&CRUD.currentPeriod?CRUD.currentPeriod():{});}catch(_){ }
    let q=sb.from('assignment_scores').select('*').eq('class',cls).limit(5000);
    const r=await q;
    if(r.error){box.innerHTML='<p style="color:#b91c1c">'+AP.esc(r.error.message)+'</p>';return;}
    let filtered=(r.data||[]).filter(s=>{
      const sSubj=String(s.subject||'').toLowerCase();
      const req=String(sub||'').toLowerCase();
      if(req && sSubj!==req && !sSubj.includes(req)) return false;
      if(cp.term){
        const sTerm=String(s.term||'').toLowerCase();
        const cTerm=String(cp.term||'').toLowerCase();
        if(sTerm && cTerm && sTerm!==cTerm) return false;
      }
      if(cp.session){
        const sSess=String(s.session||'').toLowerCase();
        const cSess=String(cp.session||'').toLowerCase();
        if(sSess && cSess && sSess!==cSess) return false;
      }
      return true;
    });
    const by={};filtered.forEach(x=>{const k=String(x.student_id);(by[k]=by[k]||{name:x.student_name,ref:x.student_id_ref,sid:x.student_id,got:0,max:0,n:0});by[k].got+=Number(x.score)||0;by[k].max+=Number(x.max_score)||0;by[k].n++;});
    const list=Object.values(by).sort((a,b)=>(b.got/(b.max||1))-(a.got/(a.max||1)));
    this._totals={list:list,cls:cls,sub:sub,cp:cp};
    box.innerHTML=list.length?'<div class="table-wrap"><table><thead><tr><th>Student</th><th>Assignments scored</th><th>Points</th><th>%</th></tr></thead><tbody>'+list.map(t=>'<tr><td><b>'+AP.esc(t.name)+'</b><br><small>'+AP.esc(t.ref||'')+'</small></td><td>'+t.n+'</td><td>'+t.got+' / '+t.max+'</td><td><b>'+(t.max?Math.round(t.got/t.max*1000)/10:0)+'%</b></td></tr>').join('')+'</tbody></table></div>':'<p style="color:var(--gray-500)">No assignment scores recorded yet for '+AP.esc(cls)+' · '+AP.esc(sub)+(cp.term?' · '+AP.esc(cp.term):'')+'. Use ✍️ Score class on an assignment above (single + multi containing '+AP.esc(sub)+').</p>';
  };

  // Patch CRUD for student Take buttons — robust, self-contained, all-inclusive, seamless
  try{
    const origRender=window.CRUD && window.CRUD.renderList;
    if(window.CRUD && !window.CRUD._cbtAssignPatched){
      const base=window.CRUD.renderList.bind(window.CRUD);
      window.CRUD.renderList=async function(moduleId, opts){
        const res=await base(moduleId, opts);
        if(moduleId==='assignments'){
          setTimeout(()=>{ AssignmentCBT.injectStudentLinks(); }, 800);
        }
        return res;
      };
      window.CRUD._cbtAssignPatched=true;
    }
  }catch(_){}
};

window.AssignmentCBT = AssignmentCBT;
document.addEventListener('DOMContentLoaded', ()=>{
  setTimeout(()=>{
    AssignmentCBT.init(typeof sb!=='undefined'?sb:null);
    if(window.AP) AssignmentCBT.patchAP();
    AssignmentCBT.renderCBTSection();
    AssignmentCBT.injectStudentLinks();
  }, 900);
});
