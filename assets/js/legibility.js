/* ============================================================================
   legibility.js — School Connect V12.26 Popup Contrast Guard (Final)
   ----------------------------------------------------------------------------
   WHY THIS EXISTS (expert analysis of user reports):

   "When there are popup messages on the platform, its texts aren't legible."
   "When the theme button is clicked to switch the theme, some texts on the
    platform are not legible, one can't clearly see these texts."

   Root causes (deep audit):

   1. Popups are built in a dozen different scripts (app.js toast, 
      platform-health.html fallback toast, DriveSync _pill, Notifications 
      showInApp, MessagesCenter bubbles, CRUD modals, Super chatbot, etc.)
   2. Most set background:#fff or background:white INLINE and never set a text
      colour, so text inherits whatever color the app shell or active theme
      happens to be using — which on dark mode is near-white intended for dark
      surface → white on white or dark on dark → illegible
   3. Inline styles beat stylesheets, so no amount of CSS can reliably win
   4. Theme switching: many elements have hardcoded colors like color:#0f172a,
      background:#fff, color:#fff on gradient, etc. that don't adapt to dark
      mode — when toggled to dark, dark text on dark background or white on
      white → illegible
   5. Toast CSS had TWO conflicting definitions: one white bg dark text, one
      dark bg #0f172a white text — second overrides first's bg but .toast-msg
      still had var(--gray-700) which in dark mode is light gray #cbd5e1 on
      dark bg #0f172a → dark gray on dark? Actually first definition's
      .toast-msg color var(--gray-700) is #475569 dark gray on dark bg #0f172a
      → NOT legible. That's the popup bug.
   6. New popups get written all the time, each can reintroduce it — whack-a-mole

   HOW IT WORKS (from Adewale Classroom legibility.js, adapted to School Connect):

   A MutationObserver watches for popup-like elements entering the DOM (fixed
   or absolute overlays, anything classed modal/popup/dropdown/panel/toast).
   For each one it walks up to find the real painted background colour, works
   out relative luminance, and if text colour does not clear WCAG AA 4.5:1,
   it pins a colour that does — dark ink #0f172a on light surface, near-white
   #f8fafc on dark — using setProperty(...,'important') so it beats inline style.

   Conservative: only touches elements whose contrast genuinely fails, so
   deliberately styled popups (dark assistant panel, coloured toast) are left
   as intended.

   Also watches for theme changes (data-theme attribute) and re-scans.

   No dependencies, ~5 KB, free-tier.
   ============================================================================ */
(function(w, d){
  'use strict';

  const SEL = [
    '.modal', '.modal-content', '.modal-backdrop > div',
    '.toast', '.toast-container > div', '#toast-container > div', '#toast > div',
    '.notif-dropdown', '#notif-dropdown', '.notif-item', '.notif-entry',
    '.mc-app', '.mc-bubble', '.mc-row', '.mc-head',
    '#sc-drive-progress', '#sc-drive-overdue',
    '#sc-theme-float', '#sc-cmdk', '.sc-cmdk-item',
    '.pwa-install', '.pwa-install-banner',
    '.card', '.stat-card', '.table-wrap',
    '[class*="popup"]', '[class*="dropdown"]', '[role="dialog"]', '[aria-modal="true"]',
    '.app-sidebar', '.app-topbar', '.app-nav a'
  ].join(',');

  function luminance(rgb){
    const c=rgb.map(v=>{
      v=v/255;
      return v<=0.03928 ? v/12.92 : Math.pow((v+0.055)/1.055,2.4);
    });
    return 0.2126*c[0]+0.7152*c[1]+0.0722*c[2];
  }
  function contrast(a,b){
    const la=luminance(a), lb=luminance(b);
    const hi=Math.max(la,lb), lo=Math.min(la,lb);
    return (hi+0.05)/(lo+0.05);
  }
  function parseColor(str){
    if(!str) return null;
    const m=String(str).match(/rgba?\(([^)]+)\)/);
    if(!m) return null;
    const p=m[1].split(',').map(x=>parseFloat(x));
    if(p.length>=4 && p[3]===0) return null;
    if(p.length<3 || p.some(isNaN)) return null;
    return [p[0],p[1],p[2]];
  }
  function effectiveBg(el){
    let node=el;
    while(node && node.nodeType===1){
      const c=parseColor(w.getComputedStyle(node).backgroundColor);
      if(c) return c;
      node=node.parentElement;
    }
    return [255,255,255];
  }

  function fix(el){
    if(!el || el.nodeType!==1 || el.dataset.scLegible==='1') return;
    try{
      if(el.closest && (el.closest('#page-help-modal') || el.closest('.site-help-modal') || el.closest('#sc-theme-float'))){
        // Don't recolour the floating theme button itself — it has its own styles
        if(el.id==='sc-theme-float') return;
      }
    }catch(e){}
    let cs;
    try{ cs=w.getComputedStyle(el); }catch(e){ return; }
    if(!cs || cs.display==='none' || cs.visibility==='hidden') return;

    const bg=effectiveBg(el);
    const fg=parseColor(cs.color) || [15,23,42];
    const ratio=contrast(fg,bg);
    if(ratio>=4.5){ el.dataset.scLegible='1'; return; }

    const dark=[15,23,42]; // #0f172a
    const light=[248,250,252]; // #f8fafc
    const pick=contrast(dark,bg) >= contrast(light,bg) ? '#0f172a' : '#f8fafc';
    const muted=pick==='#0f172a' ? '#475569' : '#cbd5e1';
    const link=pick==='#0f172a' ? '#4f46e5' : '#a5b4fc';

    // Only fix if contrast is failing and background is not transparent and not already fixed
    // For toast, we want to ensure high contrast
    if(el.classList.contains('toast') || el.classList.contains('toast-msg') || el.classList.contains('notif-item') || el.classList.contains('notif-entry') || el.classList.contains('mc-bubble') || el.closest('.toast') || el.closest('.notif-dropdown') || el.closest('.modal')){
      el.style.setProperty('color', pick, 'important');
      el.dataset.scLegible='1';
      el.dataset.scLegibleFixed=String(Math.round(ratio*10)/10);
    } else if(ratio < 3.0){
      // For general low contrast (theme switching illegible texts), fix more aggressively
      el.style.setProperty('color', pick, 'important');
      el.dataset.scLegible='1';
    } else {
      el.dataset.scLegible='1';
      return;
    }

    const kids=el.querySelectorAll('*');
    for(let i=0;i<kids.length && i<400;i++){
      const k=kids[i];
      if(k.tagName==='SVG' || k.tagName==='IMG' || k.tagName==='CANVAS') continue;
      let kcs;
      try{ kcs=w.getComputedStyle(k); }catch(e){ continue; }
      const kbg=parseColor(kcs.backgroundColor) || bg;
      const kfg=parseColor(kcs.color);
      if(!kfg) continue;
      if(contrast(kfg,kbg) < 4.5){
        const isMuted=/muted|help|hint|small|caption|gray-500|gray-600/i.test(k.className||'') || k.tagName==='SMALL';
        const isLink=k.tagName==='A';
        // Only fix if inside popup or if contrast very low
        if(k.closest('.toast') || k.closest('.notif-dropdown') || k.closest('.modal') || k.closest('.mc-app') || k.closest('#sc-drive-progress') || contrast(kfg,kbg) < 3.0){
          k.style.setProperty('color', isLink ? link : (isMuted ? muted : pick), 'important');
        }
      }
      if(/^(INPUT|SELECT|TEXTAREA)$/.test(k.tagName)){
        const cbg=parseColor(kcs.backgroundColor);
        if(!cbg || contrast(parseColor(kcs.color)||dark, cbg) < 4.5){
          if(k.closest('.modal') || k.closest('.toast') || k.closest('.notif-dropdown')){
            k.style.setProperty('background-color', pick==='#0f172a' ? '#ffffff' : '#1e293b', 'important');
            k.style.setProperty('color', pick, 'important');
          }
        }
      }
    }
  }

  function scan(root){
    root=root||d;
    try{
      if(root.nodeType===1 && root.matches && root.matches(SEL)) fix(root);
      const list=root.querySelectorAll ? root.querySelectorAll(SEL) : [];
      for(let i=0;i<list.length;i++) fix(list[i]);
    }catch(e){}
  }

  function start(){
    scan(d);
    if(!w.MutationObserver) return;
    const mo=new MutationObserver(muts=>{
      for(let i=0;i<muts.length;i++){
        const m=muts[i];
        if(m.type==='childList'){
          for(let j=0;j<m.addedNodes.length;j++){
            const n=m.addedNodes[j];
            if(n.nodeType===1) scan(n);
          }
        }else if(m.type==='attributes' && m.target && m.target.nodeType===1){
          // Re-evaluate if class/style/data-theme changes (theme switching)
          if(m.attributeName==='class' || m.attributeName==='style' || m.attributeName==='data-theme'){
            delete m.target.dataset.scLegible;
            // Also clear children's legible flags
            try{
              m.target.querySelectorAll('[data-sc-legible]').forEach(e=>{ delete e.dataset.scLegible; });
            }catch(e){}
            scan(m.target);
          }
        }
      }
    });
    mo.observe(d.documentElement, {childList:true, subtree:true, attributes:true, attributeFilter:['class','style','data-theme','hidden']});
    w.SCLegibility={
      rescan:()=>{
        d.querySelectorAll('[data-sc-legible]').forEach(e=>{ delete e.dataset.scLegible; });
        scan(d);
      },
      contrast, luminance, _fix:fix
    };
  }

  if(d.readyState==='loading') d.addEventListener('DOMContentLoaded', start);
  else start();

  // Re-check after theme changes and shortly after boot
  setTimeout(()=>{ if(w.SCLegibility) w.SCLegibility.rescan(); }, 800);
  setTimeout(()=>{ if(w.SCLegibility) w.SCLegibility.rescan(); }, 2000);

  // Listen for theme manager changes
  d.addEventListener('click', e=>{
    if(e.target.closest && (e.target.closest('#sc-theme-float') || e.target.closest('[onclick*="toggleDarkMode"]') || e.target.closest('[onclick*="toggleMode"]') || e.target.closest('.theme-preset'))){
      setTimeout(()=>{ if(w.SCLegibility) w.SCLegibility.rescan(); }, 100);
      setTimeout(()=>{ if(w.SCLegibility) w.SCLegibility.rescan(); }, 500);
    }
  });

})(window, document);
