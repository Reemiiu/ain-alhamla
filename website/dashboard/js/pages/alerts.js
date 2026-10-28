// الاستجابة للتنبيهات: طابور مرتّب بالتصعيد ثم الخطورة ثم أولوية الحاج، مع عدّاد زمن، وأقرب مستجيب، والملف الطبي.
import { supabase, rpc } from '../api.js';
import { renderShell, onTick, isAdmin, setSubtitle } from '../shell.js';
import { esc, timeAgo, clock, prioPill, ALERT_TYPE, SEVERITY, ALERT_STATUS, sevColor, openModal, toast, LANG } from '../ui.js';

const shell = renderShell({ page: 'alerts.html', title: 'الاستجابة للتنبيهات', subtitle: 'مرتّبة حسب التصعيد والخطورة وأولوية الحاج' });
let all = [], myGroups = null, filter = 'OPEN', typeFilter = 'ALL', selected = Number(location.hash.slice(1)) || null;

if (shell) init(shell);

async function init({ content, user }) {
  if (!isAdmin(user)) {
    const me = await rpc('app_me');
    myGroups = me.groups.map((g) => g.id);
    setSubtitle('تنبيهات مجموعتك فقط — مرتّبة حسب الخطورة وأولوية الحاج');
  }
  content.innerHTML = `
    <div class="filter-row">
      <div class="seg" id="statusSeg">
        <button data-s="OPEN" class="on">مفتوحة</button><button data-s="IN_PROGRESS">قيد المعالجة</button><button data-s="RESOLVED">مُغلقة</button><button data-s="ALL">الكل</button>
      </div>
      <select class="field" id="typeSel" style="max-width:200px">
        <option value="ALL">كل الأنواع</option>
        ${Object.entries(ALERT_TYPE).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}
      </select>
    </div>
    <div class="row" style="align-items:flex-start">
      <div class="sos-list" id="queue"></div>
      <div style="flex:1.4; display:flex; flex-direction:column; gap:16px; min-width:300px" id="detail">
        <div class="card"><div class="empty-state">اختر بلاغاً من الطابور لعرض تفاصيله.</div></div>
      </div>
    </div>`;
  content.querySelectorAll('#statusSeg button').forEach((b) => b.onclick = () => {
    filter = b.dataset.s; content.querySelectorAll('#statusSeg button').forEach((x) => x.classList.toggle('on', x === b)); renderQueue();
  });
  document.getElementById('typeSel').onchange = (e) => { typeFilter = e.target.value; renderQueue(); };
  await load();
  onTick(load);
  setInterval(() => document.querySelectorAll('[data-since]').forEach((el) => { el.textContent = elapsed(el.dataset.since); }), 1000);
}

async function load() {
  const { data, error } = await supabase.from('alerts')
    .select('id, type, severity, status, created_at, resolved_at, escalated_at, note, latitude, longitude, pilgrim_id, location_id, ' +
      'pilgrims(id, group_id, priority_level, priority_reason, preferred_language, users(full_name, phone), groups(name)), locations(name), ' +
      'sos_requests(id, status, acknowledged_at, responder_id)')
    .order('created_at', { ascending: false }).limit(200);
  if (error) { console.error(error); return; }
  all = (data ?? []).filter((a) => !myGroups || myGroups.includes(a.pilgrims?.group_id));
  renderQueue();
  if (selected) renderDetail();
}

const SV = { CRITICAL: 3, MEDIUM: 2, LOW: 1 }, PR = { CRITICAL: 3, HIGH: 2, NORMAL: 1 }, TY = { SOS: 3, LOST: 2, GEOFENCE_BREACH: 1 };
function sorted() {
  return all.filter((a) => (filter === 'ALL' || a.status === filter) && (typeFilter === 'ALL' || a.type === typeFilter))
    .sort((a, b) => (a.status === 'RESOLVED') - (b.status === 'RESOLVED')
      || (b.escalated_at ? 1 : 0) - (a.escalated_at ? 1 : 0)
      || (TY[b.type] ?? 0) - (TY[a.type] ?? 0)
      || SV[b.severity] - SV[a.severity]
      || (PR[b.pilgrims?.priority_level] ?? 1) - (PR[a.pilgrims?.priority_level] ?? 1)
      || new Date(b.created_at) - new Date(a.created_at));
}

function elapsed(since) {
  const s = Math.max(0, Math.floor((Date.now() - new Date(since)) / 1000));
  const m = Math.floor(s / 60);
  return m >= 60 ? `${Math.floor(m / 60)}س ${m % 60}د` : `${String(m).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

function renderQueue() {
  const box = document.getElementById('queue');
  const list = sorted();
  if (!list.length) { box.innerHTML = '<div class="empty-state card">لا توجد بلاغات في هذا التصنيف.</div>'; return; }
  box.innerHTML = list.map((a) => {
    const p = a.pilgrims, urgent = ['SOS', 'LOST'].includes(a.type) && a.status !== 'RESOLVED';
    return `
    <div class="sos-card ${a.status === 'RESOLVED' ? 'resolved' : urgent ? 'critical' : ''} ${a.id === selected ? 'selected' : ''}" data-id="${a.id}">
      <div class="sos-card-head">
        <div class="sos-card-icon" style="background:${sevColor(a.severity)}22"><span style="color:${sevColor(a.severity)}">●</span></div>
        <div style="flex:1">
          <div class="sos-card-title" style="color:${urgent ? 'var(--danger)' : 'inherit'}">${esc(ALERT_TYPE[a.type] ?? a.type)} — ${esc(p?.users?.full_name ?? '')}</div>
          <div class="sos-card-meta">${esc(p?.groups?.name ?? '')} · ${clock(a.created_at)} · ${ALERT_STATUS[a.status]}</div>
        </div>
        ${a.status !== 'RESOLVED' ? `<span class="timer ${a.escalated_at ? 'esc' : ''}" data-since="${a.created_at}">${elapsed(a.created_at)}</span>` : ''}
      </div>
      <div class="sos-card-body">${prioPill(p?.priority_level, p?.priority_reason)}
        ${a.escalated_at && a.status !== 'RESOLVED' ? '<span class="pill crit">مُصعَّد للإدارة</span>' : ''}
        ${p?.preferred_language && p.preferred_language !== 'ar' ? `<span class="lang-chip">${LANG[p.preferred_language]}</span>` : ''}
        ${a.note ? `<div class="meta">${esc(a.note)}</div>` : ''}</div>
      ${a.status !== 'RESOLVED' ? `<div class="sos-card-actions">
        ${a.status === 'OPEN' ? `<button class="btn ${urgent ? 'btn-danger' : 'btn-primary'}" data-act="IN_PROGRESS" data-id="${a.id}">بدء الاستجابة</button>` : ''}
        <button class="btn btn-outline" data-act="RESOLVED" data-id="${a.id}">إغلاق الحالة</button></div>` : ''}
    </div>`;
  }).join('');
  box.querySelectorAll('.sos-card').forEach((el) => el.onclick = (e) => {
    if (e.target.closest('[data-act]')) return;
    selected = Number(el.dataset.id); history.replaceState(null, '', `#${selected}`); renderQueue(); renderDetail();
  });
  box.querySelectorAll('[data-act]').forEach((b) => b.onclick = () => act(Number(b.dataset.id), b.dataset.act));
}

function act(id, status) {
  if (status === 'IN_PROGRESS') {
    return rpc('app_update_alert', { p_alert_id: id, p_status: 'IN_PROGRESS', p_note: null })
      .then(() => { toast('بدأت الاستجابة — أُبلغ الحاج أن المساعدة في الطريق'); load(); }).catch((e) => toast(e.message, 'danger'));
  }
  openModal({
    title: 'إغلاق الحالة', submitLabel: 'إغلاق',
    body: `<label class="field-label">كيف انتهت الحالة؟</label>
      <textarea class="field" name="note" rows="3" placeholder="مثال: وُجد عند بوابة المخيم وأُعيد للمجموعة"></textarea>`,
    onSubmit: async (f) => { await rpc('app_update_alert', { p_alert_id: id, p_status: 'RESOLVED', p_note: f.note || null }); toast('تم إغلاق الحالة'); load(); },
  });
}

async function renderDetail() {
  const a = all.find((x) => x.id === selected);
  const box = document.getElementById('detail');
  if (!a) return;
  const lat = Number(a.latitude), lng = Number(a.longitude), hasLoc = a.latitude != null;
  const sr = Array.isArray(a.sos_requests) ? a.sos_requests[0] : a.sos_requests;
  box.innerHTML = `
    <div class="card"><div class="card-head"><h2>${esc(ALERT_TYPE[a.type])} — ${esc(a.pilgrims?.users?.full_name ?? '')}</h2>
      <span class="pill ${a.severity === 'CRITICAL' ? 'crit' : a.severity === 'MEDIUM' ? 'warn' : 'good'}">خطورة ${SEVERITY[a.severity]}</span></div>
      ${hasLoc ? `<iframe title="موقع البلاغ" class="loc-frame" loading="lazy"
          src="https://www.openstreetmap.org/export/embed.html?bbox=${lng - 0.004},${lat - 0.004},${lng + 0.004},${lat + 0.004}&layer=mapnik&marker=${lat},${lng}"></iframe>
        <div class="meta">الإحداثيات <span dir="ltr">${lat.toFixed(5)}, ${lng.toFixed(5)}</span> ·
          <a target="_blank" rel="noopener" href="https://www.google.com/maps/dir/?api=1&destination=${lat},${lng}">اتجاهات للموقع</a></div>`
        : `<div class="empty-state">${a.locations?.name ? `الموقع المرجعي: ${esc(a.locations.name)}` : 'لم يُرسل موقع مع هذا البلاغ.'}</div>`}
      <div class="timeline-mini">
        <span>البلاغ ${clock(a.created_at)}</span>
        ${sr?.acknowledged_at ? `<span>الاستجابة ${clock(sr.acknowledged_at)}</span>` : ''}
        ${a.resolved_at ? `<span>الإغلاق ${clock(a.resolved_at)} (${Math.round((new Date(a.resolved_at) - new Date(a.created_at)) / 60000)} د)</span>` : ''}
      </div>
    </div>
    <div class="card" id="meetCard"><div class="card-head"><h2>نقطة اللقاء الذكية</h2><span class="meta">الأقرب للحاج وفي طريق مشرف الفوج</span></div><div id="meet"><div class="loading-state">...</div></div></div>
    <div class="row">
      <div class="card" style="flex:1"><div class="card-head"><h2>الملف الطبي وجهات الطوارئ</h2></div><div id="profile"><div class="loading-state">...</div></div></div>
      <div class="card" style="flex:1"><div class="card-head"><h2>أقرب المستجيبين</h2></div><div id="responders"><div class="loading-state">...</div></div></div>
    </div>
    <div class="card"><div class="card-head"><h2>التعليقات على الحالة</h2></div><div id="thread"></div>
      <form class="inline-form" id="cform"><input class="field" name="body" placeholder="اكتب تعليقاً يظهر للإدارة..." required><button class="btn btn-primary">إرسال</button></form></div>`;

  loadMeet(a);
  const [prof, resp, thr] = await Promise.allSettled([
    rpc('app_pilgrim_profile', { p_pilgrim_id: a.pilgrim_id }),
    rpc('app_nearest_responders', { p_alert_id: a.id }),
    supabase.from('comments').select('id, body, created_at, users(full_name)').eq('alert_id', a.id).order('created_at'),
  ]);
  const p = prof.value;
  document.getElementById('profile').innerHTML = p ? `
    <div class="detail-grid">
      <div><div class="detail-label">العمر / الجنسية</div><div class="detail-value">${p.age ?? '—'} · ${esc(p.nationality ?? '—')}</div></div>
      <div><div class="detail-label">فصيلة الدم</div><div class="detail-value">${esc(p.blood_type ?? '—')}</div></div>
      <div><div class="detail-label">الحالة الصحية</div><div class="detail-value">${esc(p.medical_notes || 'لا يوجد')}</div></div>
      <div><div class="detail-label">جوال الحاج</div><div class="detail-value"><a href="tel:${esc(p.phone)}">${esc(p.phone)}</a></div></div>
    </div>
    ${p.contacts.map((c) => `<div class="contact-row"><b>${esc(c.name)}</b> (${esc(c.relation ?? '')})${c.is_primary ? ' <span class="pill good">أساسية</span>' : ''}
      <a class="btn btn-outline sm" href="tel:${esc(c.phone)}">اتصال ${esc(c.phone)}</a></div>`).join('') || '<div class="meta">لا توجد جهات طوارئ</div>'}`
    : `<div class="empty-state">${esc(prof.reason?.message ?? '')}</div>`;
  document.getElementById('responders').innerHTML = (resp.value ?? []).map((r, i) => `
    <div class="contact-row"><span class="rank">${i + 1}</span><div style="flex:1"><b>${esc(r.full_name)}</b>
      <div class="meta">${esc(r.job_title ?? '')} · ${r.distance_m != null ? (r.distance_m >= 1000 ? (r.distance_m / 1000).toFixed(1) + ' كم' : r.distance_m + ' م') : 'موقع غير معروف'} · ${timeAgo(r.seen_at)}</div></div>
      <a class="btn btn-outline sm" href="tel:${esc(r.phone)}">اتصال</a></div>`).join('') || '<div class="empty-state">لا يوجد</div>';
  const renderThread = (rows) => {
    document.getElementById('thread').innerHTML = rows.map((c) => `<div class="feed-row"><div><b>${esc(c.users?.full_name)}</b> ${esc(c.body)}
      <span class="meta">${timeAgo(c.created_at)}</span></div></div>`).join('') || '<div class="meta">لا توجد تعليقات بعد</div>';
  };
  renderThread(thr.value?.data ?? []);
  document.getElementById('cform').onsubmit = async (e) => {
    e.preventDefault();
    const body = e.target.body.value.trim(); if (!body) return;
    try {
      await rpc('app_add_comment', { p_body: body, p_alert_id: a.id, p_pilgrim_id: a.pilgrim_id });
      e.target.reset();
      const r = await supabase.from('comments').select('id, body, created_at, users(full_name)').eq('alert_id', a.id).order('created_at');
      renderThread(r.data ?? []);
    } catch (ex) { toast(ex.message, 'danger'); }
  };
}

// ---------- v3: نقطة اللقاء الذكية ----------
async function loadMeet(a) {
  const box = document.getElementById('meet');
  if (!box) return;
  let r;
  try { r = await rpc('app_meeting_suggestion', { p_pilgrim_id: a.pilgrim_id }); } catch (e) { box.innerHTML = `<div class="empty-state">${esc(e.message)}</div>`; return; }
  const m = r.meeting_point;
  if (!m) { box.innerHTML = '<div class="empty-state">لا توجد نقاط لقاء مفتوحة لهذه الحملة.</div>'; return; }
  const pts = [r.pilgrim, r.group_center, m, ...r.others].filter((p) => p && p.lat != null);
  const lats = pts.map((p) => Number(p.lat)), lngs = pts.map((p) => Number(p.lng));
  const minLa = Math.min(...lats), maxLa = Math.max(...lats), minLo = Math.min(...lngs), maxLo = Math.max(...lngs);
  const sx = (lng) => 20 + ((Number(lng) - minLo) / ((maxLo - minLo) || 1)) * 360, sy = (lat) => 180 - ((Number(lat) - minLa) / ((maxLa - minLa) || 1)) * 160;
  const dot = (p, c, r0, label) => p && p.lat != null ? `<circle cx="${sx(p.lng)}" cy="${sy(p.lat)}" r="${r0}" fill="${c}" stroke="#fff" stroke-width="2"/>${label ? `<text x="${sx(p.lng)}" y="${sy(p.lat) - 10}" text-anchor="middle" font-size="11" font-weight="700" fill="var(--text)">${label}</text>` : ''}` : '';
  const line = r.pilgrim && r.group_center?.lat != null ? `<polyline points="${sx(r.pilgrim.lng)},${sy(r.pilgrim.lat)} ${sx(m.lng)},${sy(m.lat)} ${sx(r.group_center.lng)},${sy(r.group_center.lat)}" fill="none" stroke="var(--gold)" stroke-width="2.5" stroke-dasharray="6 5"/>` : '';
  box.innerHTML = `<div class="meet-card"><h3>${esc(m.name)}</h3><div class="meta">${esc(m.landmark ?? '')}</div>
      <svg class="meet-svg" viewBox="0 0 400 200" role="img" aria-label="الحاج ونقطة اللقاء ومركز الفوج">
        ${r.others.filter((o) => o.id !== m.id).map((o) => `<rect x="${sx(o.lng) - 4}" y="${sy(o.lat) - 4}" width="8" height="8" rx="2" fill="${o.is_open ? '#9C9585' : '#E4DCC8'}"/>`).join('')}
        ${line}${dot(r.group_center, 'var(--success)', 7, 'الفوج')}<rect x="${sx(m.lng) - 8}" y="${sy(m.lat) - 8}" width="16" height="16" rx="3" fill="var(--gold)" stroke="#fff" stroke-width="2"/>
        <text x="${sx(m.lng)}" y="${sy(m.lat) - 13}" text-anchor="middle" font-size="11" font-weight="800" fill="var(--gold-dark)">نقطة اللقاء</text>
        ${dot(r.pilgrim, 'var(--danger)', 8, 'الحاج')}</svg>
      <div class="mini-stats"><span>الحاج يبعد ${m.pilgrim_distance_m ?? '—'} م</span><span>الفوج يبعد ${m.group_distance_m ?? '—'} م</span><span class="${r.risk.score >= 60 ? 'crit' : r.risk.score >= 30 ? 'warn' : 'good'}">مؤشر الخطر ${r.risk.score}</span>${r.buddy ? `<span>الرفيق: ${esc(r.buddy)}</span>` : ''}</div>
      ${a.status !== 'RESOLVED' ? '<button class="btn btn-primary" id="sendMeet">إرسال نقطة اللقاء للحاج ورفيقه</button>' : ''}</div>`;
  document.getElementById('sendMeet')?.addEventListener('click', async () => {
    try { const s = await rpc('app_send_meeting_point', { p_alert_id: a.id }); toast(`أُرسلت «${esc(s.name)}» إلى ${s.notified} ${s.notified > 1 ? 'أشخاص' : 'شخص'} في التطبيق`); load(); }
    catch (e) { toast(esc(e.message), 'danger'); }
  });
}
