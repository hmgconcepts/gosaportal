/* ====================================================================
   demo-sample-data.js — School Connect V6.7 One-Click Sample Data
   ====================================================================
   Fills every showcase page with believable rows WITHOUT the SQL editor:
   an admin clicks ONE button on Admin Data and the loader tops up any
   sparse table (payroll, inventory, application links, messages,
   assignments, behaviour, support plans, library, help-desk,
   gamification, cafeteria, lost&found, PTA...). Fully idempotent: each
   block is skipped when the table already has enough rows, so clicking
   twice never duplicates. Intended for DEMO deployments; it is admin-
   gated and every insert passes normal RLS.
   ==================================================================== */
const DemoSampleData = {
  sb(){ return window.sb || null; },
  log: [],
  async need(table, min){ const r = await this.sb().from(table).select('id',{count:'exact',head:true}); if (r.error) { this.log.push(table+': skipped ('+r.error.message+')'); return false; } return (r.count||0) < min; },
  async put(table, rows, label){ const r = await this.sb().from(table).insert(rows); this.log.push((label||table)+': '+(r.error ? '⚠ '+r.error.message : '✅ '+rows.length+' row(s) added')); },
  async run(onProgress){
    if (!this.sb()) throw new Error('Database not configured.');
    this.log = [];
    const step = async (name, fn) => { try { await fn(); } catch(e){ this.log.push(name+': ⚠ '+(e.message||e)); } if (onProgress) onProgress(this.log); };
    const me = (window.SC_PROFILE||{}).id || null;
    const studs = (await this.sb().from('students').select('id,full_name,class,admission_no').limit(6)).data || [];
    const staff = (await this.sb().from('staff').select('id,full_name,staff_no').limit(4)).data || [];
    const s0 = studs[0]||{}, s1 = studs[1]||s0, s2 = studs[2]||s0;

    await step('payroll', async()=>{ if (!await this.need('payroll',4)) return;
      await this.put('payroll', staff.slice(0,4).map((t,i)=>({staff_id:t.id,staff_name:t.full_name,month:'June',year:2026,basic:150000+i*10000,allowances:20000,tax:10000,pension:12000,net_pay:148000+i*10000,method:'bank transfer',status:'paid'})), 'Payroll (June run)'); });
    await step('inventory', async()=>{ if (!await this.need('inventory',6)) return;
      await this.put('inventory',[
        {item_name:'HP ProBook laptop',category:'ICT',asset_tag:'ICT-001',quantity:6,location:'ICT Laboratory',condition:'good',unit_cost:420000},
        {item_name:'Epson projector',category:'ICT',asset_tag:'ICT-002',quantity:2,location:'Staff Room',condition:'good',unit_cost:250000},
        {item_name:'Science microscope',category:'Laboratory',asset_tag:'LAB-014',quantity:8,location:'Science Lab',condition:'fair',unit_cost:95000},
        {item_name:'Student desk & chair set',category:'Furniture',asset_tag:'FUR-101',quantity:120,location:'Classrooms',condition:'good',unit_cost:18000},
        {item_name:'55-seater school bus',category:'Transport',asset_tag:'TRN-001',quantity:1,location:'Car park',condition:'good',unit_cost:28000000},
        {item_name:'Standby generator 20KVA',category:'Facilities',asset_tag:'FAC-003',quantity:1,location:'Generator house',condition:'needs service',unit_cost:3500000}], 'Inventory (asset register)'); });
    await step('admission_links', async()=>{ if (!await this.need('admission_links',2)) return;
      await this.put('admission_links',[
        {label:'2026/2027 JSS 1 Entrance Intake',applying_for_class:'JSS 1',session:'2026/2027',active:true},
        {label:'2025/2026 SS 1 Transfer Window (closed)',applying_for_class:'SS 1',session:'2025/2026',active:false}], 'Application links'); });
    await step('assignments', async()=>{ if (!await this.need('assignments',4)) return;
      const d=(n)=>new Date(Date.now()+n*86400000).toISOString().slice(0,10);
      await this.put('assignments',[
        {title:'Essay: My Role Model',description:'Write a 400-word argumentative essay. Submit as a Drive link.',class:'SS 2',subject:'English Language',due_date:d(5),posted_by:me,drive_link:'https://drive.google.com/'},
        {title:'Simultaneous Equations Worksheet',description:'Questions 1–15, elimination and substitution methods.',class:'SS 2',subject:'Mathematics',due_date:d(3),posted_by:me,drive_link:'https://drive.google.com/'},
        {title:'States of Matter Poster',description:'Draw and label the three states of matter with examples.',class:'JSS 1',subject:'Basic Science',due_date:d(7),posted_by:me},
        {title:'Civic Education Group Project',description:'Rights and duties of a citizen — one link per group.',class:'JSS 3',subject:'Civic Education',due_date:d(10),posted_by:me,drive_link:'https://drive.google.com/'}], 'Assignments'); });
    await step('behaviour_points', async()=>{ if (!studs.length || !await this.need('behaviour_points',4)) return;
      await this.put('behaviour_points',[
        {student_id:s0.id,points:10,reason:'Led the class study group all week',badge:'⭐ Star Leader',awarded_by:me},
        {student_id:s1.id,points:5,reason:'Volunteered to clean the laboratory',badge:'🤝 Helping Hand',awarded_by:me},
        {student_id:s2.id,points:8,reason:'Perfect punctuality this month',badge:'⏰ Always Early',awarded_by:me},
        {student_id:s0.id,points:-3,reason:'Late submission of two assignments',awarded_by:me}], 'Behaviour points'); });
    await step('support_plans', async()=>{ if (!studs.length || !await this.need('support_plans',3)) return;
      const d=(n)=>new Date(Date.now()+n*86400000).toISOString().slice(0,10);
      await this.put('support_plans',[
        {student_id:s1.id,need_type:'Reading fluency',intervention:'20 minutes guided reading, three times weekly.',goal:'Reach age-appropriate fluency by end of first term.',review_date:d(30),outcome:'Improving — moved up one reading band.',status:'active'},
        {student_id:s2.id,need_type:'Mathematics anxiety',intervention:'Small-group numeracy club + weekly confidence check-in.',goal:'Attempt all test questions without skipping.',review_date:d(21),status:'review'},
        {student_id:s0.id,need_type:'Speech support',intervention:'External speech-therapist referral; seating adjustment.',goal:'Clear participation in class reading.',review_date:d(45),outcome:'Closed after successful review.',status:'closed'}], 'Support plans'); });
    await step('library', async()=>{ if (!await this.need('library',6)) return;
      await this.put('library',[
        {title:'Things Fall Apart',author:'Chinua Achebe',isbn:'978-0385474542',category:'Literature',copies:12,lent:3},
        {title:'New General Mathematics SS2',author:'M. F. Macrae',isbn:'978-9781255429',category:'Mathematics',copies:30,lent:11},
        {title:'Intensive English for SSS',author:'P. O. Olatunbosun',isbn:'978-9781234567',category:'English',copies:25,lent:6},
        {title:'Essential Biology',author:'M. C. Michael',isbn:'978-9785401234',category:'Sciences',copies:20,lent:4},
        {title:'Junior Atlas for Nigerian Schools',author:'Macmillan',isbn:'978-0333456789',category:'Reference',copies:15,lent:0},
        {title:'Civic Education for Secondary Schools',author:'S. A. Adeyemi',isbn:'978-9788765432',category:'Humanities',copies:18,lent:2}], 'Library catalogue'); });
    await step('helpdesk_tickets', async()=>{ if (!await this.need('helpdesk_tickets',4)) return;
      await this.put('helpdesk_tickets',[
        {category:'IT / computer',subject:'Projector in SS2 not displaying',body:'Screen flickers then goes blank after 5 minutes.',priority:'high',status:'in_progress',submitted_by:me},
        {category:'plumbing',subject:'Leaking tap in junior block',body:'Water wastage near the JSS toilets.',priority:'normal',status:'open',submitted_by:me},
        {category:'electrical',subject:'Faulty socket in science lab',body:'Sparks when the microscope charger is plugged in.',priority:'urgent',status:'resolved',submitted_by:me},
        {category:'furniture',subject:'Broken chairs in JSS 1B',body:'Four chairs need repair before resumption.',priority:'low',status:'open',submitted_by:me}], 'Help-desk tickets'); });
    await step('staff_bonus', async()=>{ if (!await this.need('staff_bonus',2)) return;
      const d=(n)=>new Date(Date.now()-n*86400000).toISOString().slice(0,10);
      await this.put('staff_bonus',[
        {staff_name:(staff[0]||{}).full_name||'Funke Alabi',bonus_type:'performance',amount:25000,reason:'Best WAEC Mathematics results in three years',award_date:d(20),status:'paid'},
        {staff_name:(staff[1]||{}).full_name||'Chukwuemeka Nwachukwu',bonus_type:'extra duty',amount:10000,reason:'Coordinated inter-house sports',award_date:d(12),status:'approved'}], 'Staff bonuses'); });
    // module_records powered pages (messages/inbox, gamification, cafeteria, lost & found, PTA)
    const mr = async (module, rows, label) => {
      const r = await this.sb().from('module_records').select('id',{count:'exact',head:true}).eq('module',module);
      if (!r.error && (r.count||0) >= rows.length) { return; }
      await this.put('module_records', rows.map(x=>Object.assign({module:module,created_by:me},x)), label);
    };
    await step('inbox', ()=>mr('inbox',[
      {title:'Welcome to the portal',body:'Explore results, fees, CBT and the report cards — everything is live sample data.',audience:'all',status:'read'},
      {title:'PTA meeting reminder',body:'The third-term PTA meeting holds next Saturday at 10:00 in the school hall.',audience:'parent',status:'unread'},
      {title:'Submit scheme of work',body:'All teachers should tick their covered topics before Friday.',audience:'staff',status:'unread'}],'Inbox messages'));
    await step('gamification', ()=>mr('gamification',[
      {title:'Blue House — Inter-house Quiz Champions',body:'Blue House won the third-term inter-house quiz.',status:'awarded',data:{house:'Blue',points:50}},
      {title:'Reading Challenge — 1000 Pages Club',body:'Twelve students completed the reading challenge.',status:'awarded',data:{badge:'1000 Pages',points:25}}],'Gamification'));
    await step('cafeteria', ()=>mr('cafeteria',[
      {title:'Jollof rice & grilled chicken',body:'Wednesday lunch — contains groundnut oil.',status:'planned',ref_date:new Date(Date.now()+86400000).toISOString().slice(0,10),data:{allergens:['groundnut']}},
      {title:'Beans porridge & plantain',body:'Friday lunch — vegetarian option available.',status:'planned',ref_date:new Date(Date.now()+3*86400000).toISOString().slice(0,10),data:{allergens:[]}}],'Cafeteria menu'));
    await step('lost_found', ()=>mr('lost_found',[
      {title:'Blue water bottle (found)',body:'Found near the assembly ground after Friday sports.',status:'unclaimed'},
      {title:'Casio fx-991 calculator (lost)',body:'Reported missing by an SS2 student.',status:'searching'}],'Lost & found'));
    await step('parent_meeting', ()=>mr('parent_meeting',[
      {title:'Third-Term PTA General Meeting',body:'Agenda: results review, resumption dates, development levy update.',status:'scheduled',ref_date:new Date(Date.now()+14*86400000).toISOString().slice(0,10),data:{venue:'School hall',time:'10:00'}}],'PTA meetings'));
    return this.log;
  }
};
window.DemoSampleData = DemoSampleData;

/* DEMO AUTO-FILL: on demo deployments the sample loader runs by itself the
   moment an admin/teacher opens any page — prospects never see empty pages.
   Idempotent (tables with data are skipped) + once-per-day per device. */
(function(){
  let tries=0;
  const tick=async()=>{
    tries++;
    try{
      const demo=window.SCHOOL&&window.SCHOOL.demo&&window.SCHOOL.demo.enabled;
      if(!demo){return;}
      const p=window.SC_PROFILE;
      if(!p||!p.role){ if(tries<25) setTimeout(tick,1200); return; }
      const role=String(p.role).toLowerCase();
      if(!['super_admin','admin','principal','proprietor','head_teacher','bursar','staff','teacher'].includes(role)) return;
      const KEY='sc-demo-autofill-at';
      if(Date.now()-(+localStorage.getItem(KEY)||0) < 24*3600000) return;
      localStorage.setItem(KEY,String(Date.now()));
      const log=await DemoSampleData.run();
      const added=log.filter(x=>x.includes('✅')).length;
      if(added&&typeof toast==='function') toast('🎬 Demo sample data topped up automatically ('+added+' section(s)). Every page now has live rows.','info',7000);
    }catch(e){ console.warn('[DemoSampleData] auto-fill skipped:',e.message||e); }
  };
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',()=>setTimeout(tick,2500));
  else setTimeout(tick,2500);
})();

