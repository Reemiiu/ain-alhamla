// أدوات مشتركة لصفحات v3/v4: مؤشر الخطر، المسافات، مواقيت الصلاة، وأداة سيناريو العرض.
import { rpc } from './api.js';
import { esc, toast } from './ui.js';

export function riskColor(s) { return s >= 60 ? 'var(--danger)' : s >= 30 ? 'var(--warning)' : 'var(--success)'; }
export function riskLabel(s) { return s >= 60 ? 'مرتفع' : s >= 30 ? 'متوسط' : 'منخفض'; }
export function riskBar(s) {
  const v = Math.max(0, Math.min(100, Number(s) || 0));
  return `<span class="risk"><span class="risk-track"><i style="width:${v}%;background:${riskColor(v)}"></i></span><b>${v}</b></span>`;
}
export function meters(m) {
  if (m == null) return '—';
  return m >= 1000 ? `${(m / 1000).toFixed(1)} كم` : `${m} م`;
}
export function distPill(m, warnAt, critAt) {
  if (m == null) return '<span class="pill muted">لا موقع</span>';
  const cls = m >= critAt ? 'crit' : m >= warnAt ? 'warn' : 'good';
  return `<span class="pill ${cls}">${meters(m)}</span>`;
}

// مواقيت الصلاة (طريقة أم القرى: الفجر 18.5°، العشاء = المغرب + 90 دقيقة)
const rad = (d) => (d * Math.PI) / 180, deg = (r) => (r * 180) / Math.PI;
export function prayerTimes(date, lat = 21.4133, lng = 39.8933, tz = 3) {
  const d0 = Date.UTC(date.getFullYear(), date.getMonth(), date.getDate());
  const d = d0 / 86400000 + 2440587.5 - 2451545.0;
  const g = rad((357.529 + 0.98560028 * d) % 360), q = (280.459 + 0.98564736 * d) % 360;
  const L = rad((q + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) % 360), e = rad(23.439 - 0.00000036 * d);
  let RA = deg(Math.atan2(Math.cos(e) * Math.sin(L), Math.cos(L))) / 15; RA = (RA + 24) % 24;
  const decl = Math.asin(Math.sin(e) * Math.sin(L));
  let eqt = q / 15 - RA; eqt = ((eqt + 12) % 24 + 24) % 24 - 12;
  const noon = 12 + tz - lng / 15 - eqt, la = rad(lat);
  const T = (a) => deg(Math.acos((-Math.sin(rad(a)) - Math.sin(decl) * Math.sin(la)) / (Math.cos(decl) * Math.cos(la)))) / 15;
  const maghrib = noon + T(0.833);
  return { fajr: noon - T(18.5), sunrise: noon - T(0.833), dhuhr: noon, maghrib, isha: maghrib + 1.5 };
}
/** يحوّل ساعة عشرية بتوقيت مكة في يوم معيّن إلى Date */
export function meccaDate(day, hours) {
  const ms = Date.UTC(day.getFullYear(), day.getMonth(), day.getDate()) + (hours - 3) * 3600000;
  return new Date(ms);
}
export function hm(h) { const m = Math.round(h * 60); return `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`; }

/** شريط أداة العرض (للإدارة فقط) */
export function scenarioBar() {
  return `<div class="card demo-tools"><div class="card-head"><h2>أداة العرض</h2>
      <span class="meta">تضع الحجاج في مواقع واقعية الآن بدل GPS الجوالات، وتحدّث الحرارة والزحام والجرعات. كل البيانات تُكتب في القاعدة.</span></div>
    <div class="board-actions">
      <button class="btn btn-primary" data-scn="MINA">سيناريو منى</button>
      <button class="btn btn-primary" data-scn="ARAFAH">سيناريو عرفة</button>
      <button class="btn btn-outline" id="runChecks">تشغيل الفحص الذكي الآن</button>
    </div></div>`;
}
export function bindScenario(root, after) {
  root.querySelectorAll('[data-scn]').forEach((b) => b.onclick = async () => {
    b.disabled = true;
    try {
      const r = await rpc('app_demo_scenario', { p_scenario: b.dataset.scn });
      toast(`تم تشغيل ${b.dataset.scn === 'MINA' ? 'سيناريو منى' : 'سيناريو عرفة'}: ${r.positions} موقع جديد`);
      await runChecks(true);
      after?.();
    } catch (e) { toast(esc(e.message), 'danger'); } finally { b.disabled = false; }
  });
  const rc = root.querySelector('#runChecks');
  if (rc) rc.onclick = async () => { await runChecks(false); after?.(); };
}
export async function runChecks(quiet) {
  try {
    const [s, h] = await Promise.all([rpc('app_smart_tick'), rpc('app_health_tick')]);
    const n = s.buddy_split_alerts + s.heat_alerts + h.missed_doses + h.escalated_checks;
    if (!quiet || n) toast(n ? `الفحص الذكي: ${s.buddy_split_alerts} انفصال رفاق · ${s.heat_alerts} إجهاد حراري · ${h.missed_doses} جرعة فائتة · ${h.escalated_checks} بلا رد` : 'الفحص الذكي: لا تنبيهات جديدة', n ? 'warn' : 'info');
  } catch (e) { toast(esc(e.message), 'danger'); }
}

export function loadLeaflet() {
  if (!document.querySelector('link[href*="leaflet.css"]')) {
    document.head.appendChild(Object.assign(document.createElement('link'), { rel: 'stylesheet', href: 'https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css' }));
  }
  return new Promise((res, rej) => {
    if (window.L) return res(window.L);
    const s = Object.assign(document.createElement('script'), { src: 'https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js', onload: () => res(window.L), onerror: rej });
    document.head.appendChild(s);
  });
}

export const LANGS = { ar: 'العربية', en: 'English', ur: 'اردو', id: 'Indonesia', tr: 'Türkçe', fr: 'Français' };
