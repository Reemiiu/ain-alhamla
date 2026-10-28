// عين الحملة — Service Worker لنسخة الويب من تطبيق الحاج
// يحفظ ملفات التطبيق (والمحرك والخطوط) حتى يفتح التطبيق بدون إنترنت في المشاعر.
// صور الخريطة يحفظها التطبيق نفسه في ain-map-tiles-v1، وبيانات Supabase لا تُحفظ هنا.
const APP_CACHE = 'ain-app-v2.1';
const KEEP = [APP_CACHE, 'ain-map-tiles-v1'];
const SHELL = [
  './', 'index.html', 'flutter_bootstrap.js', 'main.dart.js', 'manifest.json', 'favicon.png',
  'icons/Icon-192.png', 'assets/AssetManifest.bin.json', 'assets/FontManifest.json', 'assets/assets/logo.jpg',
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(APP_CACHE);
    await Promise.all(SHELL.map((u) => cache.add(u).catch(() => {})));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const k of await caches.keys()) if (!KEEP.includes(k)) await caches.delete(k);
    await self.clients.claim();
  })());
});

function timeout(ms) { return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms)); }

// ملفات التطبيق: من الشبكة أولاً (لتصل التحديثات)، وعند الانقطاع من المحفوظ
async function networkFirst(req) {
  const cache = await caches.open(APP_CACHE);
  try {
    const res = await Promise.race([fetch(req), timeout(8000)]);
    if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone());
    return res;
  } catch (e) {
    const hit = await cache.match(req, { ignoreSearch: true });
    if (hit) return hit;
    if (req.mode === 'navigate') return (await cache.match('index.html')) || (await cache.match('./'));
    throw e;
  }
}

// المحرك (CanvasKit) والخطوط لا تتغير: من المحفوظ أولاً
async function cacheFirst(req) {
  const cache = await caches.open(APP_CACHE);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone());
  return res;
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co') || url.hostname.endsWith('openstreetmap.org') || url.pathname.includes('/__ain_tiles/')) return;
  if (url.hostname.endsWith('gstatic.com') || url.hostname.endsWith('googleapis.com')) {
    event.respondWith(cacheFirst(req));
  } else if (url.origin === self.location.origin) {
    event.respondWith(networkFirst(req));
  }
});
