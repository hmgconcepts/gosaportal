/* ====================================================================
   notifications.js — School Connect v15 (Final Stable Edition)
   Multi-channel notifications: in-app bell, browser push, email, WhatsApp, SMS.
   100% free. No AI API. No third-party tracking.
   ==================================================================== */

const Notifications = {
  sb: null,
  sw: null,
  permission: 'default',
  bellBound: false,
  _esc(s) { return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); },

  /* ---------- Init ---------- */
  async init(supabaseClient, serviceWorkerRegistration) {
    this.sb = supabaseClient;
    this.sw = serviceWorkerRegistration || null;
    if ('Notification' in window) this.permission = Notification.permission;
    this.bindBell();
    await this.startRealtimeListener();
    await this.refreshUnreadCount();
    if (!this._pollTimer) this._pollTimer = setInterval(() => this.refreshUnreadCount().catch(()=>{}), 30000);
    try { this.loadDropdownItems(); } catch(_) {}
    try { await this.renderPageList(); } catch(_) {}
    return this;
  },

  /* ---------- Permission ---------- */
  async requestPermission() {
    if (!('Notification' in window)) { toast('Push notifications not supported on this browser.', 'warning'); return false; }
    if (this.permission === 'granted') return true;
    if (this.permission === 'denied') { toast('Notifications are blocked. Enable them in browser settings.', 'warning'); return false; }
    const res = await Notification.requestPermission();
    this.permission = res;
    if (res === 'granted') { await this.subscribeToPush(); toast('🔔 Notifications enabled!', 'success'); return true; }
    return false;
  },

  async subscribeToPush() {
    if (!this.sw || !this.sw.pushManager) return;
    try {
      const VAPID_PUBLIC = (window.SC && window.SC.VAPID_PUBLIC) || 'BAd-default-Pub-Key-Replaced-At-Deploy';
      let sub = await this.sw.pushManager.getSubscription();
      if (!sub) sub = await this.sw.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC) });
      if (this.sb) {
        const { data: { user } } = await this.sb.auth.getUser();
        if (user) {
          await this.sb.from('push_subscriptions').upsert({
            user_id: user.id,
            subscription: JSON.stringify(sub),
            user_agent: navigator.userAgent.slice(0, 200),
            updated_at: new Date().toISOString()
          });
        }
      }
    } catch (e) { console.warn('[Notifications] push subscribe failed (likely no VAPID keys yet):', e.message); }
  },

  /* ===========================================================
     v15: BELL — Bulletproof
     The previous version had a bug where the dropdown appeared
     and disappeared immediately on certain pages. The fix:

       1. Use mousedown instead of click for the close handler
          so it does not race with the bell's own click.
       2. Use a unique namespace to prevent duplicate binding.
       3. Always re-render dropdown on open (no stale state).
       4. Use pointer-events on the dropdown to absorb all events
          that should not bubble out.
     =========================================================== */
  bindBell() {
    if (this.bellBound) return;
    const bell = document.getElementById('notif-bell');
    if (!bell) return;
    this.bellBound = true;

    bell.style.cursor = 'pointer';
    bell.setAttribute('role', 'button');
    bell.setAttribute('aria-label', 'Open notifications');
    bell.setAttribute('tabindex', '0');

    const onToggle = (e) => {
      e.preventDefault();
      e.stopPropagation();
      this.toggleDropdown();
      // Set a flag that the dropdown is open so we don't close on a quick follow-up click
      this._dropdownJustOpened = true;
      setTimeout(() => { this._dropdownJustOpened = false; }, 200);
    };
    // Use BOTH mousedown (capture) and click on the bell.
    // mousedown ensures we open the dropdown IMMEDIATELY on press
    // (avoids any click race).
    bell.addEventListener('mousedown', (e) => {
      // Don't stopPropagation on mousedown — let the outside-click handler
      // see it so it doesn't immediately close
      if (e.target.closest && e.target.closest('#notif-bell')) {
        // The bell or its descendants — toggle
        e.preventDefault();
        this.toggleDropdown();
        this._dropdownJustOpened = true;
        setTimeout(() => { this._dropdownJustOpened = false; }, 200);
      }
    });
    bell.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      // If mousedown already opened it, click just stops propagation
      if (this._dropdownJustOpened) return;
      this.toggleDropdown();
    });
    bell.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') onToggle(e);
    });

    // Stop events inside the dropdown from closing it
    const dd = document.getElementById('notif-dropdown');
    if (dd) {
      dd.addEventListener('click', (e) => e.stopPropagation());
      dd.addEventListener('mousedown', (e) => e.stopPropagation());
      // Make sure the dropdown is at the top of the stacking context
      dd.style.zIndex = '2147483000';
    }

    // Use mousedown for the outside-click close — this fires BEFORE click
    // and avoids the race condition where the bell's click toggles open and
    // the document click closes it on the same event tick.
    if (!window.__scNotifOutsideBound) {
      window.__scNotifOutsideBound = true;
      document.addEventListener('mousedown', (e) => {
        // Don't close if we just opened (avoids the same-tick race)
        if (this._dropdownJustOpened) return;
        const target = e.target;
        if (target.closest && (target.closest('#notif-dropdown') || target.closest('#notif-bell'))) return;
        this.closeDropdown();
      }, true);
    }
  },

  toggleDropdown() {
    const dd = document.getElementById('notif-dropdown');
    if (!dd) return;
    const isOpen = dd.classList.contains('show');
    if (isOpen) { this.closeDropdown(); return; }
    dd.classList.add('show');
    this.loadDropdownItems();
  },

  closeDropdown() {
    const dd = document.getElementById('notif-dropdown');
    if (dd) dd.classList.remove('show');
  },

  async loadDropdownItems() {
    const list = document.getElementById('notif-list');
    if (!list) return;
    list.innerHTML = '<div class="toast-msg" style="padding:24px;text-align:center"><span class="pulse">Loading…</span></div>';
    try {
      if (!this.sb) {
        list.innerHTML = '<div class="toast-msg" style="padding:24px;text-align:center;color:var(--gray-500)">Connect to database to see notifications.<br><small>Add Supabase keys in config.js</small></div>';
        return;
      }
      const items = await this.fetchRecent(10);
      if (!items.length) {
        list.innerHTML = '<div class="toast-msg" style="padding:24px;text-align:center">No notifications yet.</div>';
        return;
      }
      list.innerHTML = items.map(n => `
        <div class="notif-item" data-id="${this._esc(n.id)}" data-url="${this._esc(n.url || '')}" tabindex="0" role="button">
          <div class="notif-item-title">${(typeof esc==='function'?esc:this._esc)(n.title)}</div>
          <div class="notif-item-msg">${(typeof esc==='function'?esc:this._esc)(n.body || '')}</div>
          <div class="notif-item-time">${timeAgo(n.created_at)}</div>
        </div>`).join('');
      // Wire up the click handlers (more reliable than inline onclick)
      list.querySelectorAll('.notif-item').forEach(el => {
        el.addEventListener('click', (e) => {
          e.preventDefault();
          e.stopPropagation();
          this.openItem(el.getAttribute('data-id'), el.getAttribute('data-url'));
        });
      });
    } catch (err) {
      console.warn('[Notifications] loadDropdownItems error:', err.message || err);
      list.innerHTML = '<div class="toast-msg" style="padding:24px;text-align:center;color:var(--gray-500)">Could not load notifications.<br><small>' + (typeof esc==='function'?esc:this._esc)(err.message || 'Check database connection') + '</small></div>';
    }
  },

  async openItem(id, url) {
    try {
      if (this.sb && id) {
        const { data: { user } } = await this.sb.auth.getUser();
        if (user) {
          try { await this.sb.rpc('notif_mark_read', { p_id: id }); }
          catch(_) {
            const { data: n } = await this.sb.from('notifications').select('read_by').eq('id', id).maybeSingle();
            const read_by = (n && Array.isArray(n.read_by)) ? n.read_by : [];
            if (!read_by.includes(user.id)) { read_by.push(user.id); await this.sb.from('notifications').update({ read_by }).eq('id', id).then(r=>r,()=>{}); }
          }
        }
      }
    } catch(e) {}
    this.closeDropdown();
    this.refreshUnreadCount().catch(()=>{});
    const target = String(url || '').trim();
    if (target) location.href = target;
  },

  async fetchRecent(limit = 20) {
    if (!this.sb) return [];
    try {
      const { data, error } = await this.sb
        .from('notifications')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) return [];
      return (data || []).filter(n => Notifications.allowedForMe(n));
    } catch(e) { return []; }
  },

  /* ENTERPRISE V11 — audience semantics. */
  allowedForMe(n) {
    try {
      if (!n) return false;
      const uid  = (window.SC_PROFILE && SC_PROFILE.id) || '';
      const role = String((window.SC_PROFILE && SC_PROFILE.role) || (window.App && App.currentRole) || '').toLowerCase();
      const aud  = String(n.audience == null ? 'all' : n.audience).toLowerCase().trim();
      const isAdmin = window.App && App.isAdminRole && App.isAdminRole(role);
      if (isAdmin) return true;
      if (n.recipient_id && uid && n.recipient_id === uid) return true;
      if (!aud || aud === 'all' || aud === 'everyone' || aud === 'any') return true;
      if (aud === 'private') return !!(uid && (n.created_by === uid || n.recipient_id === uid));
      if (aud === role) return true;
      if ((aud === 'staff' || aud === 'teachers') && (role === 'staff' || role === 'teacher')) return true;
      if ((aud === 'parents') && role === 'parent') return true;
      if ((aud === 'students') && role === 'student') return true;
      return false;
    } catch (e) { return true; }
  },

  async refreshUnreadCount() {
    const badge = document.getElementById('notif-badge');
    if (!badge) return;
    if (!this.sb) { badge.style.display = 'none'; await this.renderPageList(); return; }
    let items, user;
    try { items = await this.fetchRecent(50); } catch (e) { items = []; }
    try { const r = await this.sb.auth.getUser(); user = r.data && r.data.user; } catch (e) { user = null; }
    const unread = items.filter(n => !(n.read_by || []).includes(user?.id || '')).length;
    if (unread > 0) { badge.textContent = unread > 99 ? '99+' : String(unread); badge.style.display = 'flex'; }
    else { badge.style.display = 'none'; }
    try { await this.renderPageList(items, user?.id || ''); } catch (e) {}
  },

  async renderPageList(prefetchedItems = null, currentUserId = '') {
    const list = document.getElementById('notif-page-list');
    if (!list) return;
    if (!this.sb) {
      list.innerHTML = '<div class="card"><h3 style="margin-top:0">Notifications</h3><p>Connect this portal to Supabase in <code>assets/js/config.js</code> to load live notifications here.</p></div>';
      return;
    }
    let items = Array.isArray(prefetchedItems) ? prefetchedItems : await this.fetchRecent(50);
    let uid = currentUserId;
    if (!uid) { try { const { data: { user } } = await this.sb.auth.getUser(); uid = user?.id || ''; } catch(_) {} }
    if (!items.length) {
      list.innerHTML = '<div class="card"><h3 style="margin-top:0">No notifications yet</h3><p>When staff send announcements, broadcasts, polls or result updates, they will appear here.</p></div>';
      return;
    }
    list.innerHTML = items.map(n => {
      const unread = !uid || !Array.isArray(n.read_by) ? true : !n.read_by.includes(uid);
      const channels = (() => { try { const c = JSON.parse(n.channels || '[]'); return Array.isArray(c) ? c : []; } catch(_) { return []; } })();
      const icon = n.priority === 'high' || n.priority === 'urgent' ? '🚨' : (n.audience === 'student' || n.audience === 'students' ? '🎓' : (n.audience === 'parent' || n.audience === 'parents' ? '👨‍👩‍👧' : '📢'));
      return `
        <div class="notif-entry ${unread ? 'unread' : ''}" data-id="${this._esc(n.id)}" data-url="${this._esc(n.url || '')}" tabindex="0" role="button">
          <div class="notif-entry-icon">${icon}</div>
          <div class="notif-entry-body">
            <div class="notif-entry-title">${this._esc(n.title || 'Notification')} ${unread ? '<span class="badge badge-success">new</span>' : ''}</div>
            <div class="notif-entry-msg">${this._esc(n.body || '')}</div>
            <div class="notif-entry-time">${timeAgo(n.created_at)}</div>
            <div class="notif-entry-channels">${channels.map(ch => `<span class="channel-pill">${this._esc(ch)}</span>`).join('')}</div>
          </div>
        </div>`;
    }).join('');
    list.querySelectorAll('.notif-entry').forEach(el => {
      el.addEventListener('click', (e) => {
        e.preventDefault(); e.stopPropagation();
        this.openItem(el.getAttribute('data-id'), el.getAttribute('data-url'));
      });
    });
  },

  async markAllRead() {
    if (!this.sb) return;
    const { data: { user } } = await this.sb.auth.getUser();
    if (!user) return;
    const items = await this.fetchRecent(50);
    for (const n of items) {
      const read_by = n.read_by || [];
      if (read_by.includes(user.id)) continue;
      try { await this.sb.rpc('notif_mark_read', { p_id: n.id }); }
      catch(_) { read_by.push(user.id); await this.sb.from('notifications').update({ read_by }).eq('id', n.id).then(r=>r,()=>{}); }
    }
    await this.refreshUnreadCount();
  },

  /* ---------- Create + Broadcast ---------- */
  async create({ title, body, url, audience = 'all', priority = 'normal', channels = ['inapp'], recipient_id = null }) {
    if (!this.sb) return { error: 'No database' };
    const row = {
      title: (title || '').trim(),
      body: (body || '').trim(),
      url: url || null,
      audience,
      priority,
      channels: JSON.stringify(channels),
      read_by: [],
      created_at: new Date().toISOString()
    };
    if (recipient_id) row.recipient_id = recipient_id;
    if (window.SC_PROFILE && SC_PROFILE.id) row.created_by = SC_PROFILE.id;
    const { data, error } = await this.sb.from('notifications').insert(row).select().single();
    if (error) return { error: error.message };
    if (channels.includes('inapp')) {
      this.refreshUnreadCount();
      try { this.showInApp(title || 'Notification', body || '', 'info', url || 'notifications.html'); } catch(_) {}
    }
    if (channels.includes('push') && document.visibilityState !== 'visible') this.broadcast({ title, body, url });
    if (channels.includes('email'))    this.composeEmail({ title, body, url });
    if (channels.includes('whatsapp')) this.composeWhatsApp({ title, body });
    if (channels.includes('sms'))      this.composeSMS({ title, body });
    return { data };
  },

  async broadcast({ title, body, url, tag }) {
    if (this.permission !== 'granted') return;
    const logoExt = (window.SCHOOL && window.SCHOOL.logoExt) || 'svg';
    const logo = 'assets/img/logo.' + logoExt;
    try {
      if (this.sw && this.sw.showNotification) {
        await this.sw.showNotification(title, { body, icon: logo, badge: logo, data: { url: url || '/' }, tag: tag || ('sc-' + Date.now()), requireInteraction: false, vibrate: [200, 100, 200] });
      } else if ('Notification' in window) {
        const n = new Notification(title, { body, icon: logo, tag });
        n.onclick = () => { if (url) location.href = url; n.close(); };
      }
    } catch (e) {}
  },

  
  ensureLiveTray() {
    if (typeof document === 'undefined') return null;
    let tray = document.getElementById('sc-live-notification-tray');
    if (!tray) {
      tray = document.createElement('div');
      tray.id = 'sc-live-notification-tray';
      tray.setAttribute('aria-live', 'polite');
      tray.style.cssText = 'position:fixed;right:18px;bottom:18px;z-index:2147482500;display:flex;flex-direction:column;gap:10px;max-width:min(420px,calc(100vw - 36px));pointer-events:none';
      document.body.appendChild(tray);
    }
    return tray;
  },

  showInApp(title, body, type = 'info', url = 'notifications.html') {
    const tray = this.ensureLiveTray();
    const safe = (typeof esc === 'function' ? esc : this._esc).bind(this);
    if (!tray) { try { toast(`${title} — ${body}`, type, 12000); } catch(_) {} return; }
    const card = document.createElement('div');
    card.className = 'sc-live-notification-card';
    card.style.cssText = 'pointer-events:auto;background:#fff;border:1px solid #dbeafe;border-left:5px solid #2563eb;border-radius:14px;box-shadow:0 18px 45px rgba(15,23,42,.22);padding:12px 14px;color:#0f172a;font-family:system-ui,sans-serif';
    card.innerHTML = '<div style="display:flex;gap:10px;align-items:flex-start"><div style="font-size:1.35rem">🔔</div><div style="flex:1;min-width:0"><div style="font-weight:900;margin-bottom:3px">'+safe(title||'Notification')+'</div><div style="font-size:.88rem;color:#475569;line-height:1.35">'+safe(body||'')+'</div><div style="margin-top:8px;display:flex;gap:8px;flex-wrap:wrap"><button type="button" data-open style="border:0;background:#2563eb;color:white;border-radius:8px;padding:6px 10px;font-weight:800;cursor:pointer">Open notifications</button><button type="button" data-dismiss style="border:1px solid #cbd5e1;background:white;color:#334155;border-radius:8px;padding:6px 10px;font-weight:700;cursor:pointer">Dismiss</button></div></div></div>';
    tray.prepend(card);
    card.querySelector('[data-dismiss]').onclick = () => card.remove();
    card.querySelector('[data-open]').onclick = () => { location.href = url || 'notifications.html'; };
    while (tray.children.length > 5) tray.lastElementChild.remove();
  },

  composeEmail({ title, body, url }) {
    const subject = encodeURIComponent(title);
    const text = encodeURIComponent(body + (url ? '\n\nOpen: ' + location.origin + '/' + url : ''));
    const href = `mailto:?subject=${subject}&body=${text}`;
    if (window.SC_CONFIRM_FREE_EMAIL) window.open(href);
  },

  composeWhatsApp({ title, body }) {
    const text = encodeURIComponent('*' + title + '*\n\n' + body);
    const href = `https://wa.me/?text=${text}`;
    if (window.SC_CONFIRM_FREE_WA) window.open(href);
  },

  composeSMS({ title, body }) {
    const text = encodeURIComponent(title + ' — ' + body);
    const href = `sms:?body=${text}`;
    if (window.SC_CONFIRM_FREE_SMS) window.open(href);
  },

  async startRealtimeListener() {
    if (!this.sb || !this.sb.channel) return;
    try {
      this.sb.channel('notifications-live')
        .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notifications' }, payload => {
          const n = payload.new;
          this.refreshUnreadCount();
          this.renderPageList().catch(()=>{});
          if (Notifications.allowedForMe(n)) this.showInApp(n.title || 'Notification', n.body || '', 'info', n.url || 'notifications.html');
          this.broadcast({ title: n.title, body: n.body, url: n.url, tag: 'n-' + n.id });
        })
        .subscribe();
    } catch (e) {}
  }
};

function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - base64String.length % 4) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; ++i) out[i] = raw.charCodeAt(i);
  return out;
}

function timeAgo(iso) {
  if (!iso) return '';
  const diff = Date.now() - new Date(iso).getTime();
  const sec = Math.floor(diff / 1000);
  if (sec < 60) return 'just now';
  const min = Math.floor(sec / 60);
  if (min < 60) return min + 'm ago';
  const hr = Math.floor(min / 60);
  if (hr < 24) return hr + 'h ago';
  const day = Math.floor(hr / 24);
  if (day < 30) return day + 'd ago';
  const d=new Date(iso); return String(d.getDate()).padStart(2,'0')+'/'+String(d.getMonth()+1).padStart(2,'0')+'/'+d.getFullYear();
}

window.Notifications = Notifications;
window.timeAgo = timeAgo;

console.log('%c[School Connect v15] Notifications ready — bulletproof bell + in-app + push + email + WhatsApp + SMS.', 'color:#10b981;font-weight:bold');
