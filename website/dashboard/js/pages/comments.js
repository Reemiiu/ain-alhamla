// التعليقات: ملاحظات المشرفين + تقييمات الحجاج بعد كل منسك + ردود الإدارة (محادثات).
import { supabase, rpc } from '../api.js';
import { renderShell, isAdmin, onTick } from '../shell.js';
import { esc, timeAgo, stars, initials, openModal, toast } from '../ui.js';

const shell = renderShell({ page: 'comments.html', title: 'التعليقات', subtitle: 'ملاحظات المشرفين وتقييمات الحجاج وردود الإدارة' });
let all = [], tab = 'notes', ritualF = 'ALL', groups = [], rituals = [], user;

if (shell) init(shell);

async function init(s) {
  user = s.user;
  const [me, rit] = await Promise.all([rpc('app_me'), supabase.from('rituals').select('id, name, seq').order('seq')]);
  groups = me.groups; rituals = rit.data ?? [];
  if (!isAdmin(user)) {
    s.actions.innerHTML = '<button class="btn btn-primary" id="newNote">+ ملاحظة للإدارة</button>';
    document.getElementById('newNote').onclick = newNote;
  }
  s.content.innerHTML = `
    <div class="filter-row">
      <div class="seg" id="tabs"><button data-t="notes" class="on">ملاحظات المشرفين</button><button data-t="feedback">تقييمات الحجاج</button><button data-t="all">الكل</button></div>
      <select class="field" id="ritSel" style="max-width:240px"><option value="ALL">كل المناسك</option>${rituals.map((r) => `<option value="${r.id}">${esc(r.name)}</option>`).join('')}</select>
    </div>
    <div class="stat-row compact" id="fbStats"></div>
    <div id="list"></div>`;
  s.content.querySelectorAll('#tabs button').forEach((b) => b.onclick = () => {
    tab = b.dataset.t; s.content.querySelectorAll('#tabs button').forEach((x) => x.classList.toggle('on', x === b)); render();
  });
  document.getElementById('ritSel').onchange = (e) => { ritualF = e.target.value; render(); };
  await load();
  onTick(load);
}

async function load() {
  const { data } = await supabase.from('comments')
    .select('id, kind, body, rating, created_at, parent_id, ritual_id, group_id, alert_id, users(full_name), rituals(name), groups(name)')
    .order('created_at', { ascending: false }).limit(400);
  const gids = groups.map((g) => g.id);
  all = (data ?? []).filter((c) => isAdmin(user) || gids.includes(c.group_id));
  render();
}

function render() {
  const inRit = (c) => ritualF === 'ALL' || String(c.ritual_id) === ritualF;
  const fb = all.filter((c) => c.kind === 'PILGRIM_FEEDBACK' && inRit(c));
  const avg = fb.length ? fb.reduce((t, c) => t + c.rating, 0) / fb.length : null;
  document.getElementById('fbStats').innerHTML = `
    <div class="stat-card"><span>متوسط رضا الحجاج</span><div class="stat-value">${avg ? avg.toFixed(1) : '—'}</div>${stars(avg)}</div>
    <div class="stat-card"><span>عدد التقييمات</span><div class="stat-value">${fb.length}</div></div>
    ${[5, 4, 3, 2, 1].map((n) => { const k = fb.filter((c) => c.rating === n).length; return `<div class="stat-card"><span>${'★'.repeat(n)}</span>
      <div class="bar-h"><i style="width:${fb.length ? (100 * k) / fb.length : 0}%"></i></div><small>${k}</small></div>`; }).join('')}`;

  const roots = all.filter((c) => !c.parent_id && inRit(c) && (tab === 'all' || (tab === 'notes' ? c.kind !== 'PILGRIM_FEEDBACK' : c.kind === 'PILGRIM_FEEDBACK')));
  document.getElementById('list').innerHTML = roots.map((c) => {
    const replies = all.filter((r) => r.parent_id === c.id).reverse();
    const fbk = c.kind === 'PILGRIM_FEEDBACK';
    return `<div class="card comment-card">
      <div class="feed-row"><span class="feed-av ${fbk ? 'gold' : ''}">${esc(initials(c.users?.full_name))}</span><div style="flex:1">
        <b>${esc(c.users?.full_name)}</b> <span class="kind-tag k-${c.kind}">${fbk ? 'تقييم حاج' : c.kind === 'ADMIN_REPLY' ? 'الإدارة' : 'ملاحظة مشرف'}</span>
        ${fbk ? stars(c.rating) : ''}
        <div class="feed-body">${esc(c.body || '—')}</div>
        <span class="meta">${esc(c.rituals?.name ?? (c.alert_id ? 'على بلاغ' : 'عام'))}${c.groups?.name ? ' · ' + esc(c.groups.name) : ''} · ${timeAgo(c.created_at)}</span>
      </div></div>
      ${replies.map((r) => `<div class="feed-row reply"><span class="feed-av">${esc(initials(r.users?.full_name))}</span><div><b>${esc(r.users?.full_name)}</b>
        <span class="kind-tag k-${r.kind}">${r.kind === 'ADMIN_REPLY' ? 'الإدارة' : 'المشرف'}</span><div class="feed-body">${esc(r.body)}</div><span class="meta">${timeAgo(r.created_at)}</span></div></div>`).join('')}
      ${!fbk ? `<form class="inline-form" data-parent="${c.id}"><input class="field" name="body" required placeholder="اكتب رداً..."><button class="btn btn-outline">رد</button></form>` : ''}
    </div>`;
  }).join('') || '<div class="empty-state card">لا توجد تعليقات.</div>';
  document.querySelectorAll('form[data-parent]').forEach((f) => f.onsubmit = async (e) => {
    e.preventDefault();
    try { await rpc('app_add_comment', { p_body: f.body.value, p_parent_id: Number(f.dataset.parent) }); toast('تم إرسال الرد'); load(); }
    catch (ex) { toast(ex.message, 'danger'); }
  });
}

function newNote() {
  openModal({
    title: 'ملاحظة جديدة للإدارة', submitLabel: 'إرسال',
    body: `<div class="modal-grid">
      <div><label class="field-label">المجموعة</label><select class="field" name="g">${groups.map((g) => `<option value="${g.id}">${esc(g.name)}</option>`).join('')}</select></div>
      <div><label class="field-label">المنسك</label><select class="field" name="r"><option value="">عام</option>${rituals.map((r) => `<option value="${r.id}">${esc(r.name)}</option>`).join('')}</select></div>
      <div class="full"><label class="field-label">الملاحظة</label><textarea class="field" name="body" rows="4" required></textarea></div></div>`,
    onSubmit: async (f) => {
      if (!f.body.trim()) throw new Error('اكتب الملاحظة');
      await rpc('app_add_comment', { p_body: f.body, p_group_id: Number(f.g), p_ritual_id: f.r ? Number(f.r) : null });
      toast('وصلت ملاحظتك للإدارة'); load();
    },
  });
}
