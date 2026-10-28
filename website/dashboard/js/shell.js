// هيكل لوحة التحكم: الشريط الجانبي حسب الدور + الجرس + التحديث الدوري (app_tick).
import { requireAuth, logout, rpc } from './api.js';
import { esc, initials, timeAgo, toast } from './ui.js';

const I = {
  home: '<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>',
  alert: '<path d="M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3z"/><path d="M12 8v5"/><circle cx="12" cy="16" r=".6"/>',
  map: '<path d="M9 4 3 6v14l6-2 6 2 6-2V4l-6 2-6-2z"/><path d="M9 4v14"/><path d="M15 6v14"/>',
  report: '<path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5"/><path d="M10 13h6M10 17h4"/>',
  activity: '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
  comment: '<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9h8M8 12h5"/>',
  people: '<circle cx="9" cy="8" r="3"/><circle cx="16" cy="9" r="2.5"/><path d="M3 19c.7-3 3-4.5 6-4.5s5.3 1.5 6 4.5"/><path d="M14.5 14.7c2.2.3 3.8 1.7 4.5 4.3"/>',
  groups: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  gather: '<circle cx="12" cy="10" r="3"/><path d="M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11z"/>',
  bus: '<rect x="4" y="3" width="16" height="14" rx="2"/><path d="M4 11h16"/><circle cx="8" cy="19" r="1.5"/><circle cx="16" cy="19" r="1.5"/>',
  msg: '<path d="M3 11l18-8-8 18-2-8z"/>',
  spark: '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M6 18l2.5-2.5M15.5 8.5L18 6"/>',
  flag: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
  heart: '<path d="M12 20s-7-4.5-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.5-7 10-7 10z"/>',
  family: '<path d="M4 20h16M6 20V9l6-5 6 5v11"/><path d="M10 20v-5h4v5"/>',
  clip: '<rect x="5" y="4" width="14" height="17" rx="2"/><path d="M9 4V3h6v1M9 10h6M9 14h6"/>',
};

const NAV = {
  ADMIN: [
    ['index.html', 'الرئيسية', I.home], ['alerts.html', 'الاستجابة للتنبيهات', I.alert, 'navAlerts'],
    ['map.html', 'الخريطة الحية', I.map], ['reports.html', 'تقارير المناسك', I.report],
    ['activity.html', 'سجل الشغل', I.activity], ['comments.html', 'التعليقات', I.comment],
    ['sep', 'الإدارة'],
    ['pilgrims.html', 'الحجاج', I.people], ['groups.html', 'المجموعات والمشرفون', I.groups],
    ['gatherings.html', 'التجمعات', I.gather], ['trips.html', 'التنقلات', I.bus], ['messages.html', 'الرسائل الجماعية', I.msg],
    ['sep', 'الحج'],
    ['smart.html', 'المتابعة الذكية', I.spark], ['bounds.html', 'حدود المشاعر', I.flag],
    ['health.html', 'الصحة', I.heart], ['family.html', 'الأهل والرسائل', I.family], ['ops.html', 'التشغيل', I.clip],
  ],
  SUPERVISOR: [
    ['index.html', 'مجموعتي', I.home], ['gatherings.html', 'التجمعات والحضور', I.gather],
    ['alerts.html', 'التنبيهات', I.alert, 'navAlerts'], ['map.html', 'الخريطة', I.map],
    ['pilgrims.html', 'حجاج مجموعتي', I.people], ['reports.html', 'تقارير المناسك', I.report],
    ['comments.html', 'التعليقات', I.comment], ['messages.html', 'الرسائل', I.msg], ['trips.html', 'التنقلات', I.bus],
    ['sep', 'الحج'],
    ['smart.html', 'المتابعة الذكية', I.spark], ['bounds.html', 'حدود المشاعر', I.flag],
    ['health.html', 'الصحة', I.heart], ['family.html', 'الأهل والرسائل', I.family], ['ops.html', 'التشغيل', I.clip],
  ],
};
NAV.OPERATIONS_CENTER = NAV.ADMIN;

export const INTERFACE_NAME = { ADMIN: 'واجهة الإدارة', OPERATIONS_CENTER: 'واجهة الإدارة · مركز العمليات', SUPERVISOR: 'واجهة المشرف' };
export const ROLE_LABEL = { ADMIN: 'الإدارة', OPERATIONS_CENTER: 'مركز العمليات', SUPERVISOR: 'مشرف ميداني' };

let tickHandlers = [];
let lastUnread = null;

export function isAdmin(user) { return user.role === 'ADMIN' || user.role === 'OPERATIONS_CENTER'; }

/** يبني الصفحة ويعيد { session, user, content, actions } أو null إن لم يكن مسموحاً. */
export function renderShell({ page, title, subtitle = '', roles }) {
  const session = requireAuth(roles);
  if (!session) return null;
  const user = session.user;
  const items = NAV[user.role] ?? [];
  const nav = items.map(([href, label, icon, badge]) => href === 'sep'
    ? `<div class="db-nav-sep">${esc(label)}</div>`
    : `<a class="db-nav-item${href === page ? ' active' : ''}" href="${href}">
         <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${icon}</svg>
         <span>${label}</span>${badge ? `<span class="badge" id="${badge}" hidden>0</span>` : ''}</a>`).join('');

  document.getElementById('db-shell-root').innerHTML = `
    <div class="db-shell role-${user.role.toLowerCase()}">
      <aside class="db-sidebar" id="dbSidebar">
        <div class="db-brand"><img src="../assets/logo.jpg" alt=""><span>عين الحملة</span></div>
        <div class="db-interface">${INTERFACE_NAME[user.role] ?? ''}</div>
        <nav class="db-nav">${nav}</nav>
        <div class="db-sidebar-spacer"></div>
        <div class="db-user">
          <div class="db-user-avatar">${esc(initials(user.full_name))}</div>
          <div><div class="db-user-name">${esc(user.full_name)}</div><div class="db-user-role">${ROLE_LABEL[user.role] ?? ''}</div></div>
          <button class="db-logout" id="logoutBtn" title="تسجيل الخروج" aria-label="تسجيل الخروج">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="M16 17l5-5-5-5"/><path d="M21 12H9"/></svg>
          </button>
        </div>
      </aside>
      <div class="db-scrim" id="dbScrim"></div>
      <div class="db-main">
        <div class="db-topbar">
          <button class="db-menu-btn" id="menuBtn" aria-label="القائمة">
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg>
          </button>
          <div class="db-title"><h1>${esc(title)}</h1><div class="sub" id="pageSub">${esc(subtitle)}</div></div>
          <div class="db-topbar-extra">
            <div id="pageActions" class="page-actions"></div>
            <span class="live-dot" id="liveDot" title="تحديث تلقائي كل 20 ثانية">مباشر</span>
            <div class="bell-wrap">
              <button class="bell" id="bellBtn" aria-label="الإشعارات">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9a6 6 0 0 1 12 0c0 4 1.5 5.5 1.5 5.5H4.5S6 13 6 9z"/><path d="M10 19a2 2 0 0 0 4 0"/></svg>
                <span class="bell-count" id="bellCount" hidden>0</span>
              </button>
              <div class="bell-panel" id="bellPanel" hidden></div>
            </div>
          </div>
        </div>
        <div class="db-content" id="dbContent"><div class="loading-state">جارٍ التحميل...</div></div>
      </div>
    </div>`;

  document.getElementById('logoutBtn').onclick = logout;
  const sb = document.getElementById('dbSidebar'), scrim = document.getElementById('dbScrim');
  document.getElementById('menuBtn').onclick = () => { sb.classList.toggle('open'); scrim.classList.toggle('on'); };
  scrim.onclick = () => { sb.classList.remove('open'); scrim.classList.remove('on'); };
  document.getElementById('bellBtn').onclick = toggleBell;

  tick();
  setInterval(tick, 20000);
  refreshAlertBadge();

  return { session, user, content: document.getElementById('dbContent'), actions: document.getElementById('pageActions') };
}

export function setSubtitle(text) { const el = document.getElementById('pageSub'); if (el) el.textContent = text; }

/** تسجيل دالة تُستدعى في كل تحديث دوري (لتحديث بيانات الصفحة). */
export function onTick(fn) { tickHandlers.push(fn); }

// v2.1: حفظ صفحات اللوحة وصور الخريطة لتعمل بدون إنترنت (sw.js)
if ('serviceWorker' in navigator && location.protocol !== 'file:') {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

async function tick() {
  const dot = document.getElementById('liveDot');
  try {
    const r = await rpc('app_tick');
    dot?.classList.remove('off');
    setBell(r.unread);
    if (lastUnread !== null && r.unread > lastUnread) {
      const feed = await rpc('app_my_feed');
      const n = feed.notifications.find((x) => !x.read_at);
      if (n) toast(`<b>${esc(n.title ?? 'إشعار جديد')}</b><br>${esc(n.body ?? '')}`, n.alert_type === 'SOS' || n.alert_type === 'LOST' ? 'danger' : 'info');
    }
    lastUnread = r.unread;
    if (r.absence_alerts > 0) toast(`تنبيه غياب: ${r.absence_alerts} حاج لم يسجّل بعد انتهاء المهلة`, 'warn');
    if (r.escalated > 0) toast(`تصعيد: ${r.escalated} بلاغ بدون استجابة`, 'danger');
    Promise.allSettled([rpc('app_smart_tick'), rpc('app_health_tick')]).then(([sm, he]) => {
      const a = sm.value ?? {}, b = he.value ?? {};
      const n = (a.buddy_split_alerts ?? 0) + (a.heat_alerts ?? 0) + (b.missed_doses ?? 0) + (b.escalated_checks ?? 0);
      if (n) toast(`فحص ذكي: ${n} تنبيه جديد (رفاق/حر/جرعات/أنت بخير؟)`, 'warn');
    });
    refreshAlertBadge();
    for (const fn of tickHandlers) fn();
  } catch (e) {
    dot?.classList.add('off');
    console.warn(e);
  }
}

async function refreshAlertBadge() {
  try {
    const k = await rpc('app_kpis');
    const b = document.getElementById('navAlerts');
    if (b) { b.hidden = !k.open_alerts; b.textContent = k.open_alerts; }
  } catch { /* */ }
}

function setBell(n) {
  const c = document.getElementById('bellCount');
  if (!c) return;
  c.hidden = !n; c.textContent = n > 99 ? '99+' : n;
}

async function toggleBell() {
  const p = document.getElementById('bellPanel');
  if (!p.hidden) { p.hidden = true; return; }
  p.hidden = false;
  p.innerHTML = '<div class="loading-state">...</div>';
  const feed = await rpc('app_my_feed');
  p.innerHTML = `
    <div class="bell-head"><b>الإشعارات</b><button class="link-btn" id="markRead">تعليم الكل كمقروء</button></div>
    ${feed.notifications.length ? feed.notifications.slice(0, 15).map((n) => `
      <a class="bell-item${n.read_at ? '' : ' unread'}" href="${n.alert_id ? 'alerts.html' : n.broadcast_id ? 'messages.html' : '#'}">
        <b>${esc(n.title ?? 'إشعار')}</b><span>${esc(n.body ?? '')}</span><small>${timeAgo(n.sent_at)}</small></a>`).join('')
      : '<div class="empty-state">لا توجد إشعارات</div>'}`;
  document.getElementById('markRead').onclick = async () => { await rpc('app_mark_read'); setBell(0); lastUnread = 0; p.hidden = true; };
}

document.addEventListener('click', (e) => {
  const p = document.getElementById('bellPanel');
  if (p && !p.hidden && !e.target.closest('.bell-wrap')) p.hidden = true;
});
