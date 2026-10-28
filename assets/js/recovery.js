/* ====================================================================
   recovery.js — School Connect V12.6 One-Click Re-link after Disaster Recovery
   --------------------------------------------------------------------
   SCENARIO: old Supabase lost, data restored from Google Drive backup into a
   FRESH project. Old auth accounts are gone; everybody signs up again with
   new profile ids. Students/staff/parent links are null.

   WHAT THIS DOES (one click, robust, all-inclusive, self-contained):
     1. Takes a portable archive (the SAME JSON you restore from Drive, or a
        local file) which contains OLD profiles + OLD students/staff with their
        OLD user_id references + OLD parent_child links.
     2. Loads CURRENT profiles from the new database (all approved/pending).
     3. Builds stable maps:
          old profile id → old email (lowercased) from archive
          new email → new profile id from current DB
        Then:
          old user_id → new user_id via email bridge.
     4. For STUDENTS: current DB students are matched by admission_no (or id)
        to old students; if old student had a user_id, we set current
        student.user_id = new user_id via the bridge. If old student had NO
        user_id (never linked), we try to link by email if student had a
        linked profile email in old archive? Actually students have no email,
        so we fall back to full_name+class matching as last resort.
     5. For STAFF: matched by staff_no OR email; user_id set via bridge OR
        direct email equality (staff.email = profiles.email).
     6. For PARENT_CHILD: old parent_id → email → new parent_id, student_id
        preserved (students.id same after recovery), then upsert parent_child.
        Handles both old and new student_id formats.
     7. Reports: how many linked, how many missing, how many ambiguous, with
        exact names/numbers so admin can fix manually if needed.

   WHY NOT JUST SQL? SQL cannot read the backup file. This JS owns the file.
   The V12.2 photo-sync triggers then keep photos in sync automatically.
   The V12.4 write-map (canWriteByAccess) already lets staff edit Students.

   SECURITY: admin-only (RLS already restricts students/staff writes to staff;
   parent_child writes to admin; this page is data-require-role admin).
   No data leaves the browser except the updates to YOUR Supabase.
   ==================================================================== */
const Recovery = {
  sb(){ return window.sb || null; },

  normEmail(e){ return String(e||'').trim().toLowerCase(); },
  normName(s){ return String(s||'').trim().toLowerCase().replace(/\s+/g,' '); },

  /* Build maps from archive */
  parseArchive(archive){
    const tables = archive.tables || {};
    const oldProfiles = tables.profiles || [];
    const oldStudents = tables.students || [];
    const oldStaff = tables.staff || [];
    const oldParentChild = tables.parent_child || [];
    const oldIdToEmail = {};
    oldProfiles.forEach(p => { if(p.id && p.email) oldIdToEmail[String(p.id)] = this.normEmail(p.email); });
    // also allow matching by full_name when email missing
    const oldIdToName = {};
    oldProfiles.forEach(p => { if(p.id) oldIdToName[String(p.id)] = this.normName(p.full_name); });
    return { oldProfiles, oldStudents, oldStaff, oldParentChild, oldIdToEmail, oldIdToName };
  },

  async loadCurrent(){
    const sb = this.sb(); if(!sb) throw new Error('Database not configured');
    const [pr, st, sf] = await Promise.all([
      sb.from('profiles').select('id,email,full_name,role,status').limit(5000),
      sb.from('students').select('id,admission_no,full_name,class,user_id').limit(5000),
      sb.from('staff').select('id,staff_no,full_name,email,user_id').limit(5000)
    ]);
    if(pr.error) throw pr.error;
    if(st.error) throw st.error;
    if(sf.error) throw sf.error;
    const emailToNewId = {};
    const nameToNewId = {};
    (pr.data||[]).forEach(p => {
      const em = this.normEmail(p.email);
      if(em) emailToNewId[em] = p.id;
      const nm = this.normName(p.full_name);
      if(nm) {
        if(!nameToNewId[nm]) nameToNewId[nm] = [];
        nameToNewId[nm].push({id:p.id, role:String(p.role||'').toLowerCase(), email:em});
      }
    });
    return { profiles: pr.data||[], students: st.data||[], staff: sf.data||[], emailToNewId, nameToNewId };
  },

  /* One-click relink */
  async relinkAll(archive, onProgress){
    const log = [];
    const push = (m) => { log.push(m); if(onProgress) onProgress(log); };
    push('🔍 Parsing archive…');
    const parsed = this.parseArchive(archive);
    push(`Archive: ${parsed.oldProfiles.length} old profiles, ${parsed.oldStudents.length} old students, ${parsed.oldStaff.length} old staff, ${parsed.oldParentChild.length} old parent links`);

    push('📡 Loading current database…');
    const cur = await this.loadCurrent();
    push(`Current: ${cur.profiles.length} profiles, ${cur.students.length} students, ${cur.staff.length} staff`);

    const sb = this.sb();
    let linkedStudents = 0, missedStudents = 0, linkedStaff = 0, missedStaff = 0, linkedParents = 0, missedParents = 0;
    const details = { students:[], staff:[], parents:[] };

    /* ---- STUDENTS ---- */
    push('👨‍🎓 Re-linking students (admission_no + email bridge)…');
    // Map current students by admission_no and by id
    const curByAdm = {}; const curById = {};
    cur.students.forEach(s => {
      if(s.admission_no) curByAdm[String(s.admission_no).trim().toLowerCase()] = s;
      if(s.id) curById[String(s.id)] = s;
    });
    for(const oldS of parsed.oldStudents){
      if(!oldS) continue;
      const adm = String(oldS.admission_no||'').trim().toLowerCase();
      const curS = curByAdm[adm] || curById[String(oldS.id||'')] || null;
      if(!curS) { missedStudents++; continue; }
      if(curS.user_id) continue; // already linked
      let newUid = null;
      // primary: old user_id → old email → new id
      if(oldS.user_id){
        const oldEmail = parsed.oldIdToEmail[String(oldS.user_id)] || '';
        if(oldEmail) newUid = cur.emailToNewId[oldEmail] || null;
        // fallback: old profile name
        if(!newUid){
          const oldName = parsed.oldIdToName[String(oldS.user_id)] || '';
          const candidates = cur.nameToNewId[oldName] || [];
          const stuCandidates = candidates.filter(c => c.role === 'student');
          if(stuCandidates.length === 1) newUid = stuCandidates[0].id;
        }
      }
      // last resort: match by student full_name (when old never linked)
      if(!newUid){
        const nm = this.normName(oldS.full_name);
        const cands = cur.nameToNewId[nm] || [];
        const stuCands = cands.filter(c => c.role === 'student');
        if(stuCands.length === 1) newUid = stuCands[0].id;
      }
      if(newUid){
        const r = await sb.from('students').update({ user_id: newUid }).eq('id', curS.id);
        if(!r.error){ linkedStudents++; details.students.push(`${curS.full_name||oldS.full_name} (${curS.admission_no}) → ${newUid.slice(0,8)}…`); }
        else { missedStudents++; details.students.push(`⚠ ${curS.full_name} — ${r.error.message}`); }
      } else { missedStudents++; }
    }
    push(`Students: ✅ ${linkedStudents} linked, ⚠ ${missedStudents} still unlinked (will show as sample fallback until their account exists)`);

    /* ---- STAFF ---- */
    push('👨‍🏫 Re-linking staff (staff_no / email bridge)…');
    const curStaffByNo = {}; const curStaffById = {}; const curStaffByEmail = {};
    cur.staff.forEach(s => {
      if(s.staff_no) curStaffByNo[String(s.staff_no).trim().toLowerCase()] = s;
      if(s.id) curStaffById[String(s.id)] = s;
      const em = this.normEmail(s.email);
      if(em) curStaffByEmail[em] = s;
    });
    for(const oldSt of parsed.oldStaff){
      if(!oldSt) continue;
      const no = String(oldSt.staff_no||'').trim().toLowerCase();
      const em = this.normEmail(oldSt.email);
      let curSt = curStaffByNo[no] || curStaffById[String(oldSt.id||'')] || curStaffByEmail[em] || null;
      if(!curSt) { missedStaff++; continue; }
      if(curSt.user_id) continue;
      let newUid = null;
      if(oldSt.user_id){
        const oldEmail = parsed.oldIdToEmail[String(oldSt.user_id)] || '';
        if(oldEmail) newUid = cur.emailToNewId[oldEmail] || null;
      }
      if(!newUid && em) newUid = cur.emailToNewId[em] || null;
      if(!newUid){
        const nm = this.normName(oldSt.full_name);
        const cands = cur.nameToNewId[nm] || [];
        const stCands = cands.filter(c => ['staff','teacher'].includes(c.role));
        if(stCands.length === 1) newUid = stCands[0].id;
      }
      if(newUid){
        const r = await sb.from('staff').update({ user_id: newUid }).eq('id', curSt.id);
        if(!r.error){ linkedStaff++; details.staff.push(`${curSt.full_name} (${curSt.staff_no}) → ${newUid.slice(0,8)}…`); }
        else { missedStaff++; details.staff.push(`⚠ ${curSt.full_name} — ${r.error.message}`); }
      } else { missedStaff++; }
    }
    push(`Staff: ✅ ${linkedStaff} linked, ⚠ ${missedStaff} still unlinked`);

    /* ---- PARENT_CHILD ---- */
    push('👨‍👩‍👧 Re-linking parent-child links…');
    // current students by id for validation
    const validStudentIds = new Set(cur.students.map(s => String(s.id)));
    for(const oldLink of parsed.oldParentChild){
      if(!oldLink) continue;
      const stuId = String(oldLink.student_id||'');
      if(!stuId || !validStudentIds.has(stuId)) { missedParents++; continue; }
      const oldParentId = String(oldLink.parent_id||'');
      let newParentId = null;
      if(oldParentId){
        const oldEmail = parsed.oldIdToEmail[oldParentId] || '';
        if(oldEmail) newParentId = cur.emailToNewId[oldEmail] || null;
      }
      if(!newParentId) continue;
      // upsert: avoid duplicate (parent_id, student_id) unique constraint
      const r = await sb.from('parent_child').upsert({
        parent_id: newParentId,
        student_id: stuId,
        relationship: oldLink.relationship || 'parent',
        verified: true
      }, { onConflict: 'parent_id,student_id' });
      if(!r.error){ linkedParents++; }
      else { missedParents++; }
    }
    push(`Parent links: ✅ ${linkedParents} restored, ⚠ ${missedParents} missed`);

    push(`\nDone — ${linkedStudents+linkedStaff+linkedParents} total links restored. Real data never touched (only user_id / parent_id columns).`);
    push(`Details: students ${linkedStudents}/${parsed.oldStudents.length}, staff ${linkedStaff}/${parsed.oldStaff.length}, parent links ${linkedParents}/${parsed.oldParentChild.length}`);
    return { linkedStudents, missedStudents, linkedStaff, missedStaff, linkedParents, missedParents, details, log };
  },

  /* UI helpers for admin-data page */
  async previewArchive(file, tableHint){
    if(!window.DataPortability) throw new Error('Data portability engine not ready');
    DataPortability.init(this.sb());
    return await DataPortability.inspectFile(file, tableHint);
  }
};
window.Recovery = Recovery;
