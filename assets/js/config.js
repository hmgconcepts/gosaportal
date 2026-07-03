// ====================================================================
// School Connect Gen v3 — Generated School Site Config
// ====================================================================

// Supabase credentials
window.SUPABASE_URL = 'https://auptmhagbksebetbxknv.supabase.co';
window.SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF1cHRtaGFnYmtzZWJldGJ4a252Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMwNzk2NzIsImV4cCI6MjA5ODY1NTY3Mn0.jqVpNZlpITEM8bmw8r2ja-pt7hQuIhIYTau8uD0Clxc';

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
  primary: '#4f46e5',
  accent: '#7c3aed',
  themeId: 'indigo',
  campuses: [],
  hmgLink: 'https://hmgconcepts.pages.dev/',
  currency: '\u20A6'
};

console.log('[School Connect] Config loaded — Supabase: ' + window.SUPABASE_URL);
