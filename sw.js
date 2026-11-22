/*
 * Offline cache. The point of the app is answering at 6:45am on a bad
 * connection, so everything needed to answer is cached on first load and
 * served from cache first. The one thing never cached is the live feed:
 * a stale closing is worse than none.
 */
// The build stamps a new value in here every time the app is rebuilt.
//
// This matters more than it looks. The browser only notices a new version of
// this file if the file's own contents changed. With a fixed name, someone who
// opened the app once would keep the files they saved that day for ever, and
// every later update - including the monthly refresh - would reach nobody.
const CACHE = 'schools-20261122063524';
const ASSETS = ['./', 'index.html', 'engine.js', 'district.js', 'app.js',
                'data/pack.js', 'data/rules.js', 'data/districts.js',
                'manifest.webmanifest', 'icon.svg'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;           // never cache the live feed
  if (e.request.method !== 'GET') return;
  e.respondWith(
    caches.match(e.request).then((hit) => hit || fetch(e.request).then((res) => {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
      return res;
    }).catch(() => caches.match('index.html')))
  );
});
