// الرسائل الجماعية: المشرف لمجموعته، والإدارة لأي مجموعة أو للحملة كاملة. تصل لتطبيق الحاج فوراً.
import { supabase, rpc } from '../api.js';
import { renderShell, isAdmin } from '../shell.js';
import { esc, timeAgo, toast } from '../ui.js';

const shell = renderShell({ page: 'messages.html', title: 'الرسائل الجماعية', subtitle: 'تصل فوراً لتطبيق الحاج كإشعار' });
let groups = [];
const TEMPLATES = [
  ['تذكير بالتجمع', 'نذكّركم بموعد التجمع القادم. سجّلوا حضوركم من التطبيق فور الوصول.'],
  ['تنبيه حرارة', 'درجة الحرارة مرتفعة — اشربوا الماء باستمرار واستخدموا المظلات.'],
  ['تأخر الحافلة', 'الحافلة متأخرة 15 دقيقة. ابقوا في المخيم حتى إشعار آخر.'],
  ['زحام شديد', 'زحام شديد في الطريق — التزموا بالمشرف ولا تتفرقوا.'],
  ['شحن الجوال', 'اشحنوا جوالاتكم قبل التحرك؛ التطبيق يحتاجه لتتبعكم بأمان.'],
];

if (shell) init(shell);

async function init({ content, user }) {
  groups = (await rpc('app_me')).groups;
  content.innerHTML = `
    <div class="row" style="align-items:flex-start">
      <div class="card" style="flex:1; min-width:300px">
        <div class="card-head"><h2>رسالة جديدة</h2></div>
        <form id="f" class="stack">
          <label class="field-label">إلى</label>
          <select class="field" name="g">${isAdmin(user) ? '<option value="">كل الحملة</option>' : ''}${groups.map((g) => `<option value="${g.id}">${esc(g.name)}</option>`).join('')}</select>
          <label class="field-label">قوالب سريعة</label>
          <div class="chips">${TEMPLATES.map(([t], i) => `<button type="button" class="chip" data-t="${i}">${esc(t)}</button>`).join('')}</div>
          <label class="field-label">العنوان</label><input class="field" name="title" required>
          <label class="field-label">النص</label><textarea class="field" name="body" rows="4" required></textarea>
          <label class="meta"><input type="checkbox" name="urgent"> رسالة عاجلة (تظهر بلون أحمر في التطبيق)</label>
          <button class="btn btn-primary">إرسال</button>
        </form>
      </div>
      <div class="card" style="flex:1.3; min-width:300px"><div class="card-head"><h2>الرسائل المرسلة</h2></div><div id="hist"></div></div>
    </div>`;
  const f = document.getElementById('f');
  f.querySelectorAll('[data-t]').forEach((b) => b.onclick = () => { const [t, body] = TEMPLATES[b.dataset.t]; f.title.value = t; f.body.value = body; });
  f.onsubmit = async (e) => {
    e.preventDefault();
    try {
      const r = await rpc('app_send_broadcast', { p_group_id: f.g.value ? Number(f.g.value) : null, p_title: f.title.value, p_body: f.body.value, p_urgent: f.urgent.checked });
      toast(`وصلت الرسالة إلى ${r.recipients} حاجاً`); f.reset(); load();
    } catch (ex) { toast(ex.message, 'danger'); }
  };
  load();
}

async function load() {
  const { data } = await supabase.from('broadcasts').select('id, title, body, is_urgent, created_at, group_id, groups(name), users(full_name)').order('created_at', { ascending: false }).limit(50);
  const gids = groups.map((g) => g.id);
  const rows = (data ?? []).filter((b) => isAdmin(shell.user) || b.group_id === null || gids.includes(b.group_id));
  document.getElementById('hist').innerHTML = rows.map((b) => `<div class="msg-row ${b.is_urgent ? 'urgent' : ''}">
    <b>${esc(b.title)}</b>${b.is_urgent ? ' <span class="pill crit">عاجلة</span>' : ''}<div>${esc(b.body)}</div>
    <span class="meta">${esc(b.users?.full_name)} ← ${esc(b.groups?.name ?? 'كل الحملة')} · ${timeAgo(b.created_at)}</span></div>`).join('') || '<div class="empty-state">لا توجد رسائل.</div>';
}
