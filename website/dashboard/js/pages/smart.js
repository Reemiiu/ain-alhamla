// المتابعة الذكية: مؤشر خطر الضياع، الرفاق، الإجهاد الحراري، نبض الحشود، وجاهزية الحافلة — كلها من القاعدة الحية.
import { supabase, rpc } from '../api.js';
import { renderShell, onTick, isAdmin } from '../shell.js';
import { esc, timeAgo, battery, clock, toast } from '../ui.js';
import { riskBar, riskLabel, meters, distPill, scenarioBar, bindScenario, LANGS } from '../v3.js';

const shell = renderShell({ page: 'smart.html', title: 'المتابعة الذكية', subtitle: 'من سيضيع قبل أن يضيع: مؤشر الخطر، الرفاق، الحر، الزحام، وجاهزية الحافلة' });
let locs = [], trips = [], groups = [];

if (shell) init(shell);

async function init({ content, user }) {
  content.innerHTML = `
    ${isAdmin(user) ? scenarioBar() : ''}
    <div class="stat-row" id="kpis"></div>
    <div class="row">
      <div class="card" style="flex:1.6"><div class="card-head"><h2>مؤشر خطر الضياع</h2>
        <span class="meta">البعد عن الفوج ٣٥ + آخر ظهور ٢٥ + البطارية ١٥ + العمر ١٠ + الحالة الصحية ١٠ + بعد الرفيق ٥</span></div>
        <div style="overflow-x:auto"><table class="db-table"><thead><tr><th>الحاج</th><th>المؤشر</th><th>عن الفوج</th><th>آخر ظهور</th><th>البطارية</th><th></th></tr></thead>
        <tbody id="risk"><tr><td colspan="6"><div class="loading-state">جارٍ التحميل...</div></td></tr></tbody></table></div></div>
      <div class="card" style="flex:1"><div class="card-head"><h2>نظام الرفيق</h2><span class="meta">تنبيه للاثنين عند تجاوز الحد</span></div><div id="buddies"></div></div>
    </div>
    <div class="row">
      <div class="card"><div class="card-head"><h2>الإجهاد الحراري</h2><select class="field sm-field" id="heatLoc"></select></div><div id="heat"></div></div>
      <div class="card"><div class="card-head"><h2>نبض الحشود · الجمرات</h2><span class="meta">شخص لكل م²</span></div><div id="crowd"></div></div>
      <div class="card"><div class="card-head"><h2>جاهزية الحافلة</h2></div>
        <div class="inline-form"><select class="field" id="busTrip"></select><select class="field" id="busGroup"></select></div><div id="bus"></div></div>
    </div>`;
  bindScenario(content, load);
  const [l, t, g] = await Promise.all([
    supabase.from('locations').select('id, name, type').order('id'),
    supabase.from('trips').select('id, vehicle_no, status, route_from_id').neq('status', 'COMPLETED').order('departure_time'),
    supabase.from('groups').select('id, name').order('id'),
  ]);
  locs = l.data ?? []; trips = t.data ?? []; groups = g.data ?? [];
  const heatSel = document.getElementById('heatLoc');
  heatSel.innerHTML = locs.map((x) => `<option value="${x.id}">${esc(x.name)}</option>`).join('');
  heatSel.value = (locs.find((x) => x.name.startsWith('مخيم الحملة')) ?? locs[0])?.id ?? '';
  heatSel.onchange = loadHeat;
  document.getElementById('busTrip').innerHTML = trips.map((x) => `<option value="${x.id}">حافلة ${esc(x.vehicle_no)}</option>`).join('') || '<option value="">لا رحلات قادمة</option>';
  document.getElementById('busGroup').innerHTML = groups.map((x) => `<option value="${x.id}">${esc(x.name)}</option>`).join('');
  document.getElementById('busTrip').onchange = loadBus;
  document.getElementById('busGroup').onchange = loadBus;
  await load();
  onTick(load);
}

async function load() {
  await Promise.allSettled([loadRisk(), loadBuddies(), loadHeat(), loadCrowd(), loadBus()]);
}

async function loadRisk() {
  const rows = await rpc('app_members_risk');
  const high = rows.filter((r) => r.risk.score >= 60).length, mid = rows.filter((r) => r.risk.score >= 30 && r.risk.score < 60).length;
  document.getElementById('kpis').innerHTML = `
    <div class="stat-card ${high ? 'danger' : ''}"><div class="stat-card-head"><span>خطر ضياع مرتفع</span></div><div class="stat-value ${high ? 'danger' : ''}">${high}</div><div class="stat-sub">مؤشر ٦٠ فأكثر</div></div>
    <div class="stat-card"><div class="stat-card-head"><span>خطر متوسط</span></div><div class="stat-value">${mid}</div><div class="stat-sub">٣٠ – ٥٩</div></div>
    <div class="stat-card"><div class="stat-card-head"><span>الحجاج المتابَعون</span></div><div class="stat-value">${rows.length}</div><div class="stat-sub">مرتّبون بالأعلى خطرًا</div></div>`;
  document.getElementById('risk').innerHTML = rows.map((r) => `
    <tr><td><b>${esc(r.full_name)}</b><div class="meta">${esc(r.group_name ?? '')}${r.preferred_language && r.preferred_language !== 'ar' ? ` · <span class="lang-chip">${LANGS[r.preferred_language] ?? r.preferred_language}</span>` : ''}</div></td>
      <td>${riskBar(r.risk.score)}<div class="meta">${riskLabel(r.risk.score)}</div></td>
      <td>${meters(r.risk.distance_m)}</td>
      <td class="muted">${r.risk.seen_min != null ? (r.risk.seen_min < 1 ? 'الآن' : `قبل ${r.risk.seen_min} د`) : '—'}</td>
      <td>${battery(r.risk.battery)}</td>
      <td>${r.risk.score >= 60 ? '<a class="btn btn-outline sm" href="alerts.html">التنبيهات</a>' : ''}</td></tr>`).join('')
    || '<tr><td colspan="6"><div class="empty-state">لا يوجد حجاج.</div></td></tr>';
}

async function loadBuddies() {
  const rows = await rpc('app_buddy_status');
  document.getElementById('buddies').innerHTML = rows.map((b) => `
    <div class="contact-row"><div style="flex:1"><b>${esc(b.a_name)}</b> ⇄ <b>${esc(b.b_name)}</b><div class="meta">الحد ${b.max_distance_m} م</div></div>
      ${distPill(b.distance_m, b.max_distance_m, 500)}</div>`).join('') || '<div class="empty-state">لم يُربط أي رفيقين بعد.</div>';
}

async function loadHeat() {
  const id = Number(document.getElementById('heatLoc').value);
  if (!id) return;
  const r = await rpc('app_heat_watch', { p_location_id: id });
  const box = document.getElementById('heat');
  if (!r.reading) { box.innerHTML = '<div class="empty-state">لا توجد قراءة حرارة لهذا الموقع.</div>'; return; }
  const f = r.reading.feels_like, pos = Math.max(0, Math.min(100, ((f - 30) / 22) * 100));
  box.innerHTML = `
    <div class="heat-big"><b style="color:${f >= 46 ? 'var(--danger)' : f >= 40 ? 'var(--warning)' : 'var(--success)'}">${f}°</b>
      <span>الإحساس الفعلي<br><small>الحرارة ${Number(r.reading.temp)}° · الرطوبة ${r.reading.humidity}٪ · ${timeAgo(r.reading.at)}</small></span></div>
    <div class="heat-meter"><i style="right:${pos}%"></i></div>
    <div class="heat-scale"><span>آمن ٣٠°</span><span>حذر ٤٠°</span><span>خطر ٤٦°+</span></div>
    <div class="meta" style="margin:10px 0 4px"><b>${r.at_risk.length}</b> حجاج تجاوزوا حدهم الشخصي (٤٠° لكبار السن وأصحاب الحالات، ٤٥° لغيرهم)</div>
    ${r.at_risk.map((p) => `<div class="contact-row"><span style="flex:1">${esc(p.name)}</span><span class="pill warn">حد ${p.limit}°</span></div>`).join('')}`;
}

async function loadCrowd() {
  const jam = locs.find((x) => x.name === 'الجمرات');
  const box = document.getElementById('crowd');
  if (!jam) { box.innerHTML = '<div class="empty-state">لا يوجد موقع الجمرات.</div>'; return; }
  const now = new Date(), to = new Date(now.getTime() + 24 * 3600000);
  const r = await rpc('app_best_slot', { p_location_id: jam.id, p_from: new Date(now.getTime() - 3600000).toISOString(), p_to: to.toISOString() });
  if (!r.slots.length) { box.innerHTML = '<div class="empty-state">لا توجد توقعات زحام. شغّلي سيناريو العرض.</div>'; return; }
  const col = (d) => (d >= 4 ? 'var(--danger)' : d >= 2.5 ? 'var(--warning)' : 'var(--success)');
  box.innerHTML = `<div class="bars">${r.slots.map((s) => `
      <div class="b ${r.best && s.slot_start === r.best.slot_start ? 'best' : ''}"><span>${Number(s.density).toFixed(1)}</span>
        <i style="height:${(Number(s.density) / 6) * 100}%;background:${col(Number(s.density))}"></i><span>${clock(s.slot_start)}</span></div>`).join('')}</div>
    ${r.best ? `<div class="callout"><b>أفضل وقت للرمي: ${clock(r.best.slot_start)}</b> · الكثافة المتوقعة ${Number(r.best.density).toFixed(1)} شخص/م²،
      أقل من الذروة بـ ${Math.round((1 - Number(r.best.density) / Number(r.peak)) * 100)}٪.</div>` : ''}`;
}

async function loadBus() {
  const trip = Number(document.getElementById('busTrip').value), group = Number(document.getElementById('busGroup').value);
  const box = document.getElementById('bus');
  if (!trip || !group) { box.innerHTML = '<div class="empty-state">لا توجد رحلة قادمة.</div>'; return; }
  try {
    const r = await rpc('app_bus_readiness', { p_trip_id: trip, p_group_id: group, p_radius_m: 150 });
    const pct = r.total ? r.ready / r.total : 0, C = 2 * Math.PI * 40;
    box.innerHTML = `<div class="ready-row" style="gap:14px;align-items:center">
        <svg viewBox="0 0 100 100" width="92" height="92" role="img" aria-label="${r.ready} من ${r.total} جاهزون">
          <circle cx="50" cy="50" r="40" fill="none" stroke="var(--surface-alt)" stroke-width="10"/>
          <circle cx="50" cy="50" r="40" fill="none" stroke="var(--gold)" stroke-width="10" stroke-linecap="round" transform="rotate(-90 50 50)" stroke-dasharray="${C * pct} ${C}"/>
          <text x="50" y="56" text-anchor="middle" font-size="18" font-weight="800" fill="var(--text)">${r.ready}/${r.total}</text></svg>
        <div><b>حافلة ${esc(r.trip ?? '')} · من ${esc(r.from ?? '')}</b><div class="meta">جاهز = داخل ١٥٠م من نقطة الصعود بموقع خلال ٥ دقائق</div></div></div>
      ${r.missing.map((m) => `<div class="contact-row"><span style="flex:1">${esc(m.name)}</span>${distPill(m.distance_m, 150, 500)}</div>`).join('') || '<div class="pill good" style="margin-top:8px">الفوج كامل وجاهز للتحرك</div>'}`;
  } catch (e) { box.innerHTML = `<div class="empty-state">${esc(e.message)}</div>`; }
}
