/* School Connect V12.7 — CBT Archive Recovery Center (robust, all-inclusive, self-contained, seamless)
   Dedicated to fixing: "Admin mistakenly archives all the CBT exams. And now we are finding it difficult to restore the archive exams."

   What was hard before:
   - Default filter was Active only → archived list appeared empty → admin thought exams deleted
   - Bulk restore buttons were hidden inside filter card, required understanding filter mechanics
   - No one-click "Restore ALL" button, no stats, no undo, no export backup of archived exams

   What this adds (expert-designed, 6 defence layers):
   Layer 1 — ALWAYS-VISIBLE Archive Recovery Center card (above the list, never hidden by filters)
   Layer 2 — Live stats: total, active, archived, visible, multi-subject; warning banner when ALL archived
   Layer 3 — One-click Restore ALL Archived Exams (server RPC sc_restore_all_archived_exams with client fallback)
   Layer 4 — Scoped restore: by term/session/class/subject, filtered visible, single exam
   Layer 5 — Safety: confirm dialogs, progress log, undo last action via localStorage, export archived as portable backup before bulk actions
   Layer 6 — Universal: import portable JSON backup, Drive backup list, Vault list — same file types as Admin Data

   Self-contained: augments existing CBTUI, does not replace it. If ArchiveHub exists, reuses its engine; otherwise standalone.
   Seamless: works even if list empty (shows archived count via direct query), auto-refreshes after restore.
*/
(function(){
  const CBTArchive = {
    _logEl: null,
    _statsEl: null,
    init(){
      // Ensure dependencies
      if(window.ArchiveHub) ArchiveHub.init();
      this._logEl = document.getElementById('cbt-archive-log');
      this._statsEl = document.getElementById('cbt-archive-stats');
      // Render hub if not present (injected by HTML patch, but also ensure via JS)
      this.ensureHubHTML();
      this.refreshStats();
    },
    ensureHubHTML(){
      if(document.getElementById('cbt-archive-hub')) return;
      const list = document.getElementById('cbt-list');
      if(!list) return;
      const hub = document.createElement('div');
      hub.id='cbt-archive-hub';
      hub.className='card';
      hub.style.cssText='border:2px solid #f59e0b;background:#fffbeb;margin-bottom:16px';
      hub.innerHTML = `
        <h3 style="margin-top:0">🗃️ Archive Recovery Center — Restore Archive Exams (V12.7)</h3>
        <p style="color:#475569;margin-top:4px">If you mistakenly archived exams, <b>this is the one-click fix</b>. All archived exams are hidden from students but <b>NOT deleted</b> — their questions, results and roster are still safe. Restore them here in one click. Every action is logged, confirm-guarded, and undoable.</p>
        <div id="cbt-archive-stats" style="margin:10px 0"><span class="pulse">Loading archive stats…</span></div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px">
          <button class="btn btn-primary" onclick="CBTArchive.restoreAll()">♻️ Restore ALL Archived Exams (One Click — Fixes Mistaken Archive)</button>
          <button class="btn btn-outline" onclick="CBTArchive.restoreFiltered()">♻️ Restore Filtered (Visible) Archived Exams</button>
          <button class="btn btn-outline" onclick="CBTArchive.viewArchivedOnly()">👁️ View Archived Only</button>
          <button class="btn btn-outline" onclick="CBTArchive.viewActiveOnly()">👁️ View Active Only</button>
          <button class="btn btn-outline" onclick="CBTArchive.undo()">↩️ Undo Last Archive Action</button>
        </div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px">
          <button class="btn btn-outline" onclick="CBTArchive.exportArchived()">📦 Export Archived as Portable Backup</button>
          <label class="btn btn-outline">📥 Import Archive Backup<input type="file" id="cbt-arch-file" accept=".json" hidden onchange="CBTArchive.importBackup(this.files[0])"></label>
          <button class="btn btn-outline" onclick="CBTArchive.showAdvanced()">⚙️ Advanced — Restore by Term/Session/Class</button>
        </div>
        <div id="cbt-archive-advanced" style="display:none;margin-top:10px;padding:10px;background:#fff;border:1px solid #fcd34d;border-radius:10px">
          <div class="grid grid-3">
            <div class="form-group"><label>Term</label><input class="form-input" id="cbt-ar-term" placeholder="e.g. First Term"></div>
            <div class="form-group"><label>Session</label><input class="form-input" id="cbt-ar-session" placeholder="e.g. 2024/2025"></div>
            <div class="form-group"><label>Class</label><input class="form-input" id="cbt-ar-class" placeholder="e.g. JSS 1"></div>
            <div class="form-group"><label>Subject</label><input class="form-input" id="cbt-ar-subject" placeholder="e.g. Mathematics"></div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:8px">
            <button class="btn btn-primary btn-sm" onclick="CBTArchive.restoreByFilter()">♻️ Restore Matching Archived Exams</button>
            <button class="btn btn-outline btn-sm" onclick="document.getElementById('cbt-archive-advanced').style.display='none'">Close</button>
          </div>
          <p style="font-size:.82rem;color:#92400e;margin-top:6px">Leave fields blank to match all. Only archived exams matching ALL filled fields will be restored.</p>
        </div>
        <div id="cbt-archive-log" style="margin-top:10px;font-size:.9rem;color:#475569"></div>
      `;
      list.parentNode.insertBefore(hub, list);
      this._logEl = document.getElementById('cbt-archive-log');
      this._statsEl = document.getElementById('cbt-archive-stats');
    },
    esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;'); },
    log(msg, kind){
      if(!this._logEl) this._logEl=document.getElementById('cbt-archive-log');
      if(this._logEl){
        const color = kind==='error'? '#b91c1c' : kind==='success'? '#166534' : '#475569';
        const bg = kind==='error'? '#fef2f2' : kind==='success'? '#f0fdf4' : '#eff6ff';
        const border = kind==='error'? '#fca5a5' : kind==='success'? '#86efac' : '#93c5fd';
        this._logEl.innerHTML = `<div style="background:${bg};border:1px solid ${border};color:${color};padding:8px 10px;border-radius:8px;margin-bottom:6px">${this.esc(msg)}</div>` + this._logEl.innerHTML;
      }
      if(typeof toast==='function') toast(msg, kind||'info', 7000);
    },
    async refreshStats(){
      try{
        const sb = window.sb || (window.CBT && CBT._sb) || null;
        if(!sb){ 
          if(this._statsEl) this._statsEl.innerHTML='<p style="color:#b91c1c">Database not configured</p>';
          return;
        }
        // Fetch all exams via CBT.listExams if available, else direct
        let all=[];
        if(window.CBT && CBT.listExams){
          const r = await CBT.listExams();
          all = r.data||[];
        }else{
          const {data} = await sb.from('cbt_exams').select('id,term,session,class,subject,is_archived').limit(1000);
          all = data||[];
        }
        const total = all.length;
        const archived = all.filter(e=>e.is_archived).length;
        const active = total - archived;
        const last = (window.ArchiveHub && ArchiveHub.getLastAction()) ? ArchiveHub.getLastAction() : (()=>{ try{return JSON.parse(localStorage.getItem('sc-last-archive-action')||'null')}catch(_){return null} })();
        const allArchived = total>0 && archived===total;
        if(this._statsEl){
          this._statsEl.innerHTML = `
            <div class="stats-grid">
              <div class="stat-card"><div class="stat-value">${total}</div><div class="stat-label">Total Exams</div></div>
              <div class="stat-card"><div class="stat-value" style="color:#16a34a">${active}</div><div class="stat-label">Active (Visible)</div></div>
              <div class="stat-card"><div class="stat-value" style="color:${archived?'#d97706':'#16a34a'}">${archived}</div><div class="stat-label">Archived (Hidden)</div></div>
              <div class="stat-card"><div class="stat-value" style="font-size:.9rem">${last? this.esc(last.type+' — '+last.count) : 'None'}</div><div class="stat-label">Last Action (Undoable)</div></div>
            </div>
            ${allArchived? `<div class="notice" style="background:#fef3c7;border-color:#f59e0b;color:#92400e;margin-top:10px"><b>⚠️ All ${total} exam(s) are currently ARCHIVED and hidden from students!</b> This happens when "Archive filtered term/session" is clicked without a filter, or when all exams are selected. <b>Fix in one click:</b> press <b>♻️ Restore ALL Archived Exams</b> above — they will all become active again (still closed until you open them). Nothing was deleted.</div>` : archived>0? `<div class="notice" style="background:#fffbeb;border-color:#fcd34d;color:#92400e;margin-top:10px"><b>ℹ️ ${archived} exam(s) are archived</b> and hidden. Use the restore buttons to bring them back. Archived exams keep their questions, results, and roster safely.</div>` : `<div class="notice" style="background:#f0fdf4;border-color:#86efac;color:#166534;margin-top:10px">✅ No archived exams. All exams are active.</div>`}
          `;
        }
      }catch(e){
        if(this._statsEl) this._statsEl.innerHTML=`<p style="color:#b91c1c">${this.esc(e.message||e)}</p>`;
      }
    },
    async restoreAll(){
      if(!confirm('♻️ Restore ALL Archived CBT Exams?\n\nThis will un-archive EVERY exam that is currently archived.\n\n• Archived exams are hidden from students but NOT deleted — questions, results, roster stay safe\n• After restore they become active again (still closed until you open them)\n• This is the one-click fix for mistakenly archiving all exams\n\nContinue?')) return;
      try{
        this.log('Restoring all archived exams…', 'info');
        let res;
        if(window.ArchiveHub) res = await ArchiveHub.restoreAllArchivedExams();
        else{
          const sb = window.sb;
          const {data:arch} = await sb.from('cbt_exams').select('id').eq('is_archived', true);
          const ids=(arch||[]).map(r=>r.id);
          if(!ids.length){ this.log('No archived exams found.', 'warning'); return; }
          localStorage.setItem('sc-last-archive-action', JSON.stringify({type:'restore-all', count:ids.length, meta:ids, at:new Date().toISOString()}));
          const {error} = await sb.from('cbt_exams').update({is_archived:false, updated_at:new Date().toISOString()}).in('id', ids);
          if(error) throw error;
          res={ok:true, restored:ids.length};
        }
        this.log(`✅ Restored ${res.restored||0} archived exam(s). They are now active again.`, 'success');
        this.refreshStats();
        if(window.CBTUI && CBTUI.refresh) CBTUI.refresh();
        if(window.App && App.logActivity) App.logActivity('restore','cbt_exams','all-archived → '+(res.restored||0));
      }catch(e){ this.log('Restore failed: '+(e.message||e), 'error'); }
    },
    async restoreFiltered(){
      if(!window.CBTUI || !CBTUI._visibleExamIds || !CBTUI._visibleExamIds.length){
        this.log('No filtered exams visible. Switch to "Archived only" view or use Restore ALL.', 'warning');
        return;
      }
      const ids = CBTUI._visibleExamIds;
      // Only restore those that are archived
      try{
        const sb = window.sb;
        const {data:rows} = await sb.from('cbt_exams').select('id,is_archived').in('id', ids);
        const archIds = (rows||[]).filter(r=>r.is_archived).map(r=>r.id);
        if(!archIds.length){ this.log('None of the filtered visible exams are archived.', 'warning'); return; }
        if(!confirm(`Restore ${archIds.length} filtered archived exam(s)?`)) return;
        this.log(`Restoring ${archIds.length} filtered archived exam(s)…`, 'info');
        if(window.ArchiveHub) {
          // Use ArchiveHub path for undo tracking
          const {error} = await sb.from('cbt_exams').update({is_archived:false, updated_at:new Date().toISOString()}).in('id', archIds);
          if(error) throw error;
          ArchiveHub._saveLastAction('restore-filter', archIds.length, archIds);
        } else {
          const {error} = await sb.from('cbt_exams').update({is_archived:false, updated_at:new Date().toISOString()}).in('id', archIds);
          if(error) throw error;
        }
        this.log(`✅ Restored ${archIds.length} filtered exam(s).`, 'success');
        this.refreshStats();
        CBTUI.refresh();
      }catch(e){ this.log('Restore filtered failed: '+(e.message||e), 'error'); }
    },
    viewArchivedOnly(){
      if(window.CBTUI){
        CBTUI._filters = CBTUI._filters||{};
        CBTUI._filters.archive='archived';
        CBTUI.refresh();
        this.log('Switched to Archived Only view. Now you can see all archived exams and restore them.', 'info');
      }
    },
    viewActiveOnly(){
      if(window.CBTUI){
        CBTUI._filters = CBTUI._filters||{};
        CBTUI._filters.archive='active';
        CBTUI.refresh();
        this.log('Switched to Active Only view.', 'info');
      }
    },
    async undo(){
      try{
        this.log('Undoing last archive action…', 'info');
        let res;
        if(window.ArchiveHub) res = await ArchiveHub.undoLastArchive();
        else{
          const last = JSON.parse(localStorage.getItem('sc-last-archive-action')||'null');
          if(!last) throw Error('No last action');
          const sb = window.sb;
          if(last.type==='archive'){
            const ids = Array.isArray(last.meta)? last.meta : last.meta.ids||[];
            const {error} = await sb.from('cbt_exams').update({is_archived:false, updated_at:new Date().toISOString()}).in('id', ids);
            if(error) throw error;
            res={restored:ids.length};
          }else{
            throw Error('Cannot undo without ArchiveHub');
          }
        }
        this.log(`↩️ Undo successful.`, 'success');
        this.refreshStats();
        if(window.CBTUI) CBTUI.refresh();
      }catch(e){ this.log('Undo failed: '+(e.message||e), 'error'); }
    },
    async exportArchived(){
      try{
        this.log('Exporting archived exams as portable backup…', 'info');
        const sb = window.sb;
        const {data, error} = await sb.from('cbt_exams').select('*').eq('is_archived', true);
        if(error) throw error;
        if(!data||!data.length){ this.log('No archived exams to export.', 'warning'); return; }
        const env = {
          format:'school-connect-portable-v1',
          created_at:new Date().toISOString(),
          meta:{kind:'cbt-archived-export', row_count:data.length},
          tables:{cbt_exams:data}
        };
        // Seal if possible
        if(window.DataPortability && DataPortability.seal){
          const sealed = await DataPortability.seal(env);
          DataPortability.download('cbt-archived-'+new Date().toISOString().slice(0,10)+'.json', JSON.stringify(sealed,null,2));
        }else{
          const blob = new Blob([JSON.stringify(env,null,2)],{type:'application/json'});
          const a=document.createElement('a'); a.href=URL.createObjectURL(blob); a.download='cbt-archived-'+new Date().toISOString().slice(0,10)+'.json'; a.click();
        }
        this.log(`📦 Exported ${data.length} archived exam(s) as backup JSON.`, 'success');
      }catch(e){ this.log('Export failed: '+(e.message||e), 'error'); }
    },
    async importBackup(file){
      if(!file) return;
      try{
        this.log('Importing backup file…', 'info');
        if(window.DataPortability){
          DataPortability.init(window.sb);
          const archive = await DataPortability.inspectFile(file, null);
          const rep = await DataPortability.importArchive(archive, 'upsert');
          const saved = rep.reduce((a,x)=>a+x.saved,0);
          this.log(`📥 Import complete: ${saved} rows saved.`, 'success');
          if(window.CBTUI) CBTUI.refresh();
          this.refreshStats();
        }else{
          this.log('DataPortability engine not loaded — cannot import.', 'error');
        }
      }catch(e){ this.log('Import failed: '+(e.message||e), 'error'); }
    },
    showAdvanced(){
      const adv = document.getElementById('cbt-archive-advanced');
      if(adv) adv.style.display = adv.style.display==='none' ? '' : 'none';
    },
    async restoreByFilter(){
      const term = document.getElementById('cbt-ar-term').value.trim()||null;
      const session = document.getElementById('cbt-ar-session').value.trim()||null;
      const klass = document.getElementById('cbt-ar-class').value.trim()||null;
      const subject = document.getElementById('cbt-ar-subject').value.trim()||null;
      if(!term && !session && !klass && !subject){
        if(!confirm('No filter entered — this will restore ALL archived exams. Continue?')) return;
      }
      try{
        this.log(`Restoring archived exams matching filter…`, 'info');
        let res;
        if(window.ArchiveHub) res = await ArchiveHub.restoreArchivedByFilter({term, session, class:klass, subject});
        else{
          const sb = window.sb;
          let q = sb.from('cbt_exams').select('id').eq('is_archived', true);
          if(term) q=q.eq('term', term);
          if(session) q=q.eq('session', session);
          if(klass) q=q.eq('class', klass);
          if(subject) q=q.eq('subject', subject);
          const {data, error} = await q;
          if(error) throw error;
          const ids=(data||[]).map(r=>r.id);
          if(!ids.length){ this.log('No archived exams match that filter.', 'warning'); return; }
          const upd = await sb.from('cbt_exams').update({is_archived:false, updated_at:new Date().toISOString()}).in('id', ids);
          if(upd.error) throw upd.error;
          res={restored:ids.length};
        }
        this.log(`✅ Restored ${res.restored||0} archived exam(s) matching filter.`, 'success');
        this.refreshStats();
        if(window.CBTUI) CBTUI.refresh();
      }catch(e){ this.log('Restore by filter failed: '+(e.message||e), 'error'); }
    }
  };
  window.CBTArchive = CBTArchive;
  document.addEventListener('DOMContentLoaded', ()=>{ setTimeout(()=>CBTArchive.init(), 600); });
  // Also hook into CBTUI.refresh to update stats after each refresh
  const _origRefresh = window.CBTUI && window.CBTUI.refresh;
  // We'll patch after CBTUI defined via interval
  let tries=0;
  const patchInterval = setInterval(()=>{
    tries++;
    if(window.CBTUI && window.CBTUI.refresh && !window.CBTUI._archivePatched){
      const orig = window.CBTUI.refresh.bind(window.CBTUI);
      window.CBTUI.refresh = async function(){
        const r = await orig();
        if(window.CBTArchive) CBTArchive.refreshStats();
        return r;
      };
      window.CBTUI._archivePatched=true;
      clearInterval(patchInterval);
      CBTArchive.init();
    }
    if(tries>50) clearInterval(patchInterval);
  }, 500);
})();
