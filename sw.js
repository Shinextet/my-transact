const CACHE_VERSION = 'txpro-v' + Date.now();

self.addEventListener('install', e => {
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  // Network first — always get fresh content
  e.respondWith(
    fetch(e.request, { cache: 'no-cache' })
      .catch(() => caches.match(e.request))
  );
});
