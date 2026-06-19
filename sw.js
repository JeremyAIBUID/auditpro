// AuditPro Service Worker v10 - force cache clear (r21 scale debug raw packet capture)
const CACHE_NAME = 'auditpro-v10';

self.addEventListener('install', e => {
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.map(key => caches.delete(key)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  // Network first - always get fresh content
  e.respondWith(
    fetch(e.request).catch(() => caches.match(e.request))
  );
});
