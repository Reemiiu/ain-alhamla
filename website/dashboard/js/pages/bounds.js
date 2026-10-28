// حدود المشاعر: من داخل حد عرفة/مزدلفة/منى ومن خارجه الآن، وساعات المبيت بمنى ليلة أمس.
import { supabase, rpc } from '../api.js';
import { renderShell, onTick, setSubtitle } from '../shell.js';
import { esc, timeAgo, toast, clock } from '../ui.js';
import { meters, prayerTimes, meccaDate, hm, loadLeaflet } from '../v3.js';

const shell = renderShell({ page: 'bounds.html', title: 'حدود المشاعر', subtitle: 'الوقوف خارج حدود عرفة يُبطل ركن الحج. النظام يقارن موقع كل حاج بحد المشعر.' });
const NAMES = { ARAFAH: 'عرفة', MUZDALIFAH: 'مزدلفة', MINA: 'منى' };
let site = 'ARAFAH', sites = [], map, layer;

if (shell) init(shell);

async function init({ content }) {
  content.innerHTML = `
    <div class="filter-row">
      <div class="seg" id="siteSeg">${Object.entries(NAMES).map(([k, v]) => `<button data-k="${k}" class="${k === site ? 'on' : ''}">${v}</button>`).join('')}</div>
      <button class="btn btn-primary" id="tickBtn">تنبيه من هم خارج الحد الآن</button>
    </div>
    <div class="stat-row" id="kpis"></div>
    <div class="row">
      <div class="card" style="flex:1.5"><div class="card-head"><h2 id="mapTitle">الخريطة</h2><span class="meta">الحدود المسجلة في القاعدة (تقريبية للعرض)</span></div>
        <div id="bmap" style="height:380px;border-radius:12px;overflow:hidden"></div></div>
      <div class="card" style="flex:1"><div class="card-head"><h2>خارج الحد</h2></div><div id="outList"></div></div>
    </div>
    <div class="card"><div class="card-head"><h2>المبيت بمنى · ليلة أمس</h2><span class="meta" id="nightMeta"></span></div>
      <div id="night"><div class="loading-state">جارٍ الحساب...</div></div></div>`;
  content.querySelectorAll('#siteSeg button').forEach((b) => b.onclick = () => {
    site = b.dataset.k; content.querySelectorAll('#siteSeg button').forEach((x) => x.classList.toggle('on', x === b)); loadSite(true);
  });
  document.getElementById('tickBtn').onclick = async () => {
    try { const r = await rpc('app_site_tick', { p_key: site }); toast(r.outside_alerts ? `أُرسل ${r.outside_alerts} تنبيه للحجاج ومشرفيهم مع الاتجاه` : 'لا يوجد حاج خارج الحد بدون تنبيه'); }
    catch (e) { toast(esc(e.message), 'danger'); }
  };
  const { data } = await supabase.from('sacred_sites').select('id, key, name, boundary, note').eq('is_active', true);
  sites = data ?? [];
  await loadSite(true);
  loadNight();
  onTick(() => loadSite(false));
}

async function loadSite(fit) {
  document.getElementById('mapTitle').textContent = `${NAMES[site]} الآن`;
  const rows = await rpc('app_site_check', { p_key: site });
  const out = rows.filter((r) => !r.inside);
  setSubtitle(`${NAMES[site]}: ${rows.length - out.length} داخل الحد · ${out.length} خارجه (من لهم موقع خلال ٣٠ دقيقة)`);
  document.getElementById('kpis').innerHTML = `
    <div class="stat-card"><div class="stat-card-head"><span>داخل حدود ${NAMES[site]}</span></div><div class="stat-value" style="color:var(--success)">${rows.length - out.length}</div><div class="stat-sub">من ${rows.length} حاجًا له موقع حديث</div></div>
    <div class="stat-card ${out.length ? 'danger' : ''}"><div class="stat-card-head"><span>خارج الحد</span></div><div class="stat-value ${out.length ? 'danger' : ''}">${out.length}</div><div class="stat-sub">يُنبَّهون مع اتجاه الدخول</div></div>`;
  document.getElementById('outList').innerHTML = out.map((r) => `
    <div class="contact-row"><div style="flex:1"><b>${esc(r.full_name)}</b><div class="meta">${timeAgo(r.at)} · اتجه نحو ${dir(r.lat, r.lng, r.edge_lat, r.edge_lng)}</div></div>
      <span class="pill crit">${meters(r.distance_m)} خارج الحد</span></div>`).join('') || `<div class="empty-state">كل الحجاج داخل حدود ${NAMES[site]}.</div>`;
  await drawMap(rows, fit);
}

function dir(lat, lng, elat, elng) {
  if (elat == null) return '—';
  const a = (Math.atan2((Number(elng) - Number(lng)) * Math.cos((Number(lat) * Math.PI) / 180), Number(elat) - Number(lat)) * 180 / Math.PI + 360) % 360;
  return ['الشمال', 'الشمال الشرقي', 'الشرق', 'الجنوب الشرقي', 'الجنوب', 'الجنوب الغربي', 'الغرب', 'الشمال الغربي'][Math.round(a / 45) % 8];
}

async function drawMap(rows, fit) {
  let L;
  try { L = await loadLeaflet(); } catch { document.getElementById('bmap').innerHTML = '<div class="empty-state">تعذّر تحميل الخريطة (لا إنترنت).</div>'; return; }
  if (!map) {
    map = L.map('bmap', { zoomControl: true, attributionControl: true });
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18, attribution: '© OpenStreetMap' }).addTo(map);
  }
  layer?.remove();
  layer = L.layerGroup().addTo(map);
  const s = sites.find((x) => x.key === site);
  let bounds = null;
  if (s) {
    const poly = L.polygon(s.boundary.map((p) => [p[0], p[1]]), { color: '#C9A24A', weight: 2, fillOpacity: 0.12 }).addTo(layer);
    bounds = poly.getBounds();
  }
  rows.forEach((r) => {
    const m = L.circleMarker([Number(r.lat), Number(r.lng)], { radius: r.inside ? 6 : 8, color: '#fff', weight: 2, fillColor: r.inside ? '#3F7A57' : '#B23B2E', fillOpacity: 1 })
      .bindTooltip(`${esc(r.full_name)}${r.inside ? '' : ` · ${meters(r.distance_m)} خارج الحد`}`).addTo(layer);
    if (!r.inside && r.edge_lat != null) {
      L.polyline([[Number(r.lat), Number(r.lng)], [Number(r.edge_lat), Number(r.edge_lng)]], { color: '#B23B2E', dashArray: '4 4', weight: 2 }).addTo(layer);
      bounds = bounds ? bounds.extend(m.getLatLng()) : L.latLngBounds([m.getLatLng()]);
    }
  });
  if (fit && bounds) map.fitBounds(bounds.pad(0.15));
}

async function loadNight() {
  const today = new Date(), y = new Date(today.getTime() - 86400000);
  const from = meccaDate(y, prayerTimes(y).maghrib), to = meccaDate(today, prayerTimes(today).fajr);
  document.getElementById('nightMeta').textContent = `من المغرب ${hm(prayerTimes(y).maghrib)} إلى الفجر ${hm(prayerTimes(today).fajr)} · المطلوب أكثر من نصف الليل`;
  try {
    const r = await rpc('app_overnight_report', { p_from: from.toISOString(), p_to: to.toISOString(), p_key: 'MINA' });
    const half = Number(r.required_hours), full = Number(r.night_hours);
    document.getElementById('night').innerHTML = `<div class="meta" style="margin-bottom:8px">الليل ${full} ساعة · أكثر الليل = أكثر من ${half} ساعة</div>` +
      r.pilgrims.map((p) => {
        const h = Number(p.hours), pct = Math.min(100, (h / full) * 100), cls = p.complete ? 'good' : h > half * 0.7 ? 'warn' : 'crit';
        return `<div class="night-row"><span class="night-name">${esc(p.name)}</span>
          <span class="night-track"><i style="width:${pct}%;background:var(--${cls === 'good' ? 'success' : cls === 'warn' ? 'warning' : 'danger'})"></i><em></em></span>
          <span class="pill ${cls}">${h} س</span></div>`;
      }).join('');
  } catch (e) { document.getElementById('night').innerHTML = `<div class="empty-state">${esc(e.message)}</div>`; }
}
