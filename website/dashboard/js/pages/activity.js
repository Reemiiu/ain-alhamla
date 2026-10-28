// سجل الشغل (للإدارة): كل إجراء نفّذه المشرفون، مع ملخص أداء كل مشرف.
import { supabase } from '../api.js';
import { renderShell, onTick } from '../shell.js';
import { esc, clock, timeAgo, initials, downloadCsv } from '../ui.js';

const shell = renderShell({ page: 'activity.html', title: 'سجل الشغل', subtitle: 'كل ما نفّذه المشرفون في الميدان — لحظة بلحظة', roles: ['ADMIN', 'OPERATIONS_CENTER'] });

const ACTIONS = {
  CREATE_GATHERING: ['فتح تجمع', '📍'], CLOSE_GATHERING: ['إغلاق تجمع', '✅'], MANUAL_ATTENDANCE: ['حضور يدوي', '✍️'],
  RESPOND_ALERT: ['استجابة لتنبيه', '🚑'], RESOLVE_ALERT: ['إغلاق تنبيه', '🛡️'], BROADCAST: ['رسالة جماعية', '📣'],
  FINISH_RITUAL: ['تقرير منسك', '📄'], COMMENT: ['تعليق', '💬'], SET_PRIORITY: ['تعديل أولوية', '⭐'],
  CREATE_PILGRIM: ['إضافة حاج', '➕'], SAVE_GROUP: ['مجموعة', '👥'], SAVE_TRIP: ['رحلة', '🚌'], TRIP_STATUS: ['حالة رحلة', '🚌'],
  RITUAL_STATUS: ['حالة منسك', '🕋'], LOGIN: ['دخول', '🔑'],
};
let rows = [], actor = 'ALL', action = 'ALL';

if (shell) init(shell);

async function init({ content, actions }) {
  actions.innerHTML = '<button class="btn btn-outline" id="csv">تصدير CSV</button>';
  content.innerHTML = `
    <div class="card"><div class="card-head"><h2>أداء المشرفين</h2></div><div class="perf-grid" id="perf"></div></div>
    <div class="filter-row">
      <select class="field" id="actorSel" style="max-width:240px"><option value="ALL">كل المستخدمين</option></select>
      <select class="field" id="actionSel" style="max-width:220px"><option value="ALL">كل الإجراءات</option>
        ${Object.entries(ACTIONS).map(([k, [l]]) => `<option value="${k}">${l}</option>`).join('')}</select>
      <label class="meta"><input type="checkbox" id="hideLogin" checked> إخفاء تسجيلات الدخول</label>
    </div>
    <div class="card" id="log"></div>`;
  document.getElementById('actorSel').onchange = (e) => { actor = e.target.value; render(); };
  document.getElementById('actionSel').onchange = (e) => { action = e.target.value; render(); };
  document.getElementById('hideLogin').onchange = render;
  document.getElementById('csv').onclick = () => downloadCsv('سجل_الشغل.csv',
    [['الوقت', 'المستخدم', 'الإجراء', 'التفاصيل', 'المجموعة'], ...filtered().map((r) => [new Date(r.created_at).toLocaleString('ar-SA'), r.users?.full_name, ACTIONS[r.action]?.[0] ?? r.action, r.description, r.groups?.name])]);
  await load();
  onTick(load);
}

async function load() {
  const [log, sup, res] = await Promise.all([
    supabase.from('activity_log').select('id, action, description, created_at, actor_id, users(full_name, role), groups(name)').order('created_at', { ascending: false }).limit(500),
    supabase.from('supervisors').select('id, job_title, users(id, full_name), groups(name)'),
    supabase.from('alerts').select('resolved_by, created_at, resolved_at').not('resolved_by', 'is', null),
  ]);
  rows = log.data ?? [];
  const sel = document.getElementById('actorSel');
  const users = [...new Map(rows.filter((r) => r.users).map((r) => [r.actor_id, r.users.full_name])).entries()];
  sel.innerHTML = '<option value="ALL">كل المستخدمين</option>' + users.map(([id, n]) => `<option value="${id}" ${String(id) === actor ? 'selected' : ''}>${esc(n)}</option>`).join('');

  document.getElementById('perf').innerHTML = (sup.data ?? []).map((s) => {
    const uid = s.users?.id, mine = rows.filter((r) => r.actor_id === uid && r.action !== 'LOGIN');
    const solved = (res.data ?? []).filter((a) => a.resolved_by === uid);
    const avg = solved.length ? Math.round(solved.reduce((t, a) => t + (new Date(a.resolved_at) - new Date(a.created_at)) / 60000, 0) / solved.length) : null;
    const last = mine[0];
    return `<div class="perf-card"><div class="row-person"><span class="row-avatar">${esc(initials(s.users?.full_name))}</span>
      <div><b>${esc(s.users?.full_name)}</b><div class="meta">${esc((Array.isArray(s.groups) ? s.groups.map((g) => g.name).join('، ') : s.groups?.name) || s.job_title || '')}</div></div></div>
      <div class="perf-nums"><span><b>${mine.length}</b>إجراء</span><span><b>${solved.length}</b>تنبيه أُغلق</span><span><b>${avg ?? '—'}</b>د متوسط الإغلاق</span></div>
      <div class="meta">آخر نشاط: ${last ? `${esc(ACTIONS[last.action]?.[0] ?? last.action)} · ${timeAgo(last.created_at)}` : '—'}</div></div>`;
  }).join('');
  render();
}

function filtered() {
  const hide = document.getElementById('hideLogin')?.checked;
  return rows.filter((r) => (actor === 'ALL' || String(r.actor_id) === actor) && (action === 'ALL' || r.action === action) && !(hide && r.action === 'LOGIN'));
}

function render() {
  const list = filtered();
  let day = '';
  document.getElementById('log').innerHTML = list.map((r) => {
    const d = new Date(r.created_at).toLocaleDateString('ar-SA-u-ca-gregory', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'Asia/Riyadh' });
    const head = d !== day ? `<div class="day-sep">${(day = d)}</div>` : '';
    const [label, icon] = ACTIONS[r.action] ?? [r.action, '•'];
    return `${head}<div class="log-row"><span class="log-time">${clock(r.created_at)}</span><span class="log-icon">${icon}</span>
      <div><b>${esc(r.users?.full_name ?? 'النظام')}</b> <span class="kind-tag">${esc(label)}</span><div>${esc(r.description)}</div>
      ${r.groups?.name ? `<span class="meta">${esc(r.groups.name)}</span>` : ''}</div></div>`;
  }).join('') || '<div class="empty-state">لا يوجد شغل مطابق.</div>';
}
