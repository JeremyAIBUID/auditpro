const VERSION = '20260416034912';
const CACHE   = 'auditpro-' + VERSION;
const FALLBACKS = ['/mobile', '/manifest.json'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(FALLBACKS)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => { if(e.request.method !== 'GET') return; e.respondWith(fetch(e.request).then(r => { const cl = r.clone(); caches.open(CACHE).then(c => c.put(e.request, cl)); return r; }).catch(() => caches.match(e.request).then(c => c || caches.match('/mobile')))); });
self.addEventListener('message', e => { if(e.data === 'SKIP_WAITING') self.skipWaiting(); });
