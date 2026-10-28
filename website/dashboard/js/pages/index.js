import { supabase, rpc } from '../api.js';
import { renderShell, onTick, isAdmin, setSubtitle } from '../shell.js';
import { esc, num, timeAgo, clock, attPill, prioPill, stars, ALERT_TYPE, sevColor, initials, battery } from '../ui.js';
import { createLiveMap } from '../live-map.js';

const shell = renderShell({ page: 'index.html', title: 'الرئيسية' });
if (shell) (isAdmin(shell.user) ? adminHome : supervisorHome)(shell);

function kpi(label, value, sub = '', tone = '') {
  return `<div class="stat-card ${tone}"><div class="stat-card-head"><span>${label}</span></div>
    <div class="stat-value ${tone}">${value}</div>${sub ? `<div class="stat-sub">${sub}</div>` : ''}</div>`;
}

function ritualTimeline(rituals) {
  return `<div class="ritual-line">${rituals.map((r) => `
    <div class="ritual-step ${r.status.toLowerCase()}">
      <span class="ritual-dot"></span>
      <b>${esc(r.name)}</b><small>${r.hajj_day} ذي الحجة</small>
    </div>`).join('')}</div>`;
}

// =============================== الإدارة ===============================
async function adminHome({ content, user }) {
  setSubtitle(user.role === 'OPERATIONS_CENTER' ? 'مركز العمليات — صورة لحظية عن الحملة' : 'صورة لحظية عن الحملة كاملة');
  content.innerHTML = `
    <div class="stat-row" id="kpis"></div>
    <div class="card"><div class="card-head"><h2>مسار المناسك</h2><a href="reports.html" class="link">التقارير ←</a></div><div id="rituals"></div></div>
    <div class="row">
      <div class="card" style="flex:1.6"><div class="card-head"><h2>الخريطة الحية</h2><a href="map.html" class="link">الحجم الكامل ←</a></div><div id="miniMap"></div></div>
      <div class="card" style="flex:1"><div class="card-head"><h2>طابور الاستجابة</h2><a href="alerts.html" class="link">الكل ←</a></div><div id="queue"></div></div>
    </div>
    <div class="row">
      <div class="card" style="flex:1"><div class="card-head"><h2>جاهزية المجموعات</h2></div><div id="groups"></div></div>
      <div class="card" style="flex:1.2"><div class="card-head"><h2>آخر شغل المشرفين</h2><a href="activity.html" class="link">سجل الشغل ←</a></div><div id="activity"></div></div>
      <div class="card" style="flex:1.2"><div class="card-head"><h2>آخر التعليقات</h2><a href="comments.html" class="link">الكل ←</a></div><div id="comments"></div></div>
    </div>`;
  let map;
  createLiveMap(document.getElementById('miniMap'), { height: 320 }).then((m) => { map = m; });
  const load = async () => {
    const [k, rit, q, act, com, board] = await Promise.all([
      rpc('app_kpis'),
      supabase.from('rituals').select('id, name, hajj_day, status, seq').order('seq'),
      supabase.from('alerts').select('id, type, severity, status, created_at, escalated_at, pilgrims(priority_level, users(full_name), groups(name))')
        .neq('status', 'RESOLVED').order('created_at', { ascending: false }).limit(30),
      supabase.from('activity_log').select('id, description, created_at, users(full_name)').neq('action', 'LOGIN').order('created_at', { ascending: false }).limit(7),
      supabase.from('comments').select('id, kind, body, rating, created_at, users(full_name), rituals(name), groups(name)')
        .order('created_at', { ascending: false }).limit(5),
      rpc('app_board'),
    ]);
    document.getElementById('kpis').innerHTML =
      kpi('الحجاج', num(k.pilgrims), `${num(k.high_priority)} أولوية عالية · ${num(k.non_arabic)} غير ناطق بالعربية`) +
      kpi('نسبة الحضور', `${k.attendance_rate ?? '—'}٪`, `في الوقت: ${k.on_time_rate ?? '—'}٪`) +
      kpi('بلاغات SOS / تائه مفتوحة', num(k.open_sos), k.escalated ? `${k.escalated} مُصعَّد` : 'لا تصعيد', k.open_sos ? 'danger' : '') +
      kpi('متوسط زمن الاستجابة', k.avg_response_min != null ? `${k.avg_response_min} د` : '—', 'لبلاغات SOS والتائهين') +
      kpi('رضا الحجاج', k.avg_rating ?? '—', stars(k.avg_rating)) +
      kpi('متتبَّعون الآن', `${num(k.tracked_now)}/${num(k.pilgrims)}`, 'موقع خلال آخر 30 دقيقة');
    document.getElementById('rituals').innerHTML = ritualTimeline(rit.data ?? []);
    const pr = { CRITICAL: 3, HIGH: 2, NORMAL: 1 }, sv = { CRITICAL: 3, MEDIUM: 2, LOW: 1 }, ty = { SOS: 3, LOST: 2, GEOFENCE_BREACH: 1 };
    const qs = (q.data ?? []).sort((a, b) => (b.escalated_at ? 1 : 0) - (a.escalated_at ? 1 : 0) || (ty[b.type] ?? 0) - (ty[a.type] ?? 0) || sv[b.severity] - sv[a.severity]
      || (pr[b.pilgrims?.priority_level] ?? 1) - (pr[a.pilgrims?.priority_level] ?? 1)).slice(0, 6);
    document.getElementById('queue').innerHTML = qs.length ? qs.map((a) => `
      <a class="alert-row" href="alerts.html#${a.id}"><span class="dot" style="background:${sevColor(a.severity)}"></span>
        <div><b>${esc(ALERT_TYPE[a.type] ?? a.type)} — ${esc(a.pilgrims?.users?.full_name ?? '')}</b>
        <span class="meta">${esc(a.pilgrims?.groups?.name ?? '')} · ${timeAgo(a.created_at)}${a.escalated_at ? ' · <b class="txt-danger">مُصعَّد</b>' : ''}</span></div></a>`).join('')
      : '<div class="empty-state">لا توجد بلاغات مفتوحة 👌</div>';
    document.getElementById('groups').innerHTML = board.groups.map((g) => {
      const gt = g.gathering, pct = gt ? Math.round(100 * gt.checked / Math.max(1, g.members)) : null;
      return `<div class="ready-row"><div><b>${esc(g.name)}</b><span class="meta">${esc(g.supervisor_name ?? 'بلا مشرف')} · ${g.members}/${g.capacity}</span></div>
        ${gt ? `<div class="ready-bar"><i style="width:${pct}%"></i></div><span class="ready-pct ${pct === 100 ? 'ok' : ''}">${pct}٪</span>`
              : '<span class="meta">لا يوجد تجمع مفتوح</span>'}</div>`;
    }).join('');
    document.getElementById('activity').innerHTML = (act.data ?? []).map((a) => `
      <div class="feed-row"><span class="feed-av">${esc(initials(a.users?.full_name))}</span>
        <div><b>${esc(a.users?.full_name ?? 'النظام')}</b> ${esc(a.description)}<span class="meta">${timeAgo(a.created_at)}</span></div></div>`).join('')
      || '<div class="empty-state">لا يوجد شغل مسجّل</div>';
    document.getElementById('comments').innerHTML = (com.data ?? []).map((c) => `
      <div class="feed-row"><span class="feed-av ${c.kind === 'PILGRIM_FEEDBACK' ? 'gold' : ''}">${esc(initials(c.users?.full_name))}</span>
        <div><b>${esc(c.users?.full_name ?? '')}</b> <span class="kind-tag k-${c.kind}">${c.kind === 'PILGRIM_FEEDBACK' ? 'تقييم حاج' : c.kind === 'ADMIN_REPLY' ? 'رد الإدارة' : 'ملاحظة مشرف'}</span>
        ${c.rating ? stars(c.rating) : ''}<div class="feed-body">${esc(c.body || '—')}</div>
        <span class="meta">${esc(c.rituals?.name ?? '')}${c.groups?.name ? ' · ' + esc(c.groups.name) : ''} · ${timeAgo(c.created_at)}</span></div></div>`).join('')
      || '<div class="empty-state">لا توجد تعليقات</div>';
  };
  await load();
  onTick(() => { load(); map?.refresh(); });
}

// =============================== المشرف ===============================
async function supervisorHome({ content, user }) {
  content.innerHTML = `
    <div class="stat-row" id="kpis"></div>
    <div class="row">
      <div class="card" style="flex:1.1" id="gatherCard"></div>
      <div class="card" style="flex:1"><div class="card-head"><h2>تنبيهات مجموعتي</h2><a class="link" href="alerts.html">الكل ←</a></div><div id="alerts"></div></div>
    </div>
    <div class="card"><div class="card-head"><h2>مسار المناسك</h2><a class="link" href="reports.html">التقارير وإصدارها ←</a></div><div id="rituals"></div></div>
    <div class="table-card"><div class="card-head" style="padding:14px 16px 0"><h2>أفراد مجموعتي — مرتّبون حسب الأولوية</h2></div>
      <div style="overflow-x:auto"><table class="db-table"><thead><tr><th>الحاج</th><th>الأولوية</th><th>اللغة</th><th>التجمع الحالي</th><th>آخر موقع</th><th>البطارية</th></tr></thead>
      <tbody id="members"></tbody></table></div></div>`;
  const load = async () => {
    const [b, k, al, rit] = await Promise.all([
      rpc('app_board'), rpc('app_kpis'),
      supabase.from('alerts').select('id, type, severity, status, created_at, pilgrim_id, pilgrims!inner(group_id, users(full_name))')
        .neq('status', 'RESOLVED').order('created_at', { ascending: false }).limit(40),
      supabase.from('rituals').select('id, name, hajj_day, status, seq').order('seq'),
    ]);
    const myGroups = b.groups.map((g) => g.id);
    setSubtitle(`${b.groups.map((g) => g.name).join('، ')} · ${b.pilgrims.length} حاجاً`);
    document.getElementById('kpis').innerHTML =
      kpi('حجاج مجموعتي', num(b.pilgrims.length), `${num(k.high_priority)} أولوية عالية`) +
      kpi('نسبة الحضور', `${k.attendance_rate ?? '—'}٪`, `في الوقت: ${k.on_time_rate ?? '—'}٪`) +
      kpi('تنبيهات مفتوحة', num(k.open_alerts), k.open_sos ? `${k.open_sos} SOS / تائه` : '', k.open_sos ? 'danger' : '') +
      kpi('متتبَّعون الآن', `${num(k.tracked_now)}/${num(b.pilgrims.length)}`, 'موقع خلال 30 دقيقة') +
      kpi('رضا الحجاج', k.avg_rating ?? '—', stars(k.avg_rating));

    const g = b.groups.find((x) => x.gathering)?.gathering;
    const members = b.groups.reduce((s, x) => s + (x.gathering ? x.members : 0), 0);
    const pct = g ? Math.round(100 * g.checked / Math.max(1, members)) : 0;
    const deadline = g ? new Date(new Date(g.scheduled_at).getTime() + g.deadline_minutes * 60000) : null;
    document.getElementById('gatherCard').innerHTML = g ? `
      <div class="card-head"><h2>جاهزية المجموعة</h2><span class="pill ${pct === 100 ? 'good' : 'warn'}"><span class="dot"></span>${pct === 100 ? 'جاهزة للانطلاق' : 'بانتظار البقية'}</span></div>
      <div class="ready-big">
        <div class="ring" style="--p:${pct}"><span>${pct}٪</span></div>
        <div><b>${esc(g.title)}</b><div class="meta">${esc(g.location)} · الموعد ${clock(g.scheduled_at)} · تنتهي المهلة ${clock(deadline.toISOString())}</div>
          <div class="meta">سجّل ${g.checked} من ${members}</div>
          <a class="btn btn-primary" href="gatherings.html" style="margin-top:10px">إدارة الحضور</a></div>
      </div>` : `<div class="card-head"><h2>جاهزية المجموعة</h2></div>
      <div class="empty-state">لا يوجد تجمع مفتوح. <a href="gatherings.html">افتح تجمعاً جديداً</a></div>`;

    const mine = (al.data ?? []).filter((a) => myGroups.includes(a.pilgrims?.group_id));
    document.getElementById('alerts').innerHTML = mine.length ? mine.slice(0, 6).map((a) => `
      <a class="alert-row" href="alerts.html#${a.id}"><span class="dot" style="background:${sevColor(a.severity)}"></span>
      <div><b>${esc(ALERT_TYPE[a.type] ?? a.type)} — ${esc(a.pilgrims?.users?.full_name ?? '')}</b><span class="meta">${timeAgo(a.created_at)}</span></div></a>`).join('')
      : '<div class="empty-state">لا توجد تنبيهات مفتوحة 👌</div>';
    document.getElementById('rituals').innerHTML = ritualTimeline(rit.data ?? []);
    document.getElementById('members').innerHTML = b.pilgrims.map((p) => `
      <tr><td><div class="row-person"><span class="row-avatar">${esc(initials(p.full_name))}</span><div>${esc(p.full_name)}
        ${p.age ? `<div class="meta">${p.age} سنة · ${esc(p.nationality ?? '')}</div>` : ''}</div></div></td>
        <td>${prioPill(p.priority_level, p.priority_reason)}</td>
        <td>${p.preferred_language === 'ar' ? 'العربية' : `<span class="lang-chip">${p.preferred_language.toUpperCase()}</span>`}</td>
        <td>${attPill(p.current_status)}${p.open_alerts ? ` <span class="pill crit">${p.open_alerts} تنبيه</span>` : ''}</td>
        <td class="muted">${p.last_ping ? timeAgo(p.last_ping.at) : '—'}</td>
        <td>${battery(p.last_ping?.battery)}</td></tr>`).join('');
  };
  await load();
  onTick(load);
}
