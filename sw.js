// School Connect — Service Worker (V5 cumulative release, generator v8)
// Bump this literal on every runtime release so previously cached CBT/report code is purged.
const CACHE = 'sc-client-v12.76-20261108-68';
const CORE = [
  './', './index.html', './builder.html', './voting.html', './notifications.html',
  './install.html', './midterm-reports.html', './ecosystem.html', './about.html', './guide.html', './offline.html',
  './assets/css/style.css',
  './assets/js/config.js', './assets/js/catalog.js',
  './assets/js/notifications.js', './assets/js/voting.js', './assets/js/pwa-install.js',
  './assets/js/qrcode-generator.js','./assets/js/super.js', './assets/js/wizard.js', './assets/js/generator.js', './assets/js/templates.js', './assets/js/site-help.js',
  './assets/js/theme-manager.js', './assets/js/messages-center.js', './assets/js/drive-sync.js', './assets/js/proctor.js',
  './assets/img/logo.svg', './assets/img/favicon.svg', './manifest.json',
  /* V12.76 — the libraries are part of the app now, not a CDN's favour */
  './assets/vendor/supabase-js-2.58.0.js', './assets/vendor/chart.umd.js',
  './assets/vendor/jsqr.min.js', './assets/vendor/jszip.min.js'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(CORE).catch(err => console.warn('[SW] precache failed', err.message))).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
      .then(() => self.clients.matchAll({type: 'window'}).then(clients => {
        clients.forEach(client => client.postMessage({type: 'SW_UPDATED', version: CACHE}));
      }))
  );
});

// Manual skipWaiting trigger (kept for pwa-install.js Update Now button)
self.addEventListener('message', e => {
  if (e.data && e.data.type === 'SKIP_WAITING') self.skipWaiting();
  /* V12.74 (item 8) — the client needs a REAL version identity. It used
     registration.scriptURL, which is the same string for every release, so it
     could not tell an old version from a new one and the "Update now" banner
     reappeared even when the platform was already current. */
  if (e.data && e.data.type === 'GET_VERSION' && e.ports && e.ports[0]) {
    e.ports[0].postMessage({ version: CACHE });
  }
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== location.origin && !e.request.url.includes('fonts.googleapis')) return;

  if (e.request.mode === 'navigate') {
    // Sensitive CBT entry/result page: never serve a cached candidate page on shared devices.
    // Network required for authentication/exam lookup; offline fallback is generic, not a prior score.
    if (/\/cbt-exam\.html$/i.test(url.pathname)) {
      e.respondWith((async()=>{ try { return await fetch(new Request(e.request,{cache:'no-store'})); } catch(_) { return (await caches.match('./offline.html')) || new Response('You are offline. Reconnect to start or continue this CBT.',{status:503,headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store'}}); } })());
      return;
    }
    e.respondWith((async () => {
      const cached = await caches.match(e.request);
      try {
        const net = await Promise.race([
          fetch(e.request),
          new Promise((_, rej) => setTimeout(() => rej(new Error('slow-network')), 4000))
        ]);
        if (net.ok) {
          const clone = net.clone();
          caches.open(CACHE).then(cache => cache.put(e.request, clone));
        }
        return net;
      } catch (err) {
        if (cached) return cached;
        return (await caches.match('./offline.html')) || (await caches.match('./index.html'));
      }
    })());
    return;
  }

  // V12.48: Network-first for executable/page assets. Stale-while-revalidate served old CBT JS/HTML
  // on the first visit after deploy, causing users to keep seeing old edit/verify code.
  const isRuntimeAsset = e.request.destination === 'script' || e.request.destination === 'style' || /\.(?:js|mjs|css|html)$/i.test(url.pathname);
  if (isRuntimeAsset) {
    e.respondWith((async () => {
      const cached = await caches.match(e.request);
      try {
        const freshReq = new Request(e.request, {cache:'reload'});
        const net = await Promise.race([fetch(freshReq), new Promise((_,rej)=>setTimeout(()=>rej(new Error('runtime-timeout')),6000))]);
        if (net && net.ok) { const copy=net.clone(); caches.open(CACHE).then(c=>c.put(e.request,copy)); return net; }
        return cached || net;
      } catch (_) { return cached || Response.error(); }
    })());
    return;
  }

  // Assets: stale-while-revalidate for instant load on slow networks
  e.respondWith(
    caches.match(e.request).then(cached => {
      const fetchAndUpdate = fetch(e.request).then(res => {
        if (res.ok && e.request.url.startsWith(self.location.origin)) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return res;
      }).catch(() => cached);
      return cached || fetchAndUpdate;
    })
  );
});

// Push notification handler
self.addEventListener('push', e => {
  let data = { title: 'School Connect', body: 'You have a new notification', url: '/' };
  try { if (e.data) data = Object.assign(data, e.data.json()); } catch (_) { if (e.data) data.body = e.data.text(); }
  e.waitUntil(self.registration.showNotification(data.title, {
    body: data.body,
    icon: 'assets/img/logo.svg',
    badge: 'assets/img/logo.svg',
    data: { url: data.url },
    tag: data.tag || ('sc-' + Date.now()),
    requireInteraction: false,
    vibrate: [200, 100, 200]
  }));
});

// Notification click → focus existing tab or open the URL
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil(
    clients.matchAll({ type: 'window' }).then(list => {
      for (const c of list) {
        if (c.url.includes(url.split('?')[0])) return c.focus();
      }
      return clients.openWindow(url);
    })
  );
});
