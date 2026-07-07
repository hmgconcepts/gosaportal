// ====================================================================
// School Connect Gen v9 — Generated School Site Config
// ====================================================================

// Supabase credentials
window.SUPABASE_URL = 'https://dgarrlzbmscpgtefdupm.supabase.co';
window.SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRnYXJybHpibXNjcGd0ZWZkdXBtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzMzc0MTYsImV4cCI6MjA5NzkxMzQxNn0.7CNB3KcQD3NHr6ENDGb7gRX_ld_xjgpQeL_YVuLRW_A';

// Initialize Supabase client (guarded so public/offline pages do not crash if the CDN is unavailable)
window.sb = null;
var sb = null;
if (window.supabase && window.SUPABASE_URL && window.SUPABASE_KEY) {
  window.sb = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_KEY, {
    auth: { persistSession: true, autoRefreshToken: true }
  });
  sb = window.sb;
} else {
  console.warn('[School Connect] Supabase client unavailable. Check network/CDN or assets/js/config.js.');
}

// School configuration
window.SCHOOL = {
  name: 'God of Seed Academy',
  shortName: 'GoSA',
  motto: 'Excellence in Learning and Character',
  address: '',
  phone: '',
  email: '',
  logoExt: 'png',
  primary: '#0506ae',
  accent: '#964eec',
  themeId: 'theme15',
  campuses: [],
  hmgLink: 'https://hmgconcepts.pages.dev/',
  currency: '\u20A6'
};

console.log('[School Connect] Config loaded — Supabase: ' + window.SUPABASE_URL);

// === Missing utility functions (FIX: added by audit) ===
window.SC = window.SC || {};
if (!window.SC.esc) {
  window.SC.esc = function(s) {
    return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
  };
}
if (!window.SC.jsStr) {
  window.SC.jsStr = function(s) { return JSON.stringify(String(s==null?'':s)); };
}
if (!window.SC.slugify) {
  window.SC.slugify = function(s) { return String(s||'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,''); };
}
if (!window.SC.THEMES) window.SC.THEMES = [];
if (!window.SC.MODULES) window.SC.MODULES = [];
