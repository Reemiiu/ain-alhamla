// الخريطة الحية: النطاقات + آخر موقع لكل حاج ومشرف (من app_live_positions حسب الدور) + البلاغات المفتوحة.
// v2.1 — تعمل بدون إنترنت: آخر بيانات تُحفظ في المتصفح، وصور الخريطة يحفظها sw.js،
// وزر «حفظ الخريطة بدون إنترنت» ينزّل مسبقاً صور منطقة صغيرة حول مواقع الحملة فقط.
import { supabase, rpc } from './api.js';
import { esc, timeAgo, ATT, ALERT_TYPE, PRIORITY } from './ui.js';

const C = { CHECKPOINT: '#C9A24A', SAFE_ZONE: '#3F7A57', good: '#3F7A57', warn: '#B5761E', crit: '#B23B2E', muted: '#9C9585', sup: '#12332A' };

function loadCss(href) {
  if (document.querySelector(`link[href="${href}"]`)) return;
  document.head.appendChild(Object.assign(document.createElement('link'), { rel: 'stylesheet', href }));
}
function loadScript(src) {
  return new Promise((res, rej) => {
    if (window.L) return res();
    const s = Object.assign(document.createElement('script'), { src, onload: res, onerror: rej });
    document.head.appendChild(s);
  });
}

const DATA_KEY = 'ain_dash_map_data_v1';
export const TILE_URL = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const TILE_CACHE = 'ain-dash-tiles-v1';

function saveCache(d) {
  try { localStorage.setItem(DATA_KEY, JSON.stringify({ at: new Date().toISOString(), d })); } catch { /* التخزين غير متاح */ }
}
function readCache() {
  try { const raw = localStorage.getItem(DATA_KEY); return raw ? JSON.parse(raw) : null; } catch { return null; }
}

/** يجلب بيانات الخريطة؛ وعند انقطاع الإنترنت يعيد آخر نسخة محفوظة مع offline=true */
export async function loadMapDataSafe() {
  try {
    const d = await loadMapData();
    saveCache(d);
    return { ...d, offline: false };
  } catch (e) {
    const c = readCache();
    if (!c) throw e;
    return { ...c.d, offline: true, savedAt: c.at };
  }
}

// ---------- حفظ صور الخريطة مسبقاً (حول مواقع الحملة فقط) ----------
const tileX = (lng, z) => Math.floor(((lng + 180) / 360) * 2 ** z);
const tileY = (lat, z) => { const r = (lat * Math.PI) / 180; return Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * 2 ** z); };

export function tilesAround(locations) {
  const set = new Set();
  const box = (s, w, n, e, z) => {
    for (let x = tileX(w, z); x <= tileX(e, z); x++) for (let y = tileY(n, z); y <= tileY(s, z); y++) set.add(`${z}/${x}/${y}`);
  };
  const pts = locations.map((l) => ({ lat: Number(l.latitude), lng: Number(l.longitude), r: Number(l.radius_meters) || 200 }))
    .filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng));
  if (!pts.length) return [];
  const lats = pts.map((p) => p.lat), lngs = pts.map((p) => p.lng);
  for (let z = 11; z <= 13; z++) box(Math.min(...lats) - 0.01, Math.min(...lngs) - 0.01, Math.max(...lats) + 0.01, Math.max(...lngs) + 0.01, z);
  for (const p of pts) {
    const m = Math.max(500, p.r * 1.5), dLat = m / 111320, dLng = m / (111320 * Math.cos((p.lat * Math.PI) / 180));
    for (let z = 14; z <= 17; z++) box(p.lat - dLat, p.lng - dLng, p.lat + dLat, p.lng + dLng, z);
  }
  return [...set].slice(0, 1500).map((k) => TILE_URL.replace('{z}/{x}/{y}', k));
}

/** ينزّل صور الخريطة غير المحفوظة واحدة واحدة. onProgress(done, total) */
export async function saveOfflineArea(locations, onProgress) {
  if (!('caches' in window)) return { complete: false, total: 0, supported: false };
  const urls = tilesAround(locations);
  const cache = await caches.open(TILE_CACHE);
  let complete = true;
  for (let i = 0; i < urls.length; i++) {
    if (!(await cache.match(urls[i]))) {
      try {
        const res = await fetch(urls[i], { mode: 'cors' });
        if (!res.ok) throw new Error(res.status);
        await cache.put(urls[i], res);
      } catch { complete = false; break; }
      await new Promise((r) => setTimeout(r, 60));
    }
    onProgress?.(i + 1, urls.length);
  }
  return { complete, total: urls.length, supported: true };
}

export async function savedTilesCount() {
  try { return (await (await caches.open(TILE_CACHE)).keys()).length; } catch { return 0; }
}

export async function loadMapData() {
  const [loc, live, alerts] = await Promise.all([
    supabase.from('locations').select('id, name, type, latitude, longitude, radius_meters'),
    rpc('app_live_positions'),
    supabase.from('alerts').select('id, type, severity, latitude, longitude, created_at, pilgrim_id')
      .neq('status', 'RESOLVED').in('type', ['SOS', 'LOST']).not('latitude', 'is', null),
  ]);
  if (loc.error) throw loc.error;
  if (alerts.error) throw alerts.error;
  return { locations: loc.data ?? [], pilgrims: live.pilgrims ?? [], supervisors: live.supervisors ?? [], alerts: alerts.data ?? [] };
}

function pilgrimColor(p) {
  if (p.open_alert === 'SOS' || p.open_alert === 'LOST' || p.open_alert === 'GEOFENCE_BREACH') return C.crit;
  return C[ATT[p.status]?.cls ?? 'muted'];
}

export async function createLiveMap(el, { height = 420, onPilgrim } = {}) {
  el.style.height = typeof height === 'number' ? `${height}px` : height;
  el.classList.add('live-map');
  loadCss('https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css');
  await loadScript('https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js');
  const L = window.L;
  const map = L.map(el, { zoomControl: true });
  L.tileLayer(TILE_URL, { maxZoom: 19, attribution: '© OpenStreetMap contributors' }).addTo(map);
  const layer = L.layerGroup().addTo(map);
  let fitted = false;
  // شريط يظهر فوق الخريطة عند انقطاع الإنترنت
  const banner = Object.assign(document.createElement('div'), { className: 'map-offline', hidden: true });
  el.appendChild(banner);

  async function refresh() {
    const d = await loadMapDataSafe();
    banner.hidden = !d.offline;
    if (d.offline) banner.textContent = `بدون إنترنت — آخر بيانات محفوظة ${timeAgo(d.savedAt)}، والخريطة من ذاكرة المتصفح`;
    layer.clearLayers();
    const pts = [];
    d.locations.forEach((l) => {
      const c = C[l.type] ?? C.sup, ll = [Number(l.latitude), Number(l.longitude)];
      L.circle(ll, { radius: l.radius_meters, color: c, fillColor: c, fillOpacity: 0.12, weight: 1.5 }).addTo(layer)
        .bindPopup(`<b>${esc(l.name)}</b><br>${l.type === 'CHECKPOINT' ? 'نقطة تجمع' : 'منطقة آمنة'} · نطاق ${l.radius_meters} م`);
      L.marker(ll, { icon: L.divIcon({ className: 'lm-label', html: `<span>${esc(l.name)}</span>` }) }).addTo(layer);
    });
    d.supervisors.forEach((s) => {
      const ll = [Number(s.lat), Number(s.lng)];
      L.marker(ll, { icon: L.divIcon({ className: 'lm-sup', html: '<span>م</span>', iconSize: [24, 24] }) }).addTo(layer)
        .bindPopup(`<b>المشرف ${esc(s.name)}</b><br>${timeAgo(s.at)}`);
      pts.push(ll);
    });
    d.pilgrims.forEach((p) => {
      const ll = [Number(p.lat), Number(p.lng)];
      const crit = p.priority === 'CRITICAL';
      const m = L.circleMarker(ll, { radius: crit ? 8 : 7, color: crit ? '#C9A24A' : '#fff', weight: crit ? 3 : 2, fillColor: pilgrimColor(p), fillOpacity: 1 })
        .addTo(layer).bindPopup(`<b>${esc(p.name)}</b><br>${esc(p.group ?? '')}<br>
          ${ATT[p.status]?.label ?? 'لم يسجّل'}${p.open_alert ? ` · <b style="color:#B23B2E">${ALERT_TYPE[p.open_alert] ?? p.open_alert}</b>` : ''}<br>
          ${p.priority !== 'NORMAL' ? `أولوية ${PRIORITY[p.priority]?.label} · ` : ''}🔋 ${p.battery ?? '—'}٪ · ${timeAgo(p.at)}`);
      if (onPilgrim) m.on('click', () => onPilgrim(p));
      pts.push(ll);
    });
    d.alerts.forEach((a) => {
      const ll = [Number(a.latitude), Number(a.longitude)];
      L.marker(ll, { icon: L.divIcon({ className: 'lm-sos', html: `<span>${a.type === 'SOS' ? 'SOS' : 'تائه'}</span>`, iconSize: [38, 38] }) })
        .addTo(layer).bindPopup(`<b style="color:#B23B2E">${ALERT_TYPE[a.type]}</b><br>${timeAgo(a.created_at)}<br><a href="alerts.html">فتح الاستجابة</a>`);
      pts.push(ll);
    });
    if (!fitted) {
      if (pts.length) map.fitBounds(pts, { padding: [30, 30], maxZoom: 16 });
      else map.setView([21.4135, 39.8905], 13);
      fitted = true;
    }
    setTimeout(() => map.invalidateSize(), 150);
    return d;
  }

  await refresh();
  return { map, refresh, focus: (lat, lng) => map.setView([lat, lng], 17) };
}

export const MAP_LEGEND = `
  <div class="map-legend">
    <span><i style="background:#3F7A57"></i>حاضر</span><span><i style="background:#B5761E"></i>متأخر</span>
    <span><i style="background:#B23B2E"></i>غائب / خارج النطاق / بلاغ</span><span><i style="background:#9C9585"></i>لم يسجّل</span>
    <span><i style="background:#fff;box-shadow:0 0 0 3px #C9A24A"></i>أولوية حرجة</span>
    <span><i style="background:#12332A;border-radius:3px"></i>مشرف</span><span><i style="background:#C9A24A;opacity:.5"></i>نقطة تجمع</span>
  </div>`;
