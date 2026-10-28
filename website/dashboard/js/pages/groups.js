// المجموعات والمشرفون (الإدارة): السعة، المشرف المسؤول، الجاهزية، إضافة/تعديل.
import { supabase, rpc } from '../api.js';
import { renderShell, onTick } from '../shell.js';
import { esc, initials, openModal, toast } from '../ui.js';

const shell = renderShell({ page: 'groups.html', title: 'المجموعات والمشرفون', subtitle: 'توزيع الحجاج على الأفواج والمشرف المسؤول عن كل فوج', roles: ['ADMIN', 'OPERATIONS_CENTER'] });
let board, sups = [];

if (shell) init(shell);

async function init({ content, actions, user }) {
  if (user.role === 'ADMIN') {
    actions.innerHTML = '<button class="btn btn-primary" id="addG">+ مجموعة جديدة</button>';
    document.getElementById('addG').onclick = () => edit(null);
  }
  content.innerHTML = '<div class="group-grid" id="grid"></div><div class="card"><div class="card-head"><h2>المشرفون</h2></div><div id="sups"></div></div>';
  await load();
  onTick(load);
}

async function load() {
  const [b, s, k] = await Promise.all([
    rpc('app_board'),
    supabase.from('supervisors').select('id, job_title, users(id, full_name, phone)'),
    rpc('app_kpis'),
  ]);
  board = b; sups = s.data ?? [];
  document.getElementById('grid').innerHTML = b.groups.map((g) => {
    const mem = b.pilgrims.filter((p) => p.group_id === g.id);
    const fill = Math.round(100 * g.members / g.capacity);
    const stat = k.by_group.find((x) => x.group === g.name);
    return `<div class="card group-card">
      <div class="card-head"><h2>${esc(g.name)}</h2>${shell.user.role === 'ADMIN' ? `<button class="btn btn-outline sm" data-edit="${g.id}">تعديل</button>` : ''}</div>
      <div class="row-person"><span class="row-avatar">${esc(initials(g.supervisor_name))}</span><div><b>${esc(g.supervisor_name ?? 'بلا مشرف')}</b><div class="meta">المشرف المسؤول</div></div></div>
      <div class="cap"><div class="meta">السعة ${g.members} / ${g.capacity}</div><div class="ready-bar"><i style="width:${fill}%"></i></div></div>
      <div class="mini-stats">
        <span class="crit">حرجة ${mem.filter((p) => p.priority_level === 'CRITICAL').length}</span>
        <span class="warn">عالية ${mem.filter((p) => p.priority_level === 'HIGH').length}</span>
        <span class="muted">غير عربي ${mem.filter((p) => p.preferred_language !== 'ar').length}</span>
      </div>
      <div class="meta">نسبة الحضور ${stat?.rate ?? '—'}٪ · تنبيهات مفتوحة ${stat?.open ?? 0}</div>
      ${g.gathering ? `<div class="meta">التجمع الحالي: ${esc(g.gathering.title)} — سجّل ${g.gathering.checked}/${g.members}</div>` : ''}
    </div>`;
  }).join('');
  document.querySelectorAll('[data-edit]').forEach((x) => x.onclick = () => edit(Number(x.dataset.edit)));
  document.getElementById('sups').innerHTML = `<table class="db-table"><thead><tr><th>المشرف</th><th>المسمى</th><th>الجوال</th><th>المجموعات</th></tr></thead><tbody>
    ${sups.map((s) => `<tr><td>${esc(s.users?.full_name)}</td><td class="muted">${esc(s.job_title ?? '')}</td><td><a href="tel:${esc(s.users?.phone)}">${esc(s.users?.phone)}</a></td>
      <td>${b.groups.filter((g) => g.supervisor_name === s.users?.full_name).map((g) => esc(g.name)).join('، ') || '—'}</td></tr>`).join('')}</tbody></table>`;
}

async function edit(id) {
  const g = board.groups.find((x) => x.id === id);
  const { data: raw } = id ? await supabase.from('groups').select('supervisor_id').eq('id', id).single() : { data: null };
  openModal({
    title: g ? `تعديل ${g.name}` : 'مجموعة جديدة', submitLabel: 'حفظ',
    body: `<div class="modal-grid">
      <div class="full"><label class="field-label">اسم المجموعة</label><input class="field" name="name" required value="${esc(g?.name ?? '')}"></div>
      <div><label class="field-label">السعة</label><input class="field" type="number" min="1" name="cap" value="${g?.capacity ?? 40}"></div>
      <div><label class="field-label">المشرف</label><select class="field" name="sup"><option value="">—</option>
        ${sups.map((s) => `<option value="${s.id}" ${raw?.supervisor_id === s.id ? 'selected' : ''}>${esc(s.users?.full_name)}</option>`).join('')}</select></div></div>`,
    onSubmit: async (f) => {
      await rpc('app_save_group', { p_id: id, p_name: f.name, p_capacity: Number(f.cap), p_supervisor_id: f.sup ? Number(f.sup) : null });
      toast('تم الحفظ'); load();
    },
  });
}
