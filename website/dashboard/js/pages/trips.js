// التنقلات: رحلات الحافلات بين المشاعر، المجموعات المرتبطة بكل رحلة، وحالتها.
import { supabase, rpc } from '../api.js';
import { renderShell, onTick, isAdmin } from '../shell.js';
import { esc, dateTime, openModal, toast, toLocalInput } from '../ui.js';

const shell = renderShell({ page: 'trips.html', title: 'التنقلات', subtitle: 'رحلات الحافلات بين المشاعر' });
let trips = [], locations = [], groups = [];
const ST = { SCHEDULED: ['مجدولة', 'muted'], IN_PROGRESS: ['في الطريق', 'warn'], COMPLETED: ['وصلت', 'good'] };

if (shell) init(shell);

async function init({ content, actions, user }) {
  if (user.role === 'ADMIN') {
    actions.innerHTML = '<button class="btn btn-primary" id="addT">+ رحلة جديدة</button>';
    document.getElementById('addT').onclick = () => edit(null);
  }
  content.innerHTML = '<div class="table-card"><div style="overflow-x:auto"><table class="db-table"><thead><tr><th>الحافلة</th><th>السائق</th><th>المسار</th><th>المغادرة</th><th>الوصول</th><th>المجموعات</th><th>الحالة</th><th></th></tr></thead><tbody id="tb"></tbody></table></div></div>';
  const [me, loc] = await Promise.all([rpc('app_me'), supabase.from('locations').select('id, name')]);
  groups = me.groups; locations = loc.data ?? [];
  await load();
  onTick(load);
}

async function load() {
  const { data } = await supabase.from('trips')
    .select('id, vehicle_no, driver_name, departure_time, arrival_time, status, route_from_id, route_to_id, from:locations!trips_route_from_id_fkey(name), to:locations!trips_route_to_id_fkey(name), trip_groups(group_id, groups(name))')
    .order('departure_time', { ascending: false, nullsFirst: false });
  const gids = groups.map((g) => g.id);
  trips = (data ?? []).filter((t) => isAdmin(shell.user) || t.trip_groups.some((x) => gids.includes(x.group_id)));
  document.getElementById('tb').innerHTML = trips.map((t) => `<tr>
    <td><b>${esc(t.vehicle_no)}</b></td><td>${esc(t.driver_name)}</td><td>${esc(t.from?.name ?? '—')} ← ${esc(t.to?.name ?? '—')}</td>
    <td class="muted">${dateTime(t.departure_time)}</td><td class="muted">${dateTime(t.arrival_time)}</td>
    <td>${t.trip_groups.map((x) => `<span class="lang-chip">${esc(x.groups?.name)}</span>`).join(' ')}</td>
    <td><span class="pill ${ST[t.status][1]}"><span class="dot"></span>${ST[t.status][0]}</span></td>
    <td class="nowrap">${t.status === 'SCHEDULED' ? `<button class="btn btn-outline sm" data-s="IN_PROGRESS" data-id="${t.id}">انطلقت</button>` : ''}
      ${t.status === 'IN_PROGRESS' ? `<button class="btn btn-primary sm" data-s="COMPLETED" data-id="${t.id}">وصلت</button>` : ''}
      ${shell.user.role === 'ADMIN' ? `<button class="btn btn-outline sm" data-edit="${t.id}">تعديل</button>` : ''}</td></tr>`).join('')
    || '<tr><td colspan="8"><div class="empty-state">لا توجد رحلات.</div></td></tr>';
  document.querySelectorAll('[data-s]').forEach((b) => b.onclick = async () => {
    try { await rpc('app_set_trip_status', { p_trip_id: Number(b.dataset.id), p_status: b.dataset.s }); toast('تم تحديث الرحلة'); load(); }
    catch (e) { toast(e.message, 'danger'); }
  });
  document.querySelectorAll('[data-edit]').forEach((b) => b.onclick = () => edit(Number(b.dataset.edit)));
}

function edit(id) {
  const t = trips.find((x) => x.id === id);
  const opts = (sel) => locations.map((l) => `<option value="${l.id}" ${sel === l.id ? 'selected' : ''}>${esc(l.name)}</option>`).join('');
  openModal({
    title: t ? `تعديل ${t.vehicle_no}` : 'رحلة جديدة', submitLabel: 'حفظ',
    body: `<div class="modal-grid">
      <div><label class="field-label">رقم الحافلة</label><input class="field" name="v" required value="${esc(t?.vehicle_no ?? '')}"></div>
      <div><label class="field-label">السائق</label><input class="field" name="d" required value="${esc(t?.driver_name ?? '')}"></div>
      <div><label class="field-label">من</label><select class="field" name="from">${opts(t?.route_from_id)}</select></div>
      <div><label class="field-label">إلى</label><select class="field" name="to">${opts(t?.route_to_id)}</select></div>
      <div class="full"><label class="field-label">موعد المغادرة</label><input class="field" type="datetime-local" name="dep" value="${toLocalInput(t?.departure_time ? new Date(t.departure_time) : new Date(Date.now() + 3600000))}"></div>
      <div class="full"><label class="field-label">المجموعات</label><div class="check-list">${groups.map((g) => `<label><input type="checkbox" name="g${g.id}" ${t?.trip_groups.some((x) => x.group_id === g.id) ? 'checked' : ''}> ${esc(g.name)}</label>`).join('')}</div></div></div>`,
    onSubmit: async (f) => {
      await rpc('app_save_trip', { p_id: id, p_vehicle: f.v, p_driver: f.d, p_from: Number(f.from), p_to: Number(f.to),
        p_departure: new Date(f.dep).toISOString(), p_group_ids: groups.filter((g) => f[`g${g.id}`]).map((g) => g.id) });
      toast('تم حفظ الرحلة'); load();
    },
  });
}
