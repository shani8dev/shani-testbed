const C = 'fixture-v1';
self.addEventListener('install', e => e.waitUntil(caches.open(C).then(c => c.addAll(['/', '/index.html', '/logo.svg'])).then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => e.respondWith(caches.match(e.request).then(r => r || fetch(e.request))));
