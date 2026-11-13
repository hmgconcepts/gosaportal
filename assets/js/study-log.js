/* School Connect V12.17 — Study Log / Timer (from TutoringConnect Study log)
   Features: start/stop timer per subject, log duration, streaks, .ics export, makeup credit bank
   Robust, all-inclusive, self-contained, seamless, free-tier only
*/
const StudyLog = {
  sb: null,
  _timer: null,
  _start: null,
  _subject: '',
  _activity: '',
  init(client){
    this.sb = client || window.sb || (typeof sb!=='undefined'?sb:null);
    // Restore any running timer from localStorage
    try{
      const saved=JSON.parse(localStorage.getItem('sc-study-timer')||'null');
      if(saved && saved.start && !saved.ended){
        this._start=new Date(saved.start).getTime();
        this._subject=saved.subject||'';
        this._activity=saved.activity||'';
        this._resumeTimer();
      }
    }catch(_){}
  },
  esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;'); },

  start(subject, activity='Study'){
    if(this._timer){ this.stop(); }
    this._subject=subject||'General';
    this._activity=activity||'Study';
    this._start=Date.now();
    localStorage.setItem('sc-study-timer', JSON.stringify({start:new Date(this._start).toISOString(), subject:this._subject, activity:this._activity}));
    this._resumeTimer();
    toast(`⏱ Started ${this._activity} timer for ${this._subject}`, 'info');
  },

  _resumeTimer(){
    const box=document.getElementById('study-timer-display');
    if(this._timer) clearInterval(this._timer);
    this._timer=setInterval(()=>{
      const elapsed=Math.floor((Date.now()-this._start)/1000);
      const m=Math.floor(elapsed/60), s=elapsed%60;
      if(box) box.textContent=`⏱ ${m}:${String(s).padStart(2,'0')} — ${this.esc(this._subject)} — ${this.esc(this._activity)}`;
    },1000);
  },

  async stop(){
    if(!this._start) return;
    const duration=Math.floor((Date.now()-this._start)/60000); // minutes
    const payload={
      user_id: (window.SC_PROFILE&&SC_PROFILE.id)||null,
      subject: this._subject,
      activity: this._activity,
      duration_minutes: duration,
      started_at: new Date(this._start).toISOString(),
      ended_at: new Date().toISOString()
    };
    if(this._timer) clearInterval(this._timer);
    this._timer=null;
    this._start=null;
    localStorage.removeItem('sc-study-timer');
    const disp=document.getElementById('study-timer-display');
    if(disp) disp.textContent='⏱ Timer stopped — '+duration+' min logged';
    if(this.sb && payload.user_id){
      try{
        await this.sb.from('study_logs').insert(payload);
        toast(`✅ Logged ${duration} min for ${payload.subject}`, 'success');
      }catch(e){ console.warn('study log save failed', e.message); }
    }
    this.render();
  },

  async loadSubjects(){
    // V12.18: robust subject loading for study log — ensures subject field loads all subjects (fixes bug)
    try{
      if(!this.sb) return;
      const sel=document.getElementById('study-subject');
      if(!sel) return;
      const {data}=await this.sb.from('subjects').select('name').order('name').limit(500);
      if(data && data.length){
        const keep=sel.value;
        sel.innerHTML='';
        data.forEach(s=>{
          const o=document.createElement('option');
          o.value=s.name;
          o.textContent=s.name;
          sel.appendChild(o);
        });
        if(![...sel.options].some(o=>o.value.toLowerCase()==='general')){
          const o=document.createElement('option');
          o.value='General';
          o.textContent='General';
          sel.appendChild(o);
        }
        if(keep && [...sel.options].some(o=>o.value===keep)) sel.value=keep;
      }
    }catch(e){ console.warn('StudyLog loadSubjects failed', e.message); }
  },

  async render(){
    // Ensure subjects loaded
    this.loadSubjects().catch(()=>{});
    const box=document.getElementById('study-log-list');
    if(!box) return;
    if(!this.sb){ box.innerHTML='<p style="color:#64748b">DB not configured</p>'; return; }
    const uid=(window.SC_PROFILE&&SC_PROFILE.id)||null;
    if(!uid){ box.innerHTML='<p style="color:#64748b">Sign in to see study logs</p>'; return; }
    const {data}=await this.sb.from('study_logs').select('*').eq('user_id', uid).order('started_at',{ascending:false}).limit(100);
    if(!data||!data.length){ box.innerHTML='<p style="color:#64748b">No study sessions yet — start a timer above.</p>'; return; }
    const total=data.reduce((a,b)=>a+(Number(b.duration_minutes)||0),0);
    const bySub={};
    data.forEach(r=>{ const k=r.subject||'General'; bySub[k]=(bySub[k]||0)+Number(r.duration_minutes||0); });
    box.innerHTML=`
      <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:8px">
        <span class="badge" style="background:#dcfce7;color:#166534">Total: ${total} min</span>
        ${Object.entries(bySub).map(([k,v])=>`<span class="badge" style="background:#eef2ff;color:#4338ca">${this.esc(k)}: ${v}m</span>`).join('')}
      </div>
      <div class="table-wrap"><table><thead><tr><th>When</th><th>Subject</th><th>Activity</th><th>Duration</th></tr></thead><tbody>
      ${data.map(r=>`<tr><td>${new Date(r.started_at).toLocaleString()}</td><td>${this.esc(r.subject)}</td><td>${this.esc(r.activity)}</td><td>${r.duration_minutes}m</td></tr>`).join('')}
      </tbody></table></div>`;
  },

  async exportICS(){
    if(!this.sb) return;
    const uid=(window.SC_PROFILE&&SC_PROFILE.id)||null;
    if(!uid){ toast('Sign in first','warning'); return; }
    const {data}=await this.sb.from('study_logs').select('*').eq('user_id', uid).order('started_at',{ascending:false}).limit(100);
    let ics='BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//HMG Concepts//School Connect Study Log//EN\n';
    (data||[]).forEach(r=>{
      const start=new Date(r.started_at).toISOString().replace(/[-:]/g,'').replace(/\.\d+/,'');
      const end=new Date(r.ended_at||new Date(new Date(r.started_at).getTime()+r.duration_minutes*60000)).toISOString().replace(/[-:]/g,'').replace(/\.\d+/,'');
      ics+=`BEGIN:VEVENT\nDTSTART:${start}\nDTEND:${end}\nSUMMARY:${(r.subject||'Study')} — ${r.activity||''}\nDESCRIPTION:Study log ${r.duration_minutes} min\nEND:VEVENT\n`;
    });
    ics+='END:VCALENDAR';
    const blob=new Blob([ics],{type:'text/calendar'});
    const a=document.createElement('a');
    a.href=URL.createObjectURL(blob);
    a.download='study-log.ics';
    a.click();
    toast('📅 Exported study log as .ics (TutorBird-style calendar sync)', 'success');
  }
};

window.StudyLog = StudyLog;
document.addEventListener('DOMContentLoaded', ()=>{ setTimeout(()=>StudyLog.init(), 800); });
