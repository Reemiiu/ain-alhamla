// التشغيل: جاهزية ما قبل السفر، لوحة المفقودات، وتقرير نهاية الحج.
import { rpc } from '../api.js';
import { renderShell } from '../shell.js';
import { esc, timeAgo, toast, openModal, downloadCsv, ALERT_TYPE } from '../ui.js';

const shell = renderShell({ page: 'ops.html', title: 'التشغيل', subtitle: 'قبل السفر وأثناء الحج وبعده' });
const CAT = { PASSPORT: 'جواز سفر', PHONE: 'جوال', GLASSES: 'نظارة', BAG: 'حقيبة', MONEY: 'مال', OTHER: 'أخرى' };
let tab = 'prep';

if (shell) init(shell);

async function init({ content }) {
  content.innerHTML = `
    <div class="filter-row"><div class="seg" id="tabs">
      <button data-t="prep" class="on">تجهيز ما قبل السفر</button><button data-t="lost">المفقودات</button><button data-t="report">تقرير نهاية الحج</button></div></div>
    <div id="view"><div class="loading-state">جارٍ التحميل...</div></div>`;
  content.querySelectorAll('#tabs button').forEach((b) => b.onclick = () => {
    tab = b.dataset.t; content.querySelectorAll('#tabs button').forEach((x) => x.classList.toggle('on', x === b)); render();
  });
  render();
}

async function render() {
  const v = document.getElementById('view');
  v.innerHTML = '<div class="loading-state">جارٍ التحميل...</div>';
  try { await ({ prep, lost, report })[tab](v); } catch (e) { v.innerHTML = `<div class="empty-state">${esc(e.message)}</div>`; }
}

async function prep(v) {
  const m = await rpc('app_prep_matrix');
  const T = m.tasks, P = m.pilgrims.map((p) => ({ ...p, set: new Set(p.done) }));
  const ready = P.filter((p) => T.every((t) => p.set.has(t.id))).length;
  const per = T.map((t) => P.filter((p) => p.set.has(t.id)).length);
  const weakest = per.indexOf(Math.min(...per));
  v.innerHTML = `
    <div class="stat-row">
      <div class="stat-card"><div class="stat-card-head"><span>جاهزون بالكامل</span></div><div class="stat-value" style="color:var(--success)">${ready}</div><div class="stat-sub">من ${P.length} حاجًا</div></div>
      <div class="stat-card ${P.length - ready ? 'danger' : ''}"><div class="stat-card-head"><span>لديهم مهام ناقصة</span></div><div class="stat-value">${P.length - ready}</div><div class="stat-sub">الحاج يحدّثها من التطبيق</div></div>
      <div class="stat-card"><div class="stat-card-head"><span>أضعف مهمة</span></div><div class="stat-value" style="font-size:15px;line-height:1.5">${esc(T[weakest]?.name ?? '—')}</div><div class="stat-sub">${per[weakest] ?? 0} من ${P.length}</div></div>
    </div>
    <div class="table-card"><div style="overflow-x:auto"><table class="db-table prep-matrix">
      <thead><tr><th>الحاج</th>${T.map((t) => `<th class="vert"><span>${esc(t.name)}</span></th>`).join('')}<th>الإنجاز</th></tr></thead>
      <tbody>${P.sort((a, b) => a.set.size - b.set.size).map((p) => `<tr><td><b>${esc(p.name)}</b></td>
        ${T.map((t) => `<td class="c"><span class="dotc ${p.set.has(t.id) ? 'y' : 'n'}" title="${esc(t.name)}"></span></td>`).join('')}
        <td><span class="pill ${p.set.size === T.length ? 'good' : p.set.size >= T.length - 2 ? 'warn' : 'crit'}">${p.set.size}/${T.length}</span></td></tr>`).join('')}</tbody></table></div></div>`;
}

async function lost(v) {
  const rows = await rpc('app_lost_list');
  const col = (st, title) => {
    const items = rows.filter((x) => x.status === st);
    return `<div class="lost-col"><h3>${title} <span class="pill muted">${items.length}</span></h3>${items.map((x) => `
      <div class="lost-item ${x.is_urgent && st === 'OPEN' ? 'urgent' : ''}"><b>${esc(x.description)}</b>
        <div class="meta">${CAT[x.category] ?? ''} · ${x.owner ? `صاحبه: ${esc(x.owner)}` : 'صاحبه غير معروف'} · ${esc(x.place ?? '')} · ${timeAgo(x.created_at)}</div>
        ${x.finder ? `<div class="meta">وجده: ${esc(x.finder)}</div>` : ''}
        ${x.is_urgent && st === 'OPEN' ? '<span class="pill crit">مستند رسمي · أُبلغ مدير الحملة</span>' : ''}
        ${st === 'OPEN' ? `<button class="btn btn-outline sm" data-found="${x.id}">وُجد</button>` : ''}
        ${st === 'FOUND' ? `<button class="btn btn-primary sm" data-ret="${x.id}">سُلّم لصاحبه</button>` : ''}
      </div>`).join('') || '<div class="meta">لا شيء</div>'}</div>`;
  };
  v.innerHTML = `<div class="board-actions" style="margin-bottom:12px"><button class="btn btn-primary" id="addFound">+ تسجيل غرض موجود</button></div>
    <div class="lost-board">${col('OPEN', 'مفقود')}${col('FOUND', 'وُجد · بانتظار التسليم')}${col('RETURNED', 'سُلّم')}</div>`;
  v.querySelectorAll('[data-found]').forEach((b) => b.onclick = async () => {
    try { await rpc('app_report_found', { p_item_id: Number(b.dataset.found) }); toast('سُجّل كموجود، وأُبلغ صاحبه في التطبيق'); render(); } catch (e) { toast(esc(e.message), 'danger'); }
  });
  v.querySelectorAll('[data-ret]').forEach((b) => b.onclick = async () => {
    try { await rpc('app_return_lost', { p_item_id: Number(b.dataset.ret) }); toast('سُجّل التسليم'); render(); } catch (e) { toast(esc(e.message), 'danger'); }
  });
  document.getElementById('addFound').onclick = async () => {
    const board = await rpc('app_board');
    openModal({
      title: 'تسجيل غرض موجود', submitLabel: 'حفظ',
      body: `<label class="field-label">الوصف</label><input class="field" name="d" required placeholder="مثال: محفظة بنية فيها بطاقة">
        <label class="field-label">أين وُجد؟</label><input class="field" name="p">
        <label class="field-label">صاحبه (إن عُرف)</label><select class="field" name="o"><option value="">غير معروف</option>${board.pilgrims.map((p) => `<option value="${p.id}">${esc(p.full_name)}</option>`).join('')}</select>`,
      onSubmit: async (f) => {
        if (!f.d.trim()) throw new Error('اكتبي الوصف');
        await rpc('app_report_found', { p_item_id: null, p_description: f.d, p_place: f.p || null, p_owner: f.o ? Number(f.o) : null });
        toast('سُجّل الغرض'); render();
      },
    });
  };
}

async function report(v) {
  const r = await rpc('app_season_report');
  const types = Object.entries(r.alerts_by_type).sort((a, b) => b[1] - a[1]);
  const max = Math.max(1, ...types.map((t) => t[1]));
  const rituals = [...new Set(r.groups.flatMap((g) => g.attendance.map((a) => a.ritual)))];
  const cell = (rate) => rate == null ? '<td class="c muted">—</td>' : `<td class="c rate ${rate >= 100 ? 'g' : rate >= 90 ? 'w' : 'r'}">${rate}٪</td>`;
  v.innerHTML = `
    <div class="board-actions" style="margin-bottom:12px"><button class="btn btn-outline" id="csv">تصدير CSV</button></div>
    <div class="card"><div class="card-head"><h2>الحضور لكل فوج في كل منسك</h2><span class="meta">من تقارير المناسك المحفوظة في القاعدة</span></div>
      <div style="overflow-x:auto"><table class="db-table"><thead><tr><th>الفوج</th>${rituals.map((x) => `<th class="c">${esc(x)}</th>`).join('')}<th class="c">تنبيهات</th><th class="c">الاستجابة</th><th class="c">التقييم</th></tr></thead>
      <tbody>${r.groups.map((g) => `<tr><td><b>${esc(g.group)}</b></td>${rituals.map((x) => cell(g.attendance.find((a) => a.ritual === x)?.rate)).join('')}
        <td class="c">${g.alerts}</td><td class="c">${g.avg_response_min != null ? `${g.avg_response_min} د` : '—'}</td><td class="c">${g.avg_rating ?? '—'}</td></tr>`).join('')}</tbody></table></div></div>
    <div class="row">
      <div class="card"><div class="card-head"><h2>التنبيهات حسب النوع</h2></div>
        ${types.map(([k, n]) => `<div class="hbar"><span>${esc(ALERT_TYPE[k] ?? k)}</span><span class="ready-bar"><i style="width:${(n / max) * 100}%"></i></span><b>${n}</b></div>`).join('') || '<div class="empty-state">لا تنبيهات</div>'}</div>
      <div class="card"><div class="card-head"><h2>ملاحظات المشرفين</h2></div>
        ${r.groups.map((g) => g.notes.map((n) => `<div class="feed-row"><div><b>${esc(g.group)}:</b> ${esc(n)}</div></div>`).join('')).join('') || '<div class="empty-state">لا ملاحظات بعد</div>'}
        <div class="meta" style="margin-top:8px">المفقودات: ${r.lost_items.total} بلاغ، سُلّم منها ${r.lost_items.returned}</div></div>
    </div>`;
  document.getElementById('csv').onclick = () => downloadCsv('تقرير_نهاية_الحج.csv', [['الفوج', ...rituals, 'تنبيهات', 'متوسط الاستجابة (د)', 'التقييم'],
    ...r.groups.map((g) => [g.group, ...rituals.map((x) => g.attendance.find((a) => a.ritual === x)?.rate ?? ''), g.alerts, g.avg_response_min ?? '', g.avg_rating ?? ''])]);
}
