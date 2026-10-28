// الصحة: أدوية الحجاج وجرعات اليوم، الجرعات الفائتة، فحوص "أنت بخير؟"، وبطاقة المسعف.
import { rpc } from '../api.js';
import { renderShell, onTick, setSubtitle } from '../shell.js';
import { esc, clock, timeAgo, toast, openModal } from '../ui.js';
import { runChecks } from '../v3.js';

const shell = renderShell({ page: 'health.html', title: 'الصحة', subtitle: 'جرعات الأدوية، والجرعات الفائتة، وفحوص "أنت بخير؟" عند توقف الحركة' });
const DOSE = { TAKEN: ['أُخذت', 'good'], MISSED: ['فائتة', 'crit'], DUE: ['قادمة', 'muted'], SKIPPED: ['متروكة', 'warn'] };
const WELL = { SENT: ['بانتظار الرد', 'warn'], ESCALATED: ['لم يرد · أُبلغ المشرف', 'crit'], HELP: ['طلب مساعدة', 'crit'], ANSWERED_OK: ['رد: بخير', 'good'], SUPPRESSED: ['داخل المخيم · لم يُسأل', 'muted'] };
let meds = [];

if (shell) init(shell);

async function init({ content, actions }) {
  actions.innerHTML = '<button class="btn btn-primary" id="addMed">+ دواء لحاج</button><button class="btn btn-outline" id="genBtn">توليد جرعات اليوم</button><button class="btn btn-outline" id="chkBtn">فحص الجرعات الآن</button>';
  content.innerHTML = `
    <div class="stat-row" id="kpis"></div>
    <div class="row">
      <div class="card" style="flex:1.6"><div class="card-head"><h2>أدوية اليوم</h2><span class="meta">إن لم يؤكد الحاج خلال ٣٠ دقيقة تصبح فائتة ويصل تنبيه لمشرفه</span></div>
        <div style="overflow-x:auto"><table class="db-table"><thead><tr><th>الحاج</th><th>الدواء</th><th>الجرعات</th><th></th></tr></thead><tbody id="meds"></tbody></table></div></div>
      <div class="card" style="flex:1"><div class="card-head"><h2>أنت بخير؟</h2><span class="meta">آخر ٢٤ ساعة</span></div><div id="well"></div></div>
    </div>`;
  document.getElementById('genBtn').onclick = async () => {
    try { const n = await rpc('app_generate_doses'); toast(n ? `أُضيفت ${n} جرعة لليوم` : 'جرعات اليوم موجودة مسبقًا'); load(); } catch (e) { toast(esc(e.message), 'danger'); }
  };
  document.getElementById('chkBtn').onclick = async () => { await runChecks(false); load(); };
  document.getElementById('addMed').onclick = addMedication;
  await load();
  onTick(load);
}

async function load() {
  const [m, w] = await Promise.all([rpc('app_meds_overview'), rpc('app_wellness_list')]);
  meds = m;
  const doses = m.flatMap((x) => x.doses);
  const missed = doses.filter((d) => d.status === 'MISSED').length, due = doses.filter((d) => d.status === 'DUE').length, taken = doses.filter((d) => d.status === 'TAKEN').length;
  const openWell = w.filter((x) => ['SENT', 'ESCALATED', 'HELP'].includes(x.status)).length;
  setSubtitle(`${new Set(m.map((x) => x.pilgrim_id)).size} حجاج لديهم أدوية · ${missed} جرعة فائتة اليوم`);
  document.getElementById('kpis').innerHTML = `
    <div class="stat-card ${missed ? 'danger' : ''}"><div class="stat-card-head"><span>جرعات فائتة</span></div><div class="stat-value ${missed ? 'danger' : ''}">${missed}</div><div class="stat-sub">تحتاج متابعة المشرف</div></div>
    <div class="stat-card"><div class="stat-card-head"><span>قادمة اليوم</span></div><div class="stat-value">${due}</div><div class="stat-sub">تذكير قبل الموعد</div></div>
    <div class="stat-card"><div class="stat-card-head"><span>أُخذت</span></div><div class="stat-value" style="color:var(--success)">${taken}</div><div class="stat-sub">مؤكدة من الحاج أو المشرف</div></div>
    <div class="stat-card ${openWell ? 'danger' : ''}"><div class="stat-card-head"><span>فحوص بلا رد</span></div><div class="stat-value ${openWell ? 'danger' : ''}">${openWell}</div><div class="stat-sub">أنت بخير؟</div></div>`;
  document.getElementById('meds').innerHTML = m.map((x, i) => `
    <tr><td><b>${esc(x.pilgrim)}</b>${x.allergies ? `<div class="meta" style="color:var(--danger)">حساسية: ${esc(x.allergies)}</div>` : ''}</td>
      <td><b>${esc(x.name)}</b><div class="meta">${esc(x.condition ?? '')}${x.needs_fridge ? ' · يحتاج تبريد' : ''}</div></td>
      <td><div class="mini-stats">${x.prn ? '<span class="muted">عند الحاجة</span>' : x.doses.map((d) => `<span class="${DOSE[d.status][1]}">${clock(d.at)} · ${DOSE[d.status][0]}</span>`).join('') || '<span class="muted">لم تُولَّد جرعات اليوم</span>'}</div></td>
      <td><div class="board-actions" style="flex-wrap:nowrap">
        ${x.doses.filter((d) => d.status !== 'TAKEN').slice(0, 1).map((d) => `<button class="btn btn-primary sm" data-dose="${d.id}">أُعطيت ${clock(d.at)}</button>`).join('')}
        <button class="btn btn-outline sm" data-card="${x.pilgrim_id}">بطاقة المسعف</button>
        <button class="btn btn-outline sm" data-stop="${x.medication_id}" data-name="${esc(x.name)}" title="إيقاف الدواء">إيقاف</button></div></td></tr>`).join('')
    || '<tr><td colspan="4"><div class="empty-state">لا توجد أدوية مسجلة.</div></td></tr>';
  document.querySelectorAll('[data-dose]').forEach((b) => b.onclick = async () => {
    try { await rpc('app_take_dose', { p_dose_id: Number(b.dataset.dose) }); toast('سُجّلت الجرعة كمُعطاة'); load(); } catch (e) { toast(esc(e.message), 'danger'); }
  });
  document.querySelectorAll('[data-card]').forEach((b) => b.onclick = () => medicCard(Number(b.dataset.card)));
  document.querySelectorAll('[data-stop]').forEach((b) => b.onclick = () => openModal({
    title: `إيقاف ${b.dataset.name}؟`, sub: 'تُترك جرعات اليوم القادمة ولن تُولَّد جرعات جديدة. يبقى السجل محفوظًا.',
    body: '', submitLabel: 'إيقاف الدواء', danger: true,
    onSubmit: async () => { await rpc('app_stop_medication', { p_medication_id: Number(b.dataset.stop) }); toast('أُوقف الدواء'); load(); },
  }));
  document.getElementById('well').innerHTML = w.map((x) => `
    <div class="contact-row"><div style="flex:1"><b>${esc(x.pilgrim)}</b><div class="meta">${x.still_minutes} د بلا حركة · ${timeAgo(x.sent_at)}</div></div>
      <span class="pill ${WELL[x.status][1]}">${WELL[x.status][0]}</span></div>`).join('')
    || '<div class="empty-state">لا فحوص خلال ٢٤ ساعة. الفحص يُرسل من تطبيق الحاج عند توقف الحركة خارج المخيم.</div>';
}

async function medicCard(pid) {
  try {
    const c = await rpc('app_medic_card', { p_pilgrim_id: pid });
    openModal({
      title: `بطاقة المسعف · ${c.name}`, sub: 'نفس ما يظهر على شاشة قفل جوال الحاج',
      body: `<div class="detail-grid">
        <div><div class="detail-label">فصيلة الدم</div><div class="detail-value" style="font-size:20px;color:var(--danger)">${esc(c.blood_type ?? '—')}</div></div>
        <div><div class="detail-label">العمر</div><div class="detail-value">${c.age ?? '—'}</div></div>
        <div><div class="detail-label">الحالة الصحية</div><div class="detail-value">${esc(c.medical_notes || 'لا يوجد')}</div></div>
        <div><div class="detail-label">الحساسية</div><div class="detail-value" style="color:var(--danger)">${esc(c.allergies || 'لا يوجد')}</div></div>
        <div><div class="detail-label">الأدوية</div><div class="detail-value">${(c.medications ?? []).map(esc).join('، ') || 'لا يوجد'}</div></div>
        <div><div class="detail-label">جهة الطوارئ</div><div class="detail-value">${c.emergency ? `${esc(c.emergency.name)} (${esc(c.emergency.relation ?? '')}) <span dir="ltr">${esc(c.emergency.phone)}</span>` : '—'}</div></div>
      </div>`,
    });
  } catch (e) { toast(esc(e.message), 'danger'); }
}

async function addMedication() {
  const board = await rpc('app_board');
  openModal({
    title: 'إضافة دواء لحاج', submitLabel: 'حفظ',
    sub: 'يُحفظ في ملف الحاج ويظهر في تطبيقه، وتُولَّد جرعات اليوم القادمة فورًا. إن لم يؤكدها خلال ٣٠ دقيقة يصلك تنبيه.',
    body: `<label class="field-label">الحاج</label><select class="field" name="pid" required>${board.pilgrims.map((p) => `<option value="${p.id}">${esc(p.full_name)}</option>`).join('')}</select>
      <label class="field-label">اسم الدواء</label><input class="field" name="name" required placeholder="مثال: ميتفورمين 500">
      <label class="field-label">الحالة (اختياري)</label><input class="field" name="cond" placeholder="مثال: سكري">
      <label class="field-label">الأوقات بتوقيت مكة</label><input class="field" name="times" dir="ltr" placeholder="08:00, 20:00">
      <div class="meta">اتركيها فارغة إن كان الدواء عند الحاجة.</div>
      <label class="field-label"><input type="checkbox" name="fridge"> يحتاج تبريد</label>`,
    onSubmit: async (f) => {
      if (!f.name.trim()) throw new Error('اكتبي اسم الدواء');
      const times = f.times.replace(/،/g, ',').split(/[,\s]+/).map((t) => t.trim()).filter(Boolean);
      const r = await rpc('app_add_medication', { p_name: f.name.trim(), p_pilgrim_id: Number(f.pid), p_condition: f.cond.trim() || null, p_times: times, p_needs_fridge: !!f.fridge });
      toast(r.doses_today ? `أُضيف الدواء و${r.doses_today} جرعة لليوم` : 'أُضيف الدواء'); load();
    },
  });
}
