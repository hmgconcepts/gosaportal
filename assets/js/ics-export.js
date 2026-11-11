/* School Connect V12.17 — ICS Calendar Export (from TutoringConnect + DramaConnect)
   Features: export timetable, assignments, CBT exams, programmes as .ics for Google Calendar / Outlook / Apple
   Robust, all-inclusive, self-contained, seamless, no paid API
*/
const ICSExport = {
  esc(s){ return String(s||'').replace(/[,;\n]/g,' '); },

  buildICS(events, calName='School Connect Calendar'){
    let ics='BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//HMG Concepts//School Connect//EN\nCALSCALE:GREGORIAN\nMETHOD:PUBLISH\nX-WR-CALNAME:'+this.esc(calName)+'\n';
    events.forEach(ev=>{
      const uid=(ev.uid||('sc-'+Date.now()+'-'+Math.random().toString(36).slice(2,9)))+'@schoolconnect';
      const dtstamp=new Date().toISOString().replace(/[-:]/g,'').replace(/\.\d+/,'');
      const start=this.toICSDate(ev.start);
      const end=this.toICSDate(ev.end||new Date(new Date(ev.start).getTime()+60*60*1000));
      ics+=`BEGIN:VEVENT\nUID:${uid}\nDTSTAMP:${dtstamp}\nDTSTART:${start}\nDTEND:${end}\nSUMMARY:${this.esc(ev.title||'Event')}\nDESCRIPTION:${this.esc(ev.description||'')}\nLOCATION:${this.esc(ev.location||'')}\nEND:VEVENT\n`;
    });
    ics+='END:VCALENDAR';
    return ics;
  },

  toICSDate(d){
    try{
      const dt=new Date(d);
      return dt.toISOString().replace(/[-:]/g,'').replace(/\.\d+/,'');
    }catch(_){ return new Date().toISOString().replace(/[-:]/g,'').replace(/\.\d+/,''); }
  },

  downloadICS(ics, filename='school-connect.ics'){
    const blob=new Blob([ics],{type:'text/calendar'});
    const a=document.createElement('a');
    a.href=URL.createObjectURL(blob);
    a.download=filename;
    a.click();
    if(typeof toast==='function') toast('📅 Exported '+filename+' — import into Google Calendar / Outlook', 'success', 6000);
  },

  async exportTimetable(){
    if(!window.sb){ toast('DB not configured','warning'); return; }
    const {data}=await sb.from('timetable').select('*').limit(500);
    const events=(data||[]).map(row=>{
      // Assume row has day, period, start_time, subject, class
      const dayMap={Monday:1,Tuesday:2,Wednesday:3,Thursday:4,Friday:5,Saturday:6,Sunday:0};
      const today=new Date();
      const dayNum=dayMap[row.day]||1;
      const diff=(dayNum - today.getDay() +7)%7;
      const date=new Date(today.getTime()+diff*24*60*60*1000);
      const [h,m]=String(row.start_time||'08:00').split(':').map(Number);
      date.setHours(h||8,m||0,0,0);
      return {
        title: `${row.subject||'Class'} — ${row.class||''} — ${row.teacher||''}`,
        start: date,
        description: `Timetable: ${row.class||''} ${row.subject||''} Period ${row.period||''}`,
        location: row.class||''
      };
    });
    const ics=this.buildICS(events, 'School Connect Timetable');
    this.downloadICS(ics, 'timetable.ics');
  },

  async exportAssignments(){
    if(!window.sb){ toast('DB not configured','warning'); return; }
    const {data}=await sb.from('assignments').select('*').order('due_date',{ascending:true}).limit(200);
    const events=(data||[]).filter(a=>a.due_date).map(a=>{
      const d=new Date(a.due_date);
      return {
        title: `Assignment: ${a.title||'Homework'} — ${a.class||''} ${a.subject||''}`,
        start: d,
        description: `${a.description||''} — Drive: ${a.drive_link||''}`,
        location: `${a.class||''} ${a.subject||''}`
      };
    });
    const ics=this.buildICS(events, 'School Connect Assignments');
    this.downloadICS(ics, 'assignments.ics');
  },

  async exportCBTExams(){
    if(!window.sb){ toast('DB not configured','warning'); return; }
    const {data}=await sb.from('cbt_exams').select('code,title,subject,class,start_at,close_at').eq('is_archived', false).limit(200);
    const events=(data||[]).filter(e=>e.start_at||e.close_at).map(e=>{
      const start=e.start_at?new Date(e.start_at):new Date();
      const end=e.close_at?new Date(e.close_at):new Date(start.getTime()+60*60*1000);
      return {
        title: `CBT: ${e.title||e.code} — ${e.subject||''}`,
        start,
        end,
        description: `Code: ${e.code} — Class: ${e.class||''} — ${e.subject||''}`,
        location: e.class||''
      };
    });
    const ics=this.buildICS(events, 'School Connect CBT Exams');
    this.downloadICS(ics, 'cbt-exams.ics');
  },

  async exportAll(){
    if(!window.sb){ toast('DB not configured','warning'); return; }
    const [tt, assigns, cbts] = await Promise.all([
      sb.from('timetable').select('*').limit(200).then(r=>r.data||[]).catch(()=>[]),
      sb.from('assignments').select('*').limit(200).then(r=>r.data||[]).catch(()=>[]),
      sb.from('cbt_exams').select('code,title,subject,class,start_at,close_at').eq('is_archived', false).limit(200).then(r=>r.data||[]).catch(()=>[])
    ]);
    const events=[];
    tt.forEach(row=>{
      if(!row.start_time) return;
      const dayMap={Monday:1,Tuesday:2,Wednesday:3,Thursday:4,Friday:5,Saturday:6,Sunday:0};
      const today=new Date();
      const dayNum=dayMap[row.day]||1;
      const diff=(dayNum - today.getDay() +7)%7;
      const date=new Date(today.getTime()+diff*24*60*60*1000);
      const [h,m]=String(row.start_time||'08:00').split(':').map(Number);
      date.setHours(h||8,m||0,0,0);
      events.push({title:`Timetable: ${row.subject} — ${row.class}`, start:date, description:`Period ${row.period||''}`, location:row.class||''});
    });
    assigns.filter(a=>a.due_date).forEach(a=>{
      events.push({title:`Assignment: ${a.title}`, start:new Date(a.due_date), description:a.description||'', location:`${a.class} ${a.subject}`});
    });
    cbts.filter(e=>e.start_at||e.close_at).forEach(e=>{
      events.push({title:`CBT: ${e.title||e.code}`, start:e.start_at?new Date(e.start_at):new Date(), end:e.close_at?new Date(e.close_at):undefined, description:`Code ${e.code}`, location:e.class||''});
    });
    const ics=this.buildICS(events, 'School Connect Full Calendar');
    this.downloadICS(ics, 'school-connect-full.ics');
  }
};

window.ICSExport = ICSExport;
