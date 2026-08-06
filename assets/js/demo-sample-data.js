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
    /* ---- V7.5 breadth: every remaining showcase page gets believable rows ---- */
    await step('staff_loans', async()=>{ if (!staff.length || !await this.need('staff_loans',2)) return;
      await this.put('staff_loans',[
        {staff_name:(staff[0]||{}).full_name||'Staff Member',loan_type:'personal loan',principal:150000,monthly_repayment:15000,months:10,amount_repaid:60000,date_taken:new Date(Date.now()-120*86400000).toISOString().slice(0,10),status:'active',notes:'Laptop purchase support, approved by proprietor.'},
        {staff_name:(staff[1]||staff[0]||{}).full_name||'Staff Member',loan_type:'emergency',principal:80000,monthly_repayment:10000,months:8,amount_repaid:80000,date_taken:new Date(Date.now()-300*86400000).toISOString().slice(0,10),status:'completed',notes:'Medical advance, fully repaid.'}], 'Staff loans'); });
    await step('staff_appraisals', async()=>{ if (!staff.length || !await this.need('staff_appraisals',2)) return;
      await this.put('staff_appraisals',[
        {staff_name:(staff[0]||{}).full_name||'Staff Member',period:'Current session',punctuality:9,teaching_quality:10,student_results:9,teamwork:9,conduct:10,total_score:'9.4 — Outstanding',recommendation:'commend',comments:'Outstanding lesson delivery; class average rose 14% this session.'},
        {staff_name:(staff[1]||staff[0]||{}).full_name||'Staff Member',period:'Current session',punctuality:7,teaching_quality:8,student_results:8,teamwork:9,conduct:9,total_score:'8.2 — Very Good',recommendation:'train',comments:'Strong classroom management; recommend ICT-integration training.'}], 'Staff appraisals'); });
    await step('promotions', async()=>{ if (!studs.length || !await this.need('promotions',3)) return;
      let ladder=[], cp={};
      try { ladder = await (window.CRUD && CRUD.classLadder ? CRUD.classLadder() : []); } catch(_){ }
      try { cp = await (window.CRUD && CRUD.currentPeriod ? CRUD.currentPeriod() : {}); } catch(_){ }
      const nextOf=(c)=>{const i=ladder.findIndex(x=>String(x).toLowerCase()===String(c||'').toLowerCase());return i<0?'':(i>=ladder.length-1?'GRADUATED':ladder[i+1]);};
      const rows = studs.slice(0,5).map((s,i)=>({student_id:s.id,student_name:s.full_name,from_class:s.class,
        to_class:(i===2? s.class : (nextOf(s.class)||'')),action:(i===2?'repeat':(nextOf(s.class)==='GRADUATED'?'graduate':'promote')),
        average:(i===2?41:70+i*5),status:(i===4?'applied':'pending'),term:cp.term||null,session:cp.session||null}));
      await this.put('promotions', rows, 'Promotion drafts'); });
    await step('module_records breadth', ()=>Promise.all([
      mr('front_desk',[
        {title:'Prospectus enquiry — walk-in',body:'Parent asked about JSS 1 admission requirements; prospectus issued.',data:{kind:'walk-in',contact:'0803 555 1122'},ref_date:new Date().toISOString().slice(0,10)},
        {title:'Courier dispatch — WAEC forms',body:'WAEC registration forms dispatched to zonal office via courier.',data:{kind:'dispatch',contact:'Courier waybill 4491'}}],'Front desk'),
      mr('broadcast',[
        {title:'Results released',body:'Dear parents, term results are now on the portal. Log in to view your child\u2019s report card.',data:{channel:'whatsapp',audience:'parents'},status:'sent'},
        {title:'Resumption reminder',body:'School resumes soon — the fees portal is open.',data:{channel:'sms',audience:'all'},status:'queued'}],'Broadcasts'),
      mr('reports',[{title:'Termly enrolment summary',body:'Active students, staff strength, attendance rate and fee collection at a glance.',data:{type:'termly'},ref_date:new Date().toISOString().slice(0,10)}],'Reports'),
      mr('lms',[
        {title:'Quadratic Equations — video lesson',body:'Watch the worked examples then attempt the practice set.',data:{subject:'Mathematics',class:(s0.class||'SS 2'),video:'https://drive.google.com/'}},
        {title:'Photosynthesis explained',body:'Full topic notes with diagram labelling task.',data:{subject:'Biology',class:(s1.class||'SS 1'),video:'https://drive.google.com/'}}],'LMS lessons'),
      mr('document_builder',[{title:'Fee clearance letter',body:'This is to certify that [NAME] of [CLASS] has cleared all fees for [TERM], [SESSION].',data:{type:'fee clearance',student:s0.full_name||'',class:s0.class||'',signatory_role:'Principal',reference:'FC/'+new Date().getFullYear()+'/014'},status:'issued'}],'Document builder'),
      mr('facility_booking',[
        {title:'School hall — PTA meeting',ref_date:new Date(Date.now()+9*86400000).toISOString().slice(0,10),data:{time:'10:00',bookedby:'PTA Secretary'},status:'approved'},
        {title:'Football pitch — inter-house practice',ref_date:new Date(Date.now()+14*86400000).toISOString().slice(0,10),data:{time:'14:00',bookedby:'Games Master'},status:'requested'}],'Facility bookings'),
      mr('compliance',[
        {title:'Fire extinguisher service',data:{category:'fire drill'},ref_date:new Date(Date.now()+26*86400000).toISOString().slice(0,10),status:'due',body:'Annual service of all extinguishers.'},
        {title:'Ministry of Education inspection',data:{category:'inspection'},status:'passed',body:'Passed with commendation on record keeping.'}],'Compliance'),
      mr('fleet_tracking',[{title:'Bus 1 — morning route',data:{driver:'School driver'},body:'Morning run completed 07:42; evening run departs 15:30.',ref_date:new Date().toISOString().slice(0,10)}],'Fleet log'),
      mr('transcripts',[{title:'Session transcript',data:{student:s0.full_name||'',term:'Third Term',gpa:'4.2 / 5.0',remark:'Excellent — top 5% of class'},body:'Mathematics A, English B2, Physics B3, Chemistry A, Biology B2.'}],'Transcripts'),
      mr('transfer_cert',[{title:'TC/'+new Date().getFullYear()+'/003',data:{student:s2.full_name||'',last_class:s2.class||'',reason:'relocation',conduct:'good'},body:'Family relocated. All fees cleared.',ref_date:new Date().toISOString().slice(0,10)}],'Transfer certificates'),
      mr('counselling',[{title:'Exam anxiety session',data:{student:s1.full_name||'',counsellor:'School counsellor'},status:'closed',body:'Two sessions held; coping strategies working well.'}],'Counselling'),
      mr('rubrics',[{title:'Argumentative essay rubric',data:{subject:'English Language',class:(s0.class||'SS 2'),criteria:'Thesis clarity\nEvidence & examples\nOrganisation\nGrammar & mechanics',scale:'1-4 (Beginning–Exceeding)'},body:'Used for all continuous-assessment essays.'}],'Rubrics'),
      mr('career_counseling',[{title:'University guidance — sciences',data:{student:s0.full_name||'',university:'University of Lagos — Medicine'},body:'JAMB subject combination confirmed; mock UTME booked.'}],'Career counselling'),
      mr('financial_aid',[{title:'Proprietor\u2019s Scholarship',data:{student:s2.full_name||''},amount:75000,status:'approved',body:'50% tuition waiver for academic excellence.'}],'Financial aid'),
      mr('book_request',[{title:'Further Mathematics — Egbe et al',data:{student:s1.full_name||''},status:'reserved',ref_date:new Date().toISOString().slice(0,10)}],'Book requests'),
      mr('school_calendar',[{title:'Next term resumption',ref_date:new Date(Date.now()+40*86400000).toISOString().slice(0,10),data:{category:'term-start'},body:'All students resume; boarding house opens the day before.'}],'School calendar'),
      mr('messages',[
        {title:'Revision groups announced',body:'Revision groups meet in the library every Tuesday before mock exams.',audience:'student',data:{to:'All students'}},
        {title:'Fee balance reminder',body:'Dear parents, kindly clear outstanding balances before the PTA meeting.',audience:'parent',data:{to:'All parents'}}],'Messages')
    ]));
    await step('eresources', async()=>{ if (!await this.need('eresources',3)) return;
      await this.put('eresources',[
        {title:'WAEC Past Questions — Mathematics',description:'Five years of past questions with chief examiner reports.',subject:'Mathematics',class:'SS 3',term:'Third Term',drive_link:'https://drive.google.com/'},
        {title:'Phonics drill audio pack',description:'Daily 10-minute drills for early readers.',subject:'English Language',class:'JSS 1',term:'Third Term',drive_link:'https://drive.google.com/'}], 'E-resources'); });
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
      const log=await DemoSampleData.run();
      const added=log.filter(x=>x.includes('✅')).length;
      /* V7.2: stamp AFTER a successful run — a failed/blocked attempt (e.g. RLS
         before sign-in resolved, network drop) can retry on the next page. */
      localStorage.setItem(KEY,String(Date.now()));
      if(added&&typeof toast==='function') toast('🎬 Demo sample data topped up automatically ('+added+' section(s)). Every page now has live rows.','info',7000);
    }catch(e){ console.warn('[DemoSampleData] auto-fill skipped:',e.message||e); }
  };
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',()=>setTimeout(tick,2500));
  else setTimeout(tick,2500);
})();


/* DEMO EMPTY-STATE BANNER: if key showcase tables are empty on a demo deployment,
   admins see an unmissable banner with a one-click loader — no hunting for the card. */
(function(){
  let tries=0;
  const check=async()=>{
    tries++;
    try{
      const demo=window.SCHOOL&&window.SCHOOL.demo&&window.SCHOOL.demo.enabled;
      if(!demo||!window.sb)return;
      const p=window.SC_PROFILE;
      if(!p||!p.role){ if(tries<20) setTimeout(check,1500); return; }
      if(!['super_admin','admin','principal','proprietor','head_teacher','bursar'].includes(String(p.role).toLowerCase()))return;
      if(document.getElementById('sc-demo-empty-banner'))return;
      const r=await window.sb.from('payroll').select('id',{count:'exact',head:true});
      const r2=await window.sb.from('library').select('id',{count:'exact',head:true});
      if((r.count||0)>0&&(r2.count||0)>0)return;                    // demo already looks alive
      const bar=document.createElement('div');
      bar.id='sc-demo-empty-banner';
      bar.setAttribute('style','position:fixed;left:0;right:0;bottom:0;z-index:9990;background:linear-gradient(90deg,#7c3aed,#4f46e5);color:#fff;padding:10px 16px;display:flex;gap:12px;align-items:center;justify-content:center;flex-wrap:wrap;font-size:.95rem;box-shadow:0 -6px 20px rgba(0,0,0,.25)');
      bar.innerHTML='<span>🎬 <b>Demo looks empty?</b> Load believable sample data on every page (payroll, inventory, library, messages, assignments…) in one click.</span>'+
        '<button id="sc-demo-fill-btn" style="background:#fff;color:#4f46e5;border:0;border-radius:10px;padding:8px 18px;font-weight:800;cursor:pointer">Load sample data now</button>'+
        '<button onclick="this.parentNode.remove()" style="background:transparent;color:#e0e7ff;border:1px solid rgba(255,255,255,.5);border-radius:10px;padding:8px 12px;cursor:pointer">Later</button>';
      document.body.appendChild(bar);
      document.getElementById('sc-demo-fill-btn').onclick=async function(){
        this.disabled=true;this.textContent='Loading…';
        try{const log=await DemoSampleData.run();const added=log.filter(x=>x.includes('✅')).length;
          if(typeof toast==='function')toast('🎬 Sample data loaded ('+added+' section(s)). Open any page to see it live.','success',8000);
          bar.remove(); if(window.CRUD&&location.pathname.match(/(payroll|inventory|library|assignments|messages)/))location.reload();
        }catch(e){this.disabled=false;this.textContent='Load sample data now';if(typeof toast==='function')toast(e.message||e,'danger',8000);}
      };
    }catch(e){/* silent */}
  };
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>setTimeout(check,3200));
  else setTimeout(check,3200);
})();
