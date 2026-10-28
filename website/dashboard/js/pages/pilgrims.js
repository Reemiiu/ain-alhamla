// الحجاج: جدول حسب الأولوية + فلاتر + الملف الكامل (عبر دالة تتحقق من الصلاحية) + إضافة حاج + تعديل الأولوية.
import { rpc } from '../api.js';
import { renderShell, isAdmin, setSubtitle } from '../shell.js';
import { esc, timeAgo, attPill, prioPill, initials, openModal, toast, downloadCsv, battery, LANG, PRIORITY, ATT, dateTime } from '../ui.js';

const shell = renderShell({ page: 'pilgrims.html', title: 'الحجاج' });
let data = { groups: [], pilgrims: [] }, q = '', gF = 'ALL', pF = 'ALL', lF = 'ALL';

if (shell) init(shell);

async function init({ content, actions, user }) {
  if (!isAdmin(user)) document.querySelector('.db-topbar h1').textContent = 'حجاج مجموعتي';
  actions.innerHTML = `<button class="btn btn-outline" id="csv">تصدير CSV</button>${user.role !== 'OPERATIONS_CENTER' ? '<button class="btn btn-primary" id="addBtn">+ إضافة حاج</button>' : ''}`;
  content.innerHTML = `
    <div class="filter-row">
      <div class="search-bar"><input id="q" placeholder="ابحث بالاسم أو رقم الهوية..."></div>
      <select class="field" id="gF" style="max-width:180px"><option value="ALL">كل المجموعات</option></select>
      <select class="field" id="pF" style="max-width:170px"><option value="ALL">كل الأولويات</option>
        <option value="CRITICAL">حرجة</option><option value="HIGH">عالية</option><option value="NORMAL">عادية</option></select>
      <select class="field" id="lF" style="max-width:170px"><option value="ALL">كل اللغات</option>
        ${Object.entries(LANG).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select>
    </div>
    <div class="table-card"><div style="overflow-x:auto"><table class="db-table">
      <thead><tr><th>الحاج</th><th>المجموعة</th><th>الأولوية</th><th>اللغة</th><th>آخر حضور</th><th>آخر موقع</th><th>البطارية</th><th></th></tr></thead>
      <tbody id="tbody"><tr><td colspan="8"><div class="loading-state">جارٍ التحميل...</div></td></tr></tbody></table></div></div>`;
  document.getElementById('q').oninput = (e) => { q = e.target.value.trim().toLowerCase(); render(); };
  ['gF', 'pF', 'lF'].forEach((id) => document.getElementById(id).onchange = (e) => {
    ({ gF: () => { gF = e.target.value; }, pF: () => { pF = e.target.value; }, lF: () => { lF = e.target.value; } })[id](); render();
  });
  document.getElementById('csv').onclick = () => downloadCsv('الحجاج.csv', [['الاسم', 'الهوية', 'الجوال', 'المجموعة', 'الأولوية', 'السبب', 'الجنسية', 'اللغة', 'آخر حضور'],
    ...list().map((p) => [p.full_name, p.national_id, p.phone, p.group_name, PRIORITY[p.priority_level]?.label, p.priority_reason, p.nationality, LANG[p.preferred_language], ATT[p.last_attendance?.status]?.label])]);
  document.getElementById('addBtn')?.addEventListener('click', addPilgrim);
  await load();
}

async function load() {
  data = await rpc('app_board');
  setSubtitle(`${data.pilgrims.length} حاجاً · ${data.pilgrims.filter((p) => p.priority_level !== 'NORMAL').length} أولوية عالية/حرجة · ${data.pilgrims.filter((p) => p.preferred_language !== 'ar').length} غير ناطق بالعربية`);
  const sel = document.getElementById('gF');
  sel.innerHTML = '<option value="ALL">كل المجموعات</option>' + data.groups.map((g) => `<option value="${g.id}">${esc(g.name)}</option>`).join('');
  sel.value = gF;
  render();
}

function list() {
  return data.pilgrims.filter((p) => (gF === 'ALL' || String(p.group_id) === gF) && (pF === 'ALL' || p.priority_level === pF)
    && (lF === 'ALL' || p.preferred_language === lF) && (!q || p.full_name.toLowerCase().includes(q) || p.national_id.includes(q)));
}

function render() {
  const rows = list();
  document.getElementById('tbody').innerHTML = rows.map((p) => `
    <tr data-id="${p.id}" class="clickable">
      <td><div class="row-person"><span class="row-avatar">${esc(initials(p.full_name))}</span><div>${esc(p.full_name)}
        <div class="meta">${esc(p.national_id)}${p.age ? ` · ${p.age} سنة` : ''}</div></div></div></td>
      <td>${esc(p.group_name ?? '—')}</td>
      <td>${prioPill(p.priority_level, p.priority_reason)}</td>
      <td>${p.preferred_language === 'ar' ? 'العربية' : `<span class="lang-chip">${LANG[p.preferred_language]}</span>`}<div class="meta">${esc(p.nationality ?? '')}</div></td>
      <td>${attPill(p.last_attendance?.status, '—')}<div class="meta">${p.last_attendance ? `${esc(p.last_attendance.location ?? '')} · ${timeAgo(p.last_attendance.at)}` : ''}</div></td>
      <td class="muted">${p.last_ping ? timeAgo(p.last_ping.at) : '—'}</td>
      <td>${battery(p.last_ping?.battery)}</td>
      <td>${p.open_alerts ? `<span class="pill crit">${p.open_alerts} تنبيه</span>` : ''}</td>
    </tr>`).join('') || '<tr><td colspan="8"><div class="empty-state">لا يوجد حجاج مطابقون.</div></td></tr>';
  document.querySelectorAll('tr[data-id]').forEach((tr) => tr.onclick = () => openProfile(Number(tr.dataset.id)));
}

async function openProfile(id) {
  let p;
  try { p = await rpc('app_pilgrim_profile', { p_pilgrim_id: id }); } catch (e) { toast(e.message, 'danger'); return; }
  const canEdit = shell.user.role !== 'OPERATIONS_CENTER';
  const m = openModal({
    title: p.full_name, wide: true, sub: `${prioPill(p.priority_level, p.priority_reason)} ${p.preferred_language !== 'ar' ? `<span class="lang-chip">${LANG[p.preferred_language]}</span>` : ''}`,
    body: `<div class="detail-grid">
        <div><div class="detail-label">الهوية</div><div class="detail-value">${esc(p.national_id)}</div></div>
        <div><div class="detail-label">الجوال</div><div class="detail-value"><a href="tel:${esc(p.phone)}">${esc(p.phone)}</a></div></div>
        <div><div class="detail-label">العمر · الجنسية</div><div class="detail-value">${p.age ?? '—'} · ${esc(p.nationality ?? '—')}</div></div>
        <div><div class="detail-label">الجواز</div><div class="detail-value">${esc(p.passport_no ?? '—')}</div></div>
        <div><div class="detail-label">فصيلة الدم</div><div class="detail-value">${esc(p.blood_type ?? '—')}</div></div>
        <div><div class="detail-label">الحالة الصحية</div><div class="detail-value">${esc(p.medical_notes || 'لا يوجد')}</div></div>
      </div>
      <h3 class="sub-h">جهات الطوارئ</h3>
      ${p.contacts.map((c) => `<div class="contact-row"><b>${esc(c.name)}</b> (${esc(c.relation ?? '')}) ${c.is_primary ? '<span class="pill good">أساسية</span>' : ''}
        <a class="btn btn-outline sm" href="tel:${esc(c.phone)}">${esc(c.phone)}</a></div>`).join('') || '<div class="meta">لا يوجد</div>'}
      <h3 class="sub-h">سجل الحضور</h3>
      <div class="att-history">${p.attendance.map((a) => `<div>${attPill(a.status)} <b>${esc(a.gathering ?? a.location ?? '')}</b> <span class="meta">${dateTime(a.at)} · ${a.source === 'MANUAL' ? 'يدوي' : 'التطبيق'}</span></div>`).join('') || '<div class="meta">لا يوجد</div>'}</div>
      ${canEdit ? `<div class="modal-actions"><button type="button" class="btn btn-outline" id="prioBtn">تعديل الأولوية</button></div>` : ''}`,
  });
  m.root.querySelector('#prioBtn')?.addEventListener('click', () => {
    m.close();
    openModal({
      title: `أولوية ${p.full_name}`, submitLabel: 'حفظ',
      sub: 'تُحسب الأولوية تلقائياً من العمر والحالة الصحية، ويمكنك تعديلها يدوياً (مثل: إعاقة حركية، أول حج، لا يجيد القراءة).',
      body: `<label class="field-label">الأولوية</label><select class="field" name="level">${Object.entries(PRIORITY).map(([k, v]) => `<option value="${k}" ${k === p.priority_level ? 'selected' : ''}>${v.label}</option>`).join('')}</select>
        <label class="field-label">السبب</label><input class="field" name="reason" value="${esc(p.priority_reason ?? '')}">`,
      onSubmit: async (f) => { await rpc('app_set_priority', { p_pilgrim_id: id, p_level: f.level, p_reason: f.reason }); toast('تم تحديث الأولوية'); load(); },
    });
  });
}

function addPilgrim() {
  openModal({
    title: 'إضافة حاج', sub: 'يُنشأ للحاج حساب في التطبيق تلقائياً، وتُحسب أولويته من عمره وحالته الصحية.', submitLabel: 'حفظ وإنشاء الحساب',
    body: `<div class="modal-grid">
      <div class="full"><label class="field-label">الاسم الكامل</label><input class="field" name="name" required></div>
      <div><label class="field-label">رقم الهوية / الإقامة</label><input class="field" name="nid" required inputmode="numeric"></div>
      <div><label class="field-label">الجوال</label><input class="field" name="phone" required inputmode="tel"></div>
      <div><label class="field-label">كلمة مرور مؤقتة</label><input class="field" name="pw" required value="Hajj@${Math.floor(1000 + Math.random() * 9000)}"></div>
      <div><label class="field-label">المجموعة</label><select class="field" name="group">${data.groups.map((g) => `<option value="${g.id}">${esc(g.name)} (${g.members}/${g.capacity})</option>`).join('')}</select></div>
      <div><label class="field-label">تاريخ الميلاد</label><input class="field" type="date" name="birth"></div>
      <div><label class="field-label">الجنسية</label><input class="field" name="nat"></div>
      <div><label class="field-label">لغة التطبيق</label><select class="field" name="lang">${Object.entries(LANG).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select></div>
      <div><label class="field-label">الجواز</label><input class="field" name="passport"></div>
      <div><label class="field-label">فصيلة الدم</label><select class="field" name="blood"><option value="">—</option>${['O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'].map((b) => `<option>${b}</option>`).join('')}</select></div>
      <div class="full"><label class="field-label">الحالة الصحية</label><input class="field" name="med" placeholder="مثال: سكري، ضغط، ربو..."></div>
    </div>`,
    onSubmit: async (f) => {
      if (!f.name.trim() || !f.nid.trim() || !f.phone.trim()) throw new Error('الاسم والهوية والجوال مطلوبة');
      await rpc('app_create_pilgrim', {
        p_full_name: f.name, p_national_id: f.nid, p_phone: f.phone, p_password: f.pw, p_group_id: Number(f.group),
        p_birth_date: f.birth || null, p_nationality: f.nat || null, p_language: f.lang, p_passport_no: f.passport || null,
        p_blood_type: f.blood || null, p_medical_notes: f.med || null,
      });
      toast(`تمت إضافة ${esc(f.name)} — بيانات الدخول: ${esc(f.nid)} / ${esc(f.pw)}`); load();
    },
  });
}
