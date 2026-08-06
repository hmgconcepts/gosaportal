// School Connect Service Worker — V5 cumulative release (offline + push + timeout)
// Literal cache version intentionally changes with every runtime deployment.
const CACHE = 'sc-client-v7.7-20260806-32';
const CORE = ['./','./index.html','./login.html','./dashboard.html','./offline.html','./assets/css/style.css','./assets/js/config.js','./assets/js/app.js','./assets/js/crud.js','./assets/js/drive-sync.js','./assets/js/security-guard.js','./assets/js/cbt-engine.js','./assets/js/report-engine.js','./assets/js/notifications.js','./assets/js/voting.js','./assets/js/pwa-install.js','./assets/js/super.js','./assets/js/site-help.js','./assets/js/enterprise.js','./assets/js/analytics.js','./assets/img/logo.png','./manifest.json'];

self.addEventListener('install', e => {
  // Cache independently: addAll() is atomic, so one missing optional asset
  // previously resulted in no offline cache at all.
  e.waitUntil(caches.open(CACHE).then(async c => {
    const results = await Promise.allSettled(CORE.map(url => c.add(url)));
    const failed = results.filter(r => r.status === 'rejected').length;
    if (failed) console.warn('[SW] skipped', failed, 'unavailable precache resource(s)');
    await self.skipWaiting();
  }));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== location.origin && !e.request.url.includes('fonts.googleapis')) return;
  if (e.request.mode === 'navigate') {
    e.respondWith((async () => {
      const cached = await caches.match(e.request);
      try {
        const net = await Promise.race([
          fetch(e.request),
          new Promise((_, rej) => setTimeout(() => rej(new Error('slow')), 4000))
        ]);
        if (net.ok) { const copy = net.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
        return net;
      } catch (_) {
        return cached || caches.match('./offline.html') || caches.match('./index.html');
      }
    })());
    return;
  }
  e.respondWith(
    caches.match(e.request).then(cached => {
      const network = fetch(e.request).then(res => {
        if (res.ok && e.request.url.startsWith(self.location.origin)) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return res;
      }).catch(() => cached);
      return cached || network;
    })
  );
});
self.addEventListener('push', e => {
  let data = { title: 'God of Seed Academy', body: 'You have a new notification' };
  try { if (e.data) data = Object.assign(data, e.data.json()); } catch (_) {}
  e.waitUntil(self.registration.showNotification(data.title, {
    body: data.body, icon: 'assets/img/logo.png', badge: 'assets/img/logo.png',
    data: data, vibrate: [200,100,200], tag: data.tag || 'sc-' + Date.now()
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil(clients.matchAll({ type: 'window' }).then(list => {
    for (const c of list) { if (c.url.includes(url)) return c.focus(); }
    return clients.openWindow(url);
  }));
});
