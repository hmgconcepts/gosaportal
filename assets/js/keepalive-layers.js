/* School Connect V12.17 — 14-Layer Keep-Alive Monitoring (from DramaConnect v14.2)
   Robust, all-inclusive, self-contained, seamless monitoring of every layer against Supabase pausing.
   Shows where last ping came from, total pings, pause countdown, and all 14 layers including never-run.
   Each layer has specific fix. Quorum detection, single-point-of-failure warning, human vs automated.
   Free-tier only, no paid API.
*/
const KeepAliveLayers = {
  // Every layer listed, including never-reported — missing row used to hide scheduler that never ran
  LAYERS: [
    { source: 'pg-cron', name: 'L1 · pg_cron (in-database)', kind: 'automated', fix: 'Re-run database/complete-schema.sql; it enables pg_cron and schedules job every 2 days at 05:23 UTC when extension available.' },
    { source: 'site-visit', name: 'L2 · Site visits', kind: 'human', fix: 'Writes automatically whenever someone opens the site (once per 24h via app.js).' },
    { source: 'github-actions', name: 'L3 · GitHub Actions (keep-supabase-alive)', kind: 'automated', fix: 'Push repo to GitHub; workflow reads assets/js/config.js — no secrets required. Enable Actions if disabled. Runs Mon & Thu.' },
    { source: 'vercel-cron', name: 'L4 · Vercel Cron (/api/keep-alive)', kind: 'automated', fix: 'Redeploy on Vercel — /api/keep-alive self-configures from config.js (CRON_SECRET optional).' },
    { source: 'apps-script', name: 'L5 · Google Apps Script', kind: 'automated', fix: 'Paste script from docs/SUPABASE_FREE_TIER_PROTECTION.md into script.google.com and add daily trigger.' },
    { source: 'cron-job-org', name: 'L6 · cron-job.org', kind: 'automated', fix: 'Free job POSTing to /rest/v1/rpc/sc_keep_alive with body {"src":"cron-job-org"} or /functions/v1/ping?source=cron-job-org' },
    { source: 'edge-ping', name: 'L7 · Edge Function + UptimeRobot', kind: 'automated', fix: 'GitHub → Actions → Deploy Supabase Edge Functions → Run (needs SUPABASE_ACCESS_TOKEN), then add ping URL to UptimeRobot.' },
    { source: 'manual-button', name: 'L8 · Manual button (Platform Health)', kind: 'human', fix: 'Press "Send keep-alive heartbeat NOW" on Platform Health page.' },
    { source: 'auto-restore', name: 'L9 · Auto-restore watchdog (Management API)', kind: 'automated', fix: 'Runs from GitHub Actions; add SUPABASE_ACCESS_TOKEN to also enable automatic un-pausing.' },
    { source: 'database-backup', name: 'L10 · Weekly backup workflow', kind: 'automated', fix: 'Runs from GitHub Actions weekly and always sends heartbeat; encrypted dump opt-in.' },
    { source: 'self-commit', name: 'L11 · Self-committing workflow (anti-freeze)', kind: 'automated', fix: 'Part of GitHub heartbeat workflow: monthly commit stops GitHub disabling scheduled workflows after 60 idle days.' },
    { source: 'fleet-console', name: 'L12 · HMG Fleet Console (one-click, auto-pilot, wake-up)', kind: 'human', fix: 'Register project in HMG Fleet Console and press Ping or enable Auto-pilot.' },
    { source: 'fleet-actions', name: 'L13 · Fleet Console GitHub workflow', kind: 'automated', fix: 'Add project to console repo FLEET_TARGETS secret — pings every 2 days.' },
    { source: 'external', name: 'L14 · Other external callers', kind: 'human', fix: 'Any unknown source name counted here.' }
  ],

  LABELS: null,

  init(){
    this.LABELS = Object.fromEntries(this.LAYERS.map(l=>[l.source, l.name.replace(/^L\d+ · /,'')]));
    // Ensure site-visit heartbeat once per 24h (already in app.js, but also here as backup)
    try{
      const KEY='sc-keepalive-at';
      const last=Number(localStorage.getItem(KEY)||0);
      if(Date.now()-last>24*60*60*1000){
        if(window.sb){
          window.sb.rpc('sc_keep_alive',{src:'site-visit'}).then(r=>{
            if(!r.error) localStorage.setItem(KEY, String(Date.now()));
          }).catch(()=>{});
        }
      }
    }catch(_){}
  },

  async ping(source='external'){
    if(!window.sb) throw Error('Database not configured');
    const {data, error}=await sb.rpc('sc_keep_alive',{src: source});
    if(error) throw error;
    return data;
  },

  async getHealth(){
    if(!window.sb) throw Error('Database not configured');
    const [main, sources, health] = await Promise.all([
      sb.from('sc_heartbeat').select('*').eq('id',1).maybeSingle().then(r=>r.data||null).catch(()=>null),
      sb.from('sc_keepalive_sources').select('source,last_ping_at,ping_count,first_seen_at,updated_at').order('last_ping_at',{ascending:false}).then(r=>r.data||[]).catch(()=>[]),
      sb.rpc('sc_heartbeat_health').then(r=>r.error?null:r.data).catch(()=>null)
    ]);
    return { main, sources, health };
  },

  formatAgo(ts){
    if(!ts) return 'never';
    const s=Math.max(0,(Date.now()-new Date(ts).getTime())/1000);
    if(s<90) return 'just now';
    if(s<5400) return `${Math.round(s/60)} min ago`;
    if(s<172800) return `${Math.round(s/3600)} h ago`;
    return `${Math.round(s/86400)} days ago`;
  },

  renderLayerRow(layer, data){
    const src=layer.source;
    const found=(data||[]).find(x=>x.source===src);
    const last=found?found.last_ping_at:null;
    const count=found?found.ping_count:0;
    const ageHours=last? (Date.now()-new Date(last).getTime())/3600000 : 9999;
    const fresh=ageHours<72;
    const state=fresh? (count>0?'✅ Fresh':'⚪ Never') : (count>0?'⚠️ Stale':'⚪ Never');
    const stateCls=fresh?'ok':(count>0?'warn':'bad');
    return { layer, found, last, count, ageHours, fresh, state, stateCls };
  }
};

window.KeepAliveLayers = KeepAliveLayers;
document.addEventListener('DOMContentLoaded', ()=>{ setTimeout(()=>KeepAliveLayers.init(), 500); });
