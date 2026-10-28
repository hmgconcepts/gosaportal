/* School Connect V12.7 — Universal Archive & Restore Hub
   Robust, all-inclusive, self-contained, seamless restoration for EVERY archive type.

   Archive types covered:
   1. CBT exams — is_archived boolean (admin mistakenly archives all)
   2. Student archives — module_records module='student_archive' (auto-created on delete)
   3. File Storage Vault — archives bucket (attendance_checkins, cbt_results, activity_log, etc)
   4. Portable JSON backups — local file restore via DataPortability
   5. Google Drive backups — DriveSync restore
   6. Any table via portable export — full disaster recovery

   Design principles:
   - Every restore is confirmed, logged, and toast-notified
   - Every bulk action shows exact counts before/after
   - Undo support via localStorage for last CBT archive action
   - Server RPCs used where available (bypass RLS, atomic), client fallback otherwise
   - Self-contained: no external deps, works even if DataPortability/DriveSync not loaded yet
   - Seamless: one-click buttons, progress logs, stats grids

   Usage:
   - Include after data-portability.js and drive-sync.js
   - Admin Data page mounts Universal Hub via ArchiveHub.renderUniversal()
   - CBT page uses CBTArchive (in cbt-archive.js) which reuses this engine
*/
const ArchiveHub = {
  sb: null,
  init(client){
    this.sb = client || (typeof sb!=='undefined'?sb:null) || window.sb || null;
    if(window.DataPortability) DataPortability.init(this.sb);
    if(window.DriveSync && DriveSync.loadCfg) DriveSync.loadCfg().catch(()=>{});
  },

  // ---------- CBT Exams ----------
  async listArchivedExams(){
    if(!this.sb) throw Error('Database not configured');
    const {data, error} = await this.sb.from('cbt_exams').select('id,code,title,subject,class,term,session,is_archived,created_at').eq('is_archived', true).order('created_at',{ascending:false}).limit(500);
    if(error) throw error;
    return data||[];
  },
  async countArchivedExams(){
    try{
      const {count, error} = await this.sb.from('cbt_exams').select('id',{count:'exact', head:true}).eq('is_archived', true);
      if(error) throw error;
      return count||0;
    }catch(_){
      const list = await this.listArchivedExams();
      return list.length;
    }
  },
  async restoreAllArchivedExams(){
    if(!this.sb) throw Error('Database not configured');
    // Try server RPC first (atomic, admin-gated, bypasses RLS)
    try{
      const {data, error} = await this.sb.rpc('sc_restore_all_archived_exams');
      if(!error && data && data.ok){
        this._saveLastAction('restore-all', data.restored||0, 'all');
        return data;
      }
    }catch(_){ /* fallback to client */ }
    // Client fallback: bulk update
    const archived = await this.listArchivedExams();
    if(!archived.length) return {ok:true, restored:0, total_was:0, note:'No archived exams found'};
    const ids = archived.map(r=>r.id);
    // Save for undo
    this._saveLastAction('restore-all', ids.length, ids);
    const {error} = await this.sb.from('cbt_exams').update({is_archived:false, updated_at:new Date().toISOString()}).in('id', ids);
    if(error) throw error;
    return {ok:true, restored:ids.length, total_was:ids.length};
  },
  async restoreArchivedByFilter({term, session, class:klass, subject}){
    if(!this.sb) throw Error('Database not configured');
    try{
      const {data, error} = await this.sb.rpc('sc_restore_archived_exams_by_filter', {
        p_term: term||null, p_session: session||null, p_class: klass||null, p_subject: subject||null
      });
      if(!error && data && data.ok) return data;
    }catch(_){}
    // Client fallback
    let q = this.sb.from('cbt_exams').select('id').eq('is_archived', true);
    if(term) q = q.eq('term', term);
    if(session) q = q.eq('session', session);
    if(klass) q = q.eq('class', klass);
    if(subject) q = q.eq('subject', subject);
    const {data, error} = await q;
    if(error) throw error;
    const ids = (data||[]).map(r=>r.id);
    if(!ids.length) return {ok:true, restored:0};
    this._saveLastAction('restore-filter', ids.length, {term,session,class:klass,subject, ids});
    const upd = await this.sb.from('cbt_exams').update({is_archived:false, updated_at:new Date().toISOString()}).in('id', ids);
    if(upd.error) throw upd.error;
    return {ok:true, restored:ids.length};
  },
  async archiveExams(ids){
    if(!this.sb) throw Error('Database not configured');
    if(!ids||!ids.length) return {ok:true, archived:0};
    this._saveLastAction('archive', ids.length, ids);
    try{
      const {data, error} = await this.sb.rpc('sc_archive_cbt_exams', {p_ids: ids});
      if(!error && data && data.ok) return data;
    }catch(_){}
    const {error} = await this.sb.from('cbt_exams').update({is_archived:true, is_open:false, updated_at:new Date().toISOString()}).in('id', ids);
    if(error) throw error;
    return {ok:true, archived:ids.length};
  },
  _saveLastAction(type, count, meta){
    try{
      localStorage.setItem('sc-last-archive-action', JSON.stringify({type, count, meta, at:new Date().toISOString()}));
    }catch(_){}
  },
  getLastAction(){
    try{
      return JSON.parse(localStorage.getItem('sc-last-archive-action')||'null');
    }catch(_){ return null; }
  },
  async undoLastArchive(){
    const last = this.getLastAction();
    if(!last) throw Error('No last archive action to undo');
    if(last.type==='archive'){
      // Last action was archiving, so undo = restore those ids
      const ids = Array.isArray(last.meta) ? last.meta : (last.meta && last.meta.ids) || [];
      if(!ids.length) throw Error('Last archive had no ids stored');
      const {error} = await this.sb.from('cbt_exams').update({is_archived:false, updated_at:new Date().toISOString()}).in('id', ids);
      if(error) throw error;
      return {ok:true, restored:ids.length, undone:last};
    }else if(last.type.startsWith('restore')){
      // Last action was restore, undo = re-archive
      const ids = Array.isArray(last.meta) ? last.meta : (last.meta && last.meta.ids) || [];
      if(Array.isArray(ids) && ids.length){
        const {error} = await this.sb.from('cbt_exams').update({is_archived:true, is_open:false, updated_at:new Date().toISOString()}).in('id', ids);
        if(error) throw error;
        return {ok:true, archived:ids.length, undone:last};
      }else{
        throw Error('Cannot undo — original ids not stored (old format). Use Archive view to re-archive manually.');
      }
    }
    throw Error('Unknown last action type: '+last.type);
  },

  // ---------- Student Archives ----------
  async listStudentArchives(){
    if(!this.sb) throw Error('Database not configured');
    try{
      const {data, error} = await this.sb.rpc('sc_list_student_archives');
      if(!error && data) return data;
    }catch(_){}
    // Fallback direct select (RLS admin)
    const {data, error} = await this.sb.from('module_records').select('*').eq('module','student_archive').order('created_at',{ascending:false}).limit(200);
    if(error) throw error;
    return data||[];
  },
  async restoreStudentArchive(archiveId){
    if(!this.sb) throw Error('Database not configured');
    try{
      const {data, error} = await this.sb.rpc('sc_restore_student_archive', {p_archive_id: archiveId});
      if(!error && data) {
        if(!data.ok) throw Error(data.error||'Restore failed');
        return data;
      }
    }catch(e){
      // If RPC missing or fails, fallback to client-side restore via DataPortability pattern
      if(/not found|schema cache|function/i.test(String(e.message||''))){
        // client fallback
      }else if(e.message && !/function/i.test(e.message)){
        throw e;
      }
    }
    // Client fallback: fetch archive, insert student
    const {data:rec, error} = await this.sb.from('module_records').select('*').eq('id', archiveId).eq('module','student_archive').maybeSingle();
    if(error) throw error;
    if(!rec) throw Error('Archive not found');
    const row = rec.data || {};
    // Remove generated columns, keep core
    const payload = {
      full_name: row.full_name,
      admission_no: row.admission_no,
      class: row.class,
      arm: row.arm,
      gender: row.gender,
      date_of_birth: row.date_of_birth||null,
      admission_year: row.admission_year||null,
      photo_url: row.photo_url||null,
      guardian_name: row.guardian_name||null,
      guardian_phone: row.guardian_phone||null,
      guardian_email: row.guardian_email||null,
      address: row.address||null,
      status: 'active'
    };
    // Check admission_no conflict
    if(payload.admission_no){
      const {data:exists} = await this.sb.from('students').select('id').eq('admission_no', payload.admission_no).maybeSingle();
      if(exists) throw Error('A student with admission_no '+payload.admission_no+' already exists. Delete or change it first.');
    }
    const {data:ins, error:insErr} = await this.sb.from('students').insert(payload).select('id').maybeSingle();
    if(insErr) throw insErr;
    await this.sb.from('module_records').update({status:'restored', body:(rec.body||'')+' — Restored on '+new Date().toISOString()}).eq('id', archiveId);
    return {ok:true, restored_id: ins&&ins.id, archive_id: archiveId};
  },
  async restoreAllStudentArchives(){
    const list = await this.listStudentArchives();
    let ok=0, fail=0, errors=[];
    for(const rec of list){
      try{ await this.restoreStudentArchive(rec.id); ok++; }catch(e){ fail++; if(errors.length<5) errors.push((rec.title||rec.id)+': '+(e.message||e)); }
    }
    return {ok:true, restored:ok, failed:fail, errors};
  },

  // ---------- Vault ----------
  async listVault(){
    if(!window.DataPortability) throw Error('Vault engine not loaded');
    DataPortability.init(this.sb);
    return await DataPortability.listVault();
  },
  async restoreVault(path){
    if(!window.DataPortability) throw Error('Vault engine not loaded');
    DataPortability.init(this.sb);
    return await DataPortability.restoreFromVault(path, 'upsert');
  },

  // ---------- Portable JSON ----------
  async importPortableFile(file){
    if(!window.DataPortability) throw Error('Portability engine not loaded');
    DataPortability.init(this.sb);
    const archive = await DataPortability.inspectFile(file, null);
    return await DataPortability.importArchive(archive, 'upsert');
  },

  // ---------- Drive ----------
  async listDriveBackups(){
    if(!window.DriveSync) throw Error('DriveSync not loaded');
    await DriveSync.loadCfg();
    return await DriveSync.listBackups();
  },
  async restoreDriveBackup(id){
    if(!window.DriveSync) throw Error('DriveSync not loaded');
    return await DriveSync.restoreFrom(id, 'upsert');
  },

  // ---------- Universal Hub Render ----------
  renderUniversal(containerId){
    const el = document.getElementById(containerId);
    if(!el) return;
    el.innerHTML = `
      <div class="card" style="border:2px solid #f59e0b;background:#fffbeb;margin-bottom:16px">
        <h3 style="margin-top:0">🗃️ Universal Archive & Restore Hub — Restore Anything, Anytime (V12.7)</h3>
        <p style="color:#475569;margin-top:4px">One place to see and restore <b>every</b> archived record: CBT exams, deleted students, File Storage vault, portable JSON, Google Drive backups. All actions are confirmed, logged, and toast-notified. Nothing is ever truly lost.</p>
        <div id="auh-stats" style="margin:10px 0"><span class="pulse">Loading archive stats…</span></div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px">
          <button class="btn btn-primary" onclick="ArchiveHub.uiRestoreAllCBT()">♻️ Restore ALL Archived CBT Exams (One Click)</button>
          <button class="btn btn-outline" onclick="ArchiveHub.uiViewArchivedCBT()">👁️ View Archived CBT Only</button>
          <button class="btn btn-outline" onclick="ArchiveHub.uiUndoLast()">↩️ Undo Last Archive Action</button>
          <button class="btn btn-outline" onclick="ArchiveHub.uiExportArchivedCBT()">📦 Export Archived CBT as Backup</button>
          <button class="btn btn-outline" onclick="ArchiveHub.refreshStats()">↻ Refresh Stats</button>
        </div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px">
          <button class="btn btn-outline" onclick="ArchiveHub.uiListStudentArchives()">👨‍🎓 View Deleted Student Archives</button>
          <button class="btn btn-outline" onclick="ArchiveHub.uiRestoreAllStudents()">♻️ Restore ALL Deleted Students</button>
          <button class="btn btn-outline" onclick="document.getElementById('auh-file').click()">📥 Import Portable JSON / CSV</button>
          <input type="file" id="auh-file" accept=".json,.csv" hidden onchange="ArchiveHub.uiImportFile(this.files[0])">
          <button class="btn btn-outline" onclick="ArchiveHub.uiListVault()">📦 View File Storage Vault</button>
          <button class="btn btn-outline" onclick="ArchiveHub.uiListDrive()">☁️ View Drive Backups</button>
        </div>
        <div id="auh-log" style="margin-top:10px;font-size:.9rem;color:#475569"></div>
        <div id="auh-detail" style="margin-top:12px"></div>
      </div>
    `;
    this.refreshStats();
  },
  async refreshStats(){
    const box = document.getElementById('auh-stats');
    if(!box) return;
    try{
      this.init();
      const [cbtCount, studentList, vaultList] = await Promise.all([
        this.countArchivedExams().catch(()=>0),
        this.listStudentArchives().catch(()=>[]),
        (window.DataPortability? this.listVault().catch(()=>[]) : Promise.resolve([]))
      ]);
      const last = this.getLastAction();
      box.innerHTML = `
        <div class="stats-grid">
          <div class="stat-card"><div class="stat-value" style="color:${cbtCount?'#d97706':'#16a34a'}">${cbtCount}</div><div class="stat-label">Archived CBT Exams</div></div>
          <div class="stat-card"><div class="stat-value">${(studentList||[]).length}</div><div class="stat-label">Deleted Student Archives</div></div>
          <div class="stat-card"><div class="stat-value">${(vaultList||[]).length}</div><div class="stat-label">Vault Archives (File Storage)</div></div>
          <div class="stat-card"><div class="stat-value" style="font-size:.95rem">${last? (last.type+' — '+last.count+' — '+String(last.at).slice(0,16)) : 'None'}</div><div class="stat-label">Last Archive Action (Undoable)</div></div>
        </div>
        ${cbtCount>0? `<div class="notice" style="background:#fffbeb;border-color:#fcd34d;color:#92400e;margin-top:8px"><b>⚠️ ${cbtCount} CBT exam(s) are currently archived and hidden from students.</b> Click "Restore ALL Archived CBT Exams" above to bring them back in one click. If all exams were archived by mistake, this is the fix.</div>` : `<div class="notice" style="background:#f0fdf4;border-color:#86efac;color:#166534;margin-top:8px">✅ No CBT exams are archived. All exams are live.</div>`}
      `;
    }catch(e){
      box.innerHTML = `<p style="color:#b91c1c">${this.esc(e.message||e)}</p>`;
    }
  },
  esc(v){ return String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;'); },
  log(m, kind){
    const el = document.getElementById('auh-log');
    if(el) el.innerHTML = `<div class="notice" style="${kind==='error'?'background:#fef2f2;border-color:#fca5a5;color:#b91c1c':kind==='success'?'background:#f0fdf4;border-color:#86efac;color:#166534':'background:#eff6ff;border-color:#93c5fd;color:#1e3a8a'}">${this.esc(m)}</div>` + el.innerHTML;
    if(typeof toast==='function') toast(m, kind||'info', 7000);
  },

  // UI actions
  async uiRestoreAllCBT(){
    if(!confirm('♻️ Restore ALL archived CBT exams?\n\nThis will un-archive every exam that is currently archived, making them visible again to staff and students (still closed until opened).\n\nThis is the one-click fix when an admin mistakenly archives all exams.\n\nContinue?')) return;
    try{
      const res = await this.restoreAllArchivedExams();
      this.log(`✅ Restored ${res.restored||0} archived CBT exam(s). They are now visible again. Refreshing list…`, 'success');
      this.refreshStats();
      if(window.CBTUI && CBTUI.refresh) CBTUI.refresh();
      if(window.App && App.logActivity) App.logActivity('restore','cbt_exams','all-archived → '+ (res.restored||0));
    }catch(e){ this.log('Restore failed: '+(e.message||e), 'error'); }
  },
  uiViewArchivedCBT(){
    if(window.CBTUI){
      CBTUI._filters = CBTUI._filters||{};
      CBTUI._filters.archive='archived';
      CBTUI.refresh();
      this.log('Showing archived CBT exams only. Use the Restore buttons to bring them back.', 'info');
    }else{
      location.href='cbt.html?archive=archived';
    }
  },
  async uiUndoLast(){
    try{
      const res = await this.undoLastArchive();
      this.log(`↩️ Undo successful: ${res.restored? 'restored '+res.restored : 'archived '+res.archived} exam(s).`, 'success');
      this.refreshStats();
      if(window.CBTUI && CBTUI.refresh) CBTUI.refresh();
    }catch(e){ this.log('Undo failed: '+(e.message||e), 'error'); }
  },
  async uiExportArchivedCBT(){
    try{
      this.init();
      const archived = await this.listArchivedExams();
      if(!archived.length){ this.log('No archived CBT exams to export.', 'warning'); return; }
      // Fetch full rows
      const {data, error} = await this.sb.from('cbt_exams').select('*').eq('is_archived', true);
      if(error) throw error;
      const env = await DataPortability.envelope({cbt_exams:data},{kind:'cbt-archived-export', row_count:data.length, exported_at:new Date().toISOString()});
      const sealed = await DataPortability.seal(env);
      DataPortability.download('cbt-archived-'+new Date().toISOString().slice(0,10)+'.json', JSON.stringify(sealed,null,2));
      this.log(`📦 Exported ${data.length} archived exam(s) as portable backup. Keep this file safe — you can re-import it anytime.`, 'success');
    }catch(e){ this.log('Export failed: '+(e.message||e), 'error'); }
  },
  async uiListStudentArchives(){
    const detail = document.getElementById('auh-detail');
    if(!detail) return;
    detail.innerHTML='<span class="pulse">Loading deleted student archives…</span>';
    try{
      const list = await this.listStudentArchives();
      if(!list.length){ detail.innerHTML='<p style="color:#64748b">No deleted student archives found. When you delete a student, their full record is auto-saved here for  record-tracking and can be restored.</p>'; return; }
      detail.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Deleted</th><th>Student</th><th>Admission No</th><th>Actions</th></tr></thead><tbody>`+
        list.map(r=>{
          const d = r.data||{};
          return `<tr><td>${String(r.created_at||'').slice(0,16)}</td><td>${this.esc(d.full_name||r.title||'—')}</td><td>${this.esc(d.admission_no||'')}</td><td><button class="btn btn-sm btn-primary" onclick="ArchiveHub.uiRestoreStudent('${r.id}')">♻️ Restore</button></td></tr>`;
        }).join('')+`</tbody></table></div><p style="font-size:.82rem;color:#64748b">Restoring re-creates the student row with the same admission number (if still free). Old scores remain purged — this is intentional to prevent ghost report sheets.</p>`;
    }catch(e){ detail.innerHTML=`<p style="color:#b91c1c">${this.esc(e.message||e)}</p>`; }
  },
  async uiRestoreStudent(id){
    if(!confirm('Restore this deleted student?\n\nTheir record will be re-created with the same admission number. Make sure that admission number is not already in use.')) return;
    try{
      const res = await this.restoreStudentArchive(id);
      this.log(`✅ Student restored (new id ${res.restored_id||'—'}).`, 'success');
      this.uiListStudentArchives();
      this.refreshStats();
    }catch(e){ this.log('Restore failed: '+(e.message||e), 'error'); }
  },
  async uiRestoreAllStudents(){
    if(!confirm('Restore ALL deleted student archives?\n\nThis will attempt to restore every deleted student. If an admission number is already taken, that row will be skipped and reported. Continue?')) return;
    try{
      const res = await this.restoreAllStudentArchives();
      this.log(`✅ Bulk restore: ${res.restored} restored, ${res.failed} failed. ${res.errors&&res.errors.length? 'Errors: '+res.errors.join(' | ') : ''}`, res.failed?'warning':'success');
      this.refreshStats();
    }catch(e){ this.log('Bulk restore failed: '+(e.message||e), 'error'); }
  },
  async uiImportFile(file){
    if(!file) return;
    try{
      this.init();
      const rep = await this.importPortableFile(file);
      const saved = rep.reduce((a,x)=>a+x.saved,0), failed=rep.reduce((a,x)=>a+x.failed,0);
      document.getElementById('auh-detail').innerHTML = DataPortability.reportHTML(rep);
      this.log(`📥 Import complete: ${saved} rows saved, ${failed} failed. See table report below.`, failed?'warning':'success');
      this.refreshStats();
    }catch(e){ this.log('Import failed: '+(e.message||e), 'error'); }
  },
  async uiListVault(){
    const detail = document.getElementById('auh-detail');
    detail.innerHTML='<span class="pulse">Loading vault…</span>';
    try{
      const items = await this.listVault();
      if(!items.length){ detail.innerHTML='<p>No vault archives yet. Use Storage Manager → Archive Vault to move old rows into File Storage.</p>'; return; }
      detail.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Archive</th><th>Size</th><th>Created</th><th>Actions</th></tr></thead><tbody>`+
        items.map(i=>`<tr><td style="word-break:break-all">${this.esc(i.path)}</td><td>${i.size||''}</td><td>${this.esc(String(i.created||'').slice(0,16))}</td><td><button class="btn btn-sm btn-outline" onclick="ArchiveHub.uiRestoreVault('${this.esc(i.path)}')">↩ Restore</button></td></tr>`).join('')+
        `</tbody></table></div>`;
    }catch(e){ detail.innerHTML=`<p style="color:#b91c1c">${this.esc(e.message||e)}</p>`; }
  },
  async uiRestoreVault(path){
    if(!confirm('Restore vault archive '+path+' back into database? Existing rows with same id are updated.')) return;
    try{
      const rep = await this.restoreVault(path);
      const saved = rep.reduce((a,x)=>a+x.saved,0);
      this.log(`✅ Vault restore: ${saved} rows restored from ${path}.`, 'success');
      document.getElementById('auh-detail').innerHTML = DataPortability.reportHTML(rep);
    }catch(e){ this.log('Vault restore failed: '+(e.message||e), 'error'); }
  },
  async uiListDrive(){
    const detail = document.getElementById('auh-detail');
    detail.innerHTML='<span class="pulse">Loading Drive backups…</span>';
    try{
      const files = await this.listDriveBackups();
      if(!files.length){ detail.innerHTML='<p>No Drive backups yet. Use Admin Data → Google Drive Backup & Sync → Back up now.</p>'; return; }
      detail.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Backup</th><th>Size</th><th>Created</th><th>Actions</th></tr></thead><tbody>`+
        files.map(f=>`<tr><td style="word-break:break-all">${this.esc(f.name)}</td><td>${f.size||''}</td><td>${this.esc(String(f.createdTime||'').slice(0,16))}</td><td><button class="btn btn-sm btn-outline" onclick="ArchiveHub.uiRestoreDrive('${f.id}')">↩ Restore</button></td></tr>`).join('')+
        `</tbody></table></div>`;
    }catch(e){ detail.innerHTML=`<p style="color:#b91c1c">${this.esc(e.message||e)} — Configure Drive first in Admin Data → Setup.</p>`; }
  },
  async uiRestoreDrive(id){
    if(!confirm('Restore this Drive backup into database? Existing rows updated, missing re-created.')) return;
    try{
      const rep = await this.restoreDriveBackup(id);
      const saved = rep.reduce((a,x)=>a+x.saved,0);
      this.log(`✅ Drive restore: ${saved} rows restored.`, 'success');
      document.getElementById('auh-detail').innerHTML = DataPortability.reportHTML(rep);
      this.refreshStats();
    }catch(e){ this.log('Drive restore failed: '+(e.message||e), 'error'); }
  }
};
window.ArchiveHub = ArchiveHub;
document.addEventListener('DOMContentLoaded', ()=>ArchiveHub.init());
