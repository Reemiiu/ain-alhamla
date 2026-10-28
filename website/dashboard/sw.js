// عين الحملة — Service Worker للوحة التحكم
// 1) يحفظ صفحات اللوحة وملفاتها ومكتبات CDN (Leaflet / Supabase / الخطوط) لتفتح بدون إنترنت.
// 2) يحفظ صور الخريطة (OpenStreetMap) التي عُرضت أو حُفظت مسبقاً، ويعرضها عند الانقطاع.
// بيانات Supabase نفسها لا تُحفظ هنا — الخريطة تحفظ آخر نسخة منها في المتصفح (live-map.js).
const APP_CACHE = 'ain-dash-v3.2';
const TILE_CACHE = 'ain-dash-tiles-v1';
const MAX_TILES = 4000;
const SHELL = [
  'login.html', 'index.html', 'map.html', 'alerts.html', 'css/dashboard.css',
  'js/shell.js', 'js/ui.js', 'js/api.js', 'js/live-map.js', 'js/login.js', 'js/supabase-client.js', 'js/supabase-config.js',
  'js/pages/index.js', 'js/pages/map.js', 'js/pages/alerts.js', '../assets/logo.jpg',
  'smart.html', 'bounds.html', 'health.html', 'family.html', 'ops.html', 'css/v3.css', 'js/v3.js',
  'js/pages/smart.js', 'js/pages/bounds.js', 'js/pages/health.js', 'js/pages/family.js', 'js/pages/ops.js',
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
    for (const k of await caches.keys()) {
      if (k.startsWith('ain-dash-') && k !== APP_CACHE && k !== TILE_CACHE) await caches.delete(k);
    }
    await self.clients.claim();
  })());
});

const timeout = (ms) => new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms));
const okToCache = (res) => res && (res.ok || res.type === 'opaque');

async function networkFirst(req) {
  const cache = await caches.open(APP_CACHE);
  try {
    const res = await Promise.race([fetch(req), timeout(8000)]);
    if (okToCache(res)) cache.put(req, res.clone());
    return res;
  } catch (e) {
    const hit = await cache.match(req, { ignoreSearch: true });
    if (hit) return hit;
    if (req.mode === 'navigate') return (await cache.match('index.html')) || Response.error();
    throw e;
  }
}

async function cacheFirst(req, name) {
  const cache = await caches.open(name);
  const hit = await cache.match(req, { ignoreVary: true });
  if (hit) return hit;
  const res = await fetch(req);
  if (okToCache(res)) {
    await cache.put(req, res.clone());
    if (name === TILE_CACHE && Math.random() < 0.02) trimTiles();
  }
  return res;
}

async function trimTiles() {
  const cache = await caches.open(TILE_CACHE);
  const keys = await cache.keys();
  for (let i = 0; i < keys.length - MAX_TILES; i++) await cache.delete(keys[i]);
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co')) return;                       // البيانات الحية: من الشبكة فقط
  if (url.hostname.endsWith('tile.openstreetmap.org')) {
    event.respondWith(cacheFirst(req, TILE_CACHE));                      // صور الخريطة
  } else if (/(^|\.)(jsdelivr\.net|unpkg\.com|gstatic\.com|googleapis\.com)$/.test(url.hostname)) {
    event.respondWith(cacheFirst(req, APP_CACHE));                       // مكتبات بإصدار ثابت + الخطوط
  } else if (url.origin === self.location.origin) {
    event.respondWith(networkFirst(req));                                // صفحات اللوحة
  }
});
