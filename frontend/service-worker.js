const CACHE = 'faceswap-pwa-v1';
const ASSETS = ['/','/index.html','/styles.css','/app.js','/manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)));
  self.skipWaiting();
});
self.addEventListener('activate', e => {
  e.waitUntil(clients.claim());
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (ASSETS.includes(url.pathname) || url.pathname === '/') {
    e.respondWith(caches.match(e.request).then(r => r || fetch(e.request)));
  }
});